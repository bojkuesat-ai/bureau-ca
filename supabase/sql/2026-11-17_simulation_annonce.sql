-- Simulation budget : mail d'annonce envoyé automatiquement à la PREMIÈRE activation (une seule fois)
-- aux membres du CA actifs, sauf le propriétaire (Esat), les cooptés, les hors CA et les désabonnés.
-- Expéditeur « Trésorerie du BE ». — 17/11/2026

alter table public.ca_meta add column if not exists simu_annonce_at timestamptz;

create or replace function public.simu_budget_annonce()
returns int language plpgsql security definer set search_path = public as $$
declare d record; n int := 0; corps text;
begin
  corps := '<h2 style="margin:0 0 10px">Nouvel outil dans l''app CA : la simulation budget</h2>'
    || '<p>Bonjour à toutes et à tous,</p>'
    || '<p>Un nouvel outil est disponible dans l''app CA : l''onglet <b>« € Simulation budget »</b>.</p>'
    || '<p>Il vous permet de savoir, avant même de déposer une demande, si un budget est compatible avec la trésorerie de l''association.</p>'
    || '<p><b>Comment ça marche :</b></p><ol style="padding-left:20px">'
    || '<li>Ouvrez l''onglet « Simulation budget ».</li>'
    || '<li>Tapez l''objet de votre budget et son montant.</li>'
    || '<li>Cliquez sur « Simuler » : l''app vous dit tout de suite si c''est faisable ou non.</li></ol>'
    || '<p>Le calcul se fait automatiquement à partir des chiffres de la Caisse : le solde de l''association, les factures à payer et les budgets déjà votés qui sont encore en cours. Vous n''avez qu''à taper votre montant.</p>'
    || '<p><b>Si c''est faisable</b>, l''app vous le confirme.<br><b>Si ce n''est pas faisable</b>, l''app vous indique le montant maximum que vous pouvez demander.</p>'
    || '<p>Dans les deux cas, vous pouvez envoyer le résultat en PDF à tous les membres du CA, pour préparer la réunion et le vote.</p>'
    || '<p>Cet outil nous aide à garder des budgets raisonnables par rapport à nos moyens, et à préparer les réunions plus sereinement.</p>'
    || '<p>N''hésitez pas à me contacter si vous avez des questions.</p>'
    || '<p>Bonne journée,<br>La trésorerie du Bureau étudiant</p>'
    || '<p><a href="https://bojkuesat-ai.github.io/bureau-ca/" style="background:#241c46;color:#fff;padding:11px 20px;border-radius:8px;text-decoration:none;font-weight:bold;display:inline-block">Ouvrir l''espace CA</a></p>';
  for d in select distinct lower(trim(c.email)) email from ca_membres c
           where c.statut = 'actif' and coalesce(c.role, '') not in ('coopte', 'proprietaire', 'owner')
             and not coalesce(c.hors_ca, false) and coalesce(c.email, '') <> ''
             and not exists (select 1 from ca_desabonnes x where lower(x.email) = lower(trim(c.email))) loop
    perform fm_mail(d.email, 'Nouvel outil dans l''app CA : la simulation budget', corps, 'Trésorerie du BE');
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.simu_budget_annonce() from anon, authenticated, public;

drop function if exists public.simu_budget_activer(boolean);
create function public.simu_budget_activer(p_actif boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m text; v_deja timestamptz; n int := null;
begin
  if not ca_est_admin() then raise exception 'Réservé à l''Admin du CA.'; end if;
  if not mfa_ok() then raise exception 'Tapez d''abord le code de double authentification.'; end if;
  m := app_refus_motif(null, null);
  if m <> '' then raise exception '%', m; end if;
  select simu_annonce_at into v_deja from ca_meta where id = 1 for update;
  update ca_meta set simu_budget_actif = coalesce(p_actif, false) where id = 1;
  if coalesce(p_actif, false) and v_deja is null then
    n := simu_budget_annonce();
    update ca_meta set simu_annonce_at = now() where id = 1;
  end if;
  return jsonb_build_object('actif', coalesce(p_actif, false), 'annonce_envoyee', n, 'annonce_deja', v_deja);
end $$;
revoke all on function public.simu_budget_activer(boolean) from anon, public;
grant execute on function public.simu_budget_activer(boolean) to authenticated;
