-- Ordre du jour : les points peuvent être ajoutés/retirés jusqu'à l'heure de la réunion
-- (avant : clôture la veille à 23 h 59). Sans heure encodée : jusqu'à la fin du jour de la réunion.
-- Le secrétariat peut toujours ajouter à tout moment.
create or replace function public.reu_odj_ferme(p_date date, p_heure time)
returns boolean language sql stable as $$
  select p_date is not null and now() >= (
    case when p_heure is not null
      then (p_date + p_heure)::timestamp at time zone 'Europe/Brussels'
      else ((p_date + 1)::timestamp at time zone 'Europe/Brussels') end) $$;

do $mig$
declare src text;
begin
  select pg_get_functiondef('public.ca_reunions_garde()'::regprocedure) into src;
  src := replace(src, 'reu_odj_ferme(old.date)', 'reu_odj_ferme(old.date, old.heure)');
  src := replace(src, 'reu_odj_ferme(new.date)', 'reu_odj_ferme(new.date, new.heure)');
  src := replace(src, '(la veille de la réunion à 23 h 59)', '(jusqu''''à l''''heure de la réunion)');
  execute src;
end $mig$;
