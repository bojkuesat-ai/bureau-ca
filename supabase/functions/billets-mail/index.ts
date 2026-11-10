// =====================================================================
//  billets-mail — Billetterie du Bureau étudiant
//  Tous les mails de la Billetterie sont construits ICI, côté serveur,
//  à partir de l'identifiant d'une inscription : la page publique ne peut
//  jamais faire partir un mail au contenu libre.
//  À déployer avec « Verify JWT » DÉSACTIVÉ (la fonction vérifie elle-même
//  qui l'appelle : public, responsable connecté ou tâche planifiée).
//  Version du 10/11/2026 — nom d'expéditeur par commission (bil_commissions.expediteur)
//  et signature au prénom du ou des responsables de la commission (ca_membres.fonction).
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2.115.0";
import qrcode from "npm:qrcode-generator@1.4.4";

const SB_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SRK = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ANON = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const APP = (Deno.env.get("BILLETS_APP_URL") ?? "https://bojkuesat-ai.github.io/bureau-ca/billets/").replace(/\/?$/, "/");
const FROM_ADRESSE = "noreply@bureauetuidant.xyz";
const FROM_DEFAUT = "Billetterie-BE";
const FROM = `${FROM_DEFAUT} <${FROM_ADRESSE}>`;
/* Nom d'expéditeur d'une commission (colonne bil_commissions.expediteur : « ACA-BE »,
   « Festif-BE »…), nettoyé pour ne jamais casser l'en-tête From. */
function expediteurDe(nom: unknown) {
  const n = String(nom ?? "").replace(/[<>"@\r\n]/g, "").trim().slice(0, 40) || FROM_DEFAUT;
  return `${n} <${FROM_ADRESSE}>`;
}
const ORIGINES = ["https://bojkuesat-ai.github.io", ...(Deno.env.get("BILLETS_ORIGINES") ?? "").split(",").map((s) => s.trim()).filter(Boolean)];
const BUCKET = "billets";
const MAX_FICHIER = 10 * 1024 * 1024;
const TYPES_FICHIERS = ["image/jpeg", "image/png", "image/webp", "image/heic", "image/heif", "image/gif", "application/pdf"];
const LOT = 60;            // envois par appel depuis l'app (l'app relance tant qu'il en reste)
const LOT_CRON = 150;      // envois par passage de la tâche planifiée

const db = createClient(SB_URL, SRK, { auth: { persistSession: false, autoRefreshToken: false } });

class Refus extends Error { statut: number; constructor(m: string, s = 400) { super(m); this.statut = s; } }

// ------------------------------------------------------------------ HTTP
function cors(req: Request) {
  const o = req.headers.get("origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ORIGINES.includes(o) ? o : ORIGINES[0],
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}
function rep(req: Request, corps: unknown, statut = 200) {
  return new Response(JSON.stringify(corps), { status: statut, headers: { ...cors(req), "Content-Type": "application/json; charset=utf-8" } });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return rep(req, { ok: false, erreur: "Méthode non autorisée." }, 405);
  try {
    const ct = req.headers.get("content-type") ?? "";
    if (ct.includes("multipart/form-data")) return rep(req, await inscrire(req));
    const b = await req.json().catch(() => ({})) as Record<string, any>;
    const a = String(b.action ?? "");
    if (a === "cron") return rep(req, await cron(req));
    if (a === "confirmer") return rep(req, await confirmer(String(b.token ?? "")));
    if (a === "desinscrire") return rep(req, await desinscrire(String(b.secret ?? "")));
    const u = await utilisateur(req);
    if (!u) throw new Refus("Connexion requise : reconnectez-vous.", 401);
    switch (a) {
      case "valider": return rep(req, await valider(u, String(b.id)));
      case "refuser": return rep(req, await refuser(u, String(b.id), String(b.motif ?? "")));
      case "repecher": return rep(req, await repecher(u, String(b.id)));
      case "supprimer": return rep(req, await supprimer(u, String(b.id)));
      case "masse": return rep(req, await masse(u, String(b.evenement_id), String(b.quoi)));
      case "liberer": return rep(req, await libererAction(u, String(b.evenement_id)));
      case "envoyer_billets": return rep(req, await lotAction(u, "billet", b));
      case "presence": return rep(req, await lotAction(u, "presence", b));
      case "rappel": return rep(req, await lotAction(u, "rappel", b));
      case "relance": return rep(req, await lotAction(u, "relance", b));
      case "bilan": return rep(req, await bilanAction(u, String(b.evenement_id)));
      case "test": return rep(req, await testAction(u, String(b.evenement_id)));
      default: throw new Refus("Action inconnue.");
    }
  } catch (e) {
    if (e instanceof Refus) return rep(req, { ok: false, erreur: e.message }, e.statut);
    console.error(e);
    return rep(req, { ok: false, erreur: "Erreur du serveur : " + String((e as Error)?.message ?? e) }, 500);
  }
});

// ------------------------------------------------------------------ Qui appelle ?
type Membre = { id: string; prenom: string; nom: string; email: string; jwt: string; role: string };
async function utilisateur(req: Request): Promise<Membre | null> {
  const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!jwt || jwt.startsWith("sb_") || jwt === ANON) return null;
  const { data, error } = await db.auth.getUser(jwt);
  if (error || !data?.user) return null;
  const { data: m } = await db.from("ca_membres").select("id,prenom,nom,email,role,statut").eq("id", data.user.id).maybeSingle();
  if (!m) return null;
  return { id: m.id, prenom: m.prenom ?? "", nom: m.nom ?? "", email: m.email ?? data.user.email ?? "", role: m.role ?? "", jwt };
}
async function exigerDroit(u: Membre, eid: string) {
  const { data } = await db.rpc("bil_srv_droit", { p_uid: u.id, p_eid: eid });
  if (data !== true) throw new Refus("Vous n'êtes pas responsable de cette commission.", 403);
}
const nomDe = (u: Membre) => `${u.prenom} ${u.nom}`.trim();

// ------------------------------------------------------------------ Données
type Evt = Record<string, any>;

/* Signature des mails : prénom du ou des responsables actifs de la commission,
   retrouvés par leur fonction dans le CA. Le poste change de titulaire ? La
   signature suit. Poste vide ? On garde la signature générique du Bureau. */
const POSTES_COMMISSION: Record<string, { fonctions: string[]; titre: string; titres?: string }> = {
  academique: { fonctions: ["Responsable événements académiques"], titre: "Responsable événements académiques" },
  festif: { fonctions: ["Responsable événements festifs"], titre: "Responsable événements festifs" },
  culturel: { fonctions: ["Responsable événements culturels"], titre: "Responsable événements culturels" },
  jobdays: { fonctions: ["Responsable jobdays"], titre: "Responsable Jobdays" },
  sponsors: { fonctions: ["Responsable sponsors"], titre: "Responsable sponsors" },
  salle: { fonctions: ["Responsable salle facultaire"], titre: "Responsable salle facultaire" },
  com: { fonctions: ["Responsable communication"], titre: "Responsable communication" },
  entraide: { fonctions: ["Responsable Commission Entraide Sociale"], titre: "Responsable Commission Entraide Sociale" },
  crimino: { fonctions: ["Représentation criminologie"], titre: "Représentation criminologie", titres: "Représentation criminologie" },
  syllabus_codes: { fonctions: ["Responsable syllabus", "Responsable codes"], titre: "Responsable syllabus et codes" },
};
/* « FARAH » → « Farah », « acacia-laure » → « Acacia-Laure ». */
const prenomPropre = (p: unknown) => String(p ?? "").trim().toLowerCase()
  .replace(/(^|[\s'-])(\p{L})/gu, (_m, a, b) => a + b.toUpperCase());
async function signatureDe(cid: string | null | undefined): Promise<{ noms: string; titre: string } | null> {
  const poste = POSTES_COMMISSION[String(cid ?? "")];
  if (!poste) return null;
  try {
    const { data } = await db.from("ca_membres").select("prenom,fonction,statut").in("fonction", poste.fonctions).eq("statut", "actif");
    const prenoms = [...new Set(((data ?? []) as any[]).map((m) => prenomPropre(m.prenom)).filter(Boolean))];
    if (!prenoms.length) return null;
    const noms = prenoms.length === 1 ? prenoms[0] : prenoms.slice(0, -1).join(", ") + " et " + prenoms[prenoms.length - 1];
    const titre = prenoms.length === 1 ? poste.titre : (poste.titres ?? poste.titre.replace(/^Responsable\b/, "Responsables"));
    return { noms, titre };
  } catch (_) { return null; }
}
type Insc = Record<string, any>;
async function lireEvt(eid: string): Promise<Evt> {
  const { data, error } = await db.from("bil_evenements").select("*").eq("id", eid).maybeSingle();
  if (error || !data) throw new Refus("Événement introuvable.", 404);
  const { data: c } = await db.from("bil_commissions").select("*").eq("id", data.commission_id).maybeSingle();
  data.commission = c?.nom ?? "";
  data.pdf_joint = !!c?.pdf_joint;
  data.expediteur = expediteurDe(c?.expediteur);
  data.signature = await signatureDe(data.commission_id);
  return data;
}
async function lireInsc(id: string): Promise<Insc> {
  const { data, error } = await db.from("bil_inscriptions").select("*").eq("id", id).maybeSingle();
  if (error || !data) throw new Refus("Inscription introuvable.", 404);
  return data;
}
async function rpc(fn: string, args: Record<string, unknown>) {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Refus(error.message);
  return data;
}
async function cleUnique(cle: string): Promise<boolean> {
  const { error } = await db.from("ca_rappels_envoyes").insert({ cle });
  return !error;
}
async function config() {
  const { data } = await db.from("bil_config").select("*").eq("id", 1).maybeSingle();
  return data ?? { iban: "BE74363057740807", titulaire: "Le bureau étudiant ASBL", contact_rgpd: "esat.bojku@ulb.be", cron_secret: "" };
}

// ------------------------------------------------------------------ Outils texte / dates
const esc = (s: unknown) => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const eur = (n: unknown) => new Intl.NumberFormat("fr-BE", { style: "currency", currency: "EUR" }).format(Number(n ?? 0));
function dateLongue(iso?: string | null) {
  if (!iso) return "";
  try { return new Date(String(iso).slice(0, 10) + "T12:00:00Z").toLocaleDateString("fr-BE", { weekday: "long", day: "numeric", month: "long", year: "numeric", timeZone: "UTC" }); }
  catch { return String(iso); }
}
const hm = (t?: string | null) => t ? String(t).slice(0, 5).replace(":", "h") : "";
function bxl(d = new Date()) {
  const p = Object.fromEntries(new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Brussels", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" })
    .formatToParts(d).map((x) => [x.type, x.value]));
  return { date: `${p.year}-${p.month}-${p.day}`, heure: Number(p.hour) };
}
function plusJours(iso: string, n: number) { const d = new Date(iso + "T12:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); }
function decalageBxl(ts: number) {
  const p = Object.fromEntries(new Intl.DateTimeFormat("en-US", { timeZone: "Europe/Brussels", hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" })
    .formatToParts(new Date(ts)).map((x) => [x.type, x.value]));
  return Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute, +p.second) - ts;
}
function bxlVersUtc(iso: string, t: string) {
  const [y, m, d] = iso.split("-").map(Number); const [h, mi] = t.split(":").map(Number);
  const g = Date.UTC(y, m - 1, d, h, mi);
  return new Date(g - decalageBxl(g - decalageBxl(g)));
}
const prenomOu = (i: Insc) => (i.prenom || i.nom || "").trim();

// ------------------------------------------------------------------ Mise en page des mails
function cadre(e: Evt, titre: string, corps: string, signer = true) {
  const sig = signer && e.signature
    ? `<p style="margin:20px 0 0;line-height:1.45"><b>${esc(e.signature.noms)}</b><br><span style="color:#555">${esc(e.signature.titre)}</span><br><span style="color:#555">Bureau étudiant de la Faculté de Droit et de Criminologie</span></p>`
    : "";
  return `<div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:0 auto;color:#1a1a2e;font-size:14.5px;line-height:1.6">
<div style="background:#241c46;color:#fff;border-radius:12px 12px 0 0;padding:18px 20px">
<div style="font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:#e8b04b">🎟 Billetterie du Bureau étudiant</div>
<div style="font-size:20px;font-weight:bold;margin-top:4px">${esc(e.titre)}</div>
<div style="font-size:12.5px;color:#c9c3e4;margin-top:2px">Organisé par la commission ${esc(e.commission)}</div></div>
<div style="border:1px solid #e2e0ef;border-top:none;border-radius:0 0 12px 12px;padding:20px">
${titre ? `<h2 style="margin:0 0 12px;font-size:18px">${esc(titre)}</h2>` : ""}${corps}${sig}
<p style="color:#999;font-size:12px;margin-top:22px;border-top:1px solid #eee;padding-top:12px">${sig ? "Envoi automatique" : "Le Bureau étudiant de la Faculté de Droit et de Criminologie — envoi automatique"}, merci de ne pas répondre à ce message.</p>
</div></div>`;
}
function bouton(href: string, texte: string, fond = "#241c46") {
  return `<p style="text-align:center;margin:18px 0"><a href="${esc(href)}" style="background:${fond};color:#fff;padding:13px 22px;border-radius:10px;text-decoration:none;font-weight:bold;display:inline-block">${texte}</a></p>`;
}
function infos(e: Evt) {
  const l: [string, string][] = [];
  if (e.date_evt) l.push(["Date", dateLongue(e.date_evt)]);
  if (e.heure_debut) l.push(["Heure", hm(e.heure_debut) + (e.heure_fin ? " – " + hm(e.heure_fin) : "")]);
  if (e.lieu) l.push(["Lieu", e.lieu]);
  const rows = l.map(([k, v]) => `<tr><td style="padding:4px 14px 4px 0;color:#666;vertical-align:top">${k}</td><td><b>${esc(v)}</b></td></tr>`).join("");
  return (rows ? `<table style="border-collapse:collapse;margin:10px 0;font-size:14px">${rows}</table>` : "")
    + (e.infos ? `<div style="background:#f5f4fb;border-radius:8px;padding:10px 12px;margin:8px 0;white-space:pre-wrap;font-size:13.5px">${esc(e.infos)}</div>` : "");
}
const lienBillet = (i: Insc) => APP + "?t=" + i.secret;
const lienDesinsc = (i: Insc) => APP + "?d=" + i.secret;
function piedDesinsc(i: Insc) {
  return `<p style="font-size:12.5px;color:#777;margin-top:16px">Vous ne pouvez plus venir ? <a href="${lienDesinsc(i)}" style="color:#777">Se désinscrire en un clic</a> — votre place ira à la personne suivante sur la liste d'attente.</p>`;
}
function blocPaiement(e: Evt, i: Insc, cfg: Record<string, any>) {
  if (!e.payant) return "";
  return `<div style="background:#fff8e6;border:1px solid #e8d9a8;border-radius:8px;padding:10px 12px;margin:10px 0;font-size:13.5px">
<b>Paiement</b><br>Montant : <b>${eur(i.montant ?? e.prix)}</b><br>Compte : <b>${esc(String(cfg.iban).replace(/(.{4})/g, "$1 ").trim())}</b> — ${esc(cfg.titulaire)}<br>
Communication : <b>${esc(i.communication ?? "")}</b><br><a href="${APP}?v=${i.secret}" style="color:#241c46">Afficher le QR de virement</a></div>`;
}

// ------------------------------------------------------------------ Envoi (Amazon SES)
type PJ = { filename: string; content: string; contentType?: string };
type Envoi = { ok: boolean; via: string; erreur?: string };
const enc = new TextEncoder();
function b64(bytes: Uint8Array) { let s = ""; for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000)); return btoa(s); }
const b64txt = (s: string) => b64(enc.encode(s));
const hex = (b: ArrayBuffer | Uint8Array) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
async function hmac(cle: Uint8Array, msg: string) {
  const k = await crypto.subtle.importKey("raw", cle, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, enc.encode(msg)));
}
const sha = async (s: string) => hex(await crypto.subtle.digest("SHA-256", enc.encode(s)));
function env(...noms: string[]) { for (const n of noms) { const v = Deno.env.get(n); if (v) return v; } return ""; }
const SES_ID = env("BILLETS_SES_KEY_ID", "AWS_ACCESS_KEY_ID", "SES_ACCESS_KEY_ID", "AWS_SES_ACCESS_KEY_ID", "AWS_SES_ACCESS_KEY");
const SES_SECRET = env("BILLETS_SES_SECRET", "AWS_SECRET_ACCESS_KEY", "SES_SECRET_ACCESS_KEY", "AWS_SES_SECRET_ACCESS_KEY", "AWS_SES_SECRET_KEY");
const SES_REGION = env("BILLETS_SES_REGION", "AWS_REGION", "AWS_SES_REGION", "SES_REGION", "AWS_DEFAULT_REGION") || "eu-west-1";

function mime(to: string, sujet: string, html: string, pj: PJ[], from = FROM) {
  const f = "=_bil_" + crypto.randomUUID().replace(/-/g, "");
  const ligne = (s: string) => s.replace(/(.{76})/g, "$1\r\n");
  let m = `From: ${from}\r\nTo: ${to}\r\nSubject: =?UTF-8?B?${b64txt(sujet)}?=\r\nMIME-Version: 1.0\r\n`;
  m += `Content-Type: multipart/mixed; boundary="${f}"\r\n\r\n--${f}\r\nContent-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n${ligne(b64txt(html))}\r\n`;
  for (const p of pj) {
    const t = p.contentType ?? (p.filename.endsWith(".pdf") ? "application/pdf" : p.filename.endsWith(".ics") ? "text/calendar; charset=UTF-8; method=PUBLISH" : "application/octet-stream");
    m += `--${f}\r\nContent-Type: ${t}; name="${p.filename}"\r\nContent-Disposition: attachment; filename="${p.filename}"\r\nContent-Transfer-Encoding: base64\r\n\r\n${ligne(p.content)}\r\n`;
  }
  return m + `--${f}--\r\n`;
}
async function viaSes(to: string, sujet: string, html: string, pj: PJ[], from = FROM): Promise<Envoi> {
  const hote = `email.${SES_REGION}.amazonaws.com`, chemin = "/v2/email/outbound-emails";
  const corps = JSON.stringify({ Destination: { ToAddresses: [to] }, Content: { Raw: { Data: b64txt(mime(to, sujet, html, pj, from)) } } });
  const now = new Date(), amz = now.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, ""), jour = amz.slice(0, 8);
  const portee = `${jour}/${SES_REGION}/ses/aws4_request`;
  const canon = `POST\n${chemin}\n\ncontent-type:application/json\nhost:${hote}\nx-amz-date:${amz}\n\ncontent-type;host;x-amz-date\n${await sha(corps)}`;
  const aSigner = `AWS4-HMAC-SHA256\n${amz}\n${portee}\n${await sha(canon)}`;
  let k = await hmac(enc.encode("AWS4" + SES_SECRET), jour);
  k = await hmac(k, SES_REGION); k = await hmac(k, "ses"); k = await hmac(k, "aws4_request");
  const sig = hex(await hmac(k, aSigner));
  const r = await fetch(`https://${hote}${chemin}`, { method: "POST", body: corps, headers: {
    "Content-Type": "application/json", "X-Amz-Date": amz,
    "Authorization": `AWS4-HMAC-SHA256 Credential=${SES_ID}/${portee}, SignedHeaders=content-type;host;x-amz-date, Signature=${sig}` } });
  if (r.ok) return { ok: true, via: "ses" };
  return { ok: false, via: "ses", erreur: `SES ${r.status} ${(await r.text()).slice(0, 200)}` };
}
// Repli : la fonction send-email existante du CA.
async function viaSendEmail(to: string, sujet: string, html: string, pj: PJ[], jwt?: string, from = FROM): Promise<Envoi> {
  const payload = JSON.stringify({ to, subject: sujet, html, from, ...(pj.length ? { attachments: pj.map((p) => ({ filename: p.filename, content: p.content })) } : {}) });
  const essais = [jwt, SRK, ANON].filter(Boolean) as string[];
  let der = "";
  for (const t of essais) {
    try {
      const r = await fetch(SB_URL + "/functions/v1/send-email", { method: "POST", body: payload,
        headers: { "Content-Type": "application/json", "Authorization": "Bearer " + t, "apikey": ANON || SRK } });
      if (r.ok) return { ok: true, via: "send-email" };
      der = `send-email ${r.status} ${(await r.text()).slice(0, 160)}`;
      if (r.status !== 401 && r.status !== 403) break;
    } catch (e) { der = "send-email : " + String(e); }
  }
  return { ok: false, via: "send-email", erreur: der };
}
async function envoyer(to: string | null | undefined, sujet: string, html: string, pj: PJ[] = [], jwt?: string, from = FROM): Promise<Envoi> {
  if (!to || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(to)) return { ok: false, via: "", erreur: "adresse absente" };
  let r: Envoi = { ok: false, via: "", erreur: "" };
  for (let essai = 0; essai < 2 && !r.ok; essai++) {
    if (essai) await new Promise((ok) => setTimeout(ok, 700));
    try { r = (SES_ID && SES_SECRET) ? await viaSes(to, sujet, html, pj, from) : await viaSendEmail(to, sujet, html, pj, jwt, from); }
    catch (e) { r = { ok: false, via: "?", erreur: String(e) }; }
  }
  if (!r.ok) console.error("Envoi impossible", to, r.erreur);
  return r;
}
const pause = (ms = 90) => new Promise((ok) => setTimeout(ok, ms));

// ------------------------------------------------------------------ Agenda (.ics) et billet PDF
function ics(e: Evt, i: Insc) {
  const f = (d: Date) => d.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
  const nettoie = (s: string) => String(s ?? "").replace(/\\/g, "\\\\").replace(/([,;])/g, "\\$1").replace(/\r?\n/g, "\\n");
  let deb = "", fin = "";
  if (e.date_evt && e.heure_debut) {
    const d = bxlVersUtc(e.date_evt, e.heure_debut);
    let fi = e.heure_fin ? bxlVersUtc(e.date_evt, e.heure_fin) : new Date(d.getTime() + 3 * 3600000);
    if (fi <= d) fi = new Date(fi.getTime() + 86400000);
    deb = `DTSTART:${f(d)}`; fin = `DTEND:${f(fi)}`;
  } else if (e.date_evt) {
    deb = `DTSTART;VALUE=DATE:${e.date_evt.replace(/-/g, "")}`; fin = `DTEND;VALUE=DATE:${plusJours(e.date_evt, 1).replace(/-/g, "")}`;
  } else return "";
  return ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Bureau etudiant//Billetterie//FR", "METHOD:PUBLISH", "BEGIN:VEVENT",
    `UID:${i.code}@billetterie-be`, `DTSTAMP:${f(new Date())}`, deb, fin, `SUMMARY:${nettoie(e.titre)}`,
    e.lieu ? `LOCATION:${nettoie(e.lieu)}` : "", `DESCRIPTION:${nettoie(`Organisé par la commission ${e.commission}. Billet : ${lienBillet(i)}`)}`,
    "END:VEVENT", "END:VCALENDAR"].filter(Boolean).join("\r\n") + "\r\n";
}

const HELV: Record<string, number> = {};
" !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~".split("").forEach((ch, k) => {
  HELV[ch] = [278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278, 556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556, 1015,
    667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556, 333,
    556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, 556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584][k];
});
const largeur = (s: string, t: number, gras = false) => [...s].reduce((a, ch) => a + (HELV[ch] ?? HELV[ch.normalize("NFD")[0]] ?? 556), 0) * t / 1000 * (gras ? 1.06 : 1);
const WIN: Record<string, number> = { "€": 0x80, "‚": 0x82, "„": 0x84, "…": 0x85, "‘": 0x91, "’": 0x92, "“": 0x93, "”": 0x94, "•": 0x95, "–": 0x96, "—": 0x97, "œ": 0x9c, "Œ": 0x8c, "Ÿ": 0x9f };
function pdfTxt(s: string) {
  let o = "";
  for (const ch of String(s ?? "")) {
    const c = ch.codePointAt(0)!;
    const b = WIN[ch] ?? (c >= 0x20 && c <= 0x7e ? c : c >= 0xa0 && c <= 0xff ? c : (ch.normalize("NFD").charCodeAt(0) < 0x7f ? ch.normalize("NFD").charCodeAt(0) : 0x3f));
    const x = String.fromCharCode(b);
    o += (x === "(" || x === ")" || x === "\\") ? "\\" + x : x;
  }
  return o;
}
function couper(s: string, t: number, max: number, gras = false) {
  const mots = String(s ?? "").split(/\s+/); const l: string[] = []; let cur = "";
  for (const m of mots) { const essai = cur ? cur + " " + m : m; if (largeur(essai, t, gras) > max && cur) { l.push(cur); cur = m; } else cur = essai; }
  if (cur) l.push(cur);
  return l;
}
function billetPdf(e: Evt, i: Insc): string {
  const W = 297.64, H = 419.53, c: string[] = [];
  const texte = (s: string, x: number, y: number, t: number, police = "F1", rgb = "0.1 0.1 0.18") => c.push(`BT ${rgb} rg /${police} ${t} Tf ${x.toFixed(2)} ${y.toFixed(2)} Td (${pdfTxt(s)}) Tj ET`);
  const centre = (s: string, y: number, t: number, police = "F1", rgb?: string) => texte(s, (W - largeur(s, t, police === "F2")) / 2, y, t, police, rgb);
  c.push("0.141 0.110 0.275 rg 0 329 297.64 90.53 re f");
  const lignes = couper(e.titre, 15, W - 36, true).slice(0, 2);
  let y = lignes.length > 1 ? 396 : 386;
  lignes.forEach((l) => { centre(l, y, 15, "F2", "1 1 1"); y -= 18; });
  centre(`Organisé par la commission ${e.commission}`, y - 4, 8.5, "F1", "0.79 0.76 0.89");
  const nomC = `${i.prenom ?? ""} ${i.nom ?? ""}`.trim() || "Billet";
  centre(nomC.length > 34 ? nomC.slice(0, 34) + "…" : nomC, 304, 16, "F2");
  const l1 = [e.date_evt ? dateLongue(e.date_evt) : "", e.heure_debut ? hm(e.heure_debut) : ""].filter(Boolean).join(" · ");
  if (l1) centre(l1, 286, 10);
  if (e.lieu) centre(couper(e.lieu, 10, W - 40)[0] ?? "", 272, 10, "F1", "0.35 0.35 0.45");
  const q = qrcode(0, "M"); q.addData(String(i.code)); q.make();
  const n = q.getModuleCount(), taille = 160, m = taille / (n + 8), x0 = (W - taille) / 2, y0 = 90;
  c.push("1 1 1 rg " + `${x0} ${y0} ${taille} ${taille} re f`, "0.094 0.071 0.2 rg");
  for (let r = 0; r < n; r++) for (let k = 0; k < n; k++) if (q.isDark(r, k))
    c.push(`${(x0 + (k + 4) * m).toFixed(3)} ${(y0 + taille - (r + 5) * m).toFixed(3)} ${(m + 0.02).toFixed(3)} ${(m + 0.02).toFixed(3)} re f`);
  centre(String(i.code), 68, 15, "F3");
  centre("Billet personnel — valable une seule fois à l'entrée.", 40, 8, "F1", "0.45 0.45 0.5");
  centre("Bureau étudiant de la Faculté de Droit et de Criminologie", 28, 7.5, "F1", "0.6 0.6 0.65");
  const flux = c.join("\n");
  const objs = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${W} ${H}] /Contents 4 0 R /Resources << /Font << /F1 5 0 R /F2 6 0 R /F3 7 0 R >> >> >>`,
    `<< /Length ${flux.length} >>\nstream\n${flux}\nendstream`,
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>",
    "<< /Type /Font /Subtype /Type1 /BaseFont /Courier-Bold /Encoding /WinAnsiEncoding >>",
  ];
  let out = "%PDF-1.4\n%\xe2\xe3\xcf\xd3\n"; const pos: number[] = [];
  objs.forEach((o, k) => { pos.push(out.length); out += `${k + 1} 0 obj\n${o}\nendobj\n`; });
  const xref = out.length;
  out += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n` + pos.map((p) => String(p).padStart(10, "0") + " 00000 n \n").join("");
  out += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return b64(Uint8Array.from(out, (ch) => ch.charCodeAt(0) & 0xff));
}
const nomFichier = (s: string) => String(s ?? "").normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/[^A-Za-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 40) || "billet";

// ------------------------------------------------------------------ Les mails
async function mailConfirmationAdresse(e: Evt, i: Insc, token: string) {
  const corps = `<p>Bonjour ${esc(prenomOu(i))},</p><p>Merci pour votre inscription. Pour la finaliser, confirmez votre adresse e-mail :</p>`
    + bouton(APP + "?c=" + token, "✓ Confirmer mon adresse", "#2e8b57")
    + (e.payant ? `<p>Ensuite, un·e responsable vérifiera votre preuve de paiement ; vous recevrez votre billet dès la validation.</p>` : `<p>Votre billet vous sera envoyé juste après.</p>`)
    + infos(e)
    + `<p style="font-size:12.5px;color:#777">Si le bouton ne fonctionne pas, ouvrez ce lien : <br><a href="${APP}?c=${token}">${APP}?c=${token}</a><br>Vous n'êtes pas à l'origine de cette inscription ? Ignorez simplement ce message.</p>`;
  return envoyer(i.email, "Confirmez votre inscription — " + e.titre, cadre(e, "Confirmez votre adresse e-mail", corps), [], undefined, e.expediteur);
}
async function mailBillet(e: Evt, i: Insc, entete = "", jwt?: string) {
  const pj: PJ[] = [];
  const cal = ics(e, i);
  if (cal) pj.push({ filename: "evenement.ics", content: b64txt(cal), contentType: "text/calendar; charset=UTF-8; method=PUBLISH" });
  if (e.pdf_joint) { try { pj.push({ filename: `billet-${nomFichier(e.titre)}-${nomFichier(i.prenom || i.nom)}.pdf`, content: billetPdf(e, i), contentType: "application/pdf" }); } catch (x) { console.error("PDF", x); } }
  const corps = (entete ? `<div style="background:#e8f6ee;border:1px solid #bfe3cd;border-radius:8px;padding:10px 12px;margin:0 0 12px;font-weight:bold">${entete}</div>` : "")
    + `<p>Bonjour ${esc(prenomOu(i))},</p><p>Votre inscription est confirmée. Voici votre billet personnel.</p>`
    + bouton(lienBillet(i), "📱 Afficher mon billet (QR)")
    + `<p style="text-align:center;font-family:'Courier New',monospace;font-size:18px;letter-spacing:2px;margin:-6px 0 14px"><b>${esc(i.code)}</b></p>`
    + infos(e)
    + `<p>Présentez le QR à l'entrée (écran allumé, luminosité au maximum). Il n'est valable qu'une seule fois.</p>`
    + (cal ? `<p>📅 <a href="${lienBillet(i)}&ics=1" style="color:#241c46">Ajouter l'événement à l'agenda de mon téléphone</a> (le fichier .ics est aussi joint à ce mail).</p>` : "")
    + (e.pdf_joint ? `<p>Le billet est aussi joint en PDF.</p>` : "")
    + piedDesinsc(i);
  const r = await envoyer(i.email, "Votre billet — " + e.titre, cadre(e, "", corps), pj, jwt, e.expediteur);
  if (r.ok) await db.from("bil_inscriptions").update({ billet_envoye_le: new Date().toISOString() }).eq("id", i.id);
  return r;
}
async function rangAttente(i: Insc) {
  const { data } = await db.rpc("bil_public_billet", { p_secret: i.secret });
  return (data as any)?.rang ?? null;
}
async function mailAttente(e: Evt, i: Insc) {
  const rang = await rangAttente(i);
  const corps = `<p>Bonjour ${esc(prenomOu(i))},</p><p>Votre adresse est confirmée, mais l'événement est <b>complet</b> : vous êtes sur la <b>liste d'attente</b>${rang ? ` (position ${rang})` : ""}.</p>`
    + `<p>Si une place se libère, ${e.payant ? "votre preuve de paiement sera vérifiée et vous recevrez votre billet" : "vous recevrez <b>automatiquement</b> votre billet"} par e-mail.</p>`
    + (e.payant ? `<p style="font-size:13px;color:#666">Si aucune place ne se libère, contactez la commission ${esc(e.commission)} pour le remboursement de votre virement.</p>` : "")
    + bouton(lienBillet(i), "Voir ma place dans la liste", "#5a4a8a") + infos(e) + piedDesinsc(i);
  const r = await envoyer(i.email, "Liste d'attente — " + e.titre, cadre(e, "Vous êtes sur la liste d'attente", corps), [], undefined, e.expediteur);
  if (r.ok) await db.from("bil_inscriptions").update({ attente_mail_le: new Date().toISOString() }).eq("id", i.id);
  return r;
}
async function mailPaiementEnVerification(e: Evt, i: Insc, placeLiberee = false) {
  const cfg = await config();
  const corps = (placeLiberee ? `<div style="background:#e8f6ee;border:1px solid #bfe3cd;border-radius:8px;padding:10px 12px;margin:0 0 12px;font-weight:bold">Bonne nouvelle : une place s'est libérée pour vous !</div>` : "")
    + `<p>Bonjour ${esc(prenomOu(i))},</p><p>${placeLiberee ? "Votre" : "Merci, votre adresse est confirmée. Votre"} preuve de paiement va être vérifiée par un·e responsable de la commission ${esc(e.commission)}. Vous recevrez votre billet dès la validation.</p>`
    + blocPaiement(e, i, cfg) + infos(e) + piedDesinsc(i);
  return envoyer(i.email, (placeLiberee ? "Une place s'est libérée — " : "Paiement en vérification — ") + e.titre, cadre(e, "", corps), [], undefined, e.expediteur);
}
async function mailRefus(e: Evt, i: Insc, motif: string, jwt?: string) {
  const corps = `<p>Bonjour ${esc(prenomOu(i))},</p><p>Votre inscription à <b>${esc(e.titre)}</b> n'a pas pu être validée.</p>`
    + (motif.trim() ? `<p><b>Motif :</b></p><p style="background:#f7f7fb;border-radius:8px;padding:10px 12px;white-space:pre-wrap">${esc(motif)}</p>` : "")
    + `<p>Pour toute question, contactez la commission ${esc(e.commission)} du Bureau étudiant.</p>`;
  return envoyer(i.email, "Inscription non validée — " + e.titre, cadre(e, "", corps), [], jwt, e.expediteur);
}
async function mailDesinscription(e: Evt, i: Insc) {
  const corps = `<p>Bonjour ${esc(prenomOu(i))},</p><p>Votre désinscription à <b>${esc(e.titre)}</b> est bien enregistrée. Votre place a été libérée.</p>`
    + (e.payant && i.paye ? `<p>Pour un éventuel remboursement, contactez la commission ${esc(e.commission)}.</p>` : "")
    + `<p>À bientôt à un autre événement du Bureau étudiant !</p>`;
  return envoyer(i.email, "Désinscription enregistrée — " + e.titre, cadre(e, "", corps), [], undefined, e.expediteur);
}
async function mailPresence(e: Evt, i: Insc, jwt?: string) {
  const l = APP + "?p=" + i.secret;
  const corps = `<p>Bonjour ${esc(prenomOu(i))},</p><p>Afin d'organiser au mieux l'accueil, pourriez-vous nous confirmer votre présence ?</p>` + infos(e)
    + `<p style="text-align:center;margin:22px 0 10px"><a href="${l}&r=oui" style="background:#3fae7a;color:#fff;padding:13px 20px;border-radius:10px;text-decoration:none;font-weight:bold;display:inline-block;margin:4px">✅ Je serai présent·e</a> `
    + `<a href="${l}&r=non" style="background:#c9463d;color:#fff;padding:13px 20px;border-radius:10px;text-decoration:none;font-weight:bold;display:inline-block;margin:4px">❌ Je ne viendrai pas</a></p>`
    + `<p style="font-size:13px;color:#666">Votre billet reste valable : <a href="${lienBillet(i)}">afficher mon billet</a>.</p>`;
  const r = await envoyer(i.email, "Confirmez votre présence — " + e.titre, cadre(e, "", corps), [], jwt, e.expediteur);
  if (r.ok) await db.from("bil_inscriptions").update({ presence_demandee_le: new Date().toISOString() }).eq("id", i.id);
  return r;
}
async function mailRappel(e: Evt, i: Insc, jwt?: string) {
  const demain = e.date_evt && plusJours(bxl().date, 1) === String(e.date_evt).slice(0, 10);
  const corps = `<p>Bonjour ${esc(prenomOu(i))},</p><p>${demain ? "C'est <b>demain</b> !" : "Petit rappel :"} nous vous attendons à <b>${esc(e.titre)}</b>.</p>` + infos(e)
    + bouton(lienBillet(i), "📱 Afficher mon billet (QR)") + `<p>Préparez votre QR à l'entrée pour gagner du temps.</p>` + piedDesinsc(i);
  const r = await envoyer(i.email, (demain ? "C'est demain — " : "Rappel — ") + e.titre, cadre(e, "", corps), [], jwt, e.expediteur);
  if (r.ok) await db.from("bil_inscriptions").update({ rappel_le: new Date().toISOString() }).eq("id", i.id);
  return r;
}
async function mailRelance(e: Evt, i: Insc, jwt?: string) {
  const corps = `<p>Bonjour ${esc(prenomOu(i))},</p><p>L'événement a commencé et nous ne vous avons pas encore vu à l'entrée. Voici à nouveau votre billet :</p>`
    + bouton(lienBillet(i), "📱 Afficher mon billet (QR)") + infos(e);
  const r = await envoyer(i.email, "Rappel — " + e.titre, cadre(e, "", corps), [], jwt, e.expediteur);
  if (r.ok) await db.from("bil_inscriptions").update({ relance_le: new Date().toISOString() }).eq("id", i.id);
  return r;
}
async function mailSondage(e: Evt, i: Insc) {
  const corps = `<p>Bonjour ${esc(prenomOu(i))},</p><p>Merci d'être venu·e à <b>${esc(e.titre)}</b> ! Trois questions, trente secondes : votre avis aide la commission ${esc(e.commission)} à faire encore mieux.</p>`
    + bouton(APP + "?s=" + i.secret, "Donner mon avis", "#2e8b57");
  const r = await envoyer(i.email, "Votre avis sur " + e.titre, cadre(e, "", corps), [], undefined, e.expediteur);
  if (r.ok) await db.from("bil_inscriptions").update({ sondage_envoye_le: new Date().toISOString() }).eq("id", i.id);
  return r;
}
async function responsables(e: Evt): Promise<string[]> {
  const { data } = await db.rpc("bil_srv_responsables", { p_cid: e.commission_id });
  return [...new Set(((data as any[]) ?? []).map((r) => r.email).filter(Boolean))];
}
const lienGestion = (e: Evt) => APP + "?ev=" + e.id;
async function alerteResponsables(e: Evt, sujet: string, corps: string) {
  let ok = 0;
  for (const to of await responsables(e)) { if ((await envoyer(to, sujet, cadre(e, "", corps, false), [], undefined, e.expediteur)).ok) ok++; await pause(); }
  return ok;
}
async function alertePreuves(e: Evt, forcer = false) {
  const { count } = await db.from("bil_inscriptions").select("id", { count: "exact", head: true }).eq("evenement_id", e.id).eq("statut", "a_valider");
  if (!count) return;
  const tranche = new Date(); tranche.setUTCMinutes(tranche.getUTCMinutes() < 30 ? 0 : 30, 0, 0);
  if (!forcer && !(await cleUnique(`bil:preuves:${e.id}:${tranche.toISOString()}`))) return;
  await alerteResponsables(e, `${count} preuve(s) de paiement à vérifier — ${e.titre}`,
    `<p>${count} inscription(s) attendent la vérification de leur preuve de paiement.</p>${bouton(lienGestion(e), "Vérifier les preuves")}`);
}
async function alerteJauge(e: Evt) {
  const j = await rpc("bil_srv_jauge", { p_eid: e.id }) as any;
  if (!j?.alerte) return;
  const complet = j.alerte === "complet";
  await alerteResponsables(e, (complet ? "Complet — " : "Presque complet (90 %) — ") + e.titre,
    `<p>${complet ? "L'événement est <b>complet</b>" : "L'événement est <b>presque complet</b>"} : ${j.reserves} place(s) prise(s) sur ${j.places}.</p>`
    + (complet ? "<p>Les nouvelles inscriptions vont en liste d'attente automatiquement.</p>" : "") + bouton(lienGestion(e), "Ouvrir la billetterie"));
}
// Après un changement d'état : le bon mail, et les alertes.
async function apresPassage(e: Evt, id: string, statut: string, contexte: "confirmation" | "liberee" | "validation", jwt?: string) {
  const i = await lireInsc(id);
  if (statut === "inscrit") await mailBillet(e, i, contexte === "liberee" ? "Bonne nouvelle : une place s'est libérée pour vous !" : "", jwt);
  else if (statut === "a_valider") { await mailPaiementEnVerification(e, i, contexte === "liberee"); await alertePreuves(e); }
  else if (statut === "attente") await mailAttente(e, i);
  if (statut === "inscrit" || statut === "a_valider") await alerteJauge(e);
}
async function liberer(e: Evt, jwt?: string) {
  const promus = await rpc("bil_srv_liberer", { p_eid: e.id }) as any[] ?? [];
  for (const p of promus) { await apresPassage(e, p.id, p.statut, "liberee", jwt); await pause(); }
  return promus.length;
}
async function effacerFichiers(chemins: unknown) {
  const l = ((chemins as string[]) ?? []).filter(Boolean);
  for (let k = 0; k < l.length; k += 100) await db.storage.from(BUCKET).remove(l.slice(k, k + 100));
  return l.length;
}

// ------------------------------------------------------------------ Public : inscription
function ogmValide(s: string) {
  const m = /^\+\+\+(\d{3})\/(\d{4})\/(\d{5})\+\+\+$/.exec(s); if (!m) return false;
  const d = m[1] + m[2] + m[3], base = BigInt(d.slice(0, 10)), ctrl = Number(d.slice(10));
  const r = Number(base % 97n); return (r === 0 ? 97 : r) === ctrl;
}
async function hacher(s: string) { return (await sha(s + "|bil")).slice(0, 24); }
const RE_MAIL = /^[^\s@]{1,64}@[^\s@]{1,190}\.[^\s@]{2,}$/;
async function inscrire(req: Request) {
  const fd = await req.formData();
  const g = (k: string) => String(fd.get(k) ?? "").trim();
  if (g("site_web")) return { ok: true, etat: "confirmation" };               // champ piège : on fait semblant
  const { data: e0 } = await db.from("bil_evenements").select("*").eq("code", g("evenement").toUpperCase()).maybeSingle();
  if (!e0) throw new Refus("Cet événement n'existe pas (ou plus).", 404);
  const e = await lireEvt(e0.id);
  const raison = await rpc("bil_raison_fermeture", { p_eid: e.id }) as string;
  if (raison === "maintenance") throw new Refus("La billetterie est en maintenance. Réessayez un peu plus tard.");
  if (raison) throw new Refus(raison === "pas_encore" ? "Les inscriptions ne sont pas encore ouvertes." : "Les inscriptions sont fermées.");
  const nom = g("nom").slice(0, 120), prenom = g("prenom").slice(0, 120), email = g("email").toLowerCase();
  if (!nom || !prenom) throw new Refus("Indiquez votre nom et votre prénom.");
  if (!RE_MAIL.test(email)) throw new Refus("Adresse e-mail invalide.");
  if (g("email2") && g("email2").toLowerCase() !== email) throw new Refus("Les deux adresses e-mail ne sont pas identiques.");
  if (g("rgpd") !== "1") throw new Refus("Merci d'accepter le traitement de vos données (case RGPD).");
  const t0 = Number(g("t0") || 0);
  if (t0 && Date.now() - t0 < 2500) return { ok: true, etat: "confirmation" };   // rempli en moins de 3 s : robot
  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim();
  if (!(await rpc("bil_srv_limite", { p_cle: "mail:" + email, p_max: 6, p_minutes: 60 }))) throw new Refus("Trop d'inscriptions avec cette adresse. Réessayez dans une heure.", 429);
  if (ip && !(await rpc("bil_srv_limite", { p_cle: "ip:" + await hacher(ip), p_max: 40, p_minutes: 60 }))) throw new Refus("Trop d'inscriptions depuis cette connexion. Réessayez plus tard.", 429);

  // Réponses au formulaire personnalisé, vérifiées champ par champ.
  let brut: Record<string, any> = {};
  try { brut = JSON.parse(g("reponses") || "{}"); } catch { brut = {}; }
  const reponses: Record<string, any> = {};
  const aDeposer: { champ: string; label: string; f: File }[] = [];
  for (const c of (e.formulaire ?? []) as any[]) {
    const lab = String(c.label ?? "");
    if (c.type === "photo" || c.type === "fichier") {
      const f = fd.get("f_" + c.id);
      if (f instanceof File && f.size > 0) {
        if (f.size > MAX_FICHIER) throw new Refus(`« ${lab} » : fichier trop lourd (10 Mo au plus).`);
        if (!TYPES_FICHIERS.includes(f.type)) throw new Refus(`« ${lab} » : envoyez une image ou un PDF.`);
        if (c.type === "photo" && !f.type.startsWith("image/")) throw new Refus(`« ${lab} » : une photo est attendue.`);
        aDeposer.push({ champ: c.id, label: lab, f });
      } else if (c.requis) throw new Refus(`« ${lab} » est obligatoire.`);
      continue;
    }
    let v = brut[c.id];
    if (c.type === "case") { v = v === true || v === "1" || v === "oui"; if (c.requis && !v) throw new Refus(`« ${lab} » doit être cochée.`); reponses[c.id] = v; continue; }
    if (c.type === "choix_multiple") {
      const opts = (c.options ?? []).map(String); const l = (Array.isArray(v) ? v : []).map(String).filter((x: string) => opts.includes(x));
      if (c.requis && !l.length) throw new Refus(`« ${lab} » est obligatoire.`); reponses[c.id] = l; continue;
    }
    v = String(v ?? "").trim().slice(0, c.type === "texte_long" ? 3000 : 300);
    if (!v) { if (c.requis) throw new Refus(`« ${lab} » est obligatoire.`); continue; }
    if (c.type === "choix_unique" && !(c.options ?? []).map(String).includes(v)) throw new Refus(`« ${lab} » : choix invalide.`);
    if (c.type === "nombre" && !/^-?\d+([.,]\d+)?$/.test(v)) throw new Refus(`« ${lab} » : un nombre est attendu.`);
    if (c.type === "date" && !/^\d{4}-\d{2}-\d{2}$/.test(v)) throw new Refus(`« ${lab} » : date invalide.`);
    if (c.type === "telephone" && !/^[+0-9 ()./-]{6,25}$/.test(v)) throw new Refus(`« ${lab} » : numéro invalide.`);
    reponses[c.id] = v;
  }
  let preuve: File | null = null, communication = "";
  if (e.payant) {
    const p = fd.get("preuve");
    if (!(p instanceof File) || !p.size) throw new Refus("La preuve de paiement est obligatoire.");
    if (p.size > MAX_FICHIER) throw new Refus("Preuve de paiement trop lourde (10 Mo au plus).");
    if (!TYPES_FICHIERS.includes(p.type)) throw new Refus("Preuve de paiement : envoyez une image ou un PDF.");
    preuve = p; communication = g("communication");
    if (!ogmValide(communication)) throw new Refus("Communication de paiement invalide : rechargez la page.");
  }
  const coopte = g("coopte") === "1" && !!(e.cooptation?.actif);
  const r = await rpc("bil_srv_inscrire", { p: { evenement_id: e.id, nom, prenom, email, reponses, coopte, communication } }) as any;
  if (r.etat === "deja") {
    const lib: Record<string, string> = { a_valider: "votre preuve de paiement est en cours de vérification", attente: "vous êtes sur la liste d'attente", inscrit: "votre billet vous a été envoyé (pensez aux spams)" };
    throw new Refus(`Cette adresse est déjà inscrite à cet événement : ${lib[r.statut] ?? "inscription en cours"}.`, 409);
  }
  if (r.etat === "ferme") throw new Refus("Les inscriptions sont fermées.");
  if (r.etat === "communication") throw new Refus("Cette communication de paiement est déjà utilisée : rechargez la page.", 409);
  if (r.etat !== "nouveau" && r.etat !== "maj") throw new Refus("Inscription impossible.");
  // Fichiers : stockage privé, lisible uniquement par les responsables de la commission.
  const deposes: string[] = [], fichiers: any[] = [];
  let preuvePath: string | null = null;
  try {
    const dep = async (f: File, prefixe: string) => {
      const ext = (f.name.split(".").pop() ?? "").toLowerCase().replace(/[^a-z0-9]/g, "").slice(0, 5) || (f.type === "application/pdf" ? "pdf" : "jpg");
      const chemin = `${e.id}/${r.id}/${prefixe}-${crypto.randomUUID().slice(0, 8)}.${ext}`;
      const { error } = await db.storage.from(BUCKET).upload(chemin, f, { contentType: f.type, upsert: false });
      if (error) throw new Error(error.message);
      deposes.push(chemin); return chemin;
    };
    for (const a of aDeposer) {
      const chemin = await dep(a.f, a.champ);
      fichiers.push({ champ: a.champ, label: a.label, path: chemin, nom: a.f.name.slice(0, 120), type: a.f.type });
      reponses[a.champ] = a.f.name.slice(0, 120);
    }
    if (preuve) preuvePath = await dep(preuve, "preuve");
    const { error } = await db.from("bil_inscriptions").update({ fichiers, preuve_path: preuvePath, reponses }).eq("id", r.id);
    if (error) throw new Error(error.message);
  } catch (x) {
    await effacerFichiers(deposes);
    if (r.etat === "nouveau") await db.from("bil_inscriptions").delete().eq("id", r.id);
    throw new Refus("L'envoi des fichiers a échoué. Vérifiez votre connexion et réessayez. (" + String((x as Error).message ?? x).slice(0, 80) + ")", 502);
  }
  if (r.etat === "maj") await effacerFichiers(((r.anciens ?? []) as any[]).map((x) => x.path));
  const i = await lireInsc(r.id);
  const m = await mailConfirmationAdresse(e, i, r.token);
  return { ok: true, etat: "confirmation", mail: m.ok, email };
}

async function confirmer(token: string) {
  if (!token) throw new Refus("Lien incomplet.");
  const r = await rpc("bil_srv_confirmer", { p_token: token }) as any;
  if (r.etat === "inconnu") return { ok: false, etat: "inconnu" };
  if (r.etat === "expire") return { ok: false, etat: "expire" };
  if (r.etat === "ferme") return { ok: false, etat: "ferme" };
  const e = await lireEvt(r.evenement_id);
  const i = await lireInsc(r.id);
  if (r.etat === "ok") await apresPassage(e, r.id, r.statut, "confirmation");
  return { ok: true, etat: r.etat, statut: r.statut, titre: e.titre, payant: e.payant, secret: i.secret, email: i.email };
}

async function desinscrire(secret: string) {
  if (!secret) throw new Refus("Lien incomplet.");
  const r = await rpc("bil_srv_desinscrire", { p_secret: secret }) as any;
  if (r.etat !== "ok") return { ok: false, etat: r.etat, statut: r.statut };
  const e = await lireEvt(r.evenement_id);
  const i = await lireInsc(r.id);
  if (r.ancien !== "a_confirmer") await mailDesinscription(e, i);
  if (r.ancien === "inscrit" || r.ancien === "a_valider") { await liberer(e); await rpc("bil_srv_jauge", { p_eid: e.id }); }
  return { ok: true, etat: "ok", titre: e.titre };
}

// ------------------------------------------------------------------ Responsables
async function valider(u: Membre, id: string) {
  const i0 = await lireInsc(id); await exigerDroit(u, i0.evenement_id);
  const r = await rpc("bil_srv_valider", { p_id: id, p_par: nomDe(u) }) as any;
  if (!r.ok) throw new Refus("Cette inscription n'est plus en attente de validation (déjà traitée ?).", 409);
  const e = await lireEvt(i0.evenement_id);
  const m = await mailBillet(e, await lireInsc(id), "", u.jwt);
  return { ok: true, mail: m.ok, erreur_mail: m.erreur };
}
async function refuser(u: Membre, id: string, motif: string) {
  const i0 = await lireInsc(id); await exigerDroit(u, i0.evenement_id);
  const r = await rpc("bil_srv_refuser", { p_id: id, p_par: nomDe(u), p_motif: motif }) as any;
  if (!r.ok) throw new Refus("Cette inscription ne peut plus être refusée (déjà traitée ?).", 409);
  const e = await lireEvt(i0.evenement_id);
  const m = r.ancien === "a_confirmer" ? { ok: true } : await mailRefus(e, await lireInsc(id), motif, u.jwt);
  const promus = (r.ancien === "a_valider") ? await liberer(e, u.jwt) : 0;
  if (r.ancien === "a_valider") await rpc("bil_srv_jauge", { p_eid: e.id });
  return { ok: true, mail: m.ok, promus };
}
async function repecher(u: Membre, id: string) {
  const i0 = await lireInsc(id); await exigerDroit(u, i0.evenement_id);
  const r = await rpc("bil_srv_repecher", { p_id: id }) as any;
  if (!r.ok) throw new Refus(r.raison === "doublon" ? "Cette adresse a déjà une autre inscription active." : "Impossible de repêcher cette inscription.", 409);
  const e = await lireEvt(i0.evenement_id);
  await apresPassage(e, id, r.statut, "liberee", u.jwt);
  return { ok: true, statut: r.statut };
}
async function supprimer(u: Membre, id: string) {
  const i0 = await lireInsc(id); await exigerDroit(u, i0.evenement_id);
  const r = await rpc("bil_srv_supprimer", { p_id: id }) as any;
  await effacerFichiers(r.fichiers);
  const e = await lireEvt(i0.evenement_id);
  const promus = (r.statut === "inscrit" || r.statut === "a_valider") ? await liberer(e, u.jwt) : 0;
  await rpc("bil_srv_jauge", { p_eid: e.id });
  return { ok: true, promus };
}
async function masse(u: Membre, eid: string, quoi: string) {
  await exigerDroit(u, eid);
  if (!["doublons", "non_entres", "reset_entrees", "effacer"].includes(quoi)) throw new Refus("Action inconnue.");
  const r = await rpc("bil_srv_masse", { p_eid: eid, p_action: quoi }) as any;
  await effacerFichiers(r.fichiers);
  const e = await lireEvt(eid);
  const promus = quoi === "doublons" ? await liberer(e, u.jwt) : 0;
  await rpc("bil_srv_jauge", { p_eid: eid });
  return { ok: true, n: r.n, promus };
}
async function libererAction(u: Membre, eid: string) {
  await exigerDroit(u, eid);
  const e = await lireEvt(eid);
  const promus = await liberer(e, u.jwt);
  await alerteJauge(e);
  return { ok: true, promus };
}
// Envois groupés depuis l'app : par lots, l'app relance tant qu'il en reste.
async function lotAction(u: Membre, quoi: "billet" | "presence" | "rappel" | "relance", b: Record<string, any>) {
  const eid = String(b.evenement_id); await exigerDroit(u, eid);
  const e = await lireEvt(eid);
  const ids: string[] = Array.isArray(b.ids) ? b.ids.map(String) : [];
  const depuis = String(b.depuis ?? new Date(Date.now() - 6 * 3600000).toISOString());
  let q = db.from("bil_inscriptions").select("*").eq("evenement_id", eid).eq("statut", "inscrit").not("email", "is", null);
  if (ids.length) q = q.in("id", ids);
  else if (quoi === "billet") q = q.is("billet_envoye_le", null);
  else if (quoi === "presence") q = q.is("presence", null).or(`presence_demandee_le.is.null,presence_demandee_le.lt.${depuis}`);
  else if (quoi === "rappel") q = q.or(`rappel_le.is.null,rappel_le.lt.${depuis}`);
  else if (quoi === "relance") q = q.is("entre_le", null).or(`relance_le.is.null,relance_le.lt.${depuis}`);
  const { data, error } = await q.order("created_at").limit(LOT + 1);
  if (error) throw new Refus(error.message);
  const liste = (data ?? []) as Insc[];
  const lot = liste.slice(0, LOT);
  let envoyes = 0; const echecs: string[] = []; let via = "", der = "";
  for (const i of lot) {
    const r = quoi === "billet" ? await mailBillet(e, i, "", u.jwt) : quoi === "presence" ? await mailPresence(e, i, u.jwt)
      : quoi === "rappel" ? await mailRappel(e, i, u.jwt) : await mailRelance(e, i, u.jwt);
    if (r.ok) envoyes++; else { echecs.push(`${i.prenom} ${i.nom} <${i.email}>`); der = r.erreur ?? ""; }
    via = r.via || via;
    await pause();
  }
  const restants = ids.length ? 0 : Math.max(liste.length - lot.length, 0);
  return { ok: true, envoyes, echecs, restants, via, erreur: der };
}
async function bilanHtml(e: Evt) {
  const s = await rpc("bil_stats", { p_eid: e.id }) as any;
  const so = s.sondage ?? {};
  const l = (k: string, v: unknown) => `<tr><td style="padding:4px 14px 4px 0;color:#666">${k}</td><td><b>${esc(v)}</b></td></tr>`;
  return `<p>Voici le bilan de l'événement.</p><table style="border-collapse:collapse;font-size:14px">`
    + l("Inscrit·es", s.inscrits) + l("Présent·es", s.presents) + l("Absent·es", s.absents)
    + l("Taux de présence", s.inscrits ? Math.round(100 * s.presents / s.inscrits) + " %" : "—")
    + (e.payant ? l("Paiements validés", s.payes) + l("Recettes", eur(s.recettes)) : "")
    + l("Liste d'attente (restante)", s.attente) + l("Refus", s.refuses) + l("Désinscriptions", s.desinscrits)
    + (s.cooptes ? l("Intéressé·es par la cooptation", s.cooptes) : "")
    + `</table>` + (so.n ? `<p><b>Sondage</b> (${so.n} réponse(s)) : note globale ${so.note}/5 · organisation ${so.organisation}/5 · reviendraient : ${so.oui} oui, ${so.peut} peut-être, ${so.non} non.</p>` : "")
    + (e.payant && !e.recettes_envoyees_le ? `<p>N'oubliez pas : « Envoyer les recettes à la Caisse » dans l'onglet Bilan.</p>` : "")
    + bouton(lienGestion(e), "Ouvrir la billetterie");
}
async function bilanAction(u: Membre, eid: string) {
  await exigerDroit(u, eid);
  const e = await lireEvt(eid);
  const corps = await bilanHtml(e);
  const dest = new Set([...(await responsables(e)), (u.email ?? "").toLowerCase()].filter(Boolean));
  let ok = 0;
  for (const to of dest) { if ((await envoyer(to, "Bilan — " + e.titre, cadre(e, "Bilan de fin", corps, false), [], u.jwt, e.expediteur)).ok) ok++; await pause(); }
  await db.from("bil_evenements").update({ bilan_envoye_le: new Date().toISOString() }).eq("id", eid);
  return { ok: true, envoyes: ok };
}
async function testAction(u: Membre, eid: string) {
  await exigerDroit(u, eid);
  const e = await lireEvt(eid);
  const faux = { id: "", code: "TEST2345", secret: "test", prenom: u.prenom, nom: u.nom, email: u.email } as Insc;
  let pdf = true; try { billetPdf(e, faux); } catch { pdf = false; }
  const r = await envoyer(u.email, "Test de la billetterie — " + e.titre,
    cadre(e, "Test d'envoi", `<p>Bonjour ${esc(u.prenom)},</p><p>Ce message confirme que les mails de la billetterie partent bien vers votre adresse (expéditeur : ${esc(e.expediteur)}).</p>${infos(e)}`), [], undefined, e.expediteur);   // même chemin que les mails publics (sans compte)
  return { ok: r.ok, via: r.via, erreur: r.erreur ?? "", email: u.email, pdf };
}

// ------------------------------------------------------------------ Tâche planifiée
async function cron(req: Request) {
  const cfg = await config();
  if (!cfg.cron_secret || req.headers.get("x-cron-secret") !== cfg.cron_secret) throw new Refus("Accès refusé.", 401);
  const debut = Date.now(), budget = () => Date.now() - debut < 100000;
  const now = bxl(), auj = now.date, demain = plusJours(auj, 1), hier = plusJours(auj, -1);
  const bilan: Record<string, number> = { rappels: 0, sondages: 0, bilans: 0, promus: 0, fichiers: 0, purges: 0, nonconfirmes: 0 };
  let envois = 0;
  const { data: evts } = await db.from("bil_evenements").select("id").eq("statut", "actif");
  const ids = ((evts ?? []) as any[]).map((x) => x.id);
  for (const eid of ids) {
    if (!budget()) break;
    try {
      const e = await lireEvt(eid);
      const d = e.date_evt ? String(e.date_evt).slice(0, 10) : null;
      // 1) Liste d'attente : filet de sécurité.
      if (!d || d >= auj) { const n = await liberer(e); bilan.promus += n; }
      // 2) Preuves en attente : rappel aux responsables (au plus toutes les 30 min).
      await alertePreuves(e);
      // 3) Rappel la veille, à partir de 10 h.
      if (e.rappel_auto && d === demain && now.heure >= 10) {
        const { data } = await db.from("bil_inscriptions").select("*").eq("evenement_id", eid).eq("statut", "inscrit").is("rappel_le", null).not("email", "is", null).limit(LOT_CRON);
        for (const i of (data ?? []) as Insc[]) {
          if (!budget() || envois >= LOT_CRON) break;
          if (!(await cleUnique(`bil:rappel:${i.id}`))) continue;
          if ((await mailRappel(e, i)).ok) bilan.rappels++; envois++; await pause();
        }
      }
      // 4) Le lendemain (à partir de 10 h, pendant 3 jours) : sondage + bilan aux responsables.
      if (d && d <= hier && d >= plusJours(auj, -3) && now.heure >= 10) {
        if (e.sondage_auto) {
          const { count: entres } = await db.from("bil_inscriptions").select("id", { count: "exact", head: true }).eq("evenement_id", eid).not("entre_le", "is", null);
          let q = db.from("bil_inscriptions").select("*").eq("evenement_id", eid).eq("statut", "inscrit").is("sondage_envoye_le", null).not("email", "is", null);
          if (entres) q = q.not("entre_le", "is", null);
          const { data } = await q.limit(LOT_CRON);
          for (const i of (data ?? []) as Insc[]) {
            if (!budget() || envois >= LOT_CRON) break;
            if (!(await cleUnique(`bil:sondage:${i.id}`))) continue;
            if ((await mailSondage(e, i)).ok) bilan.sondages++; envois++; await pause();
          }
        }
        if (!e.bilan_envoye_le && (await cleUnique(`bil:bilan:${eid}`))) {
          const corps = await bilanHtml(e);
          for (const to of await responsables(e)) { await envoyer(to, "Bilan — " + e.titre, cadre(e, "Bilan de fin", corps, false), [], undefined, e.expediteur); await pause(); }
          await db.from("bil_evenements").update({ bilan_envoye_le: new Date().toISOString() }).eq("id", eid);
          bilan.bilans++;
        }
      }
    } catch (x) { console.error("cron evt", eid, x); }
  }
  // 5) RGPD : fichiers et photos supprimés 30 jours après l'événement.
  try {
    const { data } = await db.from("bil_evenements").select("id,date_evt,created_at").is("fichiers_purges_le", null).limit(50);
    for (const e of (data ?? []) as any[]) {
      if (!budget()) break;
      const ref = e.date_evt ? String(e.date_evt).slice(0, 10) : String(e.created_at).slice(0, 10);
      if (ref > plusJours(auj, -30)) continue;
      const { data: ins } = await db.from("bil_inscriptions").select("id,fichiers,preuve_path").eq("evenement_id", e.id);
      const chemins: string[] = [];
      for (const i of (ins ?? []) as any[]) { (i.fichiers ?? []).forEach((f: any) => f?.path && chemins.push(f.path)); if (i.preuve_path) chemins.push(i.preuve_path); }
      bilan.fichiers += await effacerFichiers(chemins);
      await db.from("bil_inscriptions").update({ fichiers: [], preuve_path: null }).eq("evenement_id", e.id);
      await db.from("bil_evenements").update({ fichiers_purges_le: new Date().toISOString() }).eq("id", e.id);
    }
  } catch (x) { console.error("cron fichiers", x); }
  // 6) RGPD : données des participants supprimées 12 mois après l'événement (statistiques conservées).
  try {
    const { data } = await db.from("bil_evenements").select("id,date_evt,created_at").is("donnees_purgees_le", null).limit(50);
    const limite = new Date(auj + "T12:00:00Z"); limite.setUTCFullYear(limite.getUTCFullYear() - 1);
    const lim = limite.toISOString().slice(0, 10);
    for (const e of (data ?? []) as any[]) {
      if (!budget()) break;
      const ref = e.date_evt ? String(e.date_evt).slice(0, 10) : String(e.created_at).slice(0, 10);
      if (ref > lim) continue;
      const r = await rpc("bil_srv_purge_donnees", { p_eid: e.id }) as any;
      await effacerFichiers(r?.fichiers);
      bilan.purges++;
    }
  } catch (x) { console.error("cron purge", x); }
  // 7) Inscriptions jamais confirmées (7 jours) et compteur anti-robots.
  try {
    const { data } = await db.from("bil_inscriptions").select("id").eq("statut", "a_confirmer").lt("created_at", new Date(Date.now() - 7 * 86400000).toISOString()).limit(200);
    for (const i of (data ?? []) as any[]) { const r = await rpc("bil_srv_supprimer", { p_id: i.id }) as any; await effacerFichiers(r?.fichiers); bilan.nonconfirmes++; }
    await db.from("bil_tentatives").delete().lt("le", new Date(Date.now() - 2 * 86400000).toISOString());
  } catch (x) { console.error("cron nettoyage", x); }
  return { ok: true, ...bilan, duree_ms: Date.now() - debut };
}
