-- Réunions : sujets d'ordre du jour, clôture la veille à 23 h 59, ODJ envoyé 1 h avant,
-- PV verrouillé pendant et après la signature — 17/11/2026
--
-- Points de l'ordre du jour (colonne ordre, jsonb) : {id, texte, sujet, note, budgetObjet,
-- budgetMontant, fait, notes, parId, par}. « sujet » vient d'une liste fixe (voir reu_sujets).
-- Demande de budget : objet et montant obligatoires. Autre : titre obligatoire.
-- Les cooptés n'ont déjà aucun accès à ca_reunions (règle pas_les_cooptes).

alter table public.ca_reunions add column if not exists heure time;
alter table public.ca_reunions add column if not exists odj_envoye_at timestamptz;

create or replace function public.reu_sujets() returns text[] language sql immutable as $$
  select array['odj','pv','suivi','tresorerie','budget','budgets_cours','evenements','retour','communication',
               'partenariats','faculte','commission','cooptation','courriers','ag','divers','autre']::text[] $$;

-- Ordre du jour fermé à partir de minuit (heure de Bruxelles) le jour de la réunion.
create or replace function public.reu_odj_ferme(p_date date) returns boolean language sql stable as $$
  select p_date is not null and now() >= (p_date::timestamp at time zone 'Europe/Brussels') $$;

-- PV envoyé à la signature (en attente) ou signé : la réunion est verrouillée.
create or replace function public.reu_pv_verrouille(p_reunion uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from ca_pv_signatures s where s.reunion_id = p_reunion::text and s.statut in ('attente','valide')) $$;

create or replace function public.ca_reunions_garde()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  uid  uuid := auth.uid();
  moi  text;
  o    jsonb;
  p    jsonb;
  ancien jsonb := coalesce(old.ordre::jsonb, '[]'::jsonb);
  neuf   jsonb := coalesce(new.ordre::jsonb, '[]'::jsonb);
  secr boolean;
begin
  if uid is null then return new; end if;
  moi := uid::text;

  -- PV en signature ou signé : plus rien ne bouge (le secrétariat doit d'abord le retirer de la signature).
  if reu_pv_verrouille(old.id) and (
       new.titre is distinct from old.titre or new.date is distinct from old.date or new.heure is distinct from old.heure
    or new.lieu is distinct from old.lieu or new.presences::jsonb is distinct from old.presences::jsonb
    or neuf is distinct from ancien) then
    raise exception 'Le PV de cette réunion est en signature ou signé : la réunion est verrouillée.';
  end if;

  secr := (exists (select 1 from ca_meta m where m.id = 1 and coalesce(m.secretaires::text, '') like '%' || moi || '%')
     or exists (select 1 from ca_membres c where c.id = uid and c.role = 'owner')) and public.mfa_ok();
  if secr then return new; end if;

  if new.titre is distinct from old.titre
     or new.date is distinct from old.date
     or new.heure is distinct from old.heure
     or new.lieu is distinct from old.lieu
     or new.odj_envoye_at is distinct from old.odj_envoye_at
     or new.presences::jsonb is distinct from old.presences::jsonb
     or new.pv_statut is distinct from old.pv_statut
     or new.pv_approuve_le is distinct from old.pv_approuve_le
     or new.pv_approuve_note is distinct from old.pv_approuve_note then
    raise exception 'Seul le secrétariat peut modifier la réunion, les présences ou le PV.';
  end if;

  for o in select * from jsonb_array_elements(ancien) loop
    select x into p from jsonb_array_elements(neuf) x where x->>'id' = o->>'id' limit 1;
    if p is null then
      if coalesce(o->>'parId', '') <> moi then
        raise exception 'Vous ne pouvez supprimer que vos propres points.';
      end if;
      if reu_odj_ferme(old.date) then
        raise exception 'L''ordre du jour est clôturé (la veille de la réunion à 23 h 59).';
      end if;
    else
      if (p->>'texte') is distinct from (o->>'texte')
         or (p->'fait')  is distinct from (o->'fait')
         or (p->>'parId') is distinct from (o->>'parId')
         or (p->>'par')  is distinct from (o->>'par')
         or (p->>'sujet') is distinct from (o->>'sujet')
         or (p->>'note') is distinct from (o->>'note')
         or (p->>'budgetObjet') is distinct from (o->>'budgetObjet')
         or (p->>'budgetMontant') is distinct from (o->>'budgetMontant') then
        raise exception 'Seul le secrétariat peut modifier ou cocher un point.';
      end if;
      if coalesce(p->>'notes', '') is distinct from coalesce(o->>'notes', '')
         and coalesce(o->>'parId', '') <> moi then
        raise exception 'Vous ne pouvez écrire des notes que sous vos propres points.';
      end if;
    end if;
  end loop;

  for p in select * from jsonb_array_elements(neuf) loop
    if not exists (select 1 from jsonb_array_elements(ancien) x where x->>'id' = p->>'id') then
      if coalesce(p->>'parId', '') <> moi then
        raise exception 'Un nouveau point doit être à votre nom.';
      end if;
      if coalesce(p->>'fait', 'false') = 'true' then
        raise exception 'Seul le secrétariat peut cocher un point.';
      end if;
      if reu_odj_ferme(new.date) then
        raise exception 'L''ordre du jour est clôturé (la veille de la réunion à 23 h 59).';
      end if;
      if not (coalesce(p->>'sujet', '') = any (reu_sujets())) then
        raise exception 'Choisissez un sujet dans la liste.';
      end if;
      if p->>'sujet' = 'budget' and (coalesce(trim(p->>'budgetObjet'), '') = ''
         or coalesce(nullif(p->>'budgetMontant', ''), '0')::numeric <= 0) then
        raise exception 'Demande de budget : l''objet et le montant sont obligatoires.';
      end if;
      if p->>'sujet' = 'autre' and coalesce(trim(p->>'texte'), '') = '' then
        raise exception 'Sujet « Autre » : écrivez le titre du point.';
      end if;
    end if;
  end loop;

  return new;
end $$;

-- Secrétariat : retirer un PV de la signature (tant qu'il n'est pas signé) pour le corriger.
-- Il passe en « refusé » avec un motif clair : le circuit existant « Corriger et renvoyer » s'applique.
create or replace function public.pvs_retirer(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare a ca_pv_signatures;
begin
  if not pvs_est_secretaire() then raise exception 'Réservé au secrétariat.'; end if;
  select * into a from ca_pv_signatures where id = p_id for update;
  if not found then raise exception 'PV introuvable.'; end if;
  if a.statut <> 'attente' then raise exception 'Seul un PV en attente de signature peut être retiré.'; end if;
  update ca_pv_signatures set statut = 'refuse', motif = 'Retiré de la signature par le secrétariat pour correction.',
    refus_at = now() where id = p_id;
end $$;
revoke all on function public.pvs_retirer(uuid) from anon, public;
grant execute on function public.pvs_retirer(uuid) to authenticated;

-- Ordre du jour envoyé automatiquement 1 h avant la réunion, aux membres du CA (pas les cooptés).
-- Expéditeur « ODJ Réu-BE ». Une seule fois par réunion (odj_envoye_at).
create or replace function public.reu_odj_envoyer()
returns void language plpgsql security definer set search_path = public, net as $$
declare
  r record; d record; debut timestamptz; pts text; corps text; lien text;
  e text := '<span style="color:#888">';
begin
  for r in select * from ca_reunions where odj_envoye_at is null and date is not null and heure is not null loop
    debut := (r.date + r.heure)::timestamp at time zone 'Europe/Brussels';
    continue when now() < debut - interval '1 hour' or now() >= debut;
    update ca_reunions set odj_envoye_at = now() where id = r.id and odj_envoye_at is null;
    continue when not found;

    select coalesce(string_agg(
      '<li style="margin:0 0 8px"><b>' || replace(replace(coalesce(p->>'texte', ''), '<', '&lt;'), '>', '&gt;') || '</b>'
      || case when coalesce(p->>'par', '') <> '' then ' ' || e || '— ' || replace(replace(p->>'par', '<', '&lt;'), '>', '&gt;') || '</span>' else '' end
      || case when p->>'sujet' = 'budget' then '<br>Montant demandé : <b>' || replace(to_char(coalesce(nullif(p->>'budgetMontant', '')::numeric, 0), 'FM999999990.00'), '.', ',') || ' €</b>' else '' end
      || case when coalesce(p->>'note', '') <> '' then '<br>' || e || replace(replace(p->>'note', '<', '&lt;'), '>', '&gt;') || '</span>' else '' end
      || '</li>', '' order by ord), '')
      into pts from jsonb_array_elements(coalesce(r.ordre, '[]'::jsonb)) with ordinality as t(p, ord);

    lien := 'https://bojkuesat-ai.github.io/bureau-ca/?go=reunion&r=' || r.id;
    corps := '<h2 style="margin:0 0 10px">Ordre du jour — ' || replace(replace(coalesce(r.titre, 'Réunion'), '<', '&lt;'), '>', '&gt;') || '</h2>'
      || '<p><b>Date :</b> ' || to_char(r.date, 'DD/MM/YYYY') || ' à ' || to_char(r.heure, 'HH24"h"MI') || '</p>'
      || case when coalesce(r.lieu, '') <> '' then '<p><b>Lieu :</b> ' || replace(replace(r.lieu, '<', '&lt;'), '>', '&gt;') || '</p>' else '' end
      || case when pts <> '' then '<p><b>Points :</b></p><ol style="padding-left:20px">' || pts || '</ol>' else '<p>Aucun point à l''ordre du jour.</p>' end
      || '<p><a href="' || lien || '" style="background:#241c46;color:#fff;padding:11px 20px;border-radius:8px;text-decoration:none;font-weight:bold;display:inline-block">Ouvrir la réunion</a></p>';

    for d in select distinct lower(trim(c.email)) email from ca_membres c
             where c.statut = 'actif' and coalesce(c.role, '') not in ('coopte', 'proprietaire') and not coalesce(c.hors_ca, false)
               and coalesce(c.email, '') <> ''
               and not exists (select 1 from ca_desabonnes x where lower(x.email) = lower(trim(c.email))) loop
      perform fm_mail(d.email, 'Ordre du jour — ' || coalesce(r.titre, 'Réunion') || ' (' || to_char(r.date, 'DD/MM') || ' à ' || to_char(r.heure, 'HH24"h"MI') || ')', corps, 'ODJ Réu-BE');
    end loop;
  end loop;
end $$;
revoke all on function public.reu_odj_envoyer() from anon, authenticated, public;

select cron.schedule('reunion-odj', '*/5 * * * *', $$select public.reu_odj_envoyer()$$);

-- État de signature du PV de chaque réunion, lisible par tous les membres du CA
-- (la table ca_pv_signatures reste réservée au secrétariat et au signataire).
create or replace function public.reu_pv_etats()
returns table(reunion_id text, id uuid, statut text, secretaire_nom text, sig_secr_at timestamptz,
              signataire_nom text, signataire_fonction text, sig_sign_at timestamptz, motif text, refus_at timestamptz, signe boolean)
language sql stable security definer set search_path = public as $$
  select distinct on (s.reunion_id) s.reunion_id, s.id, s.statut, s.secretaire_nom, s.sig_secr_at,
         s.signataire_nom, s.signataire_fonction, s.sig_sign_at, s.motif, s.refus_at, s.pdf_path is not null
  from ca_pv_signatures s
  where s.reunion_id is not null and ca_is_actif() and not ca__est_coopte() and mfa_ok()
  order by s.reunion_id, s.created_at desc $$;
revoke all on function public.reu_pv_etats() from anon, public;
grant execute on function public.reu_pv_etats() to authenticated;
