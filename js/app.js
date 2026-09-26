import * as plex from './plex.js';
import * as cache from './cache.js';
import { demoSnapshots } from './demo.js';
import * as jobsApi from './jobs.js';
import * as cz from './compress.js';
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
const SHOW_CHIPS = [['all', 'All'], ['dupes', 'Duplicate episodes'], ['unmatched', 'Unmatched'], ['4K', '4K'], ['1080p', '1080p'], ['720p', '720p'], ['SD', 'SD / 480p'], ['big', 'Over 100 GB']];

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
const HELPER_LINK = '<a href="download/Plex-Library-Helper.zip" download>get the Library Helper</a>';

function quarantineAction(v, i) {
  const j = jobFor(v);
  if (j && j.state !== 'fail') {
    const label = { queued: 'Quarantine queued', run: 'Quarantining…', done: 'Quarantined' }[j.state] || j.state;
    const waiting = j.state === 'queued' && Date.now() - j.created > 90000 ? `<span class="fine">Waiting for the Library Helper on ${esc(v.machine)}. Is it running? Not installed yet? ${HELPER_LINK}.</span>` : '';
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
  if (c && ACTIVE.includes(c.state)) out.push(progressHtml(c, v));
  else if (c?.state === 'done') {
    const o = cz.decodeInfo(c.info);
    out.push(`<div class="cstat"><span class="pill done">Compressed</span> ${esc(cz.presetById(o.p)?.label || '')}: ${fmtSize(Number(o.s) || v.size)} → <b>${fmtSize(Number(o.b))}</b>. The new copy appears here once Plex has scanned it; then choose <b>Replace original…</b> on it, or keep both.</div>`);
  } else if (c?.state === 'fail') out.push(`<div class="cstat"><span class="pill fail">Compression failed</span> ${esc(c.info)}</div>`);
  const est = jobFor(v, 'ce');
  if (est && (!c || est.created > c.created)) {
    if (ACTIVE.includes(est.state)) out.push(progressHtml(est, v));
    else if (est.state === 'done') {
      const o = cz.decodeInfo(est.info);
      out.push(`<div class="cstat"><span class="pill">Estimate</span> ${esc(cz.presetById(o.p)?.label || '')}: ${esc(cz.estimateText(est.info, v))}</div>`);
    } else if (est.state === 'fail') out.push(`<div class="cstat"><span class="pill fail">Estimate failed</span> ${esc(est.info)}</div>`);
  }
  return out.join('');
}

function progressHtml(j, v) {
  const est = j.action === 'ce';
  const preset = cz.presetById(cz.jobPreset(j))?.label || '';
  const verb = est ? 'Estimating' : 'Compressing';
  if (j.state === 'queued') {
    const late = Date.now() - j.created > 90000 ? ` Waiting for the Library Helper on the PC with the graphics card. Is it running, and did you answer yes to compression in its setup? It also waits while another encode is running. Not installed yet? ${HELPER_LINK}.` : '';
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
  renderJobsButton();
  if ($('jobs').open) renderJobs();
  if (openEntry) renderDetail();
  if ($('compress').open) renderCompress();
  clearTimeout(jobTimer);
  if (state.jobs.some((j) => ACTIVE.includes(j.state))) jobTimer = setTimeout(refreshJobs, state.demo ? 1000 : 10000);
  if (finished && !state.demo) setTimeout(sync, 8000); // let Plex notice the change, then rescan
}

function renderJobsButton() {
  const active = state.jobs.filter((j) => ACTIVE.includes(j.state)).length;
  $('jobs-btn').innerHTML = `Jobs${active ? `<span class="count">${active}</span>` : ''}`;
}

function jobDescription(j) {
  const v = findVersion(j);
  const where = v ? `${v.res} · ${fmtSize(v.size)} · ${v.machine} · ${v.drive}` : `copy ${j.mediaId}`;
  if (j.kind === 'compress') {
    const preset = cz.presetById(cz.jobPreset(j))?.label || '';
    const what = `${j.action === 'ce' ? 'Estimate' : 'Compress'}${preset ? ` (${preset})` : ''}`;
    let info = '';
    if (j.state === 'run') {
      const r = cz.parseRun(j.info);
      info = `${Math.round(r.percent)}%${r.secsLeft ? ` · about ${cz.fmtDuration(r.secsLeft)} left` : ''} · ${r.paused ? `paused: ${r.paused}` : r.what}`;
    } else if (j.state === 'done' && j.action === 'ce') info = cz.estimateText(j.info, v);
    else if (j.state === 'done') { const o = cz.decodeInfo(j.info); info = `${fmtSize(Number(o.s))} → ${fmtSize(Number(o.b))}, the original is untouched`; }
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
    <div class="sub fine">The Library Helper does these jobs on your PCs: ${HELPER_LINK} (the same download for every PC; its setup asks whether that PC should do compression).</div></div>
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
  pending = { e, versions };
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

function showDetail(s) {
  const rows = s.seasons.map((se) => `<tr>
    <td>${se.season === 0 ? 'Specials' : `Season ${se.season}`}</td>
    <td class="n">${se.eps.length}</td>
    <td class="n">${fmtSize(se.size)}</td>
    <td class="hide-sm">${Object.entries(se.res).map(([r, n]) => `${esc(r)} ×${n}`).join(', ')}</td>
    <td class="hide-sm">${se.locs.map((id) => esc(locName(state.locations.find((l) => l.id === id) || { machine: '?', drive: id }))).join('<br>')}</td>
    <td class="n">${se.dupes ? `<span class="b dup">${se.dupes}</span>` : '—'}</td></tr>`).join('');
  const dupeEps = s.seasons.flatMap((se) => se.eps.filter((ep) => ep.dupes));
  return `<div class="db">
    <table class="seasons"><thead><tr><th>Season</th><th class="n">Eps</th><th class="n">Size</th><th class="hide-sm">Quality</th><th class="hide-sm">Drive</th><th class="n">Dupes</th></tr></thead><tbody>${rows}</tbody></table>
    ${dupeEps.length ? `<details class="dupeps"><summary>${dupeEps.length} duplicated episode${dupeEps.length === 1 ? '' : 's'} · ${fmtSize(s.extra)} extra</summary>
      ${dupeEps.map((ep) => `<h4>S${String(ep.season).padStart(2, '0')}E${String(ep.ep).padStart(2, '0')} · ${esc(ep.title)}</h4>${ep.versions.map((v, i) => versionHtml(v, ep, i)).join('')}`).join('')}
    </details>` : ''}
  </div>`;
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
  cctx = { e, v, preset, audio: eo.a || saved.audio || 'keep', rules: new Set(saved.rules || cz.RULES.filter((r) => r.on).map((r) => r.id)), error: '', busy: false };
  renderCompress();
  $('compress').showModal();
}

function dvLine(p, v) {
  if (v.dv) return p.dv ? 'Keeps Dolby Vision' : 'Dolby Vision and HDR become normal colour (SDR)';
  if (v.hdr) return p.height === 1080 ? 'HDR becomes normal colour (SDR)' : 'Keeps HDR';
  return '';
}

function renderCompress() {
  const c = cctx; if (!c) return;
  const { e, v } = c;
  const p = cz.presetById(c.preset);
  const opts = cz.encodeOptions({ preset: c.preset, audio: c.audio, rules: [...c.rules] });
  // The latest estimate for exactly these settings
  const ests = state.jobs.filter((j) => j.kind === 'compress' && j.action === 'ce' && j.serverId === v.serverId && String(j.mediaId) === String(v.mediaId)).sort((a, b) => b.created - a.created);
  const est = ests.find((j) => { const o = j.state === 'run' ? { p: cz.jobPreset(j) } : cz.decodeInfo(j.info); return o.p === c.preset && (!o.a || o.a === c.audio || j.state === 'run'); });
  const estRunning = est && ACTIVE.includes(est.state);
  let estHtml = '';
  if (est?.state === 'done') {
    const o = cz.decodeInfo(est.info);
    estHtml = `<div class="cest"><b>Estimate from 3 samples of this film:</b> ${esc(cz.estimateText(est.info, v))}${o.q ? `<div class="fine">Quality ${esc(o.q)}: ${esc(cz.qualityWords(o.q))}.</div>` : ''}</div>`;
  } else if (estRunning) estHtml = progressHtml(est, v);
  else if (est?.state === 'fail') estHtml = `<div class="cest error">Estimate failed: ${esc(est.info)}</div>`;

  $('compress-body').innerHTML = `<div class="dh"><div><h2>Compress ${esc(e.title)}${e.year ? ` (${e.year})` : ''}</h2>
      <div class="sub">This copy: ${esc(v.res)} · ${esc(v.src)} · ${fmtSize(v.size)}${v.dv ? ' · Dolby Vision' : v.hdr ? ' · HDR' : ''}${v.duration ? ` · ${cz.fmtDuration(v.duration / 1000)}` : ''}</div></div>
      <div class="hbtns"><button class="btn ghost small" data-close>Close</button></div></div>
    <div class="db">
      <h3 class="ch">Quality</h3>
      <div class="presets">${cz.PRESETS.map((q) => {
        const fits = cz.presetFits(q, v); const g = cz.roughGuess(q, v, c.audio);
        return `<label class="preset${fits ? '' : ' off'}${q.id === c.preset ? ' on' : ''}">
          <input type="radio" name="preset" value="${q.id}" ${q.id === c.preset ? 'checked' : ''} ${fits ? '' : 'disabled'}>
          <div><div class="t">${esc(q.label)} <span class="b">${esc(q.where)}</span></div>
          <div class="m">${esc(q.note)}</div>
          ${fits ? `<div class="m">${g.little ? '<b>Little to gain: this copy is already fairly compact.</b> ' : ''}Typically about ${fmtSize(g.bytes)} (${Math.round((g.bytes / v.size) * 100)}%)${g.secs ? ` · about ${cz.fmtDuration(g.secs)}` : ''}${dvLine(q, v) ? ` · ${esc(dvLine(q, v))}` : ''}</div>` : '<div class="m">Needs a bigger source than this copy.</div>'}</div></label>`;
      }).join('')}</div>
      <h3 class="ch">Audio</h3>
      <div class="opts">
        <label><input type="radio" name="audio" value="keep" ${c.audio === 'keep' ? 'checked' : ''}> Keep all original audio <span class="fine">(${esc(fmtAudio(v) || 'as is')}, every language and commentary)</span></label>
        <label><input type="radio" name="audio" value="small" ${c.audio === 'small' ? 'checked' : ''}> Smaller: one main track <span class="fine">(uses the disc's Dolby Digital Plus track if it has one, which often keeps Atmos; otherwise 5.1 Dolby Digital Plus. Lossless TrueHD/DTS-HD is dropped.)</span></label>
      </div>
      <h3 class="ch">When</h3>
      <div class="opts">${cz.RULES.map((r) => `<label><input type="checkbox" data-rule="${r.id}" ${c.rules.has(r.id) ? 'checked' : ''}> ${esc(r.label)}</label>`).join('')}</div>
      ${estHtml}
      <p class="note">The Library Helper on the PC with the graphics card does the work (${HELPER_LINK} if it isn't installed; answer yes to compression in its setup). The original is never changed: the compressed copy is added next to it, checked, and shows up in Plex as a second version. Replacing the original is a separate step afterwards. Grainy films shrink much less than the typical figures; <b>Estimate</b> encodes three short samples of this film (a few minutes) to tell you the real size, time and quality first.</p>
      ${c.error ? `<p class="error">${esc(c.error)}</p>` : ''}
      <div class="foot">
        <button class="btn" data-cest ${estRunning || c.busy || !p ? 'disabled' : ''}>${estRunning ? 'Estimating…' : est?.state === 'done' ? 'Estimate again' : 'Estimate first'}</button>
        <button class="btn primary" data-cgo ${c.busy || !p ? 'disabled' : ''}>Start compressing</button>
      </div>
    </div>`;
  $('compress-body').dataset.opts = opts;
}

async function queueCompression(action) {
  const c = cctx; if (!c || c.busy) return;
  const p = cz.presetById(c.preset); if (!p) return;
  try { localStorage.setItem(CPREFS, JSON.stringify({ preset: c.preset, audio: c.audio, rules: [...c.rules] })); } catch { /* ignore */ }
  c.busy = true; c.error = ''; renderCompress();
  try {
    if (c.v.missing || !c.v.checked) throw new Error('the file is missing or hasn\'t been checked yet');
    const opts = cz.encodeOptions({ preset: c.preset, audio: c.audio, rules: [...c.rules] });
    if (state.demo) state.demoJobs.queueCompress(c.v, c.e, action, opts, cz.roughGuess(p, c.v, c.audio));
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
  $('jobs-btn').onclick = () => { renderJobs(); $('jobs').showModal(); refreshJobs(); };
  $('confirm').onclick = (ev) => {
    if (ev.target === $('confirm') || ev.target.closest('[data-close]')) { $('confirm').close(); pending = null; return; }
    if (ev.target.closest('[data-go]')) runQuarantine();
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
    else if (t.dataset.rule) t.checked ? cctx.rules.add(t.dataset.rule) : cctx.rules.delete(t.dataset.rule);
    renderCompress();
  };
  $('jobs').onclick = async (ev) => {
    if (ev.target === $('jobs') || ev.target.closest('[data-close]')) { $('jobs').close(); return; }
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
  state.demoJobs = new jobsApi.DemoJobs(() => refreshJobs());
  rebuild(); render(); status('Sample data');
}

// ---------- Start ----------

async function start() {
  loadPrefs(); bind();
  try {
    const t = await plex.finishSignIn();
    if (t) history.replaceState(null, '', location.pathname);
  } catch (err) { $('login-error').textContent = err.message; $('login-error').hidden = false; }
  state.token = plex.getToken();
  if (new URLSearchParams(location.search).has('demo')) { startDemo(); return; }
  if (!state.token) { render(); return; }
  state.snapshots = await cache.loadAll();
  rebuild(); render();
  if (state.snapshots.length) status(`Showing last scan from ${timeAgo(Math.max(...state.snapshots.map((s) => s.lastSeen)))}`);
  sync();
}

start();
