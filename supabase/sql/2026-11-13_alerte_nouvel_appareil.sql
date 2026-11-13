-- =====================================================================
-- CA + Caisse (13/11/2026) — mail « Nouvelle connexion » au titulaire du compte.
-- Appliqué sur le projet (migration « alerte_nouvel_appareil »).
--
-- Quand un compte se connecte (CA ou Caisse) depuis un appareil jamais vu pour ce
-- compte, la personne reçoit un mail de Securite-BE : app, appareil, date, adresse IP.
-- Une seule alerte par appareil, quelle que soit l'app (les deux apps partagent
-- l'identifiant « be:appareil-id » du navigateur). Le propriétaire n'en reçoit pas
-- de copie. Tout est décidé ici, dans audit_noter (catégorie « connexion »).
-- - Premier appareil d'un compte (aucun connu) : enregistré sans mail.
-- - Appareils déjà vus dans le journal avant la mise en place : repris sans mail.
-- - Au plus 5 alertes par compte et par heure.
-- - Une erreur ici ne bloque jamais la connexion ni le journal.
-- Limite : navigation privée, cache vidé ou autre navigateur = nouvel appareil.
-- =====================================================================

create table if not exists public.securite_appareils (
  user_id      uuid not null,
  appareil_id  text not null,
  appareil     text,
  premiere_app text,
  premiere_vue timestamptz not null default now(),
  derniere_vue timestamptz not null default now(),
  alerte_le    timestamptz,
  primary key (user_id, appareil_id)
);
alter table public.securite_appareils enable row level security;
revoke all on public.securite_appareils from anon, authenticated, public;

-- Reprise des appareils déjà connus (aucun mail pour eux).
insert into public.securite_appareils (user_id, appareil_id, appareil, premiere_app, premiere_vue, derniere_vue)
select membre_id, appareil_id, (array_agg(appareil order by le desc))[1], (array_agg(app order by le))[1], min(le), max(le)
  from public.ca_audit
 where categorie = 'connexion' and app in ('ca', 'caisse') and membre_id is not null and coalesce(appareil_id, '') <> ''
 group by membre_id, appareil_id
on conflict do nothing;

create or replace function public.securite_appareil_vu(p_uid uuid, p_app text, p_appareil_id text, p_appareil text)
returns void language plpgsql security definer set search_path = public, net as $$
declare v_connus int; v_email text; v_ip text; v_quand text; v_app text; v_appareil text; v_anon text := 'sb_publishable_xoVRiE99YOepw-sb5Tmtcg_SJ3VE_0s';
begin
  if p_uid is null or coalesce(p_appareil_id, '') = '' or p_app not in ('ca', 'caisse') then return; end if;
  update securite_appareils set derniere_vue = now(), appareil = coalesce(nullif(p_appareil, ''), appareil)
   where user_id = p_uid and appareil_id = p_appareil_id;
  if found then return; end if;

  select count(*) into v_connus from securite_appareils where user_id = p_uid;
  insert into securite_appareils (user_id, appareil_id, appareil, premiere_app) values (p_uid, p_appareil_id, left(p_appareil, 200), p_app)
    on conflict do nothing;
  if not found or v_connus = 0 then return; end if;                       -- premier appareil : pas de mail
  if (select count(*) from securite_appareils where user_id = p_uid and alerte_le > now() - interval '1 hour') >= 5 then return; end if;

  select email into v_email from auth.users where id = p_uid;
  if coalesce(v_email, '') = '' then return; end if;
  begin v_ip := split_part(current_setting('request.headers', true)::json->>'x-forwarded-for', ',', 1); exception when others then v_ip := null; end;
  v_quand := to_char(now() at time zone 'Europe/Brussels', 'DD/MM/YYYY à HH24"h"MI');
  v_app := case p_app when 'caisse' then 'la Caisse' else 'l''Espace CA' end;
  v_appareil := replace(replace(coalesce(nullif(p_appareil, ''), 'Appareil inconnu'), '<', '&lt;'), '>', '&gt;');

  perform net.http_post(
    url := 'https://mlgzdfyqjhvyubrywuim.supabase.co/functions/v1/send-email',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_anon, 'apikey', v_anon,
                 'x-cron-secret', (select cron_secret from public.bil_config where id = 1)),
    body := jsonb_build_object('to', v_email, 'subject', '🔐 Nouvelle connexion à votre compte', 'from', 'Securite-BE <noreply@bureauetuidant.xyz>',
      'html', '<div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:0 auto;color:#1a1a2e">'
        || '<h2 style="margin:0 0 10px">🔐 Nouvelle connexion à votre compte</h2>'
        || '<p>Votre compte vient d''être utilisé pour se connecter à ' || v_app || ' depuis un appareil qu''il n''avait encore jamais utilisé.</p>'
        || '<table style="font-size:14px;border-collapse:collapse;margin:10px 0">'
        || '<tr><td style="color:#666;padding:3px 14px 3px 0">Appareil</td><td><b>' || v_appareil || '</b></td></tr>'
        || '<tr><td style="color:#666;padding:3px 14px 3px 0">Quand</td><td><b>' || v_quand || '</b></td></tr>'
        || case when coalesce(v_ip, '') <> '' then '<tr><td style="color:#666;padding:3px 14px 3px 0">Adresse IP</td><td>' || replace(replace(v_ip, '<', ''), '>', '') || '</td></tr>' else '' end
        || '</table>'
        || '<p>Si c''était vous (nouveau téléphone, autre navigateur, navigation privée), vous n''avez rien à faire.</p>'
        || '<p style="background:#fdf3f3;border:1px solid #e8c4c4;border-radius:8px;padding:12px"><b>Si ce n''était pas vous :</b> changez votre mot de passe tout de suite et prévenez le propriétaire de l''application.</p>'
        || '<p style="color:#999;font-size:12px">Alerte automatique de sécurité — Le bureau étudiant. Vous recevez ce mail une seule fois par appareil.</p></div>'));
  update securite_appareils set alerte_le = now() where user_id = p_uid and appareil_id = p_appareil_id;
end $$;
revoke all on function public.securite_appareil_vu(uuid, text, text, text) from anon, authenticated, public;

-- Branché dans audit_noter (appelé par les apps à chaque connexion, après la double authentification).
create or replace function public.audit_noter(p_app text, p_categorie text, p_action text, p_cible text DEFAULT NULL::text, p_details jsonb DEFAULT NULL::jsonb, p_appareil text DEFAULT NULL::text, p_appareil_id text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is null then return; end if;
  if p_categorie not in ('connexion','navigation','mails','billetterie','caisse','procuration','votes','reunions','evenements','docs','salle','comptes') then return; end if;
  -- Nouvel appareil : mail au titulaire du compte (ne bloque jamais la suite).
  if p_categorie = 'connexion' then
    begin perform public.securite_appareil_vu(auth.uid(), p_app, p_appareil_id, p_appareil);
    exception when others then raise warning 'securite_appareil_vu : % %', sqlstate, sqlerrm; end;
  end if;
  -- Onglets : pas deux fois le même en 2 minutes.
  if p_categorie = 'navigation' and exists(select 1 from public.ca_audit where membre_id = auth.uid() and categorie = 'navigation'
       and action = left(p_action,300) and app = p_app and le > now() - interval '2 minutes') then return; end if;
  if (select count(*) from public.ca_audit where membre_id = auth.uid() and le > now() - interval '1 minute') > 120 then return; end if;
  perform public.audit_ecrire(auth.uid(), null, p_app, p_categorie, p_action, p_cible, p_details, null, null, p_appareil, p_appareil_id);
end $function$;
