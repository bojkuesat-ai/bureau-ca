-- =====================================================================
-- Les connexions et actions du compte propriétaire (avant ET après la passation)
-- ne sont ni enregistrées dans le Journal de l'Admin, ni affichées dans Transparence.
-- Le propriétaire garde son mail « 🔐 Nouvelle connexion » (securite_appareil_vu, inchangé).
-- =====================================================================

-- « Propriétaire » = role owner ou proprietaire (après passation).
create or replace function public.audit_est_owner(p_uid uuid)
 returns boolean language sql stable security definer set search_path to 'public'
as $f$ select p_uid is not null and exists(select 1 from public.ca_membres where id = p_uid and role in ('owner', 'proprietaire')) $f$;

-- Écriture du journal : rien pour le propriétaire.
do $m$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p where p.oid = 'public.audit_ecrire'::regproc;
  d := replace(d, $x$if m.role = 'owner' then return; end if;$x$, $x$if m.role in ('owner', 'proprietaire') then return; end if;$x$);
  if position($x$m.role in ('owner', 'proprietaire')$x$ in d) = 0 then raise exception 'audit_ecrire : motif introuvable'; end if;
  execute d;
  select pg_get_functiondef(p.oid) into d from pg_proc p where p.oid = 'public.audit_trigger'::regproc;
  d := replace(d, $x$if m.role = 'owner' then return null; end if;$x$, $x$if m.role in ('owner', 'proprietaire') then return null; end if;$x$);
  if position($x$m.role in ('owner', 'proprietaire')$x$ in d) = 0 then raise exception 'audit_trigger : motif introuvable'; end if;
  execute d;
  select pg_get_functiondef(p.oid) into d from pg_proc p where p.oid = 'public.audit_tableau'::regproc;
  d := replace(d, $x$m.role is distinct from 'owner'$x$, $x$coalesce(m.role, '') not in ('owner', 'proprietaire')$x$);
  if position($x$not in ('owner', 'proprietaire')$x$ in d) = 0 then raise exception 'audit_tableau : motif introuvable'; end if;
  execute d;
end $m$;

-- Lecture du journal par l'Admin : jamais les lignes du compte propriétaire.
create or replace function public.audit_proprio_id()
 returns uuid language sql stable security definer set search_path to 'public'
as $f$ select id from public.ca_membres where role in ('owner', 'proprietaire') order by (role = 'owner') desc, created_at limit 1 $f$;
revoke all on function public.audit_proprio_id() from public, anon;
grant execute on function public.audit_proprio_id() to authenticated;
drop policy if exists ca_audit_lecture on public.ca_audit;
create policy ca_audit_lecture on public.ca_audit for select
  using (public.ca_est_admin() and membre_id is distinct from (select public.audit_proprio_id()));

-- Transparence : plus de liste de connexions du propriétaire.
create or replace function public.transparence_etat()
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $f$
declare c proprio_config; o record;
begin
  if auth.uid() is null or not (public.ca_est_membre_plein() or public.ca_is_actif() or public.is_approved()) then
    raise exception 'Réservé aux membres.'; end if;
  select * into c from proprio_config where id = 1;
  select m.id, trim(coalesce(m.prenom, '') || ' ' || coalesce(m.nom, '')) as nom, m.role into o
    from ca_membres m where m.role in ('owner','proprietaire') order by m.created_at limit 1;
  return jsonb_build_object(
    'proprietaire', o.nom,
    'acces_retire', o.role = 'proprietaire',
    'passation_le', c.passation_le,
    'passation_a', (select trim(coalesce(prenom, '') || ' ' || coalesce(nom, '')) from ca_membres where id = c.passation_a),
    'historique', coalesce((select jsonb_agg(jsonb_build_object('le', t.le, 'evenement', t.evenement, 'details', t.details) order by t.le desc, t.id desc)
                   from (select * from transparence_journal order by le desc, id desc limit 30) t), '[]'));
end $f$;
