-- =====================================================================
-- Caisse (13/11/2026) — code de vérification sur les décisions du trésorier.
-- Appliqué sur le projet (migration « caisse_decisions_code_verification »).
--
-- Chaque changement de statut d'une demande fait par le trésorier (validée,
-- refusée, à corriger, remboursée, remise en attente, virement rejeté) est
-- inscrit dans public.signatures_registre et reçoit un code
-- XXXX-XXXX-XXXX-XXXX, vérifiable dans l'onglet « Vérifier une signature ».
--   requests.decision_code  = code de la dernière décision
--   requests.decision_codes = historique [{statut, type, code, le, par}]
-- Ces deux colonnes ne sont écrites que par le trigger : toute valeur envoyée
-- par le navigateur est ignorée.
-- =====================================================================

alter table public.requests add column if not exists decision_code text;
alter table public.requests add column if not exists decision_codes jsonb not null default '[]'::jsonb;

create or replace function public.caisse_decision_code()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_type text; v_lib text; v_emp text; v_code text; v_now timestamptz := now(); v_ref text;
begin
  if tg_op = 'INSERT' then
    new.decision_code := null; new.decision_codes := '[]'::jsonb;
    return new;
  end if;
  -- Colonnes réservées au serveur.
  new.decision_code := old.decision_code;
  new.decision_codes := coalesce(old.decision_codes, '[]'::jsonb);
  if new.status is not distinct from old.status then return new; end if;
  if auth.uid() is null or not is_tresorier() then return new; end if;

  if new.status = 'Validée' and old.status = 'Remboursée' then v_type := 'decision_rejet'; v_lib := 'virement rejeté, remise en « Validée »';
  elsif new.status = 'Validée'    then v_type := 'decision_validee';  v_lib := 'demande validée';
  elsif new.status = 'Refusée'    then v_type := 'decision_refusee';  v_lib := 'demande refusée';
  elsif new.status = 'À corriger' then v_type := 'decision_corriger'; v_lib := 'renvoyée pour correction';
  elsif new.status = 'Remboursée' then v_type := 'decision_payee';    v_lib := 'paiement effectué';
  elsif new.status = 'En attente' then v_type := 'decision_rouverte'; v_lib := 'remise en attente';
  else return new;
  end if;

  v_ref := 'Demande n° ' || coalesce(new.seq::text, '?');
  v_emp := signature_empreinte(jsonb_build_object('id', new.id, 'seq', new.seq, 'montant', new.amount, 'objet', new.object,
    'date', new.expense_date, 'kind', new.kind, 'iban', coalesce(new.beneficiary_iban, new.iban), 'beneficiaire', new.beneficiary,
    'user', new.user_id, 'statut_avant', old.status, 'statut', new.status, 'note', new.decision_note, 'decide_le', v_now)::text);
  v_code := signature_interne('caisse', v_type, new.id::text, v_ref || ' — ' || v_lib || ' — trésorier', v_emp,
    jsonb_build_object('numero', new.seq, 'montant', new.amount, 'objet', new.object, 'date', new.expense_date, 'kind', new.kind,
      'beneficiaire', new.beneficiary, 'demandeur', new.requester_name, 'decision', v_lib,
      'statut_avant', old.status, 'statut', new.status));
  new.decision_code := v_code;
  new.decision_codes := new.decision_codes || jsonb_build_array(jsonb_build_object(
    'statut', new.status, 'type', v_type, 'code', v_code, 'le', v_now,
    'par', (select name from profiles where id = auth.uid())));
  return new;
end $$;
revoke all on function public.caisse_decision_code() from anon, authenticated, public;

-- « zy_ » : dernier trigger BEFORE (après les contrôles budget, TB, garde, verrou) ;
-- si l'un d'eux refuse la modification, rien n'est inscrit au registre.
drop trigger if exists zy_caisse_decision_code on public.requests;
create trigger zy_caisse_decision_code
  before insert or update on public.requests
  for each row execute function public.caisse_decision_code();
