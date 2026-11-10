/* TimeClock Admin — Service Worker (PWA del portal 24/7 Medical Aid)
   Estrategia DELIBERADAMENTE conservadora para no afectar las otras apps del
   mismo dominio (nomina, monitor, etc.): network-first en TODO lo del propio
   origen (si hay red, siempre gana la red → nunca sirve algo viejo ni rompe el
   flujo de actualización por version.txt); la caché solo es respaldo sin conexión.
   Lo de otros orígenes (Supabase, CDNs, fuentes) NO se intercepta. */
const CACHE = 'tc-admin-v1';
const SHELL = ['/reloj.html', '/manifest.json', '/icon-192.png', '/icon-512.png', '/icon-maskable-512.png',
  '/chat.html', '/manifest-chat.json', '/icon-chat-192.png', '/icon-chat-512.png', '/icon-chat-maskable-512.png'];

self.addEventListener('install', e => {
  self.skipWaiting();
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL).catch(() => {})));
});

self.addEventListener('activate', e => {
  e.waitUntil((async () => {
    const ks = await caches.keys();
    await Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  let url;
  try { url = new URL(req.url); } catch (_) { return; }
  if (url.origin !== self.location.origin) return;      // Supabase / CDNs / fuentes: pasar directo

  // version.txt: siempre red (no romper el aviso de actualización); respaldo caché
  if (url.pathname.endsWith('/version.txt')) {
    e.respondWith(fetch(req).catch(() => caches.match(req)));
    return;
  }

  // Todo lo demás del propio origen: network-first con respaldo en caché
  e.respondWith((async () => {
    try {
      const resp = await fetch(req);
      if (resp && resp.ok) {
        const copy = resp.clone();
        caches.open(CACHE).then(c => c.put(req, copy)).catch(() => {});
      }
      return resp;
    } catch (_) {
      const cached = await caches.match(req);
      if (cached) return cached;
      if (req.mode === 'navigate') return (await caches.match('/reloj.html')) || Response.error();
      return Response.error();
    }
  })());
});

/* (v294) Clic en una notificación del chat: enfocar una ventana existente de la
   app y avisarle para abrir esa conversación; si no hay ninguna, abrir la app. */
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const data = e.notification.data || {};
  e.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of all) {
      if (c.url && c.url.startsWith(self.location.origin)) {
        try { await c.focus(); } catch (_) {}
        try { c.postMessage({ tipo: 'notifClick', chatId: data.chatId || 0, k: data.k || '' }); } catch (_) {}
        return;
      }
    }
    try { await self.clients.openWindow('/?app=1&goto=reloj'); } catch (_) {}
  })());
});
