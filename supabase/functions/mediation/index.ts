// Supabase Edge Function : « mediation »
// Envoie les mails de médiation. Les adresses sont trouvées ICI, côté serveur :
// le navigateur ne reçoit jamais l'identité d'une personne anonyme.
// Aucun mail ne contient de nom ni de contenu : seulement un lien vers l'app.
//
// Déploiement : Supabase > Edge Functions > Create function > nom « mediation »,
// coller ce code, puis DÉSACTIVER « Verify JWT » (la fonction vérifie elle-même).
// 09/11/2026 : CORS limité aux sites du bureau.
import { createClient } from "jsr:@supabase/supabase-js@2";

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const APP = Deno.env.get("CA_APP_URL") ?? "https://bojkuesat-ai.github.io/bureau-ca/";
const ORIGINES = ["https://bojkuesat-ai.github.io", "https://bureauetuidant.xyz", "https://www.bureauetuidant.xyz"];
function corsPour(req: Request) {
  const o = req.headers.get("origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ORIGINES.includes(o) ? o : ORIGINES[0],
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}
const recent = (t: string | null, min: number) => !!t && Date.now() - new Date(t).getTime() < min * 60000;

Deno.serve(async (req) => {
  const CORS = corsPour(req);
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const auth = req.headers.get("Authorization") ?? "";
  const apikey = req.headers.get("apikey") ?? "";
  const db = createClient(SB_URL, SERVICE, { auth: { persistSession: false } });

  const { data: ud } = await db.auth.getUser(auth.replace(/^Bearer\s+/i, ""));
  const u = ud?.user?.id;
  if (!u) return json({ error: "Non connecté." }, 401);
  const { data: moi } = await db.from("ca_membres").select("statut").eq("id", u).maybeSingle();
  if (!moi || moi.statut !== "actif") return json({ error: "Compte non actif." }, 403);

  let body: { evenement?: string; dossier?: string } = {};
  try { body = await req.json(); } catch { /* vide */ }
  const ev = body.evenement ?? "";

  const email = async (id: string | null) => {
    if (!id) return null;
    const { data } = await db.from("ca_membres").select("email").eq("id", id).maybeSingle();
    return data?.email ?? null;
  };
  const rpc = async (f: string, a: Record<string, unknown> = {}) => (await db.rpc(f, a)).data as string | null;

  let envoyes = 0;
  const envoyer = async (id: string | null, sujet: string, phrase: string) => {
    const to = await email(id);
    if (!to) return;
    const html = `<div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:0 auto;color:#1a1a2e">
      <h2 style="margin:0 0 10px">Médiation</h2><p>${phrase}</p>
      <p>Pour des raisons de confidentialité, ce message ne contient ni nom ni détail.</p>
      <p><a href="${APP}" style="background:#241c46;color:#fff;padding:11px 20px;border-radius:8px;text-decoration:none;font-weight:bold;display:inline-block">Ouvrir l'espace CA</a></p>
      <p style="color:#999;font-size:12px">Envoi automatique — merci de ne pas répondre.</p></div>`;
    const r = await fetch(`${SB_URL}/functions/v1/send-email`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: auth, apikey },
      body: JSON.stringify({ to, subject: "Médiation — " + sujet, html }),
    });
    if (r.ok) envoyes++;
  };

  // Retards de 12 h : prévenir le propriétaire, une seule fois par dossier.
  if (ev === "retard") {
    const { data: ds } = await db.from("ca_med_dossiers").select("id")
      .eq("statut", "a_reattribuer").is("retard_mail_le", null);
    const own = await rpc("ca_med_owner");
    for (const d of ds ?? []) {
      await db.from("ca_med_dossiers").update({ retard_mail_le: new Date().toISOString() }).eq("id", d.id);
      await envoyer(own, "dossier à réattribuer",
        "Un médiateur n'a pas répondu dans les 12 heures. Le dossier doit être réattribué.");
    }
    return json({ envoyes });
  }

  const { data: d } = await db.from("ca_med_dossiers").select("*").eq("id", body.dossier ?? "").maybeSingle();
  if (!d) return json({ error: "Dossier introuvable." }, 404);
  const parties = [d.demandeur_id, d.vise_id];

  if (ev === "nouveau") {
    if (u !== d.demandeur_id || !recent(d.created_at, 10)) return json({ error: "Refusé." }, 403);
    await envoyer(await rpc("ca_med_owner"), "nouvelle demande à attribuer",
      "Une nouvelle demande de médiation attend d'être attribuée à un médiateur.");
    await envoyer(d.demandeur_id, "demande enregistrée",
      "Votre demande de médiation est enregistrée. Un médiateur neutre va être désigné. " +
      "Si la médiation n'aboutit pas, le dossier sera transmis à la présidence.");
  } else if (ev === "attribue") {
    const own = await rpc("ca_med_owner");
    if (u !== own || !recent(d.attribue_le, 10)) return json({ error: "Refusé." }, 403);
    await envoyer(d.mediateur_id, "un dossier vous est confié",
      "Un dossier de médiation vous est confié. Merci d'y répondre dans les 12 heures, sinon il sera réattribué.");
    await envoyer(d.demandeur_id, "médiateur désigné", "Un médiateur a été désigné pour votre dossier.");
    await envoyer(d.vise_id, "une médiation vous concerne",
      "Une demande de médiation vous concerne. Un médiateur va vous écrire dans l'espace CA.");
  } else if (ev === "message") {
    const { data: m } = await db.from("ca_med_messages").select("auteur_role,cote,created_at")
      .eq("dossier_id", d.id).eq("auteur_id", u).order("created_at", { ascending: false }).limit(1).maybeSingle();
    if (!m || !recent(m.created_at, 5)) return json({ error: "Refusé." }, 403);
    if (m.auteur_role === "demandeur" || m.auteur_role === "vise") {
      const qui = d.statut === "escalade" ? d.escalade_vers : d.mediateur_id;
      await envoyer(qui, "nouveau message", "Un nouveau message a été ajouté dans un dossier qui vous est confié.");
    } else {
      await envoyer(m.cote === "demandeur" ? d.demandeur_id : d.vise_id, "nouvelle réponse",
        "Vous avez une nouvelle réponse dans votre dossier de médiation.");
    }
  } else if (ev === "clos") {
    if (u !== d.mediateur_id || !recent(d.clos_le, 10)) return json({ error: "Refusé." }, 403);
    if (d.statut === "regle") {
      await envoyer(await rpc("ca_med_pres"), "rapport : dossier réglé",
        "Un dossier de médiation a été réglé. Le rapport est disponible dans l'espace CA, onglet Médiation.");
      for (const p of parties) await envoyer(p, "dossier réglé", "Votre dossier de médiation est clos : il a été réglé.");
    } else if (d.statut === "escalade") {
      const label = (await rpc("ca_med_label_escalade", { p: d.escalade_vers })) ?? "un responsable";
      await envoyer(d.escalade_vers, "dossier non réglé à trancher",
        "Une médiation n'a pas abouti. Le dossier vous est transmis : c'est à vous de trancher.");
      for (const p of parties) await envoyer(p, "dossier transmis",
        `La médiation n'a pas abouti. Le dossier est transmis à ${label}.`);
    }
  } else if (ev === "tranche") {
    if (u !== d.escalade_vers || !recent(d.decide_le, 10)) return json({ error: "Refusé." }, 403);
    for (const p of parties) await envoyer(p, "décision rendue", "Une décision a été rendue dans votre dossier de médiation.");
  } else {
    return json({ error: "Événement inconnu." }, 400);
  }
  return json({ envoyes });
});
