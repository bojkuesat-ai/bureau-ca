-- Rapport de trésorerie du 16/11/2026 à Rania : demain 10 h, rappel 13 h (heure de Bruxelles).
-- Table d'envois programmés de la trésorerie : chaque ligne part une fois, puis sa tâche cron se retire.
create table if not exists public.treso_mails_programmes (
  cle text primary key, a text not null, sujet text not null, html text not null, exp text not null,
  pdf_nom text, pdf_b64 text, job text, envoye_at timestamptz, created_at timestamptz default now());
alter table public.treso_mails_programmes enable row level security;
revoke all on public.treso_mails_programmes from anon, authenticated, public;

create or replace function public.treso_mail_programme_envoyer(p_cle text)
returns void language plpgsql security definer set search_path = public, net as $$
declare m treso_mails_programmes; v_anon text := 'sb_publishable_xoVRiE99YOepw-sb5Tmtcg_SJ3VE_0s'; v_body jsonb;
begin
  select * into m from treso_mails_programmes where cle = p_cle for update;
  if not found or m.envoye_at is not null then
    if m.job is not null then begin perform cron.unschedule(m.job); exception when others then null; end; end if;
    return; end if;
  v_body := jsonb_build_object('to', m.a, 'subject', m.sujet, 'from', m.exp || ' <noreply@bureauetuidant.xyz>',
    'html', '<div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:0 auto;color:#1a1a2e;line-height:1.5">' || m.html
      || '<p style="color:#999;font-size:12px;margin-top:22px">Message automatique — applications du Bureau étudiant. Ne pas répondre.</p></div>');
  if m.pdf_b64 is not null then
    v_body := v_body || jsonb_build_object('attachments', jsonb_build_array(jsonb_build_object('filename', m.pdf_nom, 'content', m.pdf_b64, 'contentType', 'application/pdf')));
  end if;
  perform net.http_post(url := 'https://mlgzdfyqjhvyubrywuim.supabase.co/functions/v1/send-email',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_anon, 'apikey', v_anon,
                 'x-cron-secret', (select cron_secret from bil_config where id = 1)),
    body := v_body, timeout_milliseconds := 30000);
  update treso_mails_programmes set envoye_at = now() where cle = p_cle;
  if m.job is not null then begin perform cron.unschedule(m.job); exception when others then null; end; end if;
end $$;
revoke all on function public.treso_mail_programme_envoyer(text) from anon, authenticated, public;

-- Les deux lignes (destinataire, texte, PDF en base64) ont été insérées directement dans la base,
-- pas dans ce dépôt public : le PDF contient des chiffres de la trésorerie.
--   cle 'rapport-2026-11-16'        → job treso_rapport_1711_10h
--   cle 'rapport-2026-11-16-rappel' → job treso_rapport_1711_13h

-- Heures en UTC : 10 h et 13 h à Bruxelles le 17/11 = 9 h et 12 h UTC.
select cron.schedule('treso_rapport_1711_10h', '0 9 17 11 *', $$select public.treso_mail_programme_envoyer('rapport-2026-11-16')$$);
select cron.schedule('treso_rapport_1711_13h', '0 12 17 11 *', $$select public.treso_mail_programme_envoyer('rapport-2026-11-16-rappel')$$);
