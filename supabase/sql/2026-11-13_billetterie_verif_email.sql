-- =====================================================================
-- Billetterie (13/11/2026) — vérification de l'adresse e-mail au choix.
-- Appliqué sur le projet (migration « billetterie_verif_email »).
-- Par défaut (false) : pas de mail « Confirmez votre adresse », l'inscription
-- passe tout de suite à inscrit / a_valider / attente. Le responsable peut
-- l'activer par événement dans Réglages › Inscriptions.
-- =====================================================================
alter table public.bil_evenements add column if not exists verif_email boolean not null default false;

create or replace function public.bil_public_evenement(p_code text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare e public.bil_evenements; c public.bil_commissions; cfg public.bil_config; res int; raison text;
begin
  select * into e from public.bil_evenements where code = upper(trim(coalesce(p_code,'')));
  if not found then return null; end if;
  select * into c from public.bil_commissions where id = e.commission_id;
  select * into cfg from public.bil_config where id = 1;
  res := public.bil_reserves(e.id);
  raison := public.bil_raison_fermeture(e.id);
  return jsonb_build_object(
    'code', e.code, 'titre', e.titre, 'commission', c.nom,
    'date', e.date_evt, 'heure_debut', to_char(e.heure_debut, 'HH24:MI'), 'heure_fin', to_char(e.heure_fin, 'HH24:MI'),
    'lieu', e.lieu, 'infos', e.infos,
    'places', e.places, 'restantes', case when coalesce(e.places,0) > 0 then greatest(e.places - res, 0) end,
    'complet', coalesce(e.places,0) > 0 and res >= e.places,
    'payant', e.payant, 'prix', e.prix,
    'iban', case when e.payant then cfg.iban end, 'titulaire', case when e.payant then cfg.titulaire end,
    'formulaire', e.formulaire,
    'cooptation', case when coalesce((e.cooptation->>'actif')::boolean, false) then e.cooptation->>'libelle' end,
    'ouvert', raison = '', 'raison', raison, 'ouverture', e.ouverture, 'fermeture', e.fermeture,
    'contact_rgpd', cfg.contact_rgpd,
    'verif_email', e.verif_email);
end $function$;
