const $ = s => document.querySelector(s), $$ = s => document.querySelectorAll(s);

/* ---------- environment: self-hosted web app or Chrome extension page ---------- */
const IS_EXT = location.protocol === 'chrome-extension:';
const SRC = new URLSearchParams(location.search).get('src') || '';   // extension: the tab the overlay sits on
const YT_RE = /(?:v=|youtu\.be\/|shorts\/|embed\/|live\/)([A-Za-z0-9_-]{11})/;
if (IS_EXT) document.documentElement.classList.add('ext');

const hk = new URLSearchParams(location.hash.slice(1)).get('k');
if (hk){ localStorage.laternowKey = hk; history.replaceState(null, '', location.pathname + location.search); }
let K = localStorage.laternowKey || localStorage.momentsKey || localStorage.feedKey || '';

async function api(p, body){
  let status, data;
  if (IS_EXT){
    const r = await chrome.runtime.sendMessage({type: 'api', method: body ? 'POST' : 'GET', path: p, body});
    if (!r) throw new Error('Extension background did not answer');
    ({status, data} = r);
  } else {
    const r = await fetch(`/api/${p}${p.includes('?') ? '&' : '?'}k=${encodeURIComponent(K)}`,
      body ? {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body)} : {});
    if (r.status === 401){ openSheet('#keySheet'); throw new Error('key'); }
    status = r.status; data = await r.json().catch(() => ({}));
  }
  if (status >= 400){ const e = new Error(data?.error || `Error ${status}`); e.status = status; throw e; }
  return data;
}
const dlog = (ev, extra = {}) => {
  const d = {ev, ua: navigator.userAgent, w: innerWidth, h: innerHeight, cur, ready, st: ready ? player.getPlayerState() : null, ...extra};
  try { IS_EXT ? api('log', d).catch(() => {}) : navigator.sendBeacon(`/api/log?k=${encodeURIComponent(K)}`, JSON.stringify(d)); } catch {}
};
addEventListener('error', e => dlog('jserror', {msg: e.message, line: e.lineno}));

const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'}[c]));
const fmt = s => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;
const thumb = (v, q = 'hqdefault') => `https://i.ytimg.com/vi/${v}/${q}.jpg`;
const ytUrl = m => `https://www.youtube.com/watch?v=${m.vid}&t=${Math.floor(m.start)}s`;
const ICON = {
  heart: '<path d="M12 20.5s-7.5-4.6-9.6-9.3C.9 7.7 3.3 4 7 4c2.1 0 3.6 1.1 5 3 1.4-1.9 2.9-3 5-3 3.7 0 6.1 3.7 4.6 7.2C19.5 15.9 12 20.5 12 20.5z"/>',
  full: '<path d="M14 4h6v6M20 4l-8 8M10 5H6a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2h11a2 2 0 0 0 2-2v-4"/>'
};
const svg = k => `<svg viewBox="0 0 24 24">${ICON[k]}</svg>`;
const S = LaterNowPlayer.State;

let mode = {topic: ''};
let soundOn = (localStorage.laternowSound ?? localStorage.momentsSound) === '1', items = [], cur = -1, player, ready = false, playing = false, watched = 0, loading = false, rate = 1, exhausted = false;
let lastStatus = null, settings = null, firstLoad = true;
// Auto-advance only once the new moment is really playing: right after a scroll the player can still report the
// previous video's time or its 'ended' state, which used to skip the moment you just scrolled to.
let settled = false;
const sc = $('#scroller');

/* ---------- cards ---------- */
function card(m, i){
  const el = document.createElement('section'); el.className = 'card';
  el.innerHTML = `<div class="bgimg" style="background-image:url(${thumb(m.vid)})"></div>
    <div class="head"><div class="topic">${esc(m.topic)}</div><div class="title">${esc(m.title)}</div></div>
    <div class="slot" style="background-image:url(${thumb(m.vid)})"></div>
    <div class="cap"></div>
    <div class="meta"><b>${esc(m.vtitle)}</b>${esc(m.channel || 'YouTube')} · ${fmt(m.start)}–${fmt(m.end)}</div>
    <div class="rail">
      <button class="like${m.liked ? ' on' : ''}" aria-label="Like">${svg('heart')}</button>
      <button class="full" aria-label="Open full video">${svg('full')}</button>
    </div>
    <div class="prog"><div class="track"><i></i></div></div>`;
  el.querySelector('.like').onclick = () => like(i);
  el.querySelector('.full').onclick = () => openFull(i);
  scrub(el.querySelector('.prog'), i);
  return el;
}
const BREAK_EVERY = 10;   // a breather card after this many moments
function pauseCard(m){
  const el = document.createElement('section'); el.className = 'pause';
  if (m.kind === 'break'){
    el.innerHTML = `<h2>Take a breather</h2>
      <p>That was ${m.recap.length} ideas in about ${Math.max(1, Math.round(m.secs / 60))} minutes. Which one stuck with you?</p>
      <ol>${m.recap.map(t => `<li>${esc(t)}</li>`).join('')}</ol>
      <p class="hint">Swipe up when you're ready. Or stop here, that counts too.</p>`;
  } else {
    const later = lastStatus?.later || 0;
    el.innerHTML = `<h2>You're all caught up</h2>
      <p>${later ? `${later} moment${later === 1 ? '' : 's'} you skipped will come back later, so nothing gets lost.` : 'You\'ve watched every moment from your videos.'}</p>
      <div class="row"><button class="btn" data-add>Add videos</button></div>
      <p class="hint">New moments appear here as your videos finish processing.</p>`;
    el.querySelector('[data-add]').onclick = () => openAdd();
  }
  return el;
}
const real = () => items.filter(m => !m.kind);
let sinceBreak = [], breakSecs = 0;
const needsKey = () => settings && settings.provider === 'gemini' && !settings.ai_ready;
function emptyState(){
  const t = mode.topic;
  sc.innerHTML = `<div class="empty">
    <h2>${t ? `Nothing left in ${esc(t)}` : 'Your feed is empty'}</h2>
    <p>${t ? 'Pick another topic, or add more videos.' : 'Add a few long YouTube videos. Their best moments show up here in a minute or two.'}</p>
    ${needsKey() ? `<button class="btn" data-ai>Connect Gemini</button><p class="hint">Step 1 of 2. Then add videos.</p>` : `<button class="btn" data-add>Add videos</button>`}
  </div>`;
  sc.querySelector('[data-add]')?.addEventListener('click', openAdd);
  sc.querySelector('[data-ai]')?.addEventListener('click', openAI);
}
async function more(){
  if (loading || exhausted) return; loading = true;
  const q = `feed?n=6&exclude=${real().map(m => m.id).join(',')}` + (mode.topic ? `&topic=${encodeURIComponent(mode.topic)}` : '') + (firstLoad ? '&resume=1' : '');
  let got = []; try { got = await api(q); firstLoad = false; } catch { loading = false; return; }
  const fresh = got.filter(m => !items.some(x => x.id === m.id));
  if (!fresh.length) exhausted = true;
  if (!items.length && !fresh.length) emptyState();
  for (const m of fresh){
    items.push(m); sc.appendChild(card(m, items.length - 1));
    sinceBreak.push(m.title); breakSecs += m.end - m.start;
    if (sinceBreak.length >= BREAK_EVERY){
      const b = {kind: 'break', recap: sinceBreak.slice(), secs: breakSecs}; sinceBreak = []; breakSecs = 0;
      items.push(b); sc.appendChild(pauseCard(b));
    }
  }
  if (exhausted && items.length && !items.some(m => m.kind === 'end')){
    const e = {kind: 'end'}; items.push(e); sc.appendChild(pauseCard(e));
  }
  loading = false; upNext();
}
async function reload(){
  report(); items = []; cur = -1; exhausted = false; firstLoad = true; sinceBreak = []; breakSecs = 0; sc.innerHTML = ''; sc.scrollTop = 0;
  $('#playerWrap').classList.remove('show'); $('#cover').classList.remove('on'); if (ready) player.pauseVideo();
  await more(); if (items.length) activate(0);
}

/* ---------- playback ---------- */
function onScroll(){
  const i = Math.round(sc.scrollTop / sc.clientHeight);
  if (i !== cur && items[i]) activate(i);
  else if (i === cur && items[cur] && !items[cur].kind) $('#playerWrap').classList.add('show');
  if (i >= items.length - 3) more();
}
let scrollT; sc.addEventListener('scroll', () => {
  clearTimeout(scrollT);
  if (Math.abs(sc.scrollTop - cur * sc.clientHeight) > sc.clientHeight * 0.15) $('#playerWrap').classList.remove('show');
  scrollT = setTimeout(onScroll, 90);
});
function activate(i){
  report(); $('#cover').classList.remove('on'); $('#app').classList.remove('onpause');
  cur = i; watched = 0; settled = false; playing = false; window._actAt = Date.now(); const m = items[i];
  if (m.kind){   // breather / end card: stop the video
    if (ready) player.pauseVideo();
    $('#playerWrap').classList.remove('show'); $('#lsHead').textContent = ''; $('#lsCap').innerHTML = ''; $('#app').classList.add('onpause');
    clearTimeout(window._wd); upNext(); return;
  }
  // Coming from another tab: continue at the second it was left, not at the start of the moment.
  const from = m.resume_t > m.start && m.resume_t < m.end - 2 ? m.resume_t : m.start; delete m.resume_t;
  if (IS_EXT) api('progress', {moment: m.id, t: from}).catch(() => {});
  if (ready){
    if (!soundOn) player.mute();
    player.loadVideoById({videoId: m.vid, startSeconds: from, endSeconds: m.end, suggestedQuality: 'hd720'});
    if (soundOn) player.unMute();
    player.setPlaybackRate(rate);
  }
  $('#lsHead').textContent = m.title; $('#lsCap').innerHTML = '';
  setTimeout(() => $('#playerWrap').classList.add('show'), 280);
  clearTimeout(window._wd); const at = i;
  const stuck = () => { const st = player.getPlayerState(); return cur === at && ready && st !== S.PLAYING && st !== S.BUFFERING; };
  window._wd = setTimeout(() => {
    if (!stuck()) return;
    // The browser may refuse sound until you interact with this tab: keep playing muted, one tap brings sound back.
    if (soundOn && !player.isMuted()){ soundOn = false; $('#snd').classList.remove('off'); player.mute(); player.playVideo(); dlog('muted-fallback'); }
    window._wd = setTimeout(() => {   // still stuck: show a play button the user can tap
      if (stuck()){ dlog('stuck', {st: player.getPlayerState()}); $('#cover').style.backgroundImage = `url(${thumb(m.vid)})`; $('#cover').classList.add('on'); }
    }, 2000);
  }, 1500);
  upNext();
}
function report(action){
  if (cur < 0 || !items[cur] || items[cur].kind || items[cur].reported) return;
  const m = items[cur]; m.reported = true;
  api('event', {moment: m.id, watched, dur: m.end - m.start, action: action || (watched < 3 ? 'skip' : 'watch')}).catch(() => {});
}
const go = i => { if (items[i]) sc.scrollTo({top: i * sc.clientHeight, behavior: 'smooth'}); };
const next = () => go(cur + 1), prev = () => go(cur - 1);
function toggle(){ if (!ready || items[cur]?.kind) return; if (!soundOn) return unmute(); playing ? player.pauseVideo() : player.playVideo(); }
function unmute(){ soundOn = true; localStorage.laternowSound = '1'; player.unMute(); player.setVolume(100); player.playVideo(); $('#snd').classList.add('off'); }
function like(i, x, y){
  const m = items[i]; if (!m || m.kind) return;
  heart(x, y);
  if (m.liked) return; m.liked = true; sc.children[i]?.querySelector('.like')?.classList.add('on');
  api('event', {moment: m.id, watched, dur: m.end - m.start, action: 'like'}).catch(() => {});
}
function openFull(i){ if (!items[i] || items[i].kind) return; if (ready) player.pauseVideo(); window.open(ytUrl(items[i]), '_blank'); }
function heart(x, y){
  const r = $('#app').getBoundingClientRect();
  x = x ?? r.left + r.width / 2; y = y ?? r.top + r.height * .46;
  const h = document.createElement('div'); h.className = 'heart'; h.innerHTML = svg('heart');
  h.style.left = (x - r.left) + 'px'; h.style.top = (y - r.top) + 'px';
  $('#app').appendChild(h); setTimeout(() => h.remove(), 750);
}
let toastT; function toast(t){ const el = $('#toast'); el.textContent = t; el.classList.add('on'); clearTimeout(toastT); toastT = setTimeout(() => el.classList.remove('on'), 1600); }
function scrub(bar, i){
  const seek = e => { const r = bar.getBoundingClientRect(), f = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)), m = items[i];
    if (ready && i === cur){ player.seekTo(m.start + f * (m.end - m.start), true); bar.querySelector('i').style.width = f * 100 + '%'; } };
  bar.addEventListener('pointerdown', e => { e.stopPropagation(); bar.classList.add('drag'); bar.setPointerCapture(e.pointerId); seek(e); });
  bar.addEventListener('pointermove', e => { if (bar.classList.contains('drag')) seek(e); });
  bar.addEventListener('pointerup', () => bar.classList.remove('drag'));
}

player = new LaterNowPlayer($('#player'), {
  vars: {controls: 0, playsinline: 1, rel: 0, iv_load_policy: 3, disablekb: 1, fs: 0, cc_load_policy: 0, mute: 1},
  onReady: () => { ready = true; dlog('ready'); },
  onError: e => {
    dlog('yterror', {code: e.data, vid: items[cur]?.vid});
    if (Date.now() - (window._actAt || 0) < 400) return;   // a late error from the video we just left
    const at = cur;
    toast(e.data === 101 || e.data === 150 ? "This video can't be embedded. Skipping." : 'Video failed to load. Skipping.');
    setTimeout(() => { if (cur === at) next(); }, 1200);
  },
  onStateChange: e => {
    playing = e.data === S.PLAYING;
    const paused = e.data === S.PAUSED && items[cur] && !items[cur].kind;
    if (paused) $('#cover').style.backgroundImage = `url(${thumb(items[cur].vid)})`;
    $('#cover').classList.toggle('on', paused);
    if (e.data === S.ENDED && settled && Date.now() - (window._actAt || 0) > 1500) next();
  }
});

/* captions (word-by-word highlight), progress, watch time */
let lastLine = null, lastBeat = 0;
setInterval(() => {
  if (!ready || cur < 0 || !items[cur] || items[cur].kind) return;
  const m = items[cur], t = player.getCurrentTime();
  if (playing) watched += 0.125 * rate;
  if (playing && Date.now() - (window._actAt || 0) > 1500 && Math.abs(sc.scrollTop - cur * sc.clientHeight) < 4){
    const pw = $('#playerWrap'), cv = $('#cover');
    if (!pw.classList.contains('show') || cv.classList.contains('on')){ pw.classList.add('show'); cv.classList.remove('on'); dlog('healed'); }
  }
  if (IS_EXT && playing && Date.now() - lastBeat > 1500){ lastBeat = Date.now(); api('progress', {moment: m.id, t}).catch(() => {}); }
  const c = sc.children[cur]; if (!c) return;
  const line = (m.lines || []).filter(l => l[0] <= t).pop(), cap = c.querySelector('.cap');
  if (!line || t - line[0] > line[1] + 1.5){ if (lastLine){ cap.innerHTML = ''; lastLine = null; } }
  else {
    if (lastLine !== line){ cap.innerHTML = line[2].replace(/\[.*?\]/g, '').split(/\s+/).filter(Boolean).map(w => `<span>${esc(w)} </span>`).join(''); lastLine = line; }
    const ws = cap.children, k = Math.ceil(Math.min(1, (t - line[0]) / Math.max(.5, line[1])) * ws.length);
    for (let j = 0; j < ws.length; j++) ws[j].classList.toggle('on', j < k);
  }
  $('#lsCap').innerHTML = cap.innerHTML;
  c.querySelector('.prog i').style.width = Math.max(0, Math.min(100, (t - m.start) / (m.end - m.start) * 100)) + '%';
  if (playing && t >= m.start - 3 && t < m.end + 1 && Date.now() - (window._actAt || 0) > 600) settled = true;
  if (settled && playing && t >= m.end - 0.3) next();
}, 125);

/* tap = pause/play, double tap = like at finger, long press = 2x */
let lastTap = 0, pressT = null, pressed = false;
const tap = $('#tap');
tap.addEventListener('pointerdown', () => { pressed = false; pressT = setTimeout(() => { if (ready && playing){ pressed = true; player.setPlaybackRate(2); $('#fast').classList.add('on'); } }, 380); });
const endPress = () => { clearTimeout(pressT); if (pressed){ player.setPlaybackRate(rate); $('#fast').classList.remove('on'); } };
tap.addEventListener('pointerup', endPress); tap.addEventListener('pointercancel', endPress); tap.addEventListener('pointerleave', endPress);
tap.addEventListener('click', e => {
  if (pressed){ pressed = false; return; }
  const now = Date.now();
  if (now - lastTap < 300){ like(cur, e.clientX, e.clientY); lastTap = 0; return; }
  lastTap = now;
  if (!soundOn && ready){ unmute(); $('#cover').classList.remove('on'); lastTap = 0; return; }
  setTimeout(() => { if (lastTap === now) toggle(); }, 300);
});

/* desktop: wheel / trackpad and keyboard */
// One swipe = one moment. A trackpad keeps sending momentum events for a second or more after the fingers lift, so
// after a step every further wheel event extends the lock: the next step needs a short pause in scrolling.
let wheelAcc = 0, wheelLock = 0, wheelReset;
$('#app').addEventListener('wheel', e => {
  if (e.target.closest('.sheet,.topics')) return;
  e.preventDefault();
  const now = Date.now(); if (now < wheelLock){ wheelLock = Math.max(wheelLock, now + 180); return; }
  wheelAcc += e.deltaY;
  if (Math.abs(wheelAcc) > 40){ wheelAcc > 0 ? next() : prev(); wheelAcc = 0; wheelLock = now + 650; }
  clearTimeout(wheelReset); wheelReset = setTimeout(() => wheelAcc = 0, 200);
}, {passive: false});
addEventListener('keydown', e => {
  if (e.target.matches('textarea,input') || $('#gate')) return;
  const k = e.key.toLowerCase();
  if (['arrowdown', 'j', 'pagedown'].includes(k)){ e.preventDefault(); next(); }
  else if (['arrowup', 'k', 'pageup'].includes(k)){ e.preventDefault(); prev(); }
  else if (k === ' '){ e.preventDefault(); toggle(); }
  else if (k === 'l') like(cur);
  else if (k === 'm' && ready){ if (soundOn && !player.isMuted()){ player.mute(); soundOn = false; localStorage.laternowSound = '0'; $('#snd').classList.remove('off'); } else unmute(); }
  else if (k === 'f' && items[cur]) openFull(cur);
  else if (k === 'a'){ e.preventDefault(); openAdd(); }
  else if (k === 'escape') closeSheets();
});

/* ---------- header: topics, status ---------- */
function renderTopics(){
  const t = lastStatus?.topics || [];
  $('#topics').innerHTML = [`<button data-t="" class="${mode.topic ? '' : 'on'}">All</button>`]
    .concat(t.slice(0, 14).map(x => `<button data-t="${esc(x.topic)}" class="${mode.topic === x.topic ? 'on' : ''}">${esc(x.topic)}</button>`)).join('');
  $$('#topics button').forEach(b => b.onclick = () => { mode.topic = b.dataset.t; renderTopics(); reload(); });
}
let statusT;
async function poll(){
  clearTimeout(statusT);
  try {
    const s = await api('status'); const firstReady = !lastStatus?.moments && s.moments; lastStatus = s;
    if (!$('#topics').children.length || $('#topics').children.length - 1 !== Math.min(14, s.topics.length)) renderTopics();
    $('#busyDot').classList.toggle('on', !!s.busy);
    if (firstReady && !items.length && !$('#gate')) reload();
    if ($('#libSheet').classList.contains('open')) renderLib();
    statusT = setTimeout(poll, s.busy ? 4000 : 20000);
  } catch { statusT = setTimeout(poll, 20000); }
}
async function loadSettings(){
  try { settings = await api('settings'); } catch { settings = null; }
  return settings;
}
// "in 3 min", "at 9:30 AM", "tomorrow 12:00 AM"
function when(ts){
  const d = new Date(ts * 1000), mins = Math.round((d - Date.now()) / 60000);
  if (mins < 1) return 'in a moment';
  if (mins < 60) return `in ${mins} min`;
  const t = d.toLocaleTimeString([], {hour: 'numeric', minute: '2-digit'});
  return d.toDateString() === new Date().toDateString() ? `at ${t}` : `tomorrow ${t}`;
}
const AI_NAME = {gemini: 'Gemini', anthropic: 'Claude API', openai: 'OpenAI-compatible API', ollama: 'Ollama', claude: 'Claude Code', hermes: 'Hermes Agent', none: 'Off', 'workers-ai': 'Workers AI'};
async function renderLib(){
  const s = lastStatus; if (!s) return;
  const c = s.counts || {};
  $('#stats').innerHTML = [[`${s.moments ? Math.round((s.done || 0) / s.moments * 100) : 0}%`, 'watched'], [s.moments, 'moments'], [c.ready || 0, 'videos']]
    .map(([n, l]) => `<div class="stat"><b>${n}</b><span>${l}</span></div>`).join('');
  const ai = s.ai || settings?.provider;
  const isGem = ai === 'gemini';
  const q = s.quota, model = (s.model || settings?.model || '').replace(/^models\//, '');
  const quotaTxt = !q ? '' : q.resumes_at ? ` · free quota used up, back ${when(q.resumes_at)}` : q.used_today ? ` · ${q.used_today} requests today` : '';
  $('#aiRow').innerHTML = `<span>AI</span><span class="v">${esc(AI_NAME[ai] || ai || '')}${isGem ? (s.ai_ready ? `${model && model !== 'auto' ? ` · ${esc(model)}` : ''}${quotaTxt}` : ' · not connected') : ''}</span>${isGem ? `<button class="link">${s.ai_ready ? 'Change key' : 'Connect'}</button>` : ''}`;
  $('#aiRow').querySelector('button')?.addEventListener('click', openAI);
  $('#taste').innerHTML = s.topics.length ? s.topics.slice(0, 8).map(r => `<div class="bar"><span>${esc(r.topic)}</span><div class="tr"><i style="width:${Math.round(r.score * 100)}%"></i></div><small>${r.n}</small></div>`).join('')
    : '<p class="sub">Watch a few moments and this fills in.</p>';
  const v = await api('videos').catch(() => []);
  const lab = x => x.status === 'ready' ? `${x.moments} moments${!x.error ? '' : x.error.startsWith('No captions') ? ' · no captions' : ' · plain chunks'}`
    : x.status === 'failed' ? esc(x.error || 'Failed')
    : x.status === 'waiting' ? esc((x.error || 'Waiting').replace(/\. (Continues|Retrying) automatically\.?$/, '')) + (x.retry_at ? `, continues ${when(x.retry_at)}` : '')
    : x.status === 'needs_key' ? 'Waiting for your Gemini key'
    : x.status === 'queued' ? 'Queued' : esc(x.status[0].toUpperCase() + x.status.slice(1)) + '…';
  const cls = x => ['ready', 'failed', 'waiting'].includes(x.status) ? x.status : x.status === 'needs_key' ? 'waiting' : x.status === 'queued' ? '' : 'busy';
  $('#vids').innerHTML = v.map(x => `<div class="vid"><img loading="lazy" src="${thumb(x.id, 'default')}" alt=""><div class="vt"><div class="t">${esc(x.title)}</div>
    <div class="st"><span class="dot ${cls(x)}"></span>${lab(x)}</div></div></div>`).join('') || '<p class="sub">No videos yet.</p>';
}
function upNext(){
  const el = $('#upnext'); if (!el || getComputedStyle($('#panelL')).display === 'none') return;
  el.innerHTML = items.map((m, j) => [m, j]).slice(cur + 1).filter(([m]) => !m.kind).slice(0, 5).map(([m, j]) => `<div class="upnext" data-i="${j}"><img src="${thumb(m.vid, 'mqdefault')}" alt=""><div>${esc(m.title)}</div></div>`).join('') || '<div class="muted">Nothing queued</div>';
  $$('.upnext').forEach(u => u.onclick = () => go(+u.dataset.i));
}

/* ---------- sheets ---------- */
function openSheet(id){ closeSheets(); $('#scrim').classList.add('on'); $(id).classList.add('open'); }
function closeSheets(){ $('#scrim').classList.remove('on'); $$('.sheet').forEach(s => s.classList.remove('open')); }
$('#scrim').onclick = closeSheets;

function openAdd(){
  if (needsKey()) return openAI();
  const q = [];
  const vid = SRC.match(YT_RE)?.[1];
  if (vid) q.push(`<button class="qbtn" data-u="https://www.youtube.com/watch?v=${vid}">Add this video</button>`);
  if (IS_EXT) q.push(`<button class="qbtn" data-wl>Import Watch Later</button>`);
  $('#quick').innerHTML = q.join('');
  $$('#quick [data-u]').forEach(b => b.onclick = () => addUrls(b.dataset.u, b));
  $$('#quick [data-wl]').forEach(b => b.onclick = () => importWatchLater(b));
  openSheet('#addSheet');
  if (matchMedia('(hover:hover)').matches) setTimeout(() => $('#urls').focus(), 300);
}
function openAI(){
  const s = settings || {};
  $('#aiKey').value = ''; $('#aiErr').textContent = '';
  $('#aiKey').placeholder = s.key_set ? `Current key ${s.key_hint || ''}`.trim() : 'Gemini API key';
  $('#aiGo').textContent = s.key_set ? 'Replace key' : 'Connect';
  $('#aiRemove').style.display = s.key_set ? '' : 'none';
  $('#aiWhere').textContent = IS_EXT ? 'Your key is stored only in this browser and sent only to Google.' : 'Your key is stored on your Later Now server and sent only to Google.';
  openSheet('#aiSheet');
  if (matchMedia('(hover:hover)').matches) setTimeout(() => $('#aiKey').focus(), 300);
}
async function saveKey(key){
  const b = $('#aiGo'), t = b.textContent; b.disabled = true; b.textContent = key ? 'Checking…' : 'Removing…'; $('#aiErr').textContent = '';
  try {
    await api('settings', {gemini_key: key});
    await loadSettings(); poll();
    closeSheets(); toast(key ? 'Gemini connected' : 'Key removed');
    if (key && !items.length) setTimeout(openAdd, 350);
  } catch (e){ $('#aiErr').textContent = e.message || 'Something went wrong.'; }
  b.disabled = false; b.textContent = t;
}
$('#aiGo').onclick = () => { const k = $('#aiKey').value.trim(); if (k) saveKey(k); else $('#aiErr').textContent = 'Paste your key first.'; };
$('#aiKey').addEventListener('keydown', e => { if (e.key === 'Enter') $('#aiGo').click(); });
$('#aiRemove').onclick = () => saveKey('');

$('#addBtn').onclick = openAdd;
$('#libBtn').onclick = () => { openSheet('#libSheet'); renderLib(); };
$('#retry').onclick = async () => { try { const r = await api('retry', {}); toast(r.requeued ? `Retrying ${r.requeued}` : 'Nothing to retry'); poll(); renderLib(); } catch {} };
function added(r){
  toast(r.found ? `Added ${r.new} video${r.new === 1 ? '' : 's'}${r.found - r.new ? `, ${r.found - r.new} already in` : ''}` : (r.notes?.[0] || 'No YouTube links found'));
  if (r.new){ $('#urls').value = ''; openSheet('#libSheet'); poll(); renderLib(); }
}
async function addUrls(v, btn){
  v = (v || '').trim(); if (!v) return;
  const t = btn.textContent; btn.textContent = 'Adding…'; btn.disabled = true;
  try { added(await api('add', {urls: v})); } catch (e){ toast(e.message); }
  btn.textContent = t; btn.disabled = false;
}
async function importWatchLater(btn){
  const t = btn.textContent; btn.textContent = 'Reading Watch Later…'; btn.disabled = true;
  try { added(await api('watchlater', {})); } catch (e){ toast(e.message); }
  btn.textContent = t; btn.disabled = false;
}
$('#addGo').onclick = () => addUrls($('#urls').value, $('#addGo'));
$('#keyGo').onclick = () => { K = $('#keyIn').value.trim(); localStorage.laternowKey = K; closeSheets(); loadSettings(); poll(); reload(); };

let rsT; addEventListener('resize', () => { clearTimeout(rsT); rsT = setTimeout(() => { if (cur >= 0) sc.scrollTo({top: cur * sc.clientHeight}); upNext(); }, 120); });
addEventListener('pagehide', () => report());
// The floating player and the Later Now window are one player for every tab: nothing to pause or hand off when hidden.
const FLOAT = new URLSearchParams(location.search).has('float') || new URLSearchParams(location.search).has('win');
// In the Later Now window, the pin button moves the player into an always-on-top window (float.html does the work).
const pinHost = (() => { try { return new URLSearchParams(location.search).has('win') && typeof parent.momentsPin === 'function' && 'documentPictureInPicture' in parent ? parent : null; } catch { return null; } })();
if (pinHost){
  $('#pinBtn').hidden = false;
  $('#pinBtn').onclick = async () => {
    if (ready) player.pauseVideo();
    if (items[cur] && !items[cur].kind) api('progress', {moment: items[cur].id, t: player.getCurrentTime()}).catch(() => {});   // the pinned player resumes here
    if (!(await pinHost.momentsPin())){ if (ready) player.playVideo(); toast("Couldn't keep Later Now on top"); }
  };
}
document.addEventListener('visibilitychange', async () => {
  if (FLOAT) return;   // floating window: one player for every tab, nothing to hand off
  const m = items[cur];
  if (document.hidden){
    if (ready) player.pauseVideo();
    if (IS_EXT && m && !m.kind) api('progress', {moment: m.id, t: player.getCurrentTime()}).catch(() => {});
    return;
  }
  // Extension: you may have kept watching in another tab. Pick up exactly where that left off.
  if (!IS_EXT || $('#gate') || !ready) return;
  let p; try { p = await api('progress'); } catch { return; }
  if (!p?.moment) return;
  if (m && m.id === p.moment){
    if (Math.abs(player.getCurrentTime() - (p.t || 0)) > 1.5 && p.t > m.start && p.t < m.end) player.seekTo(p.t, true);
    if (!$('#libSheet').classList.contains('open')) player.playVideo();
  } else reload();
});

async function startApp(){
  $('#gate')?.remove(); localStorage.laternowStarted = '1';
  await loadSettings(); poll(); await more();
  if (!items.length && needsKey()) openAI();
  let tries = 0;
  const start = () => { if (ready && items.length) activate(0); else if (items.length && ++tries < 80) setTimeout(start, 150); else if (items.length){ dlog('noplayer'); toast("YouTube player didn't load. Check content blockers."); } };
  start();
}
$('#go').onclick = startApp;
if (localStorage.laternowStarted || localStorage.momentsStarted) startApp();   // the welcome screen is only for the first visit
