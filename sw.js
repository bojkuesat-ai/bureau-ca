/* Service worker — contrôle d'entrée QR (mode hors-ligne) */
const CACHE = "qrentry-v176";
const PRECACHE = [
  "./",
  "https://cdnjs.cloudflare.com/ajax/libs/qrious/4.0.2/qrious.min.js",
  "https://cdnjs.cloudflare.com/ajax/libs/html5-qrcode/2.3.8/html5-qrcode.min.js",
  "https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.1/jspdf.umd.min.js"
];

self.addEventListener("install", function(e){
  self.skipWaiting();
  e.waitUntil(caches.open(CACHE).then(function(c){
    return Promise.allSettled(PRECACHE.map(function(u){ return c.add(u); }));
  }));
});

self.addEventListener("activate", function(e){
  e.waitUntil(
    caches.keys().then(function(keys){
      return Promise.all(keys.filter(function(k){ return k!==CACHE; }).map(function(k){ return caches.delete(k); }));
    }).then(function(){ return self.clients.claim(); })
  );
});

// Les appels d'API doivent toujours passer par le réseau (jamais servis depuis le cache)
const BYPASS = /(firestore|identitytoolkit|securetoken)\.googleapis\.com|supabase\.co|esm\.sh/;

self.addEventListener("fetch", function(e){
  const req = e.request;
  if(req.method !== "GET") return;
  let url;
  try { url = new URL(req.url); } catch(_) { return; }
  if(BYPASS.test(url.href)) return; // réseau direct

  const cacheable = (url.origin === self.location.origin) ||
                    /cdnjs\.cloudflare\.com|fonts\.googleapis\.com|fonts\.gstatic\.com/.test(url.href);

  // Navigation (ouverture de la page) : réseau d'abord, puis cache si hors-ligne
  if(req.mode === "navigate"){
    e.respondWith(
      fetch(req, { cache:"no-store" }).then(function(r){   // toujours la dernière version publiée
        const clone = r.clone();
        caches.open(CACHE).then(function(c){ c.put("./", clone); });
        return r;
      }).catch(function(){ return caches.match("./"); })
    );
    return;
  }

  // Ressources : cache d'abord, sinon réseau (et on met en cache si pertinent)
  e.respondWith(
    caches.match(req).then(function(hit){
      if(hit) return hit;
      return fetch(req).then(function(r){
        if(cacheable && r && r.status === 200){
          const clone = r.clone();
          caches.open(CACHE).then(function(c){ c.put(req, clone); });
        }
        return r;
      }).catch(function(){ return caches.match(req); });
    })
  );
});

self.addEventListener("message", function(e){ if(e.data==="skipWaiting") self.skipWaiting(); });
