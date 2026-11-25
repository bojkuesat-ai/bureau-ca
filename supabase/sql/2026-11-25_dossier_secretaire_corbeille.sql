-- =====================================================================
--  Dossier de la secrétaire : corbeille de 30 jours (25/11/2026)
--  migration dossier_secretaire_corbeille
--  - supprime_le / supprime_par : document mis à la corbeille (invisible dans le dossier et le ZIP).
--  - sec_dossier_corbeille(id, mettre) : mettre à la corbeille ou restaurer
--    (le déposant, la secrétaire, le propriétaire). Seule cette fonction touche ces colonnes.
--  - Suppression définitive : bouton, ou automatiquement après 30 jours (fait par l'app
--    à l'ouverture du dossier, car les fichiers se suppriment par l'API de stockage).
-- =====================================================================
alter table public.ca_sec_dossier add column if not exists supprime_le timestamptz;
alter table public.ca_sec_dossier add column if not exists supprime_par uuid;

create or replace function public.ca_sec_dossier_avant()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare f jsonb; corb boolean := current_setting('app.sec_corbeille', true) = '1';
begin
  if auth.uid() is null then return new; end if;  -- serveur (fin de mandat…)
  if tg_op = 'INSERT' then
    new.depose_par := auth.uid(); new.created_at := now(); new.modifie_le := null;
    new.supprime_le := null; new.supprime_par := null;
  else
    new.depose_par := old.depose_par; new.created_at := old.created_at;
    if corb then
      new.modifie_le := old.modifie_le;
    else
      new.modifie_le := now(); new.supprime_le := old.supprime_le; new.supprime_par := old.supprime_par;
    end if;
  end if;
  select nullif(btrim(coalesce(m.prenom, '') || ' ' || coalesce(m.nom, '')), '') into new.depose_nom
    from ca_membres m where m.id = new.depose_par;
  if jsonb_typeof(new.fichiers) is distinct from 'array' or jsonb_array_length(new.fichiers) = 0 then
    new.fichiers := jsonb_build_array(jsonb_build_object('chemin', new.chemin, 'nom', new.nom_fichier, 'taille', new.taille, 'type', new.type_mime));
  end if;
  if jsonb_array_length(new.fichiers) > 20 then raise exception 'Maximum 20 fichiers par document.'; end if;
  for f in select * from jsonb_array_elements(new.fichiers) loop
    if coalesce(f ->> 'chemin', '') not like 'secretariat/%'
       or split_part(f ->> 'chemin', '/', 2) <> new.depose_par::text
       or length(coalesce(f ->> 'nom', '')) not between 1 and 255 then
      raise exception 'Chemin du fichier invalide.';
    end if;
  end loop;
  f := new.fichiers -> 0;
  new.chemin := f ->> 'chemin'; new.nom_fichier := f ->> 'nom';
  new.taille := nullif(f ->> 'taille', '')::bigint; new.type_mime := f ->> 'type';
  return new;
end $$;

create or replace function public.sec_dossier_corbeille(p_id uuid, p_mettre boolean)
returns void language plpgsql security definer set search_path to 'public' as $$
declare d ca_sec_dossier;
begin
  if auth.uid() is null or public.ca__est_coopte() or not public.ca_is_actif() then raise exception 'Accès refusé.'; end if;
  if not public.mfa_ok() then raise exception 'Double authentification requise.'; end if;
  select * into d from ca_sec_dossier where id = p_id for update;
  if not found then raise exception 'Document introuvable.'; end if;
  if not (d.depose_par = auth.uid() or public.ca_est_secretaire() or public.ca_is_owner()) then
    raise exception 'Vous ne pouvez pas supprimer ce document.';
  end if;
  perform set_config('app.sec_corbeille', '1', true);
  update ca_sec_dossier set supprime_le = case when p_mettre then now() end,
                            supprime_par = case when p_mettre then auth.uid() end
   where id = p_id;
  perform set_config('app.sec_corbeille', '', true);
end $$;
revoke all on function public.sec_dossier_corbeille(uuid, boolean) from public, anon;
grant execute on function public.sec_dossier_corbeille(uuid, boolean) to authenticated;
