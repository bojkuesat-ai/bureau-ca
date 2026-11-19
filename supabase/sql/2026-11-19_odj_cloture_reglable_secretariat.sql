-- Ordre du jour : le secrétariat règle, réunion par réunion, la date/heure limite d'ajout des points.
-- Vide = heure de la réunion (voir 2026-11-19_odj_ouvert_jusqu_a_la_reunion.sql).
-- Appliqué sur Supabase via apply_migration « odj_cloture_reglable_secretariat » :
--   1) alter table ca_reunions add column odj_cloture_at timestamptz;
--   2) reu_odj_ferme(date, time, timestamptz) : limite fixée sinon règle par défaut ;
--   3) ca_reunions_garde() : appelle la nouvelle fonction, et seul le secrétariat peut modifier odj_cloture_at.
alter table public.ca_reunions add column if not exists odj_cloture_at timestamptz;
create or replace function public.reu_odj_ferme(p_date date, p_heure time, p_cloture timestamptz)
returns boolean language sql stable as $$
  select case when p_cloture is not null then now() >= p_cloture
              else public.reu_odj_ferme(p_date, p_heure) end $$;
