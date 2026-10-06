// Service worker: nodig om de site als app te kunnen installeren, en voor de dagelijkse herinnering.
// Er wordt niets bewaard: alles komt altijd vers van het internet.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', () => {});

// Pushmelding tonen (verstuurd door de functie rizz-push in Supabase)
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Rizz Academy', {
    body: d.body || '',
    icon: 'img/icon-192.png',
    badge: 'img/icon-192.png',
    tag: d.tag || 'rizz',
    renotify: true,
    data: { url: d.url || './' },
  }));
});

// Tik op de melding: open de app (of breng ze naar voor)
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || './', self.registration.scope).href;
  e.waitUntil((async () => {
    const list = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of list) {
      if ('focus' in c) {
        try { if ('navigate' in c) await c.navigate(url); } catch (_) { /* niet erg */ }
        return c.focus();
      }
    }
    return self.clients.openWindow(url);
  })());
});
