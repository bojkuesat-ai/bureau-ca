/* Espace CA — service worker minimal.
   Stratégie : RÉSEAU D'ABORD. On sert toujours la version en ligne ;
   le cache ne sert que de filet quand le réseau tombe.
   Objectif : rendre l'app installable (PWA) sans jamais servir une version périmée. */

const CACHE = "ca-v1";

self.addEventListener("install", () => self.skipWaiting());

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys()
      .then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;

  const url = new URL(req.url);
  /* On ne touche à rien d'externe : Supabase, edge functions, CDN passent en direct. */
  if (url.origin !== self.location.origin) return;

  e.respondWith(
    fetch(req)
      .then(res => {
        if (res && res.ok) {
          const copie = res.clone();
          caches.open(CACHE).then(c => c.put(req, copie)).catch(() => {});
        }
        return res;
      })
      .catch(() => caches.match(req).then(r => r || Response.error()))
  );
});

/* Permet de forcer la mise à jour depuis la page si besoin :
   navigator.serviceWorker.controller.postMessage("maj") */
self.addEventListener("message", (e) => { if (e.data === "maj") self.skipWaiting(); });
