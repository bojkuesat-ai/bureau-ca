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

### Contrôles des signatures Caisse (13/11/2026)
`sql/2026-11-13_caisse_signatures_controles.sql`.
- `signature_verifier` signale une demande **modifiée après signature** (`modifie_apres`,
  `champs_modifies`, `actuel`) ou **supprimée** (`supprimee`). La signature reste valide.
- Décisions du trésorier : un changement de statut n'est accepté que si le mot de passe a été
  retapé dans les 5 minutes (`caisse_mdp_ouvrir` → table `caisse_mdp_frais`, contrôlé par le
  trigger `zy_caisse_decision_code`). Les tâches serveur (sans utilisateur) ne sont pas concernées.

## Vérification automatique
`.github/workflows/verification.yml` contrôle la syntaxe des pages et des fonctions Edge à
chaque push (croix rouge et mail en cas d'erreur ; le site est publié quand même).

### Décision du trésorier en une étape (Caisse, 13/11/2026)
`sql/2026-11-13_caisse_decider.sql`. `caisse_decider(id, statut_attendu, patch, évènement, mail)` :
statut + historique (`events`, nom lu sur le serveur) + code de vérification + mail au membre
(`caisse_envoyer_mail` via pg_net, adresse lue sur le serveur) dans **une seule transaction**.
Statut différent de celui attendu → `conflit`, rien n'est écrit ni envoyé. Champs modifiables
limités (status, decision_note, decided_at, paid_at, pay_mode, attachments, reexamen_*, exported_at).
Le texte du mail vient de l'app ; `{{CODE_DECISION}}` y est remplacé par le code délivré.
- `caisse_mails.net_id` : référence de l'envoi ; `caisse_mail_statut(ids)` le lit (l'app prévient
  le trésorier si le mail n'est pas parti) ; tâche `caisse-mails-statuts` (*/10) reporte ok/erreur.
- Utilisée par : décision dans le panneau, validation et paiement par lot, série de virements
  (qui ne marque plus que les demandes encore « Validée »).

### Lecture des tickets (Caisse, 13/11/2026)
`caisse/lib/ocr/` : tesseract.js 7 + modèle français, chargés seulement quand une photo est jointe.
Lecture dans le navigateur (rien n'est envoyé). La page autorise `'wasm-unsafe-eval'` (WebAssembly).

### Alerte « Nouvelle connexion » au titulaire du compte (CA + Caisse, 13/11/2026)
`sql/2026-11-13_alerte_nouvel_appareil.sql`. Dans `audit_noter` (connexion) : si l'appareil
(`be:appareil-id`) n'a jamais été vu pour ce compte, mail de Securite-BE **à la personne**
(app, appareil, heure, IP). Une alerte par appareil, toutes apps confondues (CA et Caisse ;
la Billetterie n'est pas concernée). Table `securite_appareils` ; premier appareil d'un compte
et appareils déjà présents dans le journal : sans mail ; 5 alertes max par compte et par heure.
L'alerte au propriétaire (« 🚨 Nouvel appareil — … ») existait déjà et n'a pas changé.

### Propriétaire, Admin, état des apps, modules, licences (13/11/2026)
`sql/2026-11-13_proprietaire_licences.sql` (en-tête = mode d'emploi complet).
- **Propriétaire** (`ca_membres.role = 'owner'`) : espace « 🔑 Propriétaire » du CA, ouvert par un
  **lien secret** (`#proprietaire=…`, hash dans `proprio_config.lien_hash`) + connexion + 2FA.
  Licences, état des apps, modules, fonctions (Admin, trésorier, cosignataire GJ, « hors CA »),
  réglages techniques (2FA, sauvegardes, page d'erreur, onglets, CES, zone dangereuse, export).
- **Admin délégué** (`ca_membres.admin`) : onglet Admin (comptes, coopté·es, bilans, droits, liste e-mail).
- **Trésorier** (`profiles.role`) nommé par le propriétaire ; décide aussi des budgets du CA.
- **Blocage serveur** : trigger `a0_app_garde` + politique `app_fermee` sur les tables de `app_tables`.
- **Licence** : `licence_demander` → mail au propriétaire → `proprio_licence_approuver` → lien
  `#licence=…` → `licence_activer` (le demandeur devient Admin) ; rappels `licence-rappels` (07:13 UTC).

## Double authentification obligatoire, budgets du trésorier, guide de passation (13/11/2026)

Fichier : `sql/2026-11-13_mfa_obligatoire_passation_guide.sql` (migrations `proprio_9`, `proprio_10`).

- Double authentification : **facultative** (retour en arrière le 14/11/2026, migrations `proprio_11` et `proprio_12`). Un bandeau discret la propose aux membres du CA (« Plus tard » pour le masquer). Elle reste exigée pour qui l'a activée.
- Budgets de la Caisse : approuvés ou refusés par le trésorier. L'effectif du CA exclut le propriétaire retiré et les membres « hors CA ».
- Passation : le guide complet part par mail à la nouvelle Admin / trésorière ; les notifications push du propriétaire sont supprimées.
- `send-email` v24 : après la passation, le propriétaire ne reçoit plus aucun mail du CA ni de la Caisse (sauf licence et « Nouvelle connexion »). Les réponses vont à l'Admin.

## Invitation à la double authentification (14/11/2026)

- Mail unique « Sécurité-BE » le samedi 14/11/2026 à 10:00 (tâche `mfa_invitation_1411`, fonction `mfa_invitation_envoyer()`), seulement aux membres actifs du CA (pas les coopté·es) sans double authentification. La table `mfa_invitations` empêche tout second envoi ; la tâche se supprime après l'envoi.
- Espace CA et Caisse : bandeau pour les membres du CA tant qu'elle n'est pas activée, et popup une seule fois (par compte et par appareil). Personne hors du CA ne voit rien.
