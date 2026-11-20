-- Réunion : heure de fin (facultative) et rédaction enrichie du PV.
-- Appliqué sur Supabase via apply_migration « reunion_heure_fin_pv_contenu » :
--  * ca_reunions.heure_fin (time) et ca_reunions.pv_contenu (jsonb : intro, fin, points{id:html}, budgets, exclus[]) ;
--  * ca_reunions_garde() : heure_fin et pv_contenu réservés au secrétariat et verrouillés avec le PV ;
--  * reu_odj_envoyer() : le mail affiche « à 14h – 16h » quand une heure de fin existe.
alter table public.ca_reunions add column if not exists heure_fin time, add column if not exists pv_contenu jsonb;
