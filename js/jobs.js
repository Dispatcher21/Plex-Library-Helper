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

// Ask the helper to stop a running compression: same job, state "stop" (new label first, then remove the old)
export async function stopJob(api, job) {
  const tag = `${job.prefix}${job.id}:${job.action}:${job.mediaId}:stop`;
  await api.addLabel(job.sectionId, job.ratingKey, tag);
  await api.removeLabel(job.sectionId, job.ratingKey, job.tag);
}

export async function fetchJobs(api, serverId) {
  const jobs = [];
  const sections = (await api.sections()).filter((s) => s.type === 'movie');
  for (const s of sections) {
    const labels = (await api.sectionLabels(s.key)).filter((l) => parse(l.title));
    for (const l of labels) {
      const j = parse(l.title); if (!j) continue;
      const items = await api.itemsWithLabel(s.key, l.key);
      for (const it of items) jobs.push({ ...j, serverId, sectionId: String(s.key), ratingKey: String(it.ratingKey), title: it.title, year: it.year });
    }
  }
  return jobs;
}

export function removeJob(api, job) { return api.removeLabel(job.sectionId, job.ratingKey, job.tag); }

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
  stop(job) { this.set(job, 'stop', ''); setTimeout(() => this.set(job, 'fail', 'Stopped from the dashboard'), 1500); }
  remove(job) { this.jobs = this.jobs.filter((j) => j !== job && j.id !== job.id); this.onChange(null); }
}
