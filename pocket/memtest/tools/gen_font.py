#!/usr/bin/env python3
"""Generate the 8x8 font ROM (fpga/core/font8x8.hex) from font8x8_basic.h.

  tools/gen_font.py

font8x8_basic is by Daniel Hepper (public domain, https://github.com/dhepper/font8x8):
128 glyphs of 8 bytes, bit 0 = leftmost pixel, first byte = top row. One byte per line.
"""
import re
from pathlib import Path

here = Path(__file__).resolve().parent
src = (here / "font8x8_basic.h").read_text()
rows = re.findall(r"\{\s*((?:0x[0-9A-Fa-f]{2}\s*,?\s*){8})\}", src)
assert len(rows) == 128, len(rows)
out = []
for r in rows:
    out += [b[2:].upper() for b in re.findall(r"0x[0-9A-Fa-f]{2}", r)]
(here.parent / "fpga/core/font8x8.hex").write_text("\n".join(out) + "\n")
print("font8x8.hex:", len(out), "bytes")
