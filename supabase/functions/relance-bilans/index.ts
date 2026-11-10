/* Espace CA — relance anonyme des bilans moraux.
   La liste des membres n'ayant pas déposé est calculée ICI et ne sort jamais :
   le navigateur ne reçoit qu'un nombre. Réservé au secrétariat et au propriétaire.
   09/11/2026 : CORS limité aux sites du bureau. */

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SRV = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;

/* En dessous de ce nombre de manquants, un rappel désignerait les personnes. */
const SEUIL = 3;
/* Délai minimum entre deux rappels (heures). */
const DELAI_H = 12;

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

function json(req: Request, body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsPour(req), "Content-Type": "application/json" },
  });
}

async function rest(path: string) {
  const r = await fetch(`${SB_URL}/rest/v1/${path}`, {
    headers: { apikey: SRV, Authorization: `Bearer ${SRV}` },
  });
  if (!r.ok) throw new Error(await r.text());
  return await r.json();
}

function esc(x: unknown) {
  return String(x ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsPour(req) });
  if (req.method !== "POST") return json(req, { error: "méthode non autorisée" }, 405);

  try {
    const auth = req.headers.get("Authorization") || "";
    if (!auth.toLowerCase().startsWith("bearer ")) return json(req, { error: "non authentifié" }, 401);

    /* 1. Qui appelle ? */
    const ur = await fetch(`${SB_URL}/auth/v1/user`, { headers: { Authorization: auth, apikey: ANON } });
    if (!ur.ok) return json(req, { error: "session invalide" }, 401);
    const uid = (await ur.json())?.id;
    if (!uid) return json(req, { error: "session invalide" }, 401);

    /* 2. A-t-il le droit ? */
    const membres = await rest("ca_membres?select=id,email,statut,role,fonction");
    const meta = (await rest("ca_meta?id=eq.1&select=bilan_etat,bilan_actif,secretaires,bilan_relance_le"))[0] || {};
    const moi = membres.find((m: any) => m.id === uid);
    const secretaires: string[] = Array.isArray(meta.secretaires) ? meta.secretaires : [];
    const autorise = !!moi && moi.role !== "coopte" && (
      moi.role === "owner" ||
      String(moi.fonction || "").toLowerCase().startsWith("secr") ||
      secretaires.includes(uid)
    );
    if (!autorise) return json(req, { error: "réservé au secrétariat" }, 403);

    /* 3. La collecte est-elle ouverte ? */
    const etat = meta.bilan_etat || (meta.bilan_actif ? "ouvert" : "ferme");
    if (etat !== "ouvert") return json(req, { error: "la collecte n'est pas ouverte" }, 400);

    /* 4. Pas deux rappels coup sur coup. */
    if (meta.bilan_relance_le) {
      const h = (Date.now() - new Date(meta.bilan_relance_le).getTime()) / 3600000;
      if (h < DELAI_H) return json(req, { error: `un rappel a déjà été envoyé il y a moins de ${DELAI_H} h` }, 429);
    }

    /* 5. Qui manque ? (ne sort jamais d'ici) */
    const faits = await rest("ca_bilan_faits?select=membre_id");
    const deposes = new Set(faits.map((f: any) => f.membre_id));
    const desab = new Set(
      (await rest("ca_desabonnes?select=email")).map((d: any) => String(d.email || "").toLowerCase()),
    );

    const actifs = membres.filter((m: any) => m.email && m.statut === "actif" && m.role !== "coopte");
    const manquants = actifs.filter((m: any) => !deposes.has(m.id));
    if (!manquants.length) return json(req, { error: "tout le monde a déposé son bilan" }, 400);
    if (manquants.length < SEUIL) {
      return json(req, { error: `moins de ${SEUIL} manquants : le rappel désignerait les personnes` }, 400);
    }

    const cibles = [...new Set(
      manquants.map((m: any) => String(m.email).toLowerCase().trim()).filter((e: string) => e && !desab.has(e)),
    )];

    /* 6. Envoi, un mail par personne — jamais de liste groupée. */
    let appUrl = "";
    try { appUrl = String((await req.json())?.app_url || ""); } catch (_) { /* corps vide accepté */ }
    const lien = /^https?:\/\//.test(appUrl)
      ? `<p style="margin:14px 0 0"><a href="${esc(appUrl)}">Ouvrir l'espace CA</a></p>`
      : "";

    const sujet = "Rappel — votre bilan moral n'a pas encore été déposé";
    const html =
      `<div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:0 auto;color:#1a1a2e">` +
      `<h2 style="margin:0 0 10px">Bilans moraux — rappel</h2>` +
      `<p>La collecte des bilans moraux est toujours ouverte et votre bilan n'a pas encore été déposé.</p>` +
      `<p>Vos réponses sont <b>anonymes</b> : elles ne portent aucune trace de leur auteur et sont mélangées à celles des autres dès l'envoi.</p>` +
      `<p style="color:#666;font-size:13px">Ce rappel est envoyé automatiquement aux personnes qui n'ont pas encore répondu. La personne qui l'a déclenché ne sait pas qui l'a reçu.</p>` +
      lien +
      `<p style="color:#999;font-size:12px;margin-top:18px">Ceci est un envoi automatique — merci de ne pas répondre à ce message.<br>Le bureau étudiant — Espace CA</p></div>`;

    let envoyes = 0;
    for (const to of cibles) {
      try {
        const r = await fetch(`${SB_URL}/functions/v1/send-email`, {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: auth, apikey: ANON },
          body: JSON.stringify({ to, subject: sujet, html }),
        });
        if (r.ok) envoyes++;
      } catch (_) { /* on continue */ }
      await new Promise((r) => setTimeout(r, 120));
    }

    /* 7. Trace de la date seule. */
    const date = new Date().toISOString();
    await fetch(`${SB_URL}/rest/v1/ca_meta?id=eq.1`, {
      method: "PATCH",
      headers: {
        apikey: SRV,
        Authorization: `Bearer ${SRV}`,
        "Content-Type": "application/json",
        Prefer: "return=minimal",
      },
      body: JSON.stringify({ bilan_relance_le: date }),
    });

    return json(req, { envoyes, manquants: manquants.length, date });
  } catch (e) {
    return json(req, { error: String((e as Error)?.message || e) }, 500);
  }
});
