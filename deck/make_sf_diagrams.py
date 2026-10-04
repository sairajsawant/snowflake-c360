"""
Generate the Snowflake-branded diagrams from the originals.

    python make_sf_diagrams.py && DIAG_DIR=diagrams_sf IMG_DIR=img_sf ./render.sh

diagrams/ stays the single source of truth for content and layout. This only
swaps colours to the Snowflake 2026 palette and fonts to Arial, so editing a
diagram means editing diagrams/*.html and re-running the line above.
"""
import pathlib
import re

SRC, DST = pathlib.Path("diagrams"), pathlib.Path("diagrams_sf")
DST.mkdir(exist_ok=True)

# original (research-blog palette) -> Snowflake 2026 brand palette
COLORS = {
    "FAF9F5": "FFFFFF",   # canvas -> white, so diagrams sit flush on the slide
    "141413": "252525",   # ink
    "5E5D59": "5B5B5B",   # medium gray
    "B9B6AC": "C9D3DC",   # rules
    "D97757": "29B5E8", "F5DED3": "DDF2FB", "B4583A": "11567F",   # accent -> Snowflake Blue
    "6A9BCC": "11567F", "DDE8F3": "E3EDF4",                       # -> Mid-Blue
    "788C5D": "75CDD7", "E3E9D9": "E3F6F7", "3F4A33": "1F5E66",   # -> Star Blue
    "C49A6C": "FF9F36", "F0E5D3": "FFF0E0",                       # -> Valencia Orange
    "8E8BB0": "7254A3", "E7E6F0": "EEEAF5",                       # -> Purple Moon
    "F0EEE6": "F2F6F9", "E3E0D8": "DCE3EA", "D9D6CC": "C9D3DC",   # neutrals
}
FONT_STACK = re.compile(r'font-family:[^;]*?(Georgia|Tiempos|Styrene|Söhne)[^;]*;')


def convert(text):
    for a, b in COLORS.items():
        text = re.sub(a, b, text, flags=re.I)
    text = FONT_STACK.sub('font-family: Arial, "Helvetica Neue", sans-serif;', text)
    # headings were a semibold serif; brand headings are Arial Bold
    text = text.replace("font-weight: 600; }", "font-weight: 700; }")
    # serif italics (quotes) read better upright-italic in Arial at the same size
    return text


for f in SRC.iterdir():
    if f.suffix in (".html", ".css"):
        (DST / f.name).write_text(convert(f.read_text()))
print("wrote", sorted(p.name for p in DST.iterdir()))
