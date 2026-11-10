-- =====================================================================
-- BILLETTERIE — nom d'expéditeur par commission
-- À coller dans : https://supabase.com/dashboard/project/mlgzdfyqjhvyubrywuim/sql/new
-- Réexécutable sans risque (idempotent).
-- =====================================================================

-- 1. Colonne « expediteur » (nom affiché devant noreply@bureauetuidant.xyz)
alter table public.bil_commissions
  add column if not exists expediteur text;

alter table public.bil_commissions
  drop constraint if exists bil_commissions_expediteur_chk;
alter table public.bil_commissions
  add constraint bil_commissions_expediteur_chk
  check (expediteur is null
         or (length(expediteur) between 2 and 40 and expediteur !~ '[<>"@\r\n]'));

-- 2. Valeurs de départ (ne touche pas une commission déjà renseignée)
update public.bil_commissions set expediteur = 'ACA-BE'     where expediteur is null and nom ilike '%acad%';
update public.bil_commissions set expediteur = 'Festif-BE'  where expediteur is null and nom ilike '%festi%';
update public.bil_commissions set expediteur = 'Culture-BE' where expediteur is null and nom ilike '%cultur%';
-- Les autres restent NULL → la fonction billets-mail utilisera « Billetterie-BE ».

-- 3. RPC : le propriétaire (ca_membres.role = 'owner') change le nom depuis CA › Admin
create or replace function public.bil_admin_expediteur(p_cid uuid, p_exp text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_exp text := nullif(btrim(coalesce(p_exp, '')), '');
begin
  if auth.uid() is null
     or not exists (select 1 from public.ca_membres m
                     where m.id = auth.uid() and m.role = 'owner') then
    raise exception 'Réservé au propriétaire' using errcode = '42501';
  end if;

  if v_exp is not null and (length(v_exp) < 2 or length(v_exp) > 40 or v_exp ~ '[<>"@\r\n]') then
    raise exception 'Nom d''expéditeur invalide (2 à 40 caractères, sans < > " @)';
  end if;

  update public.bil_commissions set expediteur = v_exp where id = p_cid;
  if not found then
    raise exception 'Commission introuvable';
  end if;
end;
$$;

revoke all on function public.bil_admin_expediteur(uuid, text) from public, anon;
grant execute on function public.bil_admin_expediteur(uuid, text) to authenticated;

-- 4. Lecture pour la fonction billets-mail (clé service) et pour l'Admin :
--    nom d'expéditeur complet d'un événement, avec repli.
create or replace function public.bil_expediteur_evenement(p_eid uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(nullif(btrim(c.expediteur), ''), 'Billetterie-BE') || ' <noreply@bureauetuidant.xyz>'
    from public.bil_evenements e
    left join public.bil_commissions c on c.id = e.commission_id
   where e.id = p_eid
  union all
  select 'Billetterie-BE <noreply@bureauetuidant.xyz>'
  limit 1;
$$;

revoke all on function public.bil_expediteur_evenement(uuid) from public, anon, authenticated;
-- (seule la clé service, utilisée par billets-mail, peut l'appeler)

-- 5. Contrôle
select id, nom, actif, expediteur from public.bil_commissions order by nom;
