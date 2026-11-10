// =====================================================================
//  sauvegarde — copie chiffrée de toute la base (CA, Caisse, Billetterie)
//  Chaque dimanche (tâche planifiée) ou sur demande du propriétaire (CA › Admin).
//  La copie est compressée puis chiffrée (AES-256-GCM, clé tirée de la phrase
//  secrète SAUVEGARDE_PHRASE) : elle est envoyée par mail au propriétaire et
//  gardée dans le stockage privé « sauvegardes » (les 8 dernières).
//  Sans la phrase secrète, le fichier est illisible.
//  À déployer avec « Verify JWT » DÉSACTIVÉ.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2.115.0";

const SB_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SRK = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ANON = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const PHRASE = Deno.env.get("SAUVEGARDE_PHRASE") ?? "";
const ORIGINES = ["https://bojkuesat-ai.github.io", ...(Deno.env.get("BILLETS_ORIGINES") ?? "").split(",").map((s) => s.trim()).filter(Boolean)];
const db = createClient(SB_URL, SRK, { auth: { persistSession: false, autoRefreshToken: false } });
const enc = new TextEncoder();
const MAX_PJ = 7 * 1024 * 1024;

function cors(req: Request) {
  const o = req.headers.get("origin") ?? "";
  return { "Access-Control-Allow-Origin": ORIGINES.includes(o) ? o : ORIGINES[0], "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret", "Access-Control-Allow-Methods": "POST, OPTIONS", "Vary": "Origin" };
}
const rep = (req: Request, b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors(req), "Content-Type": "application/json" } });
function b64(bytes: Uint8Array) { let s = ""; for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000)); return btoa(s); }

async function gzip(d: Uint8Array) { return new Uint8Array(await new Response(new Blob([d]).stream().pipeThrough(new CompressionStream("gzip"))).arrayBuffer()); }
// Format du fichier : "BESAV1" (6 octets) | sel (16) | iv (12) | données chiffrées (gzip du JSON)
async function chiffrer(d: Uint8Array) {
  const sel = crypto.getRandomValues(new Uint8Array(16)), iv = crypto.getRandomValues(new Uint8Array(12));
  const base = await crypto.subtle.importKey("raw", enc.encode(PHRASE), "PBKDF2", false, ["deriveKey"]);
  const cle = await crypto.subtle.deriveKey({ name: "PBKDF2", salt: sel, iterations: 250000, hash: "SHA-256" }, base, { name: "AES-GCM", length: 256 }, false, ["encrypt"]);
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, cle, d));
  const out = new Uint8Array(6 + 16 + 12 + ct.length);
  out.set(enc.encode("BESAV1"), 0); out.set(sel, 6); out.set(iv, 22); out.set(ct, 34);
  return out;
}
async function proprietaires() {
  const { data } = await db.from("ca_membres").select("id,email,role").eq("role", "owner");
  return ((data ?? []) as any[]).filter((m) => m.email);
}
async function envoyerMail(corps: string, jwt?: string) {
  // send-email refuse souvent la clé publique : on essaie le jeton du propriétaire, puis la clé serveur, puis la clé publique.
  let der = "";
  for (const t of [jwt, SRK, ANON].filter(Boolean) as string[]) {
    try {
      const r = await fetch(SB_URL + "/functions/v1/send-email", { method: "POST", body: corps, headers: { "Content-Type": "application/json", "Authorization": "Bearer " + t, "apikey": ANON || SRK } });
      if (r.ok) return "";
      der = "send-email " + r.status + " " + (await r.text()).slice(0, 160);
      if (r.status !== 401 && r.status !== 403) break;
    } catch (e) { der = "send-email : " + String(e); }
  }
  return der || "envoi impossible";
}
async function sauvegarder(motif: string, jwt?: string) {
  if (PHRASE.length < 12) throw new Error("La phrase secrète SAUVEGARDE_PHRASE n'est pas réglée (12 caractères au moins) dans Supabase › Edge Functions › Secrets.");
  const { data: tables, error } = await db.rpc("sauvegarde_tables");
  if (error) throw new Error(error.message);
  const contenu: Record<string, unknown[]> = {}; let lignes = 0;
  for (const t of (tables ?? []) as string[]) {
    const l: unknown[] = [];
    for (let p = 0; p < 500; p++) {
      const { data, error: e } = await db.from(t).select("*").range(p * 1000, p * 1000 + 999);
      if (e) { contenu["__erreur_" + t] = [e.message]; break; }
      l.push(...(data ?? [])); if (!data || data.length < 1000) break;
    }
    contenu[t] = l; lignes += l.length;
  }
  // Liste des fichiers stockés (les fichiers eux-mêmes ne sont pas copiés).
  const fichiers: Record<string, unknown[]> = {};
  try { const { data: bks } = await db.storage.listBuckets(); for (const b of bks ?? []) { if (b.id === "sauvegardes") continue; const { data: f } = await db.storage.from(b.id).list("", { limit: 1000 }); fichiers[b.id] = (f ?? []).map((x: any) => x.name); } } catch (_) { /* facultatif */ }
  const quand = new Date();
  const json = enc.encode(JSON.stringify({ format: "sauvegarde-bureau-etudiant", version: 1, cree_le: quand.toISOString(), motif, lignes, tables: contenu, fichiers_stockes: fichiers }));
  const fichier = await chiffrer(await gzip(json));
  const nom = `sauvegarde-${quand.toISOString().slice(0, 16).replace(/[:T]/g, "-")}.besav`;
  const up = await db.storage.from("sauvegardes").upload(nom, fichier, { contentType: "application/octet-stream", upsert: true });
  if (up.error) throw new Error("Stockage : " + up.error.message);
  // On garde les 8 dernières.
  const { data: liste } = await db.storage.from("sauvegardes").list("", { limit: 100, sortBy: { column: "name", order: "desc" } });
  const vieux = ((liste ?? []) as any[]).map((x) => x.name).filter((n) => n.endsWith(".besav")).slice(8);
  if (vieux.length) await db.storage.from("sauvegardes").remove(vieux);
  // Copie hors de Supabase : par mail au propriétaire.
  const taille = fichier.length; let mails = 0, erreurMail = "";
  for (const o of await proprietaires()) {
    const html = `<div style="font-family:Arial,sans-serif;max-width:560px;margin:0 auto;color:#1a1a2e"><h2>💾 Sauvegarde du ${quand.toLocaleDateString("fr-BE", { timeZone: "Europe/Brussels" })}</h2>
      <p>${lignes} ligne(s) de ${Object.keys(contenu).length} table(s), chiffrées (${Math.round(taille / 1024)} Ko).</p>
      ${taille <= MAX_PJ ? "<p>Le fichier est joint : <b>gardez ce mail</b>. Ne l'ouvrez pas directement : il ne s'ouvre qu'avec votre phrase secrète, dans CA › Admin › Sauvegardes › « Lire / restaurer… ».</p>" : "<p>Le fichier est trop lourd pour le mail : il est disponible dans CA › Admin › Sauvegardes.</p>"}
      <p style="color:#999;font-size:12px">Envoi automatique — Le bureau étudiant.</p></div>`;
    const base = { to: o.email, subject: "💾 Sauvegarde du Bureau étudiant — " + quand.toISOString().slice(0, 10), from: "Sauvegarde-BE <noreply@bureauetuidant.xyz>", html };
    // send-email n'accepte que certains formats : on essaie plusieurs extensions (le contenu reste chiffré).
    let e = "trop lourd";
    if (taille <= MAX_PJ) for (const ext of [".txt", ".zip", ".csv", ".pdf"]) {
      e = await envoyerMail(JSON.stringify({ ...base, attachments: [{ filename: nom + ext, content: b64(fichier) }] }), jwt);
      if (!e || !/format de pi[eè]ce jointe/i.test(e)) break;
    }
    if (!e) mails++;
    else {
      // Pièce jointe refusée ou trop lourde : on envoie au moins l'avis (le fichier reste téléchargeable dans CA › Admin).
      const e2 = await envoyerMail(JSON.stringify({ ...base, html: html.replace(/<p>Le fichier est joint[\s\S]*?<\/p>/, "<p>Le fichier n'a pas pu être joint : téléchargez-le dans CA › Admin › Sauvegardes.</p>") }), jwt);
      if (!e2) mails++;
      if (e !== "trop lourd" || e2) erreurMail = (e !== "trop lourd" ? "pièce jointe refusée (" + e + ")" : "") + (e2 ? " avis non envoyé (" + e2 + ")" : "");
    }
  }
  await db.from("ca_rappels_envoyes").insert({ cle: "sauvegarde:" + quand.toISOString() });
  return { ok: true, nom, lignes, tables: Object.keys(contenu).length, ko: Math.round(taille / 1024), mails, erreurMail };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  try {
    const b = await req.json().catch(() => ({})) as Record<string, any>;
    if (b.action === "cron") {
      const { data: cfg } = await db.from("bil_config").select("cron_secret").eq("id", 1).maybeSingle();
      if (!cfg?.cron_secret || req.headers.get("x-cron-secret") !== cfg.cron_secret) return rep(req, { ok: false, erreur: "Accès refusé." }, 401);
      return rep(req, await sauvegarder("hebdomadaire"));
    }
    // Propriétaire connecté (avec le code s'il a activé la double authentification).
    const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: u } = await db.auth.getUser(jwt);
    if (!u?.user) return rep(req, { ok: false, erreur: "Connexion requise." }, 401);
    // ca_is_owner() tient compte de la double authentification.
    const uc = createClient(SB_URL, ANON, { global: { headers: { Authorization: "Bearer " + jwt } }, auth: { persistSession: false, autoRefreshToken: false } });
    const { data: own } = await uc.rpc("ca_is_owner");
    if (own !== true) return rep(req, { ok: false, erreur: "Réservé au propriétaire." }, 403);
    if (b.action === "maintenant") return rep(req, await sauvegarder("manuelle", jwt));
    if (b.action === "liste") {
      const { data } = await db.storage.from("sauvegardes").list("", { limit: 100, sortBy: { column: "name", order: "desc" } });
      return rep(req, { ok: true, phrase: PHRASE.length >= 12, fichiers: ((data ?? []) as any[]).filter((x) => x.name.endsWith(".besav")).map((x) => ({ nom: x.name, ko: Math.round((x.metadata?.size ?? 0) / 1024), le: x.created_at })) });
    }
    if (b.action === "fichiers") {
      // Liste de tous les fichiers stockés (justificatifs, PDF…) avec un lien de téléchargement de 30 min.
      const out: { bucket: string; chemin: string; taille: number; url: string }[] = [];
      const { data: bks } = await db.storage.listBuckets();
      for (const bk of bks ?? []) {
        if (bk.id === "sauvegardes") continue;
        const dossiers = [""]; let tours = 0;
        while (dossiers.length && tours++ < 2000) {
          const dos = dossiers.shift() as string;
          for (let off = 0; off < 100000; off += 1000) {
            const { data: l } = await db.storage.from(bk.id).list(dos, { limit: 1000, offset: off });
            for (const it of (l ?? []) as any[]) {
              const ch = (dos ? dos + "/" : "") + it.name;
              if (it.id === null || it.metadata == null) dossiers.push(ch);
              else out.push({ bucket: bk.id, chemin: ch, taille: Number(it.metadata?.size ?? 0), url: "" });
            }
            if (!l || l.length < 1000) break;
          }
        }
      }
      for (const bk of [...new Set(out.map((f) => f.bucket))]) {
        const l = out.filter((f) => f.bucket === bk);
        for (let i = 0; i < l.length; i += 200) {
          const { data } = await db.storage.from(bk).createSignedUrls(l.slice(i, i + 200).map((f) => f.chemin), 1800);
          (data ?? []).forEach((d: any, k: number) => { l[i + k].url = d?.signedUrl ?? ""; });
        }
      }
      return rep(req, { ok: true, fichiers: out.filter((f) => f.url) });
    }
    if (b.action === "lien") {
      const { data, error } = await db.storage.from("sauvegardes").createSignedUrl(String(b.nom ?? ""), 300);
      if (error) return rep(req, { ok: false, erreur: error.message }, 404);
      return rep(req, { ok: true, url: data.signedUrl });
    }
    return rep(req, { ok: false, erreur: "Action inconnue." }, 400);
  } catch (e) { console.error(e); return rep(req, { ok: false, erreur: String((e as Error)?.message ?? e) }, 500); }
});
