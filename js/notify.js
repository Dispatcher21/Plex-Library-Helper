// "Tell me when it's done": system notifications while the dashboard is open (any device), plus a
// message inside the page that always works. Nothing is sent anywhere: the page notices finished jobs
// when it re-reads them from Plex.

const PREF = 'pld.notify';

export function supported() { return 'Notification' in window && window.isSecureContext; }
export function permission() { return supported() ? Notification.permission : 'unsupported'; }
export function wanted() { try { return localStorage.getItem(PREF) === 'on'; } catch { return false; } }
function setWanted(on) { try { localStorage.setItem(PREF, on ? 'on' : 'off'); } catch { /* ignore */ } }
export function enabled() { return wanted() && permission() === 'granted'; }

let reg = null;
async function registration() {
  if (reg || !('serviceWorker' in navigator)) return reg;
  try { reg = await navigator.serviceWorker.register('sw.js'); await navigator.serviceWorker.ready; } catch { reg = null; }
  return reg;
}

// Must be called from a click (browsers only ask for permission then). Resolves to true if notifications are on.
export async function turnOn() {
  if (!supported()) return false;
  const p = Notification.permission === 'default' ? await Notification.requestPermission() : Notification.permission;
  setWanted(p === 'granted');
  if (p === 'granted') await registration();
  return p === 'granted';
}
export function turnOff() { setWanted(false); }

export async function show(title, body, tag) {
  toast(title, body);
  if (!enabled()) return;
  const opts = { body, tag, renotify: true };
  try {
    const r = await registration();
    if (r) await r.showNotification(title, opts);   // Android Chrome only allows this route
    else new Notification(title, opts);
  } catch { /* the in-page message was shown anyway */ }
}

// In-page message, bottom corner, disappears after a while or on click
function toast(title, body) {
  let box = document.getElementById('toasts');
  if (!box) { box = document.createElement('div'); box.id = 'toasts'; box.setAttribute('aria-live', 'polite'); document.body.append(box); }
  const t = document.createElement('div');
  t.className = 'toast';
  t.innerHTML = '<b></b><span></span>';
  t.querySelector('b').textContent = title;
  t.querySelector('span').textContent = body;
  t.onclick = () => t.remove();
  box.append(t);
  setTimeout(() => t.remove(), 15000);
}
