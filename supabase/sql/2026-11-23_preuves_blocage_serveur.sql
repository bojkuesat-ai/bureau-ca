-- 23/11/2026 — Caisse › Preuves : blocage des nouvelles demandes appliqué aussi côté serveur.
-- Même règle que la page (caisse/index.html : preuveManquante, PRV_DELAI = 10) :
-- si « Bloquer les nouvelles demandes » est coché (caisse_config.compta.prvBlocage),
-- un membre qui a une demande sans preuve complète depuis plus de 10 jours ne peut pas en créer d'autre.
-- Le trésorier n'est jamais bloqué (y compris quand il saisit pour un membre). Déjà appliqué en production.

create or replace function public.caisse_preuve_manquante(r public.requests)
 returns boolean language sql stable set search_path to 'public'
as $f$
  with k as (
    select coalesce(array_agg(coalesce(a->>'kind','')), '{}') kinds, count(*) n
    from jsonb_array_elements(case when jsonb_typeof(r.attachments) = 'array' then r.attachments else '[]'::jsonb end) a
  )
  select r.status is distinct from 'Refusée' and r.preuve_validee_at is null and (
    -- aucune pièce
    ((select n from k) = 0 and coalesce(r.proof_path,'') = '')
    -- pièces présentes mais incomplètes
    or ((select n from k) > 0
        and not ((select kinds from k) && array['Justificatif','Autre pièce','Document','Déclaration de perte','Attestation du trésorier'])
        and ( not ((select kinds from k) && array['Facture','Ticket de caisse','Bon de commande','Devis'])
              or ( r.kind is distinct from 'direct'
                   and coalesce(r.payment_method,'') !~* 'esp[eè]ces'
                   and not ((select kinds from k) && array['Extrait de compte','Preuve de virement','Reçu de paiement par carte','Reçu signé du commerçant']) ) ))
  );
$f$;

create or replace function public.caisse_bloquer_si_preuves_retard()
 returns trigger language plpgsql security definer set search_path to 'public'
as $f$
declare n int; refs text;
begin
  if public.is_tresorier() then return new; end if;
  if not coalesce((select (compta->>'prvBlocage')::boolean from caisse_config where id = 1), false) then return new; end if;
  select count(*), string_agg('#' || r.seq, ', ' order by r.created_at)
    into n, refs
    from requests r
   where r.user_id = new.user_id
     and now() - coalesce(r.created_at, r.expense_date::timestamptz) >= interval '11 days'
     and not exists (select 1 from closures c
                      where c.year = case when extract(month from r.expense_date) >= 7
                                          then extract(year from r.expense_date) else extract(year from r.expense_date) - 1 end)
     and public.caisse_preuve_manquante(r);
  if n > 0 then
    raise exception 'Vous avez % demande(s) sans preuve depuis plus de 10 jours (%). Déposez d''abord vos preuves.', n, refs;
  end if;
  return new;
end; $f$;

create or replace trigger a1_preuves_retard before insert on public.requests
  for each row execute function public.caisse_bloquer_si_preuves_retard();
