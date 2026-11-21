/* Edge function « diffuser » — Espace CA (21/11/2026)
   -----------------------------------------------------------------------
   Envoie un mail à une liste de personnes, DEPUIS LE SERVEUR.
   Avant, le navigateur envoyait les mails un par un (≈ 1 par seconde) : si la
   personne fermait la page ou changeait d'onglet, le reste ne partait jamais
   (5 mails sur 19 pour le budget « Concours de Noël »). Ici, la boucle tourne
   sur le serveur et continue même si la page est fermée (EdgeRuntime.waitUntil).

   POST + jeton de l'utilisateur connecté (membre actif du CA) :
     { mode: "ca" | "liste", dest?: string[], subject, html, from?, cat?, urgent?, tous?, attachments? }
     - mode "ca"    : les destinataires sont calculés ICI (membres du CA hors cooptés,
                      liste de diffusion externe), le navigateur n'a pas besoin des adresses ;
     - mode "liste" : la liste donnée (300 adresses au plus).
     - cat          : choix de notifications de chacun (onglet Notifs), appliqués ici
                      (notif_preparer_srv : coupé = rien, résumé de 18 h = mis de côté).
     - tous         : document officiel, envoyé même aux désabonnés des annonces.
     - desabo       : diffusion (onglet Mailing) : la marque {{DESABO}} du contenu est remplacée,
                      pour chaque destinataire, par son lien personnel de désabonnement.
   Chaque mail passe par « send-email » avec le jeton de la personne : mêmes limites
   (500 destinataires / heure) et même journal (mail_envois) qu'avant.
   Réponse : { total, ok, err, desabonnes, masque, sansPiece, enCours } — jamais d'adresse,
   sauf la liste des échecs pour le propriétaire (annonce urgente).

   JWT verify : OFF (contrôle fait ici). CORS limité aux sites du bureau.
*/
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
declare const EdgeRuntime: { waitUntil: (p: Promise<unknown>) => void } | undefined;

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(SB_URL, SERVICE, { auth: { persistSession: false } });
const ORIGINES = ["https://bojkuesat-ai.github.io", "https://bureauetuidant.xyz", "https://www.bureauetuidant.xyz"];
const RE_EMAIL = /^[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}$/i;
const MAX_DEST = 300;
const APP = "https://bojkuesat-ai.github.io/bureau-ca/";
async function lienDesabo(email: string): Promise<string> {
  try {
    const { data, error } = await admin.rpc("ca_jeton_desabo", { p_email: email });
    if (error || !data) return "";
    return APP + "?desabo=" + encodeURIComponent(email) + "&t=" + String(data);
  } catch (_) { return ""; }
}

function corsPour(req: Request) {
  const o = req.headers.get("origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ORIGINES.includes(o) ? o : ORIGINES[0],
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}
const norm = (e: unknown) => String(e ?? "").toLowerCase().trim();

async function desabonnes(): Promise<Set<string>> {
  const { data } = await admin.from("ca_desabonnes").select("email");
  return new Set((data || []).map((d: any) => norm(d.email)));
}

/* Même règle que destinatairesCA() de l'app : membres actifs hors cooptés et hors « hors CA »,
   plus les adresses de la liste de diffusion qui ne sont pas déjà un compte. */
async function destinatairesCA(): Promise<string[]> {
  const { data: membres } = await admin.from("ca_membres").select("email, email_alt, statut, role, hors_ca").eq("statut", "actif");
  const { data: diffusion } = await admin.from("ca_mailing").select("email");
  const set = new Set<string>();
  (membres || []).filter((m: any) => m.role !== "coopte" && m.role !== "proprietaire" && !m.hors_ca && m.email)
    .forEach((m: any) => set.add(norm(m.email)));
  const comptes = new Set<string>();
  (membres || []).forEach((m: any) => { if (m.email) comptes.add(norm(m.email)); if (m.email_alt) comptes.add(norm(m.email_alt)); });
  (diffusion || []).forEach((d: any) => { const e = norm(d.email); if (e && !comptes.has(e)) set.add(e); });
  return [...set].filter((e) => RE_EMAIL.test(e));
}

async function filtrer(cat: string, liste: string[], sujet: string, html: string, urgent: boolean): Promise<string[]> {
  if (!cat || !liste.length) return liste;
  try {
    const { data, error } = await admin.rpc("notif_preparer_srv", { p_categorie: cat, p_emails: liste, p_sujet: sujet, p_html: html, p_urgent: urgent });
    if (error || !Array.isArray(data)) return liste;
    const ok = new Set((data as string[]).map(norm));
    return liste.filter((e) => ok.has(e));
  } catch (_) { return liste; }
}

Deno.serve(async (req) => {
  const CORS = corsPour(req);
  const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Méthode non autorisée." }, 405);

  const auth = req.headers.get("Authorization") || "";
  const jeton = auth.replace(/^Bearer\s+/i, "");
  if (!jeton) return json({ error: "Connexion requise." }, 401);
  const { data: u } = await admin.auth.getUser(jeton);
  const user = u?.user;
  if (!user) return json({ error: "Session invalide." }, 401);
  const { data: moi } = await admin.from("ca_membres").select("id, role, statut").eq("id", user.id).maybeSingle();
  if (!moi || moi.statut !== "actif" || moi.role === "proprietaire") return json({ error: "Réservé aux membres actifs de l'espace CA." }, 403);

  let b: any = {};
  try { b = await req.json(); } catch { return json({ error: "Requête illisible." }, 400); }
  const subject = String(b.subject || "").slice(0, 300);
  const html = String(b.html || "");
  if (!subject || !html) return json({ error: "Sujet et contenu requis." }, 400);
  if (html.length > 300000) return json({ error: "Contenu trop long." }, 400);
  const from = b.from ? String(b.from).slice(0, 120) : "";
  const cat = b.cat ? String(b.cat).slice(0, 40) : "";
  const urgent = b.urgent === true, tous = b.tous === true, avecDesabo = b.desabo === true;
  const pieces = Array.isArray(b.attachments) ? b.attachments.slice(0, 5) : null;

  let liste: string[];
  if (b.mode === "ca") {
    if (moi.role === "coopte") return json({ error: "Réservé aux membres du CA." }, 403);
    liste = await destinatairesCA();
  } else if (b.mode === "liste") {
    liste = [...new Set((Array.isArray(b.dest) ? b.dest : []).map(norm).filter((e: string) => RE_EMAIL.test(e)))];
    if (liste.length > MAX_DEST) return json({ error: MAX_DEST + " destinataires au plus." }, 400);
  } else return json({ error: "Mode inconnu." }, 400);

  const brut = liste.length;
  if (!tous) { const bloques = await desabonnes(); liste = liste.filter((e) => !bloques.has(e)); }
  const nbDesab = brut - liste.length;
  if (!liste.length) return json({ total: 0, ok: 0, err: 0, desabonnes: nbDesab });
  const dest = await filtrer(cat, liste, subject, html, urgent);
  if (!dest.length) return json({ total: 0, ok: 0, err: 0, desabonnes: nbDesab, masque: true });

  const headers = { "Content-Type": "application/json", Authorization: auth, apikey: req.headers.get("apikey") || "" };
  const res = { total: dest.length, ok: 0, err: 0, desabonnes: nbDesab, sansPiece: false, echecs: [] as string[] };
  const envoyer = async () => {
    let avec = !!(pieces && pieces.length), okAvecPiece = 0;
    for (const to of dest) {
      let bon = false;
      let h = html;
      if (avecDesabo) {
        const u = await lienDesabo(to);
        h = h.split("{{DESABO}}").join(u ? '<p style="color:#bbb;font-size:11px;margin-top:14px">Vous recevez ce message en tant que contact du Bureau étudiant. <a href="' + u + '" style="color:#999">Se désabonner</a>.</p>' : "");
      }
      const base: any = { to, subject, html: h }; if (from) base.from = from;
      if (avec) {
        try { const r = await fetch(`${SB_URL}/functions/v1/send-email`, { method: "POST", headers, body: JSON.stringify({ ...base, attachments: pieces }) }); bon = r.ok; } catch { bon = false; }
        if (bon) okAvecPiece++;
      }
      if (!bon) {
        try { const r = await fetch(`${SB_URL}/functions/v1/send-email`, { method: "POST", headers, body: JSON.stringify(base) }); bon = r.ok; } catch { bon = false; }
        if (avec && !okAvecPiece) { avec = false; res.sansPiece = !!(pieces && pieces.length); }
      }
      if (bon) res.ok++; else { res.err++; res.echecs.push(to); }
      await new Promise((r) => setTimeout(r, 120));
    }
  };
  const tache = envoyer();
  try { EdgeRuntime?.waitUntil(tache); } catch (_) { /* hors Supabase */ }
  const fini = await Promise.race([tache.then(() => true), new Promise<boolean>((r) => setTimeout(() => r(false), 25000))]);
  const sortie: any = { total: res.total, ok: fini ? res.ok : res.total - res.err, err: res.err, desabonnes: res.desabonnes, sansPiece: res.sansPiece, enCours: !fini };
  if (moi.role === "owner") sortie.echecs = res.echecs;
  return json(sortie);
});
