#!/usr/bin/env bash
# Render effect frames offscreen and turn each into a high-quality GIF.
# Usage: scripts/make-gifs.sh           (from the repo root)
set -euo pipefail
cd "$(dirname "$0")/.."

FRAMES="${TMPDIR:-/tmp}/macompiz-gifframes"
OUT="docs/gifs"
WIDTH=560
FPS=25

swift build >/dev/null
BIN="$(swift build --show-bin-path)/macompiz"

rm -rf "$FRAMES"; mkdir -p "$FRAMES" "$OUT"
"$BIN" --render-gifs "$FRAMES"

for dir in "$FRAMES"/*/; do
  name="$(basename "$dir")"
  [ -f "$dir/f000.png" ] || continue
  ffmpeg -loglevel error -y -framerate "$FPS" -i "$dir/f%03d.png" \
    -vf "scale=${WIDTH}:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=128[p];[s1][p]paletteuse=dither=bayer" \
    -loop 0 "$OUT/$name.gif"
  echo "  $OUT/$name.gif  ($(du -h "$OUT/$name.gif" | cut -f1))"
done
echo "done -> $OUT"
