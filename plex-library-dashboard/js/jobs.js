// Jobs for the Library Helper, carried through Plex labels on the movie:  pld:<jobId>:<action>:<mediaId>:<state>[:<info>]
// The dashboard only ever adds "queued" labels or removes its own labels; the helper (helper/library-helper.ps1)
// does the file work on the PC that owns the drive.

const PREFIX = 'pld:';
export const STATES = { queued: 'Queued', run: 'Running', done: 'Done', fail: 'Failed' };

export function parse(tag) {
  if (!tag?.toLowerCase().startsWith(PREFIX)) return null; // Plex may capitalise it ("Pld:")
  const p = tag.slice(PREFIX.length).split(':');
  if (p.length < 4) return null;
  const [id, action, mediaId, state, ...rest] = p;
  return { tag, id, action, mediaId, state, info: rest.join(':'), created: jobTime(id) };
}

function jobTime(id) { const n = parseInt(String(id).split('-')[0], 36); return Number.isFinite(n) ? n : 0; }
function newId() { return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 5)}`; }

// ---------- Plex transport ----------

// action 'q': the Library Helper double-checks that another copy in the same Plex item still exists.
// action 'qa': skip that check; used when the other surviving copy is in a different Plex item or
// server (the dashboard verified it), or when you explicitly chose to quarantine the last copy.
export async function queueQuarantine(api, v, action = 'q') {
  let sectionId = v.sectionId;
  if (!sectionId) sectionId = String((await api.metadata(v.ratingKey))?.librarySectionID || '');
  if (!sectionId) throw new Error('Plex didn\'t say which library this copy is in.');
  const tag = `${PREFIX}${newId()}:${action}:${v.mediaId}:queued`;
  await api.addLabel(sectionId, v.ratingKey, tag);
  return parse(tag);
}

export async function fetchJobs(api, serverId) {
  const jobs = [];
  const sections = (await api.sections()).filter((s) => s.type === 'movie');
  for (const s of sections) {
    const labels = (await api.sectionLabels(s.key)).filter((l) => l.title?.toLowerCase().startsWith(PREFIX));
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
  queue(v, entry) {
    const j = { ...parse(`${PREFIX}${newId()}:q:${v.mediaId}:queued`), serverId: v.serverId, sectionId: '1', ratingKey: v.ratingKey, title: entry.title, year: entry.year };
    this.jobs.push(j);
    const step = (state, info, ms) => setTimeout(() => {
      if (!this.jobs.includes(j)) return;
      j.state = state; j.info = info; j.tag = `${PREFIX}${j.id}:q:${j.mediaId}:${state}${info ? `:${info}` : ''}`; this.onChange(j);
    }, ms);
    step('run', '', 2500);
    step('done', String(v.size), 6000);
    this.onChange(j);
    return j;
  }
  remove(job) { this.jobs = this.jobs.filter((j) => j !== job && j.id !== job.id); this.onChange(null); }
}
