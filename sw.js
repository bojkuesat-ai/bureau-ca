/* Service worker du CA (et de la Caisse, même dossier) :
   - pages : réseau d'abord ; si le réseau traîne (> 3,5 s) ou manque, dernière version gardée ;
   - librairies à version figée (jsDelivr) et polices : gardées sur l'appareil ;
   - Supabase et tout le reste : jamais touchés (toujours en direct) ;
   - notifications sur le téléphone. */
const CACHE = "ca-v1-2026-10-23";
self.addEventListener("install", e => { self.skipWaiting(); });
self.addEventListener("activate", e => {
  e.waitUntil((async () => {
    for (const k of await caches.keys()) if (k !== CACHE && k.startsWith("ca-")) await caches.delete(k);
    await self.clients.claim();
  })());
});
function figee(u) {
  return (u.hostname === "cdn.jsdelivr.net" && /@\d+\.\d+\.\d+/.test(u.pathname)) || u.hostname === "fonts.gstatic.com" || u.hostname === "fonts.googleapis.com";
}
self.addEventListener("fetch", e => {
  const r = e.request; if (r.method !== "GET") return;
  const u = new URL(r.url);
  if (r.mode === "navigate" && u.origin === self.location.origin && !u.pathname.includes("/billets/")) {
    e.respondWith((async () => {
      const c = await caches.open(CACHE);
      const reseau = fetch(r).then(rep => { if (rep && rep.ok) c.put(r, rep.clone()).catch(() => {}); return rep; });
      const garde = await c.match(r, { ignoreSearch: true });
      if (!garde) return reseau;
      const lent = new Promise(ok => setTimeout(() => ok(null), 3500));
      try { const rep = await Promise.race([reseau, lent]); if (rep) return rep; } catch (_) { /* hors ligne */ }
      reseau.catch(() => {});
      return garde;
    })());
    return;
  }
  if (figee(u)) {
    e.respondWith((async () => {
      const c = await caches.open(CACHE);
      const garde = await c.match(r); if (garde) return garde;
      const rep = await fetch(r);
      if (rep && (rep.ok || rep.type === "opaque")) c.put(r, rep.clone()).catch(() => {});
      return rep;
    })());
  }
});
self.addEventListener("push", e => {
  let d = {}; try { d = e.data ? e.data.json() : {}; } catch (_) { d = { corps: e.data ? e.data.text() : "" }; }
  e.waitUntil(self.registration.showNotification(d.titre || "Bureau étudiant", {
    body: d.corps || "", tag: d.tag || undefined, renotify: !!d.tag, data: { url: d.url || self.registration.scope }
  }));
});
self.addEventListener("notificationclick", e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || self.registration.scope;
  e.waitUntil((async () => {
    const l = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const c of l) { if (c.url.split("#")[0] === url.split("#")[0] && "focus" in c) return c.focus(); }
    return self.clients.openWindow(url);
  })());
});
