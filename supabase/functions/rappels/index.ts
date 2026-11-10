/* Edge function « rappels » — Espace CA
   -----------------------------------------------------------------------
   Envoie un rappel aux personnes qui n'ont pas encore répondu :
     - budget en vote      -> qui n'a pas voté (ca_budget_votes)
     - vote ouvert         -> qui n'a pas voté (ca_vote_ballots)
     - événement à venir   -> qui n'a pas donné sa présence (ca_event_presence)

   Deux modes d'appel :
     1) depuis l'app  : POST { type, id }  + jeton de l'utilisateur connecté.
        Droits vérifiés ici : propriétaire, secrétariat, présidence,
        ou la personne qui a déposé l'objet.
     2) depuis le cron : POST {} + en-tête x-cron-secret (secret CRON_SECRET).
        Traite tous les rappels programmés (rappel_prog_at échu).

   Garde-fou : un rappel maximum toutes les 12 h par objet.
   La liste des retardataires est calculée ici et ne sort jamais :
   la réponse ne contient que des nombres.

   JWT verify : OFF (les droits sont vérifiés dans le code ci-dessous).
   09/11/2026 : CORS limité aux sites du bureau.
*/

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CRON_SECRET = Deno.env.get("CRON_SECRET") || "";
const APP_URL = "https://bojkuesat-ai.github.io/bureau-ca/";
const DELAI_MIN_H = 12;

const admin = createClient(SB_URL, SERVICE, { auth: { persistSession: false } });

const ORIGINES = ["https://bojkuesat-ai.github.io", "https://bureauetuidant.xyz", "https://www.bureauetuidant.xyz"];
function corsPour(req: Request) {
  const o = req.headers.get("origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ORIGINES.includes(o) ? o : ORIGINES[0],
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

/* Choix de notifications (onglet Notifs du CA) : un rappel de vote, de budget ou
   d'événement ne part pas chez qui a coupé la catégorie. Si la base ne répond
   pas, on envoie comme avant. */
async function notifTrier(cat: string, emails: string[]): Promise<Set<string>> {
  const tous = new Set(emails);
  if (!emails.length) return tous;
  try {
    const { data, error } = await admin.rpc("notif_preparer_srv", { p_categorie: cat, p_emails: emails, p_sujet: "", p_html: "", p_urgent: true });
    if (error || !Array.isArray(data)) return tous;
    return new Set((data as string[]).map((x) => String(x).toLowerCase().trim()));
  } catch (_) { return tous; }
}

const esc = (s: unknown) =>
  String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

/* ---- configuration par type d'objet ---- */
const TYPES: Record<string, {
  table: string;
  reponses: string;
  cle: string;
  titre: (o: any) => string;
  ouvert: (o: any) => boolean;
  intro: string;
  verbe: string;
}> = {
  budget: {
    table: "ca_budgets",
    reponses: "ca_budget_votes",
    cle: "budget_id",
    titre: (o) => o.titre,
    ouvert: (o) => o.statut === "vote",
    intro: "Une demande de budget attend encore votre voix",
    verbe: "voter",
  },
  vote: {
    table: "ca_votes",
    reponses: "ca_vote_ballots",
    cle: "vote_id",
    titre: (o) => o.question,
    ouvert: (o) => o.statut === "open",
    intro: "Un vote est toujours ouvert et attend votre voix",
    verbe: "voter",
  },
  evenement: {
    table: "ca_evenements",
    reponses: "ca_event_presence",
    cle: "evenement_id",
    titre: (o) => o.titre,
    ouvert: (o) => !o.date || new Date(o.date).getTime() >= Date.now() - 86400000,
    intro: "Un événement approche et votre présence n'est pas encore indiquée",
    verbe: "indiquer votre présence",
  },
};

function fmtQuand(iso: string | null) {
  if (!iso) return "";
  try {
    return new Date(iso).toLocaleString("fr-BE", {
      weekday: "long", day: "numeric", month: "long", hour: "2-digit", minute: "2-digit",
      timeZone: "Europe/Brussels",
    });
  } catch { return ""; }
}

/* ---- destinataires : membres actifs sans réponse, hors désabonnés ---- */
async function retardataires(type: string, id: string) {
  const cfg = TYPES[type];

  const { data: membres } = await admin
    .from("ca_membres")
    .select("id, prenom, nom, email, email_alt, statut, role")
    .eq("statut", "actif");

  const { data: diffusion } = await admin.from("ca_mailing").select("email");

  const { data: reps } = await admin
    .from(cfg.reponses)
    .select("membre_id")
    .eq(cfg.cle, id);

  const { data: desab } = await admin.from("ca_desabonnes").select("email");

  const ontRepondu = new Set((reps || []).map((r: any) => r.membre_id));
  const bloques = new Set((desab || []).map((d: any) => String(d.email || "").toLowerCase().trim()));

  const inscrits = (membres || [])
    .filter((m: any) => m.role !== "coopte")
    .filter((m: any) => m.email && String(m.email).trim())
    .filter((m: any) => !ontRepondu.has(m.id))
    .filter((m: any) => !bloques.has(String(m.email).toLowerCase().trim()))
    .map((m: any) => ({
      email: String(m.email).toLowerCase().trim(),
      prenom: String(m.prenom || "").trim(),
      sansCompte: false,
    }));

  const couvertes = new Set<string>();
  (membres || []).forEach((m: any) => {
    if (m.email) couvertes.add(String(m.email).toLowerCase().trim());
    if (m.email_alt) couvertes.add(String(m.email_alt).toLowerCase().trim());
  });

  const sansCompte = [...new Set(
    (diffusion || [])
      .map((d: any) => String(d.email || "").toLowerCase().trim())
      .filter((e: string) => e && !couvertes.has(e) && !bloques.has(e)),
  )].map((email) => ({ email, prenom: "", sansCompte: true }));

  return [...inscrits, ...sansCompte];
}

function corpsMail(type: string, obj: any, prenom: string, sansCompte = false) {
  const cfg = TYPES[type];
  const limite = obj.date_limite ? fmtQuand(obj.date_limite) : "";
  const detail =
    type === "budget" && obj.cout ? `<p style="margin:0 0 6px;color:#3a3a5a">Montant demandé : <b>${esc(Number(obj.cout).toFixed(2))} €</b></p>` :
    type === "evenement" && obj.date ? `<p style="margin:0 0 6px;color:#3a3a5a">Date : <b>${esc(fmtQuand(obj.date))}</b></p>` : "";

  return `<div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:0 auto;color:#1a1a2e">
    <h2 style="margin:0 0 10px">Rappel</h2>
    <p style="margin:0 0 10px">${prenom ? "Bonjour " + esc(prenom) + "," : "Bonjour,"}</p>
    <p style="margin:0 0 10px">${esc(cfg.intro)} :</p>
    <p style="font-size:16px;margin:0 0 6px"><b>${esc(cfg.titre(obj))}</b></p>
    ${detail}
    ${limite ? `<p style="margin:10px 0;padding:10px 12px;background:#fff7e6;border:1px solid #e8d9a8;border-radius:8px;font-size:13px;color:#5a4a1a">⏳ À traiter avant le <b>${esc(limite)}</b>.</p>` : ""}
    ${sansCompte ? `<div style="margin:14px 0;padding:12px 14px;background:#f4f2fb;border:1px solid #d9d4ee;border-radius:8px">
      <p style="margin:0 0 8px;font-size:14px"><b>Vous n'avez pas encore de compte sur l'espace CA.</b></p>
      <p style="margin:0;font-size:14px;color:#3a3a5a"><b>1.</b> Créez votre compte avec votre adresse ULB — c'est immédiat.<br><b>2.</b> Une fois connecté·e, vous pourrez ${esc(cfg.verbe)}.</p>
    </div>` : ""}
    <p style="margin:14px 0"><a href="${APP_URL}" style="background:#241c46;color:#fff;padding:11px 20px;border-radius:8px;text-decoration:none;font-weight:bold;display:inline-block">${sansCompte ? "Créer mon compte et " + esc(cfg.verbe) : "Ouvrir l'espace CA pour " + esc(cfg.verbe)}</a></p>
    <p style="color:#999;font-size:12px;margin-top:18px">Vous recevez ce rappel parce que votre réponse n'a pas encore été enregistrée. Si vous avez déjà répondu, ignorez ce message.<br>Envoi automatique — merci de ne pas répondre.<br>Le bureau étudiant — Espace CA</p>
  </div>`;
}

async function envoyer(type: string, obj: any, modeCron = false) {
  const cfg = TYPES[type];
  const maintenant = new Date().toISOString();

  if (modeCron) {
    const { data: pris } = await admin.from(cfg.table)
      .update({ rappel_prog_at: null, rappel_le: maintenant })
      .eq("id", obj.id)
      .not("rappel_prog_at", "is", null)
      .select("id");
    if (!pris || !pris.length) return { envoyes: 0, echecs: 0, restants: 0 };
  }

  const dest = await retardataires(type, obj.id);
  if (!dest.length) return { envoyes: 0, echecs: 0, restants: 0 };

  if (!modeCron) {
    await admin.from(cfg.table)
      .update({ rappel_le: maintenant, rappel_prog_at: null })
      .eq("id", obj.id);
  }

  const gardes = await notifTrier(type, dest.map((d) => d.email));
  const aEnvoyer = dest.filter((d) => gardes.has(d.email));
  /* Budget coupé pour tout le monde par le propriétaire : rien ne part, et rien ne le laisse voir. */
  let ok = type === "budget" ? dest.length - aEnvoyer.length : 0, err = 0;
  for (const d of aEnvoyer) {
    try {
      const r = await fetch(`${SB_URL}/functions/v1/send-email`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${SERVICE}`, apikey: SERVICE },
        body: JSON.stringify({
          to: d.email,
          subject: "Rappel — " + cfg.titre(obj),
          html: corpsMail(type, obj, d.prenom, d.sansCompte),
        }),
      });
      r.ok ? ok++ : err++;
    } catch { err++; }
    await new Promise((res) => setTimeout(res, 120));
  }

  return { envoyes: ok, echecs: err, restants: dest.length };
}

Deno.serve(async (req) => {
  const CORS = corsPour(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...CORS, "Content-Type": "application/json" },
    });
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  let body: any = {};
  try { body = await req.json(); } catch { /* cron sans corps */ }

  const jeton = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const parCron = !!CRON_SECRET && req.headers.get("x-cron-secret") === CRON_SECRET;
  const estCron = parCron || jeton === SERVICE || body.cron === true;

  /* ---------- MODE CRON : tous les rappels programmés échus ---------- */
  if (estCron) {
    if (!parCron && jeton !== SERVICE) return json({ error: "Non autorisé." }, 401);
    const maintenant = new Date().toISOString();
    let total = 0, objets = 0;

    for (const [type, cfg] of Object.entries(TYPES)) {
      const { data } = await admin.from(cfg.table).select("*")
        .not("rappel_prog_at", "is", null)
        .lte("rappel_prog_at", maintenant);

      for (const obj of data || []) {
        if (!cfg.ouvert(obj)) {
          await admin.from(cfg.table).update({ rappel_prog_at: null }).eq("id", obj.id);
          continue;
        }
        const res = await envoyer(type, obj, true);
        total += res.envoyes; objets++;
      }
    }
    return json({ objets, envoyes: total });
  }

  /* ---------- MODE APP : rappel immédiat déclenché par une personne ---------- */
  const type = String(body.type || "");
  const id = String(body.id || "");
  const cfg = TYPES[type];
  if (!cfg || !id) return json({ error: "Requête incomplète." }, 400);
  if (!jeton) return json({ error: "Connexion requise." }, 401);

  const { data: u } = await admin.auth.getUser(jeton);
  const user = u?.user;
  if (!user) return json({ error: "Session invalide." }, 401);

  const { data: moi } = await admin.from("ca_membres")
    .select("id, prenom, nom, fonction, role, statut").eq("id", user.id).maybeSingle();
  if (!moi || moi.statut !== "actif") return json({ error: "Compte non actif." }, 403);
  if (moi.role === "coopte") return json({ error: "Réservé aux membres du CA." }, 403);

  const { data: obj } = await admin.from(cfg.table).select("*").eq("id", id).maybeSingle();
  if (!obj) return json({ error: "Objet introuvable." }, 404);
  if (!cfg.ouvert(obj)) return json({ error: "Cet objet n'est plus ouvert." }, 400);

  const fonction = String(moi.fonction || "").toLowerCase();
  const { data: meta } = await admin.from("ca_meta").select("secretaires").eq("id", 1).maybeSingle();
  const secretaires: string[] = Array.isArray(meta?.secretaires) ? meta!.secretaires : [];
  const sig = ((moi.prenom || moi.nom || "") + (moi.fonction ? " · " + moi.fonction : "")).trim();

  const autorise =
    moi.role === "owner" ||
    /^(vice[- ]?)?pr[ée]sident/.test(fonction) ||
    fonction.startsWith("secr") ||
    secretaires.includes(moi.id) ||
    obj.cree_par === moi.id ||
    (obj.demandeur && String(obj.demandeur).trim() === sig) ||
    (obj.responsable && String(obj.responsable).trim().toLowerCase() === String(moi.prenom + " " + moi.nom).trim().toLowerCase());

  if (!autorise) return json({ error: "Seuls le déposant, la présidence, le secrétariat ou le propriétaire peuvent relancer." }, 403);

  if (body.quand) {
    const t = new Date(body.quand);
    if (isNaN(t.getTime())) return json({ error: "Date invalide." }, 400);
    if (t.getTime() < Date.now() - 60000) return json({ error: "Cette date est déjà passée." }, 400);
    await admin.from(cfg.table).update({ rappel_prog_at: t.toISOString() }).eq("id", id);
    const dest = await retardataires(type, id);
    return json({ programme: t.toISOString(), restants: dest.length });
  }

  if (obj.rappel_le) {
    const h = (Date.now() - new Date(obj.rappel_le).getTime()) / 3600000;
    if (h < DELAI_MIN_H) {
      return json({ error: `Un rappel a déjà été envoyé il y a ${Math.floor(h)} h. Attendez ${Math.ceil(DELAI_MIN_H - h)} h.` }, 429);
    }
  }

  const res = await envoyer(type, obj);
  if (!res.restants) return json({ envoyes: 0, restants: 0, message: "Tout le monde a déjà répondu." });
  return json(res);
});
