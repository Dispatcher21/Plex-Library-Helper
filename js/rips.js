// MakeMKV rip progress, published by the Library Helper to a private ntfy topic (<topic>-status); the
// auto-compress switch goes back on <topic>-cmd. The topic is stored in this browser only: it arrives via
// the link the helper's setup prints (…/#ntfy=<topic>, never sent to the website) or is pasted in Jobs.
// Nothing here needs Plex, so it works from anywhere.

const KEY = 'pld.ntfy';

export function channel() {
  try { const c = JSON.parse(localStorage.getItem(KEY) || 'null'); return c?.topic ? c : null; } catch { return null; }
}
export function connect(topic, server = 'https://ntfy.sh') {
  const t = String(topic || '').trim().replace(/^.*#ntfy=/, '').replace(/[&?].*$/, '');
  if (!/^[\w-]{6,64}$/.test(t)) return false;
  try { localStorage.setItem(KEY, JSON.stringify({ topic: t, server: server.replace(/\/$/, '') })); } catch { return false; }
  return true;
}
export function disconnect() { try { localStorage.removeItem(KEY); } catch { /* ignore */ } }

// Opened from the setup link: remember the topic, then take it out of the address bar
export function takeFromUrl() {
  const m = /[#&]ntfy=([\w-]+)/.exec(location.hash);
  if (!m) return false;
  const s = /[#&]server=([^&]+)/.exec(location.hash);
  const ok = connect(m[1], s ? decodeURIComponent(s[1]) : undefined);
  history.replaceState(null, '', location.pathname + location.search);
  return ok;
}

let latest = null; let source = null; let onChange = () => {};
export function status() { return latest; }

function take(msg) {
  if (msg?.event !== 'message') return;
  try { const s = JSON.parse(msg.message); if (s?.kind === 'rip') { latest = { ...s, received: Date.now() }; onChange(latest); } } catch { /* not ours */ }
}

// Last status from the past two hours, then live updates
export async function start(changed) {
  onChange = changed || onChange;
  stop();
  const c = channel(); if (!c) return;
  try {
    const r = await fetch(`${c.server}/${c.topic}-status/json?poll=1&since=2h`);
    if (r.ok) for (const line of (await r.text()).split('\n')) { if (line.trim()) take(JSON.parse(line)); }
  } catch { /* offline: the live stream below retries */ }
  try {
    source = new EventSource(`${c.server}/${c.topic}-status/sse`);
    source.onmessage = (ev) => { try { take(JSON.parse(ev.data)); } catch { /* ignore */ } };
  } catch { /* browsers without EventSource just get the first read */ }
}
export function stop() { source?.close(); source = null; }

export async function setAutoCompress(id, on) {
  const c = channel(); if (!c) throw new Error('Not connected to the helper\'s ntfy topic.');
  const r = await fetch(c.server, { method: 'POST', body: JSON.stringify({ topic: `${c.topic}-cmd`, message: JSON.stringify({ cmd: 'autocompress', id, on }), priority: 1 }) });
  if (!r.ok) throw new Error(`ntfy said ${r.status}`);
  if (latest?.id === id) { latest = { ...latest, autoCompress: on }; onChange(latest); }
}

// How to show it: 'ripping' | 'stale' (no word for a while) | 'done' (recently) | null (nothing to show)
export function phase(s, now = Date.now()) {
  if (!s) return null;
  const age = (now - new Date(s.time).getTime()) / 1000;
  if (s.state === 'done') return age < 3600 ? 'done' : null;
  if (s.state === 'ripping') return age < 180 ? 'ripping' : age < 6 * 3600 ? 'stale' : null;
  return null;
}

// Pretend rip for ?demo: a TV disc ripping episode by episode, finishing after a while
export function demo(changed) {
  onChange = changed || onChange;
  const started = Date.now(); const epBytes = 1.4 * 1024 ** 3;
  const tick = () => {
    const secs = (Date.now() - started) / 1000; const total = Math.min(100, secs * 2.2);
    const ep = Math.min(3, Math.floor(total / 25)); const cur = Math.min(99, (total % 25) * 4);
    const done = Array.from({ length: ep }, (_, i) => ({ file: `B1_t0${i}.mkv`, bytes: epBytes }));
    latest = total >= 100
      ? { kind: 'rip', id: 'demo', state: 'done', time: new Date().toISOString(), disc: 'AVATAR_BOOK3_D1', folder: 'Season 3', library: 'show', done: [...done, { file: 'B1_t03.mkv', bytes: epBytes }], autoCompress: latest?.autoCompress ?? false, elapsed: Math.round(secs) }
      : { kind: 'rip', id: 'demo', state: 'ripping', time: new Date().toISOString(), disc: 'AVATAR_BOOK3_D1', folder: 'Season 3', library: 'show', done, file: `B1_t0${ep}.mkv`, bytes: Math.round(epBytes * cur / 100), rate: 38 * 1024 ** 2, percent: cur, totalPercent: Math.round(total), exact: true, secsLeft: Math.round((100 - total) / 2.2), autoCompress: latest?.autoCompress ?? false, elapsed: Math.round(secs) };
    onChange(latest);
    if (total < 100) setTimeout(tick, 1500);
  };
  tick();
}
export function demoSet(on) { if (latest) { latest = { ...latest, autoCompress: on }; onChange(latest); } }
