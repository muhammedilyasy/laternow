---
name: laternow
description: Drive a self-hosted Later Now server (laternow.py) - add YouTube videos or playlists, check processing, read the feed of short moments, and record watch events. Use when the user wants to queue videos into Later Now or ask what's in their Later Now feed.
---

# Later Now server

Later Now turns long YouTube videos into short, self-contained moments (25-90s) picked by Gemini. The server is
`laternow.py` (Python, SQLite). Its base URL is usually `http://127.0.0.1:8080`. If `LATERNOW_KEY` is set, add
`?k=<key>` to every API call; without it the server answers 401.

All endpoints are under `/api/`. They take and return JSON.

| Call | What it does |
|---|---|
| `POST add` `{"urls": "<links separated by whitespace>"}` | Queue videos. Accepts video links, bare 11-character ids and playlist links. Returns `{found, new, notes}`. |
| `GET status` | `{counts: {status: n}, topics: [{topic, n, score}], moments, saved, done, later, busy, ai, ai_ready, model, quota}` |
| `GET videos` | Up to 300 most recent videos: `{id, title, channel, status, error, retry_at, moments}`. |
| `GET feed?n=6&exclude=1,2&topic=ai&saved=1&resume=1` | The next moments, best first: `{id, vid, start, end, title, topic, hook, vtitle, channel, is_saved, lines}`. |
| `POST event` `{"moment": id, "watched": secs, "dur": secs, "action": "watch\|skip\|like\|save\|unsave"}` | Teaches the feed. |
| `POST retry` `{}` | Requeue failed videos and waiting ones. |
| `GET/POST settings` | `{gemini_key}` to connect (validated with Google), `""` to remove. GET never returns the key, only `key_hint`. |
| `GET/POST progress` | The moment on screen: `{moment, t}`. |
| `POST watchlater` | Not available on the server (needs the extension). |

Video statuses: `queued`, `fetching captions`, `finding moments`, `waiting` (Gemini free quota or YouTube
throttling; continues by itself at `retry_at`), `needs_key`, `ready`, `failed`.

To open a moment on YouTube: `https://www.youtube.com/watch?v=<vid>&t=<floor(start)>s`.

Never print or store the Gemini key or `LATERNOW_KEY` in output.
