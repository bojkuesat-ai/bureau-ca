import { serve } from "https://deno.land/std@0.192.0/http/server.ts";
import { createClient } from "npm:@supabase/supabase-js@2.115.0";

/* ==========================================================================
   PROTECTION CONTRE LE SPAM (23.10.2026, durcie le 09.11.2026)
   La clé publique est visible dans le code des apps : elle ne suffit pas
   pour envoyer. Trois niveaux :
   - SERVEUR : clé secrète Supabase, ou code secret interne de la base
     (en-tête x-cron-secret) → aucune limite ;
   - MEMBRE : membre actif du CA, compte Caisse approuvé, ou responsable de
     l'app QR (compte Firebase avec mot de passe, projet be-events-13c5c)
     → 500 destinataires par heure (le propriétaire : sans limite) ;
   - ANONYME : tout le reste → UNIQUEMENT les gabarits serveur (contenu fixé),
     1 destinataire par appel, 30 par heure et par adresse IP (un wifi partagé
     sert plusieurs étudiants), 3 par heure vers une même adresse (30 pour les
     alertes à l'équipe), 2000 par heure au total. Plus de HTML libre dès que
     ANON_HTML_TOLERE passe à false.
   À déployer avec « Verify JWT » DÉSACTIVÉ : le contrôle est fait ici (le contrôle
   automatique refusait la clé secrète des autres fonctions et les jetons Firebase).
   Chaque envoi est noté dans mail_envois (sans le contenu) ; une rafale de
   refus déclenche une alerte au propriétaire.
   ========================================================================== */
const SB_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SRK = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const sbAdmin = createClient(SB_URL, SRK, { auth: { persistSession: false, autoRefreshToken: false } });
const LIMITE_MEMBRE_H = 500, LIMITE_ANON_IP_H = 30, LIMITE_ANON_DEST_H = 3, LIMITE_MODELES_TOTAL_H = 2000, LIMITE_ANON_HTML_TOTAL_H = 300;
/* TRANSITION terminée le 10/11/2026 (app QR v201 en ligne : elle envoie le jeton
   Firebase de ses responsables). Plus de HTML libre avec la seule clé publique.
   Remettre à true uniquement en cas d'urgence (anciennes règles : adresses connues). */
const ANON_HTML_TOLERE = false;
/* Gabarits adressés à l'équipe elle-même : 30 par heure vers une même adresse. */
const LIMITE_ALERTE_DEST_H = 30;
const MODELES_EQUIPE = new Set(["inscription_alerte_equipe"]);
/* Sites autorisés à appeler depuis un navigateur (CORS). Un script hors navigateur
   n'est pas arrêté par CORS : c'est le contrôle de l'appelant ci-dessous qui compte. */
const ORIGINES = ["https://bojkuesat-ai.github.io", "https://bureauetuidant.xyz", "https://www.bureauetuidant.xyz",
  ...(Deno.env.get("MAIL_ORIGINES") ?? "").split(",").map((s) => s.trim()).filter(Boolean)];
/* App QR (qr-verification) : ses responsables sont connectés via Firebase. */
const FIREBASE_PROJET = Deno.env.get("FIREBASE_PROJET") || "be-events-13c5c";
const FIREBASE_JWKS = "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com";
let jwksCache: { cles: JsonWebKey[]; t: number } = { cles: [], t: 0 };
const b64uDecode = (s: string) => { s = s.replace(/-/g, "+").replace(/_/g, "/"); while (s.length % 4) s += "="; return Uint8Array.from(atob(s), (c) => c.charCodeAt(0)); };
async function clesFirebase(): Promise<JsonWebKey[]> {
  if (jwksCache.cles.length && Date.now() - jwksCache.t < 3600000) return jwksCache.cles;
  try { const r = await fetch(FIREBASE_JWKS); const j = await r.json(); if (Array.isArray(j?.keys)) jwksCache = { cles: j.keys, t: Date.now() }; } catch (_) { /* on garde l'ancien cache */ }
  return jwksCache.cles;
}
/* Vérifie un jeton d'identité Firebase (RS256) : signature, projet, expiration,
   et compte avec mot de passe (les comptes anonymes de la page d'inscription
   publique ne comptent pas). Renvoie l'identifiant du compte, ou null. */
async function verifierFirebase(jeton: string): Promise<string | null> {
  try {
    const [h, p, sig] = jeton.split(".");
    const head = JSON.parse(new TextDecoder().decode(b64uDecode(h)));
    const corps = JSON.parse(new TextDecoder().decode(b64uDecode(p)));
    if (head.alg !== "RS256" || !head.kid) return null;
    const now = Math.floor(Date.now() / 1000);
    if (corps.iss !== "https://securetoken.google.com/" + FIREBASE_PROJET || corps.aud !== FIREBASE_PROJET) return null;
    if (typeof corps.exp !== "number" || corps.exp < now || (typeof corps.iat === "number" && corps.iat > now + 300)) return null;
    if (corps.firebase?.sign_in_provider !== "password" || !corps.email || !corps.sub) return null;
    const jwk = (await clesFirebase()).find((k: any) => k.kid === head.kid);
    if (!jwk) return null;
    const cle = await crypto.subtle.importKey("jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
    const ok = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", cle, b64uDecode(sig), new TextEncoder().encode(h + "." + p));
    return ok ? "fb:" + String(corps.sub).slice(0, 60) : null;
  } catch (_) { return null; }
}
const shaCourt = async (s: string) => { const b = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)); return [...new Uint8Array(b)].slice(0, 12).map((x) => x.toString(16).padStart(2, "0")).join(""); };
const NOM_BUREAU = /(\bBE\b|-BE\b|Bureau|Délégation|Delegation|Trésorerie|Tresorerie|Caisse|caisse|Sécurité|Securite|Billetterie|Salle|Présidence|Presidence|remboursement|Sauvegarde|\bCA\b)/i;
let secretCache = { v: "", t: 0 };
async function secretInterne(): Promise<string> {
  if (secretCache.v && Date.now() - secretCache.t < 300000) return secretCache.v;
  try { const { data } = await sbAdmin.from("bil_config").select("cron_secret").eq("id", 1).maybeSingle(); secretCache = { v: data?.cron_secret ?? "", t: Date.now() }; } catch (_) { /* */ }
  return secretCache.v;
}
type Acces = { niveau: "serveur" | "membre" | "proprio" | "anonyme"; uid: string | null };
async function quiAppelle(req: Request): Promise<Acces> {
  const jeton = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  const apikey = (req.headers.get("apikey") ?? "").trim();
  if (SRK && (jeton === SRK || apikey === SRK)) return { niveau: "serveur", uid: null };
  const sec = req.headers.get("x-cron-secret") ?? "";
  if (sec && sec === await secretInterne()) return { niveau: "serveur", uid: null };
  if (jeton && jeton.split(".").length === 3) {
    try {
      const { data } = await sbAdmin.auth.getUser(jeton);
      const u = data?.user;
      if (u) {
        const { data: m } = await sbAdmin.from("ca_membres").select("role,statut").eq("id", u.id).maybeSingle();
        if (m?.role === "owner") return { niveau: "proprio", uid: u.id };
        if (m && (m.statut ?? "actif") === "actif") return { niveau: "membre", uid: u.id };
        const { data: p } = await sbAdmin.from("profiles").select("*").eq("id", u.id).maybeSingle();
        if (p && (p.approved === true || p.role === "tresorier" || p.role === "owner")) return { niveau: "membre", uid: u.id };
        return { niveau: "anonyme", uid: u.id };
      }
    } catch (_) { /* jeton invalide → on essaie Firebase */ }
    const fb = await verifierFirebase(jeton);
    if (fb) return { niveau: "membre", uid: fb };
  }
  return { niveau: "anonyme", uid: null };
}
function ipDe(req: Request) {
  return (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || req.headers.get("cf-connecting-ip") || "?";
}
async function compter(filtre: Record<string, string>): Promise<number> {
  let q = sbAdmin.from("mail_envois").select("nb").gte("le", new Date(Date.now() - 3600000).toISOString()).is("refus", null);
  for (const [k, v] of Object.entries(filtre)) q = q.eq(k, v);
  const { data } = await q.limit(5000);
  return ((data ?? []) as { nb: number }[]).reduce((a, r) => a + (r.nb || 0), 0);
}
async function noter(l: Record<string, unknown>) {
  try { await sbAdmin.from("mail_envois").insert(l); } catch (_) { /* */ }
  if (l.refus) { try { await sbAdmin.rpc("mail_surveiller"); } catch (_) { /* */ } }
}
/* Renvoie un message d'erreur si l'envoi est refusé, sinon "". */
async function controler(req: Request, acces: Acces, dest: string[], modele: string, from: string): Promise<{ refus: string; from: string }> {
  if (acces.niveau === "serveur" || acces.niveau === "proprio") return { refus: "", from };
  const nb = dest.length;
  if (acces.niveau === "membre") {
    if (await compter({ compte: acces.uid as string }) + nb > LIMITE_MEMBRE_H) return { refus: "Limite atteinte : " + LIMITE_MEMBRE_H + " destinataires par heure. Réessayez plus tard.", from };
    return { refus: "", from };
  }
  const ip = ipDe(req);
  if (await compter({ ip, niveau: "anonyme" }) + nb > LIMITE_ANON_IP_H) return { refus: "Trop d'envois depuis cette connexion. Réessayez plus tard.", from };
  if (!modele) {
    if (!ANON_HTML_TOLERE) return { refus: "Envoi refusé : connectez-vous pour envoyer un mail.", from };
    if (await compter({ niveau: "anonyme" }) + nb > LIMITE_ANON_HTML_TOTAL_H) return { refus: "Envois temporairement suspendus. Réessayez plus tard.", from };
    const { data: connus } = await sbAdmin.rpc("mail_dest_connus", { p: dest.map((d) => String(d).toLowerCase().trim()) });
    if (Number(connus ?? 0) < nb) return { refus: "Envoi refusé : connectez-vous pour écrire à cette adresse.", from };
    const nomH = from.includes("<") ? from.split("<")[0].trim().replace(/^"|"$/g, "") : "";
    if (nomH && !NOM_BUREAU.test(nomH)) from = FROM_DEFAULT;
    return { refus: "", from };
  }
  // ANONYME + gabarit : un destinataire à la fois.
  if (nb !== 1) return { refus: "Un seul destinataire par envoi.", from };
  /* Alerte à l'équipe : l'adresse est réglée par la commission (souvent hors comptes) ;
     elle reçoit une alerte par inscription, d'où une limite plus large. */
  const limDest = MODELES_EQUIPE.has(modele) ? LIMITE_ALERTE_DEST_H : LIMITE_ANON_DEST_H;
  if (await compter({ niveau: "anonyme", dest_hash: await shaCourt(dest[0].toLowerCase().trim()) }) + nb > limDest) {
    return { refus: "Cette adresse a déjà reçu plusieurs mails récemment. Réessayez plus tard.", from };
  }
  if (await compter({ niveau: "anonyme", modele }) + nb > LIMITE_MODELES_TOTAL_H) return { refus: "Envois temporairement suspendus. Réessayez plus tard.", from };
  const nom = from.includes("<") ? from.split("<")[0].trim().replace(/^"|"$/g, "") : "";
  if (nom && !NOM_BUREAU.test(nom)) from = FROM_DEFAULT;
  return { refus: "", from };
}

const REGION = "eu-north-1";
const HOST = `email.${REGION}.amazonaws.com`;
const ENDPOINT = `https://${HOST}/v2/email/outbound-emails`;
const FROM_DEFAULT = "Bureau étudiant <noreply@bureauetuidant.xyz>";
const FROM_DOMAINE = "bureauetuidant.xyz";
const REPLY_DEFAUT = "esat.bojku@ulb.be";

/* 13/11/2026 — Passation : le propriétaire « retiré » (ca_membres.role = 'proprietaire') ne
   reçoit plus AUCUN mail du CA ni de la Caisse, quel que soit l'expéditeur (app, base, autre
   fonction). Exceptions : les mails de licence (expéditeur « Licence-BE ») et l'alerte
   « 🔐 Nouvelle connexion » sur son propre compte. Les réponses (Reply-To par défaut, qui
   était son adresse) vont alors à l'Admin. */
let retiresCache: { adresses: Set<string>; reply: string; t: number } = { adresses: new Set(), reply: "", t: 0 };
async function retires() {
  if (retiresCache.t && Date.now() - retiresCache.t < 120000) return retiresCache;
  const adresses = new Set<string>(); let reply = "";
  try {
    const { data: ms } = await sbAdmin.from("ca_membres").select("id,email,email_alt").eq("role", "proprietaire");
    for (const m of (ms ?? []) as any[]) {
      [m.email, m.email_alt].forEach((e: unknown) => { if (e) adresses.add(String(e).toLowerCase().trim()); });
      try { const { data: p } = await sbAdmin.from("profiles").select("email").eq("id", m.id).maybeSingle(); if (p?.email) adresses.add(String(p.email).toLowerCase().trim()); } catch (_) { /* */ }
      try { const { data: u } = await sbAdmin.auth.admin.getUserById(m.id); if (u?.user?.email) adresses.add(u.user.email.toLowerCase().trim()); } catch (_) { /* */ }
    }
    if (adresses.size) {
      adresses.add(REPLY_DEFAUT.toLowerCase());
      const { data: a } = await sbAdmin.from("ca_membres").select("email").eq("admin", true).eq("statut", "actif").neq("role", "proprietaire").order("created_at").limit(1);
      reply = String((a as any[])?.[0]?.email ?? "");
    }
    retiresCache = { adresses, reply, t: Date.now() };
  } catch (_) { /* on garde l'ancien cache */ }
  return retiresCache;
}

const EXPEDITEUR_DELEGATION =
  "Délégation étudiante de la Faculté de Droit et de Criminologie <noreply@bureauetuidant.xyz>";

function corsPour(req: Request) {
  const o = req.headers.get("origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ORIGINES.includes(o) ? o : ORIGINES[0],
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
    "Vary": "Origin",
  };
}

/* ==========================================================================
   GABARITS SERVEUR
   L'appelant n'envoie qu'un nom de modele et des donnees ; le HTML est
   construit ici. Un appel malveillant ne peut donc produire qu'un message
   legitime, ce qui rend l'abus sans interet.
   L'ancien format (html libre) reste accepte : rien ne casse. Il passe
   toutefois par nettoyerHtml() ci-dessous.
   ========================================================================== */

const esc = (x: unknown) =>
  String(x ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");

/* Sites du bureau. Un lien vers autre chose ne sera pas cliquable. */
const HOTES_OK = [
  "bojkuesat-ai.github.io",
  "bureauetuidant.xyz",
  "www.bureauetuidant.xyz",
  "mlgzdfyqjhvyubrywuim.supabase.co",
];

/* Un lien est accepte s'il pointe vers un site du bureau, ou s'il est
   relatif, ou s'il s'agit d'un mailto/tel. Les formes tordues servant a
   contourner le controle sont refusees d'office. */
function lienOk(u: unknown): boolean {
  let s = String(u ?? "").trim();
  if (!s) return true;
  s = s.replace(/&amp;/gi, "&");                  // seule entite admise (liens signes Supabase)
  if (/[\x00-\x20\x7f]/.test(s)) return false;    // caractere de controle : evasion
  if (/&#|&[a-zA-Z]{2,8};/.test(s)) return false; // entite encodee : evasion
  if (/\\/.test(s)) return false;                 // antislash : evasion
  if (/^(mailto|tel):[^\s<>"']+$/i.test(s)) return true;
  if (/^[a-z][a-z0-9+.-]*:/i.test(s)) {
    try {
      const url = new URL(s);
      if (url.protocol !== "https:" && url.protocol !== "http:") return false;
      return HOTES_OK.some((h) => url.hostname.toLowerCase() === h);
    } catch (_) {
      return false;
    }
  }
  return true;                                    // relatif ou ancre
}

/* Guillemets desequilibres = balise construite pour tromper le decoupage. */
function attrsSuspects(a: string): boolean {
  const g = (a.match(/"/g) || []).length;
  const ap = (a.match(/'/g) || []).length;
  return (g % 2 !== 0) || (ap % 2 !== 0);
}

/* Un lien de confirmation ne peut pointer que vers un site du bureau. */
function lienSur(u: unknown): string {
  const s = String(u ?? "");
  try {
    const url = new URL(s);
    const hotesOk = ["bojkuesat-ai.github.io", "bureauetuidant.xyz", "www.bureauetuidant.xyz"];
    if (url.protocol === "https:" && hotesOk.some((h) => url.hostname === h)) return url.href;
  } catch (_) { /* lien invalide */ }
  return "";
}

/* ==========================================================================
   NETTOYAGE DU HTML LIBRE
   Applique UNIQUEMENT au format {to, subject, html}. Les gabarits ci-dessus
   sont construits ici, ils n'ont rien a nettoyer.
   Principe : on ne supprime jamais de texte. On retire ce qui peut agir
   (script, evenement, image externe) et on rend non cliquables les liens qui
   ne pointent pas vers un site du bureau, en affichant leur adresse en clair.
   Un mail de hameconnage perd ainsi son clic ; un mail legitime ne perd rien.
   ========================================================================== */
function nettoyerHtml(src: unknown, cidsOk?: Set<string>): { html: string; retires: string[] } {
  let html = String(src ?? "");
  const retires: string[] = [];
  const cids = cidsOk ?? new Set<string>();

  html = html.replace(
    /<(script|style|iframe|object|embed|form|link|meta|base|svg|applet)\b[\s\S]*?<\/\1\s*>/gi,
    () => { retires.push("bloc actif"); return ""; },
  );
  html = html.replace(
    /<\/?(script|style|iframe|object|embed|form|link|meta|base|svg|applet)\b[^>]*>/gi,
    () => { retires.push("balise active"); return ""; },
  );
  html = html.replace(
    /\son[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/gi,
    () => { retires.push("attribut évènement"); return ""; },
  );

  html = html.replace(/<a\b([^>]*)>/gi, (tag: string, attrs: string) => {
    if (attrsSuspects(attrs)) { retires.push("balise <a> malformée"); return "<a>"; }
    const m = attrs.match(/\shref\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))/i);
    if (!m) return tag;
    const url = (m[2] ?? m[3] ?? m[4] ?? "").trim();
    if (lienOk(url)) return tag;
    retires.push(url);
    return "<a" + attrs.replace(/\shref\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/i, "") + ">";
  });

  html = html.replace(/<img\b([^>]*)>/gi, (tag: string, attrs: string) => {
    if (attrsSuspects(attrs)) { retires.push("balise <img> malformée"); return ""; }
    const m = attrs.match(/\ssrc\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))/i);
    const url = m ? (m[2] ?? m[3] ?? m[4] ?? "").trim() : "";
    /* cid: = image voyageant DANS le message. On n'accepte que celles reellement
       jointes a cet envoi : une reference inventee serait retiree comme le reste. */
    const cidM = /^cid:(.+)$/i.exec(url);
    if (cidM && cids.has(cidM[1].trim())) return tag;
    if (!m || lienOk(url)) return tag;
    retires.push(url);
    return "";
  });

  if (retires.length) {
    const liens = [...new Set(retires.filter((x) => /^[a-z]+:/i.test(x)))];
    html += '<div style="margin-top:18px;padding:10px 12px;background:#fff6f6;'
      + 'border:1px solid #e8c9c9;border-radius:8px;font-size:12.5px;color:#8a3b3b">'
      + "<b>Contenu neutralisé par sécurité.</b>"
      + (liens.length
        ? "<br>Adresse(s) rendue(s) non cliquable(s) : " + liens.map((l) => esc(l)).join(", ")
        : "")
      + "</div>";
  }
  return { html, retires };
}

function pieds() {
  return '<hr style="border:none;border-top:1px solid #eee;margin:18px 0">'
    + '<p style="margin:0;text-align:center;font-size:12px;color:#888;letter-spacing:.06em;text-transform:uppercase">Université libre de Bruxelles</p>'
    + '<p style="margin:2px 0 8px;text-align:center;font-size:13px;color:#555">Faculté de Droit et de Criminologie</p>'
    + '<p style="margin:0;text-align:center;font-size:14px;color:#333"><b>Délégation étudiante de la Faculté de Droit et de Criminologie</b></p>'
    + '<p style="margin:6px 0 0;text-align:center;font-size:12px;color:#999">Ceci est un envoi automatique — merci de ne pas répondre à ce message.</p>';
}

const enveloppe = (contenu: string) =>
  '<div style="font-family:Arial,Helvetica,sans-serif;max-width:520px;margin:0 auto;color:#1a1a1a">'
  + contenu + "</div>";

type Sortie = { subject: string; html: string; from?: string };

const GABARITS: Record<string, (d: Record<string, unknown>) => Sortie> = {

  /* 1. Accuse de reception envoye a la personne qui s'inscrit */
  inscription_recue: (d) => ({
    subject: "Inscription bien reçue — " + String(d.evenement ?? ""),
    from: EXPEDITEUR_DELEGATION,
    html: enveloppe(
      '<h2 style="margin:0 0 10px">Inscription enregistrée</h2>'
      + "<p>Bonjour " + esc(d.nom) + ",</p>"
      + "<p>Votre inscription à <b>" + esc(d.evenement) + "</b> a bien été reçue.</p>"
      + "<p>Votre inscription va être <b>vérifiée par l'équipe</b> (carte étudiante et matricule). Vous recevrez ensuite votre billet QR par e-mail.</p>"
      + '<p style="margin-top:8px">Rappel : cette invitation est <b>strictement personnelle</b> et ne vaut que pour une personne.</p>'
      + pieds(),
    ),
  }),

  /* 2. Demande de confirmation par lien */
  inscription_confirmer: (d) => {
    const lien = lienSur(d.lien);
    return {
      subject: "Confirme ton inscription — " + String(d.evenement ?? ""),
      from: EXPEDITEUR_DELEGATION,
      html: enveloppe(
        '<h2 style="margin:0 0 10px">Confirme ton inscription</h2>'
        + "<p>Bonjour " + esc(d.nom) + ",</p>"
        + "<p>Tu as demandé à t'inscrire à <b>" + esc(d.evenement) + "</b>. Pour <b>valider ton inscription</b>, clique sur le bouton ci-dessous :</p>"
        + (lien
          ? '<p style="text-align:center;margin:24px 0"><a href="' + esc(lien) + '" style="display:inline-block;background:#d8b45a;color:#241100;text-decoration:none;padding:14px 28px;border-radius:10px;font-weight:bold">Confirmer mon inscription</a></p>'
            + '<p style="font-size:13px;color:#555">Si le bouton ne fonctionne pas, copie-colle ce lien dans ton navigateur :<br><a href="' + esc(lien) + '">' + esc(lien) + "</a></p>"
          : '<p style="color:#a33">Lien de confirmation indisponible — contacte l\'équipe.</p>')
        + "<p>Après confirmation, l'équipe vérifiera ta <b>carte étudiante</b>, puis tu recevras ton <b>billet QR</b> par e-mail.</p>"
        + '<p style="font-size:13px;color:#555">Tu n\'es pas à l\'origine de cette demande ? Ignore simplement cet e-mail.</p>'
        + pieds(),
      ),
    };
  },

  /* 3. Alerte a l'equipe : une inscription vient d'arriver */
  inscription_alerte_equipe: (d) => {
    const roleLbl: Record<string, string> = {
      etudiant: "Étudiant·e", academique: "Corps académique", scientifique: "Corps scientifique",
      patgs: "Personnel", doyen: "Doyen·ne", parrain: "Parrain/Marraine",
      filleul: "Filleul·e", alumni: "Alumni",
    };
    const statuts: Record<string, string> = {
      acarte: "carte étudiante à vérifier",
      apayer: "preuve de paiement à vérifier",
    };
    const role = String(d.role ?? "");
    const statut = statuts[String(d.statut ?? "")] ?? "inscription enregistrée";
    const lignes = "<li>Nom : <b>" + esc(d.nom) + "</b></li>"
      + "<li>E-mail : " + esc(d.email) + "</li>"
      + (role ? "<li>Type : " + esc(roleLbl[role] ?? role) + "</li>" : "")
      + (d.section ? "<li>Section : " + esc(d.section) + "</li>" : "")
      + (d.matricule ? "<li>Matricule : " + esc(d.matricule) + "</li>" : "")
      + "<li>À faire : <b>" + esc(statut) + "</b></li>";
    return {
      subject: "Nouvelle inscription — " + String(d.evenement ?? ""),
      from: EXPEDITEUR_DELEGATION,
      html: enveloppe(
        '<h2 style="margin:0 0 10px">Nouvelle inscription — ' + esc(d.evenement) + "</h2>"
        + '<ul style="line-height:1.8">' + lignes + "</ul>"
        + '<p style="font-size:13px;color:#555">Connecte-toi à l\'app (onglet « Inscriptions en ligne ») pour vérifier et valider.</p>',
      ),
    };
  },
};

/* ==========================================================================
   PIÈCES JOINTES
   Format accepté, en plus de {to, subject, html} :
     attachments: [{ filename: "PV.pdf", content: "<base64 du fichier>" }]
   Le mail devient alors un message MIME complet (multipart/mixed) envoyé à
   SES en mode "Raw". Sans pièce jointe, le mode "Simple" d'avant est conservé
   à l'identique : la Caisse et l'app QR ne changent pas de comportement.

   Deux limites volontaires :
   - le mail part une fois par destinataire, donc une grosse pièce jointe est
     ré-envoyée autant de fois ; d'où le plafond de 5 Mo ;
   - seuls les formats de documents et d'images sont acceptés, jamais un
     exécutable : la fonction est appelable depuis l'extérieur et ne doit pas
     pouvoir servir à distribuer un fichier dangereux.
   ========================================================================== */

const PJ_MAX_NB = 5;
const PJ_MAX_OCTETS = 5 * 1024 * 1024;   // 5 Mo au total, taille du fichier réel

const PJ_TYPES: Record<string, string> = {
  pdf: "application/pdf",
  doc: "application/msword",
  docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  odt: "application/vnd.oasis.opendocument.text",
  rtf: "application/rtf",
  xls: "application/vnd.ms-excel",
  xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  ods: "application/vnd.oasis.opendocument.spreadsheet",
  csv: "text/csv",
  ppt: "application/vnd.ms-powerpoint",
  pptx: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  odp: "application/vnd.oasis.opendocument.presentation",
  txt: "text/plain",
  ics: "text/calendar",
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
  heic: "image/heic",
};

/* Un nom de fichier ne doit jamais pouvoir ouvrir une nouvelle ligne d'en-tete
   ni contenir un chemin. */
function nomFichierSur(n: unknown): string {
  let s = String(n ?? "").replace(/[\r\n\t\x00-\x1f\x7f]/g, " ").trim();
  s = (s.split(/[\\/]/).pop() || "").replace(/"/g, "'").trim();
  if (s.length > 120) {
    const i = s.lastIndexOf(".");
    const ext = i > 0 ? s.slice(i) : "";
    s = s.slice(0, 120 - ext.length) + ext;
  }
  return s;
}

function extensionDe(n: string): string {
  const i = n.lastIndexOf(".");
  return i > 0 ? n.slice(i + 1).toLowerCase() : "";
}

/* Repli ASCII du nom, pour les clients de messagerie anciens. */
function nomAscii(n: string): string {
  const s = n.replace(/[^\x20-\x7e]/g, "_").replace(/"/g, "'");
  return s.trim() || "piece-jointe";
}

/* On accepte du base64 classique, du base64url, et une data: URL complete.
   Tout le reste est refuse : le contenu part tel quel dans le corps MIME. */
function base64Propre(d: unknown): string | null {
  let s = String(d ?? "");
  if (/^data:/i.test(s)) {
    const v = s.indexOf(",");
    if (v < 0) return null;
    s = s.slice(v + 1);
  }
  s = s.replace(/\s+/g, "").replace(/-/g, "+").replace(/_/g, "/");
  if (!s || s.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(s)) return null;
  return s;
}

function tailleDepuisB64(s: string): number {
  const bourrage = s.endsWith("==") ? 2 : s.endsWith("=") ? 1 : 0;
  return (s.length / 4) * 3 - bourrage;
}

function b64Octets(u8: Uint8Array): string {
  let s = "";
  for (let i = 0; i < u8.length; i += 8192) {
    s += String.fromCharCode(...u8.subarray(i, i + 8192));
  }
  return btoa(s);
}

/* Le corps base64 d'un message MIME se plie a 76 caracteres par ligne. */
function plier(s: string, n = 76): string {
  const l: string[] = [];
  for (let i = 0; i < s.length; i += n) l.push(s.slice(i, i + n));
  return l.join("\r\n");
}

/* Un en-tete ne transporte que de l'ASCII : le reste passe en mots encodes
   (RFC 2047), decoupes sur des caracteres entiers pour rester lisibles. */
function enteteEncodee(txt: unknown): string {
  const s = String(txt ?? "").replace(/[\r\n]+/g, " ");
  if (/^[\x20-\x7e]*$/.test(s)) return s;
  const enc = new TextEncoder();
  const mots: string[] = [];
  let courant = "";
  for (const ch of s) {
    if (courant && enc.encode(courant + ch).length > 45) { mots.push(courant); courant = ch; }
    else courant += ch;
  }
  if (courant) mots.push(courant);
  return mots.map((m) => "=?UTF-8?B?" + b64Octets(enc.encode(m)) + "?=").join("\r\n ");
}

/* « Bureau étudiant <noreply@…> » -> nom encode, adresse intacte. */
function enteteExpediteur(v: string): string {
  const m = /^\s*(.*?)\s*<([^>]+)>\s*$/.exec(String(v ?? ""));
  if (!m) return String(v ?? "");
  const nom = m[1].replace(/^"|"$/g, "");
  const adresse = m[2].replace(/[\r\n\s]/g, "");
  if (!nom) return "<" + adresse + ">";
  if (/^[\x20-\x7e]*$/.test(nom)) {
    return /[",;:<>@\[\]\\]/.test(nom)
      ? '"' + nom.replace(/(["\\])/g, "\\$1") + '" <' + adresse + ">"
      : nom + " <" + adresse + ">";
  }
  return enteteEncodee(nom) + " <" + adresse + ">";
}

type Piece = { nom: string; type: string; b64: string; cid?: string };

/* Un identifiant interne ne doit contenir que des caracteres surs : il part
   dans un en-tete et dans le HTML. */
function cidSur(v: unknown): string {
  const s = String(v ?? "").replace(/[^A-Za-z0-9._-]/g, "").slice(0, 60);
  return s;
}

function messageBrut(o: {
  from: string; to: string[]; replyTo: string; subject: string; html: string; pj: Piece[];
}): string {
  const enc = new TextEncoder();
  const mixte = "----ca-" + crypto.randomUUID().replace(/-/g, "");
  const lie = "----rel-" + crypto.randomUUID().replace(/-/g, "");
  const embarquees = o.pj.filter((p) => !!p.cid);
  const jointes = o.pj.filter((p) => !p.cid);
  const L: string[] = [];
  L.push("From: " + enteteExpediteur(o.from));
  L.push("To: " + o.to.join(", "));
  L.push("Reply-To: " + o.replyTo);
  L.push("Subject: " + enteteEncodee(o.subject));
  L.push("MIME-Version: 1.0");
  L.push('Content-Type: multipart/mixed; boundary="' + mixte + '"');
  L.push("");

  L.push("--" + mixte);
  if (embarquees.length) {
    /* Le HTML et les images qu'il affiche voyagent ensemble : c'est ce qui fait
       qu'elles s'affichent sans que le destinataire ait à autoriser quoi que ce soit. */
    L.push('Content-Type: multipart/related; boundary="' + lie + '"');
    L.push("");
    L.push("--" + lie);
  }
  L.push('Content-Type: text/html; charset="UTF-8"');
  L.push("Content-Transfer-Encoding: base64");
  L.push("");
  L.push(plier(b64Octets(enc.encode(o.html))));
  for (const p of embarquees) {
    const ascii = nomAscii(p.nom);
    L.push("--" + lie);
    L.push("Content-Type: " + p.type + '; name="' + ascii + '"');
    L.push("Content-Transfer-Encoding: base64");
    L.push("Content-ID: <" + p.cid + ">");
    L.push('Content-Disposition: inline; filename="' + ascii + '"');
    L.push("");
    L.push(plier(p.b64));
  }
  if (embarquees.length) { L.push("--" + lie + "--"); }

  for (const p of jointes) {
    const ascii = nomAscii(p.nom);
    L.push("--" + mixte);
    L.push("Content-Type: " + p.type + '; name="' + ascii + '"');
    L.push("Content-Transfer-Encoding: base64");
    L.push('Content-Disposition: attachment; filename="' + ascii
      + '"; filename*=UTF-8\'\'' + encodeURIComponent(p.nom));
    L.push("");
    L.push(plier(p.b64));
  }
  L.push("--" + mixte + "--");
  L.push("");
  return L.join("\r\n");
}

/* Lecture et controle des pieces jointes recues. */
function lirePieces(brut: unknown): { pieces: Piece[]; erreur?: string } {
  if (!Array.isArray(brut) || !brut.length) return { pieces: [] };
  if (brut.length > PJ_MAX_NB) {
    return { pieces: [], erreur: PJ_MAX_NB + " pièces jointes maximum par mail." };
  }
  const pieces: Piece[] = [];
  let total = 0;
  for (const p of brut) {
    const o = (p || {}) as Record<string, unknown>;
    const nom = nomFichierSur(o.filename ?? o.nom ?? o.name);
    if (!nom) return { pieces: [], erreur: "Pièce jointe sans nom de fichier." };
    const ext = extensionDe(nom);
    const type = PJ_TYPES[ext];
    if (!type) {
      return {
        pieces: [],
        erreur: "Format de pièce jointe non autorisé : « " + nom
          + " ». Formats acceptés : " + Object.keys(PJ_TYPES).join(", ") + ".",
      };
    }
    const b64 = base64Propre(o.content ?? o.data ?? o.b64 ?? o.contenu);
    if (!b64) return { pieces: [], erreur: "Contenu illisible pour la pièce jointe « " + nom + " »." };
    const cid = cidSur(o.cid ?? o.contentId);
    if (cid && !/^image\//.test(type)) {
      return { pieces: [], erreur: "Seule une image peut être affichée dans le corps du mail (« " + nom + " »)." };
    }
    total += tailleDepuisB64(b64);
    if (total > PJ_MAX_OCTETS) {
      return {
        pieces: [],
        erreur: "Pièces jointes trop lourdes : "
          + (PJ_MAX_OCTETS / 1024 / 1024) + " Mo au total maximum.",
      };
    }
    pieces.push(cid ? { nom, type, b64, cid } : { nom, type, b64 });
  }
  return { pieces };
}

const encc = new TextEncoder();
function hex(buf: ArrayBuffer) {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
async function sha256(msg: string) { return hex(await crypto.subtle.digest("SHA-256", encc.encode(msg))); }
async function hmac(key: ArrayBuffer | Uint8Array, msg: string) {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return await crypto.subtle.sign("HMAC", k, encc.encode(msg));
}

serve(async (req) => {
  const CORS = corsPour(req);
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const corps = await req.json();
    let { to, subject, html, from } = corps;
    const reply_to = corps.reply_to;

    /* Les pièces jointes sont lues d'abord : le nettoyage du HTML a besoin de
       savoir quelles images embarquées accompagnent réellement ce message. */
    const { pieces, erreur } = lirePieces(corps.attachments);
    if (erreur) {
      return new Response(JSON.stringify({ error: erreur }), {
        status: 400, headers: { ...CORS, "Content-Type": "application/json" },
      });
    }
    const cidsOk = new Set(pieces.filter((p) => p.cid).map((p) => p.cid as string));

    /* ---- Nouveau format : { to, modele, data } ---- */
    if (corps.modele) {
      const g = GABARITS[String(corps.modele)];
      if (!g) {
        return new Response(JSON.stringify({ error: "Modèle inconnu : " + corps.modele }), {
          status: 400, headers: { ...CORS, "Content-Type": "application/json" },
        });
      }
      const out = g((corps.data || {}) as Record<string, unknown>);
      subject = out.subject;
      html = out.html;
      from = out.from || from;
    } else if (html) {
      /* ---- Ancien format : HTML libre, donc nettoye ---- */
      const net = nettoyerHtml(html, cidsOk);
      html = net.html;
      if (net.retires.length) {
        console.warn("send-email : contenu neutralise", {
          origin: req.headers.get("origin") || "(aucune)",
          elements: net.retires.slice(0, 10),
        });
      }
    }
    /* ---------------------------------------------- */

    if (!to || !subject || !html) {
      return new Response(JSON.stringify({ error: "Champs requis : to, subject, html (ou modele)" }), {
        status: 400, headers: { ...CORS, "Content-Type": "application/json" },
      });
    }

    let dest = Array.isArray(to) ? to : [to];
    /* Passation : le propriétaire retiré ne reçoit plus rien (voir retires()). */
    const R = await retires();
    const exempt = /^\s*"?Licence-BE\b/i.test(String(from || "")) || /^🔐 Nouvelle connexion/.test(String(subject || ""));
    if (R.adresses.size && !exempt) {
      dest = dest.filter((d: unknown) => !R.adresses.has(String(d).toLowerCase().trim()));
      if (!dest.length) {
        return new Response(JSON.stringify({ ok: true, ignore: "destinataire retiré (passation)" }), {
          status: 200, headers: { ...CORS, "Content-Type": "application/json" },
        });
      }
    }
    const replyDefaut = (R.adresses.size && R.reply) ? R.reply : REPLY_DEFAUT;
    const replyFinal = (reply_to && !R.adresses.has(String(reply_to).toLowerCase().trim())) ? String(reply_to) : replyDefaut;
    if (dest.length > 20) {
      return new Response(JSON.stringify({ error: "20 destinataires maximum par appel" }), {
        status: 400, headers: { ...CORS, "Content-Type": "application/json" },
      });
    }

    /* ---- Contrôle de l'appelant (anti-spam) ---- */
    const acces = await quiAppelle(req);
    const ctl = await controler(req, acces, dest.map((d: unknown) => String(d)), corps.modele ? String(corps.modele) : "", String(from || FROM_DEFAULT));
    const estUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(String(acces.uid ?? ""));
    const trace = { niveau: acces.niveau, uid: estUuid ? acces.uid : null, compte: acces.uid, ip: ipDe(req).slice(0, 60), nb: dest.length,
      origine: (req.headers.get("origin") ?? "").slice(0, 80) || null, modele: corps.modele ? String(corps.modele).slice(0, 40) : null,
      dest_hash: dest.length === 1 ? await shaCourt(String(dest[0]).toLowerCase().trim()) : null };
    if (ctl.refus) {
      await noter({ ...trace, refus: ctl.refus.slice(0, 120) });
      return new Response(JSON.stringify({ error: ctl.refus }), {
        status: acces.niveau === "anonyme" ? 403 : 429, headers: { ...CORS, "Content-Type": "application/json" },
      });
    }
    from = ctl.from;

    /* L'adresse d'envoi reste toujours celle du bureau ; seul le nom affiche suit. */
    const demande = String(from || FROM_DEFAULT);
    const nomAffiche = demande.includes("<")
      ? demande.split("<")[0].trim().replace(/^"|"$/g, "")
      : "";
    const expediteur = nomAffiche
      ? `${nomAffiche.slice(0, 150)} <noreply@${FROM_DOMAINE}>`
      : FROM_DEFAULT;

    const KEY = Deno.env.get("AWS_SES_KEY")!;
    const SECRET = Deno.env.get("AWS_SES_SECRET")!;

    /* Sans pièce jointe : envoi « Simple », strictement comme avant.
       Avec pièce jointe : message MIME complet, envoi « Raw ». */
    const contenu = pieces.length
      ? {
        Raw: {
          Data: b64Octets(encc.encode(messageBrut({
            from: expediteur,
            to: dest.map((d: unknown) => String(d)),
            replyTo: replyFinal,
            subject: String(subject),
            html: String(html),
            pj: pieces,
          }))),
        },
      }
      : {
        Simple: {
          Subject: { Data: subject, Charset: "UTF-8" },
          Body: { Html: { Data: html, Charset: "UTF-8" } },
        },
      };

    const body: Record<string, unknown> = {
      FromEmailAddress: expediteur,
      Destination: { ToAddresses: dest },
      Content: contenu,
      ReplyToAddresses: [replyFinal],
    };
    const payload = JSON.stringify(body);

    const now = new Date();
    const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, "");
    const dateStamp = amzDate.slice(0, 8);

    const canonicalHeaders = `content-type:application/json\nhost:${HOST}\nx-amz-date:${amzDate}\n`;
    const signedHeaders = "content-type;host;x-amz-date";
    const payloadHash = await sha256(payload);
    const canonicalRequest = `POST\n/v2/email/outbound-emails\n\n${canonicalHeaders}\n${signedHeaders}\n${payloadHash}`;

    const scope = `${dateStamp}/${REGION}/ses/aws4_request`;
    const stringToSign = `AWS4-HMAC-SHA256\n${amzDate}\n${scope}\n${await sha256(canonicalRequest)}`;

    const kDate = await hmac(encc.encode("AWS4" + SECRET), dateStamp);
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
    const data = await r.text();
    await noter({ ...trace, refus: r.ok ? null : ("SES " + r.status).slice(0, 120) });
    return new Response(data || JSON.stringify({ ok: r.ok }), {
      status: r.status, headers: { ...CORS, "Content-Type": "application/json" },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500, headers: { ...CORS, "Content-Type": "application/json" },
    });
  }
});
