-- =====================================================================
-- Caisse (13/11/2026) — décision du trésorier en une seule étape serveur.
-- Appliqué sur le projet (migration « caisse_decider »).
--
-- Avant : le navigateur changeait le statut, puis écrivait l'historique, puis
-- envoyait le mail, en trois appels séparés. Un onglet fermé ou une coupure
-- réseau au milieu laissait une décision sans historique ou sans mail, et le
-- nom inscrit dans l'historique venait du navigateur.
--
-- Maintenant : public.caisse_decider fait tout dans la même transaction :
--   1. change la demande si elle a toujours le statut attendu (sinon « conflit ») ;
--      les triggers habituels s'appliquent (budget, verrou, mot de passe frais,
--      code de vérification…) ;
--   2. écrit l'historique (events), nom du trésorier lu sur le serveur ;
--   3. met le mail au membre en file d'envoi (pg_net → send-email), adresse lue
--      sur le serveur ; le texte vient de l'app, « {{CODE_DECISION}} » y est
--      remplacé par le code délivré ; le mail est noté dans caisse_mails.
-- Si une étape échoue, rien n'est enregistré, et le mail ne part pas.
-- L'envoi effectif est asynchrone : caisse_mails.net_id garde la référence de
-- la requête, caisse_mail_statut() la lit, et la tâche « caisse-mails-statuts »
-- reporte le résultat (ok / erreur) dans caisse_mails toutes les 10 minutes.
-- =====================================================================

alter table public.caisse_mails add column if not exists net_id bigint;

create or replace function public.caisse_decider(
  p_id uuid, p_statut_attendu text, p_patch jsonb, p_evenement text, p_mail jsonb default null)
returns jsonb language plpgsql security definer set search_path = public, net as $$
declare
  v_cles text[] := array['status','decision_note','decided_at','paid_at','pay_mode','attachments',
                         'reexamen_msg','reexamen_at','exported_at'];
  k text; q requests; v_avant text; v_nom text; v_to text; v_html text; v_sujet text;
  v_net bigint; v_code text; v_change boolean;
begin
  if auth.uid() is null then raise exception 'Connexion requise.'; end if;
  if not is_tresorier() then raise exception 'Réservé au trésorier.'; end if;
  if not mfa_ok() then raise exception 'Entrez votre code de double authentification.'; end if;
  if jsonb_typeof(p_patch) <> 'object' then raise exception 'Modification invalide.'; end if;
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any(v_cles)) then raise exception 'Champ non autorisé : %', k; end if;
  end loop;

  select status into v_avant from requests where id = p_id for update;
  if not found then raise exception 'Demande introuvable.'; end if;
  if v_avant is distinct from p_statut_attendu then
    return jsonb_build_object('ok', false, 'conflit', true, 'statut', v_avant);
  end if;

  update requests set
    status        = case when p_patch ? 'status'        then p_patch->>'status'                   else status end,
    decision_note = case when p_patch ? 'decision_note' then p_patch->>'decision_note'            else decision_note end,
    decided_at    = case when p_patch ? 'decided_at'    then (p_patch->>'decided_at')::timestamptz else decided_at end,
    paid_at       = case when p_patch ? 'paid_at'       then (p_patch->>'paid_at')::timestamptz    else paid_at end,
    pay_mode      = case when p_patch ? 'pay_mode'      then p_patch->>'pay_mode'                 else pay_mode end,
    attachments   = case when p_patch ? 'attachments'   then p_patch->'attachments'               else attachments end,
    reexamen_msg  = case when p_patch ? 'reexamen_msg'  then p_patch->>'reexamen_msg'             else reexamen_msg end,
    reexamen_at   = case when p_patch ? 'reexamen_at'   then (p_patch->>'reexamen_at')::timestamptz else reexamen_at end,
    exported_at   = case when p_patch ? 'exported_at'   then (p_patch->>'exported_at')::timestamptz else exported_at end
  where id = p_id
  returning * into q;

  v_change := q.status is distinct from v_avant;
  v_code := case when v_change then q.decision_code else null end;
  select name into v_nom from profiles where id = auth.uid();

  insert into events (request_id, who, what)
  values (p_id, coalesce(v_nom, ''), left(coalesce(nullif(p_evenement, ''), 'Décision du trésorier')
    || case when v_code is not null then ' — code de vérification ' || v_code else '' end, 1000));

  if p_mail is not null and jsonb_typeof(p_mail) = 'object' then
    select email into v_to from profiles where id = q.user_id;
    if coalesce(v_to, '') = '' then
      return jsonb_build_object('ok', true, 'code', v_code, 'statut', q.status, 'mail_erreur', 'adresse du membre introuvable');
    end if;
    v_sujet := left(coalesce(p_mail->>'sujet', 'Caisse — ' || coalesce(q.object, '')), 300);
    v_html := replace(coalesce(p_mail->>'html', ''), '{{CODE_DECISION}}', coalesce(v_code, ''));
    v_net := caisse_envoyer_mail(v_to, v_sujet, v_html, nullif(p_mail->>'reply_to', ''));
    insert into caisse_mails (destinataire, sujet, html, expediteur, reply_to, ok, erreur, lot, auteur, net_id)
    values (v_to, v_sujet, left(v_html, 200000), 'Trésorerie du BE <noreply@bureauetuidant.xyz>',
            nullif(p_mail->>'reply_to', ''), true, null, nullif(p_mail->>'lot', ''), coalesce(v_nom, ''), v_net);
  end if;

  return jsonb_build_object('ok', true, 'code', v_code, 'statut', q.status, 'mail_id', v_net);
end $$;
revoke all on function public.caisse_decider(uuid, text, jsonb, text, jsonb) from anon, public;
grant execute on function public.caisse_decider(uuid, text, jsonb, text, jsonb) to authenticated;

-- Résultat de l'envoi (pour avertir le trésorier si le mail n'est pas parti).
create or replace function public.caisse_mail_statut(p_ids bigint[])
returns jsonb language plpgsql stable security definer set search_path = public, net as $$
begin
  if not is_tresorier() then raise exception 'Réservé au trésorier.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', i,
      'etat', case when r.id is null then 'en_cours'
                   when r.status_code between 200 and 299 and not coalesce(r.timed_out, false) then 'ok'
                   else 'erreur' end,
      'erreur', case when r.id is not null and not (r.status_code between 200 and 299 and not coalesce(r.timed_out, false))
                     then coalesce(r.error_msg, 'send-email ' || coalesce(r.status_code::text, '?') || ' ' || left(coalesce(r.content::text, ''), 160)) end))
    from unnest(p_ids) i left join net._http_response r on r.id = i), '[]'::jsonb);
end $$;
revoke all on function public.caisse_mail_statut(bigint[]) from anon, public;
grant execute on function public.caisse_mail_statut(bigint[]) to authenticated;

-- Report du résultat dans l'onglet « Mails envoyés » (toutes les 10 minutes).
create or replace function public.caisse_mails_statuts()
returns void language plpgsql security definer set search_path = public, net as $$
begin
  update caisse_mails m
     set ok = (r.status_code between 200 and 299 and not coalesce(r.timed_out, false)),
         erreur = case when r.status_code between 200 and 299 and not coalesce(r.timed_out, false) then null
                       else coalesce(r.error_msg, 'send-email ' || coalesce(r.status_code::text, '?') || ' ' || left(coalesce(r.content::text, ''), 160)) end,
         net_id = null
    from net._http_response r
   where m.net_id = r.id;
  update caisse_mails set ok = false, erreur = 'envoi non confirmé par le serveur', net_id = null
   where net_id is not null and created_at < now() - interval '2 hours';
end $$;
revoke all on function public.caisse_mails_statuts() from anon, authenticated, public;

select cron.unschedule('caisse-mails-statuts') where exists (select 1 from cron.job where jobname = 'caisse-mails-statuts');
select cron.schedule('caisse-mails-statuts', '*/10 * * * *', 'select public.caisse_mails_statuts();');
