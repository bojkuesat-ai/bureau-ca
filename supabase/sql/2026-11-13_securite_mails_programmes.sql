-- =====================================================================
-- Sécurité (13/11/2026) : mails programmés réservés aux membres actifs du CA.
-- Avant : n'importe quel compte connecté (inscription libre) pouvait créer,
-- lire, modifier ou supprimer un mail programmé, envoyé ensuite par le serveur
-- (sans limite) avec, en pièce jointe, n'importe quel document du CA.
-- Déjà appliqué sur le projet (migration « securite_mails_programmes »).
-- =====================================================================

create or replace function public.ca_prog_piece_ok(p_path text)
returns boolean language sql stable security definer set search_path = public, storage as $$
  select p_path is null or exists (
    select 1 from storage.objects o
     where o.bucket_id = 'ca-documents' and o.name = p_path
       and (o.owner = auth.uid() or o.owner_id = auth.uid()::text));
$$;
revoke all on function public.ca_prog_piece_ok(text) from public, anon;
grant execute on function public.ca_prog_piece_ok(text) to authenticated;

drop policy if exists prog_all on public.ca_mail_programmes;
drop policy if exists prog_select on public.ca_mail_programmes;
drop policy if exists prog_lire on public.ca_mail_programmes;
drop policy if exists prog_creer on public.ca_mail_programmes;
drop policy if exists prog_maj on public.ca_mail_programmes;
drop policy if exists prog_suppr on public.ca_mail_programmes;

create policy prog_lire on public.ca_mail_programmes
  for select to authenticated using (public.ca_is_actif());
create policy prog_creer on public.ca_mail_programmes
  for insert to authenticated
  with check (public.ca_is_actif() and cree_par = auth.uid() and statut = 'en_attente'
              and public.ca_prog_piece_ok(piece_path));
create policy prog_maj on public.ca_mail_programmes
  for update to authenticated using (public.ca_is_actif()) with check (public.ca_is_actif());
create policy prog_suppr on public.ca_mail_programmes
  for delete to authenticated using (cree_par = auth.uid() or public.ca_is_owner());
revoke all on public.ca_mail_programmes from anon;

create or replace function public.ca_prog_garde()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;          -- serveur (envois-auto)
  if new.cree_par is distinct from old.cree_par then
    raise exception 'Auteur du mail programmé non modifiable.' using errcode = '42501';
  end if;
  if new.statut not in ('en_attente', 'en_cours', 'envoye', 'erreur') then
    raise exception 'Statut invalide.' using errcode = '22023';
  end if;
  if old.cree_par is distinct from auth.uid() and not public.ca_is_owner() then
    if new.destinataires is distinct from old.destinataires or new.objet is distinct from old.objet
       or new.corps is distinct from old.corps or new.piece_path is distinct from old.piece_path
       or new.lien_piece is distinct from old.lien_piece or new.nom_piece is distinct from old.nom_piece
       or new.envoi_at is distinct from old.envoi_at then
      raise exception 'Seul l''auteur peut modifier ce mail programmé.' using errcode = '42501';
    end if;
  elsif new.piece_path is distinct from old.piece_path and not public.ca_prog_piece_ok(new.piece_path) then
    raise exception 'Pièce jointe non autorisée.' using errcode = '42501';
  end if;
  return new;
end;
$$;
drop trigger if exists ca_prog_garde on public.ca_mail_programmes;
create trigger ca_prog_garde before update on public.ca_mail_programmes
  for each row execute function public.ca_prog_garde();
