/* The Later Now window: opened by the toolbar button, it shows the feed straight away. The pin button in the feed
 * (a click inside this window, which Chrome requires) moves the player into an always-on-top Document
 * Picture-in-Picture window; this window then minimizes. Closing the floating player brings the feed back here,
 * closing this window closes everything. */
const RATIO = 9 / 19.5;
const APP = chrome.runtime.getURL('app/index.html');
let frame = null, pip = null;

function addFrame(doc, query) {
  const f = doc.createElement('iframe');
  f.src = APP + query;
  f.allow = 'autoplay; encrypted-media; clipboard-write';
  f.title = 'Later Now';
  Object.assign(f.style, { display: 'block', width: '100%', height: '100%', border: '0', background: '#000' });
  doc.body.appendChild(f);
  return f;
}
const showHere = () => { document.body.classList.remove('pinned'); frame ||= addFrame(document, '?win=1'); };

/* Called by the feed's pin button (same origin, so the click's user activation reaches this window). */
window.momentsPin = async () => {
  if (pip) return pip.focus?.();
  const h = Math.min(860, Math.max(420, innerHeight));
  try { pip = await documentPictureInPicture.requestWindow({ width: Math.round(h * RATIO), height: h }); }
  catch (e) { console.warn('Later Now: pin failed', e); return false; }
  const d = pip.document;
  d.title = 'Later Now';
  Object.assign(d.documentElement.style, { height: '100%', background: '#000' });
  Object.assign(d.body.style, { margin: '0', height: '100%', overflow: 'hidden', background: '#000' });
  frame?.remove(); frame = null;   // one player at a time
  document.body.classList.add('pinned');
  addFrame(d, '?float=1');
  chrome.runtime.sendMessage({ type: 'laternow-pinned', on: true });
  pip.addEventListener('pagehide', async () => {
    pip = null; showHere();
    chrome.runtime.sendMessage({ type: 'laternow-pinned', on: false });
    const w = await chrome.windows.getCurrent();
    chrome.windows.update(w.id, { state: 'normal', focused: true }).catch(() => {});
  });
  const w = await chrome.windows.getCurrent();
  chrome.windows.update(w.id, { state: 'minimized' }).catch(() => {});
  return true;
};

showHere();
