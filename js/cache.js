// Remembers the last scan of each server in IndexedDB, so the library shows instantly
// and servers that are switched off still appear (marked "last seen").

const DB = 'plex-library-dashboard';
const STORE = 'servers';

function open() {
  return new Promise((resolve, reject) => {
    let req;
    try { req = indexedDB.open(DB, 1); } catch (e) { reject(e); return; }
    req.onupgradeneeded = () => req.result.createObjectStore(STORE, { keyPath: 'id' });
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function tx(mode, fn) {
  const db = await open();
  return new Promise((resolve, reject) => {
    const t = db.transaction(STORE, mode);
    const out = fn(t.objectStore(STORE));
    t.oncomplete = () => { db.close(); resolve(out?.result ?? out); };
    t.onerror = () => { db.close(); reject(t.error); };
  });
}

export async function loadAll() {
  try { return (await tx('readonly', (s) => s.getAll())) || []; } catch { return []; }
}
export async function save(snapshot) {
  try { await tx('readwrite', (s) => s.put(snapshot)); } catch { /* storage unavailable: run without cache */ }
}
export async function clear() {
  try { await tx('readwrite', (s) => s.clear()); } catch { /* ignore */ }
}
