-- =====================================================================
--  Onglet Messages de l'Espace CA : réglage du propriétaire (25/11/2026)
--  migrations messages_caisse_reglage puis messages_ca_reglage (colonne renommée : c'est l'Espace CA,
--  pas la Caisse).
--  - proprio_config.messages_ca_actif (désactivé par défaut).
--  - proprio_reglages({messages_ca: true|false}) : propriétaire seulement.
--  - app_etat renvoie « messages_ca » : l'Espace CA n'affiche l'onglet Messages que s'il est activé.
-- =====================================================================
alter table public.proprio_config add column if not exists messages_ca_actif boolean not null default false;

create or replace function public.proprio_reglages(p jsonb)
 returns void language plpgsql security definer set search_path to 'public' as $function$
declare c proprio_config; k text; v jsonb;
begin
  perform proprio_exiger();
  select * into c from proprio_config where id = 1;
  if p ? 'mode_licence' then c.mode_licence := (p ->> 'mode_licence')::boolean; end if;
  if p ? 'mails_gestion' then c.mails_gestion := (p ->> 'mails_gestion')::boolean; end if;
  if p ? 'transparence' then c.transparence_actif := (p ->> 'transparence')::boolean; end if;
  if p ? 'messages_ca' then c.messages_ca_actif := (p ->> 'messages_ca')::boolean; end if;
  if p ? 'etat' then
    for k, v in select * from jsonb_each(p -> 'etat') loop
      if k not in ('ca','caisse') or (v #>> '{}') not in ('ouverte','lecture','fermee') then raise exception 'État invalide.'; end if;
      c.etat := c.etat || jsonb_build_object(k, v #>> '{}');
    end loop;
  end if;
  if p ? 'messages' then
    for k, v in select * from jsonb_each(p -> 'messages') loop
      if k not in ('ca','caisse') then raise exception 'Message invalide.'; end if;
      c.messages := c.messages || jsonb_build_object(k, left(coalesce(v #>> '{}', ''), 500));
    end loop;
  end if;
  if p ? 'modules' then
    for k, v in select * from jsonb_each(p -> 'modules') loop
      if not (k = any(modules_liste())) or jsonb_typeof(v) <> 'boolean' then raise exception 'Module invalide.'; end if;
      c.modules := c.modules || jsonb_build_object(k, v);
    end loop;
  end if;
  update proprio_config set mode_licence = c.mode_licence, etat = c.etat, messages = c.messages, modules = c.modules,
    mails_gestion = c.mails_gestion, transparence_actif = c.transparence_actif,
    messages_ca_actif = c.messages_ca_actif, maj_le = now() where id = 1;
end $function$;

create or replace function public.app_etat(p_app text)
 returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare c proprio_config; l licences; d licences; v_etat text; v_raison text; v_mod jsonb := '{}'; m text;
        v_proprio boolean := auth.uid() is not null and public.proprio_est();
        v_retire boolean := public.proprio_retire_moi();
begin
  select * into c from proprio_config where id = 1;
  select * into l from licence_courante();
  v_etat := coalesce(c.etat ->> p_app, 'ouverte');
  if v_etat <> 'ouverte' then v_raison := 'proprio'; end if;
  if v_etat = 'ouverte' and c.mode_licence and l.id is null then v_etat := 'lecture'; v_raison := 'licence'; end if;
  foreach m in array modules_liste() loop v_mod := v_mod || jsonb_build_object(m, module_actif(m)); end loop;
  if auth.uid() is not null then
    select * into d from licences where statut in ('demandee','approuvee') order by demande_le desc limit 1;
  end if;
  return jsonb_build_object(
    'app', p_app, 'etat', v_etat, 'raison', v_raison,
    'pour_moi', case when v_retire then 'retire' when v_proprio then 'ouverte' else v_etat end,
    'message', coalesce(c.messages ->> p_app, ''),
    'mode_licence', c.mode_licence,
    'licence', case when l.id is null then null else jsonb_build_object('fin', l.fin, 'options', to_jsonb(l.options), 'titulaire', l.demandeur_nom) end,
    'modules', v_mod,
    'proprio', v_proprio, 'retire', v_retire, 'passation', c.passation_faite,
    'admin', auth.uid() is not null and public.ca_est_admin(),
    'tresorier', auth.uid() is not null and public.ca_est_tresorier(),
    'med_dispatch', auth.uid() is not null and auth.uid() = public.ca_med_owner(),
    'peut_demander', c.mode_licence and public.licence_peut_demander(),
    'transparence', coalesce(c.transparence_actif, false),
    'messages_ca', coalesce(c.messages_ca_actif, false),
    'demande', case when d.id is null then null else jsonb_build_object('statut', d.statut, 'le', d.demande_le, 'par', d.demandeur_nom,
                 'duree_mois', d.duree_mois, 'options', to_jsonb(d.options), 'fin', d.fin, 'moi', d.demandeur_id = auth.uid()) end);
end $function$;
