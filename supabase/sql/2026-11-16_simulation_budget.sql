-- Simulation budget (Espace CA) — 16/11/2026
--
-- Un membre du CA tape le montant d'un budget à faire voter. Le serveur calcule :
--   trésorerie libre = solde de la caisse (ASBL, hors Novelles)
--                    − factures à échéance non payées (hors estimations)
--                    − estimations de factures non payées
--                    − reste des budgets approuvés encore ouverts
--                    − remboursements en cours hors budget
-- Faisable si le montant est ≤ 20 % de la trésorerie libre (et celle-ci est positive).
--
-- Reste d'un budget (budget + ses compléments) :
--   ouvert   : le plus grand de (coût − déjà payé) et (demandes en cours + réservations) ;
--   clôturé ou gelé (réserve suspensive non levée) : seulement les demandes déjà en cours.
-- Ce qui est déjà payé est déjà sorti du solde : il n'est jamais compté deux fois.
--
-- Onglet désactivé par défaut : ca_meta.simu_budget_actif (Admin du CA).
-- ca_meta est déjà dans fin_mandat_garder.

alter table public.ca_meta add column if not exists simu_budget_actif boolean not null default false;

create or replace function public.simu_budget_activer(p_actif boolean)
returns boolean language plpgsql security definer set search_path = public as $$
declare m text;
begin
  if not ca_est_admin() then raise exception 'Réservé à l''Admin du CA.'; end if;
  if not mfa_ok() then raise exception 'Tapez d''abord le code de double authentification.'; end if;
  m := app_refus_motif(null, null);
  if m <> '' then raise exception '%', m; end if;
  update ca_meta set simu_budget_actif = coalesce(p_actif, false) where id = 1;
  return coalesce(p_actif, false);
end $$;
revoke all on function public.simu_budget_activer(boolean) from anon, public;
grant execute on function public.simu_budget_activer(boolean) to authenticated;

create or replace function public.simu_budget_calcul(p_montant numeric)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_seuil constant numeric := 0.20;
  v_solde numeric; v_fact numeric; v_estim numeric; v_bud numeric; v_hors numeric;
  v_libre numeric; v_max numeric;
  v_factures jsonb; v_budgets jsonb;
begin
  if not courrier_peut() then raise exception 'Réservé aux membres du CA.'; end if;
  if not mfa_ok() then raise exception 'Tapez d''abord le code de double authentification.'; end if;
  if not coalesce((select simu_budget_actif from ca_meta where id = 1), false) then
    raise exception 'La simulation budget est désactivée (Admin).'; end if;
  if p_montant is not null and (p_montant < 0 or p_montant > 1000000) then
    raise exception 'Montant invalide.'; end if;

  v_solde := coalesce((select sum(amount) from incomes), 0)
           - coalesce((select sum(amount) from expenses), 0)
           - coalesce((select sum(amount) from requests where status = 'Remboursée'), 0);

  with f as (
    select fe.fournisseur, fe.objet, coalesce(fe.estimation, false) est,
           coalesce((select sum((e->>'montant')::numeric) from jsonb_array_elements(coalesce(fe.echeances, '[]'::jsonb)) e
                      where coalesce(e->>'paid_at', '') = ''), 0) reste,
           (select min(e->>'date') from jsonb_array_elements(coalesce(fe.echeances, '[]'::jsonb)) e
             where coalesce(e->>'paid_at', '') = '') prochaine
    from factures_echeance fe)
  select coalesce(sum(reste) filter (where not est), 0), coalesce(sum(reste) filter (where est), 0),
         coalesce(jsonb_agg(jsonb_build_object('fournisseur', fournisseur, 'objet', objet, 'estimation', est,
                  'reste', round(reste, 2), 'date', prochaine) order by est, prochaine) filter (where reste > 0), '[]'::jsonb)
    into v_fact, v_estim, v_factures from f;

  with fam as (
    select coalesce(nullif(b.parent_budget_id, ''), b.id::text) racine, b.id::text bid, coalesce(b.cout, 0) cout
    from ca_budgets b where b.statut = 'approuve'),
  agg as (
    select fam.racine, sum(fam.cout) cout,
      coalesce(sum((select sum(r.amount) from requests r where r.budget_id::text = fam.bid and r.status = 'Remboursée')), 0) paye,
      coalesce(sum((select sum(r.amount) from requests r where r.budget_id::text = fam.bid and r.status in ('Validée','En attente','À corriger'))), 0)
      + coalesce(sum((select sum(x.montant) from caisse_budget_reservations x where x.budget_id = fam.bid and x.statut = 'active')), 0) encours
    from fam group by fam.racine),
  b as (
    select a.*, rb.titre, m.cloture_at is not null clos, g.gel is not null gele,
      case when m.cloture_at is not null or g.gel is not null then greatest(a.encours, 0)
           else greatest(a.cout - a.paye, a.encours, 0) end reste
    from agg a join ca_budgets rb on rb.id::text = a.racine
    left join caisse_budget_meta m on m.budget_id = a.racine
    cross join lateral (select caisse_budget_gel(a.racine) gel) g)
  select coalesce(sum(reste), 0),
         coalesce(jsonb_agg(jsonb_build_object('titre', titre, 'cout', round(cout, 2), 'paye', round(paye, 2),
                  'reste', round(reste, 2), 'cloture', clos, 'gele', gele) order by reste desc, titre), '[]'::jsonb)
    into v_bud, v_budgets from b;

  v_hors := coalesce((select sum(amount) from requests
                       where (budget_id is null or budget_id::text = '')
                         and status in ('Validée','En attente','À corriger')), 0);

  v_libre := round(v_solde - v_fact - v_estim - v_bud - v_hors, 2);
  v_max := case when v_libre > 0 then floor(v_libre * v_seuil * 100) / 100 else 0 end;

  return jsonb_build_object(
    'le', now(),
    'seuil', v_seuil,
    'solde', round(v_solde, 2),
    'factures', round(v_fact, 2),
    'estimations', round(v_estim, 2),
    'budgets', round(v_bud, 2),
    'hors_budget', round(v_hors, 2),
    'libre', v_libre,
    'max', v_max,
    'montant', p_montant,
    'faisable', (p_montant is not null and p_montant > 0 and v_libre > 0 and p_montant <= v_max),
    'detail_factures', v_factures,
    'detail_budgets', v_budgets,
    'treso_email', (select treso_email from caisse_config where id = 1));
end $$;
revoke all on function public.simu_budget_calcul(numeric) from anon, public;
grant execute on function public.simu_budget_calcul(numeric) to authenticated;
