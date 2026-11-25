-- =====================================================================
--  Dossier de la secrétaire : plusieurs fichiers par document (25/11/2026)
--  migration dossier_secretaire_multi
--  - ca_sec_dossier.fichiers : [{chemin, nom, taille, type}] (1 à 20 fichiers).
--  - chemin / nom_fichier / taille / type_mime = le premier fichier (compatibilité).
--  - Chaque chemin doit être dans secretariat/<id du déposant>/.
-- =====================================================================
alter table public.ca_sec_dossier add column if not exists fichiers jsonb not null default '[]'::jsonb;

update public.ca_sec_dossier
   set fichiers = jsonb_build_array(jsonb_build_object('chemin', chemin, 'nom', nom_fichier, 'taille', taille, 'type', type_mime))
 where jsonb_array_length(fichiers) = 0;

create or replace function public.ca_sec_dossier_avant()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare f jsonb;
begin
  if auth.uid() is null then return new; end if;  -- serveur (fin de mandat…)
  if tg_op = 'INSERT' then
    new.depose_par := auth.uid(); new.created_at := now(); new.modifie_le := null;
  else
    new.depose_par := old.depose_par; new.created_at := old.created_at; new.modifie_le := now();
  end if;
  select nullif(btrim(coalesce(m.prenom, '') || ' ' || coalesce(m.nom, '')), '') into new.depose_nom
    from ca_membres m where m.id = new.depose_par;
  -- Liste des fichiers : à défaut, le fichier unique.
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
