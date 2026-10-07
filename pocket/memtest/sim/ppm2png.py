#!/usr/bin/env python3
"""Convert the ASCII PPM written by tb_screen into a PNG (pure Python, 3x upscale).

  sim/ppm2png.py sim/out/screen.ppm sim/out/screen.png
"""
import struct
import sys
import zlib

src, dst = sys.argv[1], sys.argv[2]
tok = open(src).read().split()
assert tok[0] == "P3"
w, h = int(tok[1]), int(tok[2])
vals = list(map(int, tok[4:]))
scale = 3
raw = bytearray()
for y in range(h):
    row = bytearray()
    for x in range(w):
        i = (y * w + x) * 3
        row += bytes(vals[i:i + 3]) * scale
    raw += (b"\x00" + bytes(row)) * scale


def chunk(t, d):
    c = struct.pack(">I", len(d)) + t + d
    return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)


png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w * scale, h * scale, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
open(dst, "wb").write(png)
