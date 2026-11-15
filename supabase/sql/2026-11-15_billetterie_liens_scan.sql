-- =====================================================================
-- Billetterie : liens de scan (remplacent le « code de scan des bénévoles »)
-- ---------------------------------------------------------------------
-- * Un lien par personne (prénom), valable 24 h, révocable.
-- * Couvre les événements actifs du jour de sa création :
--     - ceux dont le créateur est responsable (commission) ;
--     - ou tous (option réservée à l'Admin et au propriétaire).
-- * Le lien ne permet QUE : scanner un billet, chercher un nom
--   (nom, prénom, événement, entré ou pas). Rien d'autre.
-- * Seul le hash SHA-256 du jeton est gardé en base.
-- * Table vidée à la fin du mandat (non listée dans fin_mandat_garder).
-- =====================================================================

create table if not exists public.bil_scan_liens (
  id uuid primary key default gen_random_uuid(),
  jeton_hash text not null unique,
  prenom text not null,
  cree_par uuid not null references auth.users(id) on delete cascade,
  tous boolean not null default false,
  jour date not null,
  cree_le timestamptz not null default now(),
  expire_le timestamptz not null,
  revoque_le timestamptz,
  revoque_par uuid,
  nb_scans int not null default 0,
  dernier_scan timestamptz
);
alter table public.bil_scan_liens enable row level security;   -- aucune politique : accès par les fonctions seulement
revoke all on table public.bil_scan_liens from anon, authenticated;
drop trigger if exists a0_app_garde on public.bil_scan_liens;
create trigger a0_app_garde before insert or delete or update on public.bil_scan_liens
  for each statement execute function app_garde('', 'billetterie');

alter table public.bil_scans add column if not exists lien_id uuid;

-- Jeton -> lien valable + événements couverts (interne).
create or replace function public.bil_scan_lien_resoudre(p_jeton text, out lien public.bil_scan_liens, out ids uuid[])
 language plpgsql stable security definer set search_path to 'public', 'extensions'
as $f$
declare v text := upper(regexp_replace(coalesce(p_jeton, ''), '[^A-Za-z0-9]', '', 'g'));
begin
  ids := '{}';
  if length(v) < 20 then return; end if;
  select * into lien from public.bil_scan_liens l
   where l.jeton_hash = encode(extensions.digest(v, 'sha256'), 'hex') and l.revoque_le is null and l.expire_le > now();
  if lien.id is null then return; end if;
  if public.bil_maintenance() or (lien.tous and not public.bil_est_owner(lien.cree_par)) then lien := null; return; end if;
  select coalesce(array_agg(e.id), '{}') into ids from public.bil_evenements e
   where e.date_evt = lien.jour and e.statut = 'actif' and (lien.tous or public.bil_peut_evenement_uid(lien.cree_par, e.id));
end $f$;
revoke all on function public.bil_scan_lien_resoudre(text) from public, anon, authenticated;

-- Création (responsable de commission, Admin, propriétaire).
create or replace function public.bil_scan_lien_creer(p_prenom text, p_tous boolean default false)
 returns jsonb language plpgsql security definer set search_path to 'public', 'extensions'
as $f$
declare v_uid uuid := auth.uid(); v_jour date := (now() at time zone 'Europe/Brussels')::date;
  v_nom text := left(trim(coalesce(p_prenom, '')), 40); ids uuid[]; v_jeton text; v_id uuid; v_exp timestamptz := now() + interval '24 hours';
begin
  if v_uid is null then raise exception 'Connexion requise.' using errcode = 'P0001'; end if;
  if not public.mfa_ok() then raise exception 'Double authentification requise : entrez votre code.' using errcode = 'P0001'; end if;
  if public.bil_maintenance() and not public.bil_est_owner(v_uid) then raise exception 'Billetterie en maintenance.' using errcode = 'P0001'; end if;
  if v_nom = '' then raise exception 'Indiquez le prénom de la personne qui va scanner.' using errcode = 'P0001'; end if;
  if coalesce(p_tous, false) and not public.bil_est_owner(v_uid) then
    raise exception 'Le lien pour tous les événements est réservé à l''Admin et au propriétaire.' using errcode = 'P0001';
  end if;
  select array_agg(e.id) into ids from public.bil_evenements e
   where e.date_evt = v_jour and e.statut = 'actif' and (coalesce(p_tous, false) or public.bil_peut_evenement(e.id));
  if ids is null then raise exception 'Aucun de vos événements n''a lieu aujourd''hui : le lien ne couvre que les événements du jour.' using errcode = 'P0001'; end if;
  if (select count(*) from public.bil_scan_liens where cree_par = v_uid and cree_le > now() - interval '1 day') >= 40 then
    raise exception 'Trop de liens créés aujourd''hui (40 au plus).' using errcode = 'P0001';
  end if;
  delete from public.bil_scan_liens where expire_le < now() - interval '30 days';
  v_jeton := public.bil_alea(24);
  insert into public.bil_scan_liens(jeton_hash, prenom, cree_par, tous, jour, expire_le)
  values (encode(extensions.digest(v_jeton, 'sha256'), 'hex'), v_nom, v_uid, coalesce(p_tous, false), v_jour, v_exp)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'jeton', v_jeton, 'prenom', v_nom, 'expire', v_exp,
    'evenements', (select jsonb_agg(e.titre order by e.heure_debut nulls last) from public.bil_evenements e where e.id = any(ids)));
end $f$;
revoke all on function public.bil_scan_lien_creer(text, boolean) from public, anon;
grant execute on function public.bil_scan_lien_creer(text, boolean) to authenticated;

-- Liste : mes liens (tous pour l'Admin / le propriétaire), récents.
create or replace function public.bil_scan_liens_liste()
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $f$
declare v_uid uuid := auth.uid(); v_tout boolean;
begin
  if v_uid is null or not public.mfa_ok() then return '[]'::jsonb; end if;
  v_tout := public.bil_est_owner(v_uid);
  return coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'prenom', l.prenom, 'tous', l.tous, 'jour', l.jour,
      'cree_le', l.cree_le, 'expire_le', l.expire_le, 'revoque_le', l.revoque_le, 'nb_scans', l.nb_scans, 'dernier_scan', l.dernier_scan,
      'actif', l.revoque_le is null and l.expire_le > now(), 'a_moi', l.cree_par = v_uid,
      'cree_par_nom', nullif(trim(coalesce(m.prenom, '') || ' ' || coalesce(m.nom, '')), ''))
      order by (l.revoque_le is null and l.expire_le > now()) desc, l.cree_le desc)
    from public.bil_scan_liens l left join public.ca_membres m on m.id = l.cree_par
    where (l.cree_par = v_uid or v_tout) and l.cree_le > now() - interval '3 days'), '[]'::jsonb);
end $f$;
revoke all on function public.bil_scan_liens_liste() from public, anon;
grant execute on function public.bil_scan_liens_liste() to authenticated;

create or replace function public.bil_scan_lien_revoquer(p_id uuid)
 returns boolean language plpgsql security definer set search_path to 'public'
as $f$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Connexion requise.' using errcode = 'P0001'; end if;
  if not public.mfa_ok() then raise exception 'Double authentification requise : entrez votre code.' using errcode = 'P0001'; end if;
  update public.bil_scan_liens set revoque_le = now(), revoque_par = v_uid
   where id = p_id and revoque_le is null and (cree_par = v_uid or public.bil_est_owner(v_uid));
  if not found then raise exception 'Lien introuvable, déjà révoqué, ou pas à vous.' using errcode = 'P0001'; end if;
  return true;
end $f$;
revoke all on function public.bil_scan_lien_revoquer(uuid) from public, anon;
grant execute on function public.bil_scan_lien_revoquer(uuid) to authenticated;

-- Accès du téléphone bénévole (p_scan_code = jeton du lien).
create or replace function public.bil_scan_acces(p_scan_code text)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $f$
declare r record;
begin
  select * into r from public.bil_scan_lien_resoudre(p_scan_code);
  if (r.lien).id is null then return null; end if;
  return jsonb_build_object('lien', (r.lien).id, 'prenom', (r.lien).prenom, 'tous', (r.lien).tous, 'jour', (r.lien).jour, 'expire', (r.lien).expire_le,
    'evenements', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'titre', e.titre, 'commission', c.nom,
        'heure_debut', to_char(e.heure_debut, 'HH24:MI'), 'lieu', e.lieu) order by e.heure_debut nulls last, e.titre)
      from public.bil_evenements e left join public.bil_commissions c on c.id = e.commission_id where e.id = any(r.ids)), '[]'::jsonb));
end $f$;

create or replace function public.bil_scan(p_code text, p_evenements uuid[] default null, p_scan_code text default null,
  p_scanne_le timestamptz default null, p_appareil text default null, p_horsligne boolean default false, p_par text default null)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $f$
declare v_code text := public.bil_norm_code(p_code); ids uuid[]; i public.bil_inscriptions; r record; v_lien uuid;
  quand timestamptz := least(coalesce(p_scanne_le, now()), now()); res text; doublon boolean := false; v_par text;
begin
  if coalesce(p_scan_code,'') <> '' then
    select * into r from public.bil_scan_lien_resoudre(p_scan_code);
    if (r.lien).id is null then return jsonb_build_object('resultat', 'acces', 'message', 'Lien de scan invalide, révoqué ou expiré.'); end if;
    ids := r.ids; v_lien := (r.lien).id; v_par := (r.lien).prenom || ' (lien)';
    update public.bil_scan_liens set nb_scans = nb_scans + 1, dernier_scan = now() where id = v_lien;
  else
    if auth.uid() is null then return jsonb_build_object('resultat', 'acces', 'message', 'Connexion requise.'); end if;
    select array_agg(x) into ids from unnest(coalesce(p_evenements,'{}')) x where public.bil_peut_evenement(x);
    select trim(coalesce(prenom,'') || ' ' || coalesce(nom,'')) into v_par from public.ca_membres where id = auth.uid();
  end if;
  if quand < now() - interval '3 days' then quand := now(); end if;
  select * into i from public.bil_inscriptions where code = v_code and evenement_id = any(coalesce(ids,'{}'));
  if not found then
    insert into public.bil_scans(evenement_id, code, resultat, appareil, par, horsligne, scanne_le, lien_id)
    values (case when array_length(ids,1) = 1 then ids[1] end, left(v_code, 40), 'inconnu', p_appareil, v_par, p_horsligne, quand, v_lien);
    return jsonb_build_object('resultat', 'inconnu', 'code', v_code);
  end if;
  if i.statut <> 'inscrit' then
    insert into public.bil_scans(evenement_id, inscription_id, code, resultat, appareil, par, horsligne, scanne_le, lien_id)
    values (i.evenement_id, i.id, v_code, 'invalide', p_appareil, v_par, p_horsligne, quand, v_lien);
    return jsonb_build_object('resultat', 'invalide', 'statut', i.statut, 'nom', i.nom, 'prenom', i.prenom, 'id', i.id);
  end if;
  update public.bil_inscriptions set entre_le = quand, entre_par = v_par, entre_appareil = p_appareil
    where id = i.id and entre_le is null returning * into i;
  if found then
    res := 'ok';
  else
    select * into i from public.bil_inscriptions where code = v_code;
    res := 'deja';
    doublon := p_horsligne and coalesce(i.entre_appareil,'') <> coalesce(p_appareil,'');
  end if;
  insert into public.bil_scans(evenement_id, inscription_id, code, resultat, appareil, par, horsligne, scanne_le, lien_id)
  values (i.evenement_id, i.id, v_code, case when doublon then 'doublon' else res end, p_appareil, v_par, p_horsligne, quand, v_lien);
  return jsonb_build_object('resultat', res, 'doublon', doublon, 'id', i.id, 'evenement_id', i.evenement_id,
    'nom', i.nom, 'prenom', i.prenom, 'entre_le', i.entre_le, 'entre_par', i.entre_par, 'entre_appareil', i.entre_appareil);
end $f$;

create or replace function public.bil_scan_compteur(p_evenements uuid[] default null, p_scan_code text default null)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $f$
declare ids uuid[]; r record;
begin
  if coalesce(p_scan_code,'') <> '' then
    select * into r from public.bil_scan_lien_resoudre(p_scan_code);
    if (r.lien).id is null then return null; end if;
    ids := r.ids;
  else
    select array_agg(x) into ids from unnest(coalesce(p_evenements,'{}')) x where public.bil_peut_evenement(x);
  end if;
  return (select jsonb_build_object('total', count(*), 'entres', count(*) filter (where entre_le is not null),
      'q15', count(*) filter (where entre_le >= now() - interval '15 minutes'),
      'q60', count(*) filter (where entre_le >= now() - interval '1 hour'),
      'dernier', max(entre_le))
    from public.bil_inscriptions where evenement_id = any(coalesce(ids,'{}')) and statut = 'inscrit');
end $f$;

-- Recherche : nom, prénom, code du billet (pour valider), événement, entré ou pas. Rien d'autre.
create or replace function public.bil_scan_liste(p_evenements uuid[] default null, p_scan_code text default null)
 returns table(id uuid, evenement_id uuid, code text, nom text, prenom text, entre_le timestamptz, entre_appareil text)
 language plpgsql stable security definer set search_path to 'public'
as $f$
declare ids uuid[]; r record;
begin
  if coalesce(p_scan_code,'') <> '' then
    select * into r from public.bil_scan_lien_resoudre(p_scan_code);
    if (r.lien).id is null then raise exception 'Lien de scan invalide, révoqué ou expiré.' using errcode = 'P0001'; end if;
    ids := r.ids;
  else
    if auth.uid() is null then raise exception 'Connexion requise.' using errcode = 'P0001'; end if;
    select array_agg(x) into ids from unnest(coalesce(p_evenements,'{}')) x where public.bil_peut_evenement(x);
  end if;
  return query select i.id, i.evenement_id, i.code, i.nom, i.prenom, i.entre_le, i.entre_appareil
    from public.bil_inscriptions i where i.evenement_id = any(coalesce(ids,'{}')) and i.statut = 'inscrit';
end $f$;

-- ---------------- Retrait de l'ancien code de scan ----------------
drop function if exists public.bil_scan_code_generer(uuid);
drop function if exists public.bil_scan_code_retirer(uuid);
drop function if exists public.bil_scan_evt_par_code(text);

create or replace function public.bil_srv_purge_donnees(p_eid uuid)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $f$
declare s jsonb; f jsonb;
begin
  s := public.bil_stats_calc(p_eid);
  select coalesce(jsonb_agg(x), '[]'::jsonb) into f from (
    select jsonb_array_elements(i.fichiers)->>'path' as x from public.bil_inscriptions i where i.evenement_id = p_eid
    union all select i.preuve_path from public.bil_inscriptions i where i.evenement_id = p_eid and i.preuve_path is not null) q where x is not null;
  update public.bil_sondages set inscription_id = null, commentaire = null where evenement_id = p_eid;
  delete from public.bil_scans where evenement_id = p_eid;
  delete from public.bil_inscriptions where evenement_id = p_eid;
  update public.bil_evenements set stats = s, donnees_purgees_le = now(), statut = 'archive' where id = p_eid;
  return jsonb_build_object('stats', s, 'fichiers', f);
end $f$;

create or replace function public.bil_verifier(p_eid uuid)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $f$
declare e public.bil_evenements; c public.bil_commissions;
begin
  select * into e from public.bil_evenements where id = p_eid;
  select * into c from public.bil_commissions where id = e.commission_id;
  return jsonb_build_object(
    'droits', public.bil_peut_evenement(p_eid),
    'heure_serveur', now(),
    'scanner', (select count(*) from public.bil_inscriptions where evenement_id = p_eid and statut = 'inscrit'),
    'ouvert', public.bil_raison_fermeture(p_eid),
    'date', e.date_evt, 'lieu', e.lieu, 'heure', e.heure_debut,
    'formulaire_ok', true,
    'payant_ok', (not e.payant) or coalesce(e.prix,0) > 0,
    'commission_ouverte', c.inscriptions_ouvertes);
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
  -- Champs que seul le serveur peut écrire.
  if tg_op = 'UPDATE' and current_user = 'authenticated' then
    new.code := old.code; new.commission_id := old.commission_id;
    new.alerte_90 := old.alerte_90; new.alerte_complet := old.alerte_complet;
    new.recettes_envoyees_le := old.recettes_envoyees_le; new.recettes_montant := old.recettes_montant;
    new.recettes_income_id := old.recettes_income_id; new.bilan_envoye_le := old.bilan_envoye_le;
    new.fichiers_purges_le := old.fichiers_purges_le; new.donnees_purgees_le := old.donnees_purgees_le;
    new.stats := old.stats; new.cree_par := old.cree_par; new.created_at := old.created_at;
  end if;
  if tg_op = 'INSERT' and current_user = 'authenticated' then
    new.recettes_envoyees_le := null; new.stats := null; new.cree_par := auth.uid();
  end if;
  new.updated_at := now();
  return new;
end $f$;

alter table public.bil_evenements drop column if exists scan_code;
