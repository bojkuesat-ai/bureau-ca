-- =====================================================================
-- CA › Admin › Billetterie : champ « Expéditeur » par commission
-- À coller dans : https://supabase.com/dashboard/project/mlgzdfyqjhvyubrywuim/sql/new
-- (après billetterie_expediteur.sql déjà exécuté). Réexécutable.
-- =====================================================================

-- 1. Correction : l'id des commissions est un texte, pas un uuid.
drop function if exists public.bil_admin_expediteur(uuid, text);

create or replace function public.bil_admin_expediteur(p_cid text, p_exp text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_exp text := nullif(btrim(coalesce(p_exp, '')), '');
begin
  if auth.uid() is null or not exists
     (select 1 from public.ca_membres m where m.id = auth.uid() and m.role = 'owner') then
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
revoke all on function public.bil_admin_expediteur(text, text) from public, anon;
grant execute on function public.bil_admin_expediteur(text, text) to authenticated;

-- 2. Lecture des expéditeurs pour la carte Admin (propriétaire seul).
create or replace function public.bil_admin_expediteurs()
returns table (id text, expediteur text)
language sql
stable
security definer
set search_path = public
as $$
  select c.id, c.expediteur
    from public.bil_commissions c
   where exists (select 1 from public.ca_membres m where m.id = auth.uid() and m.role = 'owner')
   order by c.nom;
$$;
revoke all on function public.bil_admin_expediteurs() from public, anon;
grant execute on function public.bil_admin_expediteurs() to authenticated;

-- 3. Contrôle
select id, nom, expediteur from public.bil_commissions order by nom;
