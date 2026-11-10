// ============================================================
// notifier-auteur — prevenir l'auteur d'un signalement qu'on lui a repondu,
// sans jamais exposer son identite ni son adresse au navigateur appelant.
//
// Pourquoi cote serveur : depuis le 06/09/2026, la colonne membre_id de
// ca_conflits n'est plus lisible via l'API (etape 6). La personne chargee de
// la mediation ne peut donc pas savoir a qui elle repond — c'est voulu — et
// le navigateur ne peut pas retrouver l'adresse de l'auteur. Cette fonction
// fait la resolution en interne et ne renvoie qu'un compteur.
//
// Deploiement : Supabase > Edge Functions > nouvelle fonction « notifier-auteur »
// avec « Verify JWT » sur OFF. Le controle des droits est fait ici, dans le
// code, comme pour « rappels » et « relance-bilans ».
//
// Ce qui sort de cette fonction : { envoye: 0 | 1 }. Jamais d'adresse,
// jamais de nom, jamais de texte de signalement.
// 09/11/2026 : CORS limite aux sites du bureau.
// ============================================================

const URL_SB = Deno.env.get("SUPABASE_URL")!;
const CLE_SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CLE_ANON = Deno.env.get("SUPABASE_ANON_KEY")!;

const ORIGINES = ["https://bojkuesat-ai.github.io", "https://bureauetuidant.xyz", "https://www.bureauetuidant.xyz"];
function corsPour(req: Request) {
  const o = req.headers.get("origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ORIGINES.includes(o) ? o : ORIGINES[0],
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

const repondre = (req: Request, corps: unknown, code = 200) =>
  new Response(JSON.stringify(corps), {
    status: code,
    headers: { ...corsPour(req), "Content-Type": "application/json" },
  });

/* Lecture cote serveur : la cle de service ignore la RLS et les privileges
   de colonne. C'est precisement ce qui permet de retrouver l'auteur sans
   que personne d'autre ne puisse le faire. */
async function lire(chemin: string) {
  const r = await fetch(`${URL_SB}/rest/v1/${chemin}`, {
    headers: { apikey: CLE_SERVICE, Authorization: `Bearer ${CLE_SERVICE}` },
  });
  if (!r.ok) return null;
  return await r.json();
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsPour(req) });
  if (req.method !== "POST") return repondre(req, { error: "methode non autorisee" }, 405);

  // ---- 1. Qui appelle ? ----
  const entete = req.headers.get("Authorization") || "";
  if (!entete.startsWith("Bearer ")) return repondre(req, { error: "authentification requise" }, 401);

  const ru = await fetch(`${URL_SB}/auth/v1/user`, {
    headers: { apikey: CLE_ANON, Authorization: entete },
  });
  if (!ru.ok) return repondre(req, { error: "session invalide" }, 401);
  const utilisateur = await ru.json();
  const appelant = utilisateur?.id;
  if (!appelant) return repondre(req, { error: "session invalide" }, 401);

  // ---- 2. Est-il designe pour la mediation ? ----
  const meta = await lire("ca_meta?id=eq.1&select=direction");
  const designes: string[] = Array.isArray(meta?.[0]?.direction) ? meta[0].direction : [];
  if (!designes.includes(appelant)) return repondre(req, { error: "reserve a la mediation" }, 403);

  // ---- 3. Quel fil ? ----
  let fil = "";
  try {
    const corps = await req.json();
    fil = String(corps?.fil || "").trim();
  } catch (_) { /* corps illisible */ }
  if (!fil || fil.length > 64) return repondre(req, { error: "fil manquant" }, 400);

  // ---- 4. Qui a ouvert ce fil ? (jamais renvoye a l'appelant) ----
  const premier = await lire(
    `ca_conflits?fil_id=eq.${encodeURIComponent(fil)}&de_direction=is.false` +
    `&membre_id=not.is.null&order=created_at.asc&limit=1&select=membre_id`,
  );
  const auteurId = premier?.[0]?.membre_id;
  if (!auteurId) return repondre(req, { envoye: 0 });

  // Adresse : d'abord la fiche membre, sinon le compte d'authentification.
  let adresse = "";
  const membre = await lire(`ca_membres?id=eq.${auteurId}&select=email`);
  adresse = String(membre?.[0]?.email || "").trim();
  if (!adresse) {
    const ra = await fetch(`${URL_SB}/auth/v1/admin/users/${auteurId}`, {
      headers: { apikey: CLE_SERVICE, Authorization: `Bearer ${CLE_SERVICE}` },
    });
    if (ra.ok) adresse = String((await ra.json())?.email || "").trim();
  }
  if (!adresse) return repondre(req, { envoye: 0 });

  // ---- 4 bis. Anti-abus : un mail au maximum toutes les 10 minutes par fil ----
  // (la cle unique de ca_rappels_envoyes refuse un second passage dans la meme tranche)
  const tranche = Math.floor(Date.now() / 600000);
  const verrou = await fetch(`${URL_SB}/rest/v1/ca_rappels_envoyes`, {
    method: "POST",
    headers: { apikey: CLE_SERVICE, Authorization: `Bearer ${CLE_SERVICE}`, "Content-Type": "application/json", Prefer: "return=minimal" },
    body: JSON.stringify({ cle: `notifier-auteur:${fil}:${tranche}` }),
  });
  if (!verrou.ok) return repondre(req, { envoye: 0, limite: true });

  // ---- 5. Respect du desabonnement ----
  const desab = await lire(`ca_desabonnes?email=eq.${encodeURIComponent(adresse.toLowerCase())}&select=email`);
  if (Array.isArray(desab) && desab.length) return repondre(req, { envoye: 0 });

  // ---- 6. Envoi. Aucun contenu du signalement ni de la reponse. ----
  const appUrl = (Deno.env.get("CA_APP_URL") || "https://bojkuesat-ai.github.io/bureau-ca/").trim();
  const html =
    '<div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:0 auto;color:#1a1a2e">' +
    '<h2 style="margin:0 0 10px">Reponse a votre signalement</h2>' +
    "<p>La personne chargee de la mediation a repondu a votre message.</p>" +
    "<p>La reponse est consultable uniquement dans l'espace CA, onglet Mediation. " +
    "Elle n'est pas reprise dans cet e-mail.</p>" +
    '<p><a href="' + appUrl + '" style="background:#241c46;color:#fff;padding:11px 20px;' +
    'border-radius:8px;text-decoration:none;font-weight:bold;display:inline-block">Ouvrir l\'espace CA</a></p>' +
    '<p style="color:#999;font-size:12px;margin-top:18px">Ceci est un envoi automatique &mdash; ' +
    "merci de ne pas repondre a ce message.<br>Le bureau etudiant &mdash; Espace CA</p></div>";

  const envoi = await fetch(`${URL_SB}/functions/v1/send-email`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: CLE_SERVICE,
      Authorization: `Bearer ${CLE_SERVICE}`,
    },
    body: JSON.stringify({
      to: adresse,
      subject: "Mediation — reponse a votre signalement",
      html,
    }),
  });

  return repondre(req, { envoye: envoi.ok ? 1 : 0 });
});
