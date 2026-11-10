-- send-email durci (09-10/11/2026) : identifiant texte de l'appelant (comptes Firebase de l'app QR
-- inclus) et empreinte courte du destinataire pour limiter les envois anonymes vers une même adresse.
-- Déjà appliqué sur le projet (migration « mail_envois_compte_dest_hash »).
alter table public.mail_envois add column if not exists compte text;
alter table public.mail_envois add column if not exists dest_hash text;
create index if not exists mail_envois_compte_le_idx on public.mail_envois (compte, le);
create index if not exists mail_envois_dest_hash_le_idx on public.mail_envois (dest_hash, le);
update public.mail_envois set compte = uid::text where compte is null and uid is not null;
