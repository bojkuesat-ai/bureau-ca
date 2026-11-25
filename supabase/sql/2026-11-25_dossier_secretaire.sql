-- =====================================================================
--  Dossier de la secrétaire (25/11/2026) — migration dossier_secretaire
--  - ca_sec_dossier : documents déposés dans le dossier (par la secrétaire ou
--    par un membre du CA, jamais par un coopté).
--  - Fichiers : bucket « ca-documents », dossier secretariat/<id du déposant>/…
--    → inclus d'office dans le ZIP « Archives du CA » de la fin de mandat.
--  - Lecture : secrétaire, Admin, propriétaire ; le déposant voit ses propres envois.
--  - Modifier : le déposant seulement. Supprimer : le déposant, la secrétaire, le propriétaire.
--  - sec_dossier_pv() : les PV (signés, refusés, retirés) pour l'Admin et le
--    propriétaire, qui ne lisent pas ca_pv_signatures directement.
-- =====================================================================

create or replace function public.sec_dossier_voit()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select public.ca_est_secretaire() or public.ca_est_admin() or public.ca_is_owner();
$$;

create table if not exists public.ca_sec_dossier (
  id           uuid primary key default gen_random_uuid(),
  titre        text not null check (length(btrim(titre)) between 1 and 200),
  categorie    text not null default 'Divers' check (length(categorie) between 1 and 60),
  note         text check (note is null or length(note) <= 2000),
  chemin       text not null check (chemin like 'secretariat/%'),
  nom_fichier  text not null check (length(nom_fichier) between 1 and 255),
  taille       bigint,
  type_mime    text,
  depose_par   uuid not null default auth.uid(),
  depose_nom   text,
  created_at   timestamptz not null default now(),
  modifie_le   timestamptz
);
create index if not exists ca_sec_dossier_depose_par on public.ca_sec_dossier(depose_par);

-- Déposant, nom et chemin fixés par le serveur.
create or replace function public.ca_sec_dossier_avant()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is null then return new; end if;  -- serveur (fin de mandat…)
  if tg_op = 'INSERT' then
    new.depose_par := auth.uid();
    new.created_at := now();
    new.modifie_le := null;
  else
    new.depose_par := old.depose_par;
    new.created_at := old.created_at;
    new.modifie_le := now();
  end if;
  select nullif(btrim(coalesce(m.prenom, '') || ' ' || coalesce(m.nom, '')), '') into new.depose_nom
    from ca_membres m where m.id = new.depose_par;
  if split_part(new.chemin, '/', 2) <> new.depose_par::text then
    raise exception 'Chemin du fichier invalide.';
  end if;
  return new;
end $$;

create trigger a1_avant before insert or update on public.ca_sec_dossier
  for each row execute function public.ca_sec_dossier_avant();
create trigger a0_app_garde before insert or delete or update on public.ca_sec_dossier
  for each statement execute function public.app_garde('ca', '');
create trigger zz_audit after insert or delete or update on public.ca_sec_dossier
  for each row execute function public.audit_trigger();

alter table public.ca_sec_dossier enable row level security;
revoke all on public.ca_sec_dossier from anon;
grant select, insert, update, delete on public.ca_sec_dossier to authenticated;

create policy sec_lire on public.ca_sec_dossier for select to authenticated
  using (public.sec_dossier_voit() or depose_par = auth.uid());
create policy sec_ajouter on public.ca_sec_dossier for insert to authenticated
  with check (public.ca_is_actif() and depose_par = auth.uid());
create policy sec_modifier on public.ca_sec_dossier for update to authenticated
  using (depose_par = auth.uid()) with check (depose_par = auth.uid());
create policy sec_supprimer on public.ca_sec_dossier for delete to authenticated
  using (depose_par = auth.uid() or public.ca_est_secretaire() or public.ca_is_owner());
create policy mfa_aal2 on public.ca_sec_dossier as restrictive for all to authenticated
  using ((select public.mfa_ok())) with check ((select public.mfa_ok()));
create policy pas_les_cooptes on public.ca_sec_dossier as restrictive for all to authenticated
  using (not public.ca__est_coopte()) with check (not public.ca__est_coopte());
create policy app_fermee on public.ca_sec_dossier as restrictive for select to authenticated
  using ((select public.app_lecture_ok('ca')));

insert into public.app_tables(nom, app, module, lecture_bloquee)
  values ('ca_sec_dossier', 'ca', null, true) on conflict do nothing;

-- Stockage : le dossier secretariat/ n'est lisible que par le dossier (ou le déposant).
alter policy ca_st_doc_sel on storage.objects using (
  bucket_id = 'ca-documents' and public.ca_is_actif()
  and (coalesce((storage.foldername(name))[1], '') <> 'secretariat'
       or public.sec_dossier_voit()
       or (storage.foldername(name))[2] = auth.uid()::text));
alter policy ca_st_doc_ins on storage.objects with check (
  bucket_id = 'ca-documents' and public.ca_is_actif()
  and (coalesce((storage.foldername(name))[1], '') <> 'secretariat'
       or ((storage.foldername(name))[2] = auth.uid()::text and not public.ca__est_coopte())));
create policy ca_st_sec_del on storage.objects for delete to authenticated using (
  bucket_id = 'ca-documents' and (storage.foldername(name))[1] = 'secretariat'
  and (public.ca_est_secretaire() or public.ca_is_owner()));

-- PV (tous états) pour le dossier.
create or replace function public.sec_dossier_pv()
returns table (id uuid, numero int, titre text, reunion_id text, date_reunion date, statut text, motif text,
  refus_at timestamptz, secretaire_nom text, sig_secr_at timestamptz, signataire_nom text, signataire_fonction text,
  sig_sign_at timestamptz, pdf_path text, fichier jsonb, code_secr text, code_sign text, version int, created_at timestamptz)
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.sec_dossier_voit() then raise exception 'Réservé au dossier de la secrétaire.'; end if;
  if not public.mfa_ok() then raise exception 'Double authentification requise.'; end if;
  return query select p.id, p.numero, p.titre, p.reunion_id, p.date_reunion, p.statut, p.motif, p.refus_at,
    p.secretaire_nom, p.sig_secr_at, p.signataire_nom, p.signataire_fonction, p.sig_sign_at, p.pdf_path,
    p.fichier, p.code_secr, p.code_sign, p.version, p.created_at
    from ca_pv_signatures p order by p.numero desc nulls last, p.created_at desc;
end $$;
revoke all on function public.sec_dossier_pv() from public, anon;
grant execute on function public.sec_dossier_pv() to authenticated;
revoke all on function public.sec_dossier_voit() from public, anon;
grant execute on function public.sec_dossier_voit() to authenticated;
