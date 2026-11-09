/* Later Now background service worker: the whole "server", running in the user's browser.
 * Storage: chrome.storage.local (unlimitedStorage). State is cached in memory and written through.
 * The UI (app/index.html) talks to it with chrome.runtime.sendMessage({type:'api', method, path, body}). */
import { YTError, expand, meta, playlist, transcript } from './src/youtube.js';
import { AIError, BATCH_CHARS, BATCH_MAX, SOLO_CHARS, chunks, gemChoices, lastModel, listModels, normTopic,
         quotaStatus, resetQuota, segment, segmentBatch, segmentVideo, transcriptText } from './src/ai.js';

const now = () => Date.now() / 1000;
const BUSY = ['fetching captions', 'finding moments'];
const LEASE = 90;          // seconds; in-progress items whose lease is older are recovered
const YT_GAP = 3;          // seconds between caption fetches
const isBusy = s => !['ready', 'failed', 'needs_key'].includes(s);   // queued, waiting or in progress

/* ---------------- storage ---------------- */
const KEYS = ['videos', 'moments', 'nextId', 'prefs', 'hist', 'saved', 'settings', 'progress'];
let S = null, loading = null;
function load() {
  if (S) return Promise.resolve(S);
  return loading ||= chrome.storage.local.get(KEYS).then(d => {
    S = { videos: d.videos || {}, moments: d.moments || [], nextId: d.nextId || 1, prefs: d.prefs || {}, hist: d.hist || {},
          saved: d.saved || {}, settings: d.settings || {},
          progress: typeof d.progress === 'number' ? { moment: d.progress, t: 0 } : (d.progress || null) };
    return S;
  });
}
const save = (...keys) => chrome.storage.local.set(Object.fromEntries(keys.map(k => [k, S[k]])));
const trKey = vid => 'tr:' + vid;
async function getLines(vids) {
  const d = await chrome.storage.local.get(vids.map(trKey));
  return Object.fromEntries(vids.map(v => [v, d[trKey(v)] || null]));
}

/* ---------------- YouTube embeds in extension pages ----------------
 * chrome-extension:// pages send no Referer, and YouTube now refuses such embeds (error 152/153).
 * Give embeds requested by this extension (only) a valid https Referer: our own chromiumapp.org origin. */
async function registerRules() {
  const id = chrome.runtime.id;
  await chrome.declarativeNetRequest.updateDynamicRules({
    removeRuleIds: [1, 2],
    addRules: [{
      id: 1, priority: 1,
      action: { type: 'modifyHeaders', requestHeaders: [{ header: 'referer', operation: 'set', value: `https://${id}.chromiumapp.org/` }] },
      condition: { urlFilter: '||youtube.com/embed/', resourceTypes: ['sub_frame'], initiatorDomains: [id] }
    }, {
      // Our own caption/playlist fetches (not page traffic): youtubei/v1 answers 403 to an Origin of
      // chrome-extension://, and in the EU a browser without a consent cookie is redirected to consent.youtube.com.
      // The appended SOCS cookie comes after any the user already has, so their own choice wins.
      id: 2, priority: 1,
      action: { type: 'modifyHeaders', requestHeaders: [
        { header: 'origin', operation: 'set', value: 'https://www.youtube.com' },
        { header: 'cookie', operation: 'append', value: 'SOCS=CAI' }
      ] },
      condition: { urlFilter: '||youtube.com/', resourceTypes: ['xmlhttprequest'], initiatorDomains: [id] }
    }]
  });
}

/* ---------------- feed ---------------- */
const isDone = (act, w, dur) => act === 'like' || act === 'save' || w >= 0.8 * dur;
const cooldown = k => Math.min(7 * 86400, 6 * 3600 * 2 ** Math.max(0, (k || 1) - 1));
const readyVids = () => new Set(Object.values(S.videos).filter(v => v.status === 'ready').map(v => v.id));

async function feed(n, exclude, topic, saved, resume) {
  const hist = S.hist, t = now();
  const eligible = id => { const h = hist[id]; return !h || (!h.done && t - h.last >= cooldown(h.skips)); };
  const ready = readyVids();
  let rows = S.moments.filter(m => ready.has(m.vid) && (!topic || m.topic === topic) && (!saved || S.saved[m.id]) && !exclude.has(m.id));
  const pool = saved ? rows : rows.filter(r => eligible(r.id));   // never repeat finished moments
  const score = r => { const [sc, k] = S.prefs[r.topic] || [0.5, 0]; return sc + 0.35 / Math.sqrt(1 + k) + 0.04 * r.hook + Math.random() * 0.15 - 0.08 * (hist[r.id]?.skips || 0); };
  const sc = new Map(pool.map(r => [r.id, saved ? r.id : score(r)]));
  pool.sort((a, b) => sc.get(b.id) - sc.get(a.id));
  const out = []; let last = null;
  for (const r of pool) {
    if (out.length >= n) break;
    if (r.vid === last && pool.some(p => p.vid !== last && !out.includes(p))) continue;
    out.push(r); last = r.vid;
  }
  // resume: the moment that was on screen when the overlay was closed or the tab went away comes first,
  // unless it has been finished since (an interrupted view doesn't start its cooldown here).
  const pm = S.progress?.moment;
  if (resume && !saved && pm != null && !exclude.has(pm) && !hist[pm]?.done) {
    const r = rows.find(m => m.id === pm);
    if (r) { const i = out.indexOf(r); if (i >= 0) out.splice(i, 1); out.unshift(r); if (out.length > n) out.pop(); }
  }
  const vids = [...new Set(out.map(r => r.vid))];
  const tr = vids.length ? await getLines(vids) : {};
  return out.map(r => {
    const v = S.videos[r.vid] || {};
    return { ...r, ...(resume && r.id === pm && S.progress?.t ? { resume_t: S.progress.t } : {}), vtitle: v.title || r.vid, channel: v.channel || '', is_saved: S.saved[r.id] ? 1 : 0,
             lines: (tr[r.vid] || []).filter(l => l[0] >= r.start - 2 && l[0] < r.end) };
  });
}

function event(e) {
  const id = parseInt(e.moment), m = S.moments.find(x => x.id === id); if (!m) return;
  const dur = Math.max(1, +e.dur || 1), w = Math.max(0, +e.watched || 0), act = e.action || 'watch';
  if (act === 'unsave') { delete S.saved[id]; save('saved'); return; }
  const signal = (act === 'like' || act === 'save') ? 1 : (act === 'skip' && w < 3 ? 0 : Math.min(1, w / dur));
  const [sc, n] = S.prefs[m.topic] || [0.5, 0];
  S.prefs[m.topic] = [sc + Math.max(0.15, 1 / (n + 2)) * (signal - sc), n + 1];
  const h = S.hist[id] || { done: 0, last: 0, skips: 0 }, d = isDone(act, w, dur);
  S.hist[id] = { done: h.done || (d ? 1 : 0), last: now(), skips: h.skips + (d ? 0 : 1) };
  const keys = ['prefs', 'hist'];
  if (act === 'save') { S.saved[id] ||= now(); keys.push('saved'); }
  save(...keys);
}

async function status() {
  const counts = {};
  for (const v of Object.values(S.videos)) counts[v.status] = (counts[v.status] || 0) + 1;
  const ready = readyVids(), live = S.moments.filter(m => ready.has(m.vid));
  const tn = {};
  for (const m of live) tn[m.topic] = (tn[m.topic] || 0) + 1;
  const topics = Object.entries(tn).map(([topic, n]) => ({ topic, n, score: S.prefs[topic]?.[0] ?? 0.5 }))
    .sort((a, b) => b.score - a.score || b.n - a.n);
  let done = 0, later = 0;
  for (const m of live) { const h = S.hist[m.id]; if (h) h.done ? done++ : later++; }
  const st = S.settings;
  return { counts, topics, moments: live.length, saved: Object.keys(S.saved).length, done, later,
           busy: Object.entries(counts).filter(([k]) => isBusy(k)).reduce((a, [, v]) => a + v, 0),
           ai: 'gemini', ai_ready: aiReady(), model: await lastModel(), quota: await quotaStatus(st.gemini_key) };
}

function videos() {
  const count = {};
  for (const m of S.moments) count[m.vid] = (count[m.vid] || 0) + 1;
  return Object.values(S.videos).sort((a, b) => b.added - a.added).slice(0, 300)
    .map(v => ({ id: v.id, title: v.title, channel: v.channel, status: v.status, error: v.error || null,
                  retry_at: v.retry_at || 0, moments: count[v.id] || 0 }));
}

function addIds(ids) {
  let added = 0; const t = now();
  ids.forEach((id, j) => {
    if (S.videos[id]) return;
    S.videos[id] = { id, title: id, channel: '', status: 'queued', error: null, added: t + j / 1000, retry_at: 0, tries: 0, lease: 0 };
    added++;
  });
  if (added) { save('videos'); pump(); }
  return added;
}

/* ---------------- settings ---------------- */
const hint = k => k ? '…' + k.slice(-4) : '';
const aiReady = () => !!S.settings.gemini_key;
async function settingsView() {
  const s = S.settings;
  return { provider: 'gemini', ai_ready: aiReady(), key_set: !!s.gemini_key, key_hint: hint(s.gemini_key), model: await lastModel() };
}

/* Videos that were held back for a key or quota (or settled for plain 60s chunks) get another go with a new key. */
async function requeueForKey() {
  let n = 0;
  for (const v of Object.values(S.videos))
    if (v.status === 'needs_key' || (v.status === 'waiting' && /^Free Gemini/.test(v.error || '')) ||
        (v.status === 'ready' && /^Used 60s chunks/.test(v.error || '')) ||
        (v.status === 'failed' && /^No captions/.test(v.error || '') && S.settings.gemini_key)) {
      Object.assign(v, { status: 'queued', retry_at: 0, tries: 0, error: null });
      if (!v.chars) v.cap = 0;   // no transcript stored: (re)check captions first
      n++;
    }
  if (n) { await save('videos'); pump(); }
}

async function setSettings(b) {
  const s = S.settings;
  if (b.gemini_key === '') {
    delete s.gemini_key; delete s.model; await save('settings'); await resetQuota();
    return { status: 200, data: { ok: true, model: 'auto', models: [] } };
  }
  const key = typeof b.gemini_key === 'string' ? b.gemini_key.trim() : s.gemini_key;
  if (!key) return { status: 400, data: { error: 'Add your Gemini key first.' } };
  let models;
  try { models = await listModels(key); }
  catch (e) {
    if (e.code === 'BAD_KEY') return { status: 400, data: { error: "That key didn't work. Check it and try again.", detail: e.message } };
    return { status: 500, data: { error: e.message } };
  }
  // The model is picked automatically from the free-tier pool (src/ai.js); any requested model is ignored.
  const newKey = key !== s.gemini_key;
  s.gemini_key = key; delete s.model;
  await save('settings');
  if (newKey) {
    await resetQuota(models);   // a different key may be a different Google project with its own quotas
    await requeueForKey();
  }
  return { status: 200, data: { ok: true, model: await lastModel(), models: gemChoices(models) } };
}

/* ---------------- API router ---------------- */
async function api(method, path, body = {}) {
  await load();
  const u = new URL(path, 'http://x/'), p = u.pathname.replace(/^\//, ''), g = (k, d = '') => u.searchParams.get(k) ?? d;
  if (method === 'GET') {
    if (p === 'feed') {
      const ex = new Set(g('exclude').split(',').filter(x => /^\d+$/.test(x)).map(Number));
      return { status: 200, data: await feed(Math.min(20, parseInt(g('n', '6')) || 6), ex, g('topic') || null, g('saved') === '1', g('resume') === '1') };
    }
    if (p === 'status') return { status: 200, data: await status() };
    if (p === 'progress') return { status: 200, data: S.progress || {} };
    if (p === 'videos') return { status: 200, data: videos() };
    if (p === 'settings') return { status: 200, data: await settingsView() };
    return { status: 404, data: { error: 'not found' } };
  }
  if (p === 'add') {
    const { ids, notes } = await expand(body.urls);
    return { status: 200, data: { found: ids.length, new: addIds(ids), notes } };
  }
  if (p === 'watchlater') {
    const r = await playlist('WL', { requireLogin: true });
    return { status: 200, data: { found: r.ids.length, new: addIds(r.ids), notes: r.notes.length ? r.notes : (r.ids.length ? [] : ['Your Watch Later is empty']) } };
  }
  if (p === 'retry') {
    let n = 0;
    for (const v of Object.values(S.videos))
      if (((v.status === 'failed' || v.status === 'waiting') && (S.settings.gemini_key || !/^No captions/.test(v.error || ''))) ||
          (v.status === 'needs_key' && aiReady())) { v.status = 'queued'; v.retry_at = 0; v.solo = 0; n++; }
    if (n) { await save('videos'); pump(); }
    return { status: 200, data: { requeued: n } };
  }
  if (p === 'event') { event(body); return { status: 200, data: { ok: true } }; }
  if (p === 'progress') {
    const id = parseInt(body.moment), t = +body.t;
    S.progress = Number.isFinite(id) ? { moment: id, t: Number.isFinite(t) ? t : 0, at: Date.now() } : null; save('progress');
    return { status: 200, data: { ok: true } };
  }
  if (p === 'log') { console.log('client', JSON.stringify(body).slice(0, 500)); return { status: 200, data: { ok: true } }; }
  if (p === 'settings') return setSettings(body);
  return { status: 404, data: { error: 'not found' } };
}

/* ---------------- processing queue ----------------
 * 1. Captions: one video at a time, YT_GAP apart. The transcript is stored and the video marked cap=1.
 * 2. Moments: videos with captions go to Gemini together (segmentBatch: up to BATCH_MAX videos / BATCH_CHARS in one
 *    request). Long videos, and videos a batch answer skipped (solo=1), go alone. Videos without captions are
 *    watched by Gemini (segmentVideo).
 * When the free quota is used up, videos wait (status 'waiting', retry_at) and continue automatically. */
let running = false, ytLast = 0, keepAlive = null;
const sleep = ms => new Promise(r => setTimeout(r, ms));
const gemKey = () => S.settings.gemini_key || '';

function set(v, fields) { Object.assign(v, fields, { lease: now() }); return save('videos'); }
function backoff(v, base, cap, msg) {
  const tries = (v.tries || 0) + 1;
  return set(v, { status: 'waiting', tries, retry_at: now() + Math.min(cap, base * 2 ** (tries - 1)), error: msg });
}
const due = (v, t) => v.status === 'queued' || (v.status === 'waiting' && v.retry_at < t) || (BUSY.includes(v.status) && (v.lease || 0) < t - LEASE);
const byAge = (a, b) => (a.status === 'waiting') - (b.status === 'waiting') || a.added - b.added;
const topicList = () => Object.entries(S.moments.reduce((a, m) => (a[m.topic] = (a[m.topic] || 0) + 1, a), {}))
  .sort((a, b) => b[1] - a[1]).map(x => x[0]);

async function store(v, ms, err) {
  S.moments = S.moments.filter(m => m.vid !== v.id);
  for (const [start, end, t, topic, hook] of ms) S.moments.push({ id: S.nextId++, vid: v.id, start, end, title: t, topic: normTopic(topic), hook });
  await save('moments', 'nextId');
  await set(v, { status: 'ready', error: err, tries: 0, retry_at: 0, solo: 0 });
}

function rateLimited(v, e) {
  const tries = (v.tries || 0) + 1;
  return set(v, { status: 'waiting', tries, retry_at: e.retryAt || now() + Math.min(6 * 3600, 1800 * 2 ** (tries - 1)),
                  error: `${e.message}. Continues automatically.` });
}

async function failed(v, e) {
  if (e instanceof AIError && e.code === 'RATE_LIMIT') return rateLimited(v, e);
  const code = e instanceof YTError ? e.code : '';
  if (code === 'RATE_LIMIT') { ytLast = now() + 300; return backoff(v, 600, 6 * 3600, e.message); }
  if (code === 'NETWORK' || code === 'HTTP' || (e instanceof AIError && e.code === 'NETWORK')) return backoff(v, 120, 3600, e.message);
  return set(v, { status: 'failed', error: String(e.message || e).slice(0, 200) });
}

/* Step 1 for one video: title + captions. Returns false if the video is done with (failed / waiting). */
async function fetchCaptions(v) {
  await set(v, { status: 'fetching captions' });
  try {
    if (!v.channel && v.title === v.id) { const [title, channel] = await meta(v.id); Object.assign(v, { title, channel }); }
    if (!(await getLines([v.id]))[v.id]) {
      const wait = ytLast + YT_GAP - now(); if (wait > 0) await sleep(wait * 1000);
      let lines;
      try {
        try { lines = await transcript(v.id); } finally { ytLast = now(); }
      } catch (e) {
        // No captions, or YouTube blocks caption requests: Gemini can watch the video instead.
        const usable = e instanceof YTError && (e.code === 'NO_CAPTIONS' || e.code === 'RATE_LIMIT' || /PO token/.test(e.message));
        if (!usable) throw e;
        if (!gemKey()) throw e.code === 'NO_CAPTIONS' ? new YTError('FATAL', 'No captions (a Gemini key lets Later Now watch it instead)') : e;
        await set(v, { status: 'queued', cap: 1, nocap: 1, chars: 0 });
        return true;
      }
      await chrome.storage.local.set({ [trKey(v.id)]: lines });
      v.chars = transcriptText(lines).length;
    }
    if (!v.chars) v.chars = transcriptText((await getLines([v.id]))[v.id]).length;
    await set(v, { status: 'queued', cap: 1, nocap: 0 });
    return true;
  } catch (e) { await failed(v, e); return false; }
}

/* Step 2: moments for a group of captioned videos (one Gemini request if there's more than one). */
async function findMoments(group) {
  const gem = gemKey();
  const tr = await getLines(group.map(v => v.id));
  const list = group.map(v => ({ v, lines: tr[v.id] })).filter(x => x.lines?.length);
  for (const v of group) if (!tr[v.id]?.length) await set(v, { status: 'queued', cap: 0 });   // transcript lost: fetch again
  if (!list.length) return;
  for (const { v } of list) await set(v, { status: 'finding moments', error: null });
  if (!gem) { for (const { v } of list) await set(v, { status: 'needs_key', error: 'Add your Gemini key in Library' }); return; }
  try {
    if (list.length === 1) {
      const { v, lines } = list[0];
      let ms, err = null;
      try { ms = await segment(gem, v.title, lines, topicList()); }
      catch (e) {
        if (e instanceof AIError && (e.code === 'RATE_LIMIT' || e.code === 'NETWORK')) throw e;
        ms = chunks(lines); err = `Used 60s chunks (${e.message})`.slice(0, 200);
      }
      return store(v, ms, err);
    }
    const res = await segmentBatch(gem, list.map(({ v, lines }) => ({ vid: v.id, title: v.title, lines })), topicList());
    let skipped = 0;
    for (const { v } of list) {
      const ms = res.get(v.id);
      if (ms) await store(v, ms, null);
      else { skipped++; await set(v, { status: 'queued', solo: 1 }); }   // the model skipped it: try it on its own
    }
    console.log(`batch: ${list.length} videos in one request, ${skipped} skipped`);
  } catch (e) {
    if (e instanceof AIError && e.code === 'RATE_LIMIT') { for (const { v } of list) await rateLimited(v, e); return; }
    if (e instanceof AIError && e.code === 'BAD_KEY') { for (const { v } of list) await set(v, { status: 'needs_key', error: "Gemini didn't accept the key" }); return; }
    // A broken batch answer: every video gets its own request next time.
    for (const { v } of list) await (list.length > 1 ? set(v, { status: 'queued', solo: 1 }) : failed(v, e));
  }
}

/* No captions: Gemini watches the video. */
async function watchVideo(v) {
  const gem = gemKey();
  if (!gem) return set(v, { status: 'failed', error: 'No captions (a Gemini key lets Later Now watch it instead)' });
  await set(v, { status: 'finding moments', error: null });
  try { await store(v, await segmentVideo(gem, v.id, v.title, topicList()), 'No captions: Gemini watched the video to pick these'); }
  catch (e) { await failed(v, e); }
}

/* One unit of work, or false when there is nothing to do right now. */
async function step() {
  const t = now(), gem = gemKey();
  const due_ = Object.values(S.videos).filter(v => due(v, t)).sort(byAge);
  if (!due_.length) return false;
  for (const v of due_) if (BUSY.includes(v.status)) v.status = 'queued';   // recovered after a restart
  const capped = due_.filter(v => v.cap), uncapped = due_.filter(v => !v.cap);
  // Gather a full batch of captions before asking the AI, so one request covers as many videos as possible.
  if (uncapped.length && capped.filter(v => !v.nocap && !v.solo && (v.chars || 0) <= SOLO_CHARS).length < BATCH_MAX) {
    await fetchCaptions(uncapped[0]);
    return true;
  }
  if (!gem) {
    for (const v of capped) await set(v, { status: 'needs_key', error: 'Add your Gemini key in Library' });
    return capped.length > 0;
  }
  const v0 = capped[0];
  if (v0.nocap) { await watchVideo(v0); return true; }
  if (v0.solo || (v0.chars || 0) > SOLO_CHARS) { await findMoments([v0]); return true; }
  const group = []; let size = 0;
  for (const v of capped) {
    if (v.nocap || v.solo || (v.chars || 0) > SOLO_CHARS) continue;
    if (group.length >= BATCH_MAX || (group.length && size + (v.chars || 0) > BATCH_CHARS)) break;
    group.push(v); size += v.chars || 0;
  }
  await findMoments(group);
  return true;
}

async function pump() {
  if (running) return; running = true;
  await load();
  keepAlive = setInterval(() => {   // keep the service worker alive during long YouTube / AI calls
    chrome.runtime.getPlatformInfo();
    for (const v of Object.values(S.videos)) if (BUSY.includes(v.status)) v.lease = now();
    save('videos');
  }, 20000);
  try { while (await step()); }
  catch (e) { console.error('queue', e); }
  finally { clearInterval(keepAlive); running = false; }
}

/* ---------------- Later Now window ----------------
 * The toolbar button opens Later Now in its own phone-sized window (float.html), straight away. Clicking it again
 * brings the window forward, or closes it if it is already in front. From the window, the pin button floats the
 * player above every app. While the window is open the in-page overlay stays hidden (one player at a time). */
const WIN_W = 400, WIN_H = 820;
async function winId() {
  const { laternow_window } = await chrome.storage.session.get('laternow_window');
  if (!laternow_window) return 0;
  try { await chrome.windows.get(laternow_window); return laternow_window; } catch { return 0; }
}
async function openWindow() {
  const id = await winId();
  if (id) return chrome.windows.update(id, { focused: true, state: 'normal' });
  const { win_bounds: b } = await chrome.storage.local.get('win_bounds');
  const w = await chrome.windows.create({ url: chrome.runtime.getURL('float.html'), type: 'popup', focused: true,
                                          width: b?.width || WIN_W, height: b?.height || WIN_H,
                                          ...(b && Number.isFinite(b.left) ? { left: b.left, top: b.top } : {}) });
  await chrome.storage.session.set({ laternow_window: w.id });
  await chrome.storage.local.set({ overlay_float: true, overlay_open: false });
}
async function closeWindow() {
  const id = await winId();
  await chrome.storage.session.remove(['laternow_window', 'pinned']);
  await chrome.storage.local.set({ overlay_float: false, overlay_open: false });
  if (id) chrome.windows.remove(id).catch(() => {});
}
async function toggleWindow() {
  const id = await winId();
  if (!id) return openWindow();
  const w = await chrome.windows.get(id), { pinned } = await chrome.storage.session.get('pinned');
  if (pinned || (w.focused && w.state !== 'minimized')) return closeWindow();   // pinned: the toolbar closes the float
  return chrome.windows.update(id, { focused: true, state: 'normal' });
}
chrome.action.onClicked.addListener(() => toggleWindow());
chrome.windows.onRemoved.addListener(async id => {
  const { laternow_window } = await chrome.storage.session.get('laternow_window');
  if (id === laternow_window) { await chrome.storage.session.remove(['laternow_window', 'pinned']); chrome.storage.local.set({ overlay_float: false }); }
});
chrome.windows.onBoundsChanged?.addListener(async w => {
  const { laternow_window } = await chrome.storage.session.get('laternow_window');
  if (w.id === laternow_window && w.state === 'normal') chrome.storage.local.set({ win_bounds: { left: w.left, top: w.top, width: w.width, height: w.height } });
});
chrome.runtime.onMessage.addListener((m, sender) => {
  if (sender.id !== chrome.runtime.id) return;
  if (m?.type === 'laternow-float') openWindow();   // the overlay's "open in window" button
  if (m?.type === 'laternow-pinned') chrome.storage.session.set({ pinned: !!m.on });
});

/* ---------------- in-page overlay (Alt+Shift+M) ----------------
 * The overlay script only runs automatically in tabs loaded after install: if this tab doesn't have it yet, inject
 * it and open. Pages extensions can't touch (chrome://, the new tab page, the Web Store) get the window instead. */
async function toggle(tab) {
  tab = tab?.id ? tab : (await chrome.tabs.query({ active: true, lastFocusedWindow: true }))[0];
  if (await winId()) return toggleWindow();   // the window is open: the shortcut acts on it
  const { overlay_open } = await chrome.storage.local.get('overlay_open');
  if (!tab?.id) return openWindow();
  let present = false;
  try { present = !!(await chrome.tabs.sendMessage(tab.id, { type: 'laternow-ping' })); } catch {}
  if (present) return chrome.storage.local.set({ overlay_open: !overlay_open });
  try { await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ['content.js'] }); }
  catch { return openWindow(); }
  if (!overlay_open) await chrome.storage.local.set({ overlay_open: true });
}
self.momentsToggle = toggle; self.momentsWindow = toggleWindow;   // for tests
chrome.commands.onCommand.addListener((c, tab) => { if (c === 'toggle-overlay') toggle(tab); });

/* ---------------- wiring ---------------- */
chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  if (msg?.type !== 'api') return;
  // Only our own extension pages (the feed UI) may call the API, not content scripts on web pages.
  if (sender.id !== chrome.runtime.id || !String(sender.url || '').startsWith(`chrome-extension://${chrome.runtime.id}/`)) return;
  api(String(msg.method || 'GET').toUpperCase(), String(msg.path || ''), msg.body || {})
    .then(reply, e => reply({ status: 500, data: { error: String(e?.message || e) } }));
  return true;
});

// Tabs that were open before install/update don't have the overlay script yet: add it so the next click just works.
async function injectExisting() {
  for (const t of await chrome.tabs.query({ url: ['http://*/*', 'https://*/*'] }))
    chrome.scripting.executeScript({ target: { tabId: t.id }, files: ['content.js'] }).catch(() => {});
}
chrome.runtime.onInstalled.addListener(() => injectExisting());

const boot = () => { chrome.storage.local.set({ overlay_float: false }); registerRules().catch(e => console.error('rules', e)); chrome.alarms.create('queue', { periodInMinutes: 1 }); pump(); };
chrome.runtime.onInstalled.addListener(boot);
chrome.runtime.onStartup.addListener(boot);
chrome.storage.onChanged.addListener((ch, area) => { if (area === 'local' && S && ch.settings) S.settings = ch.settings.newValue || {}; });
chrome.alarms.onAlarm.addListener(a => { if (a.name === 'queue') pump(); });
registerRules().catch(() => {});
pump();
