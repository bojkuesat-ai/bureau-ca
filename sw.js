/* Service worker — app CA (installable + hors-ligne) */
const CACHE = "ca-v1";
const PRE = ["./", "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"];
self.addEventListener("install", e => { self.skipWaiting();
  e.waitUntil(caches.open(CACHE).then(c => Promise.allSettled(PRE.map(u => c.add(u))))); });
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k!==CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim())); });
const BYPASS = /supabase\.co|\/caisse\//;   // API Supabase + app Caisse : jamais interceptés
self.addEventListener("fetch", e => {
  const req = e.request; if(req.method !== "GET") return;
  let url; try { url = new URL(req.url); } catch(_) { return; }
  if(BYPASS.test(url.href)) return;
  const cacheable = url.origin === self.location.origin || /cdn\.jsdelivr\.net|fonts\.googleapis\.com|fonts\.gstatic\.com/.test(url.href);
  if(req.mode === "navigate"){
    e.respondWith(fetch(req).then(r => { const c = r.clone(); caches.open(CACHE).then(x => x.put(req, c)); return r; })
      .catch(() => caches.match(req).then(m => m || caches.match("./"))));
    return;
  }
  e.respondWith(caches.match(req).then(hit => hit || fetch(req).then(r => {
    if(cacheable && r && r.status === 200){ const c = r.clone(); caches.open(CACHE).then(x => x.put(req, c)); }
    return r;
  }).catch(() => caches.match(req))));
});
