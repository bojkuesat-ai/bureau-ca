// =====================================================================
//  Fonction serveur « soutien-notif »
//  Prévient Lamia (soutien psy étudiants) ou le responsable de la CES
//  (aide sociale) qu'il y a du nouveau. Le mail est NEUTRE : ni contenu,
//  ni identité, ni numéro de dossier.
//
//  Appelée depuis la page publique des étudiants, qui n'ont pas de compte :
//  à déployer avec « Verify JWT » DÉSACTIVÉ.
//  Anti-abus : la base n'autorise qu'un mail toutes les 10 minutes par
//  destinataire (fonction soutien__notif_cible), quel que soit le nombre d'appels.
//
//  Utilise les mêmes secrets Amazon SES que send-email (AWS_SES_KEY / AWS_SES_SECRET).
//  09/11/2026 : CORS limité aux sites du bureau.
// =====================================================================
import { serve } from "https://deno.land/std@0.192.0/http/server.ts";

const REGION = "eu-north-1";
const HOST = `email.${REGION}.amazonaws.com`;
const ENDPOINT = `https://${HOST}/v2/email/outbound-emails`;
const FROM = "Bureau étudiant <noreply@bureauetuidant.xyz>";
const APP = "https://bojkuesat-ai.github.io/bureau-ca/";

const ORIGINES = ["https://bojkuesat-ai.github.io", "https://bureauetuidant.xyz", "https://www.bureauetuidant.xyz"];
function corsPour(req: Request) {
  const o = req.headers.get("origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ORIGINES.includes(o) ? o : ORIGINES[0],
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Vary": "Origin",
  };
}

const MESSAGES: Record<string, { subject: string; titre: string; onglet: string }> = {
  psy_etu: { subject: "Soutien psychologique étudiants — nouveau message", titre: "Soutien psychologique — étudiants", onglet: "Soutien psy — étudiants" },
  ces:     { subject: "Aide sociale (CES) — nouvelle activité",            titre: "Aide sociale — CES",                onglet: "Soutien social — CES" },
};

const enc = new TextEncoder();
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
const sha256 = async (m: string) => hex(await crypto.subtle.digest("SHA-256", enc.encode(m)));
async function hmac(key: ArrayBuffer | Uint8Array, msg: string) {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return await crypto.subtle.sign("HMAC", k, enc.encode(msg));
}

async function envoyerSES(to: string, subject: string, html: string) {
  const KEY = Deno.env.get("AWS_SES_KEY")!;
  const SECRET = Deno.env.get("AWS_SES_SECRET")!;
  const payload = JSON.stringify({
    FromEmailAddress: FROM,
    Destination: { ToAddresses: [to] },
    Content: { Simple: { Subject: { Data: subject, Charset: "UTF-8" }, Body: { Html: { Data: html, Charset: "UTF-8" } } } },
  });
  const amzDate = new Date().toISOString().replace(/[:-]|\.\d{3}/g, "");
  const dateStamp = amzDate.slice(0, 8);
  const canonicalHeaders = `content-type:application/json\nhost:${HOST}\nx-amz-date:${amzDate}\n`;
  const signedHeaders = "content-type;host;x-amz-date";
  const canonicalRequest = `POST\n/v2/email/outbound-emails\n\n${canonicalHeaders}\n${signedHeaders}\n${await sha256(payload)}`;
  const scope = `${dateStamp}/${REGION}/ses/aws4_request`;
  const stringToSign = `AWS4-HMAC-SHA256\n${amzDate}\n${scope}\n${await sha256(canonicalRequest)}`;
  const kDate = await hmac(enc.encode("AWS4" + SECRET), dateStamp);
  const kRegion = await hmac(kDate, REGION);
  const kService = await hmac(kRegion, "ses");
  const kSigning = await hmac(kService, "aws4_request");
  const signature = hex(await hmac(kSigning, stringToSign));
  const authorization = `AWS4-HMAC-SHA256 Credential=${KEY}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;
  const r = await fetch(ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Amz-Date": amzDate, "Authorization": authorization },
    body: payload,
  });
  return r.ok;
}

serve(async (req) => {
  const CORS = corsPour(req);
  const json = (o: unknown, status = 200) =>
    new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const { type } = await req.json().catch(() => ({}));
    const m = MESSAGES[String(type)];
    if (!m) return json({ error: "type inconnu" }, 400);

    const URL_ = Deno.env.get("SUPABASE_URL")!;
    const SKEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const r = await fetch(`${URL_}/rest/v1/rpc/soutien__notif_cible`, {
      method: "POST",
      headers: { apikey: SKEY, Authorization: `Bearer ${SKEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ p_type: type }),
    });
    if (!r.ok) return json({ error: "base" }, 500);
    const email = await r.json();
    if (!email || typeof email !== "string") return json({ ok: true, envoye: false }); // limite de 10 min ou personne

    const html = '<div style="font-family:Arial,Helvetica,sans-serif;max-width:520px;margin:0 auto;color:#1a1a2e">'
      + `<h2 style="margin:0 0 10px;color:#241c46">${m.titre}</h2>`
      + "<p>Il y a du nouveau dans votre espace.</p>"
      + `<p>Ouvrez l'application, onglet <b>${m.onglet}</b>, pour le consulter.</p>`
      + `<p><a href="${APP}" style="background:#241c46;color:#fff;padding:11px 20px;border-radius:8px;text-decoration:none;font-weight:bold;display:inline-block">Ouvrir l'application</a></p>`
      + '<p style="font-size:12px;color:#666">Pour protéger les étudiant·es, ce mail ne contient ni identité ni contenu.</p>'
      + '<p style="color:#999;font-size:12px;margin-top:18px">Envoi automatique — merci de ne pas répondre.</p></div>';
    const ok = await envoyerSES(email, m.subject, html);
    return json({ ok, envoye: ok });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
