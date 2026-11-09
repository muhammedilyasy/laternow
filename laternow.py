#!/usr/bin/env python3
"""Later Now: the self-hostable server. Turns long YouTube videos into a vertical feed of 25-90s moments.

A port of the Chrome extension's service worker (extension/background.js + src/ai.js): same API, same feed
scoring, same queue states, same Gemini free-tier model pool. Storage is SQLite; the UI is web/.

  pip install -r requirements.txt
  LATERNOW_KEY=secret python3 laternow.py        # then open http://127.0.0.1:8080/#k=secret

Env: LATERNOW_KEY, GEMINI_API_KEY, HOST (127.0.0.1), PORT (8080), LATERNOW_DB (laternow.db next to this file),
     CAPTION_PROXY (http(s) proxy URL), CAPTION_ROUTE (direct|proxy|auto), CAPTION_GAP (seconds, default 3).
"""
import contextlib
import datetime
import hmac
import json
import math
import os
import random
import re
import sqlite3
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, unquote, urlsplit
from zoneinfo import ZoneInfo

import requests
from youtube_transcript_api import (AgeRestricted, FailedToCreateConsentCookie, InvalidVideoId, NoTranscriptFound,
                                    PoTokenRequired, RequestBlocked, TranscriptsDisabled, VideoUnavailable,
                                    VideoUnplayable, YouTubeDataUnparsable, YouTubeRequestFailed,
                                    YouTubeTranscriptApi, YouTubeTranscriptApiException)
from youtube_transcript_api.proxies import GenericProxyConfig

HERE = os.path.dirname(os.path.abspath(__file__))
WEB = os.path.realpath(os.path.join(HERE, 'web'))
LATERNOW_KEY = os.environ.get('LATERNOW_KEY', '')
ENV_GEMINI_KEY = os.environ.get('GEMINI_API_KEY', '').strip()
HOST = os.environ.get('HOST', '127.0.0.1')
PORT = int(os.environ.get('PORT', '8080'))
DB_PATH = os.environ.get('LATERNOW_DB') or os.path.join(HERE, 'laternow.db')
CAPTION_PROXY = os.environ.get('CAPTION_PROXY', '').strip()
CAPTION_ROUTE = (os.environ.get('CAPTION_ROUTE') or ('proxy' if CAPTION_PROXY else 'direct')).strip().lower()
YT_GAP = float(os.environ.get('CAPTION_GAP', '3'))   # seconds between caption fetches

now = time.time
BUSY = ('fetching captions', 'finding moments')
LEASE = 90          # seconds; in-progress items whose lease is older are recovered
UA = ('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/131.0.0.0 Safari/537.36')


def is_busy(s): return s not in ('ready', 'failed', 'needs_key')   # queued, waiting or in progress
def log(*a): print(time.strftime('%H:%M:%S'), *a, file=sys.stderr, flush=True)


# ---------------- JS number semantics (the API takes loosely typed JSON, like the extension) ----------------
_NUM_RE = re.compile(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$')
_FLOAT_RE = re.compile(r'^\s*([+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?)')


def js_num(v):      # unary +
    if isinstance(v, (bool, int, float)): return float(v)
    if isinstance(v, str):
        s = v.strip()
        return 0.0 if not s else float(s) if _NUM_RE.match(s) else math.nan
    return math.nan


def js_float(v):    # parseFloat
    if isinstance(v, bool): return math.nan
    if isinstance(v, (int, float)): return float(v)
    m = _FLOAT_RE.match(str(v)) if v is not None else None
    return float(m.group(1)) if m else math.nan


def js_int(v):      # parseInt -> int or None (NaN)
    if isinstance(v, bool) or v is None: return None
    m = re.match(r'\s*([+-]?\d+)', str(int(v)) if isinstance(v, float) and math.isfinite(v) else str(v))
    return int(m.group(1)) if m else None


def num_or(v, d):   # `+v || d`
    x = js_num(v)
    return x if x and not math.isnan(x) else d


def finite(x): return isinstance(x, (int, float)) and math.isfinite(x)
def js_round(x): return math.floor(x + 0.5)


# ---------------- storage ----------------
SCHEMA = '''
CREATE TABLE IF NOT EXISTS videos (
  id TEXT PRIMARY KEY, title TEXT NOT NULL, channel TEXT NOT NULL DEFAULT '', status TEXT NOT NULL, error TEXT,
  added REAL NOT NULL, retry_at REAL NOT NULL DEFAULT 0, tries INTEGER NOT NULL DEFAULT 0, lease REAL NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS videos_status ON videos(status);
CREATE TABLE IF NOT EXISTS moments (
  id INTEGER PRIMARY KEY AUTOINCREMENT, vid TEXT NOT NULL, start REAL NOT NULL, "end" REAL NOT NULL,
  title TEXT NOT NULL, topic TEXT NOT NULL, hook REAL NOT NULL);
CREATE INDEX IF NOT EXISTS moments_vid ON moments(vid);
CREATE TABLE IF NOT EXISTS transcripts (vid TEXT PRIMARY KEY, lines TEXT NOT NULL);   -- JSON [[start, dur, text], ...]
CREATE TABLE IF NOT EXISTS prefs (topic TEXT PRIMARY KEY, score REAL NOT NULL, n INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS hist (moment INTEGER PRIMARY KEY, done INTEGER NOT NULL, last REAL NOT NULL, skips INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS saved (moment INTEGER PRIMARY KEY, at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);   -- settings, progress, gemini
'''
MOMENT_COLS = 'id, vid, start, "end", title, topic, hook'


class DB:
    """One connection shared by all threads, serialized by a lock. Every statement is short."""
    def __init__(self, path):
        self.conn = sqlite3.connect(path, check_same_thread=False, isolation_level=None, timeout=30)
        self.conn.row_factory = sqlite3.Row
        self.lock = threading.RLock()
        self.conn.execute('PRAGMA journal_mode=WAL')
        self.conn.executescript(SCHEMA)

    def q(self, sql, args=()):
        with self.lock: return [dict(r) for r in self.conn.execute(sql, args).fetchall()]

    def one(self, sql, args=()):
        r = self.q(sql, args)
        return r[0] if r else None

    def x(self, sql, args=()):
        with self.lock: return self.conn.execute(sql, args)

    @contextlib.contextmanager
    def tx(self):
        with self.lock:
            self.conn.execute('BEGIN IMMEDIATE')
            try: yield self
            except BaseException: self.conn.execute('ROLLBACK'); raise
            else: self.conn.execute('COMMIT')

    def get(self, key, default=None):
        r = self.one('SELECT value FROM kv WHERE key=?', (key,))
        return json.loads(r['value']) if r else default

    def put(self, key, value):
        if value is None: self.x('DELETE FROM kv WHERE key=?', (key,))
        else: self.x('INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)', (key, json.dumps(value)))


db: DB = None


def settings(): return db.get('settings', {})
def gemini_key(): return settings().get('gemini_key') or ENV_GEMINI_KEY


def get_lines(vids):
    out = {v: None for v in vids}
    for r in db.q(f'SELECT vid, lines FROM transcripts WHERE vid IN ({",".join("?" * len(vids))})', vids):
        out[r['vid']] = json.loads(r['lines'])
    return out


# ---------------- YouTube ----------------
YT_RE = re.compile(r'(?:v=|youtu\.be/|shorts/|embed/|live/)([A-Za-z0-9_-]{11})')
PL_RE = re.compile(r'[?&]list=([A-Za-z0-9_-]+)')
ID_RE = re.compile(r'^[A-Za-z0-9_-]{11}$')
LANGS = ['en', 'en-US', 'en-GB']


class YTError(Exception):
    """code: 'RATE_LIMIT', 'NO_CAPTIONS', 'NETWORK', 'HTTP', 'FATAL'."""
    def __init__(self, code, msg=''):
        super().__init__(msg or code)
        self.code = code


def yt_session():
    s = requests.Session()
    s.headers.update({'User-Agent': UA, 'Accept-Language': 'en-US,en;q=0.9'})
    s.cookies.set('SOCS', 'CAI', domain='.youtube.com')   # skip the EU consent redirect
    return s


def yt_get(s, url, **kw):
    try: r = s.request(kw.pop('method', 'GET'), url, timeout=30, **kw)
    except requests.RequestException as e: raise YTError('NETWORK', f"Couldn't reach YouTube ({type(e).__name__})")
    if r.status_code == 429: raise YTError('RATE_LIMIT', 'YouTube is rate-limiting this server. Retrying automatically.')
    return r


def meta(vid):
    try:
        r = requests.get('https://www.youtube.com/oembed', timeout=15,
                         params={'format': 'json', 'url': f'https://www.youtube.com/watch?v={vid}'})
        if r.ok:
            d = r.json()
            return d.get('title') or vid, d.get('author_name') or ''
    except (requests.RequestException, ValueError):
        pass
    return vid, ''


def pick_track(tracks):
    manual = [t for t in tracks if not t.is_generated]
    auto = [t for t in tracks if t.is_generated]
    is_en = lambda t: t.language_code in LANGS or re.match(r'^en\b', t.language_code or '', re.I)
    return next((t for t in manual if is_en(t)), None) or next((t for t in auto if is_en(t)), None) or (manual or auto)[0]


def _captions(vid, proxy):
    """youtube-transcript-api, with its errors mapped to the codes the queue understands. Error messages never
    include exception text from requests, which could contain the proxy URL and its credentials."""
    api = YouTubeTranscriptApi(proxy_config=GenericProxyConfig(http_url=proxy, https_url=proxy) if proxy else None)
    try:
        tracks = list(api.list(vid))
        if not tracks: raise YTError('NO_CAPTIONS', 'No captions on this video')
        fetched = pick_track(tracks).fetch()
    except (TranscriptsDisabled, NoTranscriptFound):
        raise YTError('NO_CAPTIONS', 'No captions on this video')
    except RequestBlocked:   # includes IpBlocked (HTTP 429, captcha) and "confirm you're not a bot"
        raise YTError('RATE_LIMIT', 'YouTube is blocking caption requests from this server. Retrying automatically.')
    except PoTokenRequired:
        raise YTError('FATAL', 'YouTube requires a PO token for these captions')
    except AgeRestricted:
        raise YTError('FATAL', 'Age-restricted video')
    except (VideoUnavailable, InvalidVideoId):
        raise YTError('FATAL', 'Video unavailable')
    except VideoUnplayable as e:
        raise YTError('FATAL', f"Video can't be played{': ' + e.reason if getattr(e, 'reason', None) else ''}"[:160])
    except FailedToCreateConsentCookie:
        raise YTError('FATAL', "Couldn't get past YouTube's cookie notice")
    except YouTubeDataUnparsable:
        raise YTError('FATAL', "Couldn't read the YouTube page")
    except YouTubeRequestFailed as e:
        m = re.match(r'(\d{3})', getattr(e, 'reason', '') or '')
        raise YTError('HTTP', f'YouTube returned {m.group(1) if m else "an error"}')
    except YouTubeTranscriptApiException as e:
        raise YTError('FATAL', f"Couldn't get captions ({type(e).__name__})")
    except requests.RequestException as e:
        raise YTError('NETWORK', f"Couldn't reach YouTube ({type(e).__name__})")
    except ValueError:   # malformed caption XML / JSON
        raise YTError('FATAL', "Couldn't read the captions")
    lines = []
    for sn in fetched:
        text = re.sub(r'\s+', ' ', sn.text or '').strip()
        if text and finite(sn.start): lines.append([sn.start, sn.duration if finite(sn.duration) else 0, text])
    if not lines: raise YTError('NO_CAPTIONS', 'No captions on this video')
    return lines


def transcript(vid):
    """CAPTION_ROUTE: direct, proxy (through CAPTION_PROXY) or auto (direct first, the proxy when YouTube blocks us)."""
    if CAPTION_ROUTE == 'proxy' and CAPTION_PROXY: return _captions(vid, CAPTION_PROXY)
    if CAPTION_ROUTE == 'auto' and CAPTION_PROXY:
        try: return _captions(vid, None)
        except YTError as e:
            if e.code != 'RATE_LIMIT': raise
            log(f'{vid}: captions blocked directly, trying the proxy')
            return _captions(vid, CAPTION_PROXY)
    return _captions(vid, None)


# playlists
def extract_json(html, marker):
    i = html.find(marker)
    if i < 0: return None
    j = html.find('{', i)
    if j < 0: return None
    depth, in_str, esc = 0, False, False
    for k in range(j, len(html)):
        c = html[k]
        if in_str:
            if esc: esc = False
            elif c == '\\': esc = True
            elif c == '"': in_str = False
            continue
        if c == '"': in_str = True
        elif c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                try: return json.loads(html[j:k + 1])
                except ValueError: return None
    return None


def cont_token(o):   # first continuationCommand.token inside o
    if isinstance(o, dict):
        t = (o.get('continuationCommand') or {}).get('token') if isinstance(o.get('continuationCommand'), dict) else None
        if isinstance(t, str): return t
        vals = o.values()
    elif isinstance(o, list): vals = o
    else: return None
    for v in vals:
        t = cont_token(v)
        if t: return t
    return None


def walk(o, ids, conts):
    """Collects video ids and continuation tokens: classic playlistVideoRenderer and the newer
    lockupViewModel / continuationItemViewModel layouts."""
    if isinstance(o, list):
        for x in o: walk(x, ids, conts)
        return
    if not isinstance(o, dict): return
    v = o.get('playlistVideoRenderer')
    if isinstance(v, dict) and v.get('videoId'):
        if v.get('isPlayable') is not False: ids.append(v['videoId'])
        return
    lk = o.get('lockupViewModel')
    if lk:
        if isinstance(lk, dict) and lk.get('contentType') == 'LOCKUP_CONTENT_TYPE_VIDEO' and ID_RE.match(lk.get('contentId') or ''):
            ids.append(lk['contentId'])
        return
    c = o.get('continuationItemRenderer') or o.get('continuationItemViewModel')
    if c:
        t = cont_token(c)
        if t: conts.append(t)
        return
    for x in o.values(): walk(x, ids, conts)


def playlist(list_id):
    """Returns (ids, notes). Follows continuations through youtubei/v1/browse."""
    if list_id in ('WL', 'LL'):
        return [], [('Watch Later' if list_id == 'WL' else 'Liked videos') + ' import needs the Chrome extension']
    s = yt_session()
    r = yt_get(s, f'https://www.youtube.com/playlist?list={quote(list_id)}')
    if not r.ok: return [], [f'Playlist failed: YouTube returned {r.status_code}']
    html = r.text
    if r.url.startswith('https://consent.') or 'action="https://consent.youtube.com/s"' in html:
        return [], ["Playlist failed: YouTube showed a cookie notice"]
    data = extract_json(html, 'ytInitialData')
    if not isinstance(data, dict): return [], ["Couldn't read that playlist"]
    ids, conts, notes = [], [], []
    walk(data.get('contents') or data, ids, conts)
    if not ids and not conts:
        m = re.search(r'"text":"([^"]+)"', json.dumps(data.get('alerts') or '', separators=(',', ':')))
        return [], [f'Playlist: {m.group(1)}' if m else 'That playlist is empty or private']
    key = re.search(r'"INNERTUBE_API_KEY":\s*"([a-zA-Z0-9_-]+)"', html)
    ver = re.search(r'"INNERTUBE_CLIENT_VERSION":\s*"([^"]+)"', html)
    ver = ver.group(1) if ver else '2.20250101.00.00'
    pages, stuck = 0, False
    while conts and key and pages < 60:
        tok = conts.pop(0); pages += 1
        try:
            c = yt_get(s, f'https://www.youtube.com/youtubei/v1/browse?key={key.group(1)}&prettyPrint=false', method='POST',
                       headers={'X-YouTube-Client-Name': '1', 'X-YouTube-Client-Version': ver},
                       json={'context': {'client': {'clientName': 'WEB', 'clientVersion': ver, 'hl': 'en'}}, 'continuation': tok})
            if not c.ok: stuck = True; break
            before = len(ids)
            walk(c.json(), ids, conts)
            if len(ids) == before: conts.clear(); break   # nothing more: end of the list
        except (YTError, ValueError):
            stuck = True; break
    # The header says how many videos there are; hidden/unavailable ones account for small differences.
    m = re.search(r'"text":"([\d,.]+)"\},\{"text":" videos?"', json.dumps(data.get('header') or {}, separators=(',', ':')))
    total = int(re.sub(r'[,.]', '', m.group(1)) or 0) if m else 0
    short = (len(ids) < total * 0.95 and total - len(ids) > 2) if total else (stuck or bool(conts))
    if short: notes.append(f"Imported the first {len(ids)}{f' of {total}' if total else ''} videos. YouTube didn't return the rest.")
    return list(dict.fromkeys(ids)), notes


def expand(text):
    ids, notes = [], []
    for u in [x for x in re.split(r'[\s,]+', str(text or '')) if x]:
        pl, m = PL_RE.search(u), YT_RE.search(u)
        if pl and not m:
            try:
                got, n = playlist(pl.group(1)); ids += got; notes += n
            except Exception as e:
                notes.append(f'Playlist failed: {e}')
        elif m: ids.append(m.group(1))
        elif ID_RE.match(u): ids.append(u)
    return list(dict.fromkeys(ids)), notes


# ---------------- Gemini (port of src/ai.js) ----------------
API = 'https://generativelanguage.googleapis.com/v1beta'


def fmt(s): return f'{int(s // 60)}:{int(s % 60):02d}'


class AIError(Exception):
    """code: 'RATE_LIMIT' (retry_at = epoch seconds when a model frees up), 'BAD_KEY', 'NETWORK', 'FAILED'."""
    def __init__(self, code, msg='', retry_at=0):
        super().__init__(msg or code)
        self.code, self.retry_at = code, retry_at


def norm_topic(t):
    t = re.split(r'[,/;&|]| and ', str(t or 'misc').lower())[0]
    t = re.sub(r'^[\s.\-_#]+|[\s.\-_#]+$', '', t)
    return t[:24] or 'misc'


def PROMPT(maxn, title, text, topics): return f'''You turn part of a long video transcript into a feed of short, self-contained "moments" for people with short attention spans.

Rules:
- Each moment is 25-90 seconds and must make sense on its own: it starts at the beginning of a thought and ends when the point is complete. Never cut mid-sentence.
- Pick only the most interesting, insightful, funny or useful parts. Skip intros, sponsor reads, small talk and outros. Up to {maxn} moments.
- title: a punchy hook of max 8 words that makes someone want to watch (honest, no clickbait lies).
- topic: ONE short lowercase topic (1-2 words, never a list), e.g. "startups", "fitness", "ai", "money", "mindset". Prefer these existing topics when they fit: {topics or 'none yet'}.
- hook: 1-10, how gripping this moment is for a general viewer.
- start/end are seconds, taken from the [m:ss] markers.

Video title: {title}

Transcript:
{text}

Answer with ONLY a JSON array, no prose, no code fences:
[{{"start": 12.5, "end": 70.0, "title": "...", "topic": "...", "hook": 7}}]'''


def VPROMPT(a, b, sa, sb, sa_ex, sb_ex, maxn, title, topics): return f'''You are watching part of a long video, from {a} to {b} (mm:ss). Turn it into short, self-contained "moments" for a feed for people with short attention spans.

Rules:
- Each moment is 25-90 seconds and must make sense on its own: it starts at the beginning of a thought and ends when the point is complete. Never cut mid-sentence.
- Pick only the most interesting, insightful, funny or useful parts. Skip intros, sponsor reads, small talk and outros. Up to {maxn} moments.
- title: a punchy hook of max 8 words that makes someone want to watch (honest, no clickbait lies).
- topic: ONE short lowercase topic (1-2 words, never a list). Prefer these existing topics when they fit: {topics}.
- hook: 1-10, how gripping this moment is for a general viewer.
- start/end: seconds from the start of the FULL video (so between {sa} and {sb}).
- last_second_seen: the timestamp (seconds from the start of the full video) of the last moment of video you can see. If the video ends before {b}, this is where it ends.

Video title: {title}

Answer with ONLY a JSON object, no prose:
{{"moments": [{{"start": {sa_ex}, "end": {sb_ex}, "title": "...", "topic": "...", "hook": 7}}], "last_second_seen": {sb}}}'''


# Free-tier quotas are per Google project *per model* and reset at midnight Pacific. They are small and unpublished
# (e.g. 20 requests/day on the newest Flash, no free tier at all on Pro). So we keep a pool of every free Flash /
# Flash-Lite model the key can use, best first, spend each model's daily allowance in turn, and learn the real
# limits from Google's 429 replies (quotaId / quotaValue / retryDelay).
# State lives in kv 'gemini' = {pool: {day, models}, quota: {model: {...}}, last_model}.
SPACING = 6         # seconds between requests to the same model (stays under per-minute limits)
CALL_TIMEOUT = 300  # seconds
POOL_RE = re.compile(r'^gemini-(\d+(\.\d+)?)-flash(-lite)?(-preview)?$')
FALLBACK_POOL = ['gemini-2.5-flash', 'gemini-2.5-flash-lite']
PT = ZoneInfo('America/Los_Angeles')

_gem = None
_gem_lock = threading.RLock()   # reservations and reports are serialized so jobs never double-book a model


def load_state():
    global _gem
    if _gem is None:
        d = db.get('gemini', {})
        _gem = {'pool': d.get('pool'), 'quota': d.get('quota') or {}, 'last_model': d.get('last_model') or ''}
    return _gem


def save_state(): db.put('gemini', _gem)
def pt_day(t=None): return datetime.datetime.fromtimestamp(now() if t is None else t, PT).strftime('%Y-%m-%d')


def next_reset(t=None):
    """Epoch seconds of the next midnight Pacific (+5s), DST-safe."""
    t = now() if t is None else t
    p = datetime.datetime.fromtimestamp(t, PT)
    r = math.floor(t) + 86400 - (p.hour * 3600 + p.minute * 60 + p.second) + 5
    h = datetime.datetime.fromtimestamp(r, PT).hour   # a DST change today shifts the wall clock by an hour
    if h == 23: r += 3600
    elif h == 1: r -= 3600
    return r


def gem_choices(names):
    """Free-tier candidates, best first: newest full Flash models, then Flash-Lite, previews after the stable model
    of the same version. Pro has no free tier, and -latest aliases share a bucket with their model."""
    def rank(n):
        m = POOL_RE.match(n)
        return (1 if m.group(3) else 0, -float(m.group(1)), 1 if m.group(4) else 0, n)
    return sorted((n for n in names if POOL_RE.match(n)), key=rank)


def list_models(key):
    try: r = requests.get(f'{API}/models', params={'pageSize': 1000}, headers={'x-goog-api-key': key}, timeout=30)
    except requests.RequestException as e: raise AIError('NETWORK', f"Couldn't reach Google ({type(e).__name__})")
    try: d = r.json()
    except ValueError: d = {}
    if not isinstance(d, dict): d = {}
    if not r.ok:
        msg = (d.get('error') or {}).get('message') if isinstance(d.get('error'), dict) else None
        raise AIError('BAD_KEY' if r.status_code in (400, 401, 403) else 'FAILED', msg or f'Google returned {r.status_code}')
    return [re.sub(r'^models/', '', str(m.get('name'))) for m in d.get('models') or []
            if 'generateContent' in (m.get('supportedGenerationMethods') or [])]


def pool(key):
    """Cached model pool for this key, refreshed once per Pacific day. Call with the lock held."""
    st = load_state()
    p = st.get('pool') or {}
    if p.get('day') != pt_day() or not p.get('models'):
        try:
            st['pool'] = {'day': pt_day(), 'models': gem_choices(list_models(key))}; save_state()
        except AIError:
            if not p.get('models'): return FALLBACK_POOL
    return st['pool']['models']


def quota(st, model):
    q = st['quota'].setdefault(model, {'day': pt_day(), 'used': 0, 'day_limit': 0, 'blocked_until': 0, 'last': 0, 'note': ''})
    if q['day'] != pt_day(): q['day'] = pt_day(); q['used'] = 0
    return q


def available_at(q, t=None):
    """When this model can take another request (0 = now)."""
    t = now() if t is None else t
    at = max(q.get('blocked_until') or 0, (q.get('last') or 0) + SPACING)
    if q.get('day_limit') and q['used'] >= q['day_limit']: at = max(at, next_reset(t))
    return 0 if at <= t else at


def reserve(key, skip=()):
    """Pick the best model with allowance left and count the request: (model, None) or (None, retry_at)."""
    with _gem_lock:
        t, st, soonest = now(), load_state(), None
        for m in pool(key):
            q = quota(st, m); at = available_at(q, t)
            if m in skip:
                if not at: continue   # already failed this request; still counts for when work can resume
            elif at == 0:
                q['used'] += 1; q['last'] = t; save_state()
                return m, None
            soonest = at if soonest is None else min(soonest, at)
        return None, soonest or next_reset(t)


def report(model, kind, delay=0, limit=0, note=''):
    """Record what Google said about a request we reserved: 'ok', 'day' / 'minute' quota, 'busy', 'gone' or 'unfree'."""
    with _gem_lock:
        t, st = now(), load_state()
        q = quota(st, model)
        if kind != 'ok': q['used'] = max(0, q['used'] - 1)   # rejected requests don't count against the quota
        if kind == 'day':
            q['blocked_until'] = t + delay if delay else next_reset(t)
            if limit: q['day_limit'] = limit; q['used'] = max(q['used'], limit)
        elif kind == 'minute': q['blocked_until'] = t + max(delay, 30)
        elif kind == 'busy': q['blocked_until'] = t + 120
        elif kind in ('gone', 'unfree'): q['blocked_until'] = t + 3 * 86400
        elif kind == 'ok': st['last_model'] = model
        q['note'] = str(note)[:120]
        save_state()


def classify429(body):
    """A 429 body -> (kind, delay seconds, limit)."""
    try:
        d = json.loads(body) if isinstance(body, str) else body
        details = d['error'].get('details') or []
        if not isinstance(details, list): raise TypeError
    except (ValueError, TypeError, KeyError, AttributeError):
        return 'minute', 60, 0
    ids, limit, delay = [], 0, 0
    for det in details:
        if not isinstance(det, dict): continue
        for v in det.get('violations') or []:
            ids.append(str(v.get('quotaId') or ''))
            n = js_int(v.get('quotaValue') or 0)
            if n is not None: limit = max(limit, n)
        if det.get('retryDelay'):
            s = js_float(str(det['retryDelay']))
            if finite(s): delay = s
    if len(ids) >= 3 and not limit: return 'unfree', 0, 0   # every quota without a value: no free tier
    if any('PerDay' in i for i in ids): return 'day', delay, limit
    return 'minute', delay or 60, 0


class GemErr(Exception):
    def __init__(self, kind, delay=0, limit=0, note=''):
        super().__init__(kind)
        self.kind, self.delay, self.limit, self.note = kind, delay, limit, note


def call(key, model, parts, media_low):
    """One generateContent request. Returns text; raises GemErr for quota/availability problems, AIError otherwise."""
    cfg = {'temperature': 0.3, 'responseMimeType': 'application/json'}
    if media_low: cfg['mediaResolution'] = 'MEDIA_RESOLUTION_LOW'
    try:
        r = requests.post(f'{API}/models/{quote(model, safe="")}:generateContent', timeout=(15, CALL_TIMEOUT),
                          headers={'Content-Type': 'application/json', 'x-goog-api-key': key},
                          json={'contents': [{'role': 'user', 'parts': parts}], 'generationConfig': cfg})
        raw = r.text
    except requests.Timeout:
        raise GemErr('busy', note='no answer in time')
    except requests.RequestException as e:
        raise GemErr('busy', note=f'network: {type(e).__name__}')
    try: d = json.loads(raw)
    except ValueError: d = {}
    if not isinstance(d, dict): d = {}
    if r.status_code == 429 or 'RESOURCE_EXHAUSTED' in raw:
        kind, delay, limit = classify429(raw)
        raise GemErr(kind, delay, limit, 'quota')
    if r.status_code in (500, 502, 503, 504): raise GemErr('busy', note=f'HTTP {r.status_code}')
    if r.status_code == 404: raise GemErr('gone', note='model not found')
    if not r.ok:
        msg = (d.get('error') or {}).get('message') if isinstance(d.get('error'), dict) else None
        raise AIError('FAILED', f'Gemini {r.status_code}: {msg or raw[:120]}'[:200])
    c = (d.get('candidates') or [None])[0]
    if not c:
        br = (d.get('promptFeedback') or {}).get('blockReason')
        raise AIError('FAILED', 'Gemini returned no answer' + (f' ({br})' if br else ''))
    return ''.join(p.get('text') or '' for p in (c.get('content') or {}).get('parts') or [] if not p.get('thought'))


def ask(key, parts, media_low=False):
    """Run a request on the best model that has free allowance left, moving down the pool on quota/overload.
    Raises AIError('RATE_LIMIT', ..., retry_at) when every model is used up for now."""
    if not key: raise AIError('BAD_KEY', 'no Gemini key')
    tried = set()
    while True:
        model, retry_at = reserve(key, tried)
        if not model:
            if retry_at and retry_at - now() < 20:   # request spacing
                time.sleep(max(0.1, retry_at - now())); continue
            raise AIError('RATE_LIMIT', 'Free Gemini quota used up for now', retry_at)
        try: text = call(key, model, parts, media_low)
        except GemErr as e:
            report(model, e.kind, e.delay, e.limit, e.note); tried.add(model)
            log(f"gemini: {model} -> {e.kind} {e.note} (limit {e.limit or '?'}), trying next model")
            continue
        # a real error (bad request etc.) propagates and the request stays counted
        report(model, 'ok')
        return text


def quota_status(key):
    """For the UI: models in the pool, requests used today, and when work resumes if everything is used up."""
    if not key: return None
    with _gem_lock:
        t, st = now(), load_state()
        models = pool(key)
        qs = [quota(st, m) for m in models]
        at = [available_at(q, t) for q in qs]
        ready = len([a for a in at if a == 0 or a - t < 20])
        later = [a for a in at if a != 0 and a - t >= 20]
        return {'models': len(models), 'available': ready, 'used_today': sum(q['used'] for q in qs),
                'resumes_at': None if ready else (min(later) if later else None)}


def last_model():
    with _gem_lock: return load_state().get('last_model') or 'auto'


def reset_quota(models=None):
    """A different key may be a different Google project with its own quotas: forget everything we learned."""
    global _gem
    with _gem_lock:
        _gem = {'pool': {'day': pt_day(), 'models': gem_choices(models)} if models else None, 'quota': {}, 'last_model': ''}
        save_state()


# segmentation
def windows(lines, max_chars):
    out, blocks, cur = [], [], []
    cs = w_start = None
    size = 0

    def flush():
        nonlocal blocks, size, w_start
        if blocks: out.append({'text': '\n'.join(blocks), 'start': w_start})
        blocks, size, w_start = [], 0, None

    for s, d, t in lines:
        if cs is None: cs = s
        if w_start is None: w_start = s
        cur.append(t)
        if s + d - cs >= 8:
            b = f'[{fmt(cs)}] {" ".join(cur)}'; blocks.append(b); size += len(b); cur = []; cs = None
            if size >= max_chars: flush()
    if cur: blocks.append(f'[{fmt(cs)}] {" ".join(cur)}')
    flush()
    return out


def parse_moments(out, total):
    res = []
    m = re.search(r'\[\s*\{.*\}\s*\]', out or '', re.S)
    if not m: return res
    try: arr = json.loads(m.group(0))
    except ValueError: return res
    for x in arr if isinstance(arr, list) else []:
        if not isinstance(x, dict): continue
        s, e = js_num(x.get('start')), js_num(x.get('end'))
        if finite(s) and finite(e) and 10 <= e - s <= 150 and 0 <= s < total:
            res.append([s, min(e, total), str(x.get('title') or '')[:90], norm_topic(x.get('topic')), num_or(x.get('hook'), 5)])
    return res


def segment(key, title, lines, topics):
    """One call for the whole transcript (Gemini has a huge context); very long ones are split."""
    total = lines[-1][0] + lines[-1][1]
    max_chars = 400000
    res = []
    for w in windows(lines, max_chars):
        span = max(60, min(total, w['start'] + max_chars / 15) - w['start'])
        out = ask(key, [{'text': PROMPT(max(2, min(40, js_round(span / 120))), title, w['text'], ', '.join(topics[:20]))}])
        res += parse_moments(out, total)
    if not res: raise AIError('FAILED', 'AI returned no valid moments')
    return res


def parse_video_moments(out, a, b):
    """One clip's answer -> (moments, seen). Newer models answer in full-video seconds; gemini-2.5-flash answers
    relative to the clip, so anything clearly before the clip start is shifted by it."""
    m = re.search(r'[{\[].*[}\]]', out or '', re.S)
    try: d = json.loads(m.group(0)) if m else {}
    except ValueError: d = {}
    if isinstance(d, list): d = {'moments': d}
    if not isinstance(d, dict): d = {}
    rel = lambda t: t + a if a and t < a - 5 else t
    moments = []
    for x in d.get('moments') if isinstance(d.get('moments'), list) else []:
        if not isinstance(x, dict): continue
        st, en = rel(js_float(x.get('start'))), rel(js_float(x.get('end')))
        if finite(st) and finite(en) and 10 <= en - st <= 150 and a - 5 <= st < b + 5:
            hook = js_float(x.get('hook'))
            moments.append([st, en, str(x.get('title') or '')[:90], norm_topic(x.get('topic')), hook if finite(hook) and hook else 5])
    s = js_float(d.get('last_second_seen'))
    return moments, rel(s) if finite(s) else 0


VIDEO_SEGMENT = 20 * 60   # ~110k tokens per request at low media resolution
VIDEO_MAX_SEGMENTS = 6    # up to 2 hours


def segment_video(key, vid, title, topics):
    """No usable captions: let Gemini watch the video itself (Google fetches it from YouTube). Long videos go in
    20-minute clips until the model reports the video ended."""
    uri, res, a = f'https://www.youtube.com/watch?v={vid}', [], 0
    for _ in range(VIDEO_MAX_SEGMENTS):
        b = a + VIDEO_SEGMENT
        out = ask(key, [
            {'file_data': {'file_uri': uri}, 'video_metadata': {'start_offset': f'{a}s', 'end_offset': f'{b}s'}},
            {'text': VPROMPT(fmt(a), fmt(b), a, b, a + 12, a + 70, 10, title, ', '.join(topics[:20]) or 'none yet')}
        ], media_low=True)
        moments, seen = parse_video_moments(out, a, b)
        res += moments
        if seen < b - 60: break   # the video ended inside this clip
        a = b
    if not res: raise AIError('FAILED', "Gemini couldn't find moments in this video")
    return res


def chunks(lines):
    res, s0, first = [], None, ''
    for s, d, t in lines:
        if s0 is None: s0, first = s, t
        if s + d - s0 >= 60:
            res.append([s0, s + d, ' '.join(first.split()[:7]) + '…', 'misc', 4]); s0 = None
    return res


# ---------------- feed ----------------
def is_done(act, w, dur): return act in ('like', 'save') or w >= 0.8 * dur
def cooldown(k): return min(7 * 86400, 6 * 3600 * 2 ** max(0, (k or 1) - 1))
def ready_vids(): return {r['id'] for r in db.q("SELECT id FROM videos WHERE status='ready'")}
def all_prefs(): return {r['topic']: [r['score'], r['n']] for r in db.q('SELECT topic, score, n FROM prefs')}
def all_hist(): return {r['moment']: r for r in db.q('SELECT moment, done, last, skips FROM hist')}
def all_saved(): return {r['moment']: r['at'] for r in db.q('SELECT moment, at FROM saved')}


def feed(n, exclude, topic, saved, resume):
    with db.lock:
        hist, prefs, saved_ids, ready = all_hist(), all_prefs(), all_saved(), ready_vids()
        moments = db.q(f'SELECT {MOMENT_COLS} FROM moments ORDER BY id')
        progress = db.get('progress')
    t = now()
    eligible = lambda i: i not in hist or (not hist[i]['done'] and t - hist[i]['last'] >= cooldown(hist[i]['skips']))
    rows = [m for m in moments if m['vid'] in ready and (not topic or m['topic'] == topic)
            and (not saved or m['id'] in saved_ids) and m['id'] not in exclude]
    pool_ = rows if saved else [r for r in rows if eligible(r['id'])]   # never repeat finished moments

    def score(r):
        sc, k = prefs.get(r['topic'], [0.5, 0])
        return sc + 0.35 / math.sqrt(1 + k) + 0.04 * r['hook'] + random.random() * 0.15 - 0.08 * (hist[r['id']]['skips'] if r['id'] in hist else 0)
    sc = {r['id']: (r['id'] if saved else score(r)) for r in pool_}
    pool_.sort(key=lambda r: -sc[r['id']])
    out, out_ids, last = [], set(), None
    for r in pool_:
        if len(out) >= n: break
        if r['vid'] == last and any(p['vid'] != last and p['id'] not in out_ids for p in pool_): continue
        out.append(r); out_ids.add(r['id']); last = r['vid']
    # resume: the moment that was on screen when the page was closed comes first,
    # unless it has been finished since (an interrupted view doesn't start its cooldown here).
    pm = (progress or {}).get('moment')
    if resume and not saved and pm is not None and pm not in exclude and not (pm in hist and hist[pm]['done']):
        r = next((m for m in rows if m['id'] == pm), None)
        if r:
            out = [x for x in out if x['id'] != pm]
            out.insert(0, r)
            if len(out) > n: out.pop()
    vids = list(dict.fromkeys(r['vid'] for r in out))
    tr = get_lines(vids) if vids else {}
    vinfo = {v['id']: v for v in db.q(f'SELECT id, title, channel FROM videos WHERE id IN ({",".join("?" * len(vids))})', vids)} if vids else {}
    res = []
    for r in out:
        v = vinfo.get(r['vid'], {})
        o = dict(r)
        if resume and r['id'] == pm and (progress or {}).get('t'): o['resume_t'] = progress['t']
        o.update(vtitle=v.get('title') or r['vid'], channel=v.get('channel') or '', is_saved=1 if r['id'] in saved_ids else 0,
                 lines=[l for l in tr.get(r['vid']) or [] if r['start'] - 2 <= l[0] < r['end']])
        res.append(o)
    return res


def event(e):
    i = js_int(e.get('moment'))
    if i is None: return
    with db.tx():
        m = db.one('SELECT id, topic FROM moments WHERE id=?', (i,))
        if not m: return
        dur, w, act = max(1, num_or(e.get('dur'), 1)), max(0, num_or(e.get('watched'), 0)), e.get('action') or 'watch'
        if act == 'unsave': db.x('DELETE FROM saved WHERE moment=?', (i,)); return
        signal = 1 if act in ('like', 'save') else 0 if act == 'skip' and w < 3 else min(1, w / dur)
        p = db.one('SELECT score, n FROM prefs WHERE topic=?', (m['topic'],)) or {'score': 0.5, 'n': 0}
        sc, n = p['score'], p['n']
        db.x('INSERT OR REPLACE INTO prefs (topic, score, n) VALUES (?, ?, ?)', (m['topic'], sc + max(0.15, 1 / (n + 2)) * (signal - sc), n + 1))
        h = db.one('SELECT done, skips FROM hist WHERE moment=?', (i,)) or {'done': 0, 'skips': 0}
        d = is_done(act, w, dur)
        db.x('INSERT OR REPLACE INTO hist (moment, done, last, skips) VALUES (?, ?, ?, ?)',
             (i, h['done'] or (1 if d else 0), now(), h['skips'] + (0 if d else 1)))
        if act == 'save': db.x('INSERT OR IGNORE INTO saved (moment, at) VALUES (?, ?)', (i, now()))


def status():
    with db.lock:
        counts = {}
        for r in db.q('SELECT status, COUNT(*) n FROM videos GROUP BY status'): counts[r['status']] = r['n']
        ready, prefs, hist = ready_vids(), all_prefs(), all_hist()
        live = [m for m in db.q('SELECT id, vid, topic FROM moments ORDER BY id') if m['vid'] in ready]
        n_saved = db.one('SELECT COUNT(*) n FROM saved')['n']
    tn = {}
    for m in live: tn[m['topic']] = tn.get(m['topic'], 0) + 1
    topics = [{'topic': k, 'n': v, 'score': prefs[k][0] if k in prefs else 0.5} for k, v in tn.items()]
    topics.sort(key=lambda x: (-x['score'], -x['n']))
    done = later = 0
    for m in live:
        h = hist.get(m['id'])
        if h:
            if h['done']: done += 1
            else: later += 1
    key = gemini_key()
    return {'counts': counts, 'topics': topics, 'moments': len(live), 'saved': n_saved, 'done': done, 'later': later,
            'busy': sum(v for k, v in counts.items() if is_busy(k)),
            'ai': 'gemini', 'ai_ready': bool(key), 'model': last_model(), 'quota': quota_status(key)}


def videos():
    count = {r['vid']: r['n'] for r in db.q('SELECT vid, COUNT(*) n FROM moments GROUP BY vid')}
    return [{'id': v['id'], 'title': v['title'], 'channel': v['channel'], 'status': v['status'], 'error': v['error'] or None,
             'retry_at': v['retry_at'] or 0, 'moments': count.get(v['id'], 0)}
            for v in db.q('SELECT * FROM videos ORDER BY added DESC LIMIT 300')]


def add_ids(ids):
    added, t = 0, now()
    with db.tx():
        for j, i in enumerate(ids):
            cur = db.x("INSERT OR IGNORE INTO videos (id, title, channel, status, error, added, retry_at, tries, lease) "
                       "VALUES (?, ?, '', 'queued', NULL, ?, 0, 0, 0)", (i, i, t + j / 1000))
            added += cur.rowcount
    if added: pump()
    return added


# ---------------- settings ----------------
def hint(k): return '…' + k[-4:] if k else ''


def settings_view():
    k = gemini_key()
    return {'provider': 'gemini', 'ai_ready': bool(k), 'key_set': bool(k), 'key_hint': hint(k), 'model': last_model()}


def set_settings(b):
    s = settings()
    if b.get('gemini_key') == '':
        s.pop('gemini_key', None); s.pop('model', None); db.put('settings', s); reset_quota()
        return 200, {'ok': True, 'model': 'auto', 'models': []}
    old = gemini_key()
    key = b['gemini_key'].strip() if isinstance(b.get('gemini_key'), str) else old
    if not key: return 400, {'error': 'Add your Gemini key first.'}
    try: models = list_models(key)
    except AIError as e:
        if e.code == 'BAD_KEY': return 400, {'error': "That key didn't work. Check it and try again.", 'detail': str(e)}
        return 500, {'error': str(e)}
    # The model is picked automatically from the free-tier pool; any requested model is ignored.
    s['gemini_key'] = key; s.pop('model', None)
    db.put('settings', s)
    if key != old:
        reset_quota(models)   # a different key may be a different Google project with its own quotas
        # Videos waiting for a key or for the old key's quota, and ones that fell back to plain chunks, get real moments now.
        cur = db.x("UPDATE videos SET status='queued', retry_at=0, tries=0 WHERE status='needs_key' "
                   "OR (status='waiting' AND error LIKE 'Free Gemini quota%') OR (status='ready' AND error LIKE 'Used 60s chunks%')")
        if cur.rowcount: pump()
    log('settings: Gemini key updated')
    return 200, {'ok': True, 'model': last_model(), 'models': gem_choices(models)}


# ---------------- API router ----------------
def api(method, p, qs, body):
    g = lambda k, d='': qs[k][0] if k in qs else d
    if method == 'GET':
        if p == 'feed':
            ex = {int(x) for x in g('exclude').split(',') if re.fullmatch(r'\d+', x)}
            return 200, feed(min(20, js_int(g('n', '6')) or 6), ex, g('topic') or None, g('saved') == '1', g('resume') == '1')
        if p == 'status': return 200, status()
        if p == 'progress': return 200, db.get('progress') or {}
        if p == 'videos': return 200, videos()
        if p == 'settings': return 200, settings_view()
        return 404, {'error': 'not found'}
    if p == 'add':
        ids, notes = expand(body.get('urls'))
        return 200, {'found': len(ids), 'new': add_ids(ids), 'notes': notes}
    if p == 'watchlater':
        return 200, {'found': 0, 'new': 0, 'notes': ['Watch Later import needs the Chrome extension']}
    if p == 'retry':
        key = gemini_key()
        n = 0
        with db.tx():
            for v in db.q("SELECT id, status, error FROM videos WHERE status IN ('failed', 'waiting', 'needs_key')"):
                if (v['status'] in ('failed', 'waiting') and (key or not (v['error'] or '').startswith('No captions'))) or \
                        (v['status'] == 'needs_key' and key):
                    db.x("UPDATE videos SET status='queued', retry_at=0 WHERE id=?", (v['id'],)); n += 1
        if n: pump()
        return 200, {'requeued': n}
    if p == 'event': event(body); return 200, {'ok': True}
    if p == 'progress':
        i, t = js_int(body.get('moment')), js_num(body.get('t'))
        db.put('progress', {'moment': i, 't': t if finite(t) else 0, 'at': int(now() * 1000)} if i is not None else None)
        return 200, {'ok': True}
    if p == 'log': log('client', json.dumps(body)[:500]); return 200, {'ok': True}
    if p == 'settings': return set_settings(body)
    return 404, {'error': 'not found'}


# ---------------- processing queue ----------------
_wake = threading.Event()
yt_last = 0.0


def pump(): _wake.set()


def claim():
    t = now()
    with db.tx():
        c = db.one(f"""SELECT * FROM videos WHERE status='queued' OR (status='waiting' AND retry_at < ?)
                       OR (status IN ({','.join('?' * len(BUSY))}) AND lease < ?)
                       ORDER BY status='waiting', added LIMIT 1""", (t, *BUSY, t - LEASE))
        if not c: return None
        db.x("UPDATE videos SET status='fetching captions', lease=? WHERE id=?", (t, c['id']))
    c.update(status='fetching captions', lease=t)
    return c


def vset(v, **f):
    f['lease'] = now()
    v.update(f)
    db.x(f'UPDATE videos SET {", ".join(k + "=?" for k in f)} WHERE id=?', (*f.values(), v['id']))


def backoff(v, base, cap, msg):
    tries = (v['tries'] or 0) + 1
    vset(v, status='waiting', tries=tries, retry_at=now() + min(cap, base * 2 ** (tries - 1)), error=msg)


def topics_by_count():
    return [r['topic'] for r in db.q('SELECT topic, COUNT(*) n, MIN(id) f FROM moments GROUP BY topic ORDER BY n DESC, f')]


def process_video(v):
    global yt_last
    vid = v['id']
    try:
        title, channel = meta(vid)
        vset(v, title=title, channel=channel)
        log(f'{vid}: {title[:60]}')

        def store(ms, err):
            with db.tx():
                db.x('DELETE FROM moments WHERE vid=?', (vid,))
                for start, end, t, topic, hook in ms:
                    db.x('INSERT INTO moments (vid, start, "end", title, topic, hook) VALUES (?, ?, ?, ?, ?, ?)',
                         (vid, start, end, t, norm_topic(topic), hook))
            vset(v, status='ready', error=err, tries=0, retry_at=0)
            log(f'{vid}: ready, {len(ms)} moments' + (f' ({err})' if err else ''))

        lines = get_lines([vid])[vid]
        if not lines:
            wait = yt_last + YT_GAP - now()
            if wait > 0: time.sleep(wait)
            try:
                try: lines = transcript(vid)
                finally: yt_last = now()
            except YTError as e:
                # No captions, or YouTube blocks us: with a Gemini key, let Gemini watch the video instead.
                key = gemini_key()
                usable = e.code in ('NO_CAPTIONS', 'RATE_LIMIT') or 'PO token' in str(e)
                if not (usable and key): raise
                log(f'{vid}: {e}; Gemini watches the video instead')
                vset(v, status='finding moments', error=None)
                return store(segment_video(key, vid, title, topics_by_count()), 'No captions: Gemini watched the video to pick these')
            db.x('INSERT OR REPLACE INTO transcripts (vid, lines) VALUES (?, ?)', (vid, json.dumps(lines, ensure_ascii=False)))
            log(f'{vid}: {len(lines)} caption lines')
        key = gemini_key()
        if not key: return vset(v, status='needs_key', error='Add your Gemini key in Library')
        vset(v, status='finding moments', error=None)
        err = None
        try: ms = segment(key, title, lines, topics_by_count())
        except Exception as e:
            if isinstance(e, AIError) and e.code == 'RATE_LIMIT': raise   # free-tier quota: wait rather than settle for 60s chunks
            ms, err = chunks(lines), f'Used 60s chunks ({e})'[:200]
        store(ms, err)
    except Exception as e:
        if isinstance(e, AIError) and e.code == 'RATE_LIMIT':
            tries = (v['tries'] or 0) + 1
            vset(v, status='waiting', tries=tries, retry_at=e.retry_at or now() + min(6 * 3600, 1800 * 2 ** (tries - 1)),
                 error=f'{e}. Continues automatically.')
        else:
            code = e.code if isinstance(e, YTError) else ''
            if code == 'RATE_LIMIT': yt_last = now() + 300; backoff(v, 600, 6 * 3600, str(e))
            elif code in ('NETWORK', 'HTTP'): backoff(v, 120, 3600, str(e))
            else: vset(v, status='failed', error=str(e)[:200])
        log(f'{vid}: {v["status"]}: {v["error"]}')


def worker():
    while True:
        _wake.clear()
        try:
            while (v := claim()): process_video(v)
        except Exception as e:
            log('queue error:', repr(e)[:300])
        # Sleep until something is added, the earliest waiting video is due, or a minute passes (like the alarm).
        r = db.one("SELECT MIN(retry_at) t FROM videos WHERE status='waiting'")
        due = (r['t'] - now() + 1) if r and r['t'] else 60
        _wake.wait(max(1, min(60, due)))


# ---------------- HTTP ----------------
TYPES = {'.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
         '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg',
         '.ico': 'image/x-icon', '.webp': 'image/webp', '.txt': 'text/plain; charset=utf-8', '.webmanifest': 'application/manifest+json'}
MAX_BODY = 1 << 20


class Handler(BaseHTTPRequestHandler):
    server_version = 'Later Now'
    sys_version = ''

    def log_message(self, *a): pass   # request lines carry ?k=<access key>; never log them

    def do_GET(self): self.route('GET')
    def do_POST(self): self.route('POST')
    def do_HEAD(self): self.static(urlsplit(self.path).path)

    def send(self, status, body, ctype, extra=None):
        self.send_response(status)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('X-Content-Type-Options', 'nosniff')
        for k, v in (extra or {}).items(): self.send_header(k, v)
        self.end_headers()
        if self.command != 'HEAD': self.wfile.write(body)

    def json(self, status, data):
        self.send(status, json.dumps(data, ensure_ascii=False, separators=(',', ':')).encode(), 'application/json; charset=utf-8',
                  {'Cache-Control': 'no-store'})

    def route(self, method):
        u = urlsplit(self.path)
        if u.path == '/api' or u.path.startswith('/api/'): return self.api(method, u)
        if method != 'GET': return self.json(405, {'error': 'method not allowed'})
        self.static(u.path)

    def api(self, method, u):
        qs = parse_qs(u.query, keep_blank_values=True)
        if LATERNOW_KEY and not hmac.compare_digest(qs.get('k', [''])[0].encode(), LATERNOW_KEY.encode()):
            return self.json(401, {'error': 'unauthorized'})
        body = {}
        if method == 'POST':
            try: n = int(self.headers.get('Content-Length') or 0)
            except ValueError: n = 0
            if n > MAX_BODY: return self.json(413, {'error': 'too large'})
            raw = self.rfile.read(n) if n > 0 else b''
            try: body = json.loads(raw or b'{}')   # sendBeacon posts JSON as text/plain
            except ValueError: body = {}
            if not isinstance(body, dict): body = {}
        try: status_, data = api(method, u.path[len('/api/'):], qs, body)
        except Exception as e:
            log(f'api {method} {u.path}: {type(e).__name__}: {str(e)[:200]}')
            status_, data = 500, {'error': str(e)}
        self.json(status_, data)

    def static(self, path):
        path = unquote(path)
        if '\0' in path: return self.json(400, {'error': 'bad path'})
        if path.endswith('/'): path += 'index.html'
        full = os.path.realpath(os.path.join(WEB, path.lstrip('/')))
        if not full.startswith(WEB + os.sep) or not os.path.isfile(full):
            return self.send(404, b'Not found', 'text/plain; charset=utf-8')
        with open(full, 'rb') as f: data = f.read()
        self.send(200, data, TYPES.get(os.path.splitext(full)[1].lower(), 'application/octet-stream'), {'Cache-Control': 'no-cache'})


def main():
    global db
    db = DB(DB_PATH)
    # Single worker per database: anything left in progress by a previous run is recovered right away.
    db.x(f"UPDATE videos SET lease=0 WHERE status IN ({','.join('?' * len(BUSY))})", BUSY)
    if CAPTION_ROUTE not in ('direct', 'proxy', 'auto'): sys.exit('CAPTION_ROUTE must be direct, proxy or auto')
    if CAPTION_ROUTE != 'direct' and not CAPTION_PROXY: log(f'CAPTION_ROUTE={CAPTION_ROUTE} but no CAPTION_PROXY: fetching captions directly')
    threading.Thread(target=worker, name='queue', daemon=True).start()
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    srv.daemon_threads = True
    log(f'Later Now on http://{HOST}:{PORT}/  db={DB_PATH}  captions={CAPTION_ROUTE if CAPTION_PROXY else "direct"}'
        f'  access key {"required" if LATERNOW_KEY else "OFF (anyone who can reach this port can use it)"}'
        f'  gemini key {"from env" if ENV_GEMINI_KEY else "via Library"}')
    try: srv.serve_forever()
    except KeyboardInterrupt: pass


if __name__ == '__main__':
    main()
