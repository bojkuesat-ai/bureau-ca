-- =====================================================================
-- Signatures (13/11/2026) — code de vérification infalsifiable (CA + Caisse).
-- Appliqué sur le projet (migration « signatures_code_verification »).
--
-- Principe : chaque signature par mot de passe (procuration, PV, demande
-- Caisse, signature conjointe) laisse une ligne dans
-- public.signatures_registre, avec un code HMAC-SHA256 calculé par le serveur
-- à partir d'un secret que seul le serveur connaît. Sans ce secret, on ne peut
-- ni fabriquer un code valide, ni le recalculer. Le registre est en insertion
-- seule (ni modification ni suppression, même par les fonctions).
-- Vérification : public.signature_verifier(app, code), par un membre connecté.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Secret serveur (jamais lisible via l'API)
-- ---------------------------------------------------------------------
create table if not exists public.signatures_secret (
  id int primary key default 1 check (id = 1),
  secret text not null,
  cree_le timestamptz not null default now()
);
alter table public.signatures_secret enable row level security;
revoke all on public.signatures_secret from anon, authenticated, public;
insert into public.signatures_secret (id, secret)
  select 1, encode(extensions.gen_random_bytes(32), 'hex')
  where not exists (select 1 from public.signatures_secret where id = 1);

-- ---------------------------------------------------------------------
-- 2. Registre des signatures (insertion seule)
-- ---------------------------------------------------------------------
create table if not exists public.signatures_registre (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  app text not null check (app in ('ca', 'caisse')),
  type text not null,
  objet_id text not null,
  libelle text,
  signataire_id uuid not null,
  signataire_nom text,
  signataire_email text,
  empreinte text,
  details jsonb not null default '{}'::jsonb,
  signe_le timestamptz not null default now()
);
create index if not exists signatures_registre_objet on public.signatures_registre (app, type, objet_id);
alter table public.signatures_registre enable row level security;
revoke all on public.signatures_registre from anon, authenticated, public;

create or replace function public.signatures_registre_fige()
returns trigger language plpgsql as $$
begin
  raise exception 'Le registre des signatures ne peut être ni modifié ni effacé.';
end $$;
drop trigger if exists signatures_registre_fige on public.signatures_registre;
create trigger signatures_registre_fige
  before update or delete on public.signatures_registre
  for each row execute function public.signatures_registre_fige();

-- ---------------------------------------------------------------------
-- 3. Calcul du code (HMAC) — interne, non exposé aux clients
-- ---------------------------------------------------------------------
create or replace function public.signature_coder(
  p_app text, p_type text, p_objet_id text, p_signataire uuid, p_signe_le timestamptz, p_empreinte text)
returns text language plpgsql stable security definer set search_path = public as $$
declare v_secret text; v_hex text;
begin
  select secret into v_secret from signatures_secret where id = 1;
  if v_secret is null then raise exception 'Secret de signature absent.'; end if;
  v_hex := upper(encode(extensions.hmac(
    convert_to(p_app || '|' || p_type || '|' || p_objet_id || '|' || p_signataire::text || '|'
      || to_char(p_signe_le at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US') || '|' || coalesce(p_empreinte, ''), 'UTF8'),
    convert_to(v_secret, 'UTF8'), 'sha256'), 'hex'));
  return substr(v_hex, 1, 4) || '-' || substr(v_hex, 5, 4) || '-' || substr(v_hex, 9, 4) || '-' || substr(v_hex, 13, 4);
end $$;
revoke all on function public.signature_coder(text, text, text, uuid, timestamptz, text) from anon, authenticated, public;

-- Enregistre une signature pour l'utilisateur connecté et renvoie son code.
-- Appelée uniquement par les fonctions de signature (pas par les clients).
create or replace function public.signature_interne(
  p_app text, p_type text, p_objet_id text, p_libelle text, p_empreinte text, p_details jsonb default '{}'::jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare v_now timestamptz := clock_timestamp(); v_code text; v_nom text; v_email text;
begin
  if auth.uid() is null then raise exception 'Connexion requise.'; end if;
  if p_app = 'ca' then
    select nullif(trim(coalesce(prenom,'') || ' ' || coalesce(nom,'')), ''), email into v_nom, v_email from ca_membres where id = auth.uid();
  else
    select name, email into v_nom, v_email from profiles where id = auth.uid();
  end if;
  if v_email is null then select email into v_email from auth.users where id = auth.uid(); end if;
  v_code := signature_coder(p_app, p_type, p_objet_id, auth.uid(), v_now, p_empreinte);
  insert into signatures_registre (code, app, type, objet_id, libelle, signataire_id, signataire_nom, signataire_email, empreinte, details, signe_le)
  values (v_code, p_app, p_type, p_objet_id, p_libelle, auth.uid(), coalesce(v_nom, v_email), v_email, p_empreinte, coalesce(p_details, '{}'::jsonb), v_now);
  return v_code;
end $$;
revoke all on function public.signature_interne(text, text, text, text, text, jsonb) from anon, authenticated, public;

-- Empreinte SHA-256 d'un contenu canonique (texte).
create or replace function public.signature_empreinte(p_contenu text)
returns text language sql immutable as $$
  select encode(extensions.digest(convert_to(coalesce(p_contenu, ''), 'UTF8'), 'sha256'), 'hex');
$$;
revoke all on function public.signature_empreinte(text) from anon, authenticated, public;

-- ---------------------------------------------------------------------
-- 4. Vérification d'un code (membre connecté du CA ou de la Caisse)
-- ---------------------------------------------------------------------
create or replace function public.signature_verifier(p_app text, p_code text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_code text; r signatures_registre; v_attendu text;
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
  -- La Caisse ne voit que ses propres signatures ; le CA voit tout.
  if p_app = 'caisse' and r.app <> 'caisse' then return jsonb_build_object('valide', false, 'motif', 'inconnu'); end if;
  -- Contrôle d'intégrité : le code doit toujours correspondre au contenu enregistré.
  v_attendu := signature_coder(r.app, r.type, r.objet_id, r.signataire_id, r.signe_le, r.empreinte);
  if v_attendu <> r.code then return jsonb_build_object('valide', false, 'motif', 'altere'); end if;
  return jsonb_build_object('valide', true, 'code', r.code, 'app', r.app, 'type', r.type, 'libelle', r.libelle,
    'signataire', r.signataire_nom, 'signe_le', r.signe_le, 'empreinte', r.empreinte, 'details', r.details);
end $$;
grant execute on function public.signature_verifier(text, text) to authenticated;
revoke all on function public.signature_verifier(text, text) from anon;

-- ---------------------------------------------------------------------
-- 5. Procurations (CA) : signature et annulation côté serveur
-- ---------------------------------------------------------------------
alter table public.ca_procurations add column if not exists code text;
alter table public.ca_procurations add column if not exists code_annulation text;

create or replace function public.procuration_signer(
  p_mandataire uuid, p_date_reunion date, p_portee text, p_points jsonb, p_clause boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me ca_membres; m ca_membres; v_id uuid; v_now timestamptz := now(); v_emp text; v_code text; v_points jsonb; v_email text;
begin
  if auth.uid() is null then raise exception 'Connexion requise.'; end if;
  if not mfa_ok() then raise exception 'Double authentification requise.'; end if;
  perform pvs_mdp_frais();
  select * into me from ca_membres where id = auth.uid() and statut = 'actif';
  if not found then raise exception 'Réservé aux membres actifs du CA.'; end if;
  select * into m from ca_membres where id = p_mandataire and statut = 'actif';
  if not found then raise exception 'Mandataire introuvable ou inactif.'; end if;
  if m.id = me.id then raise exception 'Vous ne pouvez pas vous donner procuration à vous-même.'; end if;
  if p_date_reunion is null then raise exception 'Indiquez la date de la réunion.'; end if;
  if p_date_reunion < current_date then raise exception 'La date de la réunion est déjà passée.'; end if;
  if p_portee not in ('tous', 'points') then raise exception 'Portée inconnue.'; end if;
  v_points := case when p_portee = 'points' then coalesce(p_points, '[]'::jsonb) else '[]'::jsonb end;
  if p_portee = 'points' and jsonb_array_length(v_points) = 0 then raise exception 'Indiquez au moins un point de l''ordre du jour.'; end if;
  if exists (select 1 from ca_procurations where mandant_id = me.id and statut = 'active' and date_reunion = p_date_reunion) then
    raise exception 'Vous avez déjà une procuration active pour cette réunion. Annulez-la d''abord.'; end if;
  v_email := coalesce(me.email, (select email from auth.users where id = me.id), '');
  v_id := gen_random_uuid();
  v_emp := signature_empreinte(jsonb_build_object('id', v_id, 'mandant', me.id, 'mandataire', m.id, 'date_reunion', p_date_reunion,
    'portee', p_portee, 'points', v_points, 'clause', coalesce(p_clause, false), 'signe_le', v_now)::text);
  insert into ca_procurations (id, mandant_id, mandant_nom, mandant_fonction, mandant_email, mandataire_id, mandataire_nom, mandataire_email,
    date_reunion, portee, points, clause_delib, signature, signe_le, empreinte, statut)
  values (v_id, me.id, trim(coalesce(me.prenom,'') || ' ' || coalesce(me.nom,'')), coalesce(me.fonction, ''), v_email,
    m.id, trim(coalesce(m.prenom,'') || ' ' || coalesce(m.nom,'')), coalesce(m.email, ''),
    p_date_reunion, p_portee, v_points, coalesce(p_clause, false), 'Mot de passe du compte, vérifié par le serveur', v_now, v_emp, 'active');
  v_code := signature_interne('ca', 'procuration', v_id::text,
    'Procuration — réunion du ' || to_char(p_date_reunion, 'DD/MM/YYYY'), v_emp,
    jsonb_build_object('mandataire', trim(coalesce(m.prenom,'') || ' ' || coalesce(m.nom,'')), 'date_reunion', p_date_reunion,
      'portee', p_portee, 'points', v_points, 'clause', coalesce(p_clause, false)));
  update ca_procurations set code = v_code where id = v_id;
  return (select to_jsonb(p) from ca_procurations p where p.id = v_id);
end $$;
grant execute on function public.procuration_signer(uuid, date, text, jsonb, boolean) to authenticated;

create or replace function public.procuration_annuler(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p ca_procurations; v_now timestamptz := now(); v_code text;
begin
  if auth.uid() is null then raise exception 'Connexion requise.'; end if;
  if not mfa_ok() then raise exception 'Double authentification requise.'; end if;
  select * into p from ca_procurations where id = p_id for update;
  if not found then raise exception 'Procuration introuvable.'; end if;
  if p.mandant_id <> auth.uid() then raise exception 'Seul le mandant peut annuler sa procuration.'; end if;
  if p.statut <> 'active' then raise exception 'Procuration déjà annulée.'; end if;
  if p.date_reunion < current_date then raise exception 'La réunion est passée : la procuration ne peut plus être annulée.'; end if;
  v_code := signature_interne('ca', 'procuration_annulation', p.id::text,
    'Annulation de la procuration — réunion du ' || to_char(p.date_reunion, 'DD/MM/YYYY'), p.empreinte,
    jsonb_build_object('mandataire', p.mandataire_nom, 'date_reunion', p.date_reunion, 'code_procuration', p.code));
  update ca_procurations set statut = 'annulee', annulee_le = v_now, code_annulation = v_code where id = p_id;
  return (select to_jsonb(x) from ca_procurations x where x.id = p_id);
end $$;
grant execute on function public.procuration_annuler(uuid) to authenticated;

-- Dépôt du PDF : seul champ encore modifiable par le mandant.
create or replace function public.procuration_pdf(p_id uuid, p_path text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Connexion requise.'; end if;
  update ca_procurations set pdf_path = p_path where id = p_id and mandant_id = auth.uid();
  if not found then raise exception 'Procuration introuvable.'; end if;
end $$;
grant execute on function public.procuration_pdf(uuid, text) to authenticated;

-- Plus d'insertion ni de modification directes depuis le navigateur.
drop policy if exists proc_insert on public.ca_procurations;
drop policy if exists proc_update on public.ca_procurations;

-- ---------------------------------------------------------------------
-- 6. PV à signer (CA) : codes serveur pour les deux signatures
-- ---------------------------------------------------------------------
alter table public.ca_pv_signatures add column if not exists code_secr text;
alter table public.ca_pv_signatures add column if not exists code_sign text;

create or replace function public.pvs_envoyer(p_id uuid, p_titre text, p_reunion text, p_date_reunion date, p_fichier jsonb, p_signataire uuid, p_date_mode text, p_date_manuelle date)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_fn text; a ca_pv_signatures; v_code text; v_emp text;
begin
  if not pvs_est_secretaire() then raise exception 'Réservé au secrétariat.'; end if;
  perform pvs_mdp_frais();
  if coalesce(trim(p_titre), '') = '' then raise exception 'Titre obligatoire.'; end if;
  if coalesce(p_reunion, '') = '' and p_date_reunion is null then raise exception 'Choisissez la réunion ou indiquez sa date.'; end if;
  if p_fichier is null or coalesce(p_fichier->>'path', '') = '' then raise exception 'Le PV (PDF) est obligatoire.'; end if;
  if p_date_mode not in ('electronique','manuelle') then raise exception 'Choix de date inconnu.'; end if;
  if p_date_mode = 'manuelle' and p_date_manuelle is null then raise exception 'Indiquez la date de signature.'; end if;
  v_fn := pvs_fonction(p_signataire);
  if v_fn is null then raise exception 'Le signataire doit être la présidente ou le vice-président.'; end if;
  if p_signataire = auth.uid() then raise exception 'Les deux signataires doivent être différents.'; end if;

  if p_id is null then
    insert into ca_pv_signatures(titre, reunion_id, date_reunion, fichier, secretaire_id, secretaire_nom, sig_secr_at,
      signataire_id, signataire_nom, signataire_fonction, date_mode, date_manuelle, envoye_le)
    values (trim(p_titre), nullif(p_reunion, ''), p_date_reunion, p_fichier, auth.uid(), pvs_nom(auth.uid()), now(),
      p_signataire, pvs_nom(p_signataire), v_fn, p_date_mode, case when p_date_mode = 'manuelle' then p_date_manuelle end, now())
    returning id into v_id;
  else
    select * into a from ca_pv_signatures where id = p_id for update;
    if not found then raise exception 'PV introuvable.'; end if;
    if a.statut <> 'refuse' then raise exception 'Seul un PV refusé peut être corrigé et renvoyé.'; end if;
    update ca_pv_signatures set titre = trim(p_titre), reunion_id = nullif(p_reunion, ''), date_reunion = p_date_reunion,
      fichier = p_fichier, version = a.version + 1, secretaire_id = auth.uid(), secretaire_nom = pvs_nom(auth.uid()),
      sig_secr_at = now(), signataire_id = p_signataire, signataire_nom = pvs_nom(p_signataire), signataire_fonction = v_fn,
      sig_sign_at = null, date_mode = p_date_mode, date_manuelle = case when p_date_mode = 'manuelle' then p_date_manuelle end,
      statut = 'attente', motif = null, refus_at = null, envoye_le = now(), rappel_le = null, code_sign = null
    where id = p_id;
    v_id := p_id;
  end if;
  select * into a from ca_pv_signatures where id = v_id;
  v_emp := signature_empreinte(jsonb_build_object('id', a.id, 'version', a.version, 'titre', a.titre, 'fichier', a.fichier->>'hash',
    'date_mode', a.date_mode, 'date_manuelle', a.date_manuelle, 'signataire', a.signataire_id)::text);
  v_code := signature_interne('ca', 'pv_secretaire', a.id::text, 'PV « ' || a.titre || ' » — signature de la secrétaire', v_emp,
    jsonb_build_object('titre', a.titre, 'version', a.version, 'date_reunion', a.date_reunion, 'fichier_hash', a.fichier->>'hash'));
  update ca_pv_signatures set code_secr = v_code where id = v_id;
  return v_id;
end $$;

create or replace function public.pvs_signer(p_id uuid, p_decision text, p_motif text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a ca_pv_signatures; v_code text; v_emp text;
begin
  perform pvs_mdp_frais();
  select * into a from ca_pv_signatures where id = p_id for update;
  if not found then raise exception 'PV introuvable.'; end if;
  if a.signataire_id <> auth.uid() then raise exception 'Ce PV doit être signé par quelqu''un d''autre.'; end if;
  if pvs_fonction(auth.uid()) is distinct from a.signataire_fonction then raise exception 'Votre fonction ne permet plus de signer ce PV.'; end if;
  if a.statut <> 'attente' then raise exception 'PV déjà traité.'; end if;
  if p_decision = 'signer' then
    v_emp := signature_empreinte(jsonb_build_object('id', a.id, 'version', a.version, 'titre', a.titre, 'fichier', a.fichier->>'hash',
      'date_mode', a.date_mode, 'date_manuelle', a.date_manuelle, 'code_secr', a.code_secr)::text);
    v_code := signature_interne('ca', 'pv_' || a.signataire_fonction, a.id::text,
      'PV « ' || a.titre || ' » — signature ' || case when a.signataire_fonction = 'vice' then 'du vice-président' else 'de la présidente' end, v_emp,
      jsonb_build_object('titre', a.titre, 'version', a.version, 'date_reunion', a.date_reunion, 'fichier_hash', a.fichier->>'hash', 'code_secretaire', a.code_secr));
    update ca_pv_signatures set statut = 'valide', sig_sign_at = now(), code_sign = v_code where id = p_id;
  elsif p_decision = 'refuser' then
    if coalesce(trim(p_motif), '') = '' then raise exception 'Motif du refus obligatoire.'; end if;
    update ca_pv_signatures set statut = 'refuse', motif = trim(p_motif), refus_at = now() where id = p_id;
  else
    raise exception 'Décision inconnue.';
  end if;
  return (select jsonb_build_object('statut', statut, 'code_sign', code_sign) from ca_pv_signatures where id = p_id);
end $$;

-- ---------------------------------------------------------------------
-- 7. Signature conjointe (Caisse, article 10.2) : codes serveur
-- ---------------------------------------------------------------------
alter table public.sc_actes add column if not exists code_vp text;
alter table public.sc_actes add column if not exists code_treso text;

create or replace function public.sc_creer(p_intitule text, p_description text, p_montant numeric, p_date date, p_facture jsonb, p_preuve jsonb, p_date_sig date)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_code text; v_emp text; a sc_actes;
begin
  if not sc_est_vp() then raise exception 'Réservé au vice-président activé.'; end if;
  perform sc_mdp_frais();
  if coalesce(trim(p_intitule), '') = '' then raise exception 'Intitulé obligatoire.'; end if;
  if p_facture is null or coalesce(p_facture->>'path', '') = '' then raise exception 'La facture est obligatoire.'; end if;
  if p_preuve  is null or coalesce(p_preuve->>'path', '')  = '' then raise exception 'La preuve de paiement est obligatoire.'; end if;
  if p_date_sig is null then raise exception 'Indiquez la date de signature.'; end if;
  if p_date_sig > current_date then raise exception 'La date de signature ne peut pas être dans le futur.'; end if;
  insert into sc_actes(intitule, description, montant, date_decision, facture, preuve, vp_id, vp_nom, sig_vp_at, date_sig_vp)
  values (trim(p_intitule), coalesce(p_description, ''), p_montant, coalesce(p_date, current_date),
          p_facture, p_preuve, auth.uid(), (select name from profiles where id = auth.uid()), now(), p_date_sig)
  returning id into v_id;
  select * into a from sc_actes where id = v_id;
  v_emp := signature_empreinte(jsonb_build_object('id', a.id, 'intitule', a.intitule, 'montant', a.montant, 'date_decision', a.date_decision,
    'facture', a.facture->>'hash', 'preuve', a.preuve->>'hash', 'date_sig', a.date_sig_vp)::text);
  v_code := signature_interne('caisse', 'acte_vp', a.id::text, 'Acte à signature conjointe n° ' || coalesce(a.numero::text, '?') || ' — ' || a.intitule || ' — vice-président', v_emp,
    jsonb_build_object('numero', a.numero, 'intitule', a.intitule, 'montant', a.montant, 'date_decision', a.date_decision, 'date_signature', a.date_sig_vp));
  update sc_actes set code_vp = v_code where id = v_id;
  return v_id;
end $$;

create or replace function public.sc_signer(p_acte uuid, p_decision text, p_motif text default null, p_date_sig date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a sc_actes; v_code text; v_emp text;
begin
  if not sc_est_treso() then raise exception 'Réservé au trésorier.'; end if;
  perform sc_mdp_frais();
  select * into a from sc_actes where id = p_acte for update;
  if not found then raise exception 'Acte introuvable.'; end if;
  if a.statut <> 'attente' then raise exception 'Acte déjà traité.'; end if;
  if a.vp_id = auth.uid() then raise exception 'Les deux signataires doivent être différents.'; end if;
  if a.facture is null or a.preuve is null then raise exception 'Facture et preuve de paiement requises.'; end if;
  if p_decision = 'signer' then
    if p_date_sig is null then raise exception 'Indiquez la date de signature.'; end if;
    if p_date_sig > current_date then raise exception 'La date de signature ne peut pas être dans le futur.'; end if;
    v_emp := signature_empreinte(jsonb_build_object('id', a.id, 'intitule', a.intitule, 'montant', a.montant, 'date_decision', a.date_decision,
      'facture', a.facture->>'hash', 'preuve', a.preuve->>'hash', 'date_sig', p_date_sig, 'code_vp', a.code_vp)::text);
    v_code := signature_interne('caisse', 'acte_treso', a.id::text, 'Acte à signature conjointe n° ' || coalesce(a.numero::text, '?') || ' — ' || a.intitule || ' — trésorier', v_emp,
      jsonb_build_object('numero', a.numero, 'intitule', a.intitule, 'montant', a.montant, 'date_decision', a.date_decision, 'date_signature', p_date_sig, 'code_vice_president', a.code_vp));
    update sc_actes set statut = 'valide', treso_id = auth.uid(),
      treso_nom = (select name from profiles where id = auth.uid()), sig_treso_at = now(), date_sig_treso = p_date_sig, code_treso = v_code
      where id = p_acte;
  elsif p_decision = 'refuser' then
    if coalesce(trim(p_motif), '') = '' then raise exception 'Motif du refus obligatoire.'; end if;
    update sc_actes set statut = 'refuse', treso_id = auth.uid(),
      treso_nom = (select name from profiles where id = auth.uid()), motif = trim(p_motif)
      where id = p_acte;
  else
    raise exception 'Décision inconnue.';
  end if;
  return (select jsonb_build_object('statut', statut, 'code_treso', code_treso) from sc_actes where id = p_acte);
end $$;

-- ---------------------------------------------------------------------
-- 8. Demandes Caisse signées (≥ 150 €, IBAN, doublon écarté)
-- ---------------------------------------------------------------------
alter table public.requests add column if not exists signature_code text;

create or replace function public.caisse_demande_signer(p_request uuid, p_type text, p_motifs jsonb default '[]'::jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare r requests; v_code text; v_emp text;
begin
  if auth.uid() is null then raise exception 'Connexion requise.'; end if;
  perform sc_mdp_frais();
  if p_type not in ('demande', 'doublon') then raise exception 'Type de signature inconnu.'; end if;
  select * into r from requests where id = p_request for update;
  if not found then raise exception 'Demande introuvable.'; end if;
  if r.user_id <> auth.uid() then raise exception 'Seul l''auteur de la demande peut la signer.'; end if;
  if r.signature_code is not null then raise exception 'Demande déjà signée.'; end if;
  if r.created_at < now() - interval '30 minutes' then raise exception 'Délai de signature dépassé : refaites la demande.'; end if;
  v_emp := signature_empreinte(jsonb_build_object('id', r.id, 'seq', r.seq, 'montant', r.amount, 'objet', r.object, 'date', r.expense_date,
    'kind', r.kind, 'iban', coalesce(r.beneficiary_iban, r.iban), 'beneficiaire', r.beneficiary, 'user', r.user_id)::text);
  v_code := signature_interne('caisse', case when p_type = 'doublon' then 'demande_doublon' else 'demande' end, r.id::text,
    case when p_type = 'doublon' then 'Demande n° ' || coalesce(r.seq::text, '?') || ' — déclaration d''absence de doublon'
         else 'Demande n° ' || coalesce(r.seq::text, '?') || ' — demande signée' end, v_emp,
    jsonb_build_object('numero', r.seq, 'montant', r.amount, 'objet', r.object, 'date', r.expense_date, 'kind', r.kind,
      'beneficiaire', r.beneficiary, 'motifs', coalesce(p_motifs, '[]'::jsonb)));
  update requests set signature_code = v_code where id = p_request;
  return v_code;
end $$;
grant execute on function public.caisse_demande_signer(uuid, text, jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- 9. Gestion journalière (Caisse, article 20) : codes serveur via trigger.
--    gj_creer / gj_signer posent sig_treso_at / sig_pres_at ; le trigger
--    (BEFORE, même transaction, même auth.uid()) enregistre la signature.
-- ---------------------------------------------------------------------
alter table public.gj_actes add column if not exists code_treso text;
alter table public.gj_actes add column if not exists code_pres text;

create or replace function public.gj_actes_code_signature()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_emp text; v_ref text;
begin
  if auth.uid() is null then return new; end if;
  v_ref := 'GJ-' || coalesce(new.annee::text, '?') || '-' || lpad(coalesce(new.numero, 0)::text, 3, '0');
  if new.sig_treso_at is not null and new.code_treso is null and new.sig_treso_id = auth.uid()
     and (tg_op = 'INSERT' or old.sig_treso_at is null) then
    v_emp := signature_empreinte(jsonb_build_object('id', new.id, 'ref', v_ref, 'type', new.type, 'intitule', new.intitule,
      'montant', new.montant, 'date_decision', new.date_decision, 'reserve', new.reserve, 'role', 'tresorier')::text);
    new.code_treso := signature_interne('caisse', 'gj_tresorier', new.id::text,
      'Gestion journalière ' || v_ref || ' — ' || new.intitule || ' — trésorier', v_emp,
      jsonb_build_object('ref', v_ref, 'type', new.type, 'intitule', new.intitule, 'montant', new.montant,
        'date_decision', new.date_decision, 'reserve', new.reserve));
  end if;
  if new.sig_pres_at is not null and new.code_pres is null and new.sig_pres_id = auth.uid()
     and (tg_op = 'INSERT' or old.sig_pres_at is null) then
    v_emp := signature_empreinte(jsonb_build_object('id', new.id, 'ref', v_ref, 'type', new.type, 'intitule', new.intitule,
      'montant', new.montant, 'date_decision', new.date_decision, 'role', 'presidente')::text);
    new.code_pres := signature_interne('caisse', 'gj_presidente', new.id::text,
      'Gestion journalière ' || v_ref || ' — ' || new.intitule || ' — présidente', v_emp,
      jsonb_build_object('ref', v_ref, 'type', new.type, 'intitule', new.intitule, 'montant', new.montant,
        'date_decision', new.date_decision));
  end if;
  return new;
end $$;
drop trigger if exists gj_actes_code_signature on public.gj_actes;
create trigger gj_actes_code_signature
  before insert or update of sig_treso_at, sig_pres_at on public.gj_actes
  for each row execute function public.gj_actes_code_signature();

-- ---------------------------------------------------------------------
-- 10. Durcissement (conseils de sécurité Supabase)
-- ---------------------------------------------------------------------
revoke all on function public.gj_actes_code_signature() from anon, authenticated, public;
revoke all on function public.signatures_registre_fige() from anon, authenticated, public;
revoke execute on function public.procuration_signer(uuid, date, text, jsonb, boolean) from anon, public;
revoke execute on function public.procuration_annuler(uuid) from anon, public;
revoke execute on function public.procuration_pdf(uuid, text) from anon, public;
revoke execute on function public.signature_verifier(text, text) from public;
revoke execute on function public.caisse_demande_signer(uuid, text, jsonb) from anon, public;
alter function public.signatures_registre_fige() set search_path = public;
alter function public.signature_empreinte(text) set search_path = public;
