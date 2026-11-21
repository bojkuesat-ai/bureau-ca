-- 21/11/2026 — Factures émises : communication structurée et paiements partiels
-- Sert à l'ajout de plusieurs factures à la fois (lecture des PDF) et à la comparaison
-- avec les extraits de compte CSV ING (Documents › Paiements).
-- Aucun « drop » : simple ajout de colonnes.
alter table public.caisse_documents add column if not exists communication text;
alter table public.caisse_documents add column if not exists montant_recu numeric(12,2) not null default 0;
alter table public.caisse_documents add column if not exists paiements jsonb not null default '[]'::jsonb;
comment on column public.caisse_documents.communication is 'Communication structurée de la facture émise (+++xxx/xxxx/xxxxx+++)';
comment on column public.caisse_documents.montant_recu is 'Total déjà reçu sur la facture émise (paiements partiels compris)';
comment on column public.caisse_documents.paiements is 'Versements reçus : [{date, montant, ref, cle, payeur, income_id, cree}]';
