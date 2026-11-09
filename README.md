# Later Now

Later Now turns long YouTube videos (podcasts, talks, your Watch Later list) into a vertical feed of short,
self-contained moments, 25 to 90 seconds each. Gemini picks the moments from each video's captions. The feed learns
which topics you like from how you watch, and never shows you the same moment twice.

You bring your own Gemini API key. A free key is enough. Nothing is hosted: the extension runs entirely in your
browser, and the web version runs on your own machine.

- **Chrome extension** (`extension/`): the main product. A phone-sized window on any tab, or a floating player that
  stays on top of every app.
- **iPhone app** (`ios/`): native SwiftUI with Liquid Glass. Everything runs on the phone.
- **Self-hosted web app** (`laternow.py`): the same feed served from your own machine, for developers.

## Download

Everything is on the [Releases](../../releases/latest) page:

| File | What it is |
|---|---|
| `laternow-extension.zip` | Chrome extension. Unzip it, open `chrome://extensions`, turn on Developer mode, click **Load unpacked** and pick the unzipped folder. |
| `laternow-ios.ipa` | iPhone app (iOS 26 or later), unsigned. Install it with a sideloading tool such as Sideloadly or AltStore, which signs it with your own Apple ID. Or build it from source in Xcode (below). |
| `laternow-web.zip` | Self-hosted web app: `laternow.py`, the `web/` UI and `requirements.txt`. See [Self-hosted web app](#self-hosted-web-app). |

## Chrome extension

```sh
cd extension && ./build.sh
```

Open `chrome://extensions`, turn on Developer mode, click **Load unpacked** and pick the `extension` folder.
(`build.sh` copies the shared UI from `web/` into `extension/app/`; without it the extension shows a "file not found" page.)
Click the toolbar icon, connect your Gemini key from
[aistudio.google.com/apikey](https://aistudio.google.com/apikey), and add some videos.

After changing code, run `./build.sh` again and click **Reload** on the extension card. Your data is kept.
`build.sh` also writes `dist/laternow-extension.zip` for the Chrome Web Store.

**Opening it.** Click the toolbar icon. Later Now opens in its own phone-sized window, which remembers its size and
position. Click the icon again to bring the window forward, or to close it if it's already in front. Alt+Shift+M
shows Later Now inside the current page instead.

**Keep on top.** In the Later Now window, the pin button in the header floats the player above every tab and app (a
Document Picture-in-Picture window), and the Later Now window minimizes. Closing the floating player brings the feed
back to the window. While it's pinned, the toolbar icon closes Later Now.

## iPhone app

Open `ios/LaterNow.xcodeproj` in Xcode 27, pick your own team and bundle identifier under Signing & Capabilities,
and run. It needs iOS 26.

The app is a Swift port of the extension's background worker (`ios/LaterNow/Core/`): the same caption fetching,
Gemini free-tier pool and batching, queue, and feed ranking. The Gemini key is kept in the Keychain; everything else
is in the app's Application Support folder. Videos play through YouTube's embedded player in a web view, with sound.

- **For You**: the feed. Tap to pause, double-tap to like, hold for 2×, drag the bar to seek. It advances by itself.
  Videos fill the screen in portrait, cropped at the sides; a button switches to the whole 16:9 picture.
- **Library**: watched percentage, your taste, and every video with its status. Swipe a video to remove it.
- **Add**: paste links or playlists, or import Watch Later (signs in to YouTube inside the app, once).

The queue keeps running after you leave the app, as a background task with its progress on the Lock Screen
(iOS 26), and a notification tells you when new moments are ready.

## Self-hosted web app

```sh
python3 -m venv venv
venv/bin/pip install -r requirements.txt
LATERNOW_KEY=pick-a-secret venv/bin/python laternow.py
```

Open `http://127.0.0.1:8080/#k=pick-a-secret`, then connect your Gemini key under Library.

| Variable | Default | |
|---|---|---|
| `LATERNOW_KEY` | unset | Access key for `/api/*`. Set it whenever the server is reachable by anyone else. |
| `GEMINI_API_KEY` | unset | Used when no key has been saved in Library. |
| `HOST`, `PORT` | `127.0.0.1`, `8080` | Address to listen on. |
| `LATERNOW_DB` | `laternow.db` | SQLite file. |
| `CAPTION_PROXY` | unset | HTTP(S) proxy for caption requests (YouTube often blocks datacenter IPs). |
| `CAPTION_ROUTE` | `direct`, or `proxy` if a proxy is set | `direct`, `proxy`, or `auto` (direct first, then the proxy if YouTube blocks). |
| `CAPTION_GAP` | `3` | Seconds between caption requests. |

The server can't import Watch Later, because that needs your YouTube login. Use the extension for that, or paste
playlist links.

## How moments are picked

1. **Captions.** One video at a time, 3 seconds apart.
2. **Batching** (extension and iPhone). Videos whose captions are ready go to Gemini together: up to 12 videos and
   240k characters of transcript in one request (8 videos and 140k characters on iPhone), answered as one JSON object with keys `video_1` to `video_n`. A video
   over 120k characters goes on its own. A video the model skips in a batch is retried on its own.
3. **No captions.** Gemini watches the YouTube video directly, in 20-minute clips at low media resolution.
4. **Free tier.** Gemini's free quota applies per Google project and per model, at about 20 requests a day for each
   Flash model, and resets at midnight Pacific. Later Now keeps a pool of every free Flash and Flash-Lite model your
   key can use and spends each model's allowance in turn. It learns the real limits from Google's 429 replies. When
   every model is used up, videos wait and continue on their own after the reset.

Batching is the reason the free tier goes a long way: 20 requests a day can cover a couple of hundred videos.

## The feed

Each topic has a moving-average score from how much of its moments you watch: likes and saves count as fully
watched, and quick skips count as zero. Topics you've seen less get an exploration bonus. A skipped moment comes back
after a cooldown that doubles with each skip, from 6 hours up to 7 days. A finished moment never comes back.

## Layout

```
web/               Feed UI shared by the extension and the server (index.html, app.css, app.js, player.js)
extension/         MV3 extension: background.js (storage, API, queue), content.js (overlay),
                   float.html/js (floating player helper), src/ai.js (Gemini), src/youtube.js (captions, playlists)
ios/               iPhone app (SwiftUI): Core/ (engine, Gemini, YouTube), Feed/, Views/, Player/
laternow.py        Self-hosted server, same API as extension/background.js
skill/SKILL.md     Agent skill for driving the server
```

Edit `web/*` for UI changes; they apply to both versions. Then run `extension/build.sh` and reload the extension (`extension/app/` is generated). Keep the API in sync:
`/api/feed`, `status`, `videos`, `add`, `watchlater`, `retry`, `event`, `progress`, `settings`.

## Privacy

Your Gemini key and everything Later Now stores stay in your browser (extension) or on your machine (server). Requests
go only to YouTube (captions, titles, playlists, embeds) and to Google's Gemini API. There are no analytics and no
Later Now servers.
