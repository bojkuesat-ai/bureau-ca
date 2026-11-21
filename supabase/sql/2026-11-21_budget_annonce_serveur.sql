-- 21/11/2026 — Annonce d'un nouveau budget envoyée par le serveur (fonction « rappels »)
-- Avant : le navigateur de la personne envoyait les mails un par un ; si elle fermait
-- la page, le reste ne partait pas (5 mails sur 19 pour « Concours de Noël »).
-- annonce_le : date de l'annonce ; nulle = pas encore annoncé (l'app ou le cron l'envoie, une seule fois).
alter table public.ca_budgets add column if not exists annonce_le timestamptz;
comment on column public.ca_budgets.annonce_le is 'Mail « Nouveau budget soumis au vote » envoyé par le serveur (fonction rappels) — un seul envoi';
update public.ca_budgets set annonce_le = created_at where statut <> 'vote' and annonce_le is null;
