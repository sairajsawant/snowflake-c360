#!/bin/zsh
# Render every diagram HTML to a 2x PNG.
#   ./render.sh              -> all diagrams
#   ./render.sh 03-signal    -> just the ones matching a name
# Edit diagrams/*.html (or style.css), re-run, then rebuild the deck with build.py.
set -e
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
DIAG_DIR=${DIAG_DIR:-diagrams}; IMG_DIR=${IMG_DIR:-img}
mkdir -p "$IMG_DIR"
for f in "$DIAG_DIR"/*.html; do
  name=$(basename "$f" .html)
  [[ -n "$1" && "$name" != *"$1"* ]] && continue
  # canvas size comes from the <svg width/height> in each file
  w=$(grep -o '<svg width="[0-9]*"' "$f" | head -1 | grep -o '[0-9]*')
  h=$(grep -o 'height="[0-9]*" viewBox' "$f" | head -1 | grep -o '[0-9]*')
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --window-size=${w},${h} --screenshot="$PWD/$IMG_DIR/${name}.png" "file://$PWD/$f" >/dev/null 2>&1
  echo "rendered $IMG_DIR/${name}.png (${w}x${h} @2x)"
done
