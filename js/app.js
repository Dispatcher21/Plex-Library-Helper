import * as plex from './plex.js';
import * as cache from './cache.js';
import { demoSnapshots } from './demo.js';
import * as jobsApi from './jobs.js';
import * as cz from './compress.js';
import * as notify from './notify.js';
import * as rips from './rips.js';
import { normalizeMovies, normalizeEpisodes, buildMovies, buildShows, buildLocations, finishEntry, fmtSize, fmtBitrate, fmtAudio, GB } from './model.js';

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const PREFS = 'pld.prefs';

const state = {
  token: null, user: null, demo: false, syncing: false,
  servers: {},        // id -> { id, name, online, lastSeen, api }
  snapshots: [],      // per-server scan results
  movies: [], shows: [], locations: [],
  tab: 'movies', filter: 'all', loc: '', sort: 'title', q: '',
  jobs: [], demoJobs: null,
};

function loadPrefs() {
  try { Object.assign(state, JSON.parse(localStorage.getItem(PREFS) || '{}')); } catch { /* defaults */ }
}
function savePrefs() {
  const { tab, filter, loc, sort } = state;
  try { localStorage.setItem(PREFS, JSON.stringify({ tab, filter, loc, sort })); } catch { /* ignore */ }
}

function timeAgo(ms) {
  const s = Math.round((Date.now() - ms) / 1000);
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 86400) return `${Math.round(s / 3600)} h ago`;
  return `${Math.round(s / 86400)} d ago`;
}

// ---------- Data ----------

function rebuild() {
  const recs = state.snapshots;
  state.movies = buildMovies(recs.flatMap((s) => s.movies || []));
  state.shows = buildShows(recs.flatMap((s) => s.episodes || []));
  for (const s of recs) {
    const cur = state.servers[s.id] || {};
    state.servers[s.id] = { ...cur, id: s.id, name: s.name, online: !!cur.api || !!s.demo, lastSeen: s.lastSeen };
  }
  state.locations = buildLocations(state.movies, state.shows, state.servers);
  if (state.loc && !state.locations.some((l) => l.id === state.loc)) state.loc = '';
}

async function sync() {
  if (state.syncing || state.demo) return;
  state.syncing = true; $('refresh').disabled = true;
  status('Finding your Plex servers…');
  try {
    if (!state.user) {
      state.user = await plex.getUser(state.token).catch(() => null);
      renderAccount();
    }
    const servers = (await plex.getServers(state.token)).filter((s) => s.owned);
    if (!servers.length) banner("No Plex servers were found on this account. Only servers you own are shown.");
    const failures = []; const via = [];
    await Promise.all(servers.map(async (srv) => {
      try {
        status(`Connecting to ${srv.name}…`);
        const conn = await plex.connect(srv);
        const how = conn.relay ? 'Plex relay (slower)' : conn.local ? 'home network' : 'remote access';
        via.push(`${srv.name} via ${how}`);
        status(`Connected to ${srv.name} via ${how}. Reading libraries…`);
        const api = new plex.ServerApi(srv, conn);
        state.servers[srv.id] = { ...(state.servers[srv.id] || {}), id: srv.id, name: srv.name, api, online: true, relay: conn.relay };
        const sections = await api.sections();
        const movies = []; const episodes = [];
        for (const sec of sections) {
          if (sec.type === 'movie') {
            const items = await api.movies(sec.key, (n, t) => status(`${srv.name}: ${sec.title} ${n}${t ? `/${t}` : ''}`));
            movies.push(...normalizeMovies(items, srv, sec));
          } else if (sec.type === 'show') {
            status(`${srv.name}: ${sec.title}…`);
            const shows = await api.shows(sec.key);
            const eps = await api.episodes(sec.key, (n, t) => status(`${srv.name}: ${sec.title} ${n}${t ? `/${t}` : ''} episodes`));
            episodes.push(...normalizeEpisodes(eps, shows, srv, sec));
          }
        }
        const snap = { id: srv.id, name: srv.name, lastSeen: Date.now(), movies, episodes };
        state.snapshots = [...state.snapshots.filter((s) => s.id !== srv.id), snap];
        await cache.save(snap);
      } catch (err) {
        failures.push(`${srv.name}: ${err.message}`);
        state.servers[srv.id] = { ...(state.servers[srv.id] || {}), id: srv.id, name: srv.name, online: false, api: null };
      }
    }));
    rebuild(); render();
    relayTip(via.filter((v) => v.endsWith('Plex relay (slower)')).map((v) => v.replace(/ via Plex relay \(slower\)$/, '')));
    refreshJobs();
    if (failures.length && failures.length === servers.length && !state.snapshots.length) {
      banner(`Couldn't reach your Plex server. ${failures.join(' · ')} On home Wi-Fi, some routers (AT&T gateways especially) block Plex's secure local addresses: try mobile data, or set this device's DNS to 1.1.1.1 or dns.google.`);
    } else if (failures.length) banner(`Some servers couldn't be reached, so their last known contents are shown. ${failures.join(' · ')}`);
    else banner('');
    status(`Synced ${timeAgo(Date.now())}${via.length ? ` · ${via.join(', ')}` : ''}`);
  } catch (err) {
    banner(`Couldn't sync with Plex: ${err.message}`);
    status('Sync failed');
  } finally {
    state.syncing = false; $('refresh').disabled = false;
  }
}

// ---------- Filtering ----------

const MOVIE_CHIPS = [
  ['all', 'All'], ['dupes', 'Duplicates'], ['unmatched', 'Unmatched'], ['4K', '4K'], ['1080p', '1080p'], ['720p', '720p'], ['SD', 'SD / 480p'],
  ['remux', 'Remux / disc rip'], ['hdr', 'HDR / DV'], ['lossless', 'Lossless audio'], ['big', 'Over 30 GB'],
];
const SHOW_CHIPS = [['all', 'All'], ['dupes', 'Duplicate episodes'], ['missing', 'Missing episodes'], ['unmatched', 'Unmatched'], ['4K', '4K'], ['1080p', '1080p'], ['720p', '720p'], ['SD', 'SD / 480p'], ['big', 'Over 100 GB']];

function allVersions(e) { return e.kind === 'movie' ? e.versions : e.seasons.flatMap((s) => s.eps.flatMap((ep) => ep.versions)); }

function matches(e, f) {
  const vs = e.kind === 'movie' ? e.versions : null;
  switch (f) {
    case 'all': return true;
    case 'dupes': return e.dupes;
    case 'unmatched': return !!e.unmatched;
    case '4K': case '1080p': case '720p': case 'SD': return e.kind === 'movie' ? vs.some((v) => v.res === f) : e.res === f;
    case 'remux': return vs?.some((v) => v.src === 'Remux' || v.src === 'Disc rip');
    case 'hdr': return vs?.some((v) => v.hdr || v.dv);
    case 'lossless': return vs?.some((v) => v.lossless);
    case 'missing': return e.kind === 'show' && (e.missingEps > 0 || e.missingSeasons.length > 0);
    case 'big': return e.size > (e.kind === 'movie' ? 30 : 100) * GB;
    default: return true;
  }
}

function visible() {
  const list = state.tab === 'movies' ? state.movies : state.shows;
  const q = state.q.trim().toLowerCase();
  const out = list.filter((e) => matches(e, state.filter)
    && (!state.loc || e.locs.includes(state.loc))
    && (!q || e.title.toLowerCase().includes(q) || String(e.year || '').includes(q)));
  const by = {
    title: (a, b) => a.title.localeCompare(b.title, undefined, { sensitivity: 'base', ignorePunctuation: true }),
    size: (a, b) => b.size - a.size,
    extra: (a, b) => b.extra - a.extra || b.size - a.size,
    added: (a, b) => b.addedAt - a.addedAt,
    year: (a, b) => (b.year || 0) - (a.year || 0),
  }[state.sort] || (() => 0);
  return out.sort(by);
}

// ---------- Rendering ----------

function status(t) { $('sync').textContent = t; }

// Connected only through Plex's relay: at home that's nearly always the router (AT&T gateways especially)
// refusing to look up Plex's secure local addresses. Switching this device's DNS fixes it.
const TIP_HIDDEN = 'pld.relayTipHidden';
function relayTip(servers) {
  const el = $('tip');
  let hidden = false; try { hidden = localStorage.getItem(TIP_HIDDEN) === '1'; } catch { /* ignore */ }
  if (!servers.length || hidden) { el.hidden = true; return; }
  el.innerHTML = `<details><summary>ⓘ Slow connection to ${esc(servers.join(', '))} (Plex relay): how to fix</summary>
    <p>This device couldn't reach your Plex server directly, so Plex's servers are passing everything along. It works, but it's slower (and limits video quality in the Plex apps).</p>
    <p>On your home Wi-Fi, your router is probably blocking Plex's direct connection (AT&amp;T gateways do this). Point this device at Google's DNS instead:</p>
    <ul>
      <li><b>Android:</b> Settings → Connections → More connection settings → Private DNS → Private DNS provider hostname → <code>dns.google</code></li>
      <li><b>Windows PC:</b> Settings → Network &amp; internet → your connection → DNS server assignment → Edit → Manual: IPv4 <code>1.1.1.1</code> and <code>8.8.8.8</code>, and IPv6 <code>2606:4700:4700::1111</code> and <code>2001:4860:4860::8888</code> (both, or Windows keeps using the router)</li>
      <li><b>iPhone / iPad:</b> Settings → Wi-Fi → ⓘ next to your network → Configure DNS → Manual → <code>1.1.1.1</code>, <code>8.8.8.8</code></li>
    </ul>
    <p>Then reload this page: the line at the top should say “via home network”. Away from home, the relay is normal if Plex's remote access isn't reachable.</p></details>
    <button class="x" data-hidetip title="Don't show this again on this device" aria-label="Hide">×</button>`;
  el.hidden = false;
}
function banner(t) { const b = $('banner'); b.textContent = t; b.hidden = !t; }

function resBadge(res) { return `<span class="b ${res === '4K' ? 'k4' : res === 'SD' ? 'sd' : 'hd'}">${esc(res)}</span>`; }

function posterUrl(e, w = 240) {
  const srv = state.servers[e.thumbServer];
  return srv?.api && e.thumb ? srv.api.poster(e.thumb, w) : null;
}
function posterHtml(e, w) {
  const url = posterUrl(e, w);
  return `<div class="poster">${url ? `<img loading="lazy" alt="" src="${esc(url)}" onerror="this.remove()">` : ''}<div class="ph" ${url ? 'style="z-index:-1"' : ''}>${esc(e.title)}</div>`;
}

function cardBadges(e) {
  const b = [];
  if (e.unmatched) b.push('<span class="b sd" title="Plex couldn\'t identify this. Open it and use Fix match.">Unmatched</span>');
  if (e.kind === 'movie') {
    const v = e.best;
    b.push(resBadge(v.res));
    if (v.src === 'Remux' || v.src === 'Disc rip') b.push(`<span class="b">${v.src}</span>`);
    if (v.dv) b.push('<span class="b hdr">DV</span>'); else if (v.hdr) b.push('<span class="b hdr">HDR</span>');
    if (v.lossless) b.push('<span class="b">Lossless</span>');
  } else {
    b.push(resBadge(e.res));
    if (e.dv) b.push('<span class="b hdr">DV</span>'); else if (e.hdr) b.push('<span class="b hdr">HDR</span>');
  }
  return b.join('');
}

function cardHtml(e, i) {
  const dup = e.kind === 'movie'
    ? (e.dupes ? `<span class="b dup">${e.versions.length} copies</span>` : '')
    : (e.dupeEps ? `<span class="b dup">${e.dupeEps} dupe eps</span>` : '');
  const sub = e.kind === 'movie'
    ? `${e.year || 'Unknown year'} · ${fmtSize(e.size)}`
    : `${e.seasons.length} season${e.seasons.length === 1 ? '' : 's'} · ${e.epCount} eps · ${fmtSize(e.size)}`;
  return `<button class="card" data-i="${i}">
    ${posterHtml(e)}<div class="corner">${dup}</div></div>
    <h3 title="${esc(e.title)}">${esc(e.title)}</h3>
    <div class="sub">${esc(sub)}</div>
    <div class="badges">${cardBadges(e)}</div>
  </button>`;
}

let current = [];
function renderGrid() {
  current = visible();
  const total = state.tab === 'movies' ? state.movies.length : state.shows.length;
  const size = current.reduce((a, e) => a + e.size, 0);
  $('count').textContent = `${current.length} of ${total} ${state.tab} · ${fmtSize(size)}`;
  $('grid').innerHTML = current.length
    ? current.map(cardHtml).join('')
    : `<p class="empty">${total ? 'Nothing matches these filters.' : 'Nothing here yet. Rescan once your servers are online.'}</p>`;
}

function renderChips() {
  const chips = state.tab === 'movies' ? MOVIE_CHIPS : SHOW_CHIPS;
  if (!chips.some(([k]) => k === state.filter)) state.filter = 'all';
  const list = state.tab === 'movies' ? state.movies : state.shows;
  $('chips').innerHTML = chips.map(([k, label]) => {
    const n = list.filter((e) => matches(e, k)).length;
    return `<button class="chip ${state.filter === k ? 'on' : ''}" data-f="${k}">${esc(label)}<em>${n}</em></button>`;
  }).join('');
}

function locName(l) { return `${l.machine} · ${l.drive}`; }

function renderLocations() {
  const total = state.locations.reduce((a, l) => a + l.size, 0) || 1;
  $('locations').innerHTML = state.locations.map((l) => `
    <button class="loc ${state.loc === l.id ? 'on' : ''}" data-loc="${esc(l.id)}" title="Show only files on ${esc(locName(l))}">
      <div class="m"><span class="dot ${l.online ? '' : 'off'}"></span>${esc(l.machine)} · ${l.online ? 'online' : `last seen ${l.lastSeen ? timeAgo(l.lastSeen) : 'unknown'}`}</div>
      <div class="d">${esc(l.drive)}</div>
      <div class="s">${fmtSize(l.size)} in your library · ${l.files.toLocaleString()} files</div>
      <div class="bar"><i style="width:${Math.max(2, Math.round((l.size / total) * 100))}%"></i></div>
    </button>`).join('');
  $('loc').innerHTML = `<option value="">All drives</option>${state.locations.map((l) => `<option value="${esc(l.id)}" ${state.loc === l.id ? 'selected' : ''}>${esc(locName(l))}</option>`).join('')}`;
}

function renderStats() {
  const epCount = state.shows.reduce((a, s) => a + s.epCount, 0);
  const size = state.movies.reduce((a, m) => a + m.size, 0) + state.shows.reduce((a, s) => a + s.size, 0);
  const extra = state.movies.reduce((a, m) => a + m.extra, 0) + state.shows.reduce((a, s) => a + s.extra, 0);
  const dupes = state.movies.filter((m) => m.dupes).length + state.shows.filter((s) => s.dupes).length;
  $('stats').innerHTML = `
    <div class="stat"><span>Movies</span><b>${state.movies.length.toLocaleString()}</b></div>
    <div class="stat"><span>Shows · episodes</span><b>${state.shows.length} · ${epCount.toLocaleString()}</b></div>
    <div class="stat"><span>Library size</span><b>${fmtSize(size)}</b></div>
    <div class="stat"><span>In duplicates (${dupes} titles)</span><b>${fmtSize(extra)}</b></div>`;
  const waiting = rips.trashes().reduce((a, t) => a + t.total, 0);
  if (waiting) $('stats').innerHTML += `<button class="stat" data-openjobs title="See and empty _TO_DELETE"><span>Waiting in _TO_DELETE</span><b>${fmtSize(waiting)}</b></button>`;
}

function renderAccount() {
  const a = $('account');
  a.hidden = false;
  a.textContent = state.demo ? 'Exit demo' : 'Sign out';
  a.title = state.user ? `Signed in as ${state.user.username || state.user.title}` : '';
}

function render() {
  const signedIn = !!state.token || state.demo;
  $('login').hidden = signedIn;
  $('library').hidden = !signedIn;
  $('search').hidden = !signedIn;
  $('refresh').hidden = !signedIn || state.demo;
  $('jobs-btn').hidden = !signedIn;
  if (!signedIn) return;
  renderJobsButton();
  renderAccount();
  document.querySelectorAll('.tabs button').forEach((b) => b.setAttribute('aria-selected', String(b.dataset.tab === state.tab)));
  $('sort').value = state.sort;
  renderStats(); renderLocations(); renderChips(); renderGrid();
}

// ---------- Detail ----------

// Latest quarantine job for a copy (kind 'quarantine'), or latest compression job with a given action ('c' / 'ce')
function jobFor(v, action) {
  return state.jobs.filter((j) => j.serverId === v.serverId && String(j.mediaId) === String(v.mediaId)
    && (action ? j.kind === 'compress' && j.action === action : j.kind === 'quarantine')).sort((a, b) => b.created - a.created)[0];
}
const ACTIVE = ['queued', 'run', 'stop'];
// The helper download is named by version (Plex-Library-Helper-0.4.0.exe; zips before 0.4); download/latest.json says which is current
let helperDownload = null;
function helperLink() {
  if (!helperDownload) return '<a href="https://github.com/Dispatcher21/Plex-Library-Helper/tree/main/download" target="_blank" rel="noopener">get the Library Helper</a>';
  return `<a href="download/${esc(helperDownload.file)}" download>get the Library Helper (${esc(helperDownload.version)})</a>`;
}
async function loadHelperDownload() {
  try { const r = await fetch('download/latest.json', { cache: 'no-cache' }); if (r.ok) helperDownload = await r.json(); } catch { /* the GitHub link is the fallback */ }
}

function quarantineAction(v, i) {
  const j = jobFor(v);
  if (j && j.state !== 'fail') {
    const label = { queued: 'Quarantine queued', run: 'Quarantining…', done: 'Quarantined' }[j.state] || j.state;
    const waiting = j.state === 'queued' && Date.now() - j.created > 90000 ? `<span class="fine">Waiting for the Library Helper on ${esc(v.machine)}. Is it running? Not installed yet? ${helperLink()}.</span>` : '';
    return `<span class="pill ${j.state}">${label}</span>${waiting}`;
  }
  const failed = j ? `<span class="pill fail" title="${esc(j.info)}">Last try failed: ${esc(j.info || 'unknown error')}</span>` : '';
  return `<button class="btn small danger" data-q="${i}">Quarantine this copy</button>${failed}`;
}

function compressAction(v, i, e) {
  if (jobFor(v)?.state === 'done') return '';
  if (v.compressed) {
    const originals = e.versions.filter((o) => o !== v && !o.compressed && !o.missing);
    return originals.length ? `<button class="btn small" data-replace="${i}" title="Quarantine the original${originals.length > 1 ? 's' : ''} and keep this compressed copy">Replace original…</button>` : '';
  }
  if (!cz.PRESETS.some((p) => cz.presetFits(p, v)) || ACTIVE.includes(jobFor(v, 'c')?.state)) return '';
  return `<button class="btn small" data-compress="${i}">Compress…</button>`;
}

// Progress / result of this copy's latest compression and estimate
function compressStatus(v) {
  const out = [];
  const c = jobFor(v, 'c');
  if (c && ACTIVE.includes(c.state)) out.push(progressHtml(c));
  else if (c?.state === 'done') {
    const o = cz.decodeInfo(c.info);
    out.push(`<div class="cstat"><span class="pill done">Compressed</span> ${esc(cz.presetById(o.p)?.label || '')}: ${fmtSize(Number(o.s) || v.size)} → <b>${fmtSize(Number(o.b))}</b>. The new copy appears here once Plex has scanned it; then choose <b>Replace original…</b> on it, or keep both.</div>`);
  } else if (c?.state === 'fail') out.push(`<div class="cstat"><span class="pill fail">Compression failed</span> ${esc(c.info)}</div>`);
  const est = jobFor(v, 'ce');
  if (est && (!c || est.created > c.created)) {
    if (ACTIVE.includes(est.state)) out.push(progressHtml(est));
    else if (est.state === 'done') {
      const o = cz.decodeInfo(est.info);
      out.push(`<div class="cstat"><span class="pill">Estimate</span> ${esc(cz.presetById(o.p)?.label || '')}: ${esc(cz.estimateText(est.info, v))}</div>`);
    } else if (est.state === 'fail') out.push(`<div class="cstat"><span class="pill fail">Estimate failed</span> ${esc(est.info)}</div>`);
  }
  return out.join('');
}

function progressHtml(j) {
  const est = j.action === 'ce';
  const preset = `${j.show ? `${scopeText(jobScope(j))} · ` : ''}${cz.presetById(cz.jobPreset(j))?.label || ''}`;
  const verb = est ? 'Estimating' : 'Compressing';
  if (j.state === 'queued') {
    const late = Date.now() - j.created > 90000 ? ` Waiting for the Library Helper on the PC with the graphics card. Is it running, and did you answer yes to compression in its setup? It also waits while another encode is running. Not installed yet? ${helperLink()}.` : '';
    return `<div class="cstat"><span class="pill queued">${verb} queued</span> ${esc(preset)}${late}</div>`;
  }
  if (j.state === 'stop') return `<div class="cstat"><span class="pill queued">Stopping…</span> ${esc(preset)}</div>`;
  const r = cz.parseRun(j.info);
  const left = r.secsLeft ? ` · about ${cz.fmtDuration(r.secsLeft)} left` : '';
  return `<div class="cstat"><div class="crow"><span class="pill run">${verb}</span><span>${esc(preset)} · ${Math.round(r.percent)}%${left}</span></div>
    <div class="bar"><i style="width:${Math.max(2, Math.min(100, r.percent))}%"></i></div>
    <div class="fine">${r.paused ? `Paused: ${esc(r.paused)}. It carries on by itself.` : r.what === verb ? '' : esc(r.what)}</div></div>`;
}

function versionActions(v, i, e) {
  if (v.missing) return '<div class="actions"><span class="pill fail">File missing</span><span class="fine">Plex still lists this copy, but the file is gone. It disappears after Plex\'s Empty Trash.</span></div>';
  if (!v.checked) return '<div class="actions"><button class="btn small danger" disabled>Checking the file…</button></div>';
  return `<div class="actions">${quarantineAction(v, i)}${compressAction(v, i, e)}</div>${compressStatus(v)}`;
}

function versionHtml(v, e, i, actions = false) {
  const srv = state.servers[v.serverId];
  const tags = [resBadge(v.res), `<span class="b">${esc(v.src)}</span>`];
  if (v.dv) tags.push('<span class="b hdr">Dolby Vision</span>'); else if (v.hdr) tags.push('<span class="b hdr">HDR</span>');
  if (v.lossless) tags.push('<span class="b">Lossless audio</span>');
  if (i === 0 && e.versions.length > 1) tags.push('<span class="b ok">Highest quality</span>');
  if (v.identical) tags.push('<span class="b dup">Identical to best</span>');
  return `<div class="ver ${i === 0 && e.versions.length > 1 ? 'best' : ''}">
    <div class="row1">${tags.join('')}<span class="size">${fmtSize(v.size)}</span></div>
    <div class="facts">
      <div><span>Video</span>${esc(v.videoLabel || `${v.vcodec || '?'} · ${v.height ? `${v.height}p` : v.res}`)}</div>
      <div><span>Audio</span>${esc(fmtAudio(v) || '—')}</div>
      <div><span>Bitrate</span>${fmtBitrate(v.bitrate)}</div>
      <div><span>Location</span>${esc(`${v.machine} · ${v.drive}`)}</div>
      <div><span>Plex server</span>${esc(srv?.name || '?')}${srv && !srv.online ? ' (offline)' : ''}</div>
    </div>
    ${v.files.map((f) => `<div class="path"><code>${esc(f)}</code><button class="btn small" data-copy="${esc(f)}">Copy</button></div>`).join('')}
    ${v.exact ? '' : '<div class="note">HDR, Dolby Vision and Atmos above are read from the file name until exact details load.</div>'}
    ${actions ? versionActions(v, i, e) : ''}
  </div>`;
}

function activeJob(v) { return ['queued', 'run', 'done'].includes(jobFor(v)?.state); }
function keepBestTargets(e) {
  // Only real, still-present copies below the best one, and never before every copy has been checked.
  // Compressed copies are left out: you made those on purpose (use "Replace original" on them instead).
  if (!e.versions.every((v) => v.checked) || e.best.missing) return null;
  return e.versions.slice(1).filter((v) => !v.missing && !v.compressed && !activeJob(v));
}

function movieDetail(e) {
  const rest = keepBestTargets(e);
  const missing = e.versions.filter((v) => v.missing).length;
  const save = rest === null
    ? (e.versions.length > 1 ? '<div class="save"><span class="fine">Checking which copies still exist on disk…</span></div>' : '')
    : rest.length ? `<div class="save"><span>Keeping only the highest-quality copy would free <b>${fmtSize(rest.reduce((a, v) => a + v.size, 0))}</b>.</span><button class="btn small danger" data-keepbest>Keep highest quality, quarantine the rest</button></div>` : '';
  return `<div class="db">
    ${missing ? `<div class="banner">${missing} cop${missing === 1 ? 'y Plex lists no longer exists' : 'ies Plex lists no longer exist'} on disk, so ${missing === 1 ? 'it isn\'t' : 'they aren\'t'} counted as duplicates. Remove the old folder from the library in Plex and run Empty Trash to clear ${missing === 1 ? 'it' : 'them'}.</div>` : ''}
    ${e.versions.map((v, i) => versionHtml(v, e, i, true)).join('')}
    ${save}
    <p class="note">Quarantine moves a copy's files into a <code>_TO_DELETE</code> folder on the same drive, done by the Library Helper running on that PC. Nothing is deleted: you can put files back, and you empty <code>_TO_DELETE</code> yourself.</p>
  </div>`;
}

// ---------- Jobs ----------

let jobTimer = null;
let lastStates = new Map(); // job -> state at the previous refresh, to spot jobs that just finished
async function refreshJobs() {
  const before = new Map(state.jobs.map((j) => [j.tag.split(':').slice(0, 2).join(':'), j.state]));
  if (state.demo) {
    state.jobs = [...(state.demoJobs?.jobs || [])];
  } else {
    const all = [];
    await Promise.all(Object.values(state.servers).filter((s) => s.api).map(async (s) => {
      try { all.push(...await jobsApi.fetchJobs(s.api, s.id)); } catch (err) { console.warn(`Couldn't read jobs from ${s.name}`, err); }
    }));
    state.jobs = all;
  }
  // A finished quarantine or compression changes files, so rescan (estimates don't)
  const finished = state.jobs.some((j) => j.state === 'done' && j.action !== 'ce' && before.get(j.tag.split(':').slice(0, 2).join(':')) !== 'done' && before.size);
  // Compressions / estimates that finished since the last look (only ones this page saw running or queued).
  // Compared with the states remembered last time, not `before`: demo jobs change in place.
  const jobKey = (j) => j.tag.split(':').slice(0, 2).join(':').toLowerCase();
  for (const j of state.jobs) {
    const was = lastStates.get(jobKey(j));
    if (j.kind === 'compress' && was && was !== j.state && (j.state === 'done' || j.state === 'fail')) announce(j);
  }
  lastStates = new Map(state.jobs.map((j) => [jobKey(j), j.state]));
  renderJobsButton();
  if ($('jobs').open) renderJobs();
  if (openEntry) renderDetail();
  if ($('compress').open) renderCompress();
  clearTimeout(jobTimer);
  if (state.jobs.some((j) => ACTIVE.includes(j.state))) jobTimer = setTimeout(refreshJobs, state.demo ? 1000 : 10000);
  if (finished && !state.demo) setTimeout(sync, 8000); // let Plex notice the change, then rescan
}

function announce(j) {
  const v = findVersion(j);
  const name = `${j.title}${j.year ? ` (${j.year})` : ''}${j.show ? ` · ${scopeText(jobScope(j))}` : ''}`;
  const o = cz.decodeInfo(j.info);
  const preset = cz.presetById(o.p)?.label || 'Compression';
  if (j.state === 'fail') {
    if (/stopped from the dashboard/i.test(j.info)) return; // you did that yourself
    notify.show(`${j.action === 'ce' ? 'Estimate' : 'Compression'} failed: ${name}`, j.info || 'Unknown error', j.id);
  } else if (j.action === 'ce') {
    notify.show(`Estimate ready: ${name}`, `${preset}: ${cz.estimateText(j.info, v)}`, j.id);
  } else {
    const eps = o.c ? `${o.n} of ${o.c} episodes, ` : '';
    notify.show(`Compressed: ${name}`, `${preset}: ${eps}${fmtSize(Number(o.s) || v?.size || 0)} → ${fmtSize(Number(o.b))}${Number(o.f) ? ` (${o.f} not done)` : ''}. The new cop${o.c ? 'ies are' : 'y is'} next to the original${o.c ? 's' : ''} in Plex.`, j.id);
  }
}

// ---------- MakeMKV rips (rips.js) ----------

let lastRipPhase = null;
function renderRip() {
  const el = $('ripcard'); const s = rips.status(); const ph = rips.phase(s);
  if (ph === 'done' && lastRipPhase === 'ripping') {
    const total = (s.done || []).reduce((a, d) => a + d.bytes, 0);
    notify.show(`Rip finished: ${s.folder}`, `${(s.done || []).length} file(s), ${fmtSize(total)}${s.autoCompress ? '. Compression will be queued once Plex has it.' : ''}`, `rip-${s.id}`);
  }
  if (ph) lastRipPhase = ph;
  if (!ph) { el.hidden = true; return; }
  const doneBytes = (s.done || []).reduce((a, d) => a + d.bytes, 0);
  const auto = s.library === 'show'
    ? '<span class="fine">TV rip: MakeMKV names episodes by title number, so name them first, then compress the season from the show.</span>'
    : `<label class="ripauto"><input type="checkbox" data-ripauto="${esc(s.id)}" ${s.autoCompress ? 'checked' : ''}> Compress when finished</label>`;
  if (ph === 'done') {
    el.innerHTML = `<div class="rhead"><span class="pill done">Rip finished</span><b>${esc(s.folder)}</b><span class="fine">${esc(s.disc || '')} · ${timeAgo(new Date(s.time).getTime())}</span></div>
      <div class="fine">${(s.done || []).length} file${(s.done || []).length === 1 ? '' : 's'} · ${fmtSize(doneBytes)} in ${cz.fmtDuration(s.elapsed)}${(s.done || []).length ? ` · ${esc(s.done.map((d) => d.file).join(', '))}` : ''}</div>
      <div class="actions">${auto}</div>`;
  } else {
    const pct = s.exact && s.totalPercent !== undefined ? s.totalPercent : s.percent;
    const stale = ph === 'stale';
    el.innerHTML = `<div class="rhead"><span class="pill ${stale ? 'queued' : 'run'}">${stale ? 'No update' : 'Ripping'}</span><b>${esc(s.folder)}</b><span class="fine">${esc(s.disc || '')}</span></div>
      ${pct !== undefined ? `<div class="bar"><i style="width:${Math.max(2, Math.min(100, pct))}%"></i></div>` : ''}
      <div class="fine">${stale ? `Nothing heard from the helper for ${timeAgo(new Date(s.time).getTime()).replace(' ago', '')}: MakeMKV closed, or the PC asleep? · ` : ''}
        ${pct !== undefined ? `${s.exact ? '' : '~'}${Math.round(pct)}%${s.exact && s.totalPercent !== undefined ? ' of the whole rip' : ''} · ` : ''}${esc(s.file || '')} · ${fmtSize(s.bytes || 0)}${s.rate ? ` · ${fmtSize(s.rate)}/s` : ''}${s.secsLeft ? ` · about ${cz.fmtDuration(s.secsLeft)} left` : ''}${(s.done || []).length ? ` · ${s.done.length} title${s.done.length === 1 ? '' : 's'} done` : ''}${s.exact ? '' : ' · % estimated from the disc'}</div>
      <div class="actions">${auto}</div>`;
  }
  el.hidden = false;
}

// ---------- Helpers on the live channel: pause switch and _TO_DELETE ----------

// Called whenever something arrives on the channel
function liveChanged() {
  renderRip();
  if (!$('library').hidden) renderStats();
  if ($('jobs').open) renderJobs();
  if ($('confirm').open && pendingTrash) renderTrashConfirm();
}

function helperLine(h) {
  const stale = Date.now() - new Date(h.time).getTime() > 12 * 60000;   // helpers report at least every 5 min
  const jobs = (h.jobs || []).map((j) => `${j.mode === 'estimate' ? 'estimating' : j.mode === 'benchmark' ? 'benchmark' : 'compressing'} ${j.mode === 'benchmark' ? '' : `${esc(j.title)} `}${j.percent}%${j.secsLeft ? ` (about ${cz.fmtDuration(j.secsLeft)} left)` : ''}${/^paused/.test(j.what || '') ? ` · ${esc(j.what)}` : ''}`);
  const doing = stale ? `not heard from since ${timeAgo(new Date(h.time).getTime())}` : jobs.length ? jobs.join(', ') : h.paused ? 'compressions paused' : 'idle';
  const btn = h.compress && !stale ? `<button class="btn small ${h.paused ? 'primary' : ''}" data-hpause="${esc(h.pc)}" data-on="${h.paused ? 0 : 1}">${h.paused ? 'Resume compressions' : 'Pause all compressions'}</button>` : '';
  return `<div class="liverow"><span><b>${esc(h.pc)}</b> <span class="fine">helper ${esc(h.version || '?')}</span> · ${doing}</span>${btn}</div>${stale ? '' : capsLine(rips.caps(h.pc))}`;
}

// What a compressing PC can use, how fast each measured (from its benchmark), and the benchmark button
function capsLine(cap) {
  if (!cap?.compress) return '';
  const cal = cap.calibration || {};
  const tierName = (tr) => (tr === '4k' ? '4K' : '1080p');
  const fps = (n) => (n >= 10 ? Math.round(n) : Number(n).toFixed(1));
  const encs = (cap.encoders || []).filter((id) => cz.ENCODERS[id] && (!cz.ENCODERS[id].cpu || cap.allowCpu));
  const parts = encs.map((id) => {
    const t = ['4k', '1080'].filter((tr) => cal[id]?.[tr]).map((tr) => (cal[id][tr].skip ? `${tierName(tr)} too slow` : `${tierName(tr)} ${fps(cal[id][tr].fps)} fps`));
    return `${esc(cz.ENCODERS[id].label)}${t.length ? ` (${t.join(', ')})` : ''}`;
  });
  const times = Object.values(cal).flatMap((tiers) => Object.values(tiers).map((m) => new Date(m.time).getTime())).filter(Boolean);
  const b = cap.bench;
  const bench = b?.state === 'running' ? `<b>benchmark ${b.percent}%</b>${/^paused/.test(b.what || '') ? ` · ${esc(b.what)}` : ''}`
    : b?.state === 'waiting' ? 'benchmark starts when the running jobs finish'
      : times.length ? `benchmarked ${timeAgo(Math.max(...times))}` : 'not benchmarked yet (runs by itself when the PC is idle)';
  const btn = b?.state ? `<button class="btn small ghost" data-bench="${esc(cap.pc)}" data-bstop="1">Stop benchmark</button>`
    : `<button class="btn small ghost" data-bench="${esc(cap.pc)}">${times.length ? 'Benchmark again' : 'Run benchmark'}</button>`;
  return `<div class="liverow capsrow"><span class="fine">${parts.join(' · ') || 'no encoders found'}${cap.allowCpu ? '' : ' · no processor-only jobs'} · ${bench}</span>${btn}</div>`;
}

function trashLine(t) {
  return `<div class="liverow"><span><b>${esc(t.pc)}</b> · ${fmtSize(t.total)} in ${t.batches.length} batch${t.batches.length === 1 ? '' : 'es'}
    <span class="fine">${t.batches.map((b) => `${esc(b.drive)} ${esc(b.date)} ${fmtSize(b.bytes)}`).join(' · ')}</span></span>
    <button class="btn small danger" data-trash="${esc(t.pc)}">Empty…</button></div>`;
}

function liveSection() {
  if (!rips.channel() && !state.demo) return '';
  const hs = rips.helpers(); const ts = rips.trashes();
  return `${hs.length ? `<h3 class="ch">Library Helpers</h3>${hs.map(helperLine).join('')}` : ''}
    ${ts.length ? `<h3 class="ch">Waiting in _TO_DELETE</h3>${ts.map(trashLine).join('')}<p class="fine">Quarantined files wait here so you can put them back; emptying deletes them for good.</p>` : ''}`;
}

let pendingTrash = null;
function openTrashConfirm(pc) {
  const t = rips.trashes().find((x) => x.pc === pc); if (!t) return;
  pending = null; pendingShow = null;
  pendingTrash = { pc, selected: new Set(t.batches.map((b) => b.path)), typed: '', req: null, sending: false, error: '' };
  renderTrashConfirm();
  $('confirm').showModal();
}

function renderTrashConfirm() {
  const p = pendingTrash; const t = rips.trashes().find((x) => x.pc === p.pc) || { batches: [] };
  const res = p.req ? rips.result(p.req) : null;
  let body;
  if (res) {
    body = `<h2 style="margin:0 0 4px">Emptied _TO_DELETE on ${esc(p.pc)}</h2>
      <p>Freed <b>${fmtSize(res.freed)}</b>${res.deleted?.length ? ` (${res.deleted.length} batch${res.deleted.length === 1 ? '' : 'es'})` : ''}.</p>
      ${res.errors?.length ? `<p class="warn">${esc(res.errors.join(' · '))}</p>` : ''}
      <div class="foot"><button class="btn primary" data-close>Done</button></div>`;
  } else if (p.req) {
    body = `<h2 style="margin:0 0 4px">Emptying _TO_DELETE on ${esc(p.pc)}…</h2>
      <p class="fine">Waiting for the Library Helper on ${esc(p.pc)} to do it and report back (usually under a minute). You can close this; the result also shows in Jobs.</p>
      <div class="foot"><button class="btn ghost" data-close>Close</button></div>`;
  } else {
    const old = (b) => (Date.now() - new Date(b.date).getTime()) / 86400000 > 7;
    const chosen = t.batches.filter((b) => p.selected.has(b.path));
    const total = chosen.reduce((a, b) => a + b.bytes, 0);
    body = `<h2 style="margin:0 0 4px">Empty _TO_DELETE on ${esc(p.pc)}?</h2>
      <p class="fine">This <b>permanently deletes</b> the chosen batches. They can't be put back afterwards.</p>
      <div class="actions"><button class="btn small ghost" data-tsel="all">All</button><button class="btn small ghost" data-tsel="old">Older than 7 days</button><button class="btn small ghost" data-tsel="none">None</button></div>
      <ul>${t.batches.map((b) => `<li><label class="tbatch"><input type="checkbox" data-tb="${esc(b.path)}" ${p.selected.has(b.path) ? 'checked' : ''} ${b.links ? 'disabled' : ''}>
        <span><b>${esc(b.drive)} ${esc(b.date)} · ${fmtSize(b.bytes)}</b> · ${b.files} file${b.files === 1 ? '' : 's'}${old(b) ? '' : ' · <span class="fine">less than a week old</span>'}${b.links ? ' · <span class="warn">contains a link: empty it at the PC</span>' : ''}
        ${(b.titles || []).length ? `<code>${esc(b.titles.join(', '))}${b.more ? ` and ${b.more} more` : ''}</code>` : ''}</span></label></li>`).join('')}</ul>
      <p>Frees <b>${fmtSize(total)}</b>. Type <code>DELETE</code> to confirm:</p>
      <input id="trash-typed" class="ripin" autocomplete="off" value="${esc(p.typed)}" placeholder="DELETE">
      ${p.error ? `<p class="error">${esc(p.error)}</p>` : ''}
      <div class="foot"><button class="btn ghost" data-close>Cancel</button><button class="btn danger solid" data-tgo ${p.typed === 'DELETE' && chosen.length && !p.sending ? '' : 'disabled'}>${p.sending ? 'Sending…' : `Delete ${fmtSize(total)} for good`}</button></div>`;
  }
  const focused = document.activeElement?.id === 'trash-typed';
  $('confirm-body').innerHTML = `<div class="db" style="padding-top:18px">${body}</div>`;
  if (focused) { const i = $('trash-typed'); i.focus(); i.setSelectionRange(i.value.length, i.value.length); }
}

async function sendTrash() {
  const p = pendingTrash; const t = rips.trashes().find((x) => x.pc === p.pc); if (!t) return;
  const batches = t.batches.filter((b) => p.selected.has(b.path) && !b.links).map((b) => b.path);
  const req = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 7)}`;
  p.sending = true; renderTrashConfirm();
  try {
    const cmd = { cmd: 'emptytrash', pc: p.pc, req, batches };
    if (state.demo) rips.demoCommand(cmd); else await rips.command(cmd);
    p.req = req;
  } catch (err) { p.error = `Couldn't send: ${err.message}`; }
  p.sending = false; renderTrashConfirm();
}

function ripControl() {
  const c = rips.channel();
  if (c) return `<span>Rip progress: connected to the helper's ntfy topic <code>${esc(c.topic.slice(0, 8))}…</code></span> <button class="btn small ghost" data-ripoff>Disconnect</button>`;
  return `<span>MakeMKV rip progress: paste the link (or topic) from the helper's setup</span> <input id="rip-topic" class="ripin" placeholder="https://…#ntfy=pld-… or pld-…"> <button class="btn small" data-ripon>Connect</button>`;
}

function notifyControl() {
  if (!notify.supported()) return '<span>Notifications need the https site (or localhost).</span>';
  if (notify.permission() === 'denied') return '<span>Notifications are blocked for this site in your browser settings; finished jobs still show a message here.</span>';
  return notify.enabled()
    ? '<span>You\'ll get a notification when a compression or estimate finishes (while this page is open on this device).</span> <button class="btn small ghost" data-notify="off">Turn off</button>'
    : '<span>Get a notification on this device when a compression or estimate finishes?</span> <button class="btn small" data-notify="on">Notify me</button>';
}

function renderJobsButton() {
  const active = state.jobs.filter((j) => ACTIVE.includes(j.state)).length;
  $('jobs-btn').innerHTML = `Jobs${active ? `<span class="count">${active}</span>` : ''}`;
}

function jobDescription(j) {
  if (j.show && j.kind === 'quarantine') {
    const o = jobsApi.showJobInfo(j);
    const what = `Quarantine ${scopeText(o.scope)}`;
    const where = `show · ${o.ids.length || o.n} episode cop${(o.ids.length || o.n) === 1 ? 'y' : 'ies'}`;
    const info = j.state === 'done' ? `moved ${o.moved} (${fmtSize(o.bytes)}) to _TO_DELETE${o.failed ? `, ${o.failed} left in place: ${o.problem}` : ''}`: j.state === 'fail' ? j.info : '';
    return { what, where, info, percent: null };
  }
  const v = findVersion(j);
  const where = j.show ? 'show' : v ? `${v.res} · ${fmtSize(v.size)} · ${v.machine} · ${v.drive}` : `copy ${j.mediaId}`;
  if (j.kind === 'compress') {
    const preset = cz.presetById(cz.jobPreset(j))?.label || '';
    const what = `${j.action === 'ce' ? 'Estimate' : 'Compress'}${j.show ? ` ${scopeText(jobScope(j))}` : ''}${preset ? ` (${preset})` : ''}`;
    let info = '';
    if (j.state === 'run') {
      const r = cz.parseRun(j.info);
      info = `${Math.round(r.percent)}%${r.secsLeft ? ` · about ${cz.fmtDuration(r.secsLeft)} left` : ''} · ${r.paused ? `paused: ${r.paused}` : r.what}`;
    } else if (j.state === 'done' && j.action === 'ce') info = cz.estimateText(j.info, v) + ranOn(cz.decodeInfo(j.info));
    else if (j.state === 'done') {
      const o = cz.decodeInfo(j.info);
      info = (o.c ? `${o.n} of ${o.c} episodes, ${fmtSize(Number(o.s))} → ${fmtSize(Number(o.b))}${Number(o.f) ? `, ${o.f} not done: ${o.x}` : ''}; originals untouched`: `${fmtSize(Number(o.s))} → ${fmtSize(Number(o.b))}, the original is untouched`) + ranOn(o);
    }
    else if (j.state === 'fail') info = j.info;
    return { what, where, info, percent: j.state === 'run' ? cz.parseRun(j.info).percent : null };
  }
  const info = j.state === 'done' ? `Freed ${fmtSize(Number(j.info) || 0)} (moved to _TO_DELETE)` : j.state === 'fail' ? j.info : '';
  return { what: 'Quarantine', where, info, percent: null };
}

function findVersion(j) {
  for (const m of state.movies) for (const v of m.versions) if (v.serverId === j.serverId && String(v.mediaId) === String(j.mediaId)) return v;
  return null;
}

function renderJobs() {
  const list = [...state.jobs].sort((a, b) => b.created - a.created);
  $('jobs-body').innerHTML = `<div class="dh"><div><h2>Jobs</h2><div class="sub">Quarantines and compressions requested from this dashboard. Finished jobs clear themselves after a day.</div>
    <div class="sub fine">The Library Helper does these jobs on your PCs: ${helperLink()} (the same download for every PC; its setup asks whether that PC should do compression).</div>
    <div class="sub fine notifyrow">${notifyControl()}</div>
    <div class="sub fine notifyrow">${ripControl()}</div>
    ${liveSection()}</div>
    <button class="btn ghost x" data-close aria-label="Close">Close</button></div>
    <div class="db">${list.length ? list.map((j, i) => {
      const d = jobDescription(j);
      const btn = j.state === 'queued' ? `<button class="btn small" data-cancel="${i}">Cancel</button>`
        : j.state === 'run' && j.kind === 'compress' ? `<button class="btn small danger" data-stop="${i}">Stop</button>`
          : (j.state === 'done' || j.state === 'fail') ? `<button class="btn small ghost" data-clear="${i}">Clear</button>` : '';
      return `<div class="jobrow"><span class="pill ${j.state === 'stop' ? 'queued' : j.state}">${jobsApi.STATES[j.state] || esc(j.state)}</span>
        <div><div class="t">${esc(d.what)} · ${esc(j.title)}${j.year ? ` (${j.year})` : ''}</div><div class="m">${esc(d.where)} · ${timeAgo(j.created)}${d.info ? ` · ${esc(d.info)}` : ''}</div>
        ${d.percent !== null ? `<div class="bar"><i style="width:${Math.max(2, Math.min(100, d.percent))}%"></i></div>` : ''}</div>${btn}</div>`;
    }).join('') : '<p class="empty">No jobs yet. Open a movie and choose Quarantine or Compress on a copy.</p>'}</div>`;
  $('jobs-body').dataset.order = JSON.stringify(list.map((j) => j.tag));
}

function jobFromRow(i) { const tags = JSON.parse($('jobs-body').dataset.order || '[]'); return state.jobs.find((j) => j.tag === tags[i]); }

// Copies that will still exist on disk after quarantining `versions`
function survivors(e, versions) { return e.versions.filter((o) => !versions.includes(o) && !o.missing && o.checked && !activeJob(o)); }

// 'q' lets the Library Helper re-check that another copy in the same Plex item survives;
// 'qa' when the survivor is in another Plex item/server (checked here), or it's the last copy and you confirmed
function actionFor(v, e, versions) {
  const left = survivors(e, versions);
  return left.some((o) => o.serverId === v.serverId && o.ratingKey === v.ratingKey) ? 'q' : 'qa';
}

let pending = null;
function confirmQuarantine(e, versions) {
  pending = { e, versions }; pendingShow = null; pendingTrash = null;
  const all = survivors(e, versions).length === 0;
  $('confirm-body').innerHTML = `<div class="db" style="padding-top:18px">
    <h2 style="margin:0 0 4px">Quarantine ${versions.length === 1 ? 'this copy' : `${versions.length} copies`} of ${esc(e.title)}?</h2>
    <p class="fine">The Library Helper on each PC moves these files into <code>_TO_DELETE</code> on the same drive. Nothing is deleted. It checks each file matches what Plex reports before moving it, then asks Plex to rescan.</p>
    <ul>${versions.map((v) => `<li><b>${esc(v.res)} · ${esc(v.src)} · ${fmtSize(v.size)}</b> on ${esc(v.machine)} · ${esc(v.drive)}${v.files.map((f) => `<code>${esc(f)}</code>`).join('')}</li>`).join('')}</ul>
    ${all ? `<p class="warn">No other copy of ${esc(e.title)} will be left on disk. It will disappear from Plex until you restore it.</p>` : `<p class="fine">Kept: ${survivors(e, versions).map((o) => `${esc(o.res)} ${fmtSize(o.size)} on ${esc(o.machine)} · ${esc(o.drive)}`).join(', ')}.</p>`}
    <p>Frees <b>${fmtSize(versions.reduce((a, v) => a + v.size, 0))}</b> once you empty <code>_TO_DELETE</code>.</p>
    <p id="confirm-error" class="error" hidden></p>
    <div class="foot"><button class="btn ghost" data-close>Cancel</button><button class="btn danger solid" data-go>Quarantine ${versions.length === 1 ? 'copy' : `${versions.length} copies`}</button></div></div>`;
  $('confirm').showModal();
}

async function runQuarantine() {
  const { e, versions } = pending || {}; if (!versions) return;
  const go = $('confirm-body').querySelector('[data-go]'); go.disabled = true; go.textContent = 'Sending…';
  const errors = [];
  for (const v of versions) {
    try {
      if (v.missing || !v.checked) throw new Error('its file is missing or hasn\'t been checked yet');
      if (state.demo) state.demoJobs.queue(v, e);
      else {
        const api = state.servers[v.serverId]?.api;
        if (!api) throw new Error(`${state.servers[v.serverId]?.name || 'That server'} isn't connected right now.`);
        await jobsApi.queueQuarantine(api, v, actionFor(v, e, versions));
      }
    } catch (err) { errors.push(`${v.res} ${fmtSize(v.size)}: ${err.message}`); }
  }
  if (errors.length) { const el = $('confirm-error'); el.textContent = `Couldn't send: ${errors.join(' · ')}`; el.hidden = false; go.disabled = false; go.textContent = 'Try again'; return; }
  $('confirm').close(); pending = null;
  await refreshJobs();
}

// [4, 7, 8, 9] -> "E04, E07-E09"
function missingText(nums) {
  const out = []; let i = 0;
  const e = (n) => `E${String(n).padStart(2, '0')}`;
  while (i < nums.length) { let j = i; while (j + 1 < nums.length && nums[j + 1] === nums[j] + 1) j++; out.push(j > i ? `${e(nums[i])}-${e(nums[j])}` : e(nums[i])); i = j + 1; }
  return out.join(', ');
}

// ---------- Show jobs (labels on the show; see jobs.queueShowQuarantine) ----------

const seasonName = (n) => (Number(n) === 0 ? 'Specials' : `Season ${Number(n)}`);
const epCode = (ep) => `S${String(ep.season).padStart(2, '0')}E${String(ep.ep).padStart(2, '0')}`;
function scopeText(scope) {
  const m = /^(dupes-|replace-)?(all|S(\d+)(E\d+)?)$/.exec(scope || '');
  if (!m) return scope || '';
  const what = m[2] === 'all' ? 'whole show' : m[4] ? m[2] : seasonName(m[3]);
  return m[1] === 'dupes-' ? `duplicates · ${what}` : m[1] === 'replace-' ? `originals replaced by compressed copies · ${what}` : what;
}
const scopeOf = (sel) => (sel === 'all' ? 'all' : `S${String(sel).padStart(2, '0')}`);
const epsOf = (s, sel) => (sel === 'all' ? s.seasons : s.seasons.filter((se) => String(se.season) === String(sel))).flatMap((se) => se.eps);

// A season (or the whole show) presented to the Compress dialog as if it were one copy: the episodes
// still to compress (those without a compressed copy yet), their total size and running time
function showCopy(s, sel) {
  const todo = epsOf(s, sel).filter((ep) => !ep.versions.some((v) => v.compressed)).map((ep) => ep.versions.find((v) => !v.missing) || ep.versions[0]).filter(Boolean);
  if (!todo.length) return null;
  const first = todo.find((v) => v.showRatingKey) || todo[0];
  const item = s.items.find((i) => i.serverId === first.serverId && i.ratingKey === first.showRatingKey) || s.items[0];
  const res = {}; todo.forEach((v) => { res[v.res] = (res[v.res] || 0) + 1; });
  return {
    show: true, scope: scopeOf(sel), episodes: todo.length, checked: true, missing: false,
    serverId: item.serverId, ratingKey: item.ratingKey, sectionId: item.sectionId || first.sectionId, mediaId: `sh${item.ratingKey}`,
    res: Object.entries(res).sort((a, b) => b[1] - a[1])[0][0], height: Math.max(...todo.map((v) => v.height || 0)),
    size: todo.reduce((a, v) => a + v.size, 0), duration: todo.reduce((a, v) => a + (v.duration || 0), 0),
    lossless: todo.some((v) => v.lossless), dv: todo.some((v) => v.dv), hdr: todo.some((v) => v.hdr), acodec: first.acodec, ch: first.ch, atmos: todo.some((v) => v.atmos),
  };
}
// Which season a compression job is for: queued labels say s=S02, running ones carry it in the progress,
// Finished jobs from helper 0.3.9 say where they ran: m=<PC>;e=<encoder>[;v=av1]
function ranOn(o) {
  if (!o.m) return '';
  const enc = cz.ENCODERS[o.e]?.label;
  return ` · on ${o.m}${enc ? ` (${enc}${o.v === 'av1' && !/AV1/.test(enc) ? ', AV1' : ''})` : ''}`;
}

// finished ones say w=S02 (there s is the size of the originals)
function jobScope(j) {
  if (j.state === 'run') return cz.parseRun(j.info).scope;
  const o = cz.decodeInfo(j.info);
  return (j.state === 'queued' ? o.s : o.w) || '';
}
function activeShowCompress(s, scope) { return jobsForShow(s).some((j) => j.kind === 'compress' && j.action === 'c' && ACTIVE.includes(j.state) && (jobScope(j) === scope || jobScope(j) === 'all' || scope === 'all')); }
// After compressing: the originals of episodes that now have a compressed copy
function replaceTargets(s, eps) {
  const busy = busyIds(s);
  return eps.filter((ep) => ep.versions.some((v) => v.compressed)).flatMap((ep) => ep.versions.filter((v) => !v.compressed && !v.missing && !busy.has(String(v.mediaId))));
}

function jobsForShow(s) {
  const keys = new Set(s.items.map(itemKey));
  return state.jobs.filter((j) => j.show && keys.has(`${j.serverId}|${j.ratingKey}`)).sort((a, b) => b.created - a.created);
}
// Episode copies already in an active show job, so they can't be queued twice
function busyIds(s) { return new Set(jobsForShow(s).filter((j) => ACTIVE.includes(j.state)).flatMap((j) => jobsApi.showJobInfo(j).ids)); }

// Copies to quarantine for "keep the best copy of each episode": everything below the best, except
// compressed copies (made on purpose) and copies already in a job
function dupeTargets(s, eps) {
  const busy = busyIds(s);
  return eps.filter((ep) => ep.dupes).flatMap((ep) => ep.versions.slice(1).filter((v) => !v.missing && !v.compressed && !busy.has(String(v.mediaId))));
}
function allTargets(s, eps) { const busy = busyIds(s); return eps.flatMap((ep) => ep.versions.filter((v) => !busy.has(String(v.mediaId)))); }

function showJobsHtml(s) {
  const jobs = jobsForShow(s).slice(0, 6);
  if (!jobs.length) return '';
  return `<div class="showjobs">${jobs.map((j) => {
    if (j.kind === 'compress' && ACTIVE.includes(j.state)) return progressHtml(j);
    const d = jobDescription(j);
    return `<div class="cstat"><span class="pill ${j.state === 'stop' ? 'queued' : j.state}">${jobsApi.STATES[j.state] || esc(j.state)}</span> ${esc(d.what)}${d.info ? ` · ${esc(d.info)}` : ''}</div>`;
  }).join('')}</div>`;
}

function seasonHtml(s, se) {
  const eps = se.eps;
  const dupes = dupeTargets(s, eps);
  const locs = se.locs.map((id) => esc(locName(state.locations.find((l) => l.id === id) || { machine: '?', drive: id }))).join(', ');
  return `<div class="season">
    <div class="shead"><b>${seasonName(se.season)}</b><span>${eps.length} ep${eps.length === 1 ? '' : 's'} · ${fmtSize(se.size)} · ${Object.entries(se.res).map(([r, n]) => `${esc(r)} ×${n}`).join(', ')}</span></div>
    <div class="sfacts">${locs}${se.dupes ? ` · <span class="b dup">${se.dupes} duplicated</span>` : ''}${se.missing.length ? ` · <span class="b sd" title="Episodes missing between ones you have">missing ${esc(missingText(se.missing))}</span>` : ''}</div>
    <div class="actions">
      ${showCopy(s, String(se.season)) && !activeShowCompress(s, scopeOf(se.season)) ? `<button class="btn small" data-scompress="${se.season}">Compress ${seasonName(se.season).toLowerCase()}…</button>` : ''}
      ${replaceTargets(s, eps).length ? `<button class="btn small" data-sreplace="${se.season}" title="Quarantine the originals of episodes that now have a compressed copy">Replace ${replaceTargets(s, eps).length} original${replaceTargets(s, eps).length === 1 ? '' : 's'} with compressed</button>` : ''}
      ${dupes.length ? `<button class="btn small" data-sdupes="${se.season}">Keep best, quarantine ${dupes.length} duplicate${dupes.length === 1 ? '' : 's'} (${fmtSize(dupes.reduce((a, v) => a + v.size, 0))})</button>` : ''}
      <button class="btn small danger" data-sq="${se.season}">Quarantine ${seasonName(se.season).toLowerCase()}…</button>
    </div>
  </div>`;
}

function showDetail(s) {
  const allEps = s.seasons.flatMap((se) => se.eps);
  const dupeEps = allEps.filter((ep) => ep.dupes);
  const allDupes = dupeTargets(s, allEps);
  const gapNote = s.missingSeasons.length || s.missingEps ? `<p class="note">${s.missingSeasons.length ? `<b>Missing ${s.missingSeasons.length === 1 ? 'season' : 'seasons'} ${s.missingSeasons.join(', ')}</b>. ` : ''}Missing episodes are gaps between episodes you have; the last episodes of a season can't be checked.</p>` : '';
  return `<div class="db">
    ${gapNote}
    ${showJobsHtml(s)}
    <div class="actions">
      ${s.seasons.length > 1 && showCopy(s, 'all') && !activeShowCompress(s, 'all') ? '<button class="btn small" data-scompress="all">Compress whole show…</button>' : ''}
      ${allDupes.length ? `<button class="btn small" data-sdupes="all">Keep best of every episode: quarantine ${allDupes.length} duplicate${allDupes.length === 1 ? '' : 's'} (${fmtSize(allDupes.reduce((a, v) => a + v.size, 0))})</button>` : ''}
      <button class="btn small danger" data-sq="all">Quarantine whole show…</button>
    </div>
    <div class="seasons">${s.seasons.map((se) => seasonHtml(s, se)).join('')}</div>
    ${dupeEps.length ? `<details class="dupeps"><summary>${dupeEps.length} duplicated episode${dupeEps.length === 1 ? '' : 's'} · ${fmtSize(s.extra)} extra</summary>
      ${dupeEps.map((ep) => {
        const t = dupeTargets(s, [ep]);
        return `<h4>${epCode(ep)} · ${esc(ep.title)}${t.length ? ` <button class="btn small" data-edupe="${esc(ep.season)}x${esc(ep.ep)}">Keep best, quarantine ${t.length === 1 ? 'the other' : `the other ${t.length}`}</button>` : ''}</h4>${ep.versions.map((v, i) => versionHtml(v, ep, i)).join('')}`;
      }).join('')}
    </details>` : ''}
    <p class="note">Quarantine moves episode files into <code>_TO_DELETE</code> on their own drive, done by the Library Helper on that PC (it needs version 0.3.4 or newer for shows; update the helper on every PC). Nothing is deleted. "Keep best" keeps each episode's highest-quality copy, and the helper double-checks that copy still exists first.</p>
  </div>`;
}

// Confirm, then queue: copies grouped by the show entry they belong to (a show can be on two servers)
let pendingShow = null;
function confirmShowQuarantine(s, versions, action, scope) {
  if (!versions.length) return;
  if (versions.some((v) => !v.showRatingKey)) { alert('Rescan first: this list was loaded before the dashboard knew which show each episode belongs to.'); return; }
  pendingShow = { s, versions, action, scope };
  const byLoc = new Map(); for (const v of versions) byLoc.set(v.loc, (byLoc.get(v.loc) || 0) + 1);
  const total = versions.reduce((a, v) => a + v.size, 0);
  const eps = new Map(); for (const v of versions) eps.set(v.epCode, (eps.get(v.epCode) || 0) + 1);
  const codes = [...eps.keys()].sort();
  const replace = scope.startsWith('replace-');
  const dupes = action === 'qm' && !replace;
  const whole = scope === 'all';
  $('confirm-body').innerHTML = `<div class="db" style="padding-top:18px">
    <h2 style="margin:0 0 4px">${replace ? `Replace ${versions.length} original${versions.length === 1 ? '' : 's'} with the compressed cop${versions.length === 1 ? 'y' : 'ies'} in` : dupes ? `Quarantine ${versions.length} duplicate cop${versions.length === 1 ? 'y' : 'ies'} of` : whole ? 'Quarantine all of' : `Quarantine ${seasonName(scope.slice(1)).toLowerCase()} of`} ${esc(s.title)}?</h2>
    <p class="fine">The Library Helper on each PC moves these files into <code>_TO_DELETE</code> on the same drive. Nothing is deleted. ${dupes || replace ? `For every episode it first checks that the ${replace ? 'compressed copy' : 'copy being kept'} still exists; if not, that episode is left alone.` : ''}</p>
    <ul><li><b>${versions.length} episode file${versions.length === 1 ? '' : 's'} · ${fmtSize(total)}</b>${[...byLoc].map(([loc, n]) => { const l = state.locations.find((x) => x.id === loc); return `<code>${esc(l ? locName(l) : loc)}: ${n}</code>`; }).join('')}
      <code>${esc(codes.slice(0, 30).join(', '))}${codes.length > 30 ? `, and ${codes.length - 30} more` : ''}</code></li></ul>
    ${dupes || replace ? '' : `<p class="warn">${whole ? `${esc(s.title)} will disappear from Plex` : `${seasonName(scope.slice(1))} will disappear from Plex`} until you put the files back. Emptying <code>_TO_DELETE</code> later deletes them for good.</p>`}
    <p>Frees <b>${fmtSize(total)}</b> once you empty <code>_TO_DELETE</code>.</p>
    <p id="confirm-error" class="error" hidden></p>
    <div class="foot"><button class="btn ghost" data-close>Cancel</button><button class="btn danger solid" data-go>Quarantine ${versions.length} file${versions.length === 1 ? '' : 's'}</button></div></div>`;
  $('confirm').showModal();
}

async function runShowQuarantine() {
  const { s, versions, action, scope } = pendingShow || {}; if (!versions) return;
  const go = $('confirm-body').querySelector('[data-go]'); go.disabled = true; go.textContent = 'Sending…';
  const byItem = new Map();
  for (const v of versions) { const k = `${v.serverId}|${v.showRatingKey}`; if (!byItem.has(k)) byItem.set(k, []); byItem.get(k).push(v); }
  const errors = [];
  for (const [k, vs] of byItem) {
    const item = s.items.find((i) => itemKey(i) === k) || { serverId: vs[0].serverId, ratingKey: vs[0].showRatingKey, sectionId: vs[0].sectionId };
    const show = { ...item, sectionId: item.sectionId || vs[0].sectionId, title: s.title, year: s.year };
    try {
      if (state.demo) state.demoJobs.queueShow(show, vs, action, scope);
      else {
        const api = state.servers[show.serverId]?.api;
        if (!api) throw new Error(`${state.servers[show.serverId]?.name || 'That server'} isn't connected right now.`);
        await jobsApi.queueShowQuarantine(api, show, vs, action, scope);
      }
    } catch (err) { errors.push(err.message); }
  }
  if (errors.length) { const el = $('confirm-error'); el.textContent = `Couldn't send: ${errors.join(' · ')}`; el.hidden = false; go.disabled = false; go.textContent = 'Try again'; return; }
  $('confirm').close(); pendingShow = null;
  await refreshJobs();
}

let openEntry = null;
function renderDetail() {
  const e = openEntry; if (!e) return;
  const sub = e.kind === 'movie'
    ? `${e.year || 'Unknown year'} · ${e.versions.length} cop${e.versions.length === 1 ? 'y' : 'ies'} · ${fmtSize(e.size)}`
    : `${e.year || ''} · ${e.seasons.length} seasons · ${e.epCount} episodes · ${fmtSize(e.size)}`;
  $('detail-body').innerHTML = `<div class="dh">${posterHtml(e, 180)}</div>
      <div><h2>${esc(e.title)}</h2><div class="sub">${esc(sub)}</div><div class="badges">${cardBadges(e)}</div></div>
      <div class="hbtns">${e.items?.length ? '<button class="btn small" data-fixmatch>Fix match</button>' : ''}<button class="btn ghost small" data-close aria-label="Close">Close</button></div></div>
    ${e.kind === 'movie' ? movieDetail(e) : showDetail(e)}`;
}

// For each copy: asks Plex whether the file still exists on disk (checkFiles), and reads the exact
// video/audio streams (HDR format, Dolby Vision, Atmos). Actions stay disabled until this is done.
async function loadExact(e) {
  const vs = e.kind === 'movie' ? e.versions : [];
  await Promise.all(vs.map(async (v) => {
    const api = state.servers[v.serverId]?.api; if (!api) return;
    try {
      const md = await api.metadata(v.ratingKey, { checkFiles: 1 });
      const m = (md?.Media || []).find((x) => String(x.id) === String(v.mediaId));
      if (!m) { v.missing = true; v.checked = true; return; } // Plex no longer lists this copy
      v.missing = (m.Part || []).some((p) => p.exists === false || p.accessible === false || p.exists === 0);
      v.checked = true;
      const streams = m?.Part?.[0]?.Stream || [];
      const vid = streams.find((s) => s.streamType === 1);
      const aud = streams.find((s) => s.streamType === 2 && s.selected) || streams.find((s) => s.streamType === 2);
      if (vid) {
        v.dv = !!vid.DOVIPresent;
        v.hdr = v.dv || ['smpte2084', 'arib-std-b67'].includes(vid.colorTrc);
        v.videoLabel = vid.displayTitle || v.videoLabel;
      }
      if (aud) {
        v.atmos = /atmos/i.test(`${aud.displayTitle} ${aud.extendedDisplayTitle || ''} ${aud.audioChannelLayout || ''}`);
        v.lossless = ['truehd', 'flac', 'pcm', 'alac'].includes(aud.codec) || (aud.codec === 'dca' && /ma|hd/i.test(aud.profile || ''));
        v.audioLabel = (aud.extendedDisplayTitle || aud.displayTitle || '').replace(/^.*?\(|\)$/g, '') || null;
      }
      v.exact = true;
    } catch { /* keep file-name guesses */ }
  }));
  if (e.kind === 'movie') finishEntry(e); // re-rank now that HDR/DV/audio are exact
  if (openEntry === e) renderDetail();
}

function openDetail(e) {
  if (e.kind === 'movie') e.versions.forEach((v) => { v.checked = state.demo ? true : false; }); // re-check every time it's opened
  openEntry = e; renderDetail();
  const d = $('detail'); if (!d.open) d.showModal();
  if (!state.demo) loadExact(e);
}

// ---------- Compress ----------

let cctx = null;
const CPREFS = 'pld.compress';

function openCompress(e, v) {
  let saved = {}; try { saved = JSON.parse(localStorage.getItem(CPREFS) || '{}'); } catch { /* defaults */ }
  const fits = cz.PRESETS.filter((p) => cz.presetFits(p, v));
  // Start from this copy's last estimate if there is one, else the last choice, else 4K Normal / 1080p Normal
  const est = jobFor(v, 'ce'); const eo = est ? cz.decodeInfo(est.state === 'run' ? '' : est.info) : {};
  const want = eo.p || saved.preset;
  const preset = fits.find((p) => p.id === want)?.id || fits.find((p) => p.id === '4kn')?.id || fits.find((p) => p.id === '1080n')?.id || fits[0]?.id;
  cctx = { e, v, preset, audio: eo.a || saved.audio || 'keep', codec: eo.v === 'av1' || (!est && saved.codec === 'av1') ? 'av1' : 'hevc', rules: new Set(saved.rules || cz.RULES.filter((r) => r.on).map((r) => r.id)), error: '', busy: false };
  renderCompress();
  $('compress').showModal();
}

function dvLine(p, v, codec = 'hevc') {
  if (v.dv) return !p.dv ? 'Dolby Vision and HDR become normal colour (SDR)' : codec === 'av1' ? 'Dolby Vision becomes HDR10' : 'Keeps Dolby Vision';
  if (v.hdr) return p.height === 1080 ? 'HDR becomes normal colour (SDR)' : 'Keeps HDR';
  return '';
}

function renderCompress() {
  const c = cctx; if (!c) return;
  const { e, v } = c;
  const p = cz.presetById(c.preset);
  const opts = cz.encodeOptions({ preset: c.preset, audio: c.audio, rules: [...c.rules], codec: c.codec });
  const pcs = rips.caps();   // compressing PCs that have reported what they can do
  // Per preset: the quickest PC that has measured it, else the rough figure from the owner's test encodes
  const guessFor = (q) => {
    const m = cz.pcGuesses(q, v, c.audio, c.codec, pcs).filter((g) => g.measured).sort((a, b) => a.secs - b.secs)[0];
    return m ? { ...m, where: m.enc && cz.ENCODERS[m.enc].cpu ? 'Processor' : 'Graphics card' } : { ...cz.roughGuess(q, v, c.audio, c.codec), where: q.where };
  };
  // The latest estimate for exactly these settings
  const ests = state.jobs.filter((j) => j.kind === 'compress' && j.action === 'ce' && j.serverId === v.serverId && String(j.mediaId) === String(v.mediaId)).sort((a, b) => b.created - a.created);
  const est = ests.find((j) => { const o = j.state === 'run' ? { p: cz.jobPreset(j) } : cz.decodeInfo(j.info); return o.p === c.preset && (!o.a || o.a === c.audio || j.state === 'run') && (j.state === 'run' || (o.v === 'av1' ? 'av1' : 'hevc') === c.codec) && (!v.show || jobScope(j) === v.scope); });
  const estRunning = est && ACTIVE.includes(est.state);
  let estHtml = '';
  if (est?.state === 'done') {
    const o = cz.decodeInfo(est.info);
    estHtml = `<div class="cest"><b>Estimate from ${v.show ? 'samples of up to 3 episodes' : '3 samples of this film'}:</b> ${esc(cz.estimateText(est.info, v))}${o.q ? `<div class="fine">Quality ${esc(o.q)}: ${esc(cz.qualityWords(o.q))}.</div>` : ''}</div>`;
  } else if (estRunning) estHtml = progressHtml(est);
  else if (est?.state === 'fail') estHtml = `<div class="cest error">Estimate failed: ${esc(est.info)}</div>`;

  const heading = v.show ? `Compress ${v.scope === 'all' ? 'all of' : `${scopeText(v.scope).toLowerCase()} of`} ${esc(e.title)}` : `Compress ${esc(e.title)}${e.year ? ` (${e.year})` : ''}`;
  const what = v.show ? `${v.episodes} episode${v.episodes === 1 ? '' : 's'} to do (ones already compressed are skipped): ${esc(v.res)}` : `This copy: ${esc(v.res)} · ${esc(v.src)}`;
  $('compress-body').innerHTML = `<div class="dh"><div><h2>${heading}</h2>
      <div class="sub">${what} · ${fmtSize(v.size)}${v.dv ? ' · Dolby Vision' : v.hdr ? ' · HDR' : ''}${v.duration ? ` · ${cz.fmtDuration(v.duration / 1000)}` : ''}</div></div>
      <div class="hbtns"><button class="btn ghost small" data-close>Close</button></div></div>
    <div class="db">
      <h3 class="ch">Quality</h3>
      <div class="presets">${cz.PRESETS.map((q) => {
        const fits = cz.presetFits(q, v); const g = guessFor(q);
        return `<label class="preset${fits ? '' : ' off'}${q.id === c.preset ? ' on' : ''}">
          <input type="radio" name="preset" value="${q.id}" ${q.id === c.preset ? 'checked' : ''} ${fits ? '' : 'disabled'}>
          <div><div class="t">${esc(q.label)} <span class="b">${esc(g.where)}</span></div>
          <div class="m">${esc(q.note)}</div>
          ${fits ? `<div class="m">${g.little ? '<b>Little to gain: this copy is already fairly compact.</b> ' : ''}${g.measured ? 'About' : 'Typically about'} ${fmtSize(g.bytes)} (${Math.round((g.bytes / v.size) * 100)}%)${g.secs ? ` · about ${cz.fmtDuration(g.secs)}${g.measured && pcs.length > 1 ? ` on ${esc(g.pc)}` : ''}` : ''}${dvLine(q, v, c.codec) ? ` · ${esc(dvLine(q, v, c.codec))}` : ''}</div>` : '<div class="m">Needs a bigger source than this copy.</div>'}</div></label>`;
      }).join('')}</div>
      ${p && pcs.length ? whichPcHtml(p, v, c, pcs) : ''}
      <h3 class="ch">Video format</h3>
      <div class="opts">
        <label><input type="radio" name="codec" value="hevc" ${c.codec === 'hevc' ? 'checked' : ''}> HEVC (H.265) <span class="fine">plays on nearly everything; keeps Dolby Vision</span></label>
        <label><input type="radio" name="codec" value="av1" ${c.codec === 'av1' ? 'checked' : ''}> AV1 <span class="fine">about a quarter smaller again at the same quality; needs a newer TV or player, and Dolby Vision becomes HDR10${pcs.length ? `. ${av1Text(pcs)}` : ''}</span></label>
      </div>
      <h3 class="ch">Audio</h3>
      <div class="opts">
        <label><input type="radio" name="audio" value="keep" ${c.audio === 'keep' ? 'checked' : ''}> Keep all original audio <span class="fine">(${esc(fmtAudio(v) || 'as is')}, every language and commentary)</span></label>
        <label><input type="radio" name="audio" value="small" ${c.audio === 'small' ? 'checked' : ''}> Smaller: one main track <span class="fine">(uses the disc's Dolby Digital Plus track if it has one, which often keeps Atmos; otherwise 5.1 Dolby Digital Plus. Lossless TrueHD/DTS-HD is dropped.)</span></label>
      </div>
      <h3 class="ch">When</h3>
      <div class="opts">${cz.RULES.map((r) => `<label><input type="checkbox" data-rule="${r.id}" ${c.rules.has(r.id) ? 'checked' : ''}> ${esc(r.label)}</label>`).join('')}</div>
      ${estHtml}
      <p class="note">A PC with compression turned on in its Library Helper does the work: whichever one that can do it is free first (${helperLink()} if it isn't installed; answer yes to compression in its setup). The original is never changed: the compressed copy is added next to it, checked, and shows up in Plex as a second version. Replacing the original is a separate step afterwards. Grainy films shrink much less than the typical figures; <b>Estimate</b> encodes three short samples of this film (a few minutes) to tell you the real size, time and quality first.</p>
      ${c.error ? `<p class="error">${esc(c.error)}</p>` : ''}
      <div class="foot">
        <button class="btn" data-cest ${estRunning || c.busy || !p ? 'disabled' : ''}>${estRunning ? 'Estimating…' : est?.state === 'done' ? 'Estimate again' : 'Estimate first'}</button>
        <button class="btn primary" data-cgo ${c.busy || !p ? 'disabled' : ''}>Start compressing</button>
      </div>
    </div>`;
  $('compress-body').dataset.opts = opts;
}

// Which PCs could take the chosen preset, with what, and how long each would take
function whichPcHtml(p, v, c, pcs) {
  const rows = cz.pcGuesses(p, v, c.audio, c.codec, pcs).map((g) => {
    const cap = pcs.find((x) => x.pc === g.pc); const busy = rips.helpers().find((h) => h.pc === g.pc)?.jobs?.some((j) => j.mode === 'compress');
    const what = !g.enc ? `<span class="fine">can't: no ${c.codec === 'av1' ? 'AV1 encoder' : 'suitable encoder'}${cap?.allowCpu ? '' : ' (processor jobs are off there)'}</span>`
      : `${esc(cz.ENCODERS[g.enc].label)} · ${g.measured ? `about ${fmtSize(g.bytes)} · about ${cz.fmtDuration(g.secs)} <span class="fine">(${g.fps >= 10 ? Math.round(g.fps) : g.fps.toFixed(1)} fps measured)</span>` : '<span class="fine">not benchmarked yet</span>'}${busy ? ' · <span class="fine">busy with another compression</span>' : ''}`;
    return `<div class="liverow"><span><b>${esc(g.pc)}</b> · ${what}</span></div>`;
  });
  return `<div class="whichpc"><div class="fine">Which PC does ${esc(p.label)}: the first free one of these</div>${rows.join('')}</div>`;
}
function av1Text(pcs) {
  const can = pcs.filter((x) => (x.encoders || []).some((id) => cz.ENCODERS[id]?.codec === 'av1' && (!cz.ENCODERS[id].cpu || x.allowCpu)));
  if (!can.length) return 'None of your PCs can encode AV1 yet';
  const gpu = can.filter((x) => x.encoders.some((id) => cz.ENCODERS[id]?.codec === 'av1' && !cz.ENCODERS[id].cpu));
  return gpu.length ? `Graphics AV1 on ${gpu.map((x) => esc(x.pc)).join(', ')}` : `Only on the processor (slow) on ${can.map((x) => esc(x.pc)).join(', ')}`;
}

async function queueCompression(action) {
  const c = cctx; if (!c || c.busy) return;
  const p = cz.presetById(c.preset); if (!p) return;
  // First compression from this device: ask (once) whether to be notified when it's done. Has to happen
  // straight from the click, before anything is awaited, or browsers won't show the question.
  if (notify.permission() === 'default' && !notify.wanted()) notify.turnOn();
  try { localStorage.setItem(CPREFS, JSON.stringify({ preset: c.preset, audio: c.audio, codec: c.codec, rules: [...c.rules] })); } catch { /* ignore */ }
  c.busy = true; c.error = ''; renderCompress();
  try {
    if (c.v.missing || !c.v.checked) throw new Error('the file is missing or hasn\'t been checked yet');
    const opts = cz.encodeOptions({ preset: c.preset, audio: c.audio, rules: [...c.rules], codec: c.codec });
    if (state.demo) state.demoJobs.queueCompress(c.v, c.e, action, c.v.show ? `${opts};s=${c.v.scope}` : opts, cz.roughGuess(p, c.v, c.audio, c.codec));
    else if (c.v.show) {
      const api = state.servers[c.v.serverId]?.api;
      if (!api) throw new Error(`${state.servers[c.v.serverId]?.name || 'That server'} isn't connected right now.`);
      await jobsApi.queueShowCompress(api, c.v, action, opts, c.v.scope);
    }
    else {
      const api = state.servers[c.v.serverId]?.api;
      if (!api) throw new Error(`${state.servers[c.v.serverId]?.name || 'That server'} isn't connected right now.`);
      await jobsApi.queueCompress(api, c.v, action, opts);
    }
    c.busy = false;
    if (action === 'c') { $('compress').close(); cctx = null; }
    await refreshJobs();
  } catch (err) { c.busy = false; c.error = `Couldn't send: ${err.message}`; renderCompress(); }
}

// ---------- Fix match ----------

let matchCtx = null;
const itemKey = (i) => `${i.serverId}|${i.ratingKey}`;

// A sensible search from a messy file-name title like "Dune T00" or "Dune.2021.2160p.UHD"
function guessTitle(e) {
  let t = e.title || '';
  if (e.unmatched) {
    t = t.replace(/\b[tT]\d{2}\b/g, ' ').replace(/[._]/g, ' ').replace(/[[(].*?[\])]/g, ' ')
      .replace(/\b(19|20)\d{2}\b.*$/, '').replace(/\b(2160p|1080p|720p|480p|4k|uhd|bluray|web-?dl|webrip|x26[45]|hevc|remux)\b.*$/i, '')
      .replace(/\s+/g, ' ').trim();
  }
  return t || e.title;
}

function itemDescription(e, it) {
  const srv = state.servers[it.serverId];
  const file = e.kind === 'movie'
    ? e.versions.find((v) => v.serverId === it.serverId && v.ratingKey === it.ratingKey)?.files?.[0]
    : e.seasons?.[0]?.eps?.[0]?.versions?.find((v) => v.serverId === it.serverId)?.files?.[0];
  return `${srv?.name || 'Plex'}${it.unmatched ? ' · unmatched' : ''}${file ? ` · ${file}` : ''}`;
}

function openMatch(e) {
  matchCtx = { e, results: [], selected: new Set(e.items.map(itemKey)), busy: false };
  const multi = e.items.length > 1;
  $('match-body').innerHTML = `<div class="dh"><div><h2>Fix match</h2><div class="sub">${esc(e.title)}${e.year ? ` (${e.year})` : ''}${e.unmatched ? ' · Plex couldn\'t identify this' : ''}</div></div>
      <div class="hbtns"><button class="btn ghost small" data-close>Close</button></div></div>
    <div class="db">
      ${multi ? `<p class="fine">This title is ${e.items.length} separate entries in Plex. Apply the match to:</p><div class="mitems">${e.items.map((it) => `<label><input type="checkbox" data-item="${esc(itemKey(it))}" checked><code>${esc(itemDescription(e, it))}</code></label>`).join('')}</div>` : `<p class="fine"><code>${esc(itemDescription(e, e.items[0]))}</code></p>`}
      <form class="msearch" id="match-form"><input name="title" value="${esc(guessTitle(e))}" aria-label="Title" placeholder="Title"><input name="year" value="${esc(e.unmatched ? '' : e.year || '')}" inputmode="numeric" aria-label="Year" placeholder="Year"><button class="btn" type="submit">Search</button></form>
      <p id="match-error" class="error" hidden></p>
      <div id="match-results"><p class="fine">Searching Plex…</p></div>
    </div>`;
  $('match').showModal();
  searchMatches();
}

async function searchMatches() {
  const f = $('match-form'); const title = f.title.value.trim(); const year = f.year.value.trim();
  const box = $('match-results'); const err = $('match-error'); err.hidden = true;
  if (!title) { err.textContent = 'Enter a title to search for.'; err.hidden = false; return; }
  const target = matchCtx.e.items.find((it) => matchCtx.selected.has(itemKey(it))) || matchCtx.e.items[0];
  box.innerHTML = '<p class="fine">Searching Plex…</p>';
  try {
    let results;
    if (state.demo) {
      results = [{ guid: `plex://movie/demo-${title}`, name: title, year: Number(year) || 2021, summary: 'Sample search result (demo data).' },
        { guid: `plex://movie/demo-${title}-2`, name: `${title} II`, year: (Number(year) || 2021) + 3, summary: 'Another sample result.' }];
    } else {
      const api = state.servers[target.serverId]?.api;
      if (!api) throw new Error(`${state.servers[target.serverId]?.name || 'That server'} isn't connected right now.`);
      results = await api.searchMatches(target.ratingKey, title, year);
    }
    matchCtx.results = results;
    box.innerHTML = results.length ? results.slice(0, 12).map((r, i) => `<div class="mresult">
        ${r.thumb ? `<img src="${esc(r.thumb)}" alt="" loading="lazy" referrerpolicy="no-referrer" onerror="this.replaceWith(Object.assign(document.createElement('div'),{className:'noimg'}))">` : '<div class="noimg"></div>'}
        <div><div class="t">${esc(r.name)}${r.year ? ` (${r.year})` : ''}</div>${r.summary ? `<div class="m">${esc(String(r.summary).slice(0, 160))}${String(r.summary).length > 160 ? '…' : ''}</div>` : ''}</div>
        <button class="btn small${i === 0 ? ' primary' : ''}" data-use="${i}">Use this</button></div>`).join('')
      : '<p class="fine">No matches. Try a shorter title, or remove the year.</p>';
  } catch (e2) { box.innerHTML = ''; err.textContent = `Search didn't work: ${e2.message}`; err.hidden = false; }
}

async function applyMatch(i) {
  const r = matchCtx.results[i]; if (!r || matchCtx.busy) return;
  const items = matchCtx.e.items.filter((it) => matchCtx.selected.has(itemKey(it)));
  const err = $('match-error'); err.hidden = true;
  if (!items.length) { err.textContent = 'Tick at least one Plex entry to apply the match to.'; err.hidden = false; return; }
  matchCtx.busy = true;
  $('match-results').querySelectorAll('[data-use]').forEach((b) => { b.disabled = true; });
  const btn = $('match-results').querySelector(`[data-use="${i}"]`); btn.textContent = 'Applying…';
  try {
    if (state.demo) {
      for (const s of state.snapshots) for (const m of s.movies) if (items.some((it) => it.serverId === s.id && it.ratingKey === m.ratingKey)) {
        Object.assign(m, { title: r.name, year: r.year, k: r.guid, unmatched: false });
      }
    } else {
      for (const it of items) await state.servers[it.serverId].api.applyMatch(it.ratingKey, r);
    }
    $('match').close();
    status(`Matched to ${r.name}${r.year ? ` (${r.year})` : ''}. Updating…`);
    await refreshAfterMatch(matchCtx.e, items, r);
  } catch (e2) {
    err.textContent = `Couldn't apply the match: ${e2.message}`; err.hidden = false;
    btn.textContent = 'Use this'; $('match-results').querySelectorAll('[data-use]').forEach((b) => { b.disabled = false; });
  } finally { matchCtx.busy = false; }
}

// Re-reads just the matched Plex entries so the change shows immediately (shows get a full rescan)
async function refreshAfterMatch(e, items) {
  if (!state.demo && e.kind === 'movie') {
    await new Promise((res) => setTimeout(res, 1500)); // Plex applies the match in the background
    for (const it of items) {
      const srv = state.servers[it.serverId]; const snap = state.snapshots.find((s) => s.id === it.serverId);
      if (!srv?.api || !snap) continue;
      try {
        const md = await srv.api.metadata(it.ratingKey, { includeGuids: 1 });
        if (!md) continue;
        const [rec] = normalizeMovies([md], srv, { key: it.sectionId || md.librarySectionID, title: '' });
        snap.movies = [...snap.movies.filter((m) => m.ratingKey !== it.ratingKey), rec];
        await cache.save(snap);
      } catch (err) { console.warn('Refresh after match failed', err); }
    }
  }
  if (!state.demo && e.kind === 'show') { $('detail').close(); openEntry = null; await sync(); return; }
  rebuild(); render();
  const first = items[0];
  const next = (e.kind === 'movie' ? state.movies : state.shows).find((x) => x.items?.some((it) => itemKey(it) === itemKey(first)));
  if (next) openDetail(next); else { $('detail').close(); openEntry = null; }
  status('Match updated. Plex is fetching the new poster and details in the background.');
}

// ---------- Events ----------

function bind() {
  $('signin-tab').onclick = (ev) => { ev.preventDefault(); plex.signIn(() => {}, { sameTab: true }).catch((err) => { $('login-error').textContent = `Sign-in didn't work: ${err.message}`; $('login-error').hidden = false; }); };
  $('signin').onclick = async () => {
    const btn = $('signin'), msg = $('login-status'), errEl = $('login-error');
    errEl.hidden = true; btn.disabled = true;
    try {
      state.token = await plex.signIn((t) => { msg.textContent = t; msg.hidden = false; });
      msg.textContent = 'Signed in. Loading your library…';
      render(); sync();
    } catch (err) {
      console.error('Plex sign-in failed', err);
      errEl.textContent = `Sign-in didn't work: ${err.message}`; errEl.hidden = false;
    } finally {
      btn.disabled = false; msg.hidden = true;
    }
  };
  $('demo').onclick = () => startDemo();
  $('account').onclick = async () => {
    if (state.demo) { state.demo = false; state.snapshots = []; state.jobs = []; state.demoJobs = null; rebuild(); render(); status(''); return; }
    plex.signOut(); await cache.clear();
    Object.assign(state, { token: null, user: null, servers: {}, snapshots: [] }); rebuild(); render(); status('');
  };
  $('refresh').onclick = () => sync();
  $('confirm').oninput = (ev) => { if (pendingTrash && ev.target.id === 'trash-typed') { pendingTrash.typed = ev.target.value.trim(); renderTrashConfirm(); } };
  $('confirm').onchange = (ev) => {
    const cb = ev.target.closest('[data-tb]'); if (!cb || !pendingTrash) return;
    cb.checked ? pendingTrash.selected.add(cb.dataset.tb) : pendingTrash.selected.delete(cb.dataset.tb);
    renderTrashConfirm();
  };
  $('stats').onclick = (ev) => { if (ev.target.closest('[data-openjobs]')) { renderJobs(); $('jobs').showModal(); } };
  $('ripcard').onchange = async (ev) => {
    const cb = ev.target.closest('[data-ripauto]'); if (!cb) return;
    cb.disabled = true;
    try { if (state.demo) rips.demoSet(cb.checked); else await rips.setAutoCompress(cb.dataset.ripauto, cb.checked); }
    catch (err) { cb.checked = !cb.checked; alert(`Couldn't reach the helper: ${err.message}`); }
    finally { cb.disabled = false; }
  };
  $('tip').onclick = (ev) => {
    if (!ev.target.closest('[data-hidetip]')) return;
    try { localStorage.setItem(TIP_HIDDEN, '1'); } catch { /* ignore */ }
    $('tip').hidden = true;
  };
  $('jobs-btn').onclick = () => { renderJobs(); $('jobs').showModal(); refreshJobs(); };
  $('confirm').onclick = (ev) => {
    if (ev.target === $('confirm') || ev.target.closest('[data-close]')) { $('confirm').close(); pending = null; pendingShow = null; pendingTrash = null; return; }
    if (ev.target.closest('[data-go]')) { if (pendingShow) runShowQuarantine(); else runQuarantine(); }
    if (pendingTrash) {
      const sel = ev.target.closest('[data-tsel]');
      if (sel) {
        const t = rips.trashes().find((x) => x.pc === pendingTrash.pc);
        const old = (b) => (Date.now() - new Date(b.date).getTime()) / 86400000 > 7;
        pendingTrash.selected = new Set((t?.batches || []).filter((b) => !b.links && (sel.dataset.tsel === 'all' || (sel.dataset.tsel === 'old' && old(b)))).map((b) => b.path));
        renderTrashConfirm();
      }
      if (ev.target.closest('[data-tgo]')) sendTrash();
    }
  };
  $('match').onclick = (ev) => {
    if (ev.target === $('match') || ev.target.closest('[data-close]')) { $('match').close(); return; }
    const use = ev.target.closest('[data-use]'); if (use) applyMatch(+use.dataset.use);
  };
  $('match').onchange = (ev) => {
    const cb = ev.target.closest('[data-item]'); if (!cb) return;
    cb.checked ? matchCtx.selected.add(cb.dataset.item) : matchCtx.selected.delete(cb.dataset.item);
  };
  $('match').onsubmit = (ev) => { ev.preventDefault(); searchMatches(); };
  $('compress').onclick = (ev) => {
    if (ev.target === $('compress') || ev.target.closest('[data-close]')) { $('compress').close(); cctx = null; return; }
    if (ev.target.closest('[data-cest]')) queueCompression('ce');
    if (ev.target.closest('[data-cgo]')) queueCompression('c');
  };
  $('compress').onchange = (ev) => {
    if (!cctx) return;
    const t = ev.target;
    if (t.name === 'preset') cctx.preset = t.value;
    else if (t.name === 'audio') cctx.audio = t.value;
    else if (t.name === 'codec') cctx.codec = t.value;
    else if (t.dataset.rule) t.checked ? cctx.rules.add(t.dataset.rule) : cctx.rules.delete(t.dataset.rule);
    renderCompress();
  };
  $('jobs').onclick = async (ev) => {
    if (ev.target === $('jobs') || ev.target.closest('[data-close]')) { $('jobs').close(); return; }
    const hp = ev.target.closest('[data-hpause]');
    if (hp) {
      hp.disabled = true; hp.textContent = 'Sending…';
      const cmd = { cmd: 'pause', pc: hp.dataset.hpause, on: hp.dataset.on === '1' };
      try { if (state.demo) rips.demoCommand(cmd); else await rips.command(cmd); } catch (err) { alert(err.message); renderJobs(); }
      return;
    }
    const bb = ev.target.closest('[data-bench]');
    if (bb) {
      const stop = bb.dataset.bstop === '1';
      if (!stop && !confirm(`Benchmark the encoders on ${bb.dataset.bench}?\n\nIt measures quality, size and speed on a couple of your films (about 20-60 minutes), so that PC picks the right setting for each quality level and this dashboard can show real estimates. It waits for running jobs to finish, holds new ones until it's done, and pauses for Plex streams and games.`)) return;
      bb.disabled = true; bb.textContent = 'Sending…';
      const cmd = { cmd: 'benchmark', pc: bb.dataset.bench, stop };
      try { if (state.demo) rips.demoCommand(cmd); else await rips.command(cmd); } catch (err) { alert(err.message); renderJobs(); }
      return;
    }
    const tr = ev.target.closest('[data-trash]');
    if (tr) { $('jobs').close(); openTrashConfirm(tr.dataset.trash); return; }
    if (ev.target.closest('[data-ripoff]')) { rips.disconnect(); rips.stop(); renderRip(); renderJobs(); return; }
    if (ev.target.closest('[data-ripon]')) {
      if (rips.connect($('rip-topic').value)) { rips.start(liveChanged); renderJobs(); } else { $('rip-topic').value = ''; $('rip-topic').placeholder = "That doesn't look like the link or topic from setup"; }
      return;
    }
    const nb = ev.target.closest('[data-notify]');
    if (nb) {
      if (nb.dataset.notify === 'on') await notify.turnOn(); else notify.turnOff();
      renderJobs();
      return;
    }
    const b = ev.target.closest('[data-cancel],[data-clear],[data-stop]'); if (!b) return;
    const j = jobFromRow(+(b.dataset.cancel ?? b.dataset.clear ?? b.dataset.stop)); if (!j) return;
    if (b.dataset.stop !== undefined && !confirm(`Stop compressing ${j.title}? The work done so far is thrown away; the original is untouched.`)) return;
    b.disabled = true;
    try {
      const api = state.servers[j.serverId]?.api;
      if (b.dataset.stop !== undefined) { if (state.demo) state.demoJobs.stop(j); else await jobsApi.stopJob(api, j); }
      else if (state.demo) state.demoJobs.remove(j);
      else await jobsApi.removeJob(api, j);
    } catch (err) { b.disabled = false; b.textContent = 'Failed, retry'; console.error(err); return; }
    await refreshJobs();
  };
  $('search').oninput = (ev) => { state.q = ev.target.value; renderGrid(); };
  $('sort').onchange = (ev) => { state.sort = ev.target.value; savePrefs(); renderGrid(); };
  $('loc').onchange = (ev) => { state.loc = ev.target.value; savePrefs(); render(); };
  document.querySelector('.tabs').onclick = (ev) => {
    const t = ev.target.closest('[data-tab]'); if (!t) return;
    state.tab = t.dataset.tab; state.filter = 'all'; savePrefs(); render();
  };
  $('chips').onclick = (ev) => { const c = ev.target.closest('[data-f]'); if (!c) return; state.filter = c.dataset.f; savePrefs(); renderChips(); renderGrid(); };
  $('locations').onclick = (ev) => { const c = ev.target.closest('[data-loc]'); if (!c) return; state.loc = state.loc === c.dataset.loc ? '' : c.dataset.loc; savePrefs(); render(); };
  $('grid').onclick = (ev) => { const c = ev.target.closest('[data-i]'); if (c) openDetail(current[+c.dataset.i]); };
  $('detail').onclick = async (ev) => {
    if (ev.target === $('detail') || ev.target.closest('[data-close]')) { $('detail').close(); openEntry = null; return; }
    if (ev.target.closest('[data-fixmatch]') && openEntry) { openMatch(openEntry); return; }
    const q = ev.target.closest('[data-q]');
    if (q && openEntry?.kind === 'movie') { confirmQuarantine(openEntry, [openEntry.versions[+q.dataset.q]]); return; }
    // Shows: clean up duplicates / quarantine a season or the whole show
    if (openEntry?.kind === 'show') {
      const s = openEntry;
      const eps = (sel) => (sel === 'all' ? s.seasons : s.seasons.filter((se) => String(se.season) === sel)).flatMap((se) => se.eps);
      const scopeOf = (sel) => (sel === 'all' ? 'all' : `S${String(sel).padStart(2, '0')}`);
      const sc = ev.target.closest('[data-scompress]');
      if (sc) { const v = showCopy(s, sc.dataset.scompress); if (v) openCompress(s, v); return; }
      const sr = ev.target.closest('[data-sreplace]');
      if (sr) { confirmShowQuarantine(s, replaceTargets(s, eps(sr.dataset.sreplace)), 'qm', `replace-${scopeOf(sr.dataset.sreplace)}`); return; }
      const sd = ev.target.closest('[data-sdupes]');
      if (sd) { confirmShowQuarantine(s, dupeTargets(s, eps(sd.dataset.sdupes)), 'qm', `dupes-${scopeOf(sd.dataset.sdupes)}`); return; }
      const sq = ev.target.closest('[data-sq]');
      if (sq) { confirmShowQuarantine(s, allTargets(s, eps(sq.dataset.sq)), 'qma', scopeOf(sq.dataset.sq)); return; }
      const ed = ev.target.closest('[data-edupe]');
      if (ed) {
        const [sn, en] = ed.dataset.edupe.split('x').map(Number);
        const ep = s.seasons.flatMap((se) => se.eps).find((x) => x.season === sn && x.ep === en);
        if (ep) confirmShowQuarantine(s, dupeTargets(s, [ep]), 'qm', `dupes-${epCode(ep)}`);
        return;
      }
    }
    const cb = ev.target.closest('[data-compress]');
    if (cb && openEntry?.kind === 'movie') { openCompress(openEntry, openEntry.versions[+cb.dataset.compress]); return; }
    const rp = ev.target.closest('[data-replace]');
    if (rp && openEntry?.kind === 'movie') {
      const keep = openEntry.versions[+rp.dataset.replace];
      const originals = openEntry.versions.filter((o) => o !== keep && !o.compressed && !o.missing && !activeJob(o));
      if (originals.length) confirmQuarantine(openEntry, originals);
      return;
    }
    if (ev.target.closest('[data-keepbest]') && openEntry?.kind === 'movie') {
      const rest = keepBestTargets(openEntry);
      if (rest?.length) confirmQuarantine(openEntry, rest);
      return;
    }
    const cp = ev.target.closest('[data-copy]');
    if (cp) {
      try { await navigator.clipboard.writeText(cp.dataset.copy); cp.textContent = 'Copied'; }
      catch { const r = document.createRange(); r.selectNodeContents(cp.previousElementSibling); getSelection().removeAllRanges(); getSelection().addRange(r); cp.textContent = 'Press Ctrl+C'; }
      setTimeout(() => { cp.textContent = 'Copy'; }, 1500);
    }
  };
}

function startDemo() {
  state.demo = true; state.snapshots = demoSnapshots(); state.jobs = [];
  rips.demoHelpers(); rips.demo(liveChanged);
  state.demoJobs = new jobsApi.DemoJobs(() => refreshJobs());
  rebuild(); render(); status('Sample data');
}

// ---------- Start ----------

async function start() {
  loadPrefs(); bind(); loadHelperDownload();
  rips.takeFromUrl();   // opened from the helper's setup link: remember its ntfy topic
  window.addEventListener('hashchange', () => { if (rips.takeFromUrl()) rips.start(liveChanged); });   // …or pasted into an open tab
  setInterval(renderRip, 30000);   // so 'No update for …' stays true
  try {
    const t = await plex.finishSignIn();
    if (t) history.replaceState(null, '', location.pathname);
  } catch (err) { $('login-error').textContent = err.message; $('login-error').hidden = false; }
  state.token = plex.getToken();
  if (new URLSearchParams(location.search).has('demo')) { startDemo(); return; }
  if (!state.token) { render(); return; }
  rips.start(liveChanged);   // live rip progress, if this device is connected to the helper's ntfy topic
  state.snapshots = await cache.loadAll();
  rebuild(); render();
  if (state.snapshots.length) status(`Showing last scan from ${timeAgo(Math.max(...state.snapshots.map((s) => s.lastSeen)))}`);
  sync();
}

start();
