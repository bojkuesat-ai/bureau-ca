/* envois-auto — lancée toutes les 10 minutes par le serveur.
   Mails programmés, rappels de tâches, récap des idées du dimanche. */
import { createClient } from "jsr:@supabase/supabase-js@2";

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SRK = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CRON_SECRET = Deno.env.get("CRON_SECRET") || "";
const APP = "https://bojkuesat-ai.github.io/bureau-ca/";
const sb = createClient(SB_URL, SRK, { auth: { persistSession: false } });

const POSTES: Record<string, string> = {
  presidence: "Président", vice: "Vice-président", secretaire: "Secrétaire", tresorier: "Trésorier",
  delegation: "Représentant de la délégation", crimino: "Représentation criminologie",
  festif: "Responsable événements festifs", culturel: "Responsable événements culturels",
  academique: "Responsable événements académiques", sponsors: "Responsable sponsors",
  salle: "Responsable salle facultaire", syllabus: "Responsable syllabus", codes: "Responsable codes",
  com: "Responsable communication", jobdays: "Responsable jobdays",
  entraide: "Responsable Commission Entraide Sociale", novelles: "Rédacteur en chef",
};
const STATUTS_AVIS: Record<string, string> = { nouveau: "À traiter", retenue: "Retenue", discuter: "À discuter", ecartee: "Écartée" };

const esc = (x: unknown) => String(x ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const RE_EMAIL = /^[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}$/i;
const propre = (l: unknown) => [...new Set((Array.isArray(l) ? l : []).map((x) => String(x || "").toLowerCase().trim()).filter((x) => RE_EMAIL.test(x)))];

function dateBxl(d = new Date()): string {
  return new Intl.DateTimeFormat("fr-CA", { timeZone: "Europe/Brussels", year: "numeric", month: "2-digit", day: "2-digit" }).format(d);
}
function jourPlus(iso: string, n: number): string {
  const d = new Date(iso + "T12:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10);
}
function estDimancheBxl(): boolean {
  return new Intl.DateTimeFormat("en-US", { timeZone: "Europe/Brussels", weekday: "short" }).format(new Date()) === "Sun";
}
function estCoopte(m: Record<string, unknown>): boolean {
  if (m.role === "owner") return false;
  return m.role === "coopte" || !!String(m.via_code || "").trim() || /^coopt/i.test(String(m.fonction || "").trim());
}

async function envoyer(to: string, subject: string, html: string): Promise<boolean> {
  try {
    const r = await fetch(SB_URL + "/functions/v1/send-email", {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": "Bearer " + SRK, "apikey": SRK },
      body: JSON.stringify({ to, subject, html }),
    });
    return r.ok;
  } catch (_) { return false; }
}
const pause = (ms: number) => new Promise((r) => setTimeout(r, ms));

/* Choix de notifications (onglet Notifs du CA) : retire ceux qui ont coupé la
   catégorie, met de côté ceux qui veulent le résumé de 18 h. Si la base ne
   répond pas, on envoie comme avant. */
async function notifTrier(cat: string, emails: string[], sujet: string, html: string, urgent: boolean): Promise<string[]> {
  if (!emails.length) return emails;
  try {
    const { data, error } = await sb.rpc("notif_preparer_srv", { p_categorie: cat, p_emails: emails, p_sujet: sujet, p_html: html, p_urgent: urgent });
    if (error || !Array.isArray(data)) return emails;
    const ok = new Set((data as string[]).map((x) => String(x).toLowerCase().trim()));
    return emails.filter((e) => ok.has(String(e).toLowerCase().trim()));
  } catch (_) { return emails; }
}

async function lienDesabo(email: string): Promise<string> {
  try {
    const { data, error } = await sb.rpc("ca_jeton_desabo", { p_email: email });
    if (error || !data) return "";
    return APP + "?desabo=" + encodeURIComponent(email) + "&t=" + String(data);
  } catch (_) { return ""; }
}
const NO_REPLY = '<p style="color:#999;font-size:12px;margin-top:18px">Ceci est un envoi automatique &mdash; merci de ne pas répondre à ce message.<br>Le bureau étudiant &mdash; Espace CA</p>';
const enrober = (c: string) => '<div style="font-family:Arial,Helvetica,sans-serif;max-width:600px;margin:0 auto;color:#1a1a2e;font-size:14px;line-height:1.6">' + c;

async function journal(txt: string) {
  try { await sb.from("ca_journal").insert({ who: "Envoi automatique", txt }); } catch (_) { /* rien */ }
}
async function prendreCle(cle: string): Promise<boolean> {
  const r = await sb.from("ca_rappels_envoyes").insert({ cle }).select();
  return !r.error && !!r.data && r.data.length > 0;
}

/* 1. Mails programmés */
async function mailsProgrammes(desab: Set<string>) {
  const { data: dus } = await sb.from("ca_mail_programmes").select("*")
    .eq("statut", "en_attente").lte("envoi_at", new Date().toISOString());
  let n = 0;
  for (const p of dus || []) {
    const claim = await sb.from("ca_mail_programmes").update({ statut: "en_cours" })
      .eq("id", p.id).eq("statut", "en_attente").select();
    if (!claim.data || !claim.data.length) continue;
    try {
      const d = p.destinataires || {};
      const vus = new Set<string>();
      const tous: string[] = [];
      for (const l of [d.to, d.cc, d.cci]) for (const e of propre(l)) if (!vus.has(e)) { vus.add(e); tous.push(e); }
      const liste = tous.filter((e) => !desab.has(e));

      let lien = "";
      if (p.piece_path) {
        const su = await sb.storage.from("ca-documents").createSignedUrl(p.piece_path, 2592000, { download: p.nom_piece || true });
        if (su.data?.signedUrl) lien = su.data.signedUrl;
      }
      let ligneSig = "";
      if (p.cree_par) {
        const { data: a } = await sb.from("ca_membres").select("prenom,nom,fonction").eq("id", p.cree_par).maybeSingle();
        if (a) {
          const nom = ((a.prenom || "") + " " + (a.nom || "")).trim();
          ligneSig = nom + (a.fonction ? " — " + a.fonction : "");
        }
      }
      const corps = enrober(
        '<div style="white-space:pre-wrap">' + esc(p.corps) + "</div>"
        + (lien ? '<p style="margin:16px 0 0;padding:10px 12px;background:#f5f4fb;border:1px solid #e2e0ef;border-radius:8px;font-size:13px">📎 Pièce jointe : <a href="' + esc(lien) + '" style="color:#241c46;font-weight:bold">' + esc(p.nom_piece || "Télécharger le fichier") + "</a></p>" : "")
        + '<div style="margin:24px 0 0;border-top:1px solid #e2e0ef;padding-top:14px;font-size:13px;color:#1a1a2e;line-height:1.5">'
        + (ligneSig ? "<p style=\"margin:0 0 4px\"><b>" + esc(ligneSig) + "</b></p>" : "")
        + '<p style="margin:0;color:#3a3a5a">Le Bureau étudiant de la Faculté de Droit et de Criminologie</p></div>'
        + NO_REPLY,
      );
      let ok = 0, err = 0;
      for (const dest of liste) {
        const u = await lienDesabo(dest);
        const desabo = u ? '<p style="color:#bbb;font-size:11px;margin-top:14px">Vous recevez ce message en tant que contact du Bureau étudiant. <a href="' + u + '" style="color:#999">Se désabonner</a>.</p>' : "";
        if (await envoyer(dest, p.objet, corps + desabo + "</div>")) ok++; else err++;
        await pause(150);
      }
      await sb.from("ca_mail_programmes").update({ statut: err && !ok ? "erreur" : "envoye" }).eq("id", p.id);
      await journal("Mail programmé envoyé : « " + p.objet + " » à " + ok + " destinataire(s)" + (err ? ", " + err + " échec(s)" : ""));
      n++;
    } catch (e) {
      await sb.from("ca_mail_programmes").update({ statut: "erreur" }).eq("id", p.id);
      await journal("Échec de l'envoi programmé : « " + (p.objet || "(sans objet)") + " » — " + String(e));
    }
  }
  return n;
}

/* 2. Rappels de tâches */
async function rappelsTaches(membres: Record<string, unknown>[], desab: Set<string>, ongletsOff: string[]) {
  if (ongletsOff.includes("taches")) return 0;
  const demain = jourPlus(dateBxl(), 1);
  const { data: taches } = await sb.from("ca_taches").select("*").eq("echeance", demain).neq("statut", "done");
  let n = 0;
  for (const t of taches || []) {
    const set = new Set<string>();
    const titrePoste = POSTES[String(t.poste_id || "")];
    for (const a of membres) {
      if (!a.email) continue;
      const fonc = String(a.fonction || "").trim();
      const sig = (String(a.prenom || a.nom || "") + (fonc ? " · " + fonc : "")).toLowerCase().trim();
      if ((titrePoste && fonc === titrePoste) || (t.cree_par && sig === String(t.cree_par).toLowerCase().trim())) {
        set.add(String(a.email).toLowerCase().trim());
      }
    }
    const dest = [...set].filter((e) => !desab.has(e));
    if (!dest.length) continue;
    if (!(await prendreCle("tache:" + t.id + ":" + t.echeance))) continue;
    const html = enrober("<p>" + esc("Rappel : la tâche « " + (t.titre || "") + " » arrive à échéance demain.") + "</p>"
      + '<p><a href="' + APP + '" style="background:#241c46;color:#fff;padding:11px 20px;border-radius:8px;text-decoration:none;font-weight:bold;display:inline-block">Ouvrir l\'espace CA</a></p>'
      + NO_REPLY + "</div>");
    for (const e of await notifTrier("tache", dest, "Rappel : échéance demain", html, true)) { await envoyer(e, "Rappel : échéance demain", html); await pause(120); }
    await journal("Rappel automatique envoyé : tâche « " + (t.titre || "") + " »");
    n++;
  }
  return n;
}

/* 3. Récap des idées (dimanche) */
async function recapIdees(membres: Record<string, unknown>[], cooptes: Record<string, unknown>[], desab: Set<string>) {
  if (!estDimancheBxl()) return 0;
  const { data: avis } = await sb.from("ca_avis").select("*").order("created_at", { ascending: false });
  if (!avis || !avis.length) return 0;
  if (!(await prendreCle("recap-idees:" + dateBxl()))) return 0;

  const { data: votes } = await sb.from("ca_avis_votes").select("*");
  const idsMembres = new Set(membres.map((a) => a.id));
  const idsCooptes = new Set(cooptes.map((a) => a.id));
  const voix = (id: unknown, v: string) => (votes || []).filter((x) => x.avis_id === id && x.valeur === v && idsMembres.has(x.membre_id)).length;
  const voixCo = (id: unknown) => (votes || []).filter((x) => x.avis_id === id && idsCooptes.has(x.membre_id)).length;
  const eff = membres.length, seuil = eff ? Math.floor(eff / 2) + 1 : 0;
  const lundi = new Date(Date.now() - 6 * 86400000);
  const semaine = avis.filter((x) => x.created_at && new Date(x.created_at) >= lundi).length;

  const carte = (x: Record<string, unknown>) => {
    const pour = voix(x.id, "pour"), co = voixCo(x.id);
    return '<div style="border:1px solid #e2e0ef;border-radius:8px;padding:12px;margin:10px 0">'
      + "<b>" + esc(x.sujet || "Sans sujet") + "</b>"
      + '<span style="color:#777;font-size:12px"> — ' + esc(x.auteur || "") + (idsCooptes.has(x.membre_id) ? " (coopté·e)" : "") + "</span>"
      + '<span style="float:right;font-size:12px;color:#777">' + esc(STATUTS_AVIS[String(x.statut || "nouveau")] || "À traiter") + "</span>"
      + '<p style="margin:6px 0 8px;font-size:13.5px;white-space:pre-wrap">' + esc(x.texte || "") + "</p>"
      + '<p style="margin:0;font-size:13px;color:#444">Pour : <b>' + pour + "</b> · Mitigé : <b>" + voix(x.id, "mitige") + "</b> · Contre : <b>" + voix(x.id, "contre") + "</b>"
      + (co ? ' <span style="color:#777">· ' + co + " avis de coopté·e(s), hors décompte</span>" : "")
      + (seuil && pour >= seuil ? ' <span style="color:#1e7a4d"><b>— majorité atteinte</b></span>' : "")
      + "</p></div>";
  };
  const tri = avis.slice().sort((a, b) => voix(b.id, "pour") - voix(a.id, "pour"));
  const html = enrober('<h2 style="margin:0 0 10px">Idées de la semaine</h2>'
    + "<p>" + (semaine ? "<b>" + semaine + "</b> nouvelle(s) idée(s) cette semaine." : "Aucune nouvelle idée cette semaine.")
    + " " + avis.length + " idée(s) au total, classées ci-dessous par soutien.</p>"
    + tri.slice(0, 10).map(carte).join("")
    + '<p style="color:#777;font-size:12.5px">Majorité simple sur l\'effectif du conseil : ' + seuil + " voix pour sur " + eff + " membres. La décision finale revient au bureau.</p>"
    + '<p><a href="' + APP + '" style="background:#241c46;color:#fff;padding:11px 20px;border-radius:8px;text-decoration:none;display:inline-block">Ouvrir l\'espace CA</a></p>'
    + NO_REPLY + "</div>");
  const dest = [...new Set([...membres, ...cooptes].map((a) => String(a.email || "").toLowerCase().trim()))]
    .filter((e) => e && !desab.has(e));
  for (const e of await notifTrier("idees", dest, "Idées de la semaine — récapitulatif", html, false)) { await envoyer(e, "Idées de la semaine — récapitulatif", html); await pause(120); }
  await journal("Récap hebdomadaire des idées envoyé");
  return 1;
}

Deno.serve(async (req) => {
  if (!CRON_SECRET || req.headers.get("x-cron-secret") !== CRON_SECRET) {
    return new Response(JSON.stringify({ error: "refusé" }), { status: 401 });
  }
  try {
    const [{ data: tous }, { data: desabL }, { data: meta }] = await Promise.all([
      sb.from("ca_membres").select("id,email,prenom,nom,fonction,statut,role,via_code"),
      sb.from("ca_desabonnes").select("email"),
      sb.from("ca_meta").select("onglets_off").eq("id", 1).maybeSingle(),
    ]);
    const desab = new Set((desabL || []).map((d) => String(d.email || "").toLowerCase()));
    const actifs = (tous || []).filter((a) => a.statut === "actif" && a.email);
    const membres = actifs.filter((a) => !estCoopte(a));
    const cooptes = actifs.filter((a) => estCoopte(a));
    const off = Array.isArray(meta?.onglets_off) ? meta!.onglets_off as string[] : [];

    const res = {
      programmes: await mailsProgrammes(desab),
      taches: await rappelsTaches(membres, desab, off),
      recap: await recapIdees(membres, cooptes, desab),
    };
    return new Response(JSON.stringify(res), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500 });
  }
});
