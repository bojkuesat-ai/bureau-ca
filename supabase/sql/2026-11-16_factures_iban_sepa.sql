-- 16/11/2026 — Factures à échéance : IBAN du fournisseur (fichier de paiement SEPA)
-- Déjà appliqué en production.
alter table public.factures_echeance add column if not exists fournisseur_iban text;
-- Chaque échéance (jsonb echeances[]) peut porter « exporte_le » : date à laquelle elle a été
-- mise dans un fichier de paiement SEPA (avertissement anti double paiement). Pas de colonne à créer.
