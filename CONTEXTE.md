# CONTEXTE — à lire en premier (nouvelle conversation)

Dernière mise à jour : 15/11/2026 (nuit). Ce fichier résume l'état des apps et les règles de travail.
Il ne contient **aucun secret** (pas de lien secret, pas de clé, pas de mot de passe).

## 1. Règles de travail (préférences du propriétaire, Esat)

- Réponses **très brèves**, en français.
- Quand il écrit « ne code pas encore » / « réponds en bref » : expliquer, puis **attendre son « go »**.
- Tout concerne **uniquement le CA**. La Caisse est réservée aux membres du CA. Rien pour l'extérieur.
- Tester les changements serveur dans une **transaction annulée** (bloc `do $$ … raise exception 'TEST …' $$`).
  Supabase peut demander une confirmation à l'utilisateur : s'il ne répond pas, le dire et attendre.
- Après une modification : contrôle de syntaxe, commit, push, puis vérifier que la publication a réussi (`gh run list`).
- Ne jamais écrire le lien secret du propriétaire dans le dépôt (seul son hash est en base).
- Pour pousser sur GitHub depuis une nouvelle session : ajouter le dépôt `bojkuesat-ai/bureau-ca` (accès « push »).

## 2. Où est quoi

| Élément | Emplacement |
|---|---|
| Espace CA | `index.html` (racine) |
| Caisse | `caisse/index.html` |
| Billetterie | `billets/` |
| Service worker (réseau d'abord) | `sw.js` |
| SQL (documentation des migrations, déjà appliquées) | `supabase/sql/*.sql` |
| Fonctions serveur (Edge, Deno) | `supabase/functions/<nom>/index.ts` |
| Notes détaillées par fonctionnalité | `supabase/README.md` |
| Contrôle de syntaxe | `node .github/verifier-syntaxe.mjs` (nécessite `esbuild` : `npm install --no-save esbuild@0.24.2`) |

- **Supabase** : projet `mlgzdfyqjhvyubrywuim` (base, Auth, fonctions Edge, `pg_cron`, `pg_net`).
- **Publication** : GitHub Pages (`https://bojkuesat-ai.github.io/bureau-ca/`). Cache d'environ 10 minutes ; en cas de doute, ajouter `?v=…`.
- Version affichée dans l'app CA : constante `CA_VERSION` dans `index.html` (actuellement « 2026-11-15 · fin de mandat programmée »).

## 3. Rôles et droits

- `ca_membres.role` : `coopte`, `membre`, `owner` (le propriétaire tant qu'il est au CA), `proprietaire` (après la passation).
- `ca_membres.admin` (booléen) : Admin délégué. `hors_ca` : ne compte pas dans l'effectif du CA.
- `profiles.role = 'tresorier'` (avec `approved`) : trésorier de la Caisse.
- Aujourd'hui : Esat = owner, fonction « Trésorier », trésorier de la Caisse. Rania Drissi = « Président » (fonction CA).
- Fonctions SQL :
  - `ca_is_owner()`, `proprio_est()` (owner ou proprietaire), `proprio_exiger()` ;
  - `ca_est_admin()` : owner, ou Admin actif ; `ca_est_tresorier()`, `is_tresorier()` : trésorier ;
  - `mfa_ok()` = `mfa_ok_base()` (code donné si facteur) **et** `not mfa_exige_moi()` (obligation du 19/11) ;
  - `a_mfa(uuid)`, `mfa_concerne(uuid)` (membre du CA, pas coopté).
- Côté page CA : `estProprioCA()`, `estAdminCA()`, `estTresoCA()`, `proprioOuvert()`, `estCoopte()`.
- Contourner les gardes dans une fonction du propriétaire : `set_config('app.proprio_bypass','1',true)`.

## 4. Propriété, licences, Transparence (en place)

- **Espace Propriétaire** derrière un lien secret (`lireLienSpecial()`), contient aussi : suivi double authentification, **Fin de mandat**.
- **Licence** : l'Admin la demande, le propriétaire l'approuve. À l'échéance, lecture seule. Mails : `licence_mail` (expéditeur « Licence-BE »).
- **Modules en option** et état des apps : `app_etat`, `app_lecture_ok`, `app_garde`, `app_refus_motif`.
- **Transparence** : page visible par tous, historique non modifiable.

## 5. Passation (à faire prochainement)

- `proprio_passation(p_personne, p_cosign)`. Personne prévue : **Rania Drissi**, cosignataire **Hamza El Fartakhe**.
- **Attention** : Rania **reste présidente dans le CA** ; elle devient seulement Admin et **trésorière par intérim dans la Caisse**. La passation ne touche pas à sa fonction CA (vérifié).
- Effets : Admin + `profiles.role='tresorier'` + adresse du trésorier ; le propriétaire passe `proprietaire` + `hors_ca` ; mails de gestion coupés ; push supprimés ; guide `passation_guide_html` envoyé.
- Après : le propriétaire ne garde que l'espace Propriétaire et ne reçoit plus de mails du CA/Caisse (filtre `send-email`) **sauf** expéditeur « Licence-BE » et objet « 🔐 Nouvelle connexion ». → Tout mail destiné au propriétaire doit partir en « Licence-BE ».
- La phrase secrète des sauvegardes est remise **en main propre** par Esat.

## 6. Mails

- Fonction Edge `send-email` (v24), **vérification JWT désactivée** (contrôle propre : `x-cron-secret` = `bil_config.cron_secret`, membre, ou anonyme limité).
- Envoi depuis SQL : `net.http_post` vers `/functions/v1/send-email` avec `x-cron-secret`. Aides : `licence_mail`, `mfa_mail` (Sécurité-BE), `fm_mail(to, sujet, html, expéditeur)`.
- Expéditeurs : « Sécurité-BE », « Licence-BE », « Bureau étudiant », « Documents-BE ». Adresse : `noreply@bureauetuidant.xyz`.

## 7. Double authentification — OBLIGATOIRE le 19/11/2026

- Pour **tous les membres du CA** (pas les cooptés), Espace CA **et** Caisse. Au 15/11 : 2/19 l'ont activée (Esat, Pierre Defrenne).
- À faire au plus tard **mercredi 18/11/2026 23 h 59** ; blocage **jeudi 19/11 00 h** (`proprio_config.mfa_obligatoire_le`).
- Serveur : les 81 politiques restrictives `mfa_aal2` refusent tout sans code (même une session ouverte) ; `ca_membres`/`profiles` : seule sa ligne reste lisible ; `app_refus_motif` bloque les écritures des fonctions.
- Pages (même module dans les 2 apps) : bandeau avec compte à rebours, puis écran d'activation guidé (QR, clé à copier, astuce 2e appareil, aide). L'ancienne invitation facultative est coupée.
- Tâches planifiées :
  - `mfa_annonce_1611` : **lundi 16/11 10 h**, une seule annonce (pas de rappel) ;
  - `mfa_point_1811` : mercredi 18/11 18 h, retardataires → Admin + propriétaire ;
  - `mfa_rapport_1911` : **jeudi 19/11 9 h**, bilan au propriétaire seul (Licence-BE) ;
  - `mfa-suivi` (5 min) : mail de confirmation / alerte **uniquement à la personne concernée**.
- Admin › Double authentification (et espace Propriétaire) : liste, « Relancer », « Remettre à zéro » (téléphone perdu ; déconnecte, Journal, mail).

## 8. Caisse : points notables

- Décision en une étape côté serveur (`deciderServeur`), code de vérification sur les décisions du trésorier.
- Traitement à la chaîne, OCR des tickets, onglets regroupés par rubriques (`RUBRIQUES`).
- **Budgets** : approuvés ou refusés par le **trésorier**. Quorum article 16.2 : `ca_budget_regle162_ok`.

## 9. Espace CA : ajouts du 14-15/11

- **Onglets désactivables** dans Admin (`ONGLETS_OPTIONNELS`, `ca_meta.onglets_off`) : Organigramme et Contacts **désactivés**.
- Le regroupement des onglets CA en rubriques a été **écarté** par Esat.
- **✒ Courriers signés** (activé par défaut, coupable dans Admin) : tout membre du CA (pas les cooptés) tape un courrier ou joint un PDF/Word/PPT, le signe (mot de passe + code), envoi à tout le CA. Qualité lue sur le serveur (fonction CA + « Trésorerie de la Caisse » si trésorier). Table `ca_courriers`, `courrier_signer`, `courrier_finaliser`, code au registre (type `courrier`).

## 10. Fin de mandat programmée — 01/07/2027

- **01/06/2027 10 h** : prévenance de tous les membres.
- **24/06/2027 10 h** : zips « Archives du CA » et « Comptabilité de la Caisse » → présidente, secrétaire, trésorier (liens 30 jours). Copies dans l'espace Propriétaire (Télécharger, **Renvoyer**, **Aperçu**).
- **01/07/2027 00 h** : sauvegarde finale chiffrée, puis **tout est vidé** (comptes sauf le propriétaire, données CA + Caisse + Billetterie, fichiers, registre des signatures, Transparence, journaux). Mail d'adieu, rapport au propriétaire.
- Rien n'est supprimé sans archives envoyées **et** sauvegarde faite. Tâche `fin-mandat` (10 min), fonction Edge `fin-mandat`, SQL `fin_mandat_*`.
- **Toute nouvelle table de réglages à garder doit être ajoutée à `fin_mandat_garder`**, sinon elle sera vidée.
- À faire par Esat : cliquer « Aperçu » pour vérifier le contenu des zips (pas encore testé en réel).

## 10 bis. Billetterie : liens de scan (15/11)

- Le code bénévole est supprimé. À la place : **📲 Liens de scan** (un par personne, 24 h, événements du jour ; « tous » réservé à l'Admin/propriétaire). Le lien ne permet que scanner + chercher un nom. Table `bil_scan_liens`, fonctions `bil_scan_lien_*`.

## 10 ter. Billetterie (15/11, suite)

- Un seul billet par adresse ; « Écrire aux inscrits » ; « Annuler l'événement » (mails + demandes de remboursement dans la Caisse, IBAN repris du virement ou demandé par lien `?r=`) ; rapprochement des virements par import CSV (Billetterie et Caisse › Extraits) ; preuve de paiement facultative ; « Céder ma place » jusqu'au début. Détails : `supabase/README.md`.
- Supabase demande une confirmation pour les scripts avec `drop` : Esat doit rester devant l'écran et cliquer « Autoriser ».

## 11. Idées restantes (pas demandées pour l'instant)

- Bloquer les mots de passe ayant fuité (réglage Auth de Supabase).
- Relances automatiques pour les preuves ; alerte en cas de changement d'IBAN ; export SEPA ; récapitulatif mensuel.
