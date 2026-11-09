# Côté serveur (Supabase)

Copie versionnée de ce qui tourne sur le projet Supabase `mlgzdfyqjhvyubrywuim`.
La source de vérité reste Supabase : après toute modification dans le dashboard,
recopier le code ici.

**Aucun secret dans ce dossier.** Les clés (service role, Amazon SES, `cron_secret`)
sont uniquement dans Supabase › Edge Functions › Secrets et dans la table `bil_config`.

## functions/
- `billets-mail/index.ts` — tous les mails de la Billetterie (déployer avec « Verify JWT » désactivé).
  Nom d'expéditeur par commission : colonne `bil_commissions.expediteur`, repli « Billetterie-BE ».

## sql/
Scripts exécutés dans l'éditeur SQL, par date. Les scripts plus anciens
(`billetterie.sql`, `journal.sql`, `salle_facultaire.sql`, `double_authentification.sql`,
`soutien*.sql`…) n'ont pas encore été récupérés : les ajouter ici au fur et à mesure.
