// Plex API client: "Sign in with Plex" (PIN flow), server discovery, and library reads.
// All calls go straight from the browser to plex.tv and your own Plex servers.
// Auth values travel as query parameters so requests stay CORS "simple" (no preflight).

const PRODUCT = 'Plex Library Dashboard';
const VERSION = '0.1.0';
const TOKEN_KEY = 'pld.token';
const CLIENT_KEY = 'pld.clientId';
const PIN_KEY = 'pld.pendingPin';

function store(kind) {
  try { return kind === 'session' ? window.sessionStorage : window.localStorage; } catch { return null; }
}
function get(key, kind) { try { return store(kind)?.getItem(key) ?? null; } catch { return null; } }
function set(key, val, kind) { try { store(kind)?.setItem(key, val); } catch { /* storage blocked */ } }
function del(key, kind) { try { store(kind)?.removeItem(key); } catch { /* storage blocked */ } }

export function clientId() {
  let id = get(CLIENT_KEY);
  if (!id) { id = crypto.randomUUID(); set(CLIENT_KEY, id); }
  return id;
}

function plexParams(extra = {}) {
  return new URLSearchParams({
    'X-Plex-Product': PRODUCT,
    'X-Plex-Version': VERSION,
    'X-Plex-Client-Identifier': clientId(),
    'X-Plex-Platform': 'Web',
    'X-Plex-Device-Name': 'Library Dashboard',
    ...extra,
  });
}

async function getJson(url, { method = 'GET', timeout = 15000 } = {}) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeout);
  try {
    const res = await fetch(url, { method, headers: { Accept: 'application/json' }, signal: ctrl.signal });
    if (!res.ok) throw new Error(`HTTP ${res.status} from ${new URL(url).host}`);
    const text = await res.text();
    return text ? JSON.parse(text) : {};
  } finally {
    clearTimeout(timer);
  }
}

// ---------- Auth ----------

export function getToken() { return get(TOKEN_KEY); }
export function signOut() { del(TOKEN_KEY); del(PIN_KEY, 'session'); }

function authUrl(code, forwardUrl) {
  const q = new URLSearchParams({ clientID: clientId(), code, 'context[device][product]': PRODUCT });
  if (forwardUrl) q.set('forwardUrl', forwardUrl);
  return `https://app.plex.tv/auth#?${q}`;
}

async function checkPin(id) {
  const pin = await getJson(`https://plex.tv/api/v2/pins/${encodeURIComponent(id)}?${plexParams()}`);
  return pin.authToken || null;
}

// Opens Plex's sign-in in a pop-up (or new tab on phones) and waits here for it to complete.
// If pop-ups are blocked, falls back to sending this tab to Plex and back (finishSignIn picks it up).
// onStatus(text) reports progress; resolves with the token.
export async function signIn(onStatus = () => {}, { sameTab = false } = {}) {
  const popup = sameTab ? null : window.open('', 'plex-auth', 'width=520,height=720');
  onStatus('Asking Plex for a sign-in code…');
  let pin;
  try {
    pin = await getJson(`https://plex.tv/api/v2/pins?strong=true&${plexParams()}`, { method: 'POST' });
  } catch (err) { popup?.close(); throw err; }
  set(PIN_KEY, String(pin.id), 'session');

  if (!popup || popup.closed) {
    onStatus('Opening Plex…');
    location.href = authUrl(pin.code, location.href.split(/[?#]/)[0]);
    return new Promise(() => {}); // page is navigating away
  }
  popup.location.href = authUrl(pin.code);
  onStatus('Finish signing in in the Plex window…');

  const deadline = Date.now() + 10 * 60 * 1000;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 1500));
    const token = await checkPin(pin.id).catch(() => null);
    if (token) {
      set(TOKEN_KEY, token); del(PIN_KEY, 'session');
      try { popup.close(); } catch { /* already closed */ }
      return token;
    }
    if (popup.closed) {
      // Give Plex a moment in case the window closed right after approving
      const late = await checkPin(pin.id).catch(() => null);
      if (late) { set(TOKEN_KEY, late); del(PIN_KEY, 'session'); return late; }
      del(PIN_KEY, 'session');
      throw new Error('The Plex window was closed before sign-in finished.');
    }
  }
  del(PIN_KEY, 'session');
  throw new Error('Sign-in timed out. Try again.');
}

// Called on page load: if this tab was sent to app.plex.tv and back, trade the PIN for a token.
export async function finishSignIn() {
  const pinId = get(PIN_KEY, 'session');
  if (!pinId) return null;
  for (let i = 0; i < 20; i++) {
    const token = await checkPin(pinId).catch(() => null);
    if (token) { set(TOKEN_KEY, token); del(PIN_KEY, 'session'); return token; }
    await new Promise((r) => setTimeout(r, 1000));
  }
  del(PIN_KEY, 'session');
  throw new Error("Plex didn't confirm the sign-in. If Plex's page didn't let you finish, try again.");
}

export async function getUser(token) {
  return getJson(`https://plex.tv/api/v2/user?${plexParams({ 'X-Plex-Token': token })}`);
}

// ---------- Servers ----------

export async function getServers(token) {
  const res = await getJson(`https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1&${plexParams({ 'X-Plex-Token': token })}`);
  return res
    .filter((r) => (r.provides || '').split(',').includes('server'))
    .map((r) => ({
      id: r.clientIdentifier,
      name: r.name,
      owned: !!r.owned,
      token: r.accessToken || token,
      presence: !!r.presence,
      connections: r.connections || [],
    }));
}

// Try local addresses first, then remote, then Plex's relay. First one to answer wins.
export async function connect(server) {
  const https = location.protocol === 'https:';
  const usable = server.connections.filter((c) => !(https && c.protocol === 'http'));
  const tiers = [
    usable.filter((c) => c.local && !c.relay),
    usable.filter((c) => !c.local && !c.relay),
    usable.filter((c) => c.relay),
  ].filter((t) => t.length);
  for (const [i, tier] of tiers.entries()) {
    const timeout = i === 0 ? 3000 : 6000;
    try {
      return await Promise.any(tier.map(async (c) => {
        await getJson(`${c.uri}/identity?X-Plex-Token=${encodeURIComponent(server.token)}`, { timeout });
        return { uri: c.uri, relay: !!c.relay, local: !!c.local };
      }));
    } catch { /* try the next tier */ }
  }
  throw new Error(`Couldn't reach ${server.name}. Is the PC on and Plex running?`);
}

export class ServerApi {
  constructor(server, conn) { this.server = server; this.conn = conn; }

  url(path, params = {}) {
    const q = new URLSearchParams({ ...params, 'X-Plex-Token': this.server.token, 'X-Plex-Client-Identifier': clientId() });
    return `${this.conn.uri}${path}${path.includes('?') ? '&' : '?'}${q}`;
  }

  async get(path, params) { return (await getJson(this.url(path, params), { timeout: 30000 })).MediaContainer || {}; }

  async all(path, params = {}, onPage) {
    const size = 400; let start = 0; const out = [];
    for (;;) {
      const mc = await this.get(path, { ...params, 'X-Plex-Container-Start': start, 'X-Plex-Container-Size': size });
      const page = mc.Metadata || [];
      out.push(...page);
      onPage?.(out.length, mc.totalSize ?? mc.size);
      if (page.length < size) return out;
      start += size;
    }
  }

  sections() { return this.get('/library/sections').then((mc) => mc.Directory || []); }
  movies(key, onPage) { return this.all(`/library/sections/${key}/all`, { type: 1, includeGuids: 1 }, onPage); }
  shows(key) { return this.all(`/library/sections/${key}/all`, { type: 2, includeGuids: 1 }); }
  episodes(key, onPage) { return this.all(`/library/sections/${key}/all`, { type: 4, includeGuids: 1 }, onPage); }
  metadata(ratingKey, params) { return this.get(`/library/metadata/${ratingKey}`, params).then((mc) => (mc.Metadata || [])[0]); }

  // ----- matching (same calls Plex's own "Fix Match" uses) -----
  async searchMatches(ratingKey, title, year) {
    const params = { manual: 1, title };
    if (year) params.year = year;
    return (await this.get(`/library/metadata/${ratingKey}/matches`, params)).SearchResult || [];
  }
  applyMatch(ratingKey, r) {
    return this.put(`/library/metadata/${ratingKey}/match`, { guid: r.guid, name: r.name, ...(r.year ? { year: r.year } : {}) });
  }
  refreshItem(ratingKey) { return this.put(`/library/metadata/${ratingKey}/refresh`, {}); }

  // ----- labels (the job mailbox; see helper/library-helper.ps1) -----
  async put(path, params) { await getJson(this.url(path, params), { method: 'PUT', timeout: 30000 }); }
  sectionLabels(key) { return this.get(`/library/sections/${key}/label`).then((mc) => mc.Directory || []); }
  // type 1 = movies, 2 = shows (show jobs live on the show)
  itemsWithLabel(key, labelKey, type = 1) { return this.get(`/library/sections/${key}/all`, { type, label: labelKey }).then((mc) => mc.Metadata || []); }
  async itemLabels(ratingKey) { return ((await this.metadata(ratingKey))?.Label || []).map((l) => l.tag); }
  async addLabel(sectionId, ratingKey, tag, type = 1) {
    const keep = (await this.itemLabels(ratingKey)).filter((t) => t !== tag);
    const params = { type, id: ratingKey, 'label.locked': 1 };
    [...keep, tag].forEach((t, i) => { params[`label[${i}].tag.tag`] = t; });
    await this.put(`/library/sections/${sectionId}/all`, params);
  }
  removeLabel(sectionId, ratingKey, tag, type = 1) {
    return this.put(`/library/sections/${sectionId}/all`, { type, id: ratingKey, 'label[].tag.tag-': tag });
  }

  poster(thumb, w = 240) {
    if (!thumb) return null;
    return this.url('/photo/:/transcode', { width: w, height: Math.round(w * 1.5), minSize: 1, upscale: 1, url: thumb });
  }
}
