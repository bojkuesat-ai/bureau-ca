-- =====================================================================
--  Budgets à certification CA (25/11/2026) — migration budget_certification_ca
--  Premier usage : budget CES « Demande d'attribution budgétaire – Commission d'Entraide Sociale »
--  (2 000 €), ouvert pour les urgences, réserve du trésorier sur la totalité.
--  - caisse_budget_certif : budgets concernés, mention affichée et points certifiés.
--  - Dans la Caisse, une demande sur un de ces budgets exige une certification signée par mot de passe
--    (date du vote du CA obligatoire) : caisse_certif_ca_signer() → code du registre des signatures
--    (type « certif_ca »), ligne dans caisse_certifs_ca, PDF joint à la demande.
--  - Contrôle côté app (la mention suffit, pas de blocage serveur).
-- =====================================================================
create table if not exists public.caisse_budget_certif (
  budget_id  text primary key,
  mention    text not null,
  points     jsonb not null default '[]'::jsonb,
  actif      boolean not null default true,
  cree_le    timestamptz not null default now()
);
alter table public.caisse_budget_certif enable row level security;
create policy lire on public.caisse_budget_certif for select to authenticated using (true);
revoke insert, update, delete on public.caisse_budget_certif from anon, authenticated;

create table if not exists public.caisse_certifs_ca (
  id          uuid primary key default gen_random_uuid(),
  request_id  uuid not null unique references public.requests(id) on delete cascade,
  budget_id   text not null,
  user_id     uuid not null,
  date_vote   date not null,
  texte       text not null,
  code        text not null,
  signe_le    timestamptz not null default now()
);
alter table public.caisse_certifs_ca enable row level security;
create policy lire on public.caisse_certifs_ca for select to authenticated using (user_id = auth.uid() or public.is_tresorier());
revoke insert, update, delete on public.caisse_certifs_ca from anon, authenticated;

create or replace function public.caisse_certif_ca_signer(p_request uuid, p_date_vote date)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r requests; c caisse_budget_certif; v_nom text; v_fct text; v_texte text; v_code text; v_emp text; i int := 0; p text;
begin
  if auth.uid() is null then raise exception 'Connexion requise.'; end if;
  perform sc_mdp_frais();
  select * into r from requests where id = p_request for update;
  if not found then raise exception 'Demande introuvable.'; end if;
  if r.user_id <> auth.uid() then raise exception 'Seul l''auteur de la demande peut la certifier.'; end if;
  if r.created_at < now() - interval '30 minutes' then raise exception 'Délai de signature dépassé : refaites la demande.'; end if;
  select * into c from caisse_budget_certif where budget_id = r.budget_id and actif;
  if not found then raise exception 'Ce budget ne demande pas de certification.'; end if;
  if p_date_vote is null then raise exception 'Indiquez la date du vote du CA.'; end if;
  if p_date_vote > (now() at time zone 'Europe/Brussels')::date then raise exception 'La date du vote du CA ne peut pas être dans le futur.'; end if;
  if exists (select 1 from caisse_certifs_ca where request_id = p_request) then raise exception 'Demande déjà certifiée.'; end if;
  select nullif(trim(coalesce(prenom,'') || ' ' || coalesce(nom,'')), ''), fonction into v_nom, v_fct from ca_membres where id = auth.uid();
  if v_nom is null then select name, position into v_nom, v_fct from profiles where id = auth.uid(); end if;
  v_texte := 'Je soussigné·e, ' || coalesce(v_nom, '?') || coalesce(', ' || nullif(v_fct, ''), '') || ', certifie :';
  for p in select jsonb_array_elements_text(c.points) loop
    i := i + 1;
    v_texte := v_texte || chr(10) || i || '. ' || replace(p, '[date du vote]', to_char(p_date_vote, 'DD/MM/YYYY'));
  end loop;
  v_emp := signature_empreinte(jsonb_build_object('id', r.id, 'seq', r.seq, 'montant', r.amount, 'objet', r.object, 'budget', r.budget_id,
    'date_vote', p_date_vote, 'texte', v_texte, 'user', r.user_id)::text);
  v_code := signature_interne('caisse', 'certif_ca', r.id::text,
    'Demande n° ' || coalesce(r.seq::text, '?') || ' — certification d''approbation du CA (vote du ' || to_char(p_date_vote, 'DD/MM/YYYY') || ')', v_emp,
    jsonb_build_object('numero', r.seq, 'montant', r.amount, 'objet', r.object, 'budget', r.budget_id, 'date_vote', p_date_vote, 'texte', v_texte));
  insert into caisse_certifs_ca (request_id, budget_id, user_id, date_vote, texte, code) values (r.id, r.budget_id, r.user_id, p_date_vote, v_texte, v_code);
  return jsonb_build_object('code', v_code, 'texte', v_texte);
end $$;
revoke all on function public.caisse_certif_ca_signer(uuid, date) from public, anon;
grant execute on function public.caisse_certif_ca_signer(uuid, date) to authenticated;

insert into public.caisse_budget_certif (budget_id, mention, points) values (
  'bb05e542-b4f8-4b7c-8cea-ae890f6684d9',
  'Ouverture de budget (25/11/2026). Ce budget de 2 000 € est ouvert, pour le moment, uniquement pour les situations d''urgence de la Commission d''Entraide Sociale. Les demandes se font au fur et à mesure des besoins (par exemple 250 €), dans la limite du solde disponible. Chaque aide urgente doit être votée par le CA avant d''être demandée dans la Caisse. Le trésorier a émis une réserve sur la totalité du budget (2 000 €) : elle reste en vigueur.',
  jsonb_build_array(
    'que cette aide a été approuvée par le CA le [date du vote] ;',
    'qu''il s''agit d''une aide urgente, répondant à une situation de précarité qui ne peut pas attendre ;',
    'avoir pris connaissance que le trésorier a émis une réserve sur la totalité du budget (2 000 €). Cette réserve reste en vigueur : l''acceptation d''une demande urgente ne la lève pas pour le solde. Chaque nouvelle demande sur ce budget reste soumise à cette réserve et au vote du CA.'))
on conflict (budget_id) do update set mention = excluded.mention, points = excluded.points, actif = true;

-- Migration budget_certification_ca_mfa : même garde « double authentification » que les autres tables.
create policy mfa_aal2 on public.caisse_budget_certif as restrictive for all to authenticated using ((select public.mfa_ok()));
create policy mfa_aal2 on public.caisse_certifs_ca as restrictive for all to authenticated using ((select public.mfa_ok()));
