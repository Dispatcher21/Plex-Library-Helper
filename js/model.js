// Turns raw Plex metadata into the dashboard's library model:
// one entry per movie/show (merged across servers and libraries), each with every copy ("version").

const RES = { '4k': ['4K', 4], '2160': ['4K', 4], '1080': ['1080p', 3], '720': ['720p', 2], '576': ['SD', 1], '480': ['SD', 1], sd: ['SD', 1] };
const LOSSLESS = new Set(['truehd', 'flac', 'pcm', 'alac', 'mlp']);

export const GB = 1024 ** 3;

function guidKey(guids, fallback) {
  const ids = (guids || []).map((g) => g.id);
  return ids.find((i) => i.startsWith('tmdb://')) || ids.find((i) => i.startsWith('imdb://')) || ids.find((i) => i.startsWith('tvdb://')) || fallback;
}
function titleKey(title, year) {
  return `title://${String(title || '').toLowerCase().replace(/^(the|a|an) /, '').replace(/[^a-z0-9]/g, '')}${year ? `-${year}` : ''}`;
}

// Where a file lives: UNC shares become "MACHINE / Share", drive letters become "Server / X:"
export function locationOf(path, serverName) {
  const unc = /^\\\\([^\\]+)\\([^\\]+)/.exec(path || '');
  if (unc) return { id: `${unc[1].toUpperCase()}/${unc[2].toLowerCase()}`, machine: unc[1].toUpperCase(), drive: unc[2] };
  const drv = /^([A-Za-z]):[\\/]/.exec(path || '');
  if (drv) return { id: `${serverName}/${drv[1].toUpperCase()}:`, machine: serverName, drive: `${drv[1].toUpperCase()}:` };
  const nix = /^\/(mnt|media|Volumes)\/([^/]+)/.exec(path || '');
  if (nix) return { id: `${serverName}/${nix[2]}`, machine: serverName, drive: nix[2] };
  return { id: `${serverName}/other`, machine: serverName, drive: 'Other' };
}

// Files the Library Helper made: "<Title> (<Year>) - Compressed 4K High.mkv"
export const COMPRESSED = /\s-\sCompressed\s(4K|1080p)\b/i;

function sourceOf(text, res, bitrate) {
  if (COMPRESSED.test(text)) return 'Compressed';
  if (/_t\d{2}\.mkv$/i.test(text)) return 'Disc rip';
  if (/remux/i.test(text)) return 'Remux';
  if ((res === '4K' && bitrate > 45000) || (res === '1080p' && bitrate > 25000)) return 'Remux';
  if (/web-?dl|webrip|\bweb\b/i.test(text)) return 'WEB';
  return 'Encode';
}

export function versionsOf(item, server, section) {
  return (item.Media || []).map((m) => {
    const parts = m.Part || [];
    const files = parts.map((p) => p.file).filter(Boolean);
    const size = parts.reduce((a, p) => a + (p.size || 0), 0);
    const [res, rank] = RES[String(m.videoResolution || '').toLowerCase()] || (m.height >= 1600 ? RES['4k'] : m.height >= 900 ? RES['1080'] : m.height >= 650 ? RES['720'] : RES.sd);
    const file = files[0] || '';
    const segs = file.split(/[\\/]/);
    const name = segs.pop();
    const tagText = `${segs.pop() || ''} ${name}`; // release tags often live in the folder name

    const acodec = String(m.audioCodec || '').toLowerCase();
    const loc = locationOf(file, server.name);
    return {
      serverId: server.id, sectionId: String(section?.key ?? item.librarySectionID ?? ''), ratingKey: item.ratingKey, mediaId: m.id,
      res, rank, height: m.height || 0, vcodec: String(m.videoCodec || '').toUpperCase(), bitrate: m.bitrate || 0,
      acodec, ch: m.audioChannels || 0, container: m.container || '', size, files, name, duration: m.duration || item.duration || 0,
      compressed: COMPRESSED.test(name),
      loc: loc.id, machine: loc.machine, drive: loc.drive,
      src: sourceOf(tagText, res, m.bitrate || 0),
      dv: /\b(DV|DoVi|Dolby[ .]?Vision)\b/i.test(tagText),
      hdr: /\bHDR(10\+?)?\b|\bHLG\b/i.test(tagText) || /\b(DV|DoVi)\b/i.test(tagText),
      atmos: /atmos/i.test(tagText),
      lossless: LOSSLESS.has(acodec) || (acodec === 'dca' && /\bMA\b|DTS-?HD[ .]?MA/i.test(tagText)),
      exact: false,
    };
  });
}

// Plex gives unmatched items a local:// (or "none" agent) guid and no external IDs
export function isUnmatched(guid, guids) { return !guid || /^(local:|com\.plexapp\.agents\.none)/.test(guid) || (guids !== undefined && !guids?.length && !/^plex:/.test(guid)); }

export function normalizeMovies(items, server, section) {
  return items.map((it) => ({
    k: guidKey(it.Guid, titleKey(it.title, it.year)),
    title: it.title, year: it.year || null, thumb: it.thumb || null, serverId: server.id,
    ratingKey: String(it.ratingKey), sectionId: String(section?.key ?? it.librarySectionID ?? ''), unmatched: isUnmatched(it.guid, it.Guid),
    section: section.title, addedAt: it.addedAt || 0, versions: versionsOf(it, server, section),
  }));
}

export function normalizeEpisodes(episodes, shows, server, section) {
  const showBy = new Map(shows.map((s) => [String(s.ratingKey), s]));
  return episodes.map((e) => {
    const s = showBy.get(String(e.grandparentRatingKey)) || {};
    return {
      showKey: guidKey(s.Guid, titleKey(e.grandparentTitle, s.year)),
      showRatingKey: String(e.grandparentRatingKey), showUnmatched: s.guid ? isUnmatched(s.guid, s.Guid) : false,
      showTitle: e.grandparentTitle, showYear: s.year || null, showThumb: s.thumb || e.grandparentThumb || null,
      serverId: server.id, section: section.title, season: e.parentIndex ?? 0, ep: e.index ?? 0, title: e.title,
      addedAt: e.addedAt || 0, versions: versionsOf(e, server, section),
    };
  });
}

// Higher is better: resolution, then source (remux/disc rip beat re-encodes), then Dolby Vision/HDR,
// then lossless audio, then bitrate
const SRC = { 'Disc rip': 3, Remux: 3, WEB: 1, Encode: 1, Compressed: 1 };
export function score(v) {
  if (v.missing) return -1; // a file that's gone can never be the one to keep
  return v.rank * 1e8 + (SRC[v.src] || 1) * 1e7 + (v.dv ? 2e6 : v.hdr ? 1e6 : 0) + (v.lossless ? 5e5 : 0) + Math.min(v.bitrate, 499999);
}

function identical(a, b) { return a.size === b.size && a.name === b.name; }

export function finishEntry(e) {
  e.versions.sort((a, b) => score(b) - score(a));
  e.size = e.versions.reduce((a, v) => a + v.size, 0);
  e.best = e.versions[0];
  const present = e.versions.filter((v) => !v.missing);
  e.dupes = present.length > 1;
  e.extra = e.dupes ? present.reduce((a, v) => a + v.size, 0) - e.best.size : 0;
  e.versions.forEach((v, i) => { v.identical = i > 0 && identical(v, e.best); });
  e.locs = [...new Set(e.versions.map((v) => v.loc))];
  return e;
}

export function buildMovies(records) {
  const map = new Map();
  for (const r of records) {
    let e = map.get(r.k);
    if (!e) { e = { kind: 'movie', k: r.k, title: r.title, year: r.year, thumb: r.thumb, thumbServer: r.serverId, addedAt: r.addedAt, versions: [], items: [], unmatched: false }; map.set(r.k, e); }
    if (!e.thumb && r.thumb) { e.thumb = r.thumb; e.thumbServer = r.serverId; }
    if (r.ratingKey && !e.items.some((i) => i.serverId === r.serverId && i.ratingKey === r.ratingKey)) e.items.push({ serverId: r.serverId, ratingKey: r.ratingKey, sectionId: r.sectionId, unmatched: !!r.unmatched });
    e.unmatched ||= !!r.unmatched;
    e.addedAt = Math.max(e.addedAt, r.addedAt);
    e.versions.push(...r.versions);
  }
  return [...map.values()].filter((e) => e.versions.length).map(finishEntry);
}

const range = (a, b) => Array.from({ length: Math.max(0, b - a + 1) }, (_, i) => a + i);

// Episode numbers missing from a season: gaps between 1 and the highest episode you have. The end of a
// season can't be checked (Plex doesn't say how many episodes a season has unless they're in the library).
function gaps(se) {
  if (se.season === 0) return []; // specials are rarely complete or in order
  const have = new Set(se.eps.map((e) => e.ep).filter((n) => n > 0));
  if (!have.size) return [];
  return range(1, Math.max(...have)).filter((n) => !have.has(n));
}

export function buildShows(records) {
  const map = new Map();
  for (const r of records) {
    let s = map.get(r.showKey);
    if (!s) { s = { kind: 'show', k: r.showKey, title: r.showTitle, year: r.showYear, thumb: r.showThumb, thumbServer: r.serverId, addedAt: 0, eps: new Map(), items: [], unmatched: false }; map.set(r.showKey, s); }
    if (!s.thumb && r.showThumb) { s.thumb = r.showThumb; s.thumbServer = r.serverId; }
    if (r.showRatingKey && !s.items.some((i) => i.serverId === r.serverId && i.ratingKey === r.showRatingKey)) s.items.push({ serverId: r.serverId, ratingKey: r.showRatingKey, sectionId: '', unmatched: !!r.showUnmatched });
    s.unmatched ||= !!r.showUnmatched;
    s.addedAt = Math.max(s.addedAt, r.addedAt);
    const ek = `${r.season}x${r.ep}`;
    let ep = s.eps.get(ek);
    if (!ep) { ep = { season: r.season, ep: r.ep, title: r.title, versions: [] }; s.eps.set(ek, ep); }
    ep.versions.push(...r.versions);
  }
  return [...map.values()].map((s) => {
    const eps = [...s.eps.values()].map(finishEntry);
    const seasons = new Map();
    for (const ep of eps) {
      let se = seasons.get(ep.season);
      if (!se) { se = { season: ep.season, eps: [], size: 0, dupes: 0, extra: 0, res: {}, locs: new Set() }; seasons.set(ep.season, se); }
      se.eps.push(ep); se.size += ep.size; se.extra += ep.extra; if (ep.dupes) se.dupes++;
      for (const v of ep.versions) { se.res[v.res] = (se.res[v.res] || 0) + 1; se.locs.add(v.loc); }
    }
    const all = eps.flatMap((e) => e.versions);
    const resCount = {}; all.forEach((v) => { resCount[v.res] = (resCount[v.res] || 0) + 1; });
    const top = Object.entries(resCount).sort((a, b) => b[1] - a[1])[0]?.[0] || 'SD';
    const seasonList = [...seasons.values()].sort((a, b) => a.season - b.season).map((se) => ({ ...se, eps: se.eps.sort((a, b) => a.ep - b.ep), locs: [...se.locs], missing: gaps(se) }));
    // Seasons missing between ones you have (e.g. 1, 2, 4 -> 3). Specials (season 0) don't count.
    const numbered = seasonList.map((se) => se.season).filter((n) => n > 0);
    const missingSeasons = numbered.length ? range(1, Math.max(...numbered)).filter((n) => !numbered.includes(n)) : [];
    return {
      kind: 'show', k: s.k, title: s.title, year: s.year, thumb: s.thumb, thumbServer: s.thumbServer, addedAt: s.addedAt, items: s.items, unmatched: s.unmatched,
      seasons: seasonList, missingSeasons, missingEps: seasonList.reduce((a, se) => a + se.missing.length, 0),
      epCount: eps.length, size: eps.reduce((a, e) => a + e.size, 0), dupeEps: eps.filter((e) => e.dupes).length,
      extra: eps.reduce((a, e) => a + e.extra, 0), res: top, resMix: resCount,
      locs: [...new Set(all.map((v) => v.loc))],
      hdr: all.some((v) => v.hdr), dv: all.some((v) => v.dv), lossless: all.some((v) => v.lossless),
      best: { res: top }, dupes: eps.some((e) => e.dupes),
    };
  });
}

export function buildLocations(movies, shows, servers) {
  const locs = new Map();
  const add = (v) => {
    let l = locs.get(v.loc);
    if (!l) { l = { id: v.loc, machine: v.machine, drive: v.drive, size: 0, files: 0, servers: new Set() }; locs.set(v.loc, l); }
    l.size += v.size; l.files += 1; l.servers.add(v.serverId);
  };
  movies.forEach((m) => m.versions.forEach(add));
  shows.forEach((s) => s.seasons.forEach((se) => se.eps.forEach((e) => e.versions.forEach(add))));
  return [...locs.values()].map((l) => {
    const svs = [...l.servers].map((id) => servers[id]).filter(Boolean);
    return { ...l, servers: [...l.servers], online: svs.some((s) => s.online), lastSeen: Math.max(0, ...svs.map((s) => s.lastSeen || 0)) };
  }).sort((a, b) => b.size - a.size);
}

export function fmtSize(bytes) {
  if (!bytes) return '0 GB';
  const gb = bytes / GB;
  if (gb >= 1000) return `${(gb / 1024).toFixed(2)} TB`;
  if (gb >= 100) return `${Math.round(gb)} GB`;
  if (gb >= 1) return `${gb.toFixed(1)} GB`;
  return `${Math.max(1, Math.round(bytes / 1024 ** 2))} MB`;
}
export function fmtBitrate(kbps) { return kbps ? `${(kbps / 1000).toFixed(kbps >= 10000 ? 0 : 1)} Mbps` : 'â€”'; }
export function fmtAudio(v) {
  const names = { truehd: 'TrueHD', eac3: 'DD+', ac3: 'Dolby Digital', dca: 'DTS', 'dca-ma': 'DTS-HD MA', aac: 'AAC', flac: 'FLAC', opus: 'Opus', mp3: 'MP3', pcm: 'PCM' };
  const ch = v.ch ? ({ 1: '1.0', 2: '2.0', 6: '5.1', 7: '6.1', 8: '7.1' }[v.ch] || `${v.ch}ch`) : '';
  return v.audioLabel || [names[v.acodec] || v.acodec.toUpperCase(), ch, v.atmos ? 'Atmos' : ''].filter(Boolean).join(' ');
}
