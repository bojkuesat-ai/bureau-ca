-- 23/11/2026 — Caisse › Preuves : « Preuve non donnée » (trésorier). Déjà appliqué en production.
alter table public.requests add column if not exists preuve_non_donnee_at timestamptz;
alter table public.requests add column if not exists preuve_non_donnee_motif text;

-- le membre ne peut pas effacer la mention « Aucune preuve déposée »
create or replace function public.garde_requests()
 returns trigger language plpgsql security definer set search_path to 'public'
as $f$
begin
  if public.is_tresorier() then return new; end if;
  if new.status is distinct from old.status
     and not (old.status = 'Refusée' and new.status = 'En attente') then
    raise exception 'Vous ne pouvez pas modifier le statut de la demande.';
  end if;
  if new.amount        is distinct from old.amount
     or new.user_id    is distinct from old.user_id
     or new.iban       is distinct from old.iban
     or new.decision_note is distinct from old.decision_note
     or new.paid_at    is distinct from old.paid_at
     or new.preuve_non_donnee_at    is distinct from old.preuve_non_donnee_at
     or new.preuve_non_donnee_motif is distinct from old.preuve_non_donnee_motif then
    raise exception 'Seules les pièces justificatives et votre commentaire sont modifiables.';
  end if;
  return new;
end; $f$;
