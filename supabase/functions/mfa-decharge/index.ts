// =====================================================================
//  mfa-decharge — décharge « double authentification » (24/11/2026), voir sql/2026-11-24_mfa_decharges.sql
//  Actions (POST JSON) :
//   - envoyer  (x-cron-secret) : { membres: [uuid] } → lien personnel par mail Sécurité-BE ;
//   - info     (public)        : { t } → nom, fonction, texte de la décharge ;
//   - signer   (public)        : { t, mdp } → vérifie le mot de passe (sans code), ajoute la dispense,
//                                fait le PDF (code de signature unique), le range dans « fin-mandat/decharges-mfa »
//                                et l'envoie par mail à la personne.
//  Le lien ne demande ni connexion ni double authentification. Il ne sert qu'une fois, sans expiration.
//  5 mots de passe faux par lien maximum. Le mot de passe n'est jamais gardé.
//  À déployer avec « Verify JWT » DÉSACTIVÉ.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2.115.0";
import { PDFDocument, StandardFonts, rgb } from "npm:pdf-lib@1.17.1";

const SB_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SRK = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ANON = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const db = createClient(SB_URL, SRK, { auth: { persistSession: false, autoRefreshToken: false } });
const ORIGINES = ["https://bojkuesat-ai.github.io"];
const PAGE = "https://bojkuesat-ai.github.io/bureau-ca/decharge-mfa.html";
const BUCKET = "fin-mandat";
const DOSSIER = "decharges-mfa";
const ESSAIS_MAX = 5;
const enc = new TextEncoder();

function cors(req: Request) {
  const o = req.headers.get("origin") ?? "";
  return { "Access-Control-Allow-Origin": ORIGINES.includes(o) ? o : ORIGINES[0], "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret", "Access-Control-Allow-Methods": "POST, OPTIONS", "Vary": "Origin" };
}
const rep = (req: Request, b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors(req), "Content-Type": "application/json" } });
const esc = (s: unknown) => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
const sha = async (s: string) => hex(await crypto.subtle.digest("SHA-256", enc.encode(s)));
const b64u = (u: Uint8Array) => btoa(String.fromCharCode(...u)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const b64 = (u: Uint8Array) => { let s = ""; for (let i = 0; i < u.length; i += 8192) s += String.fromCharCode(...u.subarray(i, i + 8192)); return btoa(s); };
const quand = (d: Date) => ({
  date: d.toLocaleDateString("fr-BE", { timeZone: "Europe/Brussels", day: "2-digit", month: "2-digit", year: "numeric" }),
  heure: d.toLocaleTimeString("fr-BE", { timeZone: "Europe/Brussels", hour: "2-digit", minute: "2-digit", second: "2-digit" }),
});
const ipDe = (req: Request) => ((req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || req.headers.get("cf-connecting-ip") || "inconnue").slice(0, 60);

// ---------------------------------------------------------------- texte de la décharge
const TITRE = "Décharge de responsabilité — Double authentification";
function paragraphes(m: { prenom: string; nom: string; fonction: string; email: string }) {
  return {
    intro: `Je soussigné·e ${m.prenom} ${m.nom}, ${m.fonction} au sein de l'Organe d'Administration du Bureau Étudiant (ASBL), titulaire du compte ${m.email} sur les applications Espace CA et CAISSE, déclare :`,
    points: [
      "avoir été informé·e que la double authentification est demandée pour accéder aux applications, et choisir de ne pas l'activer pour mon compte ;",
      "que mon compte sera protégé uniquement par mon mot de passe ;",
      "que la sécurité de mon compte relève de ma seule responsabilité, notamment en cas de partage de mes identifiants, de perte ou de vol de mon mot de passe, ou de tout accès non autorisé qui en résulterait ;",
      "que le propriétaire et gestionnaire de l'application ne pourra pas être tenu responsable des conséquences d'un tel partage ou d'un tel accès ;",
      "pouvoir activer la double authentification à tout moment depuis mon profil.",
    ],
  };
}
function texteBrut(m: { prenom: string; nom: string; fonction: string; email: string }) {
  const p = paragraphes(m);
  return [TITRE, "", p.intro, ...p.points.map((x, i) => `${i + 1}. ${x}`)].join("\n");
}

// ---------------------------------------------------------------- mails (send-email, expéditeur Sécurité-BE)
async function secret() { const { data } = await db.from("bil_config").select("cron_secret").eq("id", 1).maybeSingle(); return String(data?.cron_secret ?? ""); }
async function mail(to: string, subject: string, corps: string, pj?: { filename: string; content: string }) {
  const html = `<div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:0 auto;color:#1a1a2e;line-height:1.5">${corps}<p style="color:#999;font-size:12px;margin-top:22px">Message automatique — applications du Bureau étudiant. Ne pas répondre.</p></div>`;
  const r = await fetch(SB_URL + "/functions/v1/send-email", { method: "POST",
    headers: { "Content-Type": "application/json", "x-cron-secret": await secret(), "apikey": ANON || SRK },
    body: JSON.stringify({ to, subject, html, from: "Sécurité-BE <noreply@bureauetuidant.xyz>", ...(pj ? { attachments: [pj] } : {}) }) });
  return r.ok ? "" : ("send-email " + r.status + " " + (await r.text()).slice(0, 200));
}

async function membre(id: string) {
  const { data } = await db.from("ca_membres").select("id,prenom,nom,fonction,email").eq("id", id).maybeSingle();
  if (!data) return null;
  const { data: u } = await db.auth.admin.getUserById(id);
  return { id, prenom: String(data.prenom ?? ""), nom: String(data.nom ?? ""), fonction: String(data.fonction ?? "membre"), email: String(u?.user?.email ?? data.email ?? "") };
}
async function ligne(t: string) {
  if (!/^[A-Za-z0-9_-]{30,80}$/.test(String(t ?? ""))) return null;
  const { data } = await db.from("mfa_decharges").select("*").eq("jeton_hash", await sha(t)).maybeSingle();
  return data as any;
}

// ---------------------------------------------------------------- envoi des liens
async function envoyer(ids: string[]) {
  const out: unknown[] = [];
  for (const id of ids) {
    const m = await membre(id);
    if (!m || !m.email) { out.push({ id, ok: false, err: "membre introuvable" }); continue; }
    const { data: dj } = await db.from("mfa_decharges").select("id").eq("membre_id", id).not("signe_le", "is", null).limit(1);
    if (dj?.length) { out.push({ id, ok: false, err: "déjà signée" }); continue; }
    const t = b64u(crypto.getRandomValues(new Uint8Array(32)));
    const { error } = await db.from("mfa_decharges").insert({ membre_id: id, jeton_hash: await sha(t) });
    if (error) { out.push({ id, ok: false, err: error.message }); continue; }
    const lien = PAGE + "#t=" + t;
    const e = await mail(m.email, "Double authentification – votre choix", `
      <p>Bonjour ${esc(m.prenom)},</p>
      <p>La double authentification est désormais demandée pour accéder à CAISSE. Si vous rencontrez un problème pour l'activer, ou si vous préférez ne pas l'utiliser, vous pouvez désactiver cette obligation pour votre compte en cliquant sur le lien ci-dessous :</p>
      <p style="text-align:center;margin:24px 0"><a href="${esc(lien)}" style="display:inline-block;background:#241c46;color:#fff;text-decoration:none;padding:13px 24px;border-radius:10px;font-weight:bold">Désactiver la double authentification</a></p>
      <p>Vous signerez la décharge avec votre <b>mot de passe CAISSE</b> (aucun code ne sera demandé). Vous recevrez ensuite votre décharge en PDF par mail.</p>
      <p>En confirmant, vous reconnaissez que votre compte sera protégé uniquement par votre mot de passe. La sécurité de votre compte relève alors de votre responsabilité, notamment en cas de partage de vos identifiants ou d'accès non autorisé. Le gestionnaire de l'application ne pourra pas être tenu responsable dans ce cas.</p>
      <p>Vous pouvez activer la double authentification à tout moment depuis votre profil.</p>
      <p style="font-size:13px;color:#555">Ce lien est personnel : ne le transférez pas. Si le bouton ne fonctionne pas, copiez ce lien dans votre navigateur :<br>${esc(lien)}</p>
      <p>Sécurité – Bureau Étudiant</p>`);
    out.push({ id, email: m.email, ok: !e, err: e || undefined });
  }
  return out;
}

// ---------------------------------------------------------------- PDF
async function pdf(m: { prenom: string; nom: string; fonction: string; email: string }, s: { date: string; heure: string; ip: string; appareil: string; code: string; empreinte: string }) {
  const doc = await PDFDocument.create();
  doc.setTitle(TITRE); doc.setAuthor(`${m.prenom} ${m.nom}`); doc.setSubject("Code de signature " + s.code); doc.setProducer("Bureau Étudiant — CAISSE");
  const page = doc.addPage([595.28, 841.89]);
  const f = await doc.embedFont(StandardFonts.Helvetica), fb = await doc.embedFont(StandardFonts.HelveticaBold);
  const ok = new Set(f.getCharacterSet());
  const net = (t: string) => [...t.normalize("NFC")].map((c) => ok.has(c.codePointAt(0) as number) ? c : (c.normalize("NFD").replace(/[\u0300-\u036f]/g, "").split("").every((x) => ok.has(x.codePointAt(0) as number)) ? c.normalize("NFD").replace(/[\u0300-\u036f]/g, "") : "?")).join("");
  const L = 60, W = 595.28 - 2 * L; let y = 780;
  const ecrire = (t: string, o: { taille?: number; gras?: boolean; retrait?: number; couleur?: [number, number, number]; apres?: number } = {}) => {
    const fo = o.gras ? fb : f, ta = o.taille ?? 10.5, r = o.retrait ?? 0;
    const mots = net(t).split(/\s+/); let l = "";
    const sortir = (x: string) => { page.drawText(x, { x: L + r, y, size: ta, font: fo, color: rgb(...(o.couleur ?? [0.1, 0.1, 0.18])) }); y -= ta * 1.45; };
    for (const w of mots) { const e = l ? l + " " + w : w; if (fo.widthOfTextAtSize(e, ta) > W - r && l) { sortir(l); l = w; } else l = e; }
    if (l) sortir(l);
    y -= o.apres ?? 6;
  };
  const p = paragraphes(m);
  ecrire("BUREAU ÉTUDIANT — Faculté de Droit et de Criminologie (ULB)", { taille: 9, couleur: [0.45, 0.45, 0.5], apres: 14 });
  ecrire(TITRE, { taille: 16, gras: true, apres: 16 });
  ecrire(p.intro, { apres: 8 });
  p.points.forEach((x, i) => {
    const yy = y; page.drawText(`${i + 1}.`, { x: L + 6, y: yy, size: 10.5, font: fb, color: rgb(0.1, 0.1, 0.18) });
    ecrire(x, { retrait: 22, apres: 5 });
  });
  y -= 14;
  page.drawRectangle({ x: L, y: y - 128, width: W, height: 140, borderColor: rgb(0.14, 0.11, 0.27), borderWidth: 1, color: rgb(0.97, 0.96, 0.99) });
  y -= 4;
  const ligneSig = (a: string, b: string) => { page.drawText(net(a), { x: L + 14, y, size: 10, font: fb, color: rgb(0.1, 0.1, 0.18) }); page.drawText(net(b), { x: L + 150, y, size: 10, font: f, color: rgb(0.1, 0.1, 0.18) }); y -= 17; };
  ecrire("Signature électronique", { gras: true, taille: 11.5, retrait: 14, apres: 4 });
  ligneSig("Signé par", `${m.prenom} ${m.nom} (${m.email})`);
  ligneSig("Moyen", "saisie du mot de passe du compte CAISSE");
  ligneSig("Date et heure", `${s.date} à ${s.heure} (heure de Bruxelles)`);
  ligneSig("Adresse IP", s.ip);
  ligneSig("Code de signature", s.code);
  ligneSig("Empreinte", s.empreinte.slice(0, 32));
  y -= 30;
  ecrire("Appareil : " + s.appareil.slice(0, 160), { taille: 8.5, couleur: [0.45, 0.45, 0.5], apres: 4 });
  ecrire("Le code de signature et l'empreinte (SHA-256 du texte signé, du compte, de la date et de l'adresse IP) sont enregistrés dans la base de l'application : ils permettent de vérifier l'authenticité de ce document. Le mot de passe n'est pas conservé.", { taille: 8.5, couleur: [0.45, 0.45, 0.5], apres: 4 });
  page.drawText(net("Document généré automatiquement — applications du Bureau étudiant"), { x: L, y: 40, size: 8, font: f, color: rgb(0.55, 0.55, 0.6) });
  return await doc.save();
}

// ---------------------------------------------------------------- signature
async function signer(req: Request, t: string, mdp: string) {
  const r = await ligne(t);
  if (!r) return { ok: false, erreur: "Lien invalide." };
  if (r.signe_le) return { ok: false, deja: true, erreur: "Cette décharge a déjà été signée.", code: r.code };
  if (r.essais >= ESSAIS_MAX) return { ok: false, erreur: "Trop d'essais de mot de passe : ce lien est bloqué. Contactez le trésorier." };
  const m = await membre(r.membre_id);
  if (!m || !m.email) return { ok: false, erreur: "Compte introuvable." };
  if (!mdp) return { ok: false, erreur: "Tapez votre mot de passe." };
  // Vérification du mot de passe seul (aucun code demandé), puis fermeture immédiate de cette session.
  const c = createClient(SB_URL, ANON, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: s, error } = await c.auth.signInWithPassword({ email: m.email, password: mdp });
  if (error || !s?.session) {
    await db.from("mfa_decharges").update({ essais: r.essais + 1 }).eq("id", r.id);
    const reste = ESSAIS_MAX - r.essais - 1;
    return { ok: false, erreur: reste > 0 ? `Mot de passe incorrect (encore ${reste} essai${reste > 1 ? "s" : ""}).` : "Mot de passe incorrect : ce lien est maintenant bloqué. Contactez le trésorier." };
  }
  try { await c.auth.signOut({ scope: "local" }); } catch (_) { /* */ }

  const now = new Date(), q = quand(now), ip = ipDe(req), appareil = (req.headers.get("user-agent") ?? "inconnu").slice(0, 300);
  const alea = hex(crypto.getRandomValues(new Uint8Array(8)).buffer).toUpperCase();
  const code = `SIG-${alea.slice(0, 4)}-${alea.slice(4, 8)}-${alea.slice(8, 12)}-${alea.slice(12, 16)}`;
  const texte = texteBrut(m);
  const empreinte = await sha([texte, m.id, m.email, now.toISOString(), ip, code].join("\n"));
  // Marquage atomique : un seul clic gagnant.
  const { data: maj } = await db.from("mfa_decharges").update({ signe_le: now.toISOString(), code, empreinte, ip, appareil, texte })
    .eq("id", r.id).is("signe_le", null).select("id");
  if (!maj?.length) return { ok: false, deja: true, erreur: "Cette décharge a déjà été signée." };

  await db.from("mfa_dispenses").upsert({ membre_id: m.id, motif: `${m.prenom} ${m.nom} : décharge signée (mot de passe) le ${q.date} à ${q.heure}, code ${code}` }, { onConflict: "membre_id" });

  const octets = await pdf(m, { date: q.date, heure: q.heure, ip, appareil, code, empreinte });
  const nomF = `Decharge-MFA_${(m.prenom + "-" + m.nom).normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/[^A-Za-z0-9-]+/g, "-")}_${now.toISOString().slice(0, 10)}_${code}.pdf`;
  const chemin = `${DOSSIER}/${nomF}`;
  const up = await db.storage.from(BUCKET).upload(chemin, octets, { contentType: "application/pdf", upsert: true });
  await db.from("mfa_decharges").update({ pdf_chemin: up.error ? null : chemin }).eq("id", r.id);
  if (up.error) console.error("stockage", up.error.message);

  const e = await mail(m.email, "Votre décharge – double authentification", `
    <p>Bonjour ${esc(m.prenom)},</p>
    <p>Votre décharge a bien été signée le <b>${esc(q.date)} à ${esc(q.heure)}</b>. La double authentification n'est plus obligatoire pour votre compte : vous pouvez vous connecter avec votre mot de passe seul.</p>
    <p>Code de signature : <b>${esc(code)}</b></p>
    <p>Vous trouverez votre décharge en PDF en pièce jointe. Vous pouvez activer la double authentification à tout moment depuis votre profil.</p>
    <p>Sécurité – Bureau Étudiant</p>`, { filename: nomF, content: b64(octets) });
  if (e) console.error("mail confirmation", e);
  return { ok: true, code, date: q.date, heure: q.heure, mail: !e };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  try {
    const b = await req.json().catch(() => ({})) as Record<string, any>;
    if (b.action === "envoyer") {
      const sec = await secret();
      if (!sec || req.headers.get("x-cron-secret") !== sec) return rep(req, { ok: false, erreur: "Accès refusé." }, 401);
      const ids = ((b.membres ?? []) as unknown[]).map(String).filter((x) => /^[0-9a-f-]{36}$/i.test(x)).slice(0, 20);
      return rep(req, { ok: true, resultats: await envoyer(ids) });
    }
    if (b.action === "info") {
      const r = await ligne(String(b.t ?? ""));
      if (!r) return rep(req, { ok: false, erreur: "Lien invalide." }, 404);
      const m = await membre(r.membre_id);
      if (!m) return rep(req, { ok: false, erreur: "Compte introuvable." }, 404);
      const p = paragraphes(m);
      return rep(req, { ok: true, prenom: m.prenom, nom: m.nom, email: m.email, titre: TITRE, intro: p.intro, points: p.points,
        signe: !!r.signe_le, code: r.signe_le ? r.code : null, bloque: r.essais >= ESSAIS_MAX });
    }
    if (b.action === "signer") return rep(req, await signer(req, String(b.t ?? ""), String(b.mdp ?? "")));
    return rep(req, { ok: false, erreur: "Action inconnue." }, 400);
  } catch (e) { console.error(e); return rep(req, { ok: false, erreur: "Erreur du serveur." }, 500); }
});
