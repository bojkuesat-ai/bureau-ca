// =====================================================================
//  fin-mandat — fin de mandat programmée (01/07/2027), voir sql/2026-11-15_fin_de_mandat.sql
//  Appelée par la tâche « fin-mandat » (x-cron-secret) quand une étape est due, ou par le
//  propriétaire connecté (espace Propriétaire) : état, liens, renvoi, aperçu.
//   - archives (jour J-7) : deux zips en parties de 40 Mo max — « archives du CA » (tables + fichiers
//     ca-documents) et « comptabilité de la Caisse » (tables + justificatifs) — rangés dans le
//     stockage privé « fin-mandat », puis liens de 30 jours à la présidente, la secrétaire, le trésorier.
//   - sauvegarde finale (jour J) : toutes les tables, chiffrées avec SAUVEGARDE_PHRASE (format BESAV1).
//   - suppression (jour J) : fin_mandat_vider() en base, puis tous les fichiers (sauf « fin-mandat »),
//     mail d'adieu aux anciens comptes, rapport au propriétaire.
//  Les mails au propriétaire partent avec l'expéditeur « Licence-BE » (seul admis après la passation).
//  À déployer avec « Verify JWT » DÉSACTIVÉ.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2.115.0";
import { zipSync, strToU8 } from "npm:fflate@0.8.2";

const SB_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SRK = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ANON = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const PHRASE = Deno.env.get("SAUVEGARDE_PHRASE") ?? "";
const ORIGINES = ["https://bojkuesat-ai.github.io"];
const db = createClient(SB_URL, SRK, { auth: { persistSession: false, autoRefreshToken: false } });
const enc = new TextEncoder();
const BUCKET = "fin-mandat";
const PARTIE_MAX = 40 * 1024 * 1024;
const LIEN_DUREE = 30 * 24 * 3600;
const APP = "https://bojkuesat-ai.github.io/bureau-ca/";

type Partie = { chemin: string; octets: number; fichiers: number };
type Suivi = { parts: Partie[]; prochain: number; fini: boolean };

// Contenu des deux zips. Les échanges confidentiels (soutien psychologique, CES, médiation,
// messages privés, bilans anonymes) ne sont PAS remis : ils restent dans la sauvegarde chiffrée.
const ZIPS: Record<string, { titre: string; fichier: string; bucket: string; tables: string[] }> = {
  ca: {
    titre: "Archives du CA", fichier: "archives-CA", bucket: "ca-documents",
    tables: ["ca_membres", "ca_reunions", "ca_pv_signatures", "ca_procurations", "ca_votes", "ca_vote_options", "ca_budgets", "ca_budget_votes",
      "ca_budget_reserves", "ca_docs", "ca_courriers", "ca_annonces", "ca_evenements", "ca_event_presence", "ca_taches", "ca_org", "ca_contacts",
      "ca_journal", "ca_avis", "ca_salle_reservations", "bil_evenements", "signatures_registre", "transparence_journal"],
  },
  compta: {
    titre: "Comptabilité de la Caisse", fichier: "comptabilite-Caisse", bucket: "justificatifs",
    tables: ["profiles", "requests", "events", "expenses", "incomes", "closures", "depensiers", "factures_echeance", "gj_actes", "gj_liens",
      "sc_actes", "novelles_acces", "novelles_mouvements", "caisse_budget_attrib", "caisse_budget_histo", "caisse_budget_meta",
      "caisse_budget_reservations", "caisse_documents", "caisse_config", "tb_config"],
  },
};
// Colonnes retirées des exports (données de connexion / techniques).
const COLONNES_MASQUEES = new Set(["jeton_hash", "lien_hash", "push_endpoint", "p256dh", "auth_key"]);

function cors(req: Request) {
  const o = req.headers.get("origin") ?? "";
  return { "Access-Control-Allow-Origin": ORIGINES.includes(o) ? o : ORIGINES[0], "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret", "Access-Control-Allow-Methods": "POST, OPTIONS", "Vary": "Origin" };
}
const rep = (req: Request, b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors(req), "Content-Type": "application/json" } });
const esc = (s: unknown) => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const jour = (d: string | Date) => new Date(d).toLocaleDateString("fr-BE", { timeZone: "Europe/Brussels", day: "2-digit", month: "2-digit", year: "numeric" });
const quand = (d: string | Date) => new Date(d).toLocaleString("fr-BE", { timeZone: "Europe/Brussels", day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit" });
const mo = (n: number) => (n / 1048576).toFixed(1).replace(".", ",") + " Mo";

async function etat() { const { data, error } = await db.from("fin_mandat").select("*").eq("id", 1).single(); if (error) throw new Error(error.message); return data as any; }
async function maj(p: Record<string, unknown>) { const { error } = await db.from("fin_mandat").update({ ...p, maj_le: new Date().toISOString() }).eq("id", 1); if (error) throw new Error(error.message); }
async function noter(quoi: string, a: string | null, detail: string | null) { await db.from("fin_mandat_envois").insert({ quoi, a, detail }); }

// ---------------------------------------------------------------- mails
async function mail(to: string, subject: string, corps: string, exp: string) {
  const { data: cfg } = await db.from("bil_config").select("cron_secret").eq("id", 1).maybeSingle();
  const html = `<div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:0 auto;color:#1a1a2e;line-height:1.5">${corps}<p style="color:#999;font-size:12px;margin-top:22px">Message automatique — applications du Bureau étudiant. Ne pas répondre.</p></div>`;
  try {
    const r = await fetch(SB_URL + "/functions/v1/send-email", { method: "POST", headers: { "Content-Type": "application/json", "x-cron-secret": String(cfg?.cron_secret ?? ""), "apikey": ANON || SRK },
      body: JSON.stringify({ to, subject, html, from: exp + " <noreply@bureauetuidant.xyz>" }) });
    return r.ok ? "" : ("send-email " + r.status + " " + (await r.text()).slice(0, 160));
  } catch (e) { return String(e); }
}
async function emailProprio(): Promise<string> {
  const { data } = await db.from("ca_membres").select("email,role").in("role", ["owner", "proprietaire"]).order("role", { ascending: false });
  return ((data ?? []) as any[]).map((m) => m.email).find(Boolean) ?? "";
}
async function auProprio(sujet: string, corps: string) { const e = await emailProprio(); if (e) await mail(e, sujet, corps, "Licence-BE"); }

// ---------------------------------------------------------------- données
async function lireTable(t: string): Promise<any[] | null> {
  const out: any[] = [];
  for (let p = 0; p < 1000; p++) {
    const { data, error } = await db.from(t).select("*").range(p * 1000, p * 1000 + 999);
    if (error) return null;
    out.push(...(data ?? [])); if (!data || data.length < 1000) break;
  }
  return out;
}
function csv(lignes: any[]): string {
  const cols: string[] = [];
  for (const l of lignes) for (const k of Object.keys(l)) if (!cols.includes(k) && !COLONNES_MASQUEES.has(k)) cols.push(k);
  const cel = (v: unknown) => { if (v === null || v === undefined) return ""; const s = typeof v === "object" ? JSON.stringify(v) : String(v); return /[";\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
  return "﻿" + [cols.join(";"), ...lignes.map((l) => cols.map((c) => cel(l[c])).join(";"))].join("\r\n");
}
async function listerFichiers(bucket: string) {
  const out: { chemin: string; taille: number }[] = [];
  const dossiers = [""]; let tours = 0;
  while (dossiers.length && tours++ < 5000) {
    const dos = dossiers.shift() as string;
    for (let off = 0; off < 1000000; off += 1000) {
      const { data: l } = await db.storage.from(bucket).list(dos, { limit: 1000, offset: off, sortBy: { column: "name", order: "asc" } });
      for (const it of (l ?? []) as any[]) {
        const ch = (dos ? dos + "/" : "") + it.name;
        if (it.id === null || it.metadata == null) dossiers.push(ch); else out.push({ chemin: ch, taille: Number(it.metadata?.size ?? 0) });
      }
      if (!l || l.length < 1000) break;
    }
  }
  return out.sort((a, b) => a.chemin.localeCompare(b.chemin));
}

// Construit UNE partie d'un zip et renvoie le suivi mis à jour.
async function partie(type: "ca" | "compta", dossier: string, date: string, suivi: Suivi): Promise<Suivi> {
  const Z = ZIPS[type];
  const fichiers = await listerFichiers(Z.bucket);
  const n = suivi.parts.length + 1;
  const contenu: Record<string, Uint8Array | [Uint8Array, { level: 0 | 6 }]> = {};
  if (n === 1) {
    const resume: string[] = [];
    for (const t of Z.tables) {
      let l = await lireTable(t);
      if (l === null) continue;
      if (t === "ca_membres") l = l.map((m) => ({ prenom: m.prenom, nom: m.nom, fonction: m.fonction, email: m.email, role: m.role, statut: m.statut, admin: m.admin, inscrit_le: m.created_at }));
      if (t === "profiles") l = l.map((p) => ({ id: p.id, nom: p.name || ((p.first_name ?? "") + " " + (p.last_name ?? "")).trim(), fonction: p.position, email: p.email, role: p.role, approuve: p.approved, iban: p.iban ?? null, inscrit_le: p.created_at }));
      contenu["tableaux/" + t + ".csv"] = [strToU8(csv(l)), { level: 6 }];
      resume.push(`  - ${t}.csv : ${l.length} ligne(s)`);
    }
    if (type === "ca") {
      // Résultats des votes (sans dire qui a voté quoi).
      const b = await lireTable("ca_vote_ballots") ?? [];
      const compte: Record<string, number> = {};
      for (const x of b) { const k = String(x.vote_id ?? "") + "|" + String(x.option_id ?? ""); compte[k] = (compte[k] ?? 0) + 1; }
      contenu["tableaux/ca_votes_resultats.csv"] = [strToU8(csv(Object.entries(compte).map(([k, v]) => ({ vote_id: k.split("|")[0], option_id: k.split("|")[1], voix: v })))), { level: 6 }];
      resume.push("  - ca_votes_resultats.csv : nombre de voix par option (bulletins individuels non inclus)");
    }
    const total = fichiers.reduce((s, f) => s + f.taille, 0);
    contenu["LISEZMOI.txt"] = [strToU8([
      `${Z.titre} — Bureau étudiant`,
      `Créé le ${quand(new Date())} (fin du mandat).`, "",
      "Dossier « tableaux » : chaque table au format CSV (séparateur « ; », s'ouvre dans Excel ou LibreOffice).",
      ...resume, "",
      `Dossier « fichiers » : ${fichiers.length} fichier(s) (${mo(total)}) tels qu'ils étaient dans l'application`,
      type === "ca" ? "  (PV signés, documents, courriers signés…)." : "  (justificatifs, factures, extraits…).",
      "Si l'archive est découpée en plusieurs parties (partie-1, partie-2…), les fichiers sont répartis entre elles : gardez-les toutes.", "",
      type === "compta" ? "À conserver : la comptabilité et ses pièces doivent être gardées plusieurs années (obligation légale de l'ASBL)." :
        "Les échanges confidentiels (soutien, médiation, messages privés) ne sont pas inclus.",
    ].join("\r\n")), { level: 6 }];
  }
  let i = suivi.prochain, taille = 0, nb = 0;
  while (i < fichiers.length && (nb === 0 || taille + fichiers[i].taille <= PARTIE_MAX)) {
    const f = fichiers[i];
    const { data, error } = await db.storage.from(Z.bucket).download(f.chemin);
    if (!error && data) { const u = new Uint8Array(await data.arrayBuffer()); contenu["fichiers/" + f.chemin] = [u, { level: 0 }]; taille += u.length; nb++; }
    else contenu["fichiers/" + f.chemin + ".INTROUVABLE.txt"] = [strToU8("Fichier non téléchargeable : " + (error?.message ?? "?")), { level: 6 }];
    i++;
  }
  const zip = zipSync(contenu as any);
  const chemin = `${dossier}/${Z.fichier}-${date}-partie-${n}.zip`;
  const up = await db.storage.from(BUCKET).upload(chemin, zip, { contentType: "application/zip", upsert: true });
  if (up.error) throw new Error("Stockage : " + up.error.message);
  return { parts: [...suivi.parts, { chemin, octets: zip.length, fichiers: nb }], prochain: i, fini: i >= fichiers.length };
}

async function liens(parts: Partie[]) {
  const out: { nom: string; url: string; octets: number }[] = [];
  for (const p of parts) {
    const { data } = await db.storage.from(BUCKET).createSignedUrl(p.chemin, LIEN_DUREE, { download: p.chemin.split("/").pop() });
    if (data?.signedUrl) out.push({ nom: p.chemin.split("/").pop() ?? p.chemin, url: data.signedUrl, octets: p.octets });
  }
  return out;
}
function blocLiens(titre: string, l: { nom: string; url: string; octets: number }[]) {
  return `<h3 style="margin:16px 0 6px">${esc(titre)}</h3>` + l.map((x) => `<p style="margin:6px 0"><a href="${x.url}" style="background:#241c46;color:#fff;padding:9px 14px;border-radius:8px;text-decoration:none;display:inline-block">⬇ ${esc(x.nom)}</a> <span style="color:#777">${mo(x.octets)}</span></p>`).join("");
}
// Envoie les deux archives à une liste de destinataires (liens neufs de 30 jours).
async function envoyerArchives(dest: any[], f: any, motif: string) {
  const lCa = await liens(f.archives?.ca?.parts ?? []), lCo = await liens(f.archives?.compta?.parts ?? []);
  const exp = new Date(Date.now() + LIEN_DUREE * 1000);
  const res: { nom: string; email: string; ok: boolean; err: string }[] = [];
  for (const d of dest) {
    const corps = `<h2 style="margin:0 0 10px">📦 Archives de fin de mandat</h2><p>Bonjour ${esc(String(d.nom ?? "").split(" ")[0])},</p>
      <p>Le mandat du CA se termine : en tant que <b>${esc(d.libelle ?? "")}</b>, vous recevez les <b>archives du CA</b> et la <b>comptabilité de la Caisse</b>.
      Le <b>${jour(f.suppression_le)}</b>, les comptes et toutes les données des applications seront supprimés : <b>téléchargez et conservez ces fichiers</b>.</p>
      ${blocLiens("Archives du CA (PV, documents, votes, budgets, courriers…)", lCa)}
      ${blocLiens("Comptabilité de la Caisse (demandes, dépenses, recettes, justificatifs…)", lCo)}
      <p style="color:#a33"><b>Liens valables jusqu'au ${jour(exp)}.</b> La comptabilité et ses pièces doivent être conservées plusieurs années.</p>
      <p style="color:#777;font-size:13px">Chaque archive contient un fichier LISEZMOI.txt. Les tableaux s'ouvrent dans Excel ou LibreOffice.</p>`;
    const e = await mail(d.email, "📦 Archives du CA et comptabilité de la Caisse — fin de mandat", corps, "Bureau étudiant");
    res.push({ nom: d.nom, email: d.email, ok: !e, err: e });
    await noter(motif, `${d.libelle} — ${d.nom} <${d.email}>`, e ? "échec : " + e : "envoyé (liens 30 jours)");
  }
  return res;
}

// ---------------------------------------------------------------- sauvegarde chiffrée
async function gzip(d: Uint8Array) { return new Uint8Array(await new Response(new Blob([d]).stream().pipeThrough(new CompressionStream("gzip"))).arrayBuffer()); }
async function chiffrer(d: Uint8Array) {
  const sel = crypto.getRandomValues(new Uint8Array(16)), iv = crypto.getRandomValues(new Uint8Array(12));
  const base = await crypto.subtle.importKey("raw", enc.encode(PHRASE), "PBKDF2", false, ["deriveKey"]);
  const cle = await crypto.subtle.deriveKey({ name: "PBKDF2", salt: sel, iterations: 250000, hash: "SHA-256" }, base, { name: "AES-GCM", length: 256 }, false, ["encrypt"]);
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, cle, d));
  const out = new Uint8Array(6 + 16 + 12 + ct.length);
  out.set(enc.encode("BESAV1"), 0); out.set(sel, 6); out.set(iv, 22); out.set(ct, 34);
  return out;
}
async function sauvegardeFinale() {
  if (PHRASE.length < 12) throw new Error("Phrase secrète SAUVEGARDE_PHRASE absente : sauvegarde finale impossible, suppression reportée.");
  const { data: tables, error } = await db.rpc("fin_mandat_tables");
  if (error) throw new Error(error.message);
  const contenu: Record<string, unknown[]> = {}; let lignes = 0;
  for (const t of (tables ?? []) as string[]) { const l = await lireTable(t); contenu[t] = l ?? []; lignes += (l ?? []).length; }
  const { data: users } = await db.auth.admin.listUsers({ page: 1, perPage: 1000 });
  contenu["__auth_users"] = ((users?.users ?? []) as any[]).map((u) => ({ id: u.id, email: u.email, cree_le: u.created_at, derniere_connexion: u.last_sign_in_at }));
  const fichiers: Record<string, unknown[]> = {};
  const { data: bks } = await db.storage.listBuckets();
  for (const b of bks ?? []) if (b.id !== BUCKET) fichiers[b.id] = await listerFichiers(b.id);
  const json = enc.encode(JSON.stringify({ format: "sauvegarde-bureau-etudiant", version: 1, cree_le: new Date().toISOString(), motif: "fin de mandat", lignes, tables: contenu, fichiers_stockes: fichiers }));
  const fichier = await chiffrer(await gzip(json));
  const chemin = `sauvegarde-finale/sauvegarde-fin-de-mandat-${new Date().toISOString().slice(0, 10)}.besav`;
  const up = await db.storage.from(BUCKET).upload(chemin, fichier, { contentType: "application/octet-stream", upsert: true });
  if (up.error) throw new Error("Stockage de la sauvegarde : " + up.error.message);
  return { chemin, octets: fichier.length, lignes, le: new Date().toISOString() };
}

// ---------------------------------------------------------------- suppression
async function viderStockage() {
  const { data: bks } = await db.storage.listBuckets(); let n = 0;
  for (const b of bks ?? []) {
    if (b.id === BUCKET) continue;
    const l = (await listerFichiers(b.id)).map((f) => f.chemin);
    for (let i = 0; i < l.length; i += 100) { const { error } = await db.storage.from(b.id).remove(l.slice(i, i + 100)); if (error) throw new Error("Stockage " + b.id + " : " + error.message); n += Math.min(100, l.length - i); }
  }
  return n;
}
async function suppression(f: any) {
  // Adresses des comptes à supprimer (pour le mail d'adieu), sauf le propriétaire.
  const proprio = await emailProprio();
  const a = new Set<string>();
  for (const t of ["ca_membres", "profiles"]) { const l = await lireTable(t) ?? []; for (const x of l) { const e = String(x.email ?? "").trim().toLowerCase(); if (e && e !== proprio.toLowerCase()) a.add(e); } }
  // La base d'abord (elle revérifie archives + sauvegarde), puis les fichiers.
  const { data: r, error } = await db.rpc("fin_mandat_vider");
  if (error) throw new Error("Vidage de la base : " + error.message);
  let nFichiers = 0;
  try { nFichiers = await viderStockage(); }
  catch (e) { await auProprio("⚠️ Fin de mandat : fichiers non supprimés", `<p>La base est vidée, mais des fichiers n'ont pas pu être supprimés : ${esc(String((e as Error)?.message ?? e))}. Supprimez-les dans Supabase › Storage (sauf « fin-mandat »).</p>`); }
  let adieux = 0;
  for (const e of a) {
    const err = await mail(e, "👋 Merci pour votre mandat", `<h2 style="margin:0 0 10px">👋 Merci pour votre mandat</h2>
      <p>Bonjour,</p><p>Le mandat est terminé : comme annoncé, votre compte de l'<b>Espace CA</b> et de la <b>Caisse</b> a été supprimé, avec toutes les données des applications.</p>
      <p>Les archives du CA et la comptabilité ont été remises à la présidente, à la secrétaire et au trésorier.</p>
      <p>Merci pour votre engagement au service des étudiants, et bonne continuation !</p>`, "Bureau étudiant");
    if (!err) adieux++;
  }
  await noter("suppression", null, `${(r as any)?.comptes_supprimes ?? "?"} compte(s), ${(r as any)?.tables_videes ?? "?"} table(s), ${nFichiers} fichier(s) ; adieux ${adieux}/${a.size}`);
  await maj({ rapport: { ...(r as any), fichiers_supprimes: nFichiers, adieux, adresses: a.size } });
  await auProprio("✅ Fin de mandat faite — applications vidées", `<h2 style="margin:0 0 10px">✅ Fin de mandat faite</h2>
    <p>Le ${quand(new Date())} :</p><ul><li>${(r as any)?.comptes_supprimes ?? "?"} compte(s) supprimé(s) (le vôtre est gardé) ;</li>
    <li>${(r as any)?.tables_videes ?? "?"} table(s) vidée(s), ${nFichiers} fichier(s) supprimé(s) ;</li><li>mail d'adieu envoyé à ${adieux}/${a.size} adresse(s).</li></ul>
    <p>Les archives et la sauvegarde finale restent dans votre <b>espace Propriétaire › Fin de mandat</b>.</p>
    <p>Pour le nouveau CA : les membres créent leur compte, puis vous nommez la nouvelle Admin depuis l'espace Propriétaire.</p><p><a href="${APP}">Ouvrir l'Espace CA</a></p>`);
}

// ---------------------------------------------------------------- étape planifiée
async function tick() {
  const f = await etat();
  if (f.statut !== "programme") return { rien: true };
  const now = Date.now();
  if (f.en_cours && now - new Date(f.en_cours).getTime() < 9 * 60000) return { en_cours: true };
  await maj({ en_cours: new Date().toISOString() });
  try {
    const date = new Date(f.archives_le).toISOString().slice(0, 10);
    // 1. Archives (une partie par passage), puis envoi.
    if (now >= new Date(f.archives_le).getTime() && !f.archives_envoye) {
      const A = f.archives ?? {};
      for (const t of ["ca", "compta"] as const) {
        const s: Suivi = A[t] ?? { parts: [], prochain: 0, fini: false };
        if (!s.fini) { A[t] = await partie(t, "archives", date, s); await maj({ archives: A, derniere_erreur: null }); return { partie: t }; }
      }
      const dest = (await db.rpc("fin_mandat_destinataires")).data as any[] ?? [];
      const res = await envoyerArchives(dest, { ...f, archives: A }, "archives");
      await maj({ archives_envoye: new Date().toISOString(), destinataires: dest, derniere_erreur: null });
      await auProprio("📦 Fin de mandat : archives envoyées", `<h2 style="margin:0 0 10px">📦 Archives envoyées</h2>
        <ul>${res.map((x) => `<li>${esc(x.nom)} &lt;${esc(x.email)}&gt; : ${x.ok ? "✅ envoyé" : "❌ " + esc(x.err)}</li>`).join("") || "<li>❌ Aucun destinataire trouvé (présidente, secrétaire, trésorier)</li>"}</ul>
        <p>Copies gardées dans votre <b>espace Propriétaire › Fin de mandat</b> (bouton « Renvoyer »). Suppression prévue le <b>${quand(f.suppression_le)}</b>.</p>`);
      return { archives: "envoyées" };
    }
    // 2. Jour J : sauvegarde finale, puis suppression.
    if (now >= new Date(f.suppression_le).getTime() && !f.suppression_fait && f.archives_envoye) {
      if (!f.sauvegarde) {
        const s = await sauvegardeFinale();
        await maj({ sauvegarde: s, derniere_erreur: null });
        const { data: l } = await db.storage.from(BUCKET).createSignedUrl(s.chemin, LIEN_DUREE, { download: s.chemin.split("/").pop() });
        await noter("sauvegarde finale", null, `${s.lignes} ligne(s), ${mo(s.octets)}`);
        await auProprio("💾 Fin de mandat : sauvegarde finale", `<h2 style="margin:0 0 10px">💾 Sauvegarde finale</h2>
          <p>${s.lignes} ligne(s), chiffrées avec votre phrase secrète (${mo(s.octets)}). La suppression suit dans quelques minutes.</p>
          ${l?.signedUrl ? `<p><a href="${l.signedUrl}">⬇ Télécharger la sauvegarde</a> (lien de 30 jours ; elle reste aussi dans l'espace Propriétaire).</p>` : ""}`);
        return { sauvegarde: true };
      }
      await suppression(f);
      return { suppression: true };
    }
    return { rien: true };
  } catch (e) {
    const m = String((e as Error)?.message ?? e);
    if (m !== f.derniere_erreur) await auProprio("⚠️ Fin de mandat : problème", `<h2 style="margin:0 0 10px">⚠️ Problème pendant la fin de mandat</h2><p>${esc(m)}</p><p>L'étape sera retentée automatiquement toutes les 10 minutes. Rien n'est supprimé tant que les archives et la sauvegarde ne sont pas faites.</p>`);
    await maj({ derniere_erreur: m });
    throw e;
  } finally {
    await db.from("fin_mandat").update({ en_cours: null }).eq("id", 1);
  }
}

// ---------------------------------------------------------------- propriétaire
async function fichiersStockes() {
  const l = await listerFichiers(BUCKET);
  return l.map((x) => ({ chemin: x.chemin, octets: x.taille }));
}
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  try {
    const b = await req.json().catch(() => ({})) as Record<string, any>;
    if (b.action === "tick") {
      const { data: cfg } = await db.from("bil_config").select("cron_secret").eq("id", 1).maybeSingle();
      if (!cfg?.cron_secret || req.headers.get("x-cron-secret") !== cfg.cron_secret) return rep(req, { ok: false, erreur: "Accès refusé." }, 401);
      // Travail en arrière-plan : la tâche planifiée n'attend pas.
      const travail = tick().catch((e) => console.error("fin-mandat", e));
      // deno-lint-ignore no-explicit-any
      (globalThis as any).EdgeRuntime?.waitUntil?.(travail);
      return rep(req, { ok: true, lance: true }, 202);
    }
    // Propriétaire connecté (avec son code de double authentification).
    const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: u } = await db.auth.getUser(jwt);
    if (!u?.user) return rep(req, { ok: false, erreur: "Connexion requise." }, 401);
    const uc = createClient(SB_URL, ANON, { global: { headers: { Authorization: "Bearer " + jwt } }, auth: { persistSession: false, autoRefreshToken: false } });
    const { data: est } = await uc.rpc("proprio_est");
    if (est !== true) return rep(req, { ok: false, erreur: "Réservé au propriétaire." }, 403);

    if (b.action === "fichiers") return rep(req, { ok: true, fichiers: await fichiersStockes(), phrase: PHRASE.length >= 12 });
    if (b.action === "lien") {
      const ch = String(b.chemin ?? "");
      const { data, error } = await db.storage.from(BUCKET).createSignedUrl(ch, 3600, { download: ch.split("/").pop() });
      if (error) return rep(req, { ok: false, erreur: error.message }, 404);
      return rep(req, { ok: true, url: data.signedUrl });
    }
    if (b.action === "renvoyer") {
      const f = await etat();
      if (!f.archives_envoye || !Array.isArray(f.destinataires)) return rep(req, { ok: false, erreur: "Les archives ne sont pas encore faites : rien à renvoyer." }, 400);
      const roles = new Set(((b.roles ?? []) as string[]).map(String));
      const dest = (f.destinataires as any[]).filter((d) => roles.has(d.role));
      if (!dest.length) return rep(req, { ok: false, erreur: "Choisissez au moins une personne." }, 400);
      const res = await envoyerArchives(dest, f, "renvoi");
      return rep(req, { ok: true, resultats: res });
    }
    if (b.action === "apercu") {
      // Aperçu pour le propriétaire seul : mêmes zips, rien n'est envoyé ni supprimé.
      const anciens = (await listerFichiers(BUCKET)).filter((x) => x.chemin.startsWith("apercu/")).map((x) => x.chemin);
      if (anciens.length) await db.storage.from(BUCKET).remove(anciens);
      const date = "apercu-" + new Date().toISOString().slice(0, 10);
      const out: Partie[] = [];
      for (const t of ["ca", "compta"] as const) {
        let s: Suivi = { parts: [], prochain: 0, fini: false };
        for (let k = 0; k < 20 && !s.fini; k++) s = await partie(t, "apercu", date, s);
        out.push(...s.parts);
      }
      await noter("aperçu", "propriétaire", out.length + " fichier(s) zip");
      return rep(req, { ok: true, parts: out });
    }
    return rep(req, { ok: false, erreur: "Action inconnue." }, 400);
  } catch (e) { console.error(e); return rep(req, { ok: false, erreur: String((e as Error)?.message ?? e) }, 500); }
});
