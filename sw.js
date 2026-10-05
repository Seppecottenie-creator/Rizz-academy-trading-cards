// Minimale service worker: nodig om de site als app te kunnen installeren.
// Er wordt niets bewaard: alles komt altijd vers van het internet.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', () => {});
