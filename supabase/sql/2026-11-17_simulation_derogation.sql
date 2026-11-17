-- Simulation budget : dérogation « 20 % même si la trésorerie libre est négative » + plafond manuel,
-- et vérification des demandes de budget de l'ordre du jour — 17/11/2026
--
-- Calcul normal : trésorerie libre = solde − factures − estimations − budgets ouverts − remboursements en cours ;
--   limite = 20 % de la trésorerie libre.
-- Dérogation (Admin, case à cocher) : base = solde − budgets ouverts (hors factures) ;
--   limite = plafond saisi par l'Admin, sinon 20 % de cette base.
-- Faisable si 0 < montant ≤ limite. Quand la simulation est activée, une demande de budget non faisable
-- ne peut pas être ajoutée à l'ordre du jour (ca_reunions_garde).

alter table public.ca_meta add column if not exists simu_derog boolean not null default false;
alter table public.ca_meta add column if not exists simu_plafond numeric;

-- Chiffres bruts (sans contrôle d'accès) : appelée seulement par les fonctions ci-dessous.
create or replace function public.simu_budget_chiffres()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_seuil constant numeric := 0.20;
  v_solde numeric; v_fact numeric; v_estim numeric; v_bud numeric; v_hors numeric;
  v_libre numeric; v_max numeric; v_base numeric; v_maxd numeric; v_derog boolean; v_plaf numeric; v_lim numeric;
  v_factures jsonb; v_budgets jsonb;
begin
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
  v_base := round(v_solde - v_bud, 2);
  v_maxd := case when v_base > 0 then floor(v_base * v_seuil * 100) / 100 else 0 end;
  select coalesce(simu_derog, false), simu_plafond into v_derog, v_plaf from ca_meta where id = 1;
  v_lim := case when coalesce(v_derog, false) then coalesce(v_plaf, v_maxd) else v_max end;

  return jsonb_build_object(
    'le', now(), 'seuil', v_seuil, 'solde', round(v_solde, 2), 'factures', round(v_fact, 2),
    'estimations', round(v_estim, 2), 'budgets', round(v_bud, 2), 'hors_budget', round(v_hors, 2),
    'libre', v_libre, 'max_normal', v_max,
    'derog', coalesce(v_derog, false), 'plafond', v_plaf, 'base_derog', v_base, 'max_derog', v_maxd,
    'max', round(coalesce(v_lim, 0), 2),
    'detail_factures', v_factures, 'detail_budgets', v_budgets);
end $$;
revoke all on function public.simu_budget_chiffres() from anon, authenticated, public;

create or replace function public.simu_budget_calcul(p_montant numeric)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c jsonb;
begin
  if not courrier_peut() then raise exception 'Réservé aux membres du CA.'; end if;
  if not mfa_ok() then raise exception 'Tapez d''abord le code de double authentification.'; end if;
  if not coalesce((select simu_budget_actif from ca_meta where id = 1), false) then
    raise exception 'La simulation budget est désactivée (Admin).'; end if;
  if p_montant is not null and (p_montant < 0 or p_montant > 1000000) then
    raise exception 'Montant invalide.'; end if;
  c := simu_budget_chiffres();
  return c || jsonb_build_object(
    'montant', p_montant,
    'faisable', (p_montant is not null and p_montant > 0 and (c->>'max')::numeric > 0 and p_montant <= (c->>'max')::numeric),
    'treso_email', (select treso_email from caisse_config where id = 1));
end $$;
revoke all on function public.simu_budget_calcul(numeric) from anon, public;
grant execute on function public.simu_budget_calcul(numeric) to authenticated;

-- Admin : chiffres de la dérogation (même quand la simulation est désactivée).
create or replace function public.simu_budget_admin_info()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c jsonb;
begin
  if not ca_est_admin() then raise exception 'Réservé à l''Admin du CA.'; end if;
  c := simu_budget_chiffres();
  return jsonb_build_object('solde', c->'solde', 'budgets', c->'budgets', 'base_derog', c->'base_derog',
    'max_derog', round((c->>'max_derog')::numeric, 2), 'derog', c->'derog', 'plafond', c->'plafond',
    'libre', c->'libre', 'max_normal', round((c->>'max_normal')::numeric, 2));
end $$;
revoke all on function public.simu_budget_admin_info() from anon, public;
grant execute on function public.simu_budget_admin_info() to authenticated;

-- Admin : enregistrer la dérogation et le plafond (plafond vide = calcul à 20 %).
create or replace function public.simu_budget_derog(p_actif boolean, p_plafond numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m text;
begin
  if not ca_est_admin() then raise exception 'Réservé à l''Admin du CA.'; end if;
  if not mfa_ok() then raise exception 'Tapez d''abord le code de double authentification.'; end if;
  m := app_refus_motif(null, null);
  if m <> '' then raise exception '%', m; end if;
  if p_plafond is not null and (p_plafond <= 0 or p_plafond > 1000000) then raise exception 'Plafond invalide.'; end if;
  update ca_meta set simu_derog = coalesce(p_actif, false), simu_plafond = round(p_plafond, 2) where id = 1;
  return simu_budget_admin_info();
end $$;
revoke all on function public.simu_budget_derog(boolean, numeric) from anon, public;
grant execute on function public.simu_budget_derog(boolean, numeric) to authenticated;

-- Garde de l'ordre du jour : demande de budget vérifiée quand la simulation est activée (pour tout le monde).
create or replace function public.reu_budget_controle(p_ancien jsonb, p_neuf jsonb)
returns void language plpgsql stable security definer set search_path = public as $$
declare p jsonb; c jsonb; v numeric;
begin
  if not coalesce((select simu_budget_actif from ca_meta where id = 1), false) then return; end if;
  for p in select * from jsonb_array_elements(p_neuf) loop
    continue when p->>'sujet' is distinct from 'budget';
    continue when exists (select 1 from jsonb_array_elements(p_ancien) x where x->>'id' = p->>'id');
    if c is null then c := simu_budget_chiffres(); end if;
    v := coalesce(nullif(p->>'budgetMontant', '')::numeric, 0);
    if v <= 0 or (c->>'max')::numeric <= 0 or v > (c->>'max')::numeric then
      raise exception 'Demande de budget pas faisable : %',
        case when (c->>'max')::numeric > 0
             then 'vous pouvez demander au maximum ' || replace(to_char((c->>'max')::numeric, 'FM999999990.00'), '.', ',') || ' €.'
             else 'aucune demande de budget n''est possible pour le moment.' end;
    end if;
  end loop;
end $$;
revoke all on function public.reu_budget_controle(jsonb, jsonb) from anon, authenticated, public;

-- Garde des réunions (version 17/11 + contrôle des demandes de budget).
create or replace function public.ca_reunions_garde()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  uid  uuid := auth.uid();
  moi  text;
  o    jsonb;
  p    jsonb;
  ancien jsonb := coalesce(old.ordre::jsonb, '[]'::jsonb);
  neuf   jsonb := coalesce(new.ordre::jsonb, '[]'::jsonb);
  secr boolean;
begin
  if uid is null then return new; end if;
  moi := uid::text;

  -- PV en signature ou signé : plus rien ne bouge (le secrétariat doit d'abord le retirer de la signature).
  if reu_pv_verrouille(old.id) and (
       new.titre is distinct from old.titre or new.date is distinct from old.date or new.heure is distinct from old.heure
    or new.lieu is distinct from old.lieu or new.presences::jsonb is distinct from old.presences::jsonb
    or neuf is distinct from ancien) then
    raise exception 'Le PV de cette réunion est en signature ou signé : la réunion est verrouillée.';
  end if;

  -- Demande de budget : vérifiée par la simulation quand elle est activée (pour tout le monde).
  perform reu_budget_controle(ancien, neuf);

  secr := (exists (select 1 from ca_meta m where m.id = 1 and coalesce(m.secretaires::text, '') like '%' || moi || '%')
     or exists (select 1 from ca_membres c where c.id = uid and c.role = 'owner')) and public.mfa_ok();
  if secr then return new; end if;

  if new.titre is distinct from old.titre
     or new.date is distinct from old.date
     or new.heure is distinct from old.heure
     or new.lieu is distinct from old.lieu
     or new.odj_envoye_at is distinct from old.odj_envoye_at
     or new.presences::jsonb is distinct from old.presences::jsonb
     or new.pv_statut is distinct from old.pv_statut
     or new.pv_approuve_le is distinct from old.pv_approuve_le
     or new.pv_approuve_note is distinct from old.pv_approuve_note then
    raise exception 'Seul le secrétariat peut modifier la réunion, les présences ou le PV.';
  end if;

  for o in select * from jsonb_array_elements(ancien) loop
    select x into p from jsonb_array_elements(neuf) x where x->>'id' = o->>'id' limit 1;
    if p is null then
      if coalesce(o->>'parId', '') <> moi then
        raise exception 'Vous ne pouvez supprimer que vos propres points.';
      end if;
      if reu_odj_ferme(old.date) then
        raise exception 'L''ordre du jour est clôturé (la veille de la réunion à 23 h 59).';
      end if;
    else
      if (p->>'texte') is distinct from (o->>'texte')
         or (p->'fait')  is distinct from (o->'fait')
         or (p->>'parId') is distinct from (o->>'parId')
         or (p->>'par')  is distinct from (o->>'par')
         or (p->>'sujet') is distinct from (o->>'sujet')
         or (p->>'note') is distinct from (o->>'note')
         or (p->>'budgetObjet') is distinct from (o->>'budgetObjet')
         or (p->>'budgetMontant') is distinct from (o->>'budgetMontant') then
        raise exception 'Seul le secrétariat peut modifier ou cocher un point.';
      end if;
      if coalesce(p->>'notes', '') is distinct from coalesce(o->>'notes', '')
         and coalesce(o->>'parId', '') <> moi then
        raise exception 'Vous ne pouvez écrire des notes que sous vos propres points.';
      end if;
    end if;
  end loop;

  for p in select * from jsonb_array_elements(neuf) loop
    if not exists (select 1 from jsonb_array_elements(ancien) x where x->>'id' = p->>'id') then
      if coalesce(p->>'parId', '') <> moi then
        raise exception 'Un nouveau point doit être à votre nom.';
      end if;
      if coalesce(p->>'fait', 'false') = 'true' then
        raise exception 'Seul le secrétariat peut cocher un point.';
      end if;
      if reu_odj_ferme(new.date) then
        raise exception 'L''ordre du jour est clôturé (la veille de la réunion à 23 h 59).';
      end if;
      if not (coalesce(p->>'sujet', '') = any (reu_sujets())) then
        raise exception 'Choisissez un sujet dans la liste.';
      end if;
      if p->>'sujet' = 'budget' and (coalesce(trim(p->>'budgetObjet'), '') = ''
         or coalesce(nullif(p->>'budgetMontant', ''), '0')::numeric <= 0) then
        raise exception 'Demande de budget : l''objet et le montant sont obligatoires.';
      end if;
      if p->>'sujet' = 'autre' and coalesce(trim(p->>'texte'), '') = '' then
        raise exception 'Sujet « Autre » : écrivez le titre du point.';
      end if;
    end if;
  end loop;

  return new;
end $$;
