// Jobs for the Library Helper, carried through Plex labels on the movie:
//   pld:<jobId>:<action>:<mediaId>:<state>[:<info>]    quarantine (q, qa)
//   pldc:<jobId>:<action>:<mediaId>:<state>[:<info>]   compression (c = compress, ce = estimate); its own
//                                                      prefix so helpers older than 0.3 ignore it
// The dashboard only ever adds "queued" labels, asks a running compression to stop (state "stop"), or
// removes its own labels; the helper (helper/library-helper.ps1) does the file work.

const PREFIX = 'pld:';
const CPREFIX = 'pldc:';
export const STATES = { queued: 'Queued', run: 'Running', stop: 'Stopping', done: 'Done', fail: 'Failed' };

export function parse(tag) {
  const low = tag?.toLowerCase() || ''; // Plex may capitalise it ("Pld:")
  const prefix = low.startsWith(CPREFIX) ? CPREFIX : low.startsWith(PREFIX) ? PREFIX : null;
  if (!prefix) return null;
  const p = tag.slice(prefix.length).split(':');
  if (p.length < 4) return null;
  const [id, action, mediaId, state, ...rest] = p;
  return { tag, prefix, kind: prefix === CPREFIX ? 'compress' : 'quarantine', id, action, mediaId, state, info: rest.join(':'), created: jobTime(id) };
}

function jobTime(id) { const n = parseInt(String(id).split('-')[0], 36); return Number.isFinite(n) ? n : 0; }
function newId() { return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 5)}`; }

// ---------- Plex transport ----------

async function sectionOf(api, v) {
  let sectionId = v.sectionId;
  if (!sectionId) sectionId = String((await api.metadata(v.ratingKey))?.librarySectionID || '');
  if (!sectionId) throw new Error('Plex didn\'t say which library this copy is in.');
  return sectionId;
}

// action 'q': the Library Helper double-checks that another copy in the same Plex item still exists.
// action 'qa': skip that check; used when the other surviving copy is in a different Plex item or
// server (the dashboard verified it), or when you explicitly chose to quarantine the last copy.
export async function queueQuarantine(api, v, action = 'q') {
  const sectionId = await sectionOf(api, v);
  const tag = `${PREFIX}${newId()}:${action}:${v.mediaId}:queued`;
  await api.addLabel(sectionId, v.ratingKey, tag);
  return parse(tag);
}

// action 'c' compress, 'ce' estimate; options from compress.encodeOptions()
export async function queueCompress(api, v, action, options) {
  const sectionId = await sectionOf(api, v);
  const tag = `${CPREFIX}${newId()}:${action}:${v.mediaId}:queued:${options}`;
  await api.addLabel(sectionId, v.ratingKey, tag);
  return parse(tag);
}

// Show jobs: labels on the show, listing episode copies (media ids). One label per drive, so one helper
// does each, and at most IDS_PER_LABEL copies per label (Plex keeps 600+ character labels intact).
// action 'qm' = clean-up, the helper keeps each episode's last copy; 'qma' = remove these on purpose.
const IDS_PER_LABEL = 40;
export async function queueShowQuarantine(api, show, versions, action, scope) {
  const byLoc = new Map();
  for (const v of versions) { if (!byLoc.has(v.loc)) byLoc.set(v.loc, []); byLoc.get(v.loc).push(v); }
  const queued = [];
  for (const group of byLoc.values()) {
    for (let i = 0; i < group.length; i += IDS_PER_LABEL) {
      const chunk = group.slice(i, i + IDS_PER_LABEL);
      const tag = `${PREFIX}${newId()}:${action}:sh${show.ratingKey}:queued:ids=${chunk.map((v) => v.mediaId).join('+')};n=${chunk.length};s=${scope}`;
      await api.addLabel(show.sectionId, show.ratingKey, tag, 2);
      queued.push(parse(tag));
    }
  }
  return queued;
}

// Ask the helper to stop a running compression: same job, state "stop" (new label first, then remove the old)
export async function stopJob(api, job) {
  const tag = `${job.prefix}${job.id}:${job.action}:${job.mediaId}:stop`;
  await api.addLabel(job.sectionId, job.ratingKey, tag, job.type);
  await api.removeLabel(job.sectionId, job.ratingKey, job.tag, job.type);
}

export async function fetchJobs(api, serverId) {
  const jobs = [];
  const sections = (await api.sections()).filter((s) => s.type === 'movie' || s.type === 'show');
  for (const s of sections) {
    const type = s.type === 'show' ? 2 : 1;
    const labels = (await api.sectionLabels(s.key)).filter((l) => parse(l.title));
    for (const l of labels) {
      const j = parse(l.title); if (!j) continue;
      const items = await api.itemsWithLabel(s.key, l.key, type);
      for (const it of items) jobs.push({ ...j, serverId, sectionId: String(s.key), type, show: type === 2, ratingKey: String(it.ratingKey), title: it.title, year: it.year });
    }
  }
  return jobs;
}

export function removeJob(api, job) { return api.removeLabel(job.sectionId, job.ratingKey, job.tag, job.type); }

// What a show job covers, from its label: { ids, n, scope } and, when done, { bytes, moved, failed, problem }
export function showJobInfo(j) {
  const o = {};
  for (const kv of String(j.info || '').split(';')) { const m = /^\s*(\w+)=(.*)$/.exec(kv); if (m) o[m[1]] = m[2]; }
  return { ids: (o.ids || '').split('+').filter(Boolean), n: Number(o.n) || 0, scope: o.s || '', bytes: Number(o.b) || 0, moved: Number(o.n) || 0, failed: Number(o.f) || 0, problem: o.x || '' };
}

// ---------- Demo transport (no Plex; jobs advance on timers) ----------

export class DemoJobs {
  constructor(onChange) { this.jobs = []; this.onChange = onChange; }
  add(prefix, action, v, entry, info = '') {
    const j = { ...parse(`${prefix}${newId()}:${action}:${v.mediaId}:queued${info ? `:${info}` : ''}`), serverId: v.serverId, sectionId: '1', ratingKey: v.ratingKey, title: entry.title, year: entry.year };
    this.jobs.push(j);
    this.onChange(j);
    return j;
  }
  set(j, state, info) {
    if (!this.jobs.includes(j)) return;
    j.state = state; j.info = info; j.tag = `${j.prefix}${j.id}:${j.action}:${j.mediaId}:${state}${info ? `:${info}` : ''}`; this.onChange(j);
  }
  queue(v, entry) {
    const j = this.add(PREFIX, 'q', v, entry);
    setTimeout(() => this.set(j, 'run', ''), 2500);
    setTimeout(() => this.set(j, 'done', String(v.size)), 6000);
    return j;
  }
  // Pretend encode: a few seconds per stage, with one pause for "someone is watching Plex"
  queueCompress(v, entry, action, options, guess) {
    const j = this.add(CPREFIX, action, v, entry, options);
    const o = Object.fromEntries(options.split(';').map((kv) => kv.split('=')));
    if (action === 'ce') {
      [10, 45, 80].forEach((p, i) => setTimeout(() => j.state !== 'stop' && this.set(j, 'run', `${p};;Estimating;${o.p}`), 1500 + i * 1500));
      setTimeout(() => j.state !== 'stop' && this.set(j, 'done', `a=${o.a};b=${Math.round(guess.bytes * 1.08)};p=${o.p};q=${o.p === '4ks' ? 88.7 : 94.3};s=${v.size};t=${Math.round(guess.secs || 5400)}`), 6000);
    } else {
      const total = Math.round(guess.secs || 5400);
      const steps = [[3, 'Reading Dolby Vision'], [20, 'Encoding'], [37, 'paused: someone is watching Plex'], [55, 'Encoding'], [80, 'Encoding'], [97, 'Checking the result']];
      steps.forEach(([p, what], i) => setTimeout(() => j.state === 'run' || j.state === 'queued' ? this.set(j, 'run', `${p};${Math.round(total * (1 - p / 100))};${what};${o.p}`) : null, 2000 + i * 2500));
      setTimeout(() => j.state === 'run' && this.set(j, 'done', `b=${Math.round(guess.bytes)};dv=${o.p?.startsWith('4k') ? 1 : 0};p=${o.p};s=${v.size}`), 2000 + steps.length * 2500);
    }
    return j;
  }
  // Pretend show quarantine: one job per drive, like the real thing
  queueShow(show, versions, action, scope) {
    const byLoc = new Map();
    for (const v of versions) { if (!byLoc.has(v.loc)) byLoc.set(v.loc, []); byLoc.get(v.loc).push(v); }
    const made = [];
    for (const group of byLoc.values()) {
      const j = { ...parse(`${PREFIX}${newId()}:${action}:sh${show.ratingKey}:queued:ids=${group.map((v) => v.mediaId).join('+')};n=${group.length};s=${scope}`), serverId: show.serverId, sectionId: '2', type: 2, show: true, ratingKey: show.ratingKey, title: show.title, year: show.year };
      this.jobs.push(j); made.push(j);
      setTimeout(() => this.set(j, 'run', ''), 2000);
      setTimeout(() => this.set(j, 'done', `b=${group.reduce((a, v) => a + v.size, 0)};f=0;n=${group.length};s=${scope}`), 4500);
    }
    this.onChange(made[0]);
    return made;
  }
  stop(job) { this.set(job, 'stop', ''); setTimeout(() => this.set(job, 'fail', 'Stopped from the dashboard'), 1500); }
  remove(job) { this.jobs = this.jobs.filter((j) => j !== job && j.id !== job.id); this.onChange(null); }
}
