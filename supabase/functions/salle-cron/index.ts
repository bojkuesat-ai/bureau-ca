// Fonction Supabase « salle-cron » — appelée toutes les 5 minutes par pg_cron.
// Déploiement : Edge Functions › nouvelle fonction « salle-cron », « Verify JWT » DÉSACTIVÉ.
// Variable à créer (Edge Functions › Secrets) : SALLE_CRON_SECRET = le secret mis dans le SQL.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const URL = Deno.env.get("SUPABASE_URL")!;
const SRK = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SECRET = Deno.env.get("SALLE_CRON_SECRET") || "";
const APP = Deno.env.get("APP_URL") || "https://bojkuesat-ai.github.io/bureau-ca/";
const EXP = "Salle-Fac <noreply@bureauetuidant.xyz>";
const M = 60000;
const db = createClient(URL, SRK, { auth: { persistSession: false } });

const e = (x: unknown) => String(x ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const fmt = (iso: string, o: Intl.DateTimeFormatOptions) => new Date(iso).toLocaleString("fr-BE", { timeZone: "Europe/Brussels", ...o });
const creneau = (r: any) => fmt(r.debut, { weekday: "long", day: "2-digit", month: "long", year: "numeric" }) + ", " +
  fmt(r.debut, { hour: "2-digit", minute: "2-digit" }) + " – " + fmt(r.fin, { hour: "2-digit", minute: "2-digit" });
const lien = (id = "") => APP + "?go=salle" + (id ? "&r=" + encodeURIComponent(id) : "");
const bouton = (id: string, t: string) => `<p><a href="${lien(id)}" style="background:#241c46;color:#fff;padding:11px 20px;border-radius:8px;text-decoration:none;font-weight:bold;display:inline-block">${e(t)}</a></p>`;
const page = (corps: string) => `<div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:0 auto;color:#1a1a2e">${corps}<p style="color:#999;font-size:12px;margin-top:18px">Ceci est un envoi automatique — merci de ne pas répondre à ce message.<br>Le bureau étudiant — Espace CA</p></div>`;

// Envoi via la fonction send-email existante (même chemin que l'app).
async function mail(dest: string[], subject: string, corps: string) {
  for (const to of [...new Set(dest.filter(Boolean))]) {
    try {
      await fetch(`${URL}/functions/v1/send-email`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${SRK}`, apikey: SRK },
        body: JSON.stringify({ to, subject, html: page(corps), from: EXP }),
      });
    } catch (_) { /* on continue avec les autres */ }
  }
}
async function cle(c: string) {
  const { data, error } = await db.from("ca_rappels_envoyes").insert({ cle: c }).select();
  return !error && !!data?.length;
}

Deno.serve(async (req) => {
  if (!SECRET || req.headers.get("x-cron-secret") !== SECRET) return new Response("interdit", { status: 403 });
  const now = Date.now();
  await db.rpc("ca_salle_echeances");

  const { data: meta } = await db.from("ca_meta").select("salle_resp,salle_charte").eq("id", 1).maybeSingle();
  const respIds: string[] = meta?.salle_resp || [];
  const { data: resp } = respIds.length
    ? await db.from("ca_membres").select("email").in("id", respIds).eq("statut", "actif")
    : { data: [] as any[] };
  const respMails = (resp || []).map((x: any) => String(x.email || "").toLowerCase()).filter(Boolean);
  const charte: string[] = Array.isArray(meta?.salle_charte) && meta!.salle_charte.length ? meta!.salle_charte : [
    "Laisser la salle propre et rangée après mon passage : tables, chaises, déchets.",
    "Respecter l'horaire réservé et libérer la salle à l'heure.",
    "Fermer les fenêtres, éteindre les lumières et le matériel.",
    "Fermer la salle à clé et remettre les clés dans le boîtier en partant.",
    "Signaler tout dégât ou problème aux responsables de la salle.",
    "Je suis responsable de la salle et des personnes présentes pendant ma réservation."];
  const regles = `<p><b>Rappel des règles :</b></p><ol>${charte.map((t) => `<li>${e(t)}</li>`).join("")}</ol>`;

  const depuis = new Date(now - 10 * 24 * 60 * M).toISOString();
  const { data: rows } = await db.from("ca_salle_reservations").select("*").gte("fin", depuis);
  let envois = 0;
  for (const r of rows || []) {
    const d = new Date(r.debut).getTime(), f = new Date(r.fin).getTime(), c = new Date(r.created_at).getTime();
    if (r.statut === "attente" && now > c + 24 * 60 * M && now < d && await cle("salle-relance:" + r.id)) {
      await mail(respMails, "Demande en attente depuis 24 h — " + creneau(r),
        `<h2>Demande toujours en attente</h2><p>La demande de <b>${e(r.demandeur_nom)}</b> pour le <b>${e(creneau(r))}</b> attend une décision depuis plus de 24 heures.</p>${bouton(r.id, "Valider ou refuser")}`); envois++;
    }
    if (r.statut !== "validee") continue;
    if (now >= d - 60 * M && now < d && await cle("salle-1h:" + r.id)) {
      await mail([r.demandeur_email], "Dans 1 heure : la salle facultaire est à vous",
        `<h2>Votre réservation commence bientôt</h2><p>La salle facultaire est à vous le <b>${e(creneau(r))}</b>.</p>${regles}`); envois++;
    }
    if (!r.depart_declare_le && now >= f - 10 * M && now < f + 30 * M && await cle("salle-fin:" + r.id)) {
      await mail([r.demandeur_email], "Fin de votre réservation : déclarez votre départ",
        `<h2>Votre réservation se termine dans 10 minutes</h2><p>Avant de partir, vérifiez que tout est en ordre, puis déclarez votre départ dans l'app avec <b>au moins 2 photos</b> de la salle.</p>${regles}${bouton(r.id, "Déclarer mon départ")}<p style="color:#a33;font-size:13px">Sans déclaration dans les 24 heures, vous ne pourrez plus réserver la salle.</p>`); envois++;
    }
    if (!r.depart_declare_le && now >= f + 30 * M && now < f + 24 * 60 * M && await cle("salle-retard:" + r.id)) {
      await mail([r.demandeur_email], "Rappel : déclarez votre départ de la salle facultaire",
        `<h2>Départ non déclaré</h2><p>Votre réservation du <b>${e(creneau(r))}</b> est terminée, mais votre départ n'est pas encore déclaré. Faites-le maintenant avec au moins 2 photos : sans déclaration dans les 24 heures après la fin, vous ne pourrez plus réserver.</p>${bouton(r.id, "Déclarer mon départ")}`);
      await mail(respMails, "Départ non déclaré — " + creneau(r),
        `<h2>Départ pas encore déclaré</h2><p><b>${e(r.demandeur_nom)}</b> n'a pas déclaré son départ, 30 minutes après la fin de sa réservation (${e(creneau(r))}). Un rappel lui a été envoyé.</p>${bouton(r.id, "Ouvrir la réservation")}`); envois++;
    }
    if (r.non_declare && now < f + 7 * 24 * 60 * M && await cle("salle-bloc:" + r.id)) {
      await mail([r.demandeur_email], "Réservations de la salle facultaire bloquées",
        `<h2>Vous ne pouvez plus réserver la salle</h2><p>Votre départ de la réservation du <b>${e(creneau(r))}</b> n'a pas été déclaré dans les 24 heures. Vos réservations sont bloquées jusqu'à ce que les responsables de la salle vous débloquent.</p>`);
      await mail(respMails, "Membre bloqué — " + (r.demandeur_nom || ""),
        `<h2>Réservations bloquées</h2><p><b>${e(r.demandeur_nom)}</b> n'a pas déclaré son départ dans les 24 heures (${e(creneau(r))}). Ses réservations sont bloquées jusqu'à ce que vous le ou la débloquiez dans l'app.</p>${bouton("", "Ouvrir l'onglet salle")}`); envois++;
    }
  }

  // Photos : suppression 3 jours après l'envoi.
  const { data: ph } = await db.from("ca_salle_reservations").select("id,depart_declare_le,arrivee_le,depart_photos,arrivee_photos").eq("photos_purgees", false);
  let purges = 0;
  for (const r of ph || []) {
    const ref = Math.max(r.depart_declare_le ? new Date(r.depart_declare_le).getTime() : 0, r.arrivee_le ? new Date(r.arrivee_le).getTime() : 0);
    const liste = [...(r.depart_photos || []), ...(r.arrivee_photos || [])];
    if (!ref || !liste.length || now < ref + 3 * 24 * 60 * M) continue;
    const { error } = await db.storage.from("ca-salle").remove(liste);
    if (!error) { await db.rpc("ca_salle_photos_purgees", { p_id: r.id }); purges++; }
  }
  return new Response(JSON.stringify({ ok: true, envois, purges }), { headers: { "Content-Type": "application/json" } });
});
