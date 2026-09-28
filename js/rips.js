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

// Everything else on the channel, newest per PC: what each helper is doing (kind 'helper'), what's waiting
// in its _TO_DELETE ('trash'), what it can compress with and its benchmark results ('caps'), and answers to
// 'empty' requests ('trashResult', by request id)
const byPc = { helper: {}, trash: {}, caps: {}, torrents: {} }; const results = {};
export function helpers() { return Object.values(byPc.helper).sort((a, b) => a.pc.localeCompare(b.pc)); }
export function trashes() { return Object.values(byPc.trash).filter((t) => t.batches?.length).sort((a, b) => a.pc.localeCompare(b.pc)); }
export function result(req) { return results[req] || null; }
// qBittorrent on each PC (kind 'torrents'): newest report per PC, only recent ones
export function torrents() { return Object.values(byPc.torrents).filter((t) => Date.now() - new Date(t.time).getTime() < 70 * 60000).sort((a, b) => a.pc.localeCompare(b.pc)); }
export function caps(pc) { return pc ? byPc.caps[pc] || null : Object.values(byPc.caps).filter((c) => c.compress).sort((a, b) => a.pc.localeCompare(b.pc)); }

function take(msg) {
  if (msg?.event !== 'message') return;
  let s; try { s = JSON.parse(msg.message); } catch { return; }
  if (s?.kind === 'rip') { latest = { ...s, received: Date.now() }; onChange(latest); }
  else if (s?.kind === 'helper' || s?.kind === 'trash' || s?.kind === 'caps' || s?.kind === 'torrents') {
    const old = byPc[s.kind][s.pc];
    if (!old || new Date(s.time) >= new Date(old.time)) { byPc[s.kind][s.pc] = s; onChange(latest); }
  } else if (s?.kind === 'trashResult') { results[s.req] = s; onChange(latest); }
}

// Commands for the helpers (<topic>-cmd); each helper acts only on ones naming its PC
export async function command(obj) {
  const c = channel(); if (!c) throw new Error('This device isn\'t connected to the helper\'s ntfy topic yet (Jobs > paste the link).');
  const r = await fetch(c.server, { method: 'POST', body: JSON.stringify({ topic: `${c.topic}-cmd`, message: JSON.stringify(obj), priority: 1 }) });
  if (!r.ok) throw new Error(`ntfy said ${r.status}`);
}

// Pretend helpers for ?demo
export function demoHelpers() {
  const now = new Date().toISOString(); const GB = 1024 ** 3;
  byPc.helper['GAMING-PC'] = { kind: 'helper', pc: 'GAMING-PC', version: '0.3.7', time: now, compress: true, paused: false, jobs: [{ title: 'Dune', mode: 'compress', preset: '4kh', percent: 37, secsLeft: 4200, what: 'Encoding' }] };
  byPc.helper['MEDIA-PC'] = { kind: 'helper', pc: 'MEDIA-PC', version: '0.3.7', time: now, compress: false, paused: false, jobs: [] };
  const lv = ['extreme', 'high', 'normal', 'saver'];
  byPc.caps['GAMING-PC'] = { kind: 'caps', pc: 'GAMING-PC', version: '0.3.9', time: now, compress: true, cpu: 'Intel(R) Core(TM) i7-10700 CPU @ 2.90GHz', threads: 16, gpus: ['AMD Radeon RX 6750 XT'], encoders: ['amf', 'x265', 'x265slow', 'svtav1'], allowCpu: true, levels: lv,
    calibration: { amf: { '4k': { fps: 37, q: [20.4, 22.6, 24.5, 27.3], kbps: [27500, 19200, 14600, 9400], src: 62000, time: now }, 1080: { fps: 140, q: [19, 21.5, 23.5, 27], kbps: [9800, 6900, 5200, 3300], src: 28000, time: now } },
      x265slow: { '4k': { fps: 1.1, q: [16.8, 18.9, 20.7, 24.1], kbps: [16000, 11800, 9000, 5600], src: 62000, time: now } }, svtav1: { '4k': { fps: 0.9, q: [24, 28, 31, 37], kbps: [12500, 9000, 7100, 4300], src: 62000, time: now } } }, bench: null };
  byPc.caps['MEDIA-PC'] = { kind: 'caps', pc: 'MEDIA-PC', version: '0.3.9', time: now, compress: true, cpu: 'Intel(R) N100', threads: 4, gpus: ['Intel(R) UHD Graphics'], encoders: ['qsv', 'x265', 'x265slow'], allowCpu: false, levels: lv,
    calibration: { qsv: { '4k': { fps: 14, q: [19.5, 21.8, 24, 28.5], kbps: [29000, 21000, 15500, 9800], src: 62000, time: now } } }, bench: { state: 'running', percent: 40, what: 'Benchmark 1080 - Intel graphics (Quick Sync, HEVC), setting 22: encoding' } };
  byPc.torrents['GAMING-PC'] = { kind: 'torrents', pc: 'GAMING-PC', time: now, running: true, slowed: true, why: 'Plex is transcoding a stream', byHelper: true, held: false, dl: 1_400_000, up: 60_000, downloading: 2, seeding: 5, total: 9,
    torrents: [{ name: 'Big.Buck.Bunny.2008.2160p.UHD', hash: 'a1', progress: 42.5, state: 'Downloading', dl: 1_200_000, up: 40_000, size: 12e9, eta: 4100, ratio: 0.1 },
      { name: 'Sintel.2010.1080p', hash: 'b2', progress: 88, state: 'Stalled', dl: 0, up: 0, size: 3e9, eta: null, ratio: 0.4 },
      { name: 'Tears.of.Steel.2012.4K', hash: 'c3', progress: 100, state: 'Seeding', dl: 0, up: 20_000, size: 5e9, eta: null, ratio: 1.7 }] };
  byPc.trash['MEDIA-PC'] = { kind: 'trash', pc: 'MEDIA-PC', time: now, total: 251 * GB, batches: [{ path: 'E:\\_TO_DELETE\\2026-09-26', drive: 'E:', date: '2026-09-26', bytes: 251 * GB, files: 5, titles: ['Pirates of the Caribbean: The Curse of the Black Pearl (2003)', 'Pirates of the Caribbean: Dead Man\'s Chest (2006)', 'Pirates of the Caribbean: At World\'s End (2007)', 'Pirates of the Caribbean: On Stranger Tides (2011)', 'Pirates of the Caribbean: Dead Men Tell No Tales (2017)'], more: 0 }] };
  byPc.trash['GAMING-PC'] = { kind: 'trash', pc: 'GAMING-PC', time: now, total: 250 * GB, batches: [{ path: 'E:\\_TO_DELETE\\2026-09-12', drive: 'E:', date: '2026-09-12', bytes: 86 * GB, files: 2, titles: ['Harry Potter and the Sorcerer\'s Stone (2001)'], more: 0 }, { path: 'G:\\_TO_DELETE\\2026-09-27', drive: 'G:', date: '2026-09-27', bytes: 164 * GB, files: 2, titles: ['Transformers (2007)', 'Transformers: Age of Extinction (2014)'], more: 0 }] };
}
export function demoCommand(obj) {
  if (obj.cmd === 'torrents') { const t = byPc.torrents[obj.pc]; if (t) byPc.torrents[obj.pc] = { ...t, held: obj.hold, slowed: obj.hold || t.why !== '', why: obj.hold ? 'paused from the tray or dashboard' : 'Plex is transcoding a stream' }; }
  if (obj.cmd === 'benchmark') { const c = byPc.caps[obj.pc]; if (c) byPc.caps[obj.pc] = { ...c, bench: obj.stop ? null : { state: 'waiting' } }; }
  if (obj.cmd === 'pause') { const h = byPc.helper[obj.pc]; if (h) byPc.helper[obj.pc] = { ...h, paused: obj.on, jobs: h.jobs.map((j) => ({ ...j, what: obj.on ? 'paused: paused from the tray or dashboard' : 'Encoding' })) }; }
  if (obj.cmd === 'emptytrash') setTimeout(() => {
    const t = byPc.trash[obj.pc]; const gone = t.batches.filter((b) => obj.batches.includes(b.path));
    byPc.trash[obj.pc] = { ...t, batches: t.batches.filter((b) => !obj.batches.includes(b.path)), total: t.total - gone.reduce((a, b) => a + b.bytes, 0) };
    results[obj.req] = { kind: 'trashResult', pc: obj.pc, req: obj.req, freed: gone.reduce((a, b) => a + b.bytes, 0), deleted: gone.map((b) => b.path), errors: [] };
    onChange(latest);
  }, 2500);
  onChange(latest);
}

// Last status from the past 12 hours (what ntfy.sh keeps; helpers send changes, not a stream), then live updates
export async function start(changed) {
  onChange = changed || onChange;
  stop();
  const c = channel(); if (!c) return;
  try {
    const r = await fetch(`${c.server}/${c.topic}-status/json?poll=1&since=12h`);
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
  // the helper sends rip progress every 3 minutes (and at once on changes)
  if (s.state === 'ripping') return age < 480 ? 'ripping' : age < 6 * 3600 ? 'stale' : null;
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
