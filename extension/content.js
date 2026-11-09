/* Later Now overlay: a floating, phone-shaped window (like macOS iPhone Mirroring) that hosts the feed UI.
 * Lives in a closed Shadow DOM so page CSS can't touch it, and is removed entirely when closed. */
(() => {
  if (window.top !== window) return;
  // Already running here? (After an extension update the old copy is orphaned: its runtime is gone.)
  const alive = f => { try { return !!f?.(); } catch { return false; } };
  if (alive(window.__momentsOverlay)) return;
  document.querySelectorAll('laternow-overlay').forEach(n => n.remove());
  window.__momentsOverlay = () => chrome.runtime?.id;
  chrome.runtime.onMessage.addListener((m, _s, reply) => {
    if (m?.type === 'laternow-ping') reply(true);
  });

  const RATIO = 9 / 19.5, BAR = 30, GAP = 8, MARGIN = 12, MIN_H = 380, HIDE_AFTER = 60000;
  const APP = chrome.runtime.getURL('app/index.html');
  const CSS = `
:host{all:initial!important;position:fixed!important;inset:0 auto auto 0!important;width:0!important;height:0!important;
  z-index:2147483647!important;display:block!important;contain:style!important}
*{box-sizing:border-box}
.win{position:fixed;left:0;top:0;opacity:0;transform:scale(.97);transform-origin:50% 60%;
  transition:opacity .18s ease,transform .18s cubic-bezier(.2,.8,.2,1);
  font:12px/1 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",system-ui,sans-serif;-webkit-font-smoothing:antialiased}
.win.on{opacity:1;transform:none}
.screen{position:absolute;inset:0;border-radius:var(--r);background:#000;overflow:hidden;
  box-shadow:0 0 0 2.5px #0c0c0d,0 0 0 3px rgba(255,255,255,.14),0 12px 28px rgba(0,0,0,.22),0 28px 80px rgba(0,0,0,.38)}
.screen iframe{display:block;width:100%;height:100%;border:0;background:#000;color-scheme:normal}
.screen .ph{position:absolute;inset:0;display:grid;place-items:center;color:#6e6e73;font-size:12px;letter-spacing:.01em}
.bar{position:absolute;left:0;right:0;bottom:calc(100% + ${GAP}px);height:${BAR}px;display:flex;align-items:center;justify-content:flex-end;gap:2px;
  padding:0 5px;border-radius:10px;color:rgba(0,0,0,.72);background:rgba(246,246,248,.78);
  -webkit-backdrop-filter:blur(24px) saturate(1.8);backdrop-filter:blur(24px) saturate(1.8);
  box-shadow:0 0 0 .5px rgba(0,0,0,.14),0 1px 0 rgba(255,255,255,.6) inset,0 6px 18px rgba(0,0,0,.12);
  opacity:0;transform:translateY(4px);transition:opacity .16s ease,transform .16s ease;cursor:grab;touch-action:none;user-select:none}
.win:hover .bar,.win.drag .bar,.win.resize .bar,.bar:focus-within{opacity:1;transform:none}
.win.drag .bar{cursor:grabbing}
.bar button{all:unset;width:24px;height:22px;display:grid;place-items:center;border-radius:6px;color:inherit;cursor:default;transition:background .15s ease,color .15s ease}
.bar button:hover{background:rgba(0,0,0,.07);color:#000}
.bar button:active{background:rgba(0,0,0,.12)}
.bar button:focus-visible{outline:1.5px solid rgba(0,0,0,.4);outline-offset:-1.5px}
@media (prefers-color-scheme:dark){
  .bar{color:rgba(255,255,255,.8);background:rgba(40,40,42,.72);box-shadow:0 0 0 .5px rgba(0,0,0,.5),0 0 0 .5px rgba(255,255,255,.1) inset,0 6px 18px rgba(0,0,0,.3)}
  .bar button:hover{background:rgba(255,255,255,.1);color:#fff}
  .bar button:active{background:rgba(255,255,255,.18)}
  .bar button:focus-visible{outline-color:rgba(255,255,255,.6)}
}
.bar svg{width:15px;height:15px;fill:none;stroke:currentColor;stroke-width:1.5;stroke-linecap:round;stroke-linejoin:round}
.grip{position:absolute;right:-6px;bottom:-6px;width:26px;height:26px;cursor:nwse-resize;touch-action:none}
.win.drag iframe,.win.resize iframe{pointer-events:none}
@media (prefers-reduced-motion:reduce){.win,.bar{transition:none}}`;
  // Icons as path data; DOM is built without innerHTML so Trusted Types pages can't block it.
  const ICON = { float: 'M4.5 5.5h15a1 1 0 0 1 1 1v11a1 1 0 0 1-1 1h-15a1 1 0 0 1-1-1v-11a1 1 0 0 1 1-1zM12 11.5h5.5v4.5H12z', home: 'M4.5 10.5 12 4.5l7.5 6V19a.5.5 0 0 1-.5.5h-4.25v-5.25h-5.5v5.25H5a.5.5 0 0 1-.5-.5z', close: 'M6.5 6.5l11 11M17.5 6.5l-11 11' };
  const el = (tag, cls, attrs = {}) => { const e = document.createElement(tag); if (cls) e.className = cls; for (const k in attrs) e.setAttribute(k, attrs[k]); return e; };
  function iconButton(name, label) {
    const b = el('button', name, { title: label, 'aria-label': label.replace(/ \(.*/, '') });
    const NS = 'http://www.w3.org/2000/svg', svg = document.createElementNS(NS, 'svg'), path = document.createElementNS(NS, 'path');
    svg.setAttribute('viewBox', '0 0 24 24'); path.setAttribute('d', ICON[name]); svg.appendChild(path); b.appendChild(svg);
    return b;
  }

  let host = null, win = null, screen = null, frame = null, geom = null, open = false, floating = false, hideT = null;

  /* ---------- geometry ---------- */
  const vw = () => document.documentElement.clientWidth || innerWidth, vh = () => innerHeight;
  function fit(g) {
    const maxH = Math.max(200, vh() - 2 * MARGIN - BAR - GAP);
    let h = Math.min(Math.max(g?.h || Math.min(760, vh() * 0.86), Math.min(MIN_H, maxH)), maxH), w = h * RATIO;
    let x = g?.x ?? vw() - w - 32, y = g?.y ?? (vh() - h) / 2 + (BAR + GAP) / 2;
    x = Math.min(Math.max(MARGIN, x), Math.max(MARGIN, vw() - w - MARGIN));
    y = Math.min(Math.max(MARGIN + BAR + GAP, y), Math.max(MARGIN + BAR + GAP, vh() - h - MARGIN));
    return { x: Math.round(x), y: Math.round(y), h: Math.round(h) };
  }
  function place(g) {
    geom = fit(g);
    const w = geom.h * RATIO;
    Object.assign(win.style, { left: geom.x + 'px', top: geom.y + 'px', width: w + 'px', height: geom.h + 'px' });
    win.style.setProperty('--r', Math.round(w * 0.13) + 'px');
  }
  const persist = () => chrome.storage.local.set({ overlay_geom: { x: geom.x, y: geom.y, h: geom.h } });

  /* ---------- iframe lifecycle ---------- */
  function addFrame() {
    if (frame || !screen || document.hidden) return;
    screen.querySelector('.ph')?.remove();
    frame = document.createElement('iframe');
    frame.src = APP + '?src=' + encodeURIComponent(location.href);
    frame.allow = 'autoplay; encrypted-media; clipboard-write';
    frame.title = 'Later Now';
    screen.appendChild(frame);
  }
  function dropFrame() { frame?.remove(); frame = null; }

  /* ---------- window ---------- */
  function build() {
    host = document.createElement('laternow-overlay');
    const root = host.attachShadow({ mode: 'closed' });
    const sheet = new CSSStyleSheet(); sheet.replaceSync(CSS);   // constructable sheet: not blocked by page CSP
    root.adoptedStyleSheets = [sheet];
    win = el('div', 'win');
    const bar = el('div', 'bar'), home = iconButton('home', 'Home'), close = iconButton('close', 'Close (Alt+Shift+M)');
    const fl = iconButton('float', 'Open in its own window'); bar.append(fl); fl.addEventListener('click', floatOut);
    bar.append(home, close);
    screen = el('div', 'screen');
    const ph = el('div', 'ph'); ph.textContent = 'Later Now'; screen.appendChild(ph);
    const grip = el('div', 'grip', { title: 'Resize' });
    win.append(bar, screen, grip);
    root.appendChild(win);
    home.addEventListener('click', () => { dropFrame(); addFrame(); });
    close.addEventListener('click', () => chrome.storage.local.set({ overlay_open: false }));
    bar.addEventListener('pointerdown', e => {
      if (e.button !== 0 || e.target.closest('button')) return;
      drag(e, bar, 'drag', (dx, dy, g) => place({ ...g, x: g.x + dx, y: g.y + dy }));
    });
    grip.addEventListener('pointerdown', e => {
      if (e.button !== 0) return;
      // Keep the aspect ratio: follow whichever axis moved further (in height units).
      drag(e, grip, 'resize', (dx, dy, g) => place({ ...g, h: g.h + (Math.abs(dx / RATIO) > Math.abs(dy) ? dx / RATIO : dy) }));
    });
    document.documentElement.appendChild(host);
  }
  function drag(e, el, cls, move) {
    e.preventDefault();
    const start = { ...geom }, x0 = e.clientX, y0 = e.clientY;
    el.setPointerCapture(e.pointerId); win.classList.add(cls);
    const mv = ev => move(ev.clientX - x0, ev.clientY - y0, start);
    const up = () => { el.removeEventListener('pointermove', mv); el.removeEventListener('pointerup', up); el.removeEventListener('pointercancel', up); win.classList.remove(cls); persist(); };
    el.addEventListener('pointermove', mv); el.addEventListener('pointerup', up); el.addEventListener('pointercancel', up);
  }

  function show(g) {
    if (!host) build();
    place(g);
    addFrame();
    requestAnimationFrame(() => requestAnimationFrame(() => win?.classList.add('on')));
  }
  function hide() {
    if (!host) return;
    const h = host; win.classList.remove('on'); dropFrame();
    host = win = screen = null;
    setTimeout(() => h.remove(), 200);
  }

  function apply(isOpen, g) {
    open = !!isOpen;
    if (open && !floating) show(g ?? geom); else hide();
  }

  /* ---------- move to the Later Now window (float.html), which can also pin the player on top of every app ---------- */
  function floatOut() {
    chrome.runtime.sendMessage({ type: 'laternow-float', h: geom?.h || 760 }).catch(() => {});
  }

  chrome.storage.local.get(['overlay_open', 'overlay_geom', 'overlay_float']).then(d => { geom = d.overlay_geom || null; floating = !!d.overlay_float; apply(d.overlay_open, geom); });
  chrome.storage.onChanged.addListener((ch, area) => {
    if (area !== 'local') return;
    if (ch.overlay_geom && host && !win.classList.contains('drag') && !win.classList.contains('resize')) place(ch.overlay_geom.newValue);
    else if (ch.overlay_geom) geom = ch.overlay_geom.newValue || geom;
    if (ch.overlay_float) floating = !!ch.overlay_float.newValue;
    if (ch.overlay_open || ch.overlay_float) chrome.storage.local.get('overlay_open').then(d => apply(d.overlay_open, geom));
  });

  // Free the player when the tab has been in the background for a while; the UI resumes where it was.
  document.addEventListener('visibilitychange', () => {
    clearTimeout(hideT);
    if (document.hidden) hideT = setTimeout(dropFrame, HIDE_AFTER);
    else if (open && host) addFrame();
  });
  let rsT; addEventListener('resize', () => { clearTimeout(rsT); rsT = setTimeout(() => { if (host) place(geom); }, 100); });
})();
