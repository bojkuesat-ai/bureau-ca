// =====================================================================
//  notifications — notifications sur le téléphone (Web Push) du Bureau étudiant
//  À déployer avec « Verify JWT » DÉSACTIVÉ (la fonction vérifie elle-même).
//  Actions :
//   - cle      : clé publique (créée automatiquement au premier appel)
//   - test     : envoie une notification d'essai à ses propres appareils (membre connecté)
//   - envoyer  : appelée par la base (déclencheurs), protégée par le secret interne
//  Chiffrement RFC 8291 (aes128gcm) et signature VAPID (RFC 8292), sans librairie.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2.115.0";

const SB_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SRK = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ORIGINES = ["https://bojkuesat-ai.github.io", ...(Deno.env.get("BILLETS_ORIGINES") ?? "").split(",").map((s) => s.trim()).filter(Boolean)];
const db = createClient(SB_URL, SRK, { auth: { persistSession: false, autoRefreshToken: false } });
const enc = new TextEncoder();

function cors(req: Request) {
  const o = req.headers.get("origin") ?? "";
  return { "Access-Control-Allow-Origin": ORIGINES.includes(o) ? o : ORIGINES[0], "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret", "Access-Control-Allow-Methods": "POST, OPTIONS", "Vary": "Origin" };
}
const rep = (req: Request, b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors(req), "Content-Type": "application/json" } });

// ---------- base64url ----------
const b64u = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const deb64u = (s: string) => { s = s.replace(/-/g, "+").replace(/_/g, "/"); while (s.length % 4) s += "="; return Uint8Array.from(atob(s), (c) => c.charCodeAt(0)); };
const concat = (...l: Uint8Array[]) => { const o = new Uint8Array(l.reduce((a, b) => a + b.length, 0)); let p = 0; for (const x of l) { o.set(x, p); p += x.length; } return o; };
async function hmac(cle: Uint8Array, data: Uint8Array) { const k = await crypto.subtle.importKey("raw", cle, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]); return new Uint8Array(await crypto.subtle.sign("HMAC", k, data)); }

// ---------- clés VAPID (stockées dans la base, jamais visibles du navigateur) ----------
type Vapid = { pub: string; jwk: JsonWebKey };
async function vapid(): Promise<Vapid> {
  const { data } = await db.from("push_config").select("*").eq("id", 1).maybeSingle();
  if (data?.vapid_public && data?.vapid_private) return { pub: data.vapid_public, jwk: JSON.parse(data.vapid_private) };
  const kp = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const pub = b64u(new Uint8Array(await crypto.subtle.exportKey("raw", kp.publicKey)));
  const jwk = await crypto.subtle.exportKey("jwk", kp.privateKey);
  await db.from("push_config").upsert({ id: 1, vapid_public: pub, vapid_private: JSON.stringify(jwk) });
  const { data: relu } = await db.from("push_config").select("*").eq("id", 1).maybeSingle();   // en cas d'appels simultanés
  return { pub: relu.vapid_public, jwk: JSON.parse(relu.vapid_private) };
}
async function jwtVapid(v: Vapid, aud: string) {
  const h = b64u(enc.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const p = b64u(enc.encode(JSON.stringify({ aud, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: "mailto:noreply@bureauetuidant.xyz" })));
  const k = await crypto.subtle.importKey("jwk", v.jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, k, enc.encode(h + "." + p)));
  return h + "." + p + "." + b64u(sig);
}
// ---------- chiffrement du message (RFC 8291) ----------
export async function chiffrer(texte: string, p256dh: string, auth: string, sel?: Uint8Array, eph?: CryptoKeyPair) {
  const uaPub = deb64u(p256dh), secret = deb64u(auth);
  const as = eph ?? await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]) as CryptoKeyPair;
  const asPub = new Uint8Array(await crypto.subtle.exportKey("raw", as.publicKey));
  const uaKey = await crypto.subtle.importKey("raw", uaPub, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const ecdh = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: uaKey }, as.privateKey, 256));
  const prkKey = await hmac(secret, ecdh);
  const ikm = await hmac(prkKey, concat(enc.encode("WebPush: info\0"), uaPub, asPub, new Uint8Array([1])));
  const salt = sel ?? crypto.getRandomValues(new Uint8Array(16));
  const prk = await hmac(salt, ikm);
  const cek = (await hmac(prk, concat(enc.encode("Content-Encoding: aes128gcm\0"), new Uint8Array([1])))).slice(0, 16);
  const nonce = (await hmac(prk, concat(enc.encode("Content-Encoding: nonce\0"), new Uint8Array([1])))).slice(0, 12);
  const k = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, k, concat(enc.encode(texte), new Uint8Array([2]))));
  const rs = new Uint8Array([0, 0, 16, 0]);   // 4096
  return concat(salt, rs, new Uint8Array([asPub.length]), asPub, ct);
}
async function pousser(v: Vapid, ab: Record<string, string>, charge: unknown) {
  const corps = await chiffrer(JSON.stringify(charge), ab.p256dh, ab.auth);
  const u = new URL(ab.endpoint);
  const r = await fetch(ab.endpoint, { method: "POST", body: corps, headers: {
    "Content-Encoding": "aes128gcm", "Content-Type": "application/octet-stream", "TTL": "86400", "Urgency": "normal",
    "Authorization": `vapid t=${await jwtVapid(v, u.origin)}, k=${v.pub}` } });
  return r.status;
}
async function envoyerA(membres: string[], charge: Record<string, unknown>) {
  if (!membres.length) return { envoyes: 0, retires: 0 };
  const { data } = await db.from("push_abonnements").select("*").in("membre_id", membres);
  const v = await vapid();
  let envoyes = 0, retires = 0;
  for (const ab of (data ?? []) as Record<string, string>[]) {
    try {
      const s = await pousser(v, ab, charge);
      if (s === 404 || s === 410) { await db.from("push_abonnements").delete().eq("id", ab.id); retires++; }
      else if (s >= 200 && s < 300) { envoyes++; await db.from("push_abonnements").update({ dernier_ok: new Date().toISOString() }).eq("id", ab.id); }
      else console.error("push", s, ab.endpoint.slice(0, 60));
    } catch (e) { console.error("push", e); }
  }
  return { envoyes, retires };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  try {
    const b = await req.json().catch(() => ({})) as Record<string, any>;
    if (b.action === "cle") return rep(req, { ok: true, cle: (await vapid()).pub });
    if (b.action === "envoyer") {
      const { data: cfg } = await db.from("bil_config").select("cron_secret").eq("id", 1).maybeSingle();
      if (!cfg?.cron_secret || req.headers.get("x-cron-secret") !== cfg.cron_secret) return rep(req, { ok: false, erreur: "Accès refusé." }, 401);
      const r = await envoyerA((b.membres ?? []).map(String), { titre: String(b.titre ?? "").slice(0, 120), corps: String(b.corps ?? "").slice(0, 300), url: String(b.url ?? "https://bojkuesat-ai.github.io/bureau-ca/"), tag: String(b.tag ?? "") });
      return rep(req, { ok: true, ...r });
    }
    if (b.action === "test") {
      const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
      const { data } = await db.auth.getUser(jwt);
      if (!data?.user) return rep(req, { ok: false, erreur: "Connexion requise." }, 401);
      const r = await envoyerA([data.user.id], { titre: "🔔 Notifications activées", corps: "Vous recevrez ici les alertes du Bureau étudiant.", url: "https://bojkuesat-ai.github.io/bureau-ca/", tag: "test" });
      return rep(req, { ok: r.envoyes > 0, ...r, erreur: r.envoyes ? "" : "Aucun appareil n'a accepté la notification." });
    }
    return rep(req, { ok: false, erreur: "Action inconnue." }, 400);
  } catch (e) { console.error(e); return rep(req, { ok: false, erreur: String((e as Error)?.message ?? e) }, 500); }
});
