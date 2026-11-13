-- =====================================================================
-- Salle facultaire (13/11/2026) — la tâche planifiée tourne enfin.
-- Appliqué sur le projet. Avant : la tâche envoyait le texte « MOTDEPASSE »
-- comme secret et salle-cron répondait 403 toutes les 5 minutes (aucun rappel,
-- aucun blocage, aucune purge de photos). Désormais la tâche lit le secret
-- interne (bil_config.cron_secret) au moment de l'appel ; salle-cron (v7)
-- l'accepte. Aucun secret n'est écrit en clair dans cron.job.
-- =====================================================================
select cron.alter_job(12, command := $cmd$
  select net.http_post(
    url := 'https://mlgzdfyqjhvyubrywuim.supabase.co/functions/v1/salle-cron',
    headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',(select cron_secret from public.bil_config where id = 1)),
    body := '{}'::jsonb);
$cmd$);
