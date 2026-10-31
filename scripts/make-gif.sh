#!/usr/bin/env bash
# Turn a screen recording into the README demo GIF.
#   scripts/make-gif.sh ~/Desktop/"Screen Recording ….mov" [docs/demo.gif]
# Needs ffmpeg (brew install ffmpeg). Uses gifski for nicer output if installed.
set -euo pipefail
IN="$1"
OUT="${2:-docs/demo.gif}"
FPS=30
WIDTH=560   # 2x of a ~280pt display width, crisp on Retina

if command -v gifski >/dev/null; then
  TMP="$(mktemp -d)"
  ffmpeg -loglevel error -i "$IN" -vf "fps=$FPS,scale=$WIDTH:-1:flags=lanczos" "$TMP/f%04d.png"
  gifski --fps "$FPS" --quality 90 -o "$OUT" "$TMP"/f*.png
  rm -rf "$TMP"
else
  ffmpeg -loglevel error -y -i "$IN" -vf \
    "fps=$FPS,scale=$WIDTH:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
    "$OUT"
fi
ls -lh "$OUT"
