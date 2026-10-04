#!/bin/zsh
# One command for the primary (Snowflake-branded) deck: diagrams -> PNGs -> pptx.
set -e
cd "$(dirname "$0")"
. .venv/bin/activate
python make_sf_diagrams.py >/dev/null
DIAG_DIR=diagrams_sf IMG_DIR=img_sf ./render.sh >/dev/null
python build.py
