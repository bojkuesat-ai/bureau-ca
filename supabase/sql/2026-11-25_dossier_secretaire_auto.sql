-- =====================================================================
--  Dossier de la secrétaire : retirer / renommer les éléments automatiques (25/11/2026)
--  migration dossier_secretaire_auto
--  Les éléments automatiques (PV, documents « PV & CR », réunions, courriers) restent
--  intacts ailleurs : ca_sec_auto ne change que leur affichage dans le dossier et le ZIP.
--  cle : « pv:<id> », « doc:<chemin> », « reu:<id> », « cour:<id> ».
--  Lecture : secrétaire, Admin, propriétaire. Écriture : secrétaire et propriétaire.
-- =====================================================================
create table if not exists public.ca_sec_auto (
  cle       text primary key check (length(cle) between 3 and 300),
  retire    boolean not null default false,
  titre     text check (titre is null or length(titre) <= 200),
  note      text check (note is null or length(note) <= 2000),
  maj_par   uuid default auth.uid(),
  maj_le    timestamptz not null default now()
);

create or replace function public.ca_sec_auto_avant()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is not null then new.maj_par := auth.uid(); end if;
  new.maj_le := now();
  new.titre := nullif(btrim(coalesce(new.titre, '')), '');
  new.note := nullif(btrim(coalesce(new.note, '')), '');
  return new;
end $$;
create trigger a1_avant before insert or update on public.ca_sec_auto for each row execute function public.ca_sec_auto_avant();
create trigger a0_app_garde before insert or delete or update on public.ca_sec_auto for each statement execute function public.app_garde('ca', '');
create trigger zz_audit after insert or delete or update on public.ca_sec_auto for each row execute function public.audit_trigger();

alter table public.ca_sec_auto enable row level security;
revoke all on public.ca_sec_auto from anon;
grant select, insert, update, delete on public.ca_sec_auto to authenticated;
create policy auto_lire on public.ca_sec_auto for select to authenticated using (public.sec_dossier_voit());
create policy auto_ajouter on public.ca_sec_auto for insert to authenticated with check (public.ca_est_secretaire() or public.ca_is_owner());
create policy auto_modifier on public.ca_sec_auto for update to authenticated
  using (public.ca_est_secretaire() or public.ca_is_owner()) with check (public.ca_est_secretaire() or public.ca_is_owner());
create policy auto_supprimer on public.ca_sec_auto for delete to authenticated using (public.ca_est_secretaire() or public.ca_is_owner());
create policy mfa_aal2 on public.ca_sec_auto as restrictive for all to authenticated
  using ((select public.mfa_ok())) with check ((select public.mfa_ok()));
create policy pas_les_cooptes on public.ca_sec_auto as restrictive for all to authenticated
  using (not public.ca__est_coopte()) with check (not public.ca__est_coopte());
create policy app_fermee on public.ca_sec_auto as restrictive for select to authenticated
  using ((select public.app_lecture_ok('ca')));

insert into public.app_tables(nom, app, module, lecture_bloquee) values ('ca_sec_auto', 'ca', null, true) on conflict do nothing;
