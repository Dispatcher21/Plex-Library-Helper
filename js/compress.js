// Compression presets and the small text formats compression jobs use in Plex labels.
// The encoding itself is done by the Library Helper (helper/compress.ps1) on the PC with the graphics card.

import { fmtSize } from './model.js';

// mbps = typical video bitrate it produces; fps = encode speed on the owner's PC (RX 6750 XT / i7-10700),
// both from test encodes on a clean 4K film. Grainy films come out much bigger: that's what Estimate is for.
export const PRESETS = [
  { id: '4kx', label: '4K Extreme', height: 2160, where: 'Processor', mbps: 14, fps: 1.0, dv: true,
    note: 'Best quality for the space. Very slow: about two days for a 2-hour 4K film. For favourites.' },
  { id: '4kh', label: '4K High', height: 2160, where: 'Graphics card', mbps: 18, fps: 30, dv: true,
    note: 'Looks the same as the original on a TV.' },
  { id: '4kn', label: '4K Normal', height: 2160, where: 'Graphics card', mbps: 13, fps: 30, dv: true,
    note: 'Very close to the original; a good default.' },
  { id: '4ks', label: '4K Data Saver', height: 2160, where: 'Graphics card', mbps: 6, fps: 30, dv: true,
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
  { id: 'plex', label: 'Pause while someone is watching Plex', on: true },
  { id: 'game', label: 'Pause while a game or full-screen video is running', on: true },
  { id: 'idle', label: 'Only while nobody is using the PC (after 10 minutes idle)', on: false },
  { id: 'night', label: 'Only overnight (11 PM to 7 AM)', on: false },
];

export function presetFits(p, v) {
  if (!v) return false;
  const h = v.height || { '4K': 2160, '1080p': 1080, '720p': 720, SD: 480 }[v.res] || 0;
  return h >= p.height * 0.7;
}

// Options travel in the queued label: p=4kh;a=keep;r=plex+game
export function encodeOptions({ preset, audio, rules }) {
  return `p=${preset};a=${audio === 'small' ? 'small' : 'keep'};r=${rules.join('+')}`;
}
export function decodeInfo(info) {
  const o = {};
  for (const kv of String(info || '').split(';')) { const m = /^\s*(\w+)=(.*)$/.exec(kv); if (m) o[m[1].toLowerCase()] = m[2].trim(); }
  return o;
}

// Running jobs report "percent;secondsLeft;what it's doing (or 'paused: why');preset"
export function parseRun(info) {
  const [pct, left, what, preset] = String(info || '').split(';');
  const n = Number(pct);
  return { percent: Number.isFinite(n) ? n : 0, secsLeft: Number(left) || null, what: what || '', preset: preset || '', paused: /^paused:/i.test(what || '') ? what.replace(/^paused:\s*/i, '') : '' };
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
export function roughGuess(p, v, audio = 'keep') {
  const secs = (v.duration || 0) / 1000;
  if (!secs) return { bytes: v.size * 0.3, secs: null, little: false };
  const audioMbps = audio === 'small' ? 0.64 : v.lossless ? 5 : 0.8;
  const srcVideoMbps = Math.max(0.5, (v.size * 8) / secs / 1e6 - audioMbps);
  const videoMbps = Math.min(p.mbps, srcVideoMbps * 0.9);
  const bytes = ((videoMbps + audioMbps) * 1e6 * secs) / 8;
  return { bytes, secs: (secs * 23.976) / p.fps, little: bytes > v.size * 0.7 };
}

export function estimateText(info, v) {
  const o = decodeInfo(info);
  const bytes = Number(o.b); const src = Number(o.s) || v?.size || 0;
  const parts = [`about ${fmtSize(bytes)}${src ? ` (${Math.round((bytes / src) * 100)}% of ${fmtSize(src)})` : ''}`];
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
