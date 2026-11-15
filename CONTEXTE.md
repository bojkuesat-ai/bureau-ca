# CONTEXTE — à lire en premier (nouvelle conversation)

Dernière mise à jour : 15/11/2026. Ce fichier résume l'état des apps et les règles de travail.
Il ne contient **aucun secret** (pas de lien secret, pas de clé, pas de mot de passe).

## 1. Règles de travail (préférences du propriétaire, Esat)

- Réponses **très brèves**, en français.
- Quand il écrit « ne code pas encore » / « réponds en bref » : expliquer, puis **attendre son « go »**.
- Tout concerne **uniquement le CA**. La Caisse est réservée aux membres du CA. Rien pour l'extérieur.
- Tester les changements serveur dans une **transaction annulée** (bloc `do $$ … raise exception 'TEST …' $$`).
- Après une modification : contrôle de syntaxe, commit, push, puis vérifier que la publication a réussi.
- Ne jamais écrire le lien secret du propriétaire dans le dépôt (seul son hash est en base).

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
- **Publication** : GitHub Pages (`https://bojkuesat-ai.github.io/bureau-ca/`). Les pages restent en cache environ 10 minutes. En cas de doute, ajouter `?v=…` à l'adresse.
- La version affichée dans l'app CA est la constante `CA_VERSION` dans `index.html`.

## 3. Rôles et droits

- `ca_membres.role` : `coopte`, `membre`, `owner` (le propriétaire tant qu'il est au CA), `proprietaire` (le propriétaire après la passation).
- `ca_membres.admin` (booléen) : Admin délégué. `hors_ca` : la personne ne compte pas dans l'effectif du CA.
- `profiles.role = 'tresorier'` (avec `approved`) : trésorier de la Caisse.
- Fonctions SQL :
  - `ca_is_owner()` : rôle owner, avec double authentification si elle est activée ;
  - `proprio_est()` : owner ou proprietaire ;
  - `proprio_exiger()` : refuse si ce n'est pas le propriétaire ;
  - `ca_est_admin()` : owner, ou Admin actif ;
  - `ca_est_tresorier()`, `is_tresorier()` : trésorier ;
  - `mfa_ok()` : code à 6 chiffres déjà donné (aal2), ou aucun facteur activé ;
  - `a_mfa(uuid)` : la personne a un facteur vérifié.
- Côté page CA : `estProprioCA()`, `estAdminCA()`, `estTresoCA()`, `proprioOuvert()`.
- Pour qu'une fonction du propriétaire contourne les gardes, dans une transaction : `set_config('app.proprio_bypass','1',true)`.

## 4. Propriété, licences, Transparence (en place)

- **Espace Propriétaire** derrière un lien secret, détecté au chargement par `lireLienSpecial()` (ainsi que lors d'un changement d'ancre `#`).
- **Licence** : l'Admin la demande, le propriétaire l'approuve après paiement. À l'échéance, les apps passent en lecture seule. Mails envoyés par `licence_mail(to, sujet, html)` avec l'expéditeur « Licence-BE ».
- **Modules en option** et état de chaque app (ouverte, lecture seule, fermée) : `app_etat`, `app_lecture_ok`, `app_garde`.
- **Transparence** : page visible par tous, historique non modifiable. Mails à la passation et à toute reprise d'accès par le propriétaire.

## 5. Passation (à faire prochainement)

- Fonction : `proprio_passation(p_personne, p_cosign)`. Personne prévue : **Rania Drissi** (présidente, Admin et trésorière par intérim). Cosignataire prévu : **Hamza El Fartakhe**.
- Effets :
  - la personne devient Admin et trésorière, et l'adresse du trésorier de la Caisse est mise à jour ;
  - le propriétaire passe en `role='proprietaire'` et `hors_ca` ;
  - les mails de gestion sont désactivés ;
  - les abonnements push du propriétaire sont supprimés (le déclencheur `a_pas_proprietaire` refuse aussi les nouveaux) ;
  - un **guide complet** part par mail à la personne : `passation_guide_html(prenom)`.
- Après la passation, le propriétaire :
  - n'a plus accès au contenu du CA ni de la Caisse ;
  - ne garde que l'espace Propriétaire (licences, état des apps, modules, réglages techniques, zone dangereuse) ;
  - ne reçoit plus aucun mail du CA ni de la Caisse : un filtre dans `send-email` les bloque, sauf l'expéditeur « Licence-BE » et l'objet « 🔐 Nouvelle connexion ». Les réponses vont à l'Admin.
- L'Admin peut nommer le prochain trésorier (`proprio_set_tresorier`) et le cosignataire (`proprio_set_gj_cosignataire`).
- La phrase secrète des sauvegardes est remise **en main propre** par Esat.

## 6. Mails

- Fonction Edge `send-email` (v24). À déployer avec **vérification JWT désactivée**, car elle fait son propre contrôle :
  - **serveur** : clé secrète, ou en-tête `x-cron-secret` (valeur `bil_config.cron_secret`) ;
  - **membre** : membre du CA, compte Caisse approuvé ou compte Firebase de l'app QR ;
  - **anonyme** : uniquement les modèles de mail prévus, avec des limites.
- Chaque envoi est noté dans `mail_envois` (sans le contenu).
- Envoi depuis une fonction SQL : `net.http_post` vers `/functions/v1/send-email` avec `x-cron-secret` (modèle : `licence_mail`).
- Expéditeurs utilisés : « Sécurité-BE », « Licence-BE », « Bureau étudiant ». Adresse : `noreply@bureauetuidant.xyz`.

## 7. Double authentification (OBLIGATOIRE au 19/11/2026)

- Décidé le 15/11 : obligatoire pour **tous les membres du CA** (pas les cooptés), Espace CA **et** Caisse.
- À activer au plus tard le **mercredi 18/11/2026 à 23 h 59** ; blocage le **jeudi 19/11 à 00 h** (`proprio_config.mfa_obligatoire_le`).
- Annonce unique « Sécurité-BE » le **lundi 16/11 à 10 h** (pas de rappel). Point le mercredi 18/11 à 18 h à l'Admin et au propriétaire.
- Bilan au propriétaire seul le jeudi 19/11 à 9 h. Confirmation d'activation : envoyée seulement à la personne concernée.
- Bandeau avec compte à rebours, puis écran d'activation guidé. Contrôle serveur (`mfa_ok`, `mfa_exige_moi`) : une session restée ouverte est refusée aussi.
- Téléphone perdu : remise à zéro par l'Admin (onglet Admin) ou le propriétaire (espace Propriétaire). Mail de confirmation à chaque activation / retrait.
- Détails : `supabase/README.md`.

## 8. Caisse : points notables

- Décision en une étape côté serveur (`deciderServeur`), avec code de vérification sur les décisions du trésorier.
- Traitement des demandes à la chaîne, lecture des tickets (OCR, tesseract.js), onglets regroupés par rubriques.
- **Budgets** : approuvés ou refusés par le **trésorier** (`bPeutDecider`, politique `ca_bud_upd`, garde `ca_budgets_garde_decision`). Règle de quorum de l'article 16.2 : `ca_budget_regle162_ok`.
- Effectif du CA (`membresCAActifs`) : sans le propriétaire retiré ni les membres `hors_ca`.

## 8 bis. Fin de mandat programmée (01/07/2027)

- 01/06/2027 10 h : prévenance de tous les membres. 24/06/2027 10 h : zips « archives du CA » et « comptabilité de la Caisse » → présidente, secrétaire, trésorier (liens 30 jours), copies dans l'espace Propriétaire (Télécharger / Renvoyer / Aperçu).
- 01/07/2027 00 h : sauvegarde finale chiffrée, puis TOUT est vidé (comptes sauf le propriétaire, données CA + Caisse + Billetterie, fichiers, registre des signatures, Transparence, journaux). Mail d'adieu.
- Restent seulement les tables de `fin_mandat_garder` (réglages techniques) : **y ajouter toute nouvelle table de réglages**.
- Détails : `supabase/README.md` (section « Fin de mandat »), fonction Edge `fin-mandat`.

## 9. Idées restantes (pas demandées pour l'instant)

- Bloquer les mots de passe ayant fuité (réglage Auth de Supabase).
- Relances automatiques pour les preuves.
- Alerte en cas de changement d'IBAN.
- Export SEPA.
- Récapitulatif mensuel.
