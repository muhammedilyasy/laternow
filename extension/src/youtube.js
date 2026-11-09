/* YouTube access from the user's own browser: metadata, captions, playlists, Watch Later.
 *
 * Captions follow youtube-transcript-api 1.2.4: watch page -> INNERTUBE_API_KEY ->
 * POST youtubei/v1/player as the ANDROID client -> captionTracks -> timedtext XML (without fmt=srv3). */

export const YT_RE = /(?:v=|youtu\.be\/|shorts\/|embed\/|live\/)([A-Za-z0-9_-]{11})/;
export const PL_RE = /[?&]list=([A-Za-z0-9_-]+)/;
const ID_RE = /^[A-Za-z0-9_-]{11}$/;
const INNERTUBE_CONTEXT = { client: { clientName: 'ANDROID', clientVersion: '20.10.38' } };
const LANGS = ['en', 'en-US', 'en-GB'];

/* Error codes the queue understands. */
export class YTError extends Error {
  constructor(code, msg) { super(msg || code); this.code = code; }
}

async function get(url, opts = {}) {
  let r;
  try { r = await fetch(url, { credentials: 'include', cache: 'no-store', ...opts, headers: { 'Accept-Language': 'en-US,en;q=0.9', ...(opts.headers || {}) } }); }
  catch (e) { throw new YTError('NETWORK', `Couldn't reach YouTube (${e.message})`); }
  if (r.status === 429) throw new YTError('RATE_LIMIT', 'YouTube is rate-limiting this browser. Retrying automatically.');
  return r;
}

const ENT = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' };
export function unescapeHtml(s) {
  return String(s).replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (m, e) => {
    if (e[0] === '#') { const n = e[1] === 'x' || e[1] === 'X' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10); return Number.isFinite(n) ? String.fromCodePoint(n) : m; }
    return ENT[e.toLowerCase()] ?? m;
  });
}

export async function meta(vid) {
  try {
    const r = await fetch('https://www.youtube.com/oembed?format=json&url=' + encodeURIComponent('https://www.youtube.com/watch?v=' + vid), { credentials: 'omit' });
    if (r.ok) { const d = await r.json(); return [d.title || vid, d.author_name || '']; }
  } catch {}
  return [vid, ''];
}

async function watchHtml(vid) {
  const r = await get(`https://www.youtube.com/watch?v=${vid}`);
  if (!r.ok) throw new YTError('HTTP', `YouTube returned ${r.status}`);
  const html = await r.text();
  if (/^https:\/\/consent\./.test(r.url) || html.includes('action="https://consent.youtube.com/s"'))
    throw new YTError('CONSENT', 'Open youtube.com once in this browser and accept the cookie notice, then retry.');
  return html;
}

function checkPlayability(ps) {
  const st = ps?.status;
  if (!st || st === 'OK') return;
  const reason = ps.reason || '';
  if (st === 'LOGIN_REQUIRED') {
    if (/not a bot/i.test(reason)) throw new YTError('RATE_LIMIT', 'YouTube asked to confirm this browser is not a bot. Retrying automatically.');
    if (/age/i.test(reason)) throw new YTError('FATAL', 'Age-restricted video');
  }
  if (st === 'ERROR' && /unavailable/i.test(reason)) throw new YTError('FATAL', 'Video unavailable');
  throw new YTError('FATAL', `Video can't be played${reason ? ': ' + reason : ''}`.slice(0, 160));
}

function pickTrack(tracks) {
  const manual = tracks.filter(t => t.kind !== 'asr'), auto = tracks.filter(t => t.kind === 'asr');
  const isEn = t => LANGS.includes(t.languageCode) || /^en\b/i.test(t.languageCode || '');
  return manual.find(isEn) || auto.find(isEn) || manual[0] || auto[0];
}

export function parseTimedText(xml) {
  const out = [];
  const re = /<text\b([^>]*)>([\s\S]*?)<\/text>/g;
  let m;
  while ((m = re.exec(xml))) {
    const a = m[1], start = parseFloat(a.match(/\bstart="([^"]*)"/)?.[1]), dur = parseFloat(a.match(/\bdur="([^"]*)"/)?.[1] || '0');
    // XML entities first, then the HTML inside the caption text (same as the Python library).
    const text = unescapeHtml(unescapeHtml(m[2])).replace(/<[^>]*>/g, '').replace(/\s+/g, ' ').trim();
    if (Number.isFinite(start) && text) out.push([start, Number.isFinite(dur) ? dur : 0, text]);
  }
  return out;
}

export async function transcript(vid) {
  const html = await watchHtml(vid);
  const key = html.match(/"INNERTUBE_API_KEY":\s*"([a-zA-Z0-9_-]+)"/)?.[1];
  if (!key) {
    if (html.includes('class="g-recaptcha"')) throw new YTError('RATE_LIMIT', 'YouTube is showing a captcha. Retrying automatically.');
    throw new YTError('FATAL', "Couldn't read the YouTube page");
  }
  const r = await get(`https://www.youtube.com/youtubei/v1/player?key=${key}`, {
    method: 'POST', credentials: 'omit', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ context: INNERTUBE_CONTEXT, videoId: vid })
  });
  if (!r.ok) throw new YTError('HTTP', `YouTube player API returned ${r.status}`);
  const data = await r.json();
  checkPlayability(data.playabilityStatus);
  const tracks = data.captions?.playerCaptionsTracklistRenderer?.captionTracks;
  if (!tracks?.length) throw new YTError('NO_CAPTIONS', 'No captions on this video');
  const t = pickTrack(tracks);
  const url = t.baseUrl.replace('&fmt=srv3', '');
  if (url.includes('&exp=xpe')) throw new YTError('FATAL', 'YouTube requires a PO token for these captions');
  const tr = await get(url, { credentials: 'omit' });
  if (!tr.ok) throw new YTError('HTTP', `Caption download returned ${tr.status}`);
  const lines = parseTimedText(await tr.text());
  if (!lines.length) throw new YTError('NO_CAPTIONS', 'No captions on this video');
  return lines;
}

/* ---------- playlists (incl. Watch Later) ---------- */
function extractJson(html, marker) {
  const i = html.indexOf(marker);
  if (i < 0) return null;
  let j = html.indexOf('{', i), depth = 0, inStr = false, esc = false;
  for (let k = j; k < html.length; k++) {
    const c = html[k];
    if (inStr) { if (esc) esc = false; else if (c === '\\') esc = true; else if (c === '"') inStr = false; continue; }
    if (c === '"') inStr = true;
    else if (c === '{') depth++;
    else if (c === '}' && --depth === 0) { try { return JSON.parse(html.slice(j, k + 1)); } catch { return null; } }
  }
  return null;
}

function token(o) {   // first continuationCommand.token inside o
  if (!o || typeof o !== 'object') return null;
  if (typeof o.continuationCommand?.token === 'string') return o.continuationCommand.token;
  for (const k in o) { const t = token(o[k]); if (t) return t; }
  return null;
}
/* Collects video ids and continuation tokens. Handles both the classic playlistVideoRenderer and the
 * newer lockupViewModel / continuationItemViewModel layouts. */
function walk(o, ids, conts) {
  if (!o || typeof o !== 'object') return;
  if (Array.isArray(o)) { for (const x of o) walk(x, ids, conts); return; }
  const v = o.playlistVideoRenderer;
  if (v?.videoId) { if (v.isPlayable !== false) ids.push(v.videoId); return; }
  const l = o.lockupViewModel;
  if (l) { if (l.contentType === 'LOCKUP_CONTENT_TYPE_VIDEO' && ID_RE.test(l.contentId || '')) ids.push(l.contentId); return; }
  const c = o.continuationItemRenderer || o.continuationItemViewModel;
  if (c) { const t = token(c); if (t) conts.push(t); return; }
  for (const k in o) walk(o[k], ids, conts);
}

/* Returns {ids, notes}. Follows continuations through youtubei/v1/browse (works for public playlists;
 * for Watch Later YouTube may require a signed request, in which case we keep what the page gave us). */
export async function playlist(listId, { requireLogin = false } = {}) {
  const notes = [];
  const r = await get(`https://www.youtube.com/playlist?list=${encodeURIComponent(listId)}`);
  if (!r.ok) return { ids: [], notes: [`Playlist failed: YouTube returned ${r.status}`] };
  const html = await r.text();
  if (/^https:\/\/consent\./.test(r.url) || html.includes('action="https://consent.youtube.com/s"'))
    return { ids: [], notes: ['Open youtube.com once in this browser and accept the cookie notice, then try again.'] };
  const loggedIn = /"LOGGED_IN":\s*true/.test(html);
  if (requireLogin && !loggedIn) return { ids: [], notes: ['Sign in to YouTube in this browser to import your Watch Later.'], signedOut: true };
  const data = extractJson(html, 'ytInitialData');
  if (!data) return { ids: [], notes: ["Couldn't read that playlist"] };
  const ids = [], conts = [];
  walk(data.contents || data, ids, conts);
  if (!ids.length && !conts.length) {
    const alert = JSON.stringify(data.alerts || '').match(/"text":"([^"]+)"/)?.[1];
    return { ids: [], notes: [alert ? `Playlist: ${alert}` : 'That playlist is empty or private'] };
  }
  const key = html.match(/"INNERTUBE_API_KEY":\s*"([a-zA-Z0-9_-]+)"/)?.[1];
  const ver = html.match(/"INNERTUBE_CLIENT_VERSION":\s*"([^"]+)"/)?.[1] || '2.20250101.00.00';
  let pages = 0, stuck = false;
  while (conts.length && key && pages < 60) {
    const token = conts.shift(); pages++;
    try {
      const c = await get(`https://www.youtube.com/youtubei/v1/browse?key=${key}&prettyPrint=false`, {
        method: 'POST', headers: { 'Content-Type': 'application/json', 'X-YouTube-Client-Name': '1', 'X-YouTube-Client-Version': ver },
        body: JSON.stringify({ context: { client: { clientName: 'WEB', clientVersion: ver, hl: 'en' } }, continuation: token })
      });
      if (!c.ok) { stuck = true; break; }
      const before = ids.length;
      walk(await c.json(), ids, conts);
      if (ids.length === before) { conts.length = 0; break; }   // nothing more: end of the list
    } catch { stuck = true; break; }
  }
  // The header says how many videos there are; hidden/unavailable ones account for small differences.
  const total = parseInt((JSON.stringify(data.header || {}).match(/"text":"([\d,.]+)"\},\{"text":" videos?"/)?.[1] || '').replace(/[,.]/g, '')) || 0;
  const short = total ? ids.length < total * 0.95 && total - ids.length > 2 : stuck || conts.length > 0;
  if (short) notes.push(`Imported the first ${ids.length}${total ? ' of ' + total : ''} videos. YouTube didn't return the rest.`);
  return { ids: [...new Set(ids)], notes };
}

export async function expand(text) {
  const ids = [], notes = [];
  for (const u of String(text || '').split(/[\s,]+/).filter(Boolean)) {
    const pl = u.match(PL_RE), m = u.match(YT_RE);
    if (pl && !m) {
      try { const r = await playlist(pl[1], { requireLogin: pl[1] === 'WL' || pl[1] === 'LL' }); ids.push(...r.ids); notes.push(...r.notes); }
      catch (e) { notes.push('Playlist failed: ' + e.message); }
    } else if (m) ids.push(m[1]);
    else if (ID_RE.test(u)) ids.push(u);
  }
  return { ids: [...new Set(ids)], notes };
}
