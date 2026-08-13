#!/bin/zsh
#
# make-icon.sh — turn a png into a macOS application icon (.icns).
#
# Usage:
#   ./tools/make-icon.sh input.png [output.icns]
#
# Pipeline:
#   1. Crop the plain background around the image (background colour is taken from
#      the top-left pixel, with an anti-aliasing tolerance)
#   2. Scale it to ICON_CONTENT_RATIO of the canvas (default 0.88) and center it,
#      leaving the margin macOS icons conventionally have
#   3. Apply a macOS-style rounded-corner mask
#   4. Emit 16/32/128/256/512 plus @2x variants and pack them into an .icns
#
# Pixel art is upscaled with nearest-neighbour to keep edges crisp. Without PIL
# this degrades to plain `sips` scaling (no crop, no rounded corners).
#
set -e
# This script runs in its own zsh (the engine invokes it as `zsh make-icon.sh`), so
# the engine's NULL_GLOB does not carry over. Without it, zsh's default NOMATCH makes
# an unmatched pattern abort the whole `for` command — the pyenv glob below would then
# kill this script on any machine without ~/.pyenv, before probing a single interpreter
# and before ever reaching the sips fallback.
setopt NULL_GLOB

SRC="$1"
OUT="${2:-${SRC:r}.icns}"

[[ -n "$SRC" ]] || { print "Usage: $0 input.png [output.icns]" >&2; exit 1 }
[[ -f "$SRC" ]] || { print "Input file not found: $SRC" >&2; exit 1 }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
base="$work/base_1024.png"

# Find a python that actually has PIL. Trying only the python3 on PATH is not
# enough — under pyenv/homebrew the one on PATH is often precisely the one without it.
PY_BIN=""
for cand in \
    python3 \
    /opt/homebrew/bin/python3 \
    /usr/local/bin/python3 \
    "$HOME/.pyenv/shims/python3" \
    "$HOME"/.pyenv/versions/*/bin/python3 \
    /usr/bin/python3
do
  c="$(command -v "$cand" 2>/dev/null || true)"
  [[ -n "$c" ]] || continue
  if "$c" -c "import PIL" 2>/dev/null; then PY_BIN="$c"; break; fi
done

if [[ -n "$PY_BIN" ]]; then
  "$PY_BIN" - "$SRC" "$base" <<'PY'
from PIL import Image, ImageChops, ImageDraw
import os, sys

src_path, out_path = sys.argv[1], sys.argv[2]
img = Image.open(src_path).convert('RGBA')

# Treat the top-left pixel as the background colour and find the real content
# bounding box. The tolerance must be generous: source art often carries a nearly
# invisible drop shadow (say 240-253 grey over a 255 white background), and folding
# that into the bbox pushes the visible artwork off centre. 28 rejects such shadows
# without eating the anti-aliased edges of the artwork. Override with
# ICON_BG_TOLERANCE for unusual sources (lower = keep more faint content,
# higher = crop more aggressively).
TOL = int(os.environ.get('ICON_BG_TOLERANCE', '28'))
bg = img.getpixel((0, 0))
diff = ImageChops.difference(img.convert('RGB'),
                            Image.new('RGB', img.size, bg[:3])).convert('L')
bbox = diff.point(lambda p: 255 if p > TOL else 0).getbbox()
if bbox:
    img = img.crop(bbox)

BASE = 1024
# Fraction of the canvas the content occupies (along its long edge). Override with
# ICON_CONTENT_RATIO. Note: for non-square artwork the padding cannot be equal on
# all sides — the long edge meets the margin while the short edge is centered
# proportionally, leaving more room along the short axis. That follows from the
# aspect ratio; raising the ratio shrinks the padding overall but never equalises it.
CONTENT = int(BASE * float(os.environ.get('ICON_CONTENT_RATIO', '0.88')))
w, h = img.size
scale = CONTENT / max(w, h)
nw, nh = max(1, int(w * scale)), max(1, int(h * scale))

# Nearest-neighbour when enlarging, LANCZOS when shrinking: keeps pixel art hard-edged
# on the way up and smooth on the way down.
resample = Image.NEAREST if scale >= 1 else Image.LANCZOS
canvas = Image.new('RGBA', (BASE, BASE), bg)
resized = img.resize((nw, nh), resample)
canvas.paste(resized, ((BASE - nw) // 2, (BASE - nh) // 2), resized)

# macOS corner radius (rounded-rectangle approximation of the squircle)
mask = Image.new('L', (BASE, BASE), 0)
ImageDraw.Draw(mask).rounded_rectangle(
    [0, 0, BASE - 1, BASE - 1], radius=int(BASE * 0.223), fill=255)
out = Image.new('RGBA', (BASE, BASE), (0, 0, 0, 0))
out.paste(canvas, (0, 0), mask)
out.save(out_path)
print(f"   source {w}x{h} -> 1024x1024 (cropped, margined, rounded)")
PY
else
  print "   No python with PIL found; falling back to plain sips scaling (no crop/rounding)"
  print "   For the full treatment: pip install Pillow"
  sips -z 1024 1024 "$SRC" --out "$base" >/dev/null
fi

iconset="$work/icon.iconset"
mkdir -p "$iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$base" --out "$iconset/icon_${s}x${s}.png" >/dev/null 2>&1
  d=$((s * 2))
  sips -z $d $d "$base" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null 2>&1
done

iconutil -c icns "$iconset" -o "$OUT"
print "   Wrote $OUT"
