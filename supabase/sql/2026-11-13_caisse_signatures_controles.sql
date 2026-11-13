-- =====================================================================
-- Caisse (13/11/2026) — contrôles sur les signatures et les décisions.
-- Appliqué sur le projet (migration « caisse_signatures_controles »).
--
-- 1. signature_verifier : pour une demande signée ou une décision du
--    trésorier, compare le contenu signé avec la demande telle qu'elle est
--    aujourd'hui. Si le montant, l'objet, la date, le bénéficiaire ou l'IBAN
--    ont changé après la signature, le résultat porte « modifie_apres » et
--    l'état actuel. Si la demande a été supprimée : « supprimee ».
--    La signature reste authentique (valide = true) : c'est le document
--    qui a changé, pas le code.
-- 2. Mot de passe pour les décisions du trésorier : un changement de statut
--    fait par le trésorier n'est accepté que si son mot de passe a été retapé
--    dans les 5 dernières minutes (caisse_mdp_ouvrir, appelée depuis une
--    session ouverte avec le mot de passe, contrôlée par sc_mdp_frais()).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Vérification : détection d'une modification après signature
-- ---------------------------------------------------------------------
create or replace function public.signature_verifier(p_app text, p_code text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_code text; r signatures_registre; v_attendu text; q requests; v_res jsonb;
        v_emp text; v_modif boolean := false; v_champs text[] := '{}'; d jsonb;
begin
  if auth.uid() is null then raise exception 'Connexion requise.'; end if;
  if p_app = 'ca' then
    if not exists (select 1 from ca_membres where id = auth.uid() and statut = 'actif') then
      raise exception 'Réservé aux membres du CA.'; end if;
  elsif p_app = 'caisse' then
    if not exists (select 1 from profiles where id = auth.uid() and coalesce(approved, false)) then
      raise exception 'Réservé aux membres approuvés de la Caisse.'; end if;
  else
    raise exception 'Application inconnue.';
  end if;
  v_code := upper(regexp_replace(coalesce(p_code, ''), '[^0-9A-Za-z]', '', 'g'));
  if length(v_code) <> 16 then return jsonb_build_object('valide', false, 'motif', 'format'); end if;
  v_code := substr(v_code, 1, 4) || '-' || substr(v_code, 5, 4) || '-' || substr(v_code, 9, 4) || '-' || substr(v_code, 13, 4);
  select * into r from signatures_registre where code = v_code;
  if not found then return jsonb_build_object('valide', false, 'motif', 'inconnu'); end if;
  if p_app = 'caisse' and r.app <> 'caisse' then return jsonb_build_object('valide', false, 'motif', 'inconnu'); end if;
  v_attendu := signature_coder(r.app, r.type, r.objet_id, r.signataire_id, r.signe_le, r.empreinte);
  if v_attendu <> r.code then return jsonb_build_object('valide', false, 'motif', 'altere'); end if;
  v_res := jsonb_build_object('valide', true, 'code', r.code, 'app', r.app, 'type', r.type, 'libelle', r.libelle,
    'signataire', r.signataire_nom, 'signe_le', r.signe_le, 'empreinte', r.empreinte, 'details', r.details);

  -- Demande Caisse : le document a-t-il changé depuis la signature ?
  if r.app = 'caisse' and (r.type in ('demande', 'demande_doublon') or r.type like 'decision\_%') then
    select * into q from requests where id::text = r.objet_id;
    if not found then
      return v_res || jsonb_build_object('supprimee', true);
    end if;
    d := r.details;
    if r.type in ('demande', 'demande_doublon') then
      -- même calcul que caisse_demande_signer : couvre aussi l'IBAN
      v_emp := signature_empreinte(jsonb_build_object('id', q.id, 'seq', q.seq, 'montant', q.amount, 'objet', q.object, 'date', q.expense_date,
        'kind', q.kind, 'iban', coalesce(q.beneficiary_iban, q.iban), 'beneficiaire', q.beneficiary, 'user', q.user_id)::text);
      if v_emp is distinct from r.empreinte then v_modif := true; end if;
    end if;
    if d ? 'montant' and (d->>'montant')::numeric is distinct from q.amount then v_champs := v_champs || 'montant'::text; end if;
    if d ? 'objet' and (d->>'objet') is distinct from q.object then v_champs := v_champs || 'objet'::text; end if;
    if d ? 'date' and (d->>'date') is distinct from q.expense_date::text then v_champs := v_champs || 'date'::text; end if;
    if d ? 'beneficiaire' and (d->>'beneficiaire') is distinct from q.beneficiary then v_champs := v_champs || 'beneficiaire'::text; end if;
    if v_modif and cardinality(v_champs) = 0 then v_champs := array['iban']; end if;
    if v_modif or cardinality(v_champs) > 0 then
      v_res := v_res || jsonb_build_object('modifie_apres', true, 'champs_modifies', to_jsonb(v_champs),
        'actuel', jsonb_build_object('montant', q.amount, 'objet', q.object, 'date', q.expense_date,
          'beneficiaire', q.beneficiary, 'statut', q.status));
    end if;
  end if;
  return v_res;
end $$;
grant execute on function public.signature_verifier(text, text) to authenticated;
revoke all on function public.signature_verifier(text, text) from anon;

-- ---------------------------------------------------------------------
-- 2. Mot de passe retapé pour les décisions du trésorier (5 minutes)
-- ---------------------------------------------------------------------
create table if not exists public.caisse_mdp_frais (
  user_id uuid primary key,
  valide_jusque timestamptz not null
);
alter table public.caisse_mdp_frais enable row level security;
revoke all on public.caisse_mdp_frais from anon, authenticated, public;

-- Appelée par la session ouverte avec le mot de passe (sbSignature côté app).
create or replace function public.caisse_mdp_ouvrir()
returns timestamptz language plpgsql security definer set search_path = public as $$
declare v timestamptz := now() + interval '5 minutes';
begin
  if auth.uid() is null then raise exception 'Connexion requise.'; end if;
  if not is_tresorier() then raise exception 'Réservé au trésorier.'; end if;
  perform sc_mdp_frais();   -- le mot de passe vient d'être tapé (moins de 2 minutes)
  insert into caisse_mdp_frais (user_id, valide_jusque) values (auth.uid(), v)
    on conflict (user_id) do update set valide_jusque = excluded.valide_jusque;
  return v;
end $$;
revoke all on function public.caisse_mdp_ouvrir() from anon, public;
grant execute on function public.caisse_mdp_ouvrir() to authenticated;

-- Le trigger des décisions exige désormais ce mot de passe frais.
create or replace function public.caisse_decision_code()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_type text; v_lib text; v_emp text; v_code text; v_now timestamptz := now(); v_ref text;
begin
  if tg_op = 'INSERT' then
    new.decision_code := null; new.decision_codes := '[]'::jsonb;
    return new;
  end if;
  new.decision_code := old.decision_code;
  new.decision_codes := coalesce(old.decision_codes, '[]'::jsonb);
  if new.status is not distinct from old.status then return new; end if;
  if auth.uid() is null or not is_tresorier() then return new; end if;
  if not exists (select 1 from caisse_mdp_frais where user_id = auth.uid() and valide_jusque > now()) then
    raise exception 'Retapez votre mot de passe pour confirmer cette décision.';
  end if;

  if new.status = 'Validée' and old.status = 'Remboursée' then v_type := 'decision_rejet'; v_lib := 'virement rejeté, remise en « Validée »';
  elsif new.status = 'Validée'    then v_type := 'decision_validee';  v_lib := 'demande validée';
  elsif new.status = 'Refusée'    then v_type := 'decision_refusee';  v_lib := 'demande refusée';
  elsif new.status = 'À corriger' then v_type := 'decision_corriger'; v_lib := 'renvoyée pour correction';
  elsif new.status = 'Remboursée' then v_type := 'decision_payee';    v_lib := 'paiement effectué';
  elsif new.status = 'En attente' then v_type := 'decision_rouverte'; v_lib := 'remise en attente';
  else return new;
  end if;

  v_ref := 'Demande n° ' || coalesce(new.seq::text, '?');
  v_emp := signature_empreinte(jsonb_build_object('id', new.id, 'seq', new.seq, 'montant', new.amount, 'objet', new.object,
    'date', new.expense_date, 'kind', new.kind, 'iban', coalesce(new.beneficiary_iban, new.iban), 'beneficiaire', new.beneficiary,
    'user', new.user_id, 'statut_avant', old.status, 'statut', new.status, 'note', new.decision_note, 'decide_le', v_now)::text);
  v_code := signature_interne('caisse', v_type, new.id::text, v_ref || ' — ' || v_lib || ' — trésorier', v_emp,
    jsonb_build_object('numero', new.seq, 'montant', new.amount, 'objet', new.object, 'date', new.expense_date, 'kind', new.kind,
      'beneficiaire', new.beneficiary, 'demandeur', new.requester_name, 'decision', v_lib,
      'statut_avant', old.status, 'statut', new.status));
  new.decision_code := v_code;
  new.decision_codes := new.decision_codes || jsonb_build_array(jsonb_build_object(
    'statut', new.status, 'type', v_type, 'code', v_code, 'le', v_now,
    'par', (select name from profiles where id = auth.uid())));
  return new;
end $$;
revoke all on function public.caisse_decision_code() from anon, authenticated, public;
