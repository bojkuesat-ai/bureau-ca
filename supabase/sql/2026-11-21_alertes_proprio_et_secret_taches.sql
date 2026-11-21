-- 21/11/2026
-- 1) Le propriétaire ne reçoit plus les alertes « Nouvel appareil » et « Activité nocturne »
--    des autres (la personne reçoit sa propre alerte de connexion ; tout reste au journal).
--    → public.audit_alerte : les clés 'appareil:%' et 'nuit:%' sautent les adresses du propriétaire.
--    (fonction remplacée par la migration « audit_alerte_sans_proprio_appareil_nuit »)
-- 2) Les tâches planifiées rappels-ca et envois-auto lisent leur secret dans bil_config.cron_secret
--    (illisible depuis les apps) au lieu d'un secret écrit en clair dans la commande :
select cron.alter_job(job_id := (select jobid from cron.job where jobname='rappels-ca'), command := $c$
  select net.http_post(
    url := 'https://mlgzdfyqjhvyubrywuim.supabase.co/functions/v1/rappels',
    headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',(select cron_secret from public.bil_config where id = 1)),
    body := '{}'::jsonb, timeout_milliseconds := 60000);
$c$);
select cron.alter_job(job_id := (select jobid from cron.job where jobname='envois-auto'), command := $c$
  select net.http_post(
    url := 'https://mlgzdfyqjhvyubrywuim.supabase.co/functions/v1/envois-auto',
    headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',(select cron_secret from public.bil_config where id = 1)),
    body := '{}'::jsonb, timeout_milliseconds := 60000);
$c$);
-- 3) À faire dans Supabase : remplacer la valeur de la variable CRON_SECRET des fonctions
--    (l'ancienne figurait en clair dans les tâches) par une valeur au hasard.
