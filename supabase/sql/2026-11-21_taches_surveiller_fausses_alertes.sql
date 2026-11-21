-- 21/11/2026 — fausses alertes « Tâche automatique en échec » (32 en 30 jours)
-- La base n'attendait que 5 s la réponse des fonctions et notait « Timeout » alors que la fonction
-- terminait son travail. Ces délais ne comptent plus ; il faut au moins 5 vraies erreurs (5xx,
-- connexion) dans l'heure. La tâche salle-cron attend désormais 60 s.
-- (appliqué par la migration « taches_surveiller_sans_fausses_alertes » ; extrait de la condition :)
--   select count(*) into n from net._http_response
--    where created > now() - interval '1 hour'
--      and (status_code >= 500 or (status_code is null and coalesce(error_msg,'') not ilike 'Timeout of%'));
--   if n >= 5 then ... alerte ...
select cron.alter_job(job_id := (select jobid from cron.job where jobname='salle-cron'), command := $c$
  select net.http_post(
    url := 'https://mlgzdfyqjhvyubrywuim.supabase.co/functions/v1/salle-cron',
    headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',(select cron_secret from public.bil_config where id = 1)),
    body := '{}'::jsonb, timeout_milliseconds := 60000);
$c$);
