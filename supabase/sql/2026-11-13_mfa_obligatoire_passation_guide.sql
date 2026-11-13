-- =====================================================================
-- 13/11/2026 — Migrations proprio_9 et proprio_10 (déjà appliquées)
--  1. Double authentification OBLIGATOIRE pour l'Admin et le trésorier :
--     ca_est_admin (branche Admin), ca_est_tresorier, is_tresorier,
--     caisse_est_tresorier, fe_est_tresorier, nv_est_tresorier exigent aal2
--     (mfa_aal2), même si la personne n'a encore aucun facteur.
--     Nommer un Admin, un trésorier ou faire la passation exige que la
--     personne ait un facteur vérifié (a_mfa).
--  2. Budgets de la Caisse : décidés par le trésorier (politique ca_bud_upd,
--     lecture ca_bud_sel, garde ca_budgets_garde_decision).
--  3. Passation : abonnements push du propriétaire supprimés (et refusés
--     ensuite par le déclencheur a_pas_proprietaire) ; guide complet envoyé
--     par mail à la nouvelle Admin / trésorière (passation_guide_html).
--  Côté fonction send-email (v24) : le propriétaire retiré ne reçoit plus
--  aucun mail du CA ni de la Caisse (sauf licence et « Nouvelle connexion »),
--  et le Reply-To par défaut passe à l'Admin.
-- =====================================================================

create or replace function public.mfa_aal2() returns boolean language sql stable security definer set search_path to '' as $$
  select coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2' $$;
create or replace function public.a_mfa(p uuid) returns boolean language sql stable security definer set search_path to '' as $$
  select exists (select 1 from auth.mfa_factors f where f.user_id = p and f.status = 'verified') $$;
revoke all on function public.a_mfa(uuid) from public, anon;
grant execute on function public.a_mfa(uuid) to authenticated;

create or replace function public.ca_est_admin() returns boolean language sql stable security definer set search_path to 'public' as $$
  select public.ca_is_owner()
      or (coalesce((select admin and statut = 'actif' and coalesce(role, '') not in ('coopte','proprietaire')
                      from public.ca_membres where id = auth.uid()), false)
          and public.mfa_aal2()) $$;
create or replace function public.ca_est_tresorier() returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'tresorier' and coalesce(approved, false))
     and public.mfa_aal2() $$;
create or replace function public.is_tresorier() returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'tresorier' and approved) and public.mfa_aal2() $$;
create or replace function public.caisse_est_tresorier() returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'tresorier' and approved) and public.mfa_aal2() $$;
create or replace function public.fe_est_tresorier() returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'tresorier' and approved) and public.mfa_aal2() $$;
create or replace function public.nv_est_tresorier() returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'tresorier' and approved) and public.mfa_aal2() $$;

drop policy if exists ca_bud_upd on public.ca_budgets;
create policy ca_bud_upd on public.ca_budgets for update
  using (ca_is_presidente() or ca_is_owner() or ca_est_tresorier())
  with check (ca_is_presidente() or ca_is_owner() or ca_est_tresorier());
drop policy if exists ca_bud_sel on public.ca_budgets;
create policy ca_bud_sel on public.ca_budgets for select using (ca_is_actif() or ca_est_tresorier());

-- ca_budgets_garde_decision : v_owner := ca_is_owner() or ca_est_tresorier()  (reste inchangé)
-- proprio_set_admin(p_membre, true) et proprio_set_tresorier(p_user, true) :
--   refus « Cette personne doit d'abord activer la double authentification » si not a_mfa(...)

create or replace function public.push_pas_proprietaire() returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if exists (select 1 from ca_membres where id = new.membre_id and role = 'proprietaire') then return null; end if;
  return new;
end $$;
drop trigger if exists a_pas_proprietaire on public.push_abonnements;
create trigger a_pas_proprietaire before insert or update on public.push_abonnements
  for each row execute function public.push_pas_proprietaire();

-- proprio_passation(p_personne, p_cosign) : en plus de la version du fichier
-- 2026-11-13_proprietaire_licences.sql :
--   if not a_mfa(p_personne) then raise exception '… activer la double authentification …';
--   delete from push_abonnements where membre_id = v_moi;
--   licence_mail(<adresse>, 'Guide de l''Admin et trésorière / trésorier — Bureau étudiant',
--                passation_guide_html(<prénom>));
-- passation_guide_html(p_prenom) : guide en 7 points (double authentification, onglet Admin,
--   Caisse et budgets, Journal / Registre / sauvegardes / export et phrase secrète remise
--   en main propre, médiation et billetterie, licence, Transparence).
-- Texte complet : voir pg_get_functiondef('public.passation_guide_html(text)'::regprocedure).
