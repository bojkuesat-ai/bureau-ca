# Côté serveur (Supabase)

Copie versionnée de ce qui tourne sur le projet Supabase `mlgzdfyqjhvyubrywuim`.
La source de vérité reste Supabase : après toute modification dans le dashboard,
recopier le code ici.

**Aucun secret dans ce dossier.** Les clés (service role, Amazon SES, `cron_secret`,
`CRON_SECRET`, `SALLE_CRON_SECRET`, `SAUVEGARDE_PHRASE`) sont uniquement dans
Supabase › Edge Functions › Secrets et dans la table `bil_config`.

## functions/ — « Verify JWT » à respecter au déploiement

| Fonction | Verify JWT | Rôle |
|---|---|---|
| `send-email` | **OFF** | Envoi central (Amazon SES). Anti-spam : serveur / membre (500 dest./h) / anonyme (gabarits). Reconnaît les jetons Firebase de l'app QR. |
| `billets-mail` | OFF | Mails de la Billetterie, expéditeur par commission (`bil_commissions.expediteur`). |
| `rappels` | OFF | Rappels de vote / budget / présence. |
| `relance-bilans` | ON | Relance anonyme des bilans moraux. |
| `notifier-auteur` | ON | Avertit l'auteur d'un signalement. |
| `mediation` | OFF | Mails de médiation. |
| `soutien-notif` | OFF | Alerte neutre soutien psy / CES. |
| `envois-auto` | OFF | Cron 10 min : mails programmés, tâches, récap idées. |
| `salle-cron` | OFF | Cron 5 min : salle facultaire. |
| `notifications` | OFF | Web Push. |
| `sauvegarde` | OFF | Sauvegarde chiffrée hebdomadaire. |

`send-email/ancienne-version-v21.ts.txt` = version d'avant le durcissement (retour arrière possible).

### Anti-spam (send-email)
Depuis le 10/11/2026 (v23), `ANON_HTML_TOLERE = false` : avec la seule clé publique,
seuls les gabarits serveur partent. L'app QR (dépôt `qr-verification`, v201) envoie le
jeton Firebase de ses responsables. Remettre à `true` uniquement en cas d'urgence.

## sql/
Scripts exécutés dans l'éditeur SQL, par date. Les scripts plus anciens
(`billetterie.sql`, `journal.sql`, `salle_facultaire.sql`, `double_authentification.sql`,
`soutien*.sql`…) n'ont pas encore été récupérés : les ajouter ici au fur et à mesure.
