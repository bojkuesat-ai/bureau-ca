-- =====================================================================
--  Rappel annuel du subside BEA / CASE (25/11/2026) — migration rappel_subside_bea
--  Courriel de Mme de Halleux (administration facultaire) : le BE ne perçoit les subsides
--  institutionnels et facultaires que s'il remet rapport d'activité + bilan financier au BEA
--  (analyse BEA → approbation CASE → versement). Pas de rétroactif ; depuis 2022, la Faculté
--  n'assure plus le suivi. Chaque 1er mars (09h07, heure de Bruxelles en hiver), un mail part à la
--  présidence et à la trésorerie en poste (ca_membres.fonction), à défaut au propriétaire.
--  Date à ajuster quand le BEA aura communiqué son calendrier : cron.alter_job / cron.schedule.
-- =====================================================================
create or replace function public.subside_rappel_annuel()
returns int language plpgsql security definer set search_path to 'public' as $$
declare m record; n int := 0; v_html text;
begin
  v_html := '<h2 style="margin:0 0 10px">Subside BEA / CASE : pensez au dossier</h2>'
    || '<p>Bonjour,</p>'
    || '<p>Le Bureau étudiant ne perçoit ses <b>subsides institutionnels et facultaires</b> que s''il remet chaque année au <b>BEA</b> un <b>rapport d''activité</b> et un <b>bilan financier</b>.</p>'
    || '<ol><li>Remise du rapport d''activité et du bilan financier au BEA ;</li><li>analyse du dossier par le BEA ;</li><li>approbation par la CASE ;</li><li>versement du subside.</li></ol>'
    || '<p><b>Aucun financement rétroactif n''est possible</b> : une année sans dossier est une année de subside perdue. Depuis 2022, la Faculté n''assure plus le suivi : c''est au Bureau étudiant de s''en charger.</p>'
    || '<p>Vérifiez dès maintenant avec le BEA la date limite de dépôt et le format attendu. Les chiffres sont dans la CAISSE (onglet Comptes) et les activités dans l''Espace CA.</p>'
    || '<p>Pensez aussi à transmettre la fiche « Procédure du subside BEA / CASE » à vos successeurs lors de la passation.</p>';
  for m in select distinct lower(trim(email)) email from ca_membres
           where coalesce(statut, 'actif') = 'actif' and coalesce(email, '') <> ''
             and (fonction ~* '^\s*pr[ée]sident' or fonction ~* '^\s*tr[ée]sori')
  loop
    perform fm_mail(m.email, 'Subside BEA / CASE : dossier annuel à remettre', v_html, 'Trésorerie-BE');
    n := n + 1;
  end loop;
  if n = 0 then
    for m in select email from ca_membres where role = 'owner' and coalesce(email, '') <> '' loop
      perform fm_mail(m.email, 'Subside BEA / CASE : dossier annuel à remettre (aucune présidence ni trésorerie trouvée)', v_html, 'Trésorerie-BE');
      n := n + 1;
    end loop;
  end if;
  return n;
end $$;
revoke all on function public.subside_rappel_annuel() from public, anon, authenticated;

select cron.schedule('subside-bea-rappel', '7 8 1 3 *', 'select public.subside_rappel_annuel()');
