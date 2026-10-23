/* Billetterie — fonctionnement hors ligne (scanner à l'entrée).
   La page et ses librairies sont gardées sur le téléphone. Les données
   (Supabase) ne sont jamais mises en cache ici : la page garde elle-même
   la liste des billets et les entrées en attente d'envoi. */
const CACHE = "billets-v1-2026-10-23";
const LIBS = [
  "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.115.0/dist/umd/supabase.js",
  "https://cdn.jsdelivr.net/npm/qrious@4.0.2/dist/qrious.min.js",
  "https://cdn.jsdelivr.net/npm/html5-qrcode@2.3.8/html5-qrcode.min.js",
  "https://cdn.jsdelivr.net/npm/jspdf@2.5.1/dist/jspdf.umd.min.js",
];
self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then(async (c) => {
    await c.add(new Request("./", { cache: "reload" })).catch(() => {});
    await Promise.all(LIBS.map((u) => c.add(new Request(u, { mode: "cors", credentials: "omit" })).catch(() => {})));
  }).then(() => self.skipWaiting()));
});
self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys().then((k) => Promise.all(k.filter((n) => n.startsWith("billets-") && n !== CACHE).map((n) => caches.delete(n)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", (e) => {
  const r = e.request;
  if (r.method !== "GET") return;
  const u = new URL(r.url);
  // Page : réseau d'abord (toujours la dernière version), copie locale si hors ligne.
  if (r.mode === "navigate" && u.origin === self.location.origin) {
    e.respondWith(fetch(r).then((rep) => {
      if (rep.ok) { const cp = rep.clone(); caches.open(CACHE).then((c) => c.put("./", cp)); }
      return rep;
    }).catch(() => caches.match("./", { ignoreSearch: true }).then((m) => m || caches.match(r, { ignoreSearch: true }))));
    return;
  }
  // Librairies figées (versions exactes) : copie locale d'abord.
  if (u.hostname === "cdn.jsdelivr.net" || u.hostname === "fonts.googleapis.com" || u.hostname === "fonts.gstatic.com") {
    e.respondWith(caches.match(r).then((m) => m || fetch(r).then((rep) => {
      if (rep.ok || rep.type === "opaque") { const cp = rep.clone(); caches.open(CACHE).then((c) => c.put(r, cp)); }
      return rep;
    })));
  }
});
