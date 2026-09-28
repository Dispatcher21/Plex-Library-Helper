// Compression presets and the small text formats compression jobs use in Plex labels.
// The encoding itself is done by the Library Helper (helper/compress.ps1) on the PC with the graphics card.

import { fmtSize } from './model.js';

// mbps = typical video bitrate it produces; fps = encode speed on the owner's PC (RX 6750 XT / i7-10700),
// from test encodes on a clean 4K film (4K GPU speed from a real job: Harry Potter 1, 59 fps with GPU decoding). Grainy films come out much bigger: that's what Estimate is for.
export const PRESETS = [
  { id: '4kx', label: '4K Extreme', height: 2160, where: 'Processor', mbps: 14, fps: 1.0, dv: true,
    note: 'Best quality for the space. Very slow: about two days for a 2-hour 4K film. For favourites.' },
  { id: '4kh', label: '4K High', height: 2160, where: 'Graphics card', mbps: 18, fps: 55, dv: true,
    note: 'Looks the same as the original on a TV.' },
  { id: '4kn', label: '4K Normal', height: 2160, where: 'Graphics card', mbps: 13, fps: 55, dv: true,
    note: 'Very close to the original; a good default.' },
  { id: '4ks', label: '4K Data Saver', height: 2160, where: 'Graphics card', mbps: 6, fps: 55, dv: true,
    note: 'Much smaller; some softness in fine detail.' },
  { id: '1080h', label: '1080p High', height: 1080, where: 'Graphics card', mbps: 6, fps: 24, dv: false,
    note: 'Full HD. HDR films are converted to normal (SDR) colour.' },
  { id: '1080n', label: '1080p Normal', height: 1080, where: 'Graphics card', mbps: 4.5, fps: 24, dv: false,
    note: 'Full HD, smaller. HDR films are converted to normal (SDR) colour.' },
  { id: '1080s', label: '1080p Data Saver', height: 1080, where: 'Graphics card', mbps: 3.4, fps: 24, dv: false,
    note: 'Smallest. Good for phones and tablets.' },
];
export const presetById = (id) => PRESETS.find((p) => p.id === id);

export const RULES = [
  { id: 'plex', label: 'Pause while Plex is transcoding a stream (the only playback that slows down)', on: true },
  { id: 'plexall', label: 'Pause whenever anything is playing on Plex, even direct play', on: false },
  { id: 'game', label: 'Pause while a game or full-screen video is running', on: true },
  { id: 'idle', label: 'Only while nobody is using the PC (after 10 minutes idle)', on: false },
  { id: 'night', label: 'Only overnight (11 PM to 7 AM)', on: false },
];

export function presetFits(p, v) {
  if (!v) return false;
  const h = v.height || { '4K': 2160, '1080p': 1080, '720p': 720, SD: 480 }[v.res] || 0;
  return h >= p.height * 0.7;
}

// Options travel in the queued label: p=4kh;a=keep;r=plex+game[;v=av1]
export function encodeOptions({ preset, audio, rules, codec }) {
  return `p=${preset};a=${audio === 'small' ? 'small' : 'keep'};r=${rules.join('+')}${codec === 'av1' ? ';v=av1' : ''}`;
}
export function decodeInfo(info) {
  const o = {};
  for (const kv of String(info || '').split(';')) { const m = /^\s*(\w+)=(.*)$/.exec(kv); if (m) o[m[1].toLowerCase()] = m[2].trim(); }
  return o;
}

// Running jobs report "percent;secondsLeft;what it's doing (or 'paused: why');preset"
export function parseRun(info) {
  const [pct, left, what, preset, scope] = String(info || '').split(';');
  const n = Number(pct);
  return { percent: Number.isFinite(n) ? n : 0, secsLeft: Number(left) || null, what: what || '', preset: preset || '', scope: scope || '', paused: /^paused:/i.test(what || '') ? what.replace(/^paused:\s*/i, '') : '' };
}

// Which preset a job is for, whatever state it's in
export function jobPreset(j) {
  if (j.state === 'run') return parseRun(j.info).preset;
  return decodeInfo(j.info).p || '';
}

export function fmtDuration(secs) {
  if (!secs || !Number.isFinite(secs)) return '';
  const m = Math.round(secs / 60);
  if (m < 1) return 'under a minute';
  if (m < 60) return `${m} min`;
  const h = Math.floor(m / 60); const r = m % 60;
  if (h >= 48) return `${Math.round(h / 24)} days`;
  return r ? `${h} h ${r} min` : `${h} h`;
}

// Before an estimate: rough size/time from the test encodes. A copy that's already an efficient encode
// can't shrink to the preset's usual bitrate, so the video part never goes above what the copy has now.
function split(v, audio) {
  const secs = (v.duration || 0) / 1000;
  const totalMbps = secs ? (v.size * 8) / secs / 1e6 : 0;
  const audioMbps = Math.min(audio === 'small' ? 0.64 : v.lossless ? 5 : 0.8, totalMbps * 0.4);
  return { secs, audioMbps, srcVideoMbps: Math.max(totalMbps * 0.6, totalMbps - audioMbps) };
}

export function roughGuess(p, v, audio = 'keep', codec = 'hevc') {
  const { secs, audioMbps, srcVideoMbps } = split(v, audio);
  if (!secs) return { bytes: v.size * 0.3, secs: null, little: false };
  const videoMbps = Math.min(p.mbps * (codec === 'av1' ? 0.75 : 1), srcVideoMbps * 0.9);
  const bytes = Math.min(v.size, ((videoMbps + audioMbps) * 1e6 * secs) / 8);   // never more than it is now
  // 1080p presets were timed turning 4K HDR into 1080p SDR on the processor; an HD source needs no conversion
  // and stays on the graphics card, which is several times faster (rough figure until measured)
  const fps = p.height === 1080 && (v.height || 1080) <= 1100 && !v.hdr ? 150 : p.fps;
  return { bytes, secs: (secs * 23.976) / fps, little: bytes > v.size * 0.7 };
}

export function estimateText(info, v) {
  const o = decodeInfo(info);
  const bytes = Number(o.b); const src = Number(o.s) || v?.size || 0;
  const eps = Number(o.c) ? ` for ${o.c} episodes` : '';
  const parts = [`about ${fmtSize(bytes)}${eps}${src ? ` (${Math.round((bytes / src) * 100)}% of ${fmtSize(src)})` : ''}`];
  if (Number(o.t)) parts.push(`about ${fmtDuration(Number(o.t))} to encode`);
  if (o.q) parts.push(`quality ${o.q} / 100`);
  return parts.join(' · ');
}

export function qualityWords(vmaf) {
  const q = Number(vmaf);
  if (!q) return '';
  if (q >= 95) return 'looks the same as the original';
  if (q >= 93) return 'excellent: very hard to tell apart';
  if (q >= 90) return 'good: small differences up close';
  if (q >= 85) return 'noticeably softer';
  return 'visibly worse than the original (often a grainy film)';
}

// ---------- Which PC does it, and how long it takes there (from each helper's benchmark) ----------
// Mirrors the helper's Choose-Encoder (helper/encoders.ps1): graphics card first; 4K Extreme prefers the
// processor's efficient encoder where processor jobs are allowed; encoders the benchmark found far too slow
// for that size of film are left out.

export const ENCODERS = {
  amf: { label: 'AMD graphics', codec: 'hevc' }, nvenc: { label: 'NVIDIA graphics', codec: 'hevc' }, qsv: { label: 'Intel graphics', codec: 'hevc' },
  x265: { label: 'processor (x265)', codec: 'hevc', cpu: true }, x265slow: { label: 'processor (x265 slow)', codec: 'hevc', cpu: true, efficient: true },
  av1_amf: { label: 'AMD graphics, AV1', codec: 'av1' }, av1_nvenc: { label: 'NVIDIA graphics, AV1', codec: 'av1' }, av1_qsv: { label: 'Intel graphics, AV1', codec: 'av1' },
  svtav1: { label: 'processor (SVT-AV1)', codec: 'av1', cpu: true, efficient: true },
};
const LEVELS = ['extreme', 'high', 'normal', 'saver'];
export function presetLevel(id) {
  const m = /^(4k|1080)([xhns])$/.exec(id || ''); if (!m) return null;
  return { tier: m[1], level: { x: 'extreme', h: 'high', n: 'normal', s: 'saver' }[m[2]] };
}

export function pickEncoder(caps, level, tier, codec = 'hevc') {
  const cal = caps.calibration || {};
  const mine = (caps.encoders || []).filter((id) => ENCODERS[id]?.codec === codec && !cal[id]?.[tier]?.skip);
  const hw = mine.filter((id) => !ENCODERS[id].cpu);
  const cpu = mine.filter((id) => ENCODERS[id].cpu).sort((a, b) => (ENCODERS[b].efficient ? 1 : 0) - (ENCODERS[a].efficient ? 1 : 0));
  if (level === 'extreme' && caps.allowCpu && cpu.length) return cpu[0];
  if (hw.length) return hw[0];
  if (caps.allowCpu && cpu.length) return cpu.find((id) => !ENCODERS[id].efficient) || cpu[0];
  return null;
}

// One line per compressing PC: which encoder it would use and, once it has been benchmarked, size and time
export function pcGuesses(p, v, audio, codec, capsList) {
  const lv = presetLevel(p.id); if (!lv) return [];
  const { secs, audioMbps, srcVideoMbps } = split(v, audio);
  return capsList.map((c) => {
    const enc = pickEncoder(c, lv.level, lv.tier, codec);
    if (!enc) return { pc: c.pc, enc: null };
    const m = c.calibration?.[enc]?.[lv.tier]; const i = (c.levels || LEVELS).indexOf(lv.level);
    if (!m || !m.kbps || !secs) return { pc: c.pc, enc, measured: false };
    const videoMbps = Math.min(m.kbps[i] / 1000, srcVideoMbps * 0.9);
    const bytes = Math.min(v.size, ((videoMbps + audioMbps) * 1e6 * secs) / 8);
    // 1080p from a 4K film also scales (and tone-maps HDR) on the processor, which the 1080p benchmark didn't
    let fps = m.fps;
    if (lv.tier === '1080' && (v.height || 0) > 1100) fps = Math.min(fps, (c.threads || 8) * 1.5);
    return { pc: c.pc, enc, measured: true, bytes, secs: (secs * 23.976) / Math.max(0.05, fps), fps, little: bytes > v.size * 0.7 };
  });
}