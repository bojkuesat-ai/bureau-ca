-- =====================================================================
-- Budgets (13/11/2026) — point 2 de l'audit : la décision est vérifiée par le serveur.
-- Appliqué via le SQL Editor (connecteur Supabase indisponible ce jour-là).
--
-- Avant : approuver / refuser / créer un budget « approuvé » était une écriture
-- directe depuis le navigateur ; le seuil de votes n'était contrôlé qu'à l'écran.
-- Décisions du 13/11/2026 :
--   * plus d'approbation « hors seuil » ;
--   * un budget voté en CA physique est introduit et SIGNÉ par le responsable qui
--     l'a obtenu (ca_budget_certifier → attente_tresorier, code de vérification),
--     puis confirmé et SIGNÉ par le trésorier (ca_budget_confirmer, code) ;
--   * plus de raccourci : tout budget créé depuis l'API naît « vote ».
-- Le trigger ne concerne que les écritures directes (rôles authenticated/anon) :
-- les fonctions SECURITY DEFINER (certifier, confirmer, retirer) font leurs propres contrôles.
-- =====================================================================

-- 1. Règle de l'article 16.2, recalculée par le serveur
create or replace function public.ca_budget_regle162_ok(p_budget text)
returns boolean language sql stable security definer set search_path = public as $$
  with n as (
    select count(*)::int as n from ca_membres
    where statut = 'actif' and coalesce(role, '') <> 'coopte' and coalesce(email, '') <> ''
  ), v as (
    select bv.choix, coalesce(m.fonction, split_part(coalesce(bv.nom, ''), '·', 2)) as fonction
    from ca_budget_votes bv left join ca_membres m on m.id = bv.membre_id
    where bv.budget_id::text = p_budget
  ), c as (
    select count(*) filter (where choix = 'pour') as pour,
           count(*) filter (where choix = 'contre') as contre,
           count(*) as votants,
           bool_or(choix = 'pour' and fonction ~* '^\s*(co-?)?pr[ée]sident') as pres_pour
    from v
  )
  select n.n > 0
     and c.votants >= ceil(n.n / 2.0)
     and (c.pour > c.contre or (c.pour = c.contre and c.pour > 0 and coalesce(c.pres_pour, false)))
  from n, c;
$$;
revoke all on function public.ca_budget_regle162_ok(text) from anon, authenticated, public;

-- 2. Verrou sur les écritures directes
create or replace function public.ca_budgets_garde_decision()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_owner boolean;
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  v_owner := exists (select 1 from ca_membres where id = auth.uid() and role = 'owner' and statut = 'actif');

  if tg_op = 'INSERT' then
    if coalesce(new.statut, 'vote') <> 'vote' then
      raise exception 'Un budget doit être créé « en vote ». Un budget voté en CA physique s''introduit par « Voté en CA physique » (certification signée du responsable).';
    end if;
    new.decide_par := null; new.decide_le := null;
    return new;
  end if;

  if new.statut is not distinct from old.statut
     and new.decide_par is not distinct from old.decide_par
     and new.decide_le is not distinct from old.decide_le then
    return new;
  end if;
  if not v_owner then
    raise exception 'Seul le trésorier peut clôturer, refuser ou rouvrir un budget.';
  end if;
  if old.statut = 'attente_tresorier' or new.statut = 'attente_tresorier' then
    raise exception 'Un budget voté en CA physique se confirme avec « ✓ Confirmer » (signature du trésorier).';
  end if;
  if new.statut = 'approuve' and old.statut is distinct from 'approuve' then
    if old.statut = 'vote' and ca_budget_regle162_ok(new.id::text) then return new; end if;
    raise exception 'Approbation refusée : le quorum ou la majorité de l''article 16.2 n''est pas atteint.';
  end if;
  return new;
end $$;
revoke all on function public.ca_budgets_garde_decision() from anon, authenticated, public;

drop trigger if exists ca_budgets_garde_decision on public.ca_budgets;
create trigger ca_budgets_garde_decision
  before insert or update on public.ca_budgets
  for each row execute function public.ca_budgets_garde_decision();

-- 3. Codes de vérification des deux signatures
alter table public.ca_budgets add column if not exists certif_code text;
alter table public.ca_budgets add column if not exists confirm_code text;

-- 4. Certification par le responsable (même signature qu'avant, renvoie toujours l'id)
create or replace function public.ca_budget_certifier(p_id text, p_titre text, p_type text, p_cout numeric, p_desc text, p_seance date)
returns text language plpgsql security definer set search_path to 'public' as $function$
declare
  me  public.ca_membres%rowtype;
  sig text;
  v_id text;
  b   public.ca_budgets%rowtype;
  v_emp text; v_code text;
begin
  select * into me from public.ca_membres where id = auth.uid();
  if not found or coalesce(me.statut,'') <> 'actif' or coalesce(me.role,'') = 'coopte' then
    raise exception 'Compte non autorisé à certifier';
  end if;
  perform pvs_mdp_frais();   -- mot de passe retapé il y a moins de 2 minutes
  if p_seance is null or p_seance > current_date then
    raise exception 'Date de séance invalide';
  end if;
  sig := coalesce(nullif(me.prenom,''), me.nom, '') || case when coalesce(me.fonction,'') <> '' then ' · ' || me.fonction else '' end;

  if p_id is null or p_id = '' then
    if coalesce(trim(p_titre),'') = '' then raise exception 'Titre manquant'; end if;
    insert into public.ca_budgets (titre, type, cout, description, demandeur, statut, cree_par,
                                   certifie_par, certifie_id, certifie_le, seance_le, origine_certif)
    values (trim(p_titre), p_type, coalesce(p_cout,0), nullif(trim(coalesce(p_desc,'')),''), sig, 'attente_tresorier', auth.uid(),
            sig, auth.uid(), now(), p_seance, 'nouveau')
    returning id::text into v_id;
  else
    select * into b from public.ca_budgets where id::text = p_id for update;
    if not found or b.statut <> 'vote' then raise exception 'Budget introuvable ou plus en vote'; end if;
    if b.cree_par is distinct from auth.uid() then
      raise exception 'Seul le responsable qui a introduit ce budget peut certifier qu''il a été voté en CA physique.';
    end if;
    update public.ca_budgets
       set statut = 'attente_tresorier', certifie_par = sig, certifie_id = auth.uid(),
           certifie_le = now(), seance_le = p_seance, origine_certif = 'vote'
     where id::text = p_id
    returning id::text into v_id;
  end if;

  select * into b from public.ca_budgets where id::text = v_id;
  v_emp := signature_empreinte(jsonb_build_object('id', b.id, 'titre', b.titre, 'type', b.type, 'cout', b.cout,
    'description', b.description, 'seance', b.seance_le, 'certifie_par', auth.uid())::text);
  v_code := signature_interne('ca', 'budget_certification', b.id::text,
    'Budget « ' || b.titre || ' » — voté en CA physique le ' || to_char(b.seance_le, 'DD/MM/YYYY') || ' — certification du responsable', v_emp,
    jsonb_build_object('titre', b.titre, 'cout', b.cout, 'type', b.type, 'seance', b.seance_le));
  update public.ca_budgets set certif_code = v_code where id = b.id;
  return v_id;
end $function$;

-- 5. Confirmation par le trésorier (signature)
create or replace function public.ca_budget_confirmer(p_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me ca_membres; b ca_budgets; v_emp text; v_code text; v_sig text;
begin
  select * into me from ca_membres where id = auth.uid() and role = 'owner' and statut = 'actif';
  if not found then raise exception 'Seul le trésorier peut confirmer un budget voté en CA physique.'; end if;
  perform pvs_mdp_frais();
  select * into b from ca_budgets where id::text = p_id for update;
  if not found then raise exception 'Budget introuvable.'; end if;
  if b.statut <> 'attente_tresorier' then raise exception 'Ce budget n''attend pas de confirmation (déjà traité ou retiré).'; end if;
  if b.certifie_id = auth.uid() then raise exception 'Les deux signataires doivent être différents : vous avez vous-même certifié ce budget.'; end if;
  v_sig := coalesce(nullif(me.prenom,''), me.nom, '') || case when coalesce(me.fonction,'') <> '' then ' · ' || me.fonction else '' end;
  v_emp := signature_empreinte(jsonb_build_object('id', b.id, 'titre', b.titre, 'type', b.type, 'cout', b.cout,
    'seance', b.seance_le, 'certif_code', b.certif_code)::text);
  v_code := signature_interne('ca', 'budget_confirmation', b.id::text,
    'Budget « ' || b.titre || ' » — voté en CA physique le ' || to_char(b.seance_le, 'DD/MM/YYYY') || ' — confirmation du trésorier', v_emp,
    jsonb_build_object('titre', b.titre, 'cout', b.cout, 'seance', b.seance_le, 'certifie_par', b.certifie_par, 'code_certification', b.certif_code));
  update ca_budgets set statut = 'approuve', decide_par = 'CA physique · ' || v_sig,
    decide_le = ((coalesce(b.seance_le, current_date)::text || ' 12:00')::timestamp at time zone 'Europe/Brussels'),
    confirm_code = v_code
   where id = b.id;
  return (select to_jsonb(x) from ca_budgets x where x.id = b.id);
end $$;
revoke all on function public.ca_budget_confirmer(text) from anon, public;
grant execute on function public.ca_budget_confirmer(text) to authenticated;

-- 6. Contrôle final (le résultat s'affiche dans le SQL Editor)
select 'trigger' as quoi, count(*)::text as resultat from pg_trigger where tgname = 'ca_budgets_garde_decision'
union all select 'confirmer', count(*)::text from pg_proc where proname = 'ca_budget_confirmer'
union all select 'colonnes codes', count(*)::text from information_schema.columns where table_name = 'ca_budgets' and column_name in ('certif_code','confirm_code')
union all select 'budgets en vote', count(*)::text from ca_budgets where statut = 'vote'
union all select 'budgets en attente du tresorier', count(*)::text from ca_budgets where statut = 'attente_tresorier'
union all select 'mfa_ok', pg_get_functiondef('public.mfa_ok'::regproc);
