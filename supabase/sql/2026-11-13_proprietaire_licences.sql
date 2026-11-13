-- =====================================================================
-- Propriétaire, Admin délégué, état des apps, modules en option, licences
-- (13/11/2026). Appliqué sur le projet en trois migrations :
--   « proprio_1_roles », « proprio_2_etat_licences », « proprio_3_garde ».
--
-- NIVEAUX
--   Propriétaire : ca_membres.role = 'owner' (+ double authentification).
--     Seul à : attribuer les fonctions (Admin du CA, trésorier de la Caisse),
--     régler l'état des apps, les modules, le mode licence, approuver les
--     licences, les onglets, pages d'erreur, sauvegardes, journal, etc.
--     L'espace Propriétaire s'ouvre par un lien secret (hash dans
--     proprio_config.lien_hash) ; il exige en plus la connexion du propriétaire.
--     ca_membres.hors_ca : le propriétaire peut ne plus compter dans le CA
--     (quorum, effectif) tout en gardant tous ses droits.
--   Admin délégué : ca_membres.admin = true (attribué par le propriétaire,
--     ou automatiquement à la personne qui active une licence).
--     Gère : validation des comptes, coopté·es, bilans moraux, droits
--     secrétariat / médiation / salle, liste e-mail, fin de mandat.
--   Trésorier : profiles.role = 'tresorier' (attribué par le propriétaire).
--     Décide aussi des budgets dans le CA (avant : le propriétaire seul).
--
-- ÉTAT DES APPS ET LICENCE (contrôlé par le serveur)
--   proprio_config.etat = {"ca": "ouverte"|"lecture"|"fermee", "caisse": …}
--   proprio_config.mode_licence : si vrai, sans licence active => lecture seule
--     partout et modules en option coupés.
--   Écritures : trigger « a0_app_garde » (par instruction) sur chaque table
--     listée dans app_tables ; refusées en lecture seule / fermée / sans
--     licence / module coupé. Toujours permises : propriétaire, tâches
--     planifiées (pas d'utilisateur), service_role.
--   Lecture : politique restrictive « app_fermee » : app fermée => plus rien
--     n'est lisible (sauf propriétaire).
--   Tables jamais bloquées : comptes (ca_membres), journaux, mails, licences…
--
-- LICENCE
--   licence_demander (Admin, ou tout membre s'il n'y a pas d'Admin) → mail au
--   propriétaire → proprio_licence_approuver (après paiement) → lien
--   d'activation par mail au demandeur → licence_activer (le demandeur devient
--   Admin) → active jusqu'à « fin » → rappels J-30 / J-7 → lecture seule.
-- =====================================================================
-- Le texte complet des trois migrations suit.

-- ============================ 1. RÔLES ================================
alter table public.ca_membres add column if not exists admin boolean not null default false;
alter table public.ca_membres add column if not exists hors_ca boolean not null default false;

create or replace function public.ca_est_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select public.ca_is_owner()
      or (coalesce((select admin and statut = 'actif' and coalesce(role, '') <> 'coopte'
                      from public.ca_membres where id = auth.uid()), false)
          and public.mfa_ok());
$$;
grant execute on function public.ca_est_admin() to authenticated;

create or replace function public.ca_est_tresorier()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'tresorier' and coalesce(approved, false))
     and public.mfa_ok();
$$;
grant execute on function public.ca_est_tresorier() to authenticated;

-- Champs réservés au propriétaire sur les comptes du CA.
create or replace function public.ca_membres_garde_proprio()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or public.ca_is_owner() or current_setting('app.proprio_bypass', true) = '1' then
    return coalesce(new, old);
  end if;
  if tg_op = 'DELETE' then
    if old.role = 'owner' or old.admin then raise exception 'Seul le propriétaire peut supprimer ce compte.'; end if;
    return old;
  end if;
  if tg_op = 'UPDATE' then
    if old.role = 'owner' and to_jsonb(new) is distinct from to_jsonb(old) then
      raise exception 'Le compte du propriétaire ne peut être modifié que par lui.'; end if;
    if new.role = 'owner' and old.role is distinct from 'owner' then raise exception 'Fonction réservée au propriétaire.'; end if;
    if new.admin is distinct from old.admin then raise exception 'Seul le propriétaire attribue la fonction d''Admin.'; end if;
    if new.hors_ca is distinct from old.hors_ca then raise exception 'Réservé au propriétaire.'; end if;
  end if;
  if tg_op = 'INSERT' and (new.admin or new.hors_ca or new.role = 'owner') then
    raise exception 'Fonction réservée au propriétaire.'; end if;
  return new;
end $$;
drop trigger if exists a1_garde_proprio on public.ca_membres;
create trigger a1_garde_proprio before insert or update or delete on public.ca_membres
  for each row execute function public.ca_membres_garde_proprio();

-- Réglages du CA réservés au propriétaire.
create or replace function public.ca_meta_garde_proprio()
returns trigger language plpgsql security definer set search_path = public as $$
declare c text;
begin
  if auth.uid() is null or public.ca_is_owner() or current_setting('app.proprio_bypass', true) = '1' then return new; end if;
  foreach c in array array['nom','onglets_off','erreur_ca','erreur_caisse','erreur_billets','ces_actif','billets_maintenance','billets_deco_le'] loop
    if (to_jsonb(new) -> c) is distinct from (to_jsonb(old) -> c) then
      raise exception 'Ce réglage est réservé au propriétaire.';
    end if;
  end loop;
  return new;
end $$;
drop trigger if exists a1_garde_proprio on public.ca_meta;
create trigger a1_garde_proprio before update on public.ca_meta
  for each row execute function public.ca_meta_garde_proprio();

-- Politiques : l'Admin délégué gère les comptes, les réglages courants et la liste e-mail.
drop policy if exists ca_membres_update on public.ca_membres;
create policy ca_membres_update on public.ca_membres for update using (public.ca_est_admin()) with check (public.ca_est_admin());
drop policy if exists ca_membres_delete on public.ca_membres;
create policy ca_membres_delete on public.ca_membres for delete using (public.ca_est_admin() and id <> auth.uid());
drop policy if exists ca_meta_upd on public.ca_meta;
create policy ca_meta_upd on public.ca_meta for update using (public.ca_est_admin()) with check (public.ca_est_admin());
drop policy if exists ca_mailing_ins on public.ca_mailing;
create policy ca_mailing_ins on public.ca_mailing for insert with check (public.ca_est_admin());
drop policy if exists ca_mailing_del on public.ca_mailing;
create policy ca_mailing_del on public.ca_mailing for delete using (public.ca_est_admin());
drop policy if exists ca_desabo_del on public.ca_desabonnes;
create policy ca_desabo_del on public.ca_desabonnes for delete using (public.ca_est_admin());

-- Fonctions existantes : propriétaire → Admin (coopté·es, bilans, secrétariat,
-- alertes d'inscription) ; propriétaire → trésorier (budgets) ; effectif sans hors_ca.
do $$
declare r record; v text; n text;
begin
  for r in select * from (values
    ('ca__peut_gerer_cooptes', 'select (exists (select 1 from public.ca_membres where id = auth.uid() and statut = ''actif'' and role = ''owner'')',
                               'select (public.ca_est_admin() or exists (select 1 from public.ca_membres where id = auth.uid() and statut = ''actif'' and role = ''owner'')'),
    ('ca_bilans_cloturer',     'where id = auth.uid() and role = ''owner'' and statut = ''actif''',
                               'where id = auth.uid() and (role = ''owner'' or coalesce(admin, false)) and statut = ''actif'''),
    ('ca_secretariat_reglages','where id = auth.uid() and role = ''owner'' and statut = ''actif''',
                               'where id = auth.uid() and (role = ''owner'' or coalesce(admin, false)) and statut = ''actif'''),
    ('ca_reset_bilans',        'm.role = ''owner''',
                               '(m.role = ''owner'' or (coalesce(m.admin, false) and m.statut = ''actif''))'),
    ('ca_code_coopte',         'ca_is_owner()', 'ca_est_admin()'),
    ('ca_notif_inscription',   'where m.role = ''owner'' and m.statut = ''actif''',
                               'where (m.role = ''owner'' or coalesce(m.admin, false)) and m.statut = ''actif'''),
    ('ca_budget_confirmer',    'and role = ''owner'' and statut = ''actif''',
                               'and (role = ''owner'' or public.ca_est_tresorier()) and statut = ''actif'''),
    ('ca_budgets_garde_decision','and role = ''owner'' and statut = ''actif''',
                               'and (role = ''owner'' or public.ca_est_tresorier()) and statut = ''actif'''),
    ('ca_budget_supprimer',    'and role = ''owner'' and statut = ''actif''',
                               'and (role = ''owner'' or public.ca_est_tresorier()) and statut = ''actif'''),
    ('ca_budget_set_cout',     'if not ca_is_owner() then', 'if not (ca_is_owner() or ca_est_tresorier()) then'),
    ('ca_budget_regle162_ok',  'and coalesce(email, '''') <> ''''',
                               'and coalesce(email, '''') <> '''' and not coalesce(hors_ca, false)')
  ) as t(fn, ancien, nouveau) loop
    select pg_get_functiondef(p.oid) into v from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = r.fn;
    if v is null then raise exception 'Fonction % introuvable', r.fn; end if;
    if position(r.nouveau in v) > 0 then continue; end if;            -- déjà fait
    if position(r.ancien in v) = 0 then raise exception 'Motif introuvable dans % : %', r.fn, r.ancien; end if;
    n := replace(v, r.ancien, r.nouveau);
    execute n;
  end loop;
end $$;

-- ===================== 2. ÉTAT DES APPS, MODULES, LICENCES =====================
create table if not exists public.proprio_config (
  id int primary key default 1 check (id = 1),
  lien_hash text,
  mode_licence boolean not null default false,
  etat jsonb not null default '{"ca":"ouverte","caisse":"ouverte"}',
  messages jsonb not null default '{}',
  modules jsonb not null default '{"salle":true,"billetterie":true,"ces":true,"soutien":true,"mediation":true}',
  maj_le timestamptz not null default now()
);
insert into public.proprio_config (id) values (1) on conflict do nothing;
alter table public.proprio_config enable row level security;
revoke all on public.proprio_config from anon, authenticated, public;

create table if not exists public.licences (
  id uuid primary key default gen_random_uuid(),
  demande_le timestamptz not null default now(),
  demandeur_id uuid not null,
  demandeur_nom text,
  demandeur_email text,
  duree_mois int,
  options text[] not null default '{}',
  message text,
  statut text not null default 'demandee' check (statut in ('demandee','approuvee','active','refusee','annulee','remplacee')),
  fin date,
  approuvee_le timestamptz,
  activee_le timestamptz,
  refus_motif text,
  jeton_hash text,
  rappel_30 timestamptz,
  rappel_7 timestamptz,
  expire_avis timestamptz
);
alter table public.licences enable row level security;
revoke all on public.licences from anon, authenticated, public;

create or replace function public.modules_liste() returns text[] language sql immutable as $$
  select array['salle','billetterie','ces','soutien','mediation'] $$;

create or replace function public.licence_courante() returns public.licences
language sql stable security definer set search_path = public as $$
  select * from licences where statut = 'active' and fin >= (now() at time zone 'Europe/Brussels')::date
   order by fin desc limit 1 $$;

create or replace function public.module_actif(p_module text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((c.modules ->> p_module)::boolean, true)
     and (not c.mode_licence or exists (select 1 from licences l where l.statut = 'active'
            and l.fin >= (now() at time zone 'Europe/Brussels')::date and p_module = any(l.options)))
    from proprio_config c where c.id = 1 $$;
grant execute on function public.module_actif(text) to anon, authenticated;

-- Motif de refus d'une écriture ('' = autorisée).
create or replace function public.app_refus_motif(p_app text, p_module text) returns text
language plpgsql stable security definer set search_path = public as $$
declare c proprio_config; v text;
begin
  if auth.uid() is null and coalesce(auth.role(), '') <> 'anon' then return ''; end if;   -- tâches planifiées, service
  if auth.uid() is not null and public.ca_is_owner() then return ''; end if;
  select * into c from proprio_config where id = 1;
  if p_app is not null then
    v := coalesce(c.etat ->> p_app, 'ouverte');
    if v = 'fermee' then return 'L''application est fermée par le propriétaire.'; end if;
    if v = 'lecture' then return 'L''application est en lecture seule (décision du propriétaire).'; end if;
    if c.mode_licence and (select l.id from licence_courante() l) is null then
      return 'Licence absente ou expirée : l''application est en lecture seule. L''Admin peut demander une licence dans l''Espace CA.';
    end if;
  end if;
  if p_module is not null and not public.module_actif(p_module) then
    return 'Le module « ' || p_module || ' » n''est pas activé.';
  end if;
  return '';
end $$;

create or replace function public.app_lecture_ok(p_app text) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is null or public.ca_is_owner()
      or coalesce((select etat ->> p_app from proprio_config where id = 1), 'ouverte') <> 'fermee' $$;
grant execute on function public.app_lecture_ok(text) to authenticated;

create or replace function public.licence_peut_demander() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and public.mfa_ok()
     and exists (select 1 from ca_membres m where m.id = auth.uid() and m.statut in ('actif','attente')
                  and coalesce(m.role, '') <> 'coopte' and coalesce(m.via_code, '') = '')
     and (public.ca_est_admin()
          or not exists (select 1 from ca_membres a where a.admin and a.statut = 'actif' and coalesce(a.role, '') <> 'owner')) $$;

-- État vu par l'app (bandeaux, onglets, page licence).
create or replace function public.app_etat(p_app text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c proprio_config; l licences; d licences; v_etat text; v_raison text; v_mod jsonb := '{}'; m text;
        v_proprio boolean := auth.uid() is not null and public.ca_is_owner();
begin
  select * into c from proprio_config where id = 1;
  select * into l from licence_courante();
  v_etat := coalesce(c.etat ->> p_app, 'ouverte');
  if v_etat <> 'ouverte' then v_raison := 'proprio'; end if;
  if v_etat = 'ouverte' and c.mode_licence and l.id is null then v_etat := 'lecture'; v_raison := 'licence'; end if;
  foreach m in array modules_liste() loop v_mod := v_mod || jsonb_build_object(m, module_actif(m)); end loop;
  if auth.uid() is not null then
    select * into d from licences where statut in ('demandee','approuvee') order by demande_le desc limit 1;
  end if;
  return jsonb_build_object(
    'app', p_app, 'etat', v_etat, 'raison', v_raison,
    'pour_moi', case when v_proprio then 'ouverte' else v_etat end,
    'message', coalesce(c.messages ->> p_app, ''),
    'mode_licence', c.mode_licence,
    'licence', case when l.id is null then null else jsonb_build_object('fin', l.fin, 'options', to_jsonb(l.options), 'titulaire', l.demandeur_nom) end,
    'modules', v_mod,
    'proprio', v_proprio,
    'admin', auth.uid() is not null and public.ca_est_admin(),
    'tresorier', auth.uid() is not null and public.ca_est_tresorier(),
    'peut_demander', c.mode_licence and public.licence_peut_demander(),
    'demande', case when d.id is null then null else jsonb_build_object('statut', d.statut, 'le', d.demande_le, 'par', d.demandeur_nom,
                 'duree_mois', d.duree_mois, 'options', to_jsonb(d.options), 'fin', d.fin, 'moi', d.demandeur_id = auth.uid()) end);
end $$;
grant execute on function public.app_etat(text) to anon, authenticated;

-- Mails de la licence (expéditeur Licence-BE, envoi par le serveur).
create or replace function public.licence_mail(p_to text, p_sujet text, p_html text) returns void
language plpgsql security definer set search_path = public, net as $$
declare v_anon text := 'sb_publishable_xoVRiE99YOepw-sb5Tmtcg_SJ3VE_0s';
begin
  if coalesce(p_to, '') = '' then return; end if;
  perform net.http_post(
    url := 'https://mlgzdfyqjhvyubrywuim.supabase.co/functions/v1/send-email',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_anon, 'apikey', v_anon,
                 'x-cron-secret', (select cron_secret from public.bil_config where id = 1)),
    body := jsonb_build_object('to', p_to, 'subject', p_sujet, 'from', 'Licence-BE <noreply@bureauetuidant.xyz>',
      'html', '<div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:0 auto;color:#1a1a2e">' || p_html
        || '<p style="color:#999;font-size:12px">Message automatique — applications du Bureau étudiant.</p></div>'));
end $$;
revoke all on function public.licence_mail(text, text, text) from anon, authenticated, public;

create or replace function public.licence_mail_proprio(p_sujet text, p_html text) returns void
language plpgsql security definer set search_path = public as $$
declare o record;
begin
  for o in select u.email from ca_membres m join auth.users u on u.id = m.id where m.role = 'owner' and u.email is not null loop
    perform licence_mail(o.email, p_sujet, p_html);
  end loop;
end $$;
revoke all on function public.licence_mail_proprio(text, text) from anon, authenticated, public;

create or replace function public.licence_options_txt(p text[]) returns text language sql immutable as $$
  select coalesce(nullif(array_to_string(array(select case x when 'salle' then 'Salle fac' when 'billetterie' then 'Billetterie'
    when 'ces' then 'CES' when 'soutien' then 'Soutien psy' when 'mediation' then 'Médiation' else x end from unnest(p) x), ', '), ''), 'aucune') $$;

-- Demande de licence (Admin, ou tout membre tant qu'il n'y a pas d'Admin).
create or replace function public.licence_demander(p_duree_mois int, p_options text[], p_message text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_nom text; v_mail text; o text;
begin
  if not (select mode_licence from proprio_config where id = 1) then raise exception 'Les licences ne sont pas en service.'; end if;
  if not public.licence_peut_demander() then raise exception 'Seul l''Admin peut demander la licence.'; end if;
  if p_duree_mois is null or p_duree_mois not in (1, 3, 6, 12, 24) then raise exception 'Durée invalide.'; end if;
  foreach o in array coalesce(p_options, '{}') loop
    if not (o = any(modules_liste())) then raise exception 'Option inconnue : %', o; end if;
  end loop;
  if exists (select 1 from licences where statut in ('demandee','approuvee')) then
    raise exception 'Une demande de licence est déjà en cours.'; end if;
  select nullif(trim(coalesce(prenom, '') || ' ' || coalesce(nom, '')), '') into v_nom from ca_membres where id = auth.uid();
  select email into v_mail from auth.users where id = auth.uid();
  insert into licences (demandeur_id, demandeur_nom, demandeur_email, duree_mois, options, message)
  values (auth.uid(), coalesce(v_nom, v_mail), v_mail, p_duree_mois, coalesce(p_options, '{}'), left(nullif(trim(p_message), ''), 1000))
  returning id into v_id;
  perform licence_mail_proprio('📄 Nouvelle demande de licence — ' || coalesce(v_nom, v_mail),
    '<h2 style="margin:0 0 10px">📄 Nouvelle demande de licence</h2>'
    || '<p><b>' || ca_html(coalesce(v_nom, '')) || '</b> (' || ca_html(coalesce(v_mail, '')) || ') demande une licence.</p>'
    || '<p>Durée : <b>' || p_duree_mois || ' mois</b><br>Options : <b>' || ca_html(licence_options_txt(coalesce(p_options, '{}'))) || '</b></p>'
    || case when nullif(trim(p_message), '') is not null then '<p>Message : ' || ca_html(p_message) || '</p>' else '' end
    || '<p>Approuvez-la dans votre espace Propriétaire après paiement : le lien d''activation partira alors au demandeur.</p>');
  perform licence_mail(v_mail, 'Votre demande de licence est enregistrée',
    '<h2 style="margin:0 0 10px">Demande de licence enregistrée</h2><p>Votre demande (' || p_duree_mois || ' mois, options : '
    || ca_html(licence_options_txt(coalesce(p_options, '{}'))) || ') a été transmise au propriétaire des applications. '
    || 'Vous recevrez le lien d''activation par mail dès qu''elle sera approuvée.</p>');
  return v_id;
end $$;
revoke all on function public.licence_demander(int, text[], text) from anon, public;
grant execute on function public.licence_demander(int, text[], text) to authenticated;

-- Activation par le lien reçu (le demandeur devient Admin).
create or replace function public.licence_activer(p_jeton text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l licences;
begin
  if auth.uid() is null then raise exception 'Connectez-vous pour activer la licence.'; end if;
  select * into l from licences where jeton_hash = encode(sha256(convert_to(coalesce(p_jeton, ''), 'UTF8')), 'hex');
  if not found then raise exception 'Lien d''activation inconnu.'; end if;
  if l.statut = 'active' and l.demandeur_id = auth.uid() then
    return jsonb_build_object('ok', true, 'deja', true, 'fin', l.fin, 'options', to_jsonb(l.options)); end if;
  if l.statut <> 'approuvee' then raise exception 'Ce lien d''activation n''est plus valable.'; end if;
  if l.demandeur_id <> auth.uid() and not public.ca_is_owner() then
    raise exception 'Ce lien est réservé à % : connectez-vous avec son compte.', coalesce(l.demandeur_nom, 'la personne qui a demandé la licence'); end if;
  if l.fin < (now() at time zone 'Europe/Brussels')::date then raise exception 'Cette licence est déjà arrivée à échéance.'; end if;
  update licences set statut = 'remplacee' where statut = 'active' and id <> l.id;
  update licences set statut = 'active', activee_le = now(), rappel_30 = null, rappel_7 = null, expire_avis = null where id = l.id;
  perform set_config('app.proprio_bypass', '1', true);
  update ca_membres set admin = true, statut = 'actif' where id = l.demandeur_id and coalesce(role, '') not in ('owner','coopte');
  perform set_config('app.proprio_bypass', '', true);
  perform licence_mail_proprio('✅ Licence activée — ' || coalesce(l.demandeur_nom, ''),
    '<h2 style="margin:0 0 10px">✅ Licence activée</h2><p>' || ca_html(coalesce(l.demandeur_nom, '')) || ' a activé la licence jusqu''au <b>'
    || to_char(l.fin, 'DD/MM/YYYY') || '</b> (options : ' || ca_html(licence_options_txt(l.options)) || '). Cette personne est désormais Admin.</p>');
  return jsonb_build_object('ok', true, 'fin', l.fin, 'options', to_jsonb(l.options));
end $$;
revoke all on function public.licence_activer(text) from anon, public;
grant execute on function public.licence_activer(text) to authenticated;

-- ------------------------- Espace Propriétaire -------------------------
create or replace function public.proprio_exiger() returns void language plpgsql stable security definer set search_path = public as $$
begin if auth.uid() is null or not public.ca_is_owner() then raise exception 'Réservé au propriétaire.'; end if; end $$;

create or replace function public.proprio_ouvrir(p_code text) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and public.ca_is_owner()
     and coalesce((select lien_hash from proprio_config where id = 1), '') = encode(sha256(convert_to(coalesce(p_code, ''), 'UTF8')), 'hex') $$;
grant execute on function public.proprio_ouvrir(text) to authenticated;

create or replace function public.proprio_nouveau_lien() returns text
language plpgsql security definer set search_path = public as $$
declare v text;
begin
  perform proprio_exiger();
  v := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  update proprio_config set lien_hash = encode(sha256(convert_to(v, 'UTF8')), 'hex'), maj_le = now() where id = 1;
  return v;
end $$;
grant execute on function public.proprio_nouveau_lien() to authenticated;

create or replace function public.proprio_tableau() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c proprio_config;
begin
  perform proprio_exiger();
  select * into c from proprio_config where id = 1;
  return jsonb_build_object(
    'config', jsonb_build_object('mode_licence', c.mode_licence, 'etat', c.etat, 'messages', c.messages, 'modules', c.modules),
    'licence', (select to_jsonb(l) - 'jeton_hash' from licence_courante() l where l.id is not null),
    'licences', coalesce((select jsonb_agg(to_jsonb(l) - 'jeton_hash' order by l.demande_le desc) from (select * from licences order by demande_le desc limit 30) l), '[]'),
    'membres', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'nom', trim(coalesce(m.prenom, '') || ' ' || coalesce(m.nom, '')), 'fonction', m.fonction,
                 'email', m.email, 'statut', m.statut, 'role', m.role, 'admin', m.admin, 'hors_ca', m.hors_ca, 'coopte', coalesce(m.via_code, '') <> '')
                 order by m.role = 'owner' desc, m.prenom) from ca_membres m where m.statut <> 'revoque'), '[]'),
    'caisse', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'nom', p.name, 'email', p.email, 'role', p.role, 'approved', p.approved,
                 'gj_presidente', p.id = (select g.id from gj__presidente() g)) order by p.role = 'tresorier' desc, p.name)
                 from profiles p where coalesce(p.approved, false)), '[]'),
    'treso_email', (select treso_email from caisse_config limit 1));
end $$;
grant execute on function public.proprio_tableau() to authenticated;

create or replace function public.proprio_reglages(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare c proprio_config; k text; v jsonb;
begin
  perform proprio_exiger();
  select * into c from proprio_config where id = 1;
  if p ? 'mode_licence' then c.mode_licence := (p ->> 'mode_licence')::boolean; end if;
  if p ? 'etat' then
    for k, v in select * from jsonb_each(p -> 'etat') loop
      if k not in ('ca','caisse') or (v #>> '{}') not in ('ouverte','lecture','fermee') then raise exception 'État invalide.'; end if;
      c.etat := c.etat || jsonb_build_object(k, v #>> '{}');
    end loop;
  end if;
  if p ? 'messages' then
    for k, v in select * from jsonb_each(p -> 'messages') loop
      if k not in ('ca','caisse') then raise exception 'Message invalide.'; end if;
      c.messages := c.messages || jsonb_build_object(k, left(coalesce(v #>> '{}', ''), 500));
    end loop;
  end if;
  if p ? 'modules' then
    for k, v in select * from jsonb_each(p -> 'modules') loop
      if not (k = any(modules_liste())) or jsonb_typeof(v) <> 'boolean' then raise exception 'Module invalide.'; end if;
      c.modules := c.modules || jsonb_build_object(k, v);
    end loop;
  end if;
  update proprio_config set mode_licence = c.mode_licence, etat = c.etat, messages = c.messages, modules = c.modules, maj_le = now() where id = 1;
end $$;
grant execute on function public.proprio_reglages(jsonb) to authenticated;

create or replace function public.proprio_licence_approuver(p_id uuid, p_fin date, p_options text[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l licences; v_jeton text; o text;
begin
  perform proprio_exiger();
  select * into l from licences where id = p_id for update;
  if not found or l.statut not in ('demandee','approuvee') then raise exception 'Cette demande n''est plus en attente.'; end if;
  if p_fin is null or p_fin <= (now() at time zone 'Europe/Brussels')::date then raise exception 'Choisissez une date de fin dans le futur.'; end if;
  foreach o in array coalesce(p_options, '{}') loop
    if not (o = any(modules_liste())) then raise exception 'Option inconnue : %', o; end if;
  end loop;
  v_jeton := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  update licences set statut = 'approuvee', fin = p_fin, options = coalesce(p_options, '{}'), approuvee_le = now(),
         jeton_hash = encode(sha256(convert_to(v_jeton, 'UTF8')), 'hex') where id = p_id;
  perform licence_mail(l.demandeur_email, '🔑 Votre licence est prête — activez-la',
    '<h2 style="margin:0 0 10px">🔑 Votre licence est prête</h2>'
    || '<p>Bonjour ' || ca_html(split_part(coalesce(l.demandeur_nom, ''), ' ', 1)) || ',</p>'
    || '<p>Votre licence pour les applications du Bureau étudiant a été approuvée : valable jusqu''au <b>' || to_char(p_fin, 'DD/MM/YYYY')
    || '</b>, options : <b>' || ca_html(licence_options_txt(coalesce(p_options, '{}'))) || '</b>.</p>'
    || '<p>Cliquez sur le bouton ci-dessous, connecté·e avec <b>votre</b> compte : la licence s''active et vous devenez Admin.</p>'
    || '<p><a href="https://bojkuesat-ai.github.io/bureau-ca/#licence=' || v_jeton || '" style="background:#241c46;color:#fff;padding:12px 22px;border-radius:8px;text-decoration:none;display:inline-block">Activer la licence</a></p>'
    || '<p style="color:#888;font-size:12px">Ce lien est personnel : il ne fonctionne qu''avec votre compte.</p>');
  return jsonb_build_object('ok', true, 'envoye_a', l.demandeur_email);
end $$;
grant execute on function public.proprio_licence_approuver(uuid, date, text[]) to authenticated;

create or replace function public.proprio_licence_refuser(p_id uuid, p_motif text) returns void
language plpgsql security definer set search_path = public as $$
declare l licences;
begin
  perform proprio_exiger();
  select * into l from licences where id = p_id for update;
  if not found or l.statut not in ('demandee','approuvee') then raise exception 'Cette demande n''est plus en attente.'; end if;
  update licences set statut = 'refusee', refus_motif = left(nullif(trim(p_motif), ''), 500), jeton_hash = null where id = p_id;
  perform licence_mail(l.demandeur_email, 'Votre demande de licence',
    '<h2 style="margin:0 0 10px">Demande de licence non approuvée</h2><p>Votre demande de licence n''a pas été approuvée.</p>'
    || case when nullif(trim(p_motif), '') is not null then '<p>Motif : ' || ca_html(p_motif) || '</p>' else '' end);
end $$;
grant execute on function public.proprio_licence_refuser(uuid, text) to authenticated;

create or replace function public.proprio_licence_retirer(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform proprio_exiger();
  update licences set statut = 'annulee', jeton_hash = null where id = p_id and statut in ('active','approuvee','demandee');
  if not found then raise exception 'Licence introuvable.'; end if;
end $$;
grant execute on function public.proprio_licence_retirer(uuid) to authenticated;

create or replace function public.proprio_set_admin(p_membre uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform proprio_exiger();
  perform set_config('app.proprio_bypass', '1', true);
  update ca_membres set admin = coalesce(p_on, false)
   where id = p_membre and coalesce(role, '') not in ('owner','coopte') and (not p_on or statut = 'actif');
  if not found then raise exception 'Compte introuvable, coopté·e, ou pas encore validé.'; end if;
  perform set_config('app.proprio_bypass', '', true);
end $$;
grant execute on function public.proprio_set_admin(uuid, boolean) to authenticated;

create or replace function public.proprio_set_hors_ca(p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform proprio_exiger();
  update ca_membres set hors_ca = coalesce(p_on, false) where id = auth.uid();
end $$;
grant execute on function public.proprio_set_hors_ca(boolean) to authenticated;

-- Trésorier de la Caisse (le propriétaire seul).
create or replace function public.proprio_set_tresorier(p_user uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
declare v_mail text;
begin
  perform proprio_exiger();
  if not exists (select 1 from profiles where id = p_user and coalesce(approved, false)) then
    raise exception 'Cette personne n''a pas de compte validé dans la Caisse.'; end if;
  if not coalesce(p_on, false) and not exists (select 1 from profiles where role = 'tresorier' and coalesce(approved, false) and id <> p_user) then
    raise exception 'Il faut au moins un trésorier : nommez d''abord le nouveau.'; end if;
  insert into caisse_proprietaire (id) values (auth.uid()) on conflict do nothing;   -- autorise le changement de rôle (profiles_garde_role)
  update profiles set role = case when p_on then 'tresorier' else 'demandeur' end where id = p_user;
  select email into v_mail from profiles where role = 'tresorier' and coalesce(approved, false)
   order by (id = p_user and p_on) desc, created_at limit 1;
  update caisse_config set treso_email = v_mail;
end $$;
grant execute on function public.proprio_set_tresorier(uuid, boolean) to authenticated;

-- Billetterie publique : en maintenance si le module n'est pas actif.
create or replace function public.bil_maintenance() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select billets_maintenance from public.ca_meta where id = 1), false) or not public.module_actif('billetterie') $$;

-- Rappels d'échéance (chaque jour).
create or replace function public.licence_rappels() returns void
language plpgsql security definer set search_path = public as $$
declare l licences; j int; auj date := (now() at time zone 'Europe/Brussels')::date; t text;
begin
  for l in select * from licences where statut = 'active' loop
    j := l.fin - auj;
    if j < 0 then
      if l.expire_avis is null then
        t := '<h2 style="margin:0 0 10px">Licence expirée</h2><p>La licence des applications du Bureau étudiant est arrivée à échéance le '
          || to_char(l.fin, 'DD/MM/YYYY') || '. Les applications sont désormais en <b>lecture seule</b>. L''Admin peut demander une nouvelle licence dans l''Espace CA.</p>';
        perform licence_mail(l.demandeur_email, '⛔ Licence expirée — applications en lecture seule', t);
        perform licence_mail_proprio('⛔ Licence expirée — ' || coalesce(l.demandeur_nom, ''), t);
        update licences set expire_avis = now() where id = l.id;
      end if;
    elsif j <= 7 and l.rappel_7 is null then
      t := '<h2 style="margin:0 0 10px">Licence : plus que ' || j || ' jour(s)</h2><p>La licence expire le <b>' || to_char(l.fin, 'DD/MM/YYYY')
        || '</b>. Pensez à demander son renouvellement dans l''Espace CA, sinon les applications passeront en lecture seule.</p>';
      perform licence_mail(l.demandeur_email, '⏳ Votre licence expire dans ' || j || ' jour(s)', t);
      perform licence_mail_proprio('⏳ Licence : échéance dans ' || j || ' jour(s)', t);
      update licences set rappel_7 = now(), rappel_30 = coalesce(rappel_30, now()) where id = l.id;
    elsif j <= 30 and l.rappel_30 is null then
      t := '<h2 style="margin:0 0 10px">Licence : échéance le ' || to_char(l.fin, 'DD/MM/YYYY') || '</h2><p>La licence expire dans ' || j
        || ' jours. Pensez à demander son renouvellement dans l''Espace CA.</p>';
      perform licence_mail(l.demandeur_email, '📅 Votre licence expire dans ' || j || ' jours', t);
      update licences set rappel_30 = now() where id = l.id;
    end if;
  end loop;
end $$;
revoke all on function public.licence_rappels() from anon, authenticated, public;
select cron.unschedule('licence-rappels') where exists (select 1 from cron.job where jobname = 'licence-rappels');
select cron.schedule('licence-rappels', '13 7 * * *', 'select public.licence_rappels();');
revoke all on function public.licence_courante() from anon, authenticated, public;
revoke all on function public.app_refus_motif(text, text) from anon, authenticated, public;
revoke all on function public.proprio_exiger() from anon, public;

-- ============================ 3. GARDE DES TABLES ================================
create table if not exists public.app_tables (
  nom text primary key,
  app text,                 -- 'ca' | 'caisse' | null (billetterie : seulement le module)
  module text,              -- module en option, ou null
  lecture_bloquee boolean not null default true   -- app fermée => plus lisible
);
alter table public.app_tables enable row level security;
revoke all on public.app_tables from anon, authenticated, public;

insert into public.app_tables (nom, app, module, lecture_bloquee) values
  ('ca_annonce_reactions','ca',null,true),('ca_annonces','ca',null,true),('ca_avis','ca',null,true),('ca_avis_votes','ca',null,true),
  ('ca_bilan_faits','ca',null,true),('ca_bilans','ca',null,true),('ca_budget_reserves','ca',null,true),('ca_budget_votes','ca',null,true),
  ('ca_budgets','ca',null,true),('ca_contacts','ca',null,true),('ca_creneaux','ca',null,true),('ca_dispos','ca',null,true),
  ('ca_docs','ca',null,true),('ca_evenements','ca',null,true),('ca_event_presence','ca',null,true),('ca_mail_groupes','ca',null,true),
  ('ca_mail_programmes','ca',null,true),('ca_mailing','ca',null,true),('ca_messages','ca',null,true),('ca_org','ca',null,true),
  ('ca_procurations','ca',null,true),('ca_pv_signatures','ca',null,true),('ca_reunions','ca',null,true),('ca_taches','ca',null,true),
  ('ca_vote_ballots','ca',null,true),('ca_vote_options','ca',null,true),('ca_votes','ca',null,true),('ca_meta','ca',null,false),
  ('ca_salle_blocages','ca','salle',true),('ca_salle_reservations','ca','salle',true),
  ('ca_conflits','ca','mediation',true),('ca_med_dossiers','ca','mediation',true),('ca_med_mediateurs','ca','mediation',true),('ca_med_messages','ca','mediation',true),
  ('ces_config','ca','ces',true),('ces_creneaux','ca','ces',true),('ces_dossiers','ca','ces',true),('ces_elements','ca','ces',true),
  ('ces_fichier_parts','ca','ces',true),('ces_fichiers','ca','ces',true),
  ('soutien_config','ca','soutien',true),('soutien_conversations','ca','soutien',true),('soutien_messages','ca','soutien',true),('soutien_notif','ca','soutien',true),
  ('bil_commissions',null,'billetterie',false),('bil_evenements',null,'billetterie',false),('bil_inscriptions',null,'billetterie',false),
  ('bil_scans',null,'billetterie',false),('bil_sondages',null,'billetterie',false),
  ('requests','caisse',null,true),('events','caisse',null,true),('expenses','caisse',null,true),('incomes','caisse',null,true),
  ('closures','caisse',null,true),('depensiers','caisse',null,true),('factures_echeance','caisse',null,true),('gj_actes','caisse',null,true),
  ('gj_liens','caisse',null,true),('messages','caisse',null,true),('novelles_acces','caisse',null,true),('novelles_mouvements','caisse',null,true),
  ('sc_actes','caisse',null,true),('tb_config','caisse',null,true),('caisse_budget_attrib','caisse',null,true),('caisse_budget_histo','caisse',null,true),
  ('caisse_budget_meta','caisse',null,true),('caisse_budget_reservations','caisse',null,true),('caisse_config','caisse',null,true),
  ('caisse_documents','caisse',null,true),('profiles','caisse',null,false)
on conflict (nom) do update set app = excluded.app, module = excluded.module, lecture_bloquee = excluded.lecture_bloquee;

create or replace function public.app_garde() returns trigger
language plpgsql security definer set search_path = public as $$
declare v text;
begin
  v := public.app_refus_motif(nullif(tg_argv[0], ''), nullif(tg_argv[1], ''));
  if v <> '' then raise exception '%', v using errcode = 'P0001', hint = 'app_garde'; end if;
  return null;
end $$;
revoke all on function public.app_garde() from anon, authenticated, public;

do $$
declare t record;
begin
  for t in select a.* from public.app_tables a join pg_class c on c.relname = a.nom and c.relnamespace = 'public'::regnamespace loop
    execute format('drop trigger if exists a0_app_garde on public.%I', t.nom);
    execute format('create trigger a0_app_garde before insert or update or delete on public.%I for each statement execute function public.app_garde(%L, %L)',
                   t.nom, coalesce(t.app, ''), coalesce(t.module, ''));
    execute format('drop policy if exists app_fermee on public.%I', t.nom);
    if t.lecture_bloquee and t.app is not null then
      execute format('create policy app_fermee on public.%I as restrictive for select to authenticated using ((select public.app_lecture_ok(%L)))', t.nom, t.app);
    end if;
  end loop;
end $$;

-- ============== 4. DEUXIÈME SIGNATAIRE GJ, SALLE, TRÉSORIER VU DU CA ==============
-- (migrations « proprio_4_gj_cosignataire » et « proprio_5_admin_salle_tresorier »)
alter table public.proprio_config add column if not exists gj_cosignataire uuid;
-- gj__presidente() : renvoie proprio_config.gj_cosignataire s'il est choisi (membre actif,
--   pas trésorier), sinon comme avant la personne dont la fonction commence par « président ».
-- proprio_set_gj_cosignataire(uuid) : réservé au propriétaire.
-- proprio_tableau() : ajoute config.gj_cosignataire et gj_cosignataire_effectif.
-- ca_salle_set_resp : « ca_salle_est_owner() » remplacé par « ca_est_admin() ».
-- ca_tresorier() : {id, email, nom} du trésorier de la Caisse, pour les membres du CA.
-- modules_liste, licence_options_txt : search_path fixé.
-- Le lien secret de l'espace Propriétaire n'est PAS dans ce dépôt : seul son hash est
-- en base (proprio_config.lien_hash) ; le propriétaire peut en générer un nouveau.
