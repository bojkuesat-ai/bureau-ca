-- =====================================================================
-- Sécurité (13/11/2026) — points 3, 4, 5 et 6 de l'audit.
-- Déjà appliqué sur le projet (migrations « securite_groupes_votes_rappels_tresorier »
-- et « securite_options_de_vote »).
-- =====================================================================

-- 3. Groupes d'envoi : réservés aux membres actifs du CA (hors cooptés).
drop policy if exists groupes_all on public.ca_mail_groupes;
drop policy if exists groupes_select on public.ca_mail_groupes;
drop policy if exists groupes_membres on public.ca_mail_groupes;
create policy groupes_membres on public.ca_mail_groupes
  for all to authenticated
  using (public.ca_est_membre_plein()) with check (public.ca_est_membre_plein());
revoke all on public.ca_mail_groupes from anon;

-- 4. Votes : question et documents figés dès la première voix ; rouvrir un vote
--    clôturé et supprimer un vote qui a des voix : propriétaire seulement.
drop policy if exists ca_vt_upd on public.ca_votes;
create policy ca_vt_upd on public.ca_votes
  for update to authenticated
  using ((cree_par = auth.uid()) or public.ca_is_owner())
  with check ((cree_par = auth.uid()) or public.ca_is_owner());

create or replace function public.ca_votes_garde()
returns trigger language plpgsql security definer set search_path = public as $$
declare voix boolean; proprio boolean;
begin
  if auth.uid() is null then return coalesce(new, old); end if;
  proprio := public.ca_is_owner();
  select exists (select 1 from public.ca_vote_ballots b where b.vote_id = old.id) into voix;
  if tg_op = 'DELETE' then
    if voix and not proprio then
      raise exception 'Ce vote a déjà reçu des voix : seul le propriétaire peut le supprimer.' using errcode = '42501';
    end if;
    return old;
  end if;
  if new.cree_par is distinct from old.cree_par then
    raise exception 'Auteur du vote non modifiable.' using errcode = '42501';
  end if;
  if voix and not proprio and (new.question is distinct from old.question or new.docs is distinct from old.docs) then
    raise exception 'Ce vote a déjà reçu des voix : la question et les documents ne peuvent plus changer.' using errcode = '42501';
  end if;
  if old.statut = 'closed' and new.statut = 'open' and not proprio then
    raise exception 'Seul le propriétaire peut rouvrir un vote clôturé.' using errcode = '42501';
  end if;
  return new;
end;
$$;
drop trigger if exists ca_votes_garde on public.ca_votes;
create trigger ca_votes_garde before update or delete on public.ca_votes
  for each row execute function public.ca_votes_garde();

-- 4 (suite). Choix de réponse : créateur du vote ou propriétaire, figés dès la première voix.
drop policy if exists ca_vo_rw on public.ca_vote_options;
drop policy if exists ca_vo_lire on public.ca_vote_options;
drop policy if exists ca_vo_ecrire on public.ca_vote_options;
create policy ca_vo_lire on public.ca_vote_options
  for select to authenticated using (public.ca_is_actif());
create policy ca_vo_ecrire on public.ca_vote_options
  for all to authenticated
  using (public.ca_is_owner() or exists (select 1 from public.ca_votes v where v.id = vote_id and v.cree_par = auth.uid()))
  with check (public.ca_is_owner() or exists (select 1 from public.ca_votes v where v.id = vote_id and v.cree_par = auth.uid() and public.ca_is_actif()));
revoke all on public.ca_vote_options from anon;

create or replace function public.ca_vote_options_garde()
returns trigger language plpgsql security definer set search_path = public as $$
declare vid uuid := coalesce(new.vote_id, old.vote_id);
begin
  if auth.uid() is null or public.ca_is_owner() then return coalesce(new, old); end if;
  if tg_op = 'UPDATE' and new.vote_id is distinct from old.vote_id then
    raise exception 'Un choix ne peut pas changer de vote.' using errcode = '42501';
  end if;
  if exists (select 1 from public.ca_vote_ballots b where b.vote_id = vid) then
    raise exception 'Ce vote a déjà reçu des voix : les choix ne peuvent plus changer.' using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;
drop trigger if exists ca_vote_options_garde on public.ca_vote_options;
create trigger ca_vote_options_garde before insert or update or delete on public.ca_vote_options
  for each row execute function public.ca_vote_options_garde();

-- 5. Registre des rappels : écriture par les membres actifs, entrées non
--    modifiables ni effaçables (sauf propriétaire).
drop policy if exists rappels_all on public.ca_rappels_envoyes;
drop policy if exists rappels_lire on public.ca_rappels_envoyes;
drop policy if exists rappels_creer on public.ca_rappels_envoyes;
drop policy if exists rappels_proprio on public.ca_rappels_envoyes;
create policy rappels_lire on public.ca_rappels_envoyes
  for select to authenticated using (public.ca_is_actif());
create policy rappels_creer on public.ca_rappels_envoyes
  for insert to authenticated with check (public.ca_is_actif());
create policy rappels_proprio on public.ca_rappels_envoyes
  for all to authenticated using (public.ca_is_owner()) with check (public.ca_is_owner());
revoke all on public.ca_rappels_envoyes from anon;

-- 6. Caisse : les anciennes règles « trésorier » exigent un trésorier approuvé.
drop policy if exists "Le tresorier peut supprimer toute demande" on public.requests;
drop policy if exists "Le tresorier peut modifier toute demande" on public.requests;
drop policy if exists tresorier_insere_pour_membre on public.requests;
create policy tresorier_insere_pour_membre on public.requests
  for insert to authenticated with check (public.is_tresorier());

drop policy if exists "Le tresorier peut deposer tout justificatif" on storage.objects;
drop policy if exists "Le tresorier peut supprimer tout justificatif" on storage.objects;
create policy "Le tresorier peut deposer tout justificatif" on storage.objects
  for insert to authenticated with check (bucket_id = 'justificatifs' and public.is_tresorier());
create policy "Le tresorier peut supprimer tout justificatif" on storage.objects
  for delete to authenticated using (bucket_id = 'justificatifs' and public.is_tresorier());
