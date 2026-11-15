-- =====================================================================
-- Double authentification OBLIGATOIRE (15/11/2026) — Espace CA + Caisse.
-- Appliqué sur le projet (migration « mfa_obligatoire_19_11 »).
--
-- Concernés : membres actifs du CA (membre, owner, proprietaire), pas les coopté·es.
-- Date limite : mercredi 18/11/2026 23:59 ; blocage dès le jeudi 19/11/2026 00:00
-- (heure de Bruxelles) = proprio_config.mfa_obligatoire_le.
-- À partir de là, sans code à 6 chiffres validé (aal2) :
--   - mfa_ok() est faux → les politiques restrictives « mfa_aal2 » (81 tables +
--     stockage) refusent toute lecture/écriture, même pour une session restée ouverte ;
--   - ca_membres / profiles : seule sa propre ligne reste lisible (pour afficher
--     l'écran d'activation) ;
--   - app_refus_motif refuse aussi les écritures faites par les fonctions serveur
--     (signatures, décisions…) ; courrier_peut() aussi.
-- Mails « Sécurité-BE » : annonce lundi 16/11 10:00 (une fois), point mercredi 18/11
-- 18:00 à l'Admin et au propriétaire, confirmation / alerte à chaque activation ou
-- retrait (tâche mfa-suivi toutes les 5 min), remise à zéro et relance individuelle.
-- =====================================================================

alter table public.proprio_config add column if not exists mfa_obligatoire_le timestamptz;
update public.proprio_config set mfa_obligatoire_le = timestamptz '2026-11-19 00:00:00+01' where id = 1;

-- Qui est concerné
create or replace function public.mfa_concerne(p uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from ca_membres c where c.id = p and c.statut = 'actif'
                   and c.role in ('membre', 'owner', 'proprietaire')
                   and coalesce(c.via_code, '') = '' and coalesce(c.fonction, '') !~* '^coopt');
$$;
revoke all on function public.mfa_concerne(uuid) from public, anon;

-- Vrai si l'utilisateur connecté DOIT encore donner un code (obligation en vigueur, pas aal2).
create or replace function public.mfa_exige_moi()
returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null
     and coalesce((select now() >= mfa_obligatoire_le from proprio_config where id = 1), false)
     and coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2'
     and public.mfa_concerne(auth.uid());
$$;
revoke all on function public.mfa_exige_moi() from public, anon;
grant execute on function public.mfa_exige_moi() to authenticated;

-- mfa_ok_base = ancien mfa_ok (code exigé si un facteur existe) ; mfa_ok ajoute l'obligation.
create or replace function public.mfa_ok_base()
returns boolean language sql stable security definer set search_path to '' as $$
  select coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2'
      or not exists (select 1 from auth.mfa_factors f where f.user_id = auth.uid() and f.status = 'verified')
$$;
grant execute on function public.mfa_ok_base() to authenticated;
create or replace function public.mfa_ok()
returns boolean language sql stable security definer set search_path to '' as $$
  select public.mfa_ok_base() and not public.mfa_exige_moi()
$$;

-- Sa propre fiche reste lisible (écran d'activation), le reste non.
drop policy if exists mfa_aal2 on public.ca_membres;
create policy mfa_aal2 on public.ca_membres as restrictive for all to authenticated
  using ((select public.mfa_ok_base()) and (id = auth.uid() or (select not public.mfa_exige_moi())))
  with check ((select public.mfa_ok_base()) and (select not public.mfa_exige_moi()));
drop policy if exists mfa_aal2 on public.profiles;
create policy mfa_aal2 on public.profiles as restrictive for all to authenticated
  using ((select public.mfa_ok_base()) and (id = auth.uid() or (select not public.mfa_exige_moi())))
  with check ((select public.mfa_ok_base()) and (select not public.mfa_exige_moi()));

-- Tables récentes sans la politique restrictive
drop policy if exists mfa_aal2 on public.ca_pv_signatures;
create policy mfa_aal2 on public.ca_pv_signatures as restrictive for all to authenticated
  using ((select public.mfa_ok())) with check ((select public.mfa_ok()));
drop policy if exists mfa_aal2 on public.ca_courriers;
create policy mfa_aal2 on public.ca_courriers as restrictive for all to authenticated
  using ((select public.mfa_ok())) with check ((select public.mfa_ok()));
create or replace function public.courrier_peut()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from ca_membres c
                  where c.id = auth.uid() and c.statut = 'actif'
                    and c.role in ('membre', 'owner') and not coalesce(c.hors_ca, false))
     and not public.mfa_exige_moi();
$$;

-- Écritures faites par les fonctions serveur (elles passent outre les politiques)
create or replace function public.app_refus_motif(p_app text, p_module text)
returns text language plpgsql stable security definer set search_path to 'public' as $function$
declare c proprio_config; v text;
begin
  if current_setting('app.proprio_bypass', true) = '1' then return ''; end if;
  if auth.uid() is null and coalesce(auth.role(), '') <> 'anon' then return ''; end if;
  if auth.uid() is not null and public.mfa_exige_moi() then
    return 'Double authentification obligatoire : activez-la (écran 🔐 à la connexion) pour continuer.';
  end if;
  if auth.uid() is not null and public.ca_is_owner() then return ''; end if;
  if p_app is not null and public.proprio_retire_moi() then return 'Accès retiré depuis la passation.'; end if;
  select * into c from proprio_config where id = 1;
  if p_app is not null then
    v := coalesce(c.etat ->> p_app, 'ouverte');
    if v = 'fermee' then return 'L''application est fermée par le propriétaire.'; end if;
    if v = 'lecture' then return 'L''application est en lecture seule (décision du propriétaire).'; end if;
    if c.mode_licence and (select l.id from licence_courante() l) is null then
      return 'Licence absente ou expirée : l''application est en lecture seule. L''Admin peut demander une licence dans l''Espace CA.';
    end if;
  end if;
  if p_module is not null and not public.module_actif(p_module) then
    return 'Le module « ' || p_module || ' » n''est pas activé.';
  end if;
  return '';
end $function$;

-- ---------------------------------------------------------------------
-- État pour les pages (bandeau, compte à rebours, écran d'activation)
-- ---------------------------------------------------------------------
create or replace function public.mfa_statut()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'exige_le', (select mfa_obligatoire_le from proprio_config where id = 1),
    'maintenant', now(),
    'concerne', public.mfa_concerne(auth.uid()),
    'a_mfa', public.a_mfa(auth.uid()),
    'aal2', coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2',
    'bloque', public.mfa_exige_moi());
$$;
revoke all on function public.mfa_statut() from public, anon;
grant execute on function public.mfa_statut() to authenticated;

-- ---------------------------------------------------------------------
-- Mails « Sécurité-BE »
-- ---------------------------------------------------------------------
create or replace function public.mfa_mail(p_to text, p_sujet text, p_html text)
returns void language plpgsql security definer set search_path to 'public', 'net' as $function$
declare v_anon text := 'sb_publishable_xoVRiE99YOepw-sb5Tmtcg_SJ3VE_0s';
begin
  if coalesce(p_to, '') = '' then return; end if;
  perform net.http_post(
    url := 'https://mlgzdfyqjhvyubrywuim.supabase.co/functions/v1/send-email',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_anon, 'apikey', v_anon,
                 'x-cron-secret', (select cron_secret from public.bil_config where id = 1)),
    body := jsonb_build_object('to', p_to, 'subject', p_sujet, 'from', 'Sécurité-BE <noreply@bureauetuidant.xyz>',
      'html', '<div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:0 auto;color:#1a1a2e;line-height:1.5">' || p_html
        || '<p style="color:#999;font-size:12px;margin-top:22px">Message automatique — applications du Bureau étudiant. Ne pas répondre.</p></div>'),
    timeout_milliseconds := 20000);
end $function$;
revoke all on function public.mfa_mail(text, text, text) from public, anon, authenticated;

create or replace function public.mfa_boutons()
returns text language sql immutable as $$
  select '<p style="text-align:center;margin:22px 0"><a href="https://bojkuesat-ai.github.io/bureau-ca/" style="background:#241c46;color:#fff;padding:11px 20px;border-radius:8px;text-decoration:none;display:inline-block;margin:4px">Ouvrir l''Espace CA</a> '
      || '<a href="https://bojkuesat-ai.github.io/bureau-ca/caisse/" style="background:#9c7628;color:#fff;padding:11px 20px;border-radius:8px;text-decoration:none;display:inline-block;margin:4px">Ouvrir la Caisse</a></p>';
$$;

-- Guide complet (annonce et relance). p_apres : obligation déjà en vigueur.
create or replace function public.mfa_guide_html(p_prenom text, p_apres boolean)
returns text language sql stable as $$
  select '<h2 style="margin:0 0 10px">🔐 Double authentification obligatoire</h2>'
    || '<p>Bonjour' || coalesce(' ' || public.ca_html(nullif(trim(p_prenom), '')), '') || ',</p>'
    || case when p_apres then
         '<p>La <b>double authentification</b> est désormais <b>obligatoire</b> pour entrer dans l''<b>Espace CA</b> et dans la <b>Caisse</b>. '
         || 'À votre prochaine connexion, l''app vous demandera de l''activer : cela prend une minute.</p>'
       else
         '<div style="background:#fff4e0;border:1px solid #e8b04b;border-radius:10px;padding:12px 14px;margin:12px 0">'
         || '<b>À faire au plus tard le mercredi 18 novembre 2026 à 23 h 59.</b><br>'
         || 'À partir du <b>jeudi 19 novembre à 00 h</b>, l''<b>Espace CA</b> et la <b>Caisse</b> ne s''ouvriront plus sans double authentification.</div>'
       end
    || '<p>Concrètement : après votre mot de passe, l''app vous demandera un <b>code à 6 chiffres</b> affiché par une application sur votre téléphone. '
    || 'Même si quelqu''un connaît votre mot de passe, il ne pourra pas entrer sans votre téléphone. '
    || '<b>Une seule activation suffit</b> pour l''Espace CA et la Caisse (même compte).</p>'
    || '<h3 style="margin:18px 0 6px">Comment faire (1 minute)</h3>'
    || '<ol style="padding-left:20px;margin:0">'
    || '<li style="margin:6px 0"><b>Sur votre téléphone</b>, installez une application gratuite : <b>Google Authenticator</b> ou <b>Microsoft Authenticator</b> (App Store ou Google Play).</li>'
    || '<li style="margin:6px 0"><b>Ouvrez l''Espace CA ou la Caisse</b>, de préférence <b>sur un ordinateur</b>, connectez-vous et cliquez sur <b>« Activer »</b> dans le bandeau 🔐.</li>'
    || '<li style="margin:6px 0">Dans l''application du téléphone : touchez <b>« + »</b> (ou « Ajouter un compte »), puis <b>« Scanner un QR code »</b>, et scannez le carré affiché à l''écran.<br>'
    || '<span style="color:#666">Vous n''avez que votre téléphone ? Choisissez plutôt <b>« Saisir une clé »</b> et copiez la clé affichée sous le QR code.</span></li>'
    || '<li style="margin:6px 0">L''application affiche un <b>code à 6 chiffres</b> : tapez-le dans l''Espace CA ou la Caisse, puis <b>« Activer »</b>. C''est fait ✅</li></ol>'
    || '<p>Ensuite, à chaque nouvelle connexion : mot de passe, puis le code affiché à ce moment-là dans l''application.</p>'
    || '<h3 style="margin:18px 0 6px">Bon à savoir</h3><ul style="padding-left:20px;margin:0">'
    || '<li style="margin:5px 0">Le code change toutes les 30 secondes : tapez toujours celui affiché <b>maintenant</b>.</li>'
    || '<li style="margin:5px 0">Code refusé alors qu''il est bon ? Vérifiez que l''<b>heure du téléphone est réglée automatiquement</b>.</li>'
    || '<li style="margin:5px 0"><b>Astuce secours</b> : au moment de l''activation, scannez le même QR code avec un <b>deuxième appareil</b> (tablette, ancien téléphone). Les deux afficheront le même code.</li>'
    || '<li style="margin:5px 0"><b>Téléphone perdu ou changé ?</b> Contactez l''Admin du CA : il remet votre double authentification à zéro et vous la réactivez en une minute.</li>'
    || '<li style="margin:5px 0">Pas de smartphone ? Contactez l''Admin : on trouvera une solution.</li></ul>'
    || public.mfa_boutons();
$$;

-- Annonce : lundi 16/11/2026 10:00 (une seule fois)
create table if not exists public.mfa_annonces (membre_id uuid primary key, le timestamptz not null default now());
alter table public.mfa_annonces enable row level security;
revoke all on public.mfa_annonces from anon, authenticated, public;

create or replace function public.mfa_annonce_envoyer()
returns integer language plpgsql security definer set search_path = public as $$
declare m record; n int := 0;
begin
  if now() < (select mfa_obligatoire_le from proprio_config where id = 1) then
    for m in
      select c.id, c.email, c.prenom from ca_membres c
       where public.mfa_concerne(c.id) and coalesce(c.email, '') <> '' and not public.a_mfa(c.id)
         and not exists (select 1 from mfa_annonces a where a.membre_id = c.id)
    loop
      perform mfa_mail(m.email, '🔐 À faire avant mercredi 18/11 : activez la double authentification', mfa_guide_html(m.prenom, false));
      insert into mfa_annonces (membre_id) values (m.id) on conflict do nothing;
      n := n + 1;
    end loop;
  end if;
  begin perform cron.unschedule('mfa_annonce_1611'); exception when others then null; end;
  return n;
end $$;
revoke all on function public.mfa_annonce_envoyer() from public, anon, authenticated;

-- Point mercredi 18/11/2026 18:00 : qui ne l'a pas encore fait (Admin + propriétaire)
create or replace function public.mfa_point_envoyer()
returns integer language plpgsql security definer set search_path = public as $$
declare v_liste text := ''; v_n int := 0; d record; n int := 0;
begin
  if now() < (select mfa_obligatoire_le from proprio_config where id = 1) then
    select count(*), coalesce(string_agg('<li>' || ca_html(coalesce(nullif(trim(coalesce(prenom,'') || ' ' || coalesce(nom,'')), ''), email))
             || coalesce(' — ' || ca_html(nullif(fonction, '')), '') || '</li>', '' order by prenom, nom), '')
      into v_n, v_liste
      from ca_membres c where public.mfa_concerne(c.id) and not public.a_mfa(c.id);
    for d in select distinct email from ca_membres
              where statut = 'actif' and coalesce(email, '') <> '' and (role in ('owner', 'proprietaire') or (admin and role not in ('coopte')))
    loop
      perform mfa_mail(d.email,
        case when v_n = 0 then '✅ Double authentification : tout le CA l''a activée'
             else '🔐 Double authentification : ' || v_n || ' membre' || case when v_n > 1 then 's' else '' end || ' ne l''ont pas encore activée' end,
        '<h2 style="margin:0 0 10px">Point avant le blocage de cette nuit</h2>'
        || '<p>À <b>00 h</b> (jeudi 19/11), l''Espace CA et la Caisse ne s''ouvriront plus sans double authentification.</p>'
        || case when v_n = 0 then '<p>✅ Tous les membres du CA l''ont activée.</p>'
           else '<p>Ne l''ont pas encore activée (' || v_n || ') :</p><ul>' || v_liste || '</ul>'
             || '<p>Vous pouvez les relancer une à une dans <b>Admin › Double authentification</b>. Après le blocage, ils pourront encore l''activer à la connexion.</p>' end
        || mfa_boutons());
      n := n + 1;
    end loop;
  end if;
  begin perform cron.unschedule('mfa_point_1811'); exception when others then null; end;
  return n;
end $$;
revoke all on function public.mfa_point_envoyer() from public, anon, authenticated;

-- Confirmation / alerte : surveille les facteurs toutes les 5 minutes
create table if not exists public.mfa_suivi_etat (user_id uuid primary key, nb int not null, maj timestamptz not null default now());
alter table public.mfa_suivi_etat enable row level security;
revoke all on public.mfa_suivi_etat from anon, authenticated, public;
insert into public.mfa_suivi_etat (user_id, nb)
  select c.id, (select count(*) from auth.mfa_factors f where f.user_id = c.id and f.status = 'verified')
    from public.ca_membres c where public.mfa_concerne(c.id)
on conflict (user_id) do nothing;

create or replace function public.mfa_suivi_scan()
returns integer language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; v_quand text := to_char(now() at time zone 'Europe/Brussels', 'DD/MM/YYYY à HH24:MI');
begin
  for r in
    select c.id, c.email, c.prenom, e.nb ancien,
           (select count(*) from auth.mfa_factors f where f.user_id = c.id and f.status = 'verified')::int nb
      from ca_membres c left join mfa_suivi_etat e on e.user_id = c.id
     where public.mfa_concerne(c.id)
  loop
    if r.ancien is null then
      insert into mfa_suivi_etat (user_id, nb) values (r.id, r.nb) on conflict (user_id) do update set nb = excluded.nb, maj = now();
    elsif r.ancien = 0 and r.nb > 0 then
      perform mfa_mail(r.email, '✅ Double authentification activée',
        '<h2 style="margin:0 0 10px">✅ Double authentification activée</h2><p>Bonjour' || coalesce(' ' || ca_html(nullif(trim(r.prenom), '')), '') || ',</p>'
        || '<p>La double authentification a été activée sur votre compte le <b>' || v_quand || '</b>. Merci !</p>'
        || '<p>À chaque nouvelle connexion (Espace CA ou Caisse), le code à 6 chiffres de votre application sera demandé après le mot de passe.</p>'
        || '<p style="color:#a33"><b>Ce n''est pas vous ?</b> Changez votre mot de passe et prévenez l''Admin du CA immédiatement.</p>');
      update mfa_suivi_etat set nb = r.nb, maj = now() where user_id = r.id; n := n + 1;
    elsif r.ancien > 0 and r.nb = 0 then
      perform mfa_mail(r.email, '⚠️ Double authentification retirée de votre compte',
        '<h2 style="margin:0 0 10px">⚠️ Double authentification retirée</h2><p>Bonjour' || coalesce(' ' || ca_html(nullif(trim(r.prenom), '')), '') || ',</p>'
        || '<p>La double authentification a été <b>retirée</b> de votre compte le <b>' || v_quand || '</b>. Elle est obligatoire : réactivez-la à votre prochaine connexion.</p>'
        || '<p style="color:#a33"><b>Ce n''est pas vous ?</b> Changez votre mot de passe et prévenez l''Admin du CA immédiatement.</p>' || mfa_boutons());
      update mfa_suivi_etat set nb = 0, maj = now() where user_id = r.id; n := n + 1;
    elsif r.nb <> r.ancien then
      update mfa_suivi_etat set nb = r.nb, maj = now() where user_id = r.id;
    end if;
  end loop;
  return n;
end $$;
revoke all on function public.mfa_suivi_scan() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Suivi, relance et remise à zéro (Admin et propriétaire)
-- ---------------------------------------------------------------------
create or replace function public.mfa_gestion_ok()
returns boolean language sql stable security definer set search_path = public as $$
  select public.ca_est_admin() or public.proprio_est();
$$;

create table if not exists public.mfa_relances (id bigint generated by default as identity primary key, membre_id uuid not null, par uuid, le timestamptz not null default now());
alter table public.mfa_relances enable row level security;
revoke all on public.mfa_relances from anon, authenticated, public;

create or replace function public.mfa_suivi()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not mfa_gestion_ok() then raise exception 'Réservé à l''Admin et au propriétaire.'; end if;
  return jsonb_build_object('exige_le', (select mfa_obligatoire_le from proprio_config where id = 1), 'membres', coalesce((
    select jsonb_agg(jsonb_build_object('id', c.id,
      'nom', coalesce(nullif(trim(coalesce(c.prenom,'') || ' ' || coalesce(c.nom,'')), ''), c.email),
      'fonction', c.fonction, 'role', c.role,
      'a_mfa', public.a_mfa(c.id),
      'active_le', (select min(f.created_at) from auth.mfa_factors f where f.user_id = c.id and f.status = 'verified'),
      'relance_le', (select max(r.le) from mfa_relances r where r.membre_id = c.id),
      'annonce_le', (select a.le from mfa_annonces a where a.membre_id = c.id))
      order by public.a_mfa(c.id), c.prenom, c.nom)
    from ca_membres c where public.mfa_concerne(c.id)), '[]'::jsonb));
end $$;
revoke all on function public.mfa_suivi() from public, anon;
grant execute on function public.mfa_suivi() to authenticated;

create or replace function public.mfa_relancer(p_membre uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c ca_membres; v_der timestamptz;
begin
  if not mfa_gestion_ok() then raise exception 'Réservé à l''Admin et au propriétaire.'; end if;
  select * into c from ca_membres where id = p_membre;
  if not found or not mfa_concerne(p_membre) then raise exception 'Membre introuvable ou non concerné.'; end if;
  if a_mfa(p_membre) then raise exception 'Cette personne a déjà activé la double authentification.'; end if;
  if coalesce(c.email, '') = '' then raise exception 'Pas d''adresse e-mail pour cette personne.'; end if;
  select max(le) into v_der from mfa_relances where membre_id = p_membre;
  if v_der > now() - interval '6 hours' then raise exception 'Déjà relancé(e) il y a moins de 6 heures.'; end if;
  perform mfa_mail(c.email, 'Rappel : activez la double authentification',
    mfa_guide_html(c.prenom, now() >= (select mfa_obligatoire_le from proprio_config where id = 1)));
  insert into mfa_relances (membre_id, par) values (p_membre, auth.uid());
  insert into ca_journal (who, txt) values (coalesce((select trim(coalesce(prenom,'') || ' ' || coalesce(nom,'')) from ca_membres where id = auth.uid()), '—'),
    'Double authentification — relance envoyée à ' || coalesce(nullif(trim(coalesce(c.prenom,'') || ' ' || coalesce(c.nom,'')), ''), c.email));
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.mfa_relancer(uuid) from public, anon;
grant execute on function public.mfa_relancer(uuid) to authenticated;

create or replace function public.mfa_reinitialiser(p_membre uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c ca_membres; v_qui text; v_n int;
begin
  if not mfa_gestion_ok() then raise exception 'Réservé à l''Admin et au propriétaire.'; end if;
  if p_membre = auth.uid() then raise exception 'Vous ne pouvez pas remettre à zéro votre propre double authentification.'; end if;
  select * into c from ca_membres where id = p_membre;
  if not found then raise exception 'Membre introuvable.'; end if;
  if c.role in ('owner', 'proprietaire') and not proprio_est() then raise exception 'Seul le propriétaire peut faire cela pour son compte.'; end if;
  delete from auth.mfa_factors where user_id = p_membre;
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'Cette personne n''a pas de double authentification à remettre à zéro.'; end if;
  delete from auth.sessions where user_id = p_membre;   -- déconnecte tous ses appareils
  insert into mfa_suivi_etat (user_id, nb) values (p_membre, 0) on conflict (user_id) do update set nb = 0, maj = now();
  select coalesce(nullif(trim(coalesce(prenom,'') || ' ' || coalesce(nom,'')), ''), email) into v_qui from ca_membres where id = auth.uid();
  insert into ca_journal (who, txt) values (coalesce(v_qui, '—'),
    'Double authentification remise à zéro pour ' || coalesce(nullif(trim(coalesce(c.prenom,'') || ' ' || coalesce(c.nom,'')), ''), c.email));
  perform mfa_mail(c.email, '🔐 Votre double authentification a été remise à zéro',
    '<h2 style="margin:0 0 10px">🔐 Double authentification remise à zéro</h2><p>Bonjour' || coalesce(' ' || ca_html(nullif(trim(c.prenom), '')), '') || ',</p>'
    || '<p><b>' || ca_html(coalesce(v_qui, 'L''Admin')) || '</b> a remis à zéro la double authentification de votre compte le <b>'
    || to_char(now() at time zone 'Europe/Brussels', 'DD/MM/YYYY à HH24:MI') || '</b>, et vos appareils ont été déconnectés.</p>'
    || '<p>À votre prochaine connexion, l''app vous demandera de la <b>réactiver</b> (1 minute) : installez Google Authenticator ou Microsoft Authenticator, scannez le QR code affiché, puis tapez le code à 6 chiffres.</p>'
    || '<p style="color:#a33"><b>Vous n''avez rien demandé ?</b> Prévenez l''Admin du CA immédiatement.</p>' || mfa_boutons());
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.mfa_reinitialiser(uuid) from public, anon;
grant execute on function public.mfa_reinitialiser(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Tâches planifiées (UTC) : 16/11 10:00 et 18/11 18:00 heure de Bruxelles
-- ---------------------------------------------------------------------
select cron.schedule('mfa_annonce_1611', '0 9 16 11 *', $$select public.mfa_annonce_envoyer()$$);
select cron.schedule('mfa_point_1811', '0 17 18 11 *', $$select public.mfa_point_envoyer()$$);
select cron.schedule('mfa-suivi', '*/5 * * * *', $$select public.mfa_suivi_scan()$$);

-- Ajout 15/11 (migration mfa_rapport_jeudi) : bilan au propriétaire seul, jeudi 19/11 09:00 Bruxelles.
-- public.mfa_rapport_proprio() : liste activée / pas activée → owner/proprietaire, puis se désinscrit.
-- select cron.schedule('mfa_rapport_1911', '0 8 19 11 *', $$select public.mfa_rapport_proprio()$$);
