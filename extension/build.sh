#!/usr/bin/env bash
# Copies the shared feed UI (../web) into app/, so this folder can be loaded unpacked in chrome://extensions,
# and writes dist/laternow-extension.zip for the Chrome Web Store.
# Run it after every change to ../web. app/ is generated: edit ../web instead.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf app dist
mkdir -p app dist/laternow/app
cp ../web/index.html ../web/app.css ../web/app.js ../web/player.js ../web/icon.svg ../web/icon-32.png ../web/apple-touch-icon.png app/
out=dist/laternow
cp manifest.json background.js content.js float.html float.js "$out/"
cp -R src icons app "$out/"
(cd "$out" && zip -qr -X ../laternow-extension.zip .)
echo "Built extension/ (load this unpacked), $out (v$(grep -m1 '"version"' manifest.json | sed 's/.*: "\(.*\)".*/\1/')) and dist/laternow-extension.zip"
