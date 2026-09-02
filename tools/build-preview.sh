#!/usr/bin/env bash
# Compose preview.png (the marketplace listing card) from the per-tab captures.
#
# The marketplace generates both its 720w grid card and its 1600w detail view
# from this one file, preserving aspect ratio — so it has to be landscape and it
# has to survive being shrunk to thumbnail size.
#
# Run tools/capture-preview.sh first to refresh assets/tabs/*.png.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

python3 tools/build-preview.py
chromium --headless --disable-gpu --hide-scrollbars \
         --window-size=1600,1000 --screenshot="$ROOT/preview.png" \
         "file://$ROOT/tools/promo.html" >/dev/null 2>&1
magick "$ROOT/preview.png" -strip "$ROOT/preview.png"
echo "preview.png -> $(magick identify -format '%wx%h %b' "$ROOT/preview.png")"
