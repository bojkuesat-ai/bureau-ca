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

### Registre des signatures (13/11/2026)
`sql/2026-11-13_signatures_code_verification.sql`. Chaque signature par mot de passe
(procuration, PV, demande Caisse signée, doublon écarté, signature conjointe, gestion
journalière) reçoit un **code de vérification** `XXXX-XXXX-XXXX-XXXX` calculé par le
serveur (HMAC-SHA256 avec le secret de `signatures_secret`, table illisible via l'API)
et consigné dans `signatures_registre` (insertion seule, trigger anti-modification).
- Fonctions appelées par les apps : `procuration_signer`, `procuration_annuler`,
  `procuration_pdf`, `caisse_demande_signer`, `signature_verifier(app, code)`.
- `pvs_envoyer`, `pvs_signer`, `sc_creer`, `sc_signer` enregistrent aussi leur code ;
  `gj_actes` passe par le trigger `gj_actes_code_signature`.
- Les apps vérifient via l'onglet « Vérifier une signature » (CA : tout ; Caisse : ses
  signatures seulement). Les documents signés avant cette date gardent leur ancien code local.
- **Ne jamais exporter ni recopier `signatures_secret`** : sans lui, aucun code n'est
  vérifiable ; s'il fuit, tout le registre peut être falsifié. Il n'est pas dans la sauvegarde.

### Décisions du trésorier (Caisse, 13/11/2026)
`sql/2026-11-13_caisse_decisions_code_verification.sql`. Chaque changement de statut d'une
demande fait par le trésorier (validée, refusée, à corriger, remboursée, remise en attente,
virement rejeté) reçoit lui aussi un code de vérification, inscrit dans `signatures_registre`
(types `decision_*`) par le trigger `zy_caisse_decision_code` sur `requests`.
- `requests.decision_code` = dernière décision ; `requests.decision_codes` = historique.
  Ces colonnes ne sont écrites que par le trigger (valeurs du navigateur ignorées).
- Le code figure dans le panneau de la demande, l'historique et le mail envoyé au membre.
