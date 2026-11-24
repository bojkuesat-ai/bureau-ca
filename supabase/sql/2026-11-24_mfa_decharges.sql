-- =====================================================================
--  Décharge « double authentification » (24/11/2026) — migration mfa_decharges
--  Pour les membres du CA obligés d'activer la double authentification qui ne l'ont pas fait.
--  Un mail Sécurité-BE leur envoie un lien personnel (sans expiration, utilisable une fois).
--  Sur la page decharge-mfa.html, la personne signe avec son mot de passe CAISSE (sans code) :
--    - dispense ajoutée dans mfa_dispenses ;
--    - PDF de décharge avec un code de signature unique, rangé dans le stockage privé
--      « fin-mandat », dossier « decharges-mfa » (espace Propriétaire › Fin de mandat › Copies gardées) ;
--    - PDF envoyé par mail à la personne (pas au propriétaire).
--  Fonction Edge : supabase/functions/mfa-decharge (Verify JWT désactivé).
--  Table réservée au serveur (RLS sans politique) : seul le jeton haché est gardé.
-- =====================================================================
create table if not exists public.mfa_decharges (
  id            uuid primary key default gen_random_uuid(),
  membre_id     uuid not null references public.ca_membres(id) on delete cascade,
  jeton_hash    text not null unique,
  envoye_le     timestamptz not null default now(),
  essais        int not null default 0,
  signe_le      timestamptz,
  code          text unique,
  empreinte     text,
  ip            text,
  appareil      text,
  pdf_chemin    text,
  texte         text
);
create index if not exists mfa_decharges_membre on public.mfa_decharges(membre_id);
alter table public.mfa_decharges enable row level security;
revoke all on public.mfa_decharges from anon, authenticated;
