// Only here so the dashboard can show system notifications (Android Chrome requires a service worker for
// them). It caches nothing and never touches requests.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

// Tapping a notification brings the dashboard back (or opens it)
self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  e.waitUntil((async () => {
    const tabs = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const tab = tabs.find((c) => c.url.startsWith(self.registration.scope));
    if (tab) return tab.focus();
    return self.clients.openWindow(self.registration.scope);
  })());
});
