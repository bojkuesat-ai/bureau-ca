# CONTEXTE — à lire en premier (nouvelle conversation)

Dernière mise à jour : 17/11/2026 (22 h 30).
Il ne contient **aucun secret** (pas de lien secret, pas de clé, pas de mot de passe).

## 1. Règles de travail (préférences du propriétaire, Esat)

- Réponses **très brèves**, en français.
- Quand il écrit « ne code pas encore » / « réponds en bref » : expliquer, puis **attendre son « go »**.
- Tout concerne **uniquement le CA**. La Caisse est réservée aux membres du CA. Rien pour l'extérieur.
- Tester les changements serveur dans une **transaction annulée** (bloc `do $$ … raise exception 'TEST …' $$`).
  Supabase peut demander une confirmation à l'utilisateur : s'il ne répond pas, le dire et attendre.
- Après une modification : contrôle de syntaxe, commit, push, puis vérifier que la publication a réussi (`gh run list`).
- Supabase demande une **confirmation** pour les scripts contenant `drop` : prévenir Esat avant, il clique « Autoriser » (sinon la demande est annulée).
- Fonction Edge : la déployer avec le **contenu complet** du fichier, puis relire la version en ligne et la comparer au dépôt.
- Ne pas inventer de chiffres d'exemple : donner les vrais chiffres (requête SQL) ou dire clairement « exemple ».
- Libellés : utiliser **exactement** les mots demandés par Esat, sans ajouter de détail entre parenthèses.
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
- Version affichée dans l'app CA : constante `CA_VERSION` dans `index.html` (actuellement « 2026-11-17 · simulation : annonce à l'activation »).

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

- **Classement des dépenses payées** (15/11) — mêmes 4 cases dans **Compta**, **Aperçu** et **À traiter** (aucun nom affiché) :
  - **Événements et activités** : remboursements aux membres + paiements directs catégorie « Événement / activité » ;
  - **Codes et syllabus** : catégorie « Codes & syllabus » ou fournisseur Kluwer / die Keure / Larcier / PUB (`RE_CODES_SYLLABUS`) ;
  - **Fonctionnement** : catégorie « Fonctionnement » (salle, entretien, administratif) ;
  - **Événements annulés** : remboursements de billets (catégorie « Billetterie »).
  - Fonctions : `ligneCompta()`, `afficherLignesCompta()`, `LIGNES_COMPTA` (caisse/index.html).
- **Catégorie obligatoire** pour tout paiement direct (formulaire `#fd_cat`, facture à échéance payée, dépense attribuée) + fenêtre de confirmation (`demanderCategorie`).
- Au 15/11 : Événements et activités 4 681,95 € · Codes et syllabus 9 321,83 € · Fonctionnement 1 119,93 € · Événements annulés 0 €.
- Factures PUB (impressions syllabus, ≈ 7 400 €) et Larcier (estimation 3 000 €) **en attente** dans « Factures à échéance » → iront dans Codes et syllabus une fois payées.
- Extraits › « Paiements de billets reçus » : import CSV → rapprochement Billetterie.
- **Factures émises (21/11)** — onglet **« Factures émises »** (rubrique Demandes, à côté de « Factures à échéance » ; même vue que Documents en mode `factem`, l'onglet Documents ne garde que les bons de commande ; pastille = factures en retard) :
  - « Ajouter plusieurs factures à la fois » : plusieurs PDF d'un coup, lecture auto (n°, client, TVA client, date, échéance, montant, communication structurée) → tableau à vérifier → enregistrement (`docLireVente`, `docLotRender`).
  - « Paiements » : compare les virements reçus des extraits CSV ING déposés (ou d'un fichier) aux factures ouvertes : communication structurée (+++ ou ***), puis n° de facture, puis nom + montant, puis montant seul (« à vérifier »). Listes : payées, payées en partie, à vérifier, échéance dépassée, pas encore échues (`docRapprocher`, `docPayRender`).
  - Liste en deux groupes : « Pas encore encaissées » (retards d'abord) et « Déjà encaissées » (encaissées + payées trouvées dans la Caisse ou les extraits, tag « Payée · à confirmer », bouton « Relier à la recette » / « Encaisser »). Les extraits CSV déposés sont lus automatiquement à l'ouverture de l'onglet.
  - Encaissement en plusieurs fois : colonnes `caisse_documents.communication`, `montant_recu`, `paiements` (SQL 2026-11-21). La recette porte « [mouvement N] » ; une recette déjà encodée pour ce virement est reliée, pas doublée.

- Décision en une étape côté serveur (`deciderServeur`), code de vérification sur les décisions du trésorier.
- Traitement à la chaîne, OCR des tickets, onglets regroupés par rubriques (`RUBRIQUES`).
- **Budgets** : approuvés ou refusés par le **trésorier**. Quorum article 16.2 : `ca_budget_regle162_ok`.

## 9. Espace CA : ajouts du 14-15/11

- **Onglets désactivables** dans Admin (`ONGLETS_OPTIONNELS`, `ca_meta.onglets_off`) : Organigramme et Contacts **désactivés**.
- Le regroupement des onglets CA en rubriques a été **écarté** par Esat.
- **✒ Courriers signés** (activé par défaut, coupable dans Admin) : tout membre du CA (pas les cooptés) tape un courrier ou joint un PDF/Word/PPT, le signe (mot de passe + code), envoi à tout le CA. Qualité lue sur le serveur (fonction CA + « Trésorerie de la Caisse » si trésorier). Table `ca_courriers`, `courrier_signer`, `courrier_finaliser`, code au registre (type `courrier`).

## 9 bis. Simulation budget (16/11)

- Onglet **€ Simulation budget** de l'Espace CA, **désactivé par défaut** : Admin › Simulation budget (`ca_meta.simu_budget_actif`, fonction `simu_budget_activer`).
- Calcul serveur `simu_budget_calcul(p_montant)` : trésorerie libre = solde de la caisse (ASBL, hors Novelles) − factures à échéance non payées − estimations − reste des budgets approuvés ouverts − remboursements en cours hors budget. Budgets **clôturés ou gelés** (réserve suspensive non levée) : seules les demandes déjà en cours comptent.
- Faisable si montant ≤ **20 %** de la trésorerie libre. **Dérogation (17/11)** : Admin › « Autoriser quand même… » (`ca_meta.simu_derog`) → limite = plafond saisi (`simu_plafond`) sinon 20 % de (solde − budgets en cours, hors factures). Calcul commun : `simu_budget_chiffres()`. Le maximum n'est affiché que si ce n'est pas faisable.
- **ODJ** : simulation activée → chaque demande de budget est vérifiée (`reu_budget_controle` dans `ca_reunions_garde`) ; faisable = point ajouté + « Simulation du … : faisable » dans la note ; pas faisable = refusé avec le maximum. Faisable ou non : PDF à tous les membres du CA (Budget-BE) ; pas faisable = le maximum est indiqué. Envoi après confirmation.

## 9 ter. Réunions : sujets, ODJ et signature du PV (17/11)

- **Ajouter un point** : choisir un sujet (`REU_SUJETS` / `reu_sujets()`), note facultative. Demande de budget : objet + montant obligatoires. Autre : titre obligatoire. Clôture **la veille à 23 h 59** (heure de Bruxelles), sauf secrétariat. Règles vérifiées par `ca_reunions_garde`. Cooptés : aucun accès (règle `pas_les_cooptes`).
- Réunion : **date + heure** obligatoires (`ca_reunions.heure`). Lien `?go=reunion&r=<id>` dans la convocation et les rappels (expéditeur **Réu-BE**). Aucun rappel automatique : bouton manuel du secrétariat.
- **ODJ 1 h avant** : cron `reunion-odj` (toutes les 5 min) → `reu_odj_envoyer()`, une fois par réunion (`odj_envoye_at`), aux membres du CA actifs (pas cooptés, pas hors CA, pas désabonnés), expéditeur **ODJ Réu-BE**.
- **PV** : plus de bouton « approuvé ». La secrétaire clique « ✍ Signer le PV et l'envoyer à la présidente / au vice-président » (mot de passe puis MFA, `pvs_envoyer` avec le PV généré). Affichage des signatures via `reu_pv_etats()`. Pendant la signature et après : réunion **verrouillée** (`reu_pv_verrouille`). « Retirer de la signature » = `pvs_retirer` (passe en refusé, motif « Retiré… »). PV signé → Documents « PV & CR ».
- Tous les mails de signature de PV : expéditeur **Signature PV du BE** (`EXP_PVSIGN`).

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

## 10 quater. Journal et Transparence (15/11)

- Les connexions et actions du propriétaire (`owner` et `proprietaire`) ne sont **jamais** enregistrées ni visibles par l'Admin ; Transparence n'affiche plus de liste de connexions.
- À corriger si Esat le veut : la page RGPD du CA dit que seul « le propriétaire » consulte le journal (en réalité l'Admin aussi).

## 11. Idées restantes (pas demandées pour l'instant)

- Bloquer les mots de passe ayant fuité (réglage Auth de Supabase).
- Caisse : relances automatiques des preuves ; alerte en cas de changement d'IBAN ; récapitulatif mensuel ; petite caisse en espèces ; clôture d'exercice.
- Espace CA : registre des décisions, sondage de disponibilités, assiduité, rapport d'activité, élections du prochain CA, inventaire, partenaires, recherche globale, guide des fonctions.
- Billetterie : plusieurs tarifs, liste d'invités, codes promo (pas demandés).

## Budgets : annonce par le serveur (21/11/2026)
- Le mail « Nouveau budget/projet soumis au vote » part de la fonction `rappels` (serveur), plus du navigateur : tous les membres du CA (hors cooptés), expéditeur **« Budget à voter-BE »** (aussi pour les rappels de budget).
- L'app appelle `rappels` avec `{type:"budget", id, annonce:true}` juste après la création ; le cron `rappels-ca` (15 min) rattrape tout budget « vote » dont `ca_budgets.annonce_le` est vide. Un seul envoi (réservation sur `annonce_le`).

## Dossier de contrôle complet (21/11/2026)
- PDF + ZIP : remboursements, paiements directs, dépenses **et recettes** (REC-xxx, avec la facture émise liée), chacune avec toutes ses pièces (factures, preuves de paiement…). Totaux séparés sorties / entrées.
- ZIP en plus : `Factures-emises/`, `Bons-de-commande/`, `Factures-a-echeance/` (+ `factures-a-echeance.csv`), `Extraits-de-compte/` (extraits déposés couvrant la période), `recapitulatif.csv`, `documents.csv`, `dossier-de-controle.pdf`.
- Extraits : chaque CSV déposé a des boutons **Excel** et **PDF** (fabriqués dans le navigateur depuis le CSV ING : `exOperations`, `exVersXlsx`, `exVersPdf`). Dans le ZIP, `Extraits-de-compte/` contient le CSV + son .xlsx + son .pdf.
- ZIP : `Extraits-de-compte/operations/` = **une fiche PDF par opération bancaire** de la période, rapprochée d'une écriture de la Caisse (n° de mouvement puis même montant à 7 j près, `dosRapprocherOps`), suivie de ses justificatifs ; sans correspondance : nom de fichier `_SANS-ECRITURE` et mention rouge. Tableau `operations.csv`.
- ZIP : `Extraits-de-compte/operations/` = **une fiche PDF par opération bancaire** de la période (date, n°, montant, contrepartie, compte, communication, libellé) — `dosFicheOperation` ; tableau `operations.csv`. Pas de rapprochement avec la Caisse dans ces fiches (choix du 21/11).
- ZIP : en plus, `Extraits-de-compte/operations-avec-justificatifs/` = la même fiche rapprochée d'une écriture de la Caisse (n° de mouvement, sinon même montant à 7 j près — `dosRapprocherOps`) et suivie de ses justificatifs ; `_SANS-ECRITURE` si rien trouvé ; tableau `operations-avec-justificatifs.csv`.

## Envois groupés par le serveur : fonction `diffuser` (21/11/2026)
- `envoyerNotifCA`, `envoyerNotifCAListe`, `envoyerAvecPiece`, l'annonce urgente et `notifEvenementCA` appellent la fonction `diffuser` (mode `ca` : destinataires calculés côté serveur ; mode `liste` : 300 adresses max). La boucle d'envoi tourne sur le serveur (EdgeRuntime.waitUntil) : fermer la page n'arrête plus rien. Choix de notifications appliqués côté serveur (`notif_preparer_srv`).
- Chaque mail passe par `send-email` avec le jeton de la personne (mêmes limites, même journal). Si `diffuser` ne répond pas, repli sur l'ancien envoi navigateur (`…Local`).
- Diffusion manuelle (onglet Mailing) : aussi par `diffuser` (lots de 300, option `desabo` : la marque {{DESABO}} reçoit le lien de désabonnement de chacun côté serveur).

## Sécurité et alertes (21/11/2026)
- `audit_alerte` : le propriétaire ne reçoit plus « Nouvel appareil » ni « Activité nocturne » (choix du propriétaire). Les autres alertes restent.
- Tâches `rappels-ca` et `envois-auto` : secret lu dans `bil_config.cron_secret` ; les fonctions `rappels` et `envois-auto` n'acceptent plus que lui (la variable `CRON_SECRET`, exposée, est ignorée).
- Rapprochement réel (01/07–19/11) : toutes les opérations bancaires ont leur écriture ; les deux virements de l'ancien CA (31/08 : 208,59 € ; 17/09 : 187,50 €) correspondent à la somme de plusieurs recettes « Remboursement du CA sortant ».
- `taches_surveiller` : les délais d'attente de la base (« Timeout of 5000 ms ») ne comptent plus ; alerte à partir de 5 vraies erreurs / heure.
- Rapprochement banque ↔ Caisse (et fiches du ZIP) : second passage `groupePourOperation` / `sousSomme` — un virement = plusieurs écritures (même sens, ±7 j, total exact).

## Mode clair / sombre (21/11/2026)
- Espace CA et Caisse : bouton `[data-theme-toggle]` (barre de l'utilisateur dans le CA, en-tête de la Caisse). Sombre par défaut.
- Choix mémorisé sur l'appareil (`localStorage["be-theme"] = "clair" | "sombre"`), commun aux deux apps ; appliqué dans <head> avant l'affichage (pas de flash).
- Thème clair = surcharge des variables CSS sous `html[data-theme="clair"]` + quelques corrections ciblées. Les fenêtres de sécurité (MFA) restent sombres, et les mails/PDF ne changent pas.

- 22/11/2026 : dispense de double authentification ajoutée pour Anais Dethy, Sidi Ahmed Youra et Amandine Culot Verboekhoven (table `mfa_dispenses`, comme Najwa Hit).
