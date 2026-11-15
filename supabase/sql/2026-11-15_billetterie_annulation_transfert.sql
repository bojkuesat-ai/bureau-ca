-- =====================================================================
-- Billetterie (15/11/2026)
--  * Un seul billet par adresse e-mail et par événement (index unique).
--  * Annulation d'un événement : inscriptions « annule », mail à tous,
--    demande de remboursement créée dans la Caisse pour chaque payeur.
--  * IBAN de remboursement : repris de l'extrait bancaire, sinon demandé
--    au participant par un lien personnel (?r=JETON).
--  * Rapprochement des virements (communication structurée) : import d'un
--    extrait CSV dans la Billetterie ou la Caisse.
--  * Transfert de billet jusqu'au début de l'événement.
--  * Messages des responsables aux inscrits (trace dans bil_messages).
-- =====================================================================

-- ---------- Statuts ----------
alter table public.bil_evenements drop constraint if exists bil_evt_statut_chk;
alter table public.bil_evenements add constraint bil_evt_statut_chk check (statut in ('actif', 'archive', 'annule'));
alter table public.bil_evenements add column if not exists annule_le timestamptz;
alter table public.bil_evenements add column if not exists annule_motif text;
alter table public.bil_evenements add column if not exists annule_par text;
alter table public.bil_evenements add column if not exists annule_par_id uuid;

alter table public.bil_inscriptions drop constraint if exists bil_insc_statut_chk;
alter table public.bil_inscriptions add constraint bil_insc_statut_chk
  check (statut in ('a_confirmer', 'a_valider', 'attente', 'inscrit', 'refuse', 'desinscrit', 'annule'));
alter table public.bil_inscriptions add column if not exists statut_avant_annulation text;
alter table public.bil_inscriptions add column if not exists annule_mail_le timestamptz;
alter table public.bil_inscriptions add column if not exists iban_payeur text;
alter table public.bil_inscriptions add column if not exists iban_titulaire text;
alter table public.bil_inscriptions add column if not exists paye_constate_le timestamptz;
alter table public.bil_inscriptions add column if not exists rembt_statut text;      -- a_traiter | iban_attendu | demande
alter table public.bil_inscriptions add column if not exists rembt_token text;
alter table public.bil_inscriptions add column if not exists rembt_request_id uuid;
alter table public.bil_inscriptions add column if not exists transfere_le timestamptz;
alter table public.bil_inscriptions add column if not exists transfere_de jsonb;
create unique index if not exists bil_insc_rembt_token on public.bil_inscriptions(rembt_token) where rembt_token is not null;

-- Un seul billet par adresse et par événement (inscriptions actives).
create unique index if not exists bil_insc_un_billet_par_mail on public.bil_inscriptions(evenement_id, lower(email))
  where email is not null and statut not in ('refuse', 'desinscrit', 'annule');

-- Les listes « actives » excluent désormais aussi les inscriptions annulées.
do $m$
declare f text; d text;
begin
  foreach f in array array['bil_ajout_manuel', 'bil_srv_inscrire', 'bil_srv_masse', 'bil_srv_repecher', 'bil_stats_calc'] loop
    select pg_get_functiondef(p.oid) into d from pg_proc p where p.proname = f and p.pronamespace = 'public'::regnamespace;
    if d is null then raise exception '% introuvable', f; end if;
    d := regexp_replace(d, $x$'refuse'(\s*),(\s*)'desinscrit'(?!\s*,\s*'annule')$x$, $x$'refuse'\1,\2'desinscrit', 'annule'$x$, 'g');
    execute d;
  end loop;
end $m$;

-- Dépôt dans la Caisse par le serveur (remboursements de la Billetterie) : pas soumis aux horaires.
do $m$
declare d text;
begin
  select pg_get_functiondef('public.depot_autorise'::regproc) into d;
  if position('auth.uid() is null' in d) = 0 then
    d := replace(d, 'if public.is_tresorier() then return new; end if;', 'if public.is_tresorier() or auth.uid() is null then return new; end if;');
    if position('auth.uid() is null' in d) = 0 then raise exception 'depot_autorise : motif introuvable'; end if;
    execute d;
  end if;
end $m$;

-- ---------- Contrôles des écritures faites depuis la page ----------
create or replace function public.bil_insc_controle()
 returns trigger language plpgsql set search_path to 'public'
as $f$
begin
  if tg_op = 'UPDATE' and current_user = 'authenticated' then
    -- Un responsable peut corriger un nom, un e-mail ou annuler une entrée ;
    -- les changements d'état passent par le serveur (mails, liste d'attente).
    new.id := old.id; new.evenement_id := old.evenement_id; new.code := old.code; new.secret := old.secret;
    new.confirm_token := old.confirm_token; new.statut := old.statut; new.paye := old.paye; new.montant := old.montant;
    new.source := old.source; new.preuve_path := old.preuve_path; new.fichiers := old.fichiers;
    new.communication := old.communication; new.created_at := old.created_at;
    new.statut_avant_annulation := old.statut_avant_annulation; new.annule_mail_le := old.annule_mail_le;
    new.iban_payeur := old.iban_payeur; new.iban_titulaire := old.iban_titulaire; new.paye_constate_le := old.paye_constate_le;
    new.rembt_statut := old.rembt_statut; new.rembt_token := old.rembt_token; new.rembt_request_id := old.rembt_request_id;
    new.transfere_le := old.transfere_le; new.transfere_de := old.transfere_de;
    if new.entre_le is not null and old.entre_le is null then
      raise exception 'Les entrées se valident avec le scanner.' using errcode = 'P0001';
    end if;
  end if;
  if tg_op = 'INSERT' and current_user = 'authenticated' then
    new.statut_avant_annulation := null; new.annule_mail_le := null; new.iban_payeur := null; new.iban_titulaire := null;
    new.paye_constate_le := null; new.rembt_statut := null; new.rembt_token := null; new.rembt_request_id := null;
    new.transfere_le := null; new.transfere_de := null;
  end if;
  new.email := nullif(lower(trim(coalesce(new.email,''))), '');
  new.nom := trim(coalesce(new.nom,'')); new.prenom := trim(coalesce(new.prenom,''));
  if new.email is not null and new.statut not in ('refuse', 'desinscrit', 'annule')
     and (tg_op = 'INSERT' or new.email is distinct from old.email or new.statut is distinct from old.statut)
     and exists(select 1 from public.bil_inscriptions x where x.evenement_id = new.evenement_id and x.id <> new.id
                and lower(x.email) = new.email and x.statut not in ('refuse', 'desinscrit', 'annule')) then
    raise exception 'Cette adresse e-mail a déjà un billet pour cet événement (un seul billet par adresse).' using errcode = 'P0001';
  end if;
  new.updated_at := now();
  return new;
end $f$;

create or replace function public.bil_evt_controle()
 returns trigger language plpgsql set search_path to 'public'
as $f$
declare f jsonb; t text; n int := 0; opts jsonb;
begin
  new.titre := trim(coalesce(new.titre,''));
  if new.titre = '' then raise exception 'L''événement n''a pas de nom.' using errcode = 'P0001'; end if;
  if length(new.titre) > 160 then raise exception 'Le nom de l''événement est trop long (160 caractères au plus).' using errcode = 'P0001'; end if;
  if jsonb_typeof(coalesce(new.formulaire,'[]'::jsonb)) <> 'array' then raise exception 'Formulaire illisible.' using errcode = 'P0001'; end if;
  for f in select * from jsonb_array_elements(coalesce(new.formulaire,'[]'::jsonb)) loop
    n := n + 1;
    if coalesce(trim(f->>'label'),'') = '' then raise exception 'Un champ n''a pas d''intitulé.' using errcode = 'P0001'; end if;
    if coalesce(trim(f->>'id'),'') = '' then raise exception 'Un champ n''a pas d''identifiant.' using errcode = 'P0001'; end if;
    t := coalesce(f->>'type','');
    if t not in ('texte','texte_long','choix_unique','choix_multiple','case','nombre','date','telephone','photo','fichier') then
      raise exception 'Type de champ inconnu : %', t using errcode = 'P0001';
    end if;
    if t in ('choix_unique','choix_multiple') then
      opts := coalesce(f->'options','[]'::jsonb);
      if jsonb_typeof(opts) <> 'array' or not exists(select 1 from jsonb_array_elements_text(opts) o where trim(o) <> '') then
        raise exception 'Une liste à choix n''a aucune option (« % »).', f->>'label' using errcode = 'P0001';
      end if;
    end if;
  end loop;
  if n > 40 then raise exception 'Le formulaire compte trop de champs (40 au plus).' using errcode = 'P0001'; end if;
  if new.payant and coalesce(new.prix,0) <= 0 then
    raise exception 'Indiquez d''abord le prix de l''événement : un événement payant doit avoir un tarif.' using errcode = 'P0001';
  end if;
  if new.ouverture is not null and new.fermeture is not null and new.fermeture <= new.ouverture then
    raise exception 'La fermeture des inscriptions doit être après leur ouverture.' using errcode = 'P0001';
  end if;
  if tg_op = 'UPDATE' and current_user = 'authenticated' then
    new.code := old.code; new.commission_id := old.commission_id;
    new.alerte_90 := old.alerte_90; new.alerte_complet := old.alerte_complet;
    new.recettes_envoyees_le := old.recettes_envoyees_le; new.recettes_montant := old.recettes_montant;
    new.recettes_income_id := old.recettes_income_id; new.bilan_envoye_le := old.bilan_envoye_le;
    new.fichiers_purges_le := old.fichiers_purges_le; new.donnees_purgees_le := old.donnees_purgees_le;
    new.stats := old.stats; new.cree_par := old.cree_par; new.created_at := old.created_at;
    new.annule_le := old.annule_le; new.annule_motif := old.annule_motif; new.annule_par := old.annule_par; new.annule_par_id := old.annule_par_id;
    if old.statut = 'annule' and new.statut is distinct from old.statut then
      raise exception 'Un événement annulé ne peut pas être réactivé.' using errcode = 'P0001';
    end if;
    if new.statut = 'annule' and old.statut <> 'annule' then
      raise exception 'Utilisez le bouton « Annuler l''événement » (Réglages) : il prévient les inscrits et prépare les remboursements.' using errcode = 'P0001';
    end if;
  end if;
  if tg_op = 'INSERT' and current_user = 'authenticated' then
    new.recettes_envoyees_le := null; new.stats := null; new.cree_par := auth.uid();
    if new.statut = 'annule' then new.statut := 'actif'; end if;
    new.annule_le := null; new.annule_motif := null; new.annule_par := null; new.annule_par_id := null;
  end if;
  new.updated_at := now();
  return new;
end $f$;

do $m$
declare d text;
begin
  select pg_get_functiondef('public.bil_raison_fermeture'::regproc) into d;
  if position($x$'annule'$x$ in d) = 0 then
    d := replace(d, $x$if e.statut <> 'actif'$x$, $x$if e.statut = 'annule' then return 'annule'; end if;
  if e.statut <> 'actif'$x$);
    if position($x$'annule'$x$ in d) = 0 then raise exception 'bil_raison_fermeture : motif introuvable'; end if;
    execute d;
  end if;
end $m$;

-- ---------- Messages aux inscrits ----------
create table if not exists public.bil_messages (
  id uuid primary key,
  evenement_id uuid not null references public.bil_evenements(id) on delete cascade,
  cible text not null,
  sujet text not null,
  texte text not null,
  par uuid,
  par_nom text,
  envoyes int not null default 0,
  cree_le timestamptz not null default now()
);
alter table public.bil_messages enable row level security;
revoke insert, update, delete on table public.bil_messages from anon, authenticated;
drop policy if exists bil_messages_sel on public.bil_messages;
create policy bil_messages_sel on public.bil_messages for select using (public.bil_peut_evenement(evenement_id));
drop policy if exists mfa_aal2 on public.bil_messages;
create policy mfa_aal2 on public.bil_messages as restrictive for all using ((select public.mfa_ok()));
drop trigger if exists a0_app_garde on public.bil_messages;
create trigger a0_app_garde before insert or delete or update on public.bil_messages
  for each statement execute function app_garde('', 'billetterie');

-- ---------- Annulation ----------
create or replace function public.bil_srv_annuler(p_eid uuid, p_uid uuid, p_par text, p_motif text)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $f$
declare e public.bil_evenements; n int;
begin
  select * into e from public.bil_evenements where id = p_eid for update;
  if not found then return jsonb_build_object('ok', false, 'raison', 'introuvable'); end if;
  if e.statut = 'annule' then return jsonb_build_object('ok', true, 'deja', true); end if;
  if e.donnees_purgees_le is not null then return jsonb_build_object('ok', false, 'raison', 'purge'); end if;
  if length(trim(coalesce(p_motif, ''))) < 5 then return jsonb_build_object('ok', false, 'raison', 'motif'); end if;
  update public.bil_evenements set statut = 'annule', annule_le = now(), annule_motif = left(trim(p_motif), 1000),
    annule_par = left(p_par, 120), annule_par_id = p_uid, inscriptions_ouvertes = false where id = p_eid;
  update public.bil_inscriptions set statut_avant_annulation = statut, statut = 'annule',
    rembt_statut = case when coalesce(montant, 0) > 0 and (paye or (statut = 'a_valider' and preuve_path is not null) or paye_constate_le is not null)
                        then 'a_traiter' end
   where evenement_id = p_eid and statut in ('a_confirmer', 'a_valider', 'attente', 'inscrit');
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'n', n);
end $f$;
revoke all on function public.bil_srv_annuler(uuid, uuid, text, text) from public, anon, authenticated;

-- Demande de remboursement dans la Caisse (ou attente de l'IBAN du participant).
create or replace function public.bil_srv_rembt_creer(p_id uuid)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $f$
declare i public.bil_inscriptions; e public.bil_evenements; c public.bil_commissions; v_uid uuid; v_nom text; v_req uuid;
  v_benef text; v_note text;
begin
  select * into i from public.bil_inscriptions where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'raison', 'introuvable'); end if;
  if i.rembt_request_id is not null then return jsonb_build_object('ok', true, 'etat', 'demande', 'deja', true); end if;
  if i.rembt_statut is null or coalesce(i.montant, 0) <= 0 then return jsonb_build_object('ok', false, 'raison', 'rien'); end if;
  if coalesce(i.iban_payeur, '') = '' then
    update public.bil_inscriptions set rembt_statut = 'iban_attendu',
      rembt_token = coalesce(rembt_token, public.bil_alea(32, 'abcdefghijkmnpqrstuvwxyz23456789')) where id = p_id returning * into i;
    return jsonb_build_object('ok', true, 'etat', 'iban_attendu', 'token', i.rembt_token);
  end if;
  select * into e from public.bil_evenements where id = i.evenement_id;
  select * into c from public.bil_commissions where id = e.commission_id;
  v_uid := coalesce(e.annule_par_id, e.cree_par, (select p.id from public.profiles p where p.role = 'tresorier' and p.approved limit 1));
  if v_uid is null then return jsonb_build_object('ok', false, 'raison', 'demandeur'); end if;
  select nullif(trim(coalesce(prenom, '') || ' ' || coalesce(nom, '')), '') into v_nom from public.ca_membres where id = v_uid;
  v_benef := coalesce(nullif(trim(coalesce(i.iban_titulaire, '')), ''), nullif(trim(coalesce(i.prenom, '') || ' ' || coalesce(i.nom, '')), ''), 'Participant');
  v_note := 'Billetterie : événement « ' || e.titre || ' » annulé le ' || to_char(coalesce(e.annule_le, now()) at time zone 'Europe/Brussels', 'DD/MM/YYYY')
    || '. Billet ' || i.code || ' (' || coalesce(i.email, 'sans e-mail') || '), communication du paiement ' || coalesce(i.communication, '—') || '. '
    || case when i.paye then 'Paiement validé dans la Billetterie.' when i.paye_constate_le is not null then 'Virement reconnu sur l''extrait bancaire.'
            else 'Attention : preuve de paiement jamais vérifiée, contrôlez la réception du virement avant de rembourser.' end
    || case when i.transfere_de is not null then ' Billet cédé par ' || coalesce(i.transfere_de->0->>'prenom', '') || ' ' || coalesce(i.transfere_de->0->>'nom', '') || '.' else '' end;
  insert into public.requests(user_id, requester_name, requester_position, expense_date, amount, object, category, note,
    kind, beneficiary, beneficiary_iban, communication, pay_mode, refund_method, payment_method, iban, status)
  values (v_uid, coalesce(v_nom, 'Billetterie'), left('Billetterie — commission ' || coalesce(c.nom, ''), 120),
    (now() at time zone 'Europe/Brussels')::date, i.montant,
    left('Remboursement billet — ' || e.titre || ' — ' || v_benef || ' (' || i.code || ')', 200), 'Billetterie', left(v_note, 1000),
    'direct', left(v_benef, 120), upper(regexp_replace(i.iban_payeur, '\s', '', 'g')), left('Remboursement billet ' || i.code || ' ' || e.titre, 140),
    'virement', 'Virement', 'Virement', '', 'En attente')
  returning id into v_req;
  update public.bil_inscriptions set rembt_request_id = v_req, rembt_statut = 'demande' where id = p_id;
  return jsonb_build_object('ok', true, 'etat', 'demande', 'request_id', v_req);
end $f$;
revoke all on function public.bil_srv_rembt_creer(uuid) from public, anon, authenticated;

-- IBAN donné par le participant (lien ?r=JETON).
create or replace function public.bil_srv_rembt_iban(p_token text, p_iban text, p_titulaire text)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $f$
declare i public.bil_inscriptions;
begin
  select * into i from public.bil_inscriptions where rembt_token = trim(coalesce(p_token, '')) and rembt_token is not null for update;
  if not found then return jsonb_build_object('ok', false, 'raison', 'inconnu'); end if;
  if i.rembt_request_id is not null then return jsonb_build_object('ok', true, 'etat', 'demande', 'deja', true, 'id', i.id); end if;
  update public.bil_inscriptions set iban_payeur = upper(regexp_replace(p_iban, '\s', '', 'g')),
    iban_titulaire = left(nullif(trim(coalesce(p_titulaire, '')), ''), 120) where id = i.id;
  return public.bil_srv_rembt_creer(i.id) || jsonb_build_object('id', i.id);
end $f$;
revoke all on function public.bil_srv_rembt_iban(text, text, text) from public, anon, authenticated;

create or replace function public.bil_public_rembt(p_token text)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $f$
declare i public.bil_inscriptions; e public.bil_evenements; c public.bil_commissions; st text;
begin
  select * into i from public.bil_inscriptions where rembt_token = trim(coalesce(p_token, '')) and rembt_token is not null;
  if not found then return null; end if;
  select * into e from public.bil_evenements where id = i.evenement_id;
  select * into c from public.bil_commissions where id = e.commission_id;
  if i.rembt_request_id is not null then select status into st from public.requests where id = i.rembt_request_id; end if;
  return jsonb_build_object('titre', e.titre, 'commission', c.nom, 'date', e.date_evt, 'motif', e.annule_motif,
    'prenom', i.prenom, 'nom', i.nom, 'montant', i.montant, 'etat', coalesce(i.rembt_statut, ''),
    'caisse', st, 'iban_fin', case when i.iban_payeur is not null then right(i.iban_payeur, 4) end);
end $f$;
grant execute on function public.bil_public_rembt(text) to anon, authenticated;

-- État des remboursements d'un événement (page des responsables).
create or replace function public.bil_rembt_etats(p_eid uuid)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $f$
begin
  if not public.bil_peut_evenement(p_eid) or not public.mfa_ok() then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'etat', i.rembt_statut, 'caisse', r.status, 'paye_le', r.paid_at,
      'iban', i.iban_payeur is not null, 'montant', i.montant))
    from public.bil_inscriptions i left join public.requests r on r.id = i.rembt_request_id
    where i.evenement_id = p_eid and i.rembt_statut is not null), '[]'::jsonb);
end $f$;
revoke all on function public.bil_rembt_etats(uuid) from public, anon;
grant execute on function public.bil_rembt_etats(uuid) to authenticated;

-- ---------- Rapprochement des virements ----------
-- p_lignes : [{ "ogm": "123456789012", "montant": 12.5 | null, "iban": "BE.." | null, "nom": "…" | null }]
create or replace function public.bil_srv_rapprocher(p_uid uuid, p_tout boolean, p_lignes jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $f$
declare l jsonb; i public.bil_inscriptions; v_ogm text; v_mnt numeric; v_iban text; v_nom text;
  valides jsonb := '[]'; rembts jsonb := '[]'; rapport jsonb := '[]'; etat text; n_lu int := 0;
begin
  for l in select * from jsonb_array_elements(coalesce(p_lignes, '[]'::jsonb)) loop
    n_lu := n_lu + 1;
    v_ogm := regexp_replace(coalesce(l->>'ogm', ''), '\D', '', 'g');
    if length(v_ogm) <> 12 then continue; end if;
    v_mnt := nullif(l->>'montant', '')::numeric;
    v_iban := nullif(upper(regexp_replace(coalesce(l->>'iban', ''), '\s', '', 'g')), '');
    v_nom := nullif(left(trim(coalesce(l->>'nom', '')), 120), '');
    select * into i from public.bil_inscriptions x
     where regexp_replace(coalesce(x.communication, ''), '\D', '', 'g') = v_ogm
       and (p_tout or public.bil_peut_evenement_uid(p_uid, x.evenement_id))
     order by (x.statut = 'a_valider') desc, x.created_at desc limit 1 for update;
    if not found then continue; end if;
    if v_mnt is not null and coalesce(i.montant, 0) > v_mnt + 0.005 then
      etat := 'montant';
    elsif i.statut = 'a_valider' then
      update public.bil_inscriptions set statut = 'inscrit', paye = true, valide_le = now(), valide_par = 'Virement reçu (extrait bancaire)',
        paye_constate_le = coalesce(paye_constate_le, now()), iban_payeur = coalesce(iban_payeur, v_iban),
        iban_titulaire = coalesce(iban_titulaire, v_nom, nullif(trim(coalesce(prenom, '') || ' ' || coalesce(nom, '')), '')) where id = i.id;
      valides := valides || to_jsonb(i.id); etat := 'valide';
    elsif i.statut = 'attente' then
      update public.bil_inscriptions set paye = true, paye_constate_le = coalesce(paye_constate_le, now()), iban_payeur = coalesce(iban_payeur, v_iban),
        iban_titulaire = coalesce(iban_titulaire, v_nom, nullif(trim(coalesce(prenom, '') || ' ' || coalesce(nom, '')), '')) where id = i.id;
      etat := 'attente';
    elsif i.statut = 'annule' then
      update public.bil_inscriptions set paye_constate_le = coalesce(paye_constate_le, now()), iban_payeur = coalesce(iban_payeur, v_iban),
        iban_titulaire = coalesce(iban_titulaire, v_nom), rembt_statut = coalesce(rembt_statut, 'a_traiter') where id = i.id;
      if i.rembt_request_id is null then rembts := rembts || to_jsonb(i.id); end if;
      etat := 'annule';
    elsif i.statut = 'inscrit' then
      if i.iban_payeur is null and v_iban is not null then
        update public.bil_inscriptions set iban_payeur = v_iban, paye_constate_le = coalesce(paye_constate_le, now()),
          iban_titulaire = coalesce(iban_titulaire, v_nom, nullif(trim(coalesce(prenom, '') || ' ' || coalesce(nom, '')), '')) where id = i.id;
      end if;
      etat := 'deja';
    else
      update public.bil_inscriptions set paye_constate_le = coalesce(paye_constate_le, now()), iban_payeur = coalesce(iban_payeur, v_iban),
        iban_titulaire = coalesce(iban_titulaire, v_nom) where id = i.id;
      etat := 'hors';   -- refusé ou désinscrit : à rembourser à la main
    end if;
    rapport := rapport || jsonb_build_array(jsonb_build_object('id', i.id, 'evenement_id', i.evenement_id, 'etat', etat,
      'nom', trim(coalesce(i.prenom, '') || ' ' || coalesce(i.nom, '')), 'montant', i.montant, 'recu', v_mnt, 'statut', i.statut));
  end loop;
  return jsonb_build_object('lues', n_lu, 'valides', valides, 'rembts', rembts, 'rapport', rapport);
end $f$;
revoke all on function public.bil_srv_rapprocher(uuid, boolean, jsonb) from public, anon, authenticated;

-- ---------- Transfert de billet ----------
create or replace function public.bil_srv_transferer(p_secret text, p_nom text, p_prenom text, p_email text)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $f$
declare i public.bil_inscriptions; e public.bil_evenements; v_mail text := lower(trim(coalesce(p_email, ''))); v_debut timestamptz;
  ancien jsonb; essai int := 0;
begin
  select * into i from public.bil_inscriptions where secret = trim(coalesce(p_secret, '')) for update;
  if not found then return jsonb_build_object('etat', 'inconnu'); end if;
  select * into e from public.bil_evenements where id = i.evenement_id;
  if e.statut <> 'actif' then return jsonb_build_object('etat', 'ferme'); end if;
  if i.statut <> 'inscrit' then return jsonb_build_object('etat', 'statut', 'statut', i.statut); end if;
  if i.entre_le is not null then return jsonb_build_object('etat', 'entre'); end if;
  if e.date_evt is not null then
    v_debut := (e.date_evt + coalesce(e.heure_debut, time '00:00'))::timestamp at time zone 'Europe/Brussels';
    if now() >= v_debut then return jsonb_build_object('etat', 'commence'); end if;
  end if;
  if trim(coalesce(p_nom, '')) = '' or trim(coalesce(p_prenom, '')) = '' then return jsonb_build_object('etat', 'invalide'); end if;
  if v_mail !~ '^[^\s@]{1,64}@[^\s@]{1,190}\.[^\s@]{2,}$' then return jsonb_build_object('etat', 'invalide'); end if;
  if v_mail = lower(coalesce(i.email, '')) then return jsonb_build_object('etat', 'meme'); end if;
  if exists(select 1 from public.bil_inscriptions x where x.evenement_id = i.evenement_id and lower(x.email) = v_mail
            and x.statut not in ('refuse', 'desinscrit', 'annule')) then
    return jsonb_build_object('etat', 'deja');
  end if;
  ancien := jsonb_build_object('prenom', i.prenom, 'nom', i.nom, 'email', i.email, 'code', i.code, 'le', now());
  loop
    begin
      update public.bil_inscriptions set nom = left(trim(p_nom), 120), prenom = left(trim(p_prenom), 120), email = v_mail,
        code = public.bil_alea(8), secret = public.bil_alea(32, 'abcdefghijkmnpqrstuvwxyz23456789'),
        reponses = '{}'::jsonb, presence = null, presence_le = null, presence_demandee_le = null, rappel_le = null,
        relance_le = null, billet_envoye_le = null, coopte = false,
        iban_titulaire = coalesce(iban_titulaire, case when paye then nullif(trim(coalesce(i.prenom, '') || ' ' || coalesce(i.nom, '')), '') end),
        transfere_le = now(), transfere_de = coalesce(transfere_de, '[]'::jsonb) || jsonb_build_array(ancien)
      where id = i.id;
      exit;
    exception when unique_violation then
      essai := essai + 1; if essai > 5 then raise; end if;
    end;
  end loop;
  return jsonb_build_object('etat', 'ok', 'id', i.id, 'evenement_id', i.evenement_id,
    'ancien_email', i.email, 'ancien_prenom', i.prenom, 'ancien_nom', i.nom);
end $f$;
revoke all on function public.bil_srv_transferer(text, text, text, text) from public, anon, authenticated;

-- Le billet public dit si la place peut être cédée, et l'état d'une annulation.
create or replace function public.bil_public_billet(p_secret text)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $f$
declare i public.bil_inscriptions; e public.bil_evenements; c public.bil_commissions; cfg public.bil_config; rang int; v_debut timestamptz;
begin
  select * into i from public.bil_inscriptions where secret = trim(coalesce(p_secret,''));
  if not found then return null; end if;
  select * into e from public.bil_evenements where id = i.evenement_id;
  select * into c from public.bil_commissions where id = e.commission_id;
  select * into cfg from public.bil_config where id = 1;
  if i.statut = 'attente' then
    select count(*) + 1 into rang from public.bil_inscriptions x where x.evenement_id = i.evenement_id and x.statut = 'attente'
      and (coalesce(x.email_confirme_le, x.created_at), x.created_at) < (coalesce(i.email_confirme_le, i.created_at), i.created_at);
  end if;
  if e.date_evt is not null then v_debut := (e.date_evt + coalesce(e.heure_debut, time '00:00'))::timestamp at time zone 'Europe/Brussels'; end if;
  return jsonb_build_object(
    'code', i.code, 'nom', i.nom, 'prenom', i.prenom, 'statut', i.statut, 'entre_le', i.entre_le, 'rang', rang,
    'presence', i.presence, 'communication', i.communication, 'montant', i.montant, 'paye', i.paye,
    'iban', case when e.payant then cfg.iban end, 'titulaire', case when e.payant then cfg.titulaire end,
    'cessible', i.statut = 'inscrit' and i.entre_le is null and e.statut = 'actif' and (v_debut is null or now() < v_debut),
    'debut', v_debut,
    'annule_motif', case when e.statut = 'annule' then e.annule_motif end,
    'rembt', i.rembt_statut, 'rembt_token', case when i.rembt_statut = 'iban_attendu' then i.rembt_token end,
    'evenement', jsonb_build_object('titre', e.titre, 'commission', c.nom, 'date', e.date_evt,
      'heure_debut', to_char(e.heure_debut, 'HH24:MI'), 'heure_fin', to_char(e.heure_fin, 'HH24:MI'),
      'lieu', e.lieu, 'infos', e.infos, 'payant', e.payant, 'prix', e.prix, 'code', e.code, 'statut', e.statut),
    'sondage_fait', exists(select 1 from public.bil_sondages s where s.inscription_id = i.id));
end $f$;

-- Responsable (ou trésorier pour le rapprochement) : l'appelant est-il trésorier de la Caisse ?
create or replace function public.bil_srv_est_tresorier(p_uid uuid)
 returns boolean language sql stable security definer set search_path to 'public'
as $f$ select exists(select 1 from public.profiles where id = p_uid and role = 'tresorier' and approved) $f$;
revoke all on function public.bil_srv_est_tresorier(uuid) from public, anon, authenticated;
