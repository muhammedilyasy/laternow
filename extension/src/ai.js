/* Picking moments with the user's own Gemini key. Prompt, windows, validation and the 60s-chunk
 * fallback are the same as cloudflare/src/worker.js; the free-tier model pool and the video fallback
 * follow moments.py. */

const API = 'https://generativelanguage.googleapis.com/v1beta';
const fmt = s => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;
const nowS = () => Date.now() / 1000;
const sleep = ms => new Promise(r => setTimeout(r, ms));

/* code: 'RATE_LIMIT' (retryAt = epoch seconds when a model frees up), 'BAD_KEY', 'NETWORK', 'FAILED'. */
export class AIError extends Error {
  constructor(code, msg, retryAt = 0) { super(msg || code); this.code = code; this.retryAt = retryAt; }
}

export function normTopic(t) {
  t = String(t || 'misc').toLowerCase().split(/[,/;&|]| and /)[0].replace(/^[\s.\-_#]+|[\s.\-_#]+$/g, '');
  return t.slice(0, 24) || 'misc';
}

export const PROMPT = (maxn, title, text, topics) => `You turn part of a long video transcript into a feed of short, self-contained "moments" for people with short attention spans.

Rules:
- Each moment is 25-90 seconds and must make sense on its own: it starts at the beginning of a thought and ends when the point is complete. Never cut mid-sentence.
- Pick only the most interesting, insightful, funny or useful parts. Skip intros, sponsor reads, small talk and outros. Up to ${maxn} moments.
- title: a punchy hook of max 8 words that makes someone want to watch (honest, no clickbait lies).
- topic: ONE short lowercase topic (1-2 words, never a list), e.g. "startups", "fitness", "ai", "money", "mindset". Prefer these existing topics when they fit: ${topics || 'none yet'}.
- hook: 1-10, how gripping this moment is for a general viewer.
- start/end are seconds, taken from the [m:ss] markers.

Video title: ${title}

Transcript:
${text}

Answer with ONLY a JSON array, no prose, no code fences:
[{"start": 12.5, "end": 70.0, "title": "...", "topic": "...", "hook": 7}]`;

export const VPROMPT = ({ a, b, sa, sb, sa_ex, sb_ex, maxn, title, topics }) => `You are watching part of a long video, from ${a} to ${b} (mm:ss). Turn it into short, self-contained "moments" for a feed for people with short attention spans.

Rules:
- Each moment is 25-90 seconds and must make sense on its own: it starts at the beginning of a thought and ends when the point is complete. Never cut mid-sentence.
- Pick only the most interesting, insightful, funny or useful parts. Skip intros, sponsor reads, small talk and outros. Up to ${maxn} moments.
- title: a punchy hook of max 8 words that makes someone want to watch (honest, no clickbait lies).
- topic: ONE short lowercase topic (1-2 words, never a list). Prefer these existing topics when they fit: ${topics}.
- hook: 1-10, how gripping this moment is for a general viewer.
- start/end: seconds from the start of the FULL video (so between ${sa} and ${sb}).
- last_second_seen: the timestamp (seconds from the start of the full video) of the last moment of video you can see. If the video ends before ${b}, this is where it ends.

Video title: ${title}

Answer with ONLY a JSON object, no prose:
{"moments": [{"start": ${sa_ex}, "end": ${sb_ex}, "title": "...", "topic": "...", "hook": 7}], "last_second_seen": ${sb}}`;

/* ---------- Gemini free tier ----------
 * Free-tier quotas are per Google project *per model* and reset at midnight Pacific. They are small and unpublished
 * (e.g. 20 requests/day on the newest Flash, no free tier at all on Pro). So we keep a pool of every free Flash /
 * Flash-Lite model the key can use, best first, spend each model's daily allowance in turn, and learn the real
 * limits from Google's 429 replies (quotaId / quotaValue / retryDelay).
 * State lives in chrome.storage.local under 'gemini' = {pool: {day, models}, quota: {model: {...}}, last_model}. */
export const SPACING = 6;       // seconds between requests to the same model (stays under per-minute limits)
const CALL_TIMEOUT = 300;       // seconds
const POOL_RE = /^gemini-(\d+(\.\d+)?)-flash(-lite)?(-preview)?$/;
const FALLBACK_POOL = ['gemini-2.5-flash', 'gemini-2.5-flash-lite'];
const STATE_KEY = 'gemini';

let store = typeof chrome !== 'undefined' && chrome.storage ? chrome.storage.local : null;
let state = null;
export function setStore(s) { store = s; state = null; }   // tests
async function loadState() {
  if (!state) {
    const d = (await store.get(STATE_KEY))[STATE_KEY] || {};
    state = { pool: d.pool || null, quota: d.quota || {}, last_model: d.last_model || '' };
  }
  return state;
}
const saveState = () => store.set({ [STATE_KEY]: state });

// Reservations and reports go through one queue so parallel jobs never double-book a model.
let lockTail = Promise.resolve();
function locked(fn) {
  const run = lockTail.then(fn, fn);
  lockTail = run.catch(() => {});
  return run;
}

const PT = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Los_Angeles', year: 'numeric', month: '2-digit', day: '2-digit',
                                              hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' });
const ptParts = t => Object.fromEntries(PT.formatToParts(new Date(t * 1000)).map(p => [p.type, p.value]));
export function ptDay(t = nowS()) { const p = ptParts(t); return `${p.year}-${p.month}-${p.day}`; }
/* Epoch seconds of the next midnight Pacific (+5s), DST-safe. */
export function nextReset(t = nowS()) {
  const p = ptParts(t);
  let r = Math.floor(t) + 86400 - (+p.hour * 3600 + +p.minute * 60 + +p.second) + 5;
  const h = +ptParts(r).hour;           // a DST change today shifts the wall clock by an hour
  if (h === 23) r += 3600; else if (h === 1) r -= 3600;
  return r;
}

/* Free-tier candidates, best first: newest full Flash models, then Flash-Lite, previews after the stable model of
 * the same version. Pro has no free tier, and -latest aliases share a bucket with their model, so both are left out. */
export function gemChoices(names) {
  const rank = n => { const m = n.match(POOL_RE); return [m[3] ? 1 : 0, -parseFloat(m[1]), m[4] ? 1 : 0]; };
  return names.filter(n => POOL_RE.test(n)).sort((a, b) => {
    const x = rank(a), y = rank(b);
    return x[0] - y[0] || x[1] - y[1] || x[2] - y[2] || (a < b ? -1 : a > b ? 1 : 0);
  });
}

export async function listModels(key) {
  let r;
  try { r = await fetch(`${API}/models?pageSize=1000`, { headers: { 'x-goog-api-key': key }, credentials: 'omit' }); }
  catch (e) { throw new AIError('NETWORK', `Couldn't reach Google (${e.message})`); }
  const d = await r.json().catch(() => ({}));
  if (!r.ok) throw new AIError([400, 401, 403].includes(r.status) ? 'BAD_KEY' : 'FAILED', d?.error?.message || `Google returned ${r.status}`);
  return (d.models || []).filter(m => (m.supportedGenerationMethods || []).includes('generateContent')).map(m => String(m.name).replace(/^models\//, ''));
}

/* Cached model pool for this key, refreshed once per Pacific day. Call with the lock held. */
async function pool(key) {
  const st = await loadState();
  if (st.pool?.day !== ptDay() || !st.pool?.models?.length) {
    try { st.pool = { day: ptDay(), models: gemChoices(await listModels(key)) }; await saveState(); }
    catch { if (!st.pool?.models?.length) return FALLBACK_POOL; }
  }
  return st.pool.models;
}

function quota(st, model) {
  const q = st.quota[model] ||= { day: ptDay(), used: 0, day_limit: 0, blocked_until: 0, last: 0, note: '' };
  if (q.day !== ptDay()) { q.day = ptDay(); q.used = 0; }
  return q;
}

/* When this model can take another request (0 = now). */
export function availableAt(q, t = nowS()) {
  let at = Math.max(q.blocked_until || 0, (q.last || 0) + SPACING);
  if (q.day_limit && q.used >= q.day_limit) at = Math.max(at, nextReset(t));
  return at <= t ? 0 : at;
}

/* Pick the best model with allowance left and count the request: {model} or {retryAt}. */
export function reserve(key, skip = new Set()) {
  return locked(async () => {
    const t = nowS(), st = await loadState();
    let soonest = null;
    for (const m of await pool(key)) {
      const q = quota(st, m), at = availableAt(q, t);
      if (skip.has(m)) { if (!at) continue; }   // already failed this request; still counts for when work can resume
      else if (at === 0) { q.used++; q.last = t; await saveState(); return { model: m }; }
      soonest = soonest === null ? at : Math.min(soonest, at);
    }
    return { retryAt: soonest || nextReset(t) };
  });
}

/* Record what Google said about a request we reserved: 'ok', 'day' / 'minute' quota, 'busy', 'gone' or 'unfree'. */
export function report(model, kind, delay = 0, limit = 0, note = '') {
  return locked(async () => {
    const t = nowS(), st = await loadState(), q = quota(st, model);
    if (kind !== 'ok') q.used = Math.max(0, q.used - 1);   // rejected requests don't count against the quota
    if (kind === 'day') {
      q.blocked_until = delay ? t + delay : nextReset(t);
      if (limit) { q.day_limit = limit; q.used = Math.max(q.used, limit); }
    } else if (kind === 'minute') q.blocked_until = t + Math.max(delay, 30);
    else if (kind === 'busy') q.blocked_until = t + 120;
    else if (kind === 'gone' || kind === 'unfree') q.blocked_until = t + 3 * 86400;
    else if (kind === 'ok') st.last_model = model;
    q.note = String(note).slice(0, 120);
    await saveState();
  });
}

/* A 429 body -> {kind, delay (seconds), limit}. */
export function classify429(body) {
  let details;
  try { details = (typeof body === 'string' ? JSON.parse(body) : body).error.details || []; }
  catch { return { kind: 'minute', delay: 60, limit: 0 }; }
  const ids = []; let limit = 0, delay = 0;
  for (const d of details) {
    for (const v of d.violations || []) {
      ids.push(String(v.quotaId || ''));
      const n = parseInt(v.quotaValue || 0, 10); if (Number.isFinite(n)) limit = Math.max(limit, n);
    }
    if (d.retryDelay) { const s = parseFloat(String(d.retryDelay)); if (Number.isFinite(s)) delay = s; }
  }
  if (ids.length >= 3 && !limit) return { kind: 'unfree', delay: 0, limit: 0 };   // every quota without a value: no free tier
  if (ids.some(i => i.includes('PerDay'))) return { kind: 'day', delay, limit };
  return { kind: 'minute', delay: delay || 60, limit: 0 };
}

class GemErr extends Error {
  constructor(kind, delay = 0, limit = 0, note = '') { super(kind); Object.assign(this, { kind, delay, limit, note }); }
}

/* One generateContent request. Returns text; throws GemErr for quota/availability problems, AIError otherwise. */
async function call(key, model, parts, mediaLow, signal) {
  const cfg = { temperature: 0.3, responseMimeType: 'application/json' };
  if (mediaLow) cfg.mediaResolution = 'MEDIA_RESOLUTION_LOW';
  const ctl = new AbortController(), to = setTimeout(() => ctl.abort(), CALL_TIMEOUT * 1000);
  const onAbort = () => ctl.abort(); signal?.addEventListener('abort', onAbort);
  let r, raw;
  try {
    r = await fetch(`${API}/models/${encodeURIComponent(model)}:generateContent`, {
      method: 'POST', credentials: 'omit', signal: ctl.signal,
      headers: { 'Content-Type': 'application/json', 'x-goog-api-key': key },
      body: JSON.stringify({ contents: [{ role: 'user', parts }], generationConfig: cfg })
    });
    raw = await r.text();
  } catch (e) {
    if (signal?.aborted) throw new AIError('FAILED', 'Cancelled');
    throw new GemErr('busy', 0, 0, ctl.signal.aborted ? 'no answer in time' : `network: ${e.message}`);
  } finally { clearTimeout(to); signal?.removeEventListener('abort', onAbort); }
  let d = {}; try { d = JSON.parse(raw); } catch {}
  if (r.status === 429 || raw.includes('RESOURCE_EXHAUSTED')) { const c = classify429(raw); throw new GemErr(c.kind, c.delay, c.limit, 'quota'); }
  if ([500, 502, 503, 504].includes(r.status)) throw new GemErr('busy', 0, 0, `HTTP ${r.status}`);
  if (r.status === 404) throw new GemErr('gone', 0, 0, 'model not found');
  if (!r.ok) throw new AIError('FAILED', `Gemini ${r.status}: ${d?.error?.message || raw.slice(0, 120)}`.slice(0, 200));
  const c = d.candidates?.[0];
  if (!c) throw new AIError('FAILED', 'Gemini returned no answer' + (d.promptFeedback?.blockReason ? ` (${d.promptFeedback.blockReason})` : ''));
  return (c.content?.parts || []).filter(p => !p.thought).map(p => p.text || '').join('');
}

/* Run a request on the best model that has free allowance left, moving down the pool on quota/overload.
 * Throws AIError('RATE_LIMIT', ..., retryAt) when every model is used up for now. */
export async function ask(key, parts, { mediaLow = false, signal } = {}) {
  if (!key) throw new AIError('BAD_KEY', 'no Gemini key');
  const tried = new Set();
  for (;;) {
    const { model, retryAt } = await reserve(key, tried);
    if (!model) {
      if (retryAt && retryAt - nowS() < 20) { await sleep(Math.max(100, (retryAt - nowS()) * 1000)); continue; }   // request spacing
      throw new AIError('RATE_LIMIT', 'Free Gemini quota used up for now', retryAt);
    }
    let text;
    try { text = await call(key, model, parts, mediaLow, signal); }
    catch (e) {
      if (e instanceof GemErr) {
        await report(model, e.kind, e.delay, e.limit, e.note); tried.add(model);
        console.log(`gemini: ${model} -> ${e.kind} ${e.note} (limit ${e.limit || '?'}), trying next model`);
        continue;
      }
      throw e;   // a real error (bad request etc.): the request stays counted, like moments.py
    }
    await report(model, 'ok');
    return text;
  }
}

/* For the UI: models in the pool, requests used today, and when work resumes if everything is used up. */
export function quotaStatus(key) {
  if (!key) return Promise.resolve(null);
  return locked(async () => {
    const t = nowS(), st = await loadState(), models = await pool(key);
    const qs = models.map(m => quota(st, m)), at = qs.map(q => availableAt(q, t));
    const ready = at.filter(a => a === 0 || a - t < 20).length, later = at.filter(a => a !== 0 && a - t >= 20);
    return { models: models.length, available: ready, used_today: qs.reduce((s, q) => s + q.used, 0),
             resumes_at: ready ? null : (later.length ? Math.min(...later) : null) };
  });
}

export async function lastModel() { return (await loadState()).last_model || 'auto'; }

/* A different key may be a different Google project with its own quotas: forget everything we learned. */
export function resetQuota(models = null) {
  return locked(async () => {
    state = { pool: models ? { day: ptDay(), models: gemChoices(models) } : null, quota: {}, last_model: '' };
    await saveState();
  });
}

/* ---------- segmentation ---------- */
export function windows(lines, maxChars) {
  const out = []; let blocks = [], cur = [], cs = null, size = 0, wStart = null;
  const flush = () => { if (blocks.length) out.push({ text: blocks.join('\n'), start: wStart }); blocks = []; size = 0; wStart = null; };
  for (const [s, d, t] of lines) {
    if (cs === null) cs = s; if (wStart === null) wStart = s;
    cur.push(t);
    if (s + d - cs >= 8) {
      const b = `[${fmt(cs)}] ${cur.join(' ')}`; blocks.push(b); size += b.length; cur = []; cs = null;
      if (size >= maxChars) flush();
    }
  }
  if (cur.length) blocks.push(`[${fmt(cs)}] ${cur.join(' ')}`);
  flush();
  return out;
}

export function parseMoments(out, total) {
  const m = (out || '').match(/\[\s*\{[\s\S]*\}\s*\]/);
  if (!m) return [];
  let arr; try { arr = JSON.parse(m[0]); } catch { return []; }
  return validMoments(arr, total);
}
function validMoments(arr, total) {
  const res = [];
  for (const x of Array.isArray(arr) ? arr : []) {
    if (!x || typeof x !== 'object') continue;
    const s = +x.start, e = +x.end;
    if (isFinite(s) && isFinite(e) && e - s >= 10 && e - s <= 150 && s >= 0 && s < total)
      res.push([s, Math.min(e, total), String(x.title || '').slice(0, 90), normTopic(x.topic), +x.hook || 5]);
  }
  return res;
}

/* One call for the whole transcript (Gemini has a huge context); very long ones are split. */
export async function segment(key, title, lines, topics, signal) {
  const total = lines.at(-1)[0] + lines.at(-1)[1];
  const maxChars = 400000;
  const res = [];
  for (const w of windows(lines, maxChars)) {
    const span = Math.max(60, Math.min(total, w.start + maxChars / 15) - w.start);
    const out = await ask(key, [{ text: PROMPT(Math.max(2, Math.min(40, Math.round(span / 120))), title, w.text, topics.slice(0, 20).join(', ')) }], { signal });
    res.push(...parseMoments(out, total));
  }
  if (!res.length) throw new AIError('FAILED', 'AI returned no valid moments');
  return res;
}

/* ---------- batching ----------
 * Each free Gemini model only allows ~20 requests a day, but each request can carry a million tokens. So videos
 * whose captions are already fetched go to Gemini together: up to BATCH_MAX videos / BATCH_CHARS of transcript in
 * one request, answered as one JSON object keyed video_1..video_n. Long videos go alone. */
export const BATCH_MAX = 12;
export const BATCH_CHARS = 240000;
export const SOLO_CHARS = 120000;   // longer transcripts are never batched

export const transcriptText = lines => windows(lines, Infinity).map(w => w.text).join('\n');
export const totalSecs = lines => lines.length ? lines.at(-1)[0] + lines.at(-1)[1] : 0;
const maxMoments = secs => Math.max(2, Math.min(40, Math.round(secs / 120)));

export const BPROMPT = (videos, topics) => `You turn long video transcripts into a feed of short, self-contained "moments" for people with short attention spans. Below are ${videos.length} separate videos. Treat each one on its own.

Rules:
- Each moment is 25-90 seconds and must make sense on its own: it starts at the beginning of a thought and ends when the point is complete. Never cut mid-sentence.
- Pick only the most interesting, insightful, funny or useful parts. Skip intros, sponsor reads, small talk and outros. Stay within the maximum given for each video.
- title: a punchy hook of max 8 words that makes someone want to watch (honest, no clickbait lies).
- topic: ONE short lowercase topic (1-2 words, never a list), e.g. "startups", "fitness", "ai", "money", "mindset". Prefer these existing topics when they fit: ${topics || 'none yet'}.
- hook: 1-10, how gripping this moment is for a general viewer.
- start/end are seconds from the start of THAT video, taken from its [m:ss] markers.

${videos.map((v, i) => `=== video_${i + 1} ===
Title: ${v.title}
Up to ${v.maxn} moments.
Transcript:
${v.text}`).join('\n\n')}

Answer with ONLY a JSON object with one key per video (video_1 to video_${videos.length}), each an array of moments, no prose:
{"video_1": [{"start": 12.5, "end": 70.0, "title": "...", "topic": "...", "hook": 7}], "video_2": []}`;

/* The batch answer -> one moments array per item, or null where the model skipped or garbled a video. */
export function parseBatch(out, items) {
  const m = (out || '').match(/\{[\s\S]*\}/);
  let d = null; try { d = m ? JSON.parse(m[0]) : null; } catch {}
  if (!d || typeof d !== 'object' || Array.isArray(d)) return items.map(() => null);
  return items.map((it, i) => {
    const ms = validMoments(d[`video_${i + 1}`], totalSecs(it.lines));
    return ms.length ? ms : null;
  });
}

/* items: [{vid, title, lines}] -> Map(vid -> moments | null). One Gemini request for all of them. */
export async function segmentBatch(key, items, topics, signal) {
  const videos = items.map(it => ({ title: it.title, text: transcriptText(it.lines), maxn: maxMoments(totalSecs(it.lines)) }));
  const out = await ask(key, [{ text: BPROMPT(videos, topics.slice(0, 20).join(', ')) }], { signal });
  const res = parseBatch(out, items);
  return new Map(items.map((it, i) => [it.vid, res[i]]));
}

/* One clip's answer -> {moments, seen}. Newer models answer in full-video seconds; gemini-2.5-flash answers
 * relative to the clip, so anything clearly before the clip start is shifted by it. */
export function parseVideoMoments(out, a, b) {
  const m = (out || '').match(/[{[][\s\S]*[}\]]/);
  let d = {}; try { d = m ? JSON.parse(m[0]) : {}; } catch {}
  if (Array.isArray(d)) d = { moments: d };
  if (!d || typeof d !== 'object') d = {};
  const rel = t => (a && t < a - 5 ? t + a : t);
  const moments = [];
  for (const x of Array.isArray(d.moments) ? d.moments : []) {
    const st = rel(parseFloat(x?.start)), en = rel(parseFloat(x?.end));
    if (isFinite(st) && isFinite(en) && en - st >= 10 && en - st <= 150 && st >= a - 5 && st < b + 5)
      moments.push([st, en, String(x.title || '').slice(0, 90), normTopic(x.topic), parseFloat(x.hook) || 5]);
  }
  const s = parseFloat(d.last_second_seen);
  return { moments, seen: isFinite(s) ? rel(s) : 0 };
}

export const VIDEO_SEGMENT = 20 * 60;   // ~110k tokens per request at low media resolution
export const VIDEO_MAX_SEGMENTS = 6;    // up to 2 hours

/* No usable captions: let Gemini watch the video itself (Google fetches it from YouTube). Long videos go in
 * 20-minute clips until the model reports the video ended. */
export async function segmentVideo(key, vid, title, topics, signal) {
  const uri = `https://www.youtube.com/watch?v=${vid}`, res = [];
  let a = 0;
  for (let i = 0; i < VIDEO_MAX_SEGMENTS; i++) {
    const b = a + VIDEO_SEGMENT;
    const out = await ask(key, [
      { file_data: { file_uri: uri }, video_metadata: { start_offset: `${a}s`, end_offset: `${b}s` } },
      { text: VPROMPT({ a: fmt(a), b: fmt(b), sa: a, sb: b, sa_ex: a + 12, sb_ex: a + 70, maxn: 10, title, topics: topics.slice(0, 20).join(', ') || 'none yet' }) }
    ], { mediaLow: true, signal });
    const { moments, seen } = parseVideoMoments(out, a, b);
    res.push(...moments);
    if (seen < b - 60) break;   // the video ended inside this clip
    a = b;
  }
  if (!res.length) throw new AIError('FAILED', "Gemini couldn't find moments in this video");
  return res;
}

export function chunks(lines) {
  const res = []; let s0 = null, first = '';
  for (const [s, d, t] of lines) {
    if (s0 === null) { s0 = s; first = t; }
    if (s + d - s0 >= 60) { res.push([s0, s + d, first.split(/\s+/).slice(0, 7).join(' ') + '…', 'misc', 4]); s0 = null; }
  }
  return res;
}
