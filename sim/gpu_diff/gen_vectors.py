#!/usr/bin/env python3
"""Seeded GPU command-stream generator for tb_diff.

usage: gen_vectors.py --suite {directed,edge,random,uniform,game,smoke} --seed N [--count N] --out FILE

Vector file: one op per line, '#' comment, all words 8 hex digits, numbers decimal.
  SUITE name          coverage suite name (first line)
  T tag...            coverage tags counted as tag_<tag>
  G1 word             GP1 write
  P word...           GP0 words (first = command word), then wait until both GPUs are idle; timed
  Q word...           GP0 words, no wait
  I                   wait until both GPUs are idle
  RS                  read GPUSTAT on both sides and compare
  RD n                n GPUREAD reads, each after GPUSTAT bit 27 (VRAM data ready) is set
  RG n                n GPUREAD reads without waiting (GPU info results)
  RDS n               wait for the command to start, then n GPUREAD reads relying on bus_stall
  W n                 n idle clk1x cycles
  OPT name 0|1        set a live GPU option (pal60 syncInterlace fixedVBlank isPal videoout_on)
  VC 0|1              compare the video outputs every clk2x
suites: directed (every command class), edge (degenerate, limits, clipping, wrap, mask, interlace),
        uniform (any word, magnitudes vary), game (on-screen 320x240, textured), random = uniform + game
        (--count primitives in total), smoke (short, ends with a draw; used by selftest).
"""
import argparse
import random
import sys


def xy(x, y):
    return ((y & 0x7FF) << 16) | (x & 0x7FF)


def rgb(r, g, b):
    return (b << 16) | (g << 8) | r


def hexw(ws):
    return " ".join("%08x" % (w & 0xFFFFFFFF) for w in ws)


def sx(v, bits=11):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


class Gen:
    def __init__(self, seed):
        self.r = random.Random(seed)
        self.out = []
        self.nprim = 0
        self.dither = 0
        self.offx = 0
        self.offy = 0
        self.areal, self.areat, self.arear, self.areab = 0, 0, 1023, 511

    # ---- raw ops
    def t(self, *tags):
        tags = [t for t in tags if t]
        if tags:
            self.out.append("T " + " ".join(tags))

    def p(self, words, tags=()):
        self.t(*tags)
        self.out.append("P " + hexw(words))
        self.nprim += 1

    def q(self, words):
        self.out.append("Q " + hexw(words))
        self.nprim += 1

    def g1(self, w):
        self.out.append("G1 %08x" % w)

    def w(self, n):
        self.out.append("W %d" % n)

    def rs(self):
        self.out.append("RS")

    def idle(self):
        self.out.append("I")

    # ---- state commands
    def e1(self, tx=0, ty=0, semi=0, depth=2, dither=0, dtd=0, tdis=0, xflip=0, yflip=0):
        self.dither = dither
        self.p([0xE1000000 | tx | ty << 4 | semi << 5 | depth << 7 | dither << 9 | dtd << 10 | tdis << 11 | xflip << 12 | yflip << 13])

    def e2(self, mx=0, my=0, ox=0, oy=0):
        self.p([0xE2000000 | mx | my << 5 | ox << 10 | oy << 15])

    def area(self, l, t, r_, b):
        self.areal, self.areat, self.arear, self.areab = l, t, r_, b
        self.p([0xE3000000 | l | t << 10])
        self.p([0xE4000000 | r_ | b << 10])

    def offset(self, x, y):
        self.offx, self.offy = x, y
        self.p([0xE5000000 | (x & 0x7FF) | (y & 0x7FF) << 11])

    def mask(self, set_=0, check=0):
        self.p([0xE6000000 | set_ | check << 1])

    # ---- primitives
    @staticmethod
    def tex_tag(depth):
        return {0: "tex4", 1: "tex8", 2: "tex15", 3: "tex_rsvd"}[depth]

    def poly(self, op, verts, cols=None, uvs=None, clut=0, tpage=0, depth=None, junk=False):
        quad = bool(op & 8)
        n = 4 if quad else 3
        shaded = bool(op & 0x10)
        tex = bool(op & 4)
        r = self.r
        cols = cols or [rgb(r.randrange(256), r.randrange(256), r.randrange(256)) for _ in range(n)]
        uvs = uvs or [(r.randrange(256), r.randrange(256)) for _ in range(n)]
        ws = [(op << 24) | cols[0]]
        for i in range(n):
            if shaded and i > 0:
                ws.append((cols[i] & 0xFFFFFF) | (r.randrange(0x50 - 1) << 24 if junk else 0))
            ws.append(xy(*verts[i]) if not junk else (xy(*verts[i]) | (r.randrange(16) << 11) | (r.randrange(32) << 27)))
            if tex:
                hi = clut if i == 0 else tpage if i == 1 else (r.randrange(65536) if junk else 0)
                ws.append((hi << 16) | (uvs[i][1] << 8) | uvs[i][0])
        tags = ["quad" if quad else "tri", "gouraud" if shaded else "flat"]
        if op & 2:
            tags.append("semi")
        if tex:
            tags += ["textured", "raw" if op & 1 else "modulated"]
            if depth is not None:
                tags.append(self.tex_tag(depth))
        if self.dither and (shaded or (tex and not op & 1)):
            tags.append("dither")
        tags += self.cull_tags(verts, n)
        self.p(ws, tags)
        return ws

    @staticmethod
    def cull_tags(verts, n):
        def culled(vs):
            xs = [v[0] for v in vs]
            ys = [v[1] for v in vs]
            return max(xs) - min(xs) >= 0x400 or max(ys) - min(ys) >= 0x200 or max(ys) == min(ys)
        c = [culled(verts[0:3])]
        if n == 4:
            c.append(culled(verts[1:4]))
        return ["cull_expect"] if all(c) else ["cull_partial"] if any(c) else []

    def line(self, op, pts, cols=None, junk=False):
        r = self.r
        shaded = bool(op & 0x10)
        poly_ = bool(op & 8)
        cols = cols or [rgb(r.randrange(256), r.randrange(256), r.randrange(256)) for _ in pts]
        ws = [(op << 24) | cols[0], xy(*pts[0])]
        for i in range(1, len(pts)):
            if shaded:
                ws.append(cols[i])
            ws.append(xy(*pts[i]))
        if poly_:
            ws.append(0x55555555)
        tags = ["polyline" if poly_ else "line", "gouraud" if shaded else "flat"]
        if op & 2:
            tags.append("semi")
        self.p(ws, tags)

    def rect(self, op, x, y, w=0, h=0, u=0, v=0, clut=0, depth=None, junk=False):
        r = self.r
        ws = [(op << 24) | rgb(r.randrange(256), r.randrange(256), r.randrange(256)), xy(x, y)]
        if op & 4:
            ws.append((clut << 16) | (v << 8) | u)
        if (op >> 3) & 3 == 0:
            ws.append((h << 16) | w)
        tags = ["rect", "rect_size%d" % ((op >> 3) & 3)]
        if op & 2:
            tags.append("semi")
        if op & 4:
            tags += ["textured", "raw" if op & 1 else "modulated"]
            if depth is not None:
                tags.append(self.tex_tag(depth))
        self.p(ws, tags)

    def fill(self, x, y, w, h):
        self.p([0x02000000 | rgb(self.r.randrange(256), self.r.randrange(256), self.r.randrange(256)), xy(x, y), (h << 16) | w], ["fill"])

    def copy(self, sx_, sy, dx, dy, w, h):
        self.p([0x80000000, xy(sx_, sy), xy(dx, dy), (h << 16) | w], ["copy"])

    def upload(self, x, y, w, h, data=None):
        n = (w * h + 1) // 2 if w * h else 0x80000
        n = (((w or 1024) * (h or 512)) + 1) // 2
        if data is None:
            data = [self.r.randrange(1 << 32) for _ in range(n)]
        self.p([0xA0000000, xy(x, y), (h << 16) | w] + data[:n], ["upload"])

    def download(self, x, y, w, h, stall=False):
        n = (((w or 1024) * (h or 512)) + 1) // 2
        self.t("download")
        self.q([0xC0000000, xy(x, y), (h << 16) | w])
        self.out.append(("RDS %d" if stall else "RD %d") % n)
        self.idle()

    def polyline_pts(self, k, lo, hi):
        r = self.r
        return [(r.randrange(lo, hi), r.randrange(lo, hi)) for _ in range(k)]

    # ---- setup
    def setup(self, hres=1, vres=0, interlace=0):
        self.g1(0x00000000)
        self.g1(0x04000000)
        self.g1(0x08000000 | hres | vres << 2 | interlace << 5)
        self.g1(0x05000000)
        self.g1(0x03000000)
        self.e1(depth=2)
        self.e2()
        self.area(0, 0, 319, 239)
        self.offset(0, 0)
        self.mask(0, 0)

    def texset(self, depth, tx, ty, w_hw=16, h=32, clut_xy=None):
        """Upload a texture block at tpage (tx, ty) and, for 4/8-bit, a CLUT; returns clut word."""
        self.upload(tx * 64, ty * 256, w_hw, h)
        clut = 0
        if depth < 2:
            cx, cy = clut_xy
            n = 16 if depth == 0 else 256
            self.upload(cx, cy, n, 1)
            clut = (cy << 6) | (cx // 16)
        return clut


def tri_verts(r, cx, cy, size, quad):
    pts = [(cx + r.randrange(-size, size + 1), cy + r.randrange(-size, size + 1)) for _ in range(4 if quad else 3)]
    return pts


# ------------------------------------------------------------------ suites

def suite_directed(g):
    r = g.r
    g.setup()
    cluts = {}
    for d in range(3):
        cluts[d] = g.texset(d, 5 + d, 0, clut_xy=(16 * d, 480 + d) if d < 2 else None)
    g.rs()
    # polygons: every opcode, textured ones at every depth, semi modes, dither on/off
    for op in range(0x20, 0x40):
        tex = op & 4
        for d in (range(3) if tex else [2]):
            for dith in (0, 1):
                tp = (5 + d) | (0 << 4) | (r.randrange(4) << 5) | (d << 7) | (dith << 9)
                g.e1(tx=5 + d, semi=r.randrange(4), depth=d, dither=dith)
                big = r.random() < 0.2
                v = tri_verts(r, 160 + r.randrange(-60, 60), 120 + r.randrange(-50, 50), 40 if big else 14, bool(op & 8))
                uvs = [(r.randrange(60), r.randrange(30)) for _ in v]
                g.poly(op, v, uvs=uvs, clut=cluts[d], tpage=tp, depth=d if tex else None)
        g.rs()
    # rectangles: all opcodes, variable sizes, every depth when textured
    g.e1(tx=5, depth=2)
    for op in range(0x60, 0x80):
        tex = op & 4
        for d in (range(3) if tex else [2]):
            g.e1(tx=5 + d, semi=r.randrange(4), depth=d)
            size = (op >> 3) & 3
            w, h = (r.randrange(1, 40), r.randrange(1, 30)) if size == 0 else (0, 0)
            g.rect(op, r.randrange(0, 280), r.randrange(0, 200), w, h, r.randrange(40), r.randrange(20), cluts[d], d if tex else None)
    # variable rectangle sizes
    g.e1(tx=5, depth=2)
    for (w, h) in [(1, 1), (8, 8), (16, 16), (2, 100), (100, 2), (255, 3)]:
        g.rect(0x60, 20, 20, w, h)
        g.rect(0x64, 20, 40, w, h, 0, 0, 0, 2)
    # lines
    for op in (0x40, 0x42, 0x48, 0x4A, 0x50, 0x52, 0x58, 0x5A):
        for k in ((2,) if not op & 8 else (3, 5)):
            g.line(op, g.polyline_pts(k, 10, 230))
    g.rs()
    # fill, copy, upload, download
    g.fill(0, 0, 64, 64)
    g.fill(16, 16, 32, 8)
    g.fill(48, 100, 100, 40)
    g.copy(0, 0, 100, 100, 50, 40)
    g.copy(10, 10, 12, 12, 30, 30)
    g.copy(300, 200, 400, 300, 40, 40)
    g.upload(200, 300, 17, 9)
    g.download(200, 300, 17, 9)
    g.download(0, 0, 32, 4, stall=True)
    g.download(5, 5, 7, 3)
    g.rs()
    # state commands and GP1
    g.p([0x01000000])
    g.p([0x1F000000])
    g.p([0x00000000])
    g.p([0x03000000])
    g.e2(3, 5, 2, 1)
    g.e2(0, 0, 0, 0)
    g.mask(1, 0)
    g.fill(100, 100, 20, 20)
    g.mask(0, 1)
    g.poly(0x20, [(90, 90), (130, 90), (110, 130)])
    g.mask(1, 1)
    g.poly(0x22, [(95, 95), (135, 95), (115, 135)])
    g.mask(0, 0)
    for info in (2, 3, 4, 5, 0, 1, 7):
        g.g1(0x10000000 | info)
        g.out.append("RG 1")
    g.g1(0x02000000)
    g.g1(0x04000001)
    g.g1(0x04000002)
    g.g1(0x04000000)
    g.g1(0x05000000 | xy(0, 0))
    g.g1(0x06000000 | 0x260 | (0xC60 << 12))
    g.g1(0x07000000 | 0x10 | (0xFF << 10))
    g.g1(0x09000000)
    for mode in (0x00, 0x01, 0x02, 0x03, 0x40, 0x41, 0x04, 0x05, 0x24, 0x08, 0x10, 0x80):
        g.g1(0x08000000 | mode)
        g.rs()
    g.g1(0x08000001)
    g.g1(0x00000000)
    g.rs()
    g.setup()
    g.poly(0x38, [(100, 50), (200, 60), (120, 150), (210, 160)])
    g.w(3000)
    g.rs()


def suite_edge(g):
    r = g.r
    g.setup()
    g.area(0, 0, 1023, 511)
    g.texset(2, 5, 0)
    # degenerate and culling-limit polygons
    deg = [
        [(10, 10), (10, 10), (10, 10)],
        [(10, 10), (50, 10), (90, 10)],
        [(10, 10), (10, 50), (10, 90)],
        [(10, 10), (50, 50), (90, 90)],
        [(10, 10), (60, 20), (10, 10)],
        [(10, 10), (60, 20), (60, 20)],
    ]
    for op in (0x20, 0x30, 0x24, 0x34):
        for v in deg:
            g.poly(op, v + [(100, 100)] if False else v, uvs=[(0, 0), (30, 0), (0, 30)], clut=0, tpage=5 | (2 << 7))
    for op in (0x28, 0x3C):
        g.poly(op, [(10, 10), (60, 60), (60, 60), (10, 60)], uvs=[(0, 0), (30, 0), (30, 30), (0, 30)], tpage=5 | (2 << 7))
        g.poly(op, [(10, 10), (60, 10), (110, 10), (160, 10)], uvs=[(0, 0), (30, 0), (30, 30), (0, 30)], tpage=5 | (2 << 7))
    for dx in (0x3FE, 0x3FF, 0x400, 0x401):
        for op in (0x20, 0x30, 0x2C):
            g.poly(op, [(0, 20), (dx, 20), (dx // 2, 24), (dx - 4, 26)][: 4 if op & 8 else 3], uvs=[(0, 0), (30, 0), (30, 30), (0, 30)], tpage=5 | (2 << 7))
            g.poly(op, [(-dx // 2, 20), (dx // 2 + (dx & 1), 22), (3, 30), (7, 33)][: 4 if op & 8 else 3], uvs=[(0, 0), (30, 0), (30, 30), (0, 30)], tpage=5 | (2 << 7))
    for dy in (0x1FE, 0x1FF, 0x200, 0x201):
        for op in (0x20, 0x30, 0x2C):
            g.poly(op, [(30, 0), (34, dy), (36, dy // 2), (40, dy // 3)][: 4 if op & 8 else 3], uvs=[(0, 0), (30, 0), (30, 30), (0, 30)], tpage=5 | (2 << 7))
            g.poly(op, [(30, -dy // 2), (34, dy // 2 + (dy & 1)), (36, 0), (38, 9)][: 4 if op & 8 else 3], uvs=[(0, 0), (30, 0), (30, 30), (0, 30)], tpage=5 | (2 << 7))
    # negative and off-screen coordinates, tiny draw area clipping
    for area in ((0, 0, 1023, 511), (50, 50, 90, 80), (0, 0, 0, 0), (300, 200, 319, 239), (100, 100, 99, 99)):
        g.area(*area)
        for op in (0x20, 0x2C, 0x34, 0x3E):
            for (cx, cy) in ((60, 60), (-20, -20), (310, 230), (-1000, 100), (1000, 400), (0, 0)):
                v = tri_verts(r, cx, cy, 30, bool(op & 8))
                g.poly(op, v, uvs=[(r.randrange(40), r.randrange(40)) for _ in v], tpage=5 | (2 << 7), depth=2)
        g.line(0x40, [(-30, -30), (400, 300)])
        g.line(0x58, [(10, 10), (80, 90), (300, 20), (-50, 60)])
        g.rect(0x60, -8, -8, 20, 20)
        g.rect(0x64, 40, 60, 20, 20, 0, 0, 0, 2)
        g.rect(0x68, 1020, 500, 1, 1)
        g.fill(0, 0, 32, 32)
    g.area(0, 0, 1023, 511)
    # drawing offset wrap
    for (ox, oy) in ((0, 0), (-1024, -1024), (1023, 511), (-1, -1), (512, 256), (-512, -256), (1000, 500)):
        g.offset(ox, oy)
        for op in (0x20, 0x34, 0x2E):
            v = tri_verts(r, 20, 20, 25, bool(op & 8))
            g.poly(op, v, uvs=[(r.randrange(40), r.randrange(40)) for _ in v], tpage=5 | (2 << 7), depth=2)
        g.line(0x40, [(5, 5), (60, 40)])
        g.rect(0x60, 5, 5, 12, 12)
    g.offset(0, 0)
    # mask bit set / check
    g.area(0, 0, 319, 239)
    for sm, ck in ((1, 0), (0, 1), (1, 1), (0, 0)):
        g.mask(sm, ck)
        g.fill(10, 10, 48, 32)
        g.poly(0x22, [(5, 5), (60, 10), (30, 50)])
        g.poly(0x3E, [(5, 5), (60, 10), (30, 50), (70, 60)], uvs=[(0, 0), (30, 0), (0, 30), (30, 30)], tpage=5 | (2 << 7))
        g.rect(0x62, 20, 20, 30, 30)
        g.line(0x4A, [(0, 0), (50, 60), (90, 10)])
        g.copy(0, 0, 100, 0, 60, 60)
        g.upload(120, 120, 8, 8)
    g.mask(0, 0)
    # texture window, flips, reserved depth
    for tw in ((3, 3, 1, 1), (31, 0, 0, 0), (0, 31, 0, 5), (7, 7, 7, 7)):
        g.e2(*tw)
        g.e1(tx=5, depth=2, xflip=r.randrange(2), yflip=r.randrange(2))
        g.rect(0x64, 10, 10, 30, 30, 5, 5, 0, 2)
        g.poly(0x2C, [(50, 50), (100, 50), (50, 100), (100, 100)], uvs=[(0, 0), (60, 0), (0, 60), (60, 60)], tpage=5 | (2 << 7))
    g.e2(0, 0, 0, 0)
    g.e1(tx=5, depth=3)
    g.rect(0x64, 10, 10, 20, 20, 0, 0, 0, 3)
    g.e1(tx=5, depth=2, tdis=1)
    g.rect(0x64, 10, 10, 20, 20)
    g.e1(tx=5, depth=2)
    # wrap-around transfers and unusual fills/copies
    g.fill(1000, 500, 100, 40)
    g.fill(3, 3, 17, 5)
    g.fill(0, 0, 0, 0) if False else None
    g.copy(1000, 500, 0, 0, 60, 30)
    g.copy(0, 0, 1010, 505, 30, 20)
    g.copy(20, 20, 30, 25, 40, 40)
    g.copy(30, 25, 20, 20, 40, 40)
    g.upload(1015, 500, 20, 20)
    g.download(1015, 500, 20, 20)
    g.upload(5, 5, 3, 3)
    g.download(5, 5, 3, 3)
    g.upload(8, 8, 1, 1)
    g.download(8, 8, 1, 1, stall=True)
    # interlaced drawing
    for hres, vres, il in ((1, 1, 1), (1, 0, 1), (1, 1, 0)):
        g.setup(hres, vres, il)
        g.e1(dtd=0, depth=2)
        g.area(0, 0, 319, 479)
        g.poly(0x30, [(10, 10), (150, 20), (60, 100)])
        g.poly(0x20, [(10, 10), (150, 20), (60, 100), (180, 120)])
        g.rect(0x60, 20, 20, 40, 40)
        g.line(0x40, [(0, 0), (200, 100)])
        g.fill(0, 200, 64, 32)
        g.e1(dtd=1, depth=2)
        g.poly(0x30, [(10, 10), (150, 20), (60, 100)])
        g.rs()
    g.setup()
    g.poly(0x38, [(100, 50), (200, 60), (120, 150), (210, 160)])
    g.w(2000)
    g.rs()


def suite_uniform(g, count):
    r = g.r
    g.setup()
    g.area(0, 0, 1023, 511)
    for _ in range(count):
        mag = r.choice((24, 64, 160, 400, 1100))
        if r.random() < 0.06:
            la, ra = sorted((r.randrange(1024), r.randrange(1024)))
            ta, ba = sorted((r.randrange(512), r.randrange(512)))
            g.area(la, ta, ra, ba)
        kind = r.random()

        def pt():
            return (r.randrange(-mag, mag + 1) + r.randrange(0, 320 if mag < 400 else 1), r.randrange(-mag, mag + 1) + r.randrange(0, 240 if mag < 400 else 1))
        if kind < 0.40:
            op = r.randrange(0x20, 0x40)
            n = 4 if op & 8 else 3
            d = r.randrange(3)
            if r.random() < 0.3:
                g.e1(tx=r.randrange(16), ty=r.randrange(2), semi=r.randrange(4), depth=d, dither=r.randrange(2))
            g.poly(op, [pt() for _ in range(n)], clut=r.randrange(1 << 15), tpage=r.randrange(1 << 9) | (d << 7) & 0x180, depth=d, junk=True)
        elif kind < 0.55:
            op = r.choice((0x40, 0x42, 0x48, 0x4A, 0x50, 0x52, 0x58, 0x5A))
            k = r.randrange(3, 7) if op & 8 else 2
            g.line(op, [pt() for _ in range(k)])
        elif kind < 0.75:
            op = r.randrange(0x60, 0x80)
            w, h = (r.choice((1, 2, 7, 33, 100, 255)), r.choice((1, 3, 9, 40, 90))) if (op >> 3) & 3 == 0 else (0, 0)
            x, y = pt()
            g.rect(op, x, y, w, h, r.randrange(256), r.randrange(256), r.randrange(1 << 15), r.randrange(3))
        elif kind < 0.82:
            g.fill(r.randrange(1024), r.randrange(512), r.randrange(1, 200), r.randrange(1, 100))
        elif kind < 0.90:
            g.copy(r.randrange(1024), r.randrange(512), r.randrange(1024), r.randrange(512), r.randrange(1, 100), r.randrange(1, 60))
        elif kind < 0.94:
            g.upload(r.randrange(1024), r.randrange(512), r.randrange(1, 40), r.randrange(1, 20))
        elif kind < 0.97:
            g.download(r.randrange(1024), r.randrange(512), r.randrange(1, 24), r.randrange(1, 12))
        else:
            c = r.randrange(5)
            if c == 0:
                g.e2(r.randrange(32), r.randrange(32), r.randrange(32), r.randrange(32))
            elif c == 1:
                g.offset(r.randrange(-1024, 1024), r.randrange(-1024, 1024))
            elif c == 2:
                g.mask(r.randrange(2), r.randrange(2))
            elif c == 3:
                g.e1(tx=r.randrange(16), ty=r.randrange(2), semi=r.randrange(4), depth=r.randrange(3), dither=r.randrange(2),
                     dtd=r.randrange(2), tdis=r.randrange(2), xflip=r.randrange(2), yflip=r.randrange(2))
            else:
                g.rs()
    g.area(0, 0, 1023, 511)
    g.offset(0, 0)
    g.mask(0, 0)
    g.rs()


def suite_game(g, count, trace_tail=0):
    r = g.r
    g.setup()
    bufy = 0
    texes = []
    n0 = g.nprim

    def new_tex():
        d = r.choice((0, 1, 1, 2, 2, 2))
        tx = 5 + r.randrange(11)
        ty = r.randrange(2)
        slot = len(texes)
        clut = g.texset(d, tx, ty, r.choice((16, 32, 64)), r.choice((16, 32, 64)),
                        clut_xy=(16 * r.randrange(0, 20), 480 + r.randrange(32)) if d < 2 else None)
        scale = (4, 2, 1)[d]
        t = (d, tx, ty, clut, 16 * scale)
        if len(texes) < 8:
            texes.append(t)
        else:
            texes[r.randrange(8)] = t
        return t
    for _ in range(3):
        new_tex()
    g.e1(tx=texes[0][1], ty=texes[0][2], depth=texes[0][0], dither=1)
    frame = 0
    while g.nprim - n0 < count:
        k = r.random()
        if r.random() < 0.015:
            new_tex()
        if r.random() < 0.02:
            frame += 1
            bufy = 240 if frame & 1 else 0
            g.g1(0x05000000 | xy(0, 240 - bufy))
            g.area(0, bufy, 319, bufy + 239)
            g.offset(0, bufy)
            g.fill(0, bufy, 320, 240) if False else None
        d, tx, ty, clut, lim = r.choice(texes)
        if k < 0.60:
            quad = r.random() < 0.5
            tex = r.random() < 0.8
            shaded = r.random() < 0.4
            semi = r.random() < 0.15
            raw = r.random() < 0.15
            op = 0x20 | (raw if tex else 0) | semi << 1 | tex << 2 | quad << 3 | shaded << 4
            if r.random() < 0.3:
                g.e1(tx=tx, ty=ty, semi=r.randrange(4), depth=d, dither=r.randrange(2))
            size = r.choice((8, 16, 24, 40, 64, 120))
            v = tri_verts(r, r.randrange(0, 320), r.randrange(0, 240), size, quad)
            g.poly(op, v, uvs=[(r.randrange(lim), r.randrange(16)) for _ in v], clut=clut,
                   tpage=tx | ty << 4 | d << 7, depth=d if tex else None)
        elif k < 0.80:
            tex = r.random() < 0.75
            szsel = r.choice((0, 0, 1, 2, 3))
            op = 0x60 | (r.random() < 0.2) | (r.random() < 0.15) << 1 | tex << 2 | szsel << 3
            if tex and r.random() < 0.3:
                g.e1(tx=tx, ty=ty, semi=r.randrange(4), depth=d)
            w, h = (r.randrange(4, 64), r.randrange(4, 40)) if szsel == 0 else (0, 0)
            g.rect(op, r.randrange(-8, 320), r.randrange(-8, 240), w, h, r.randrange(lim), r.randrange(16), clut, d if tex else None)
        elif k < 0.88:
            op = r.choice((0x40, 0x42, 0x48, 0x50, 0x52, 0x58))
            g.line(op, g.polyline_pts(r.randrange(3, 5) if op & 8 else 2, 0, 300))
        elif k < 0.93:
            g.fill(r.randrange(0, 300), bufy + r.randrange(0, 200), r.randrange(8, 160), r.randrange(8, 40))
        elif k < 0.97:
            g.copy(r.randrange(0, 280), r.randrange(0, 200), r.randrange(0, 280), r.randrange(0, 200), r.randrange(8, 80), r.randrange(8, 50))
        elif k < 0.985:
            g.upload(r.randrange(320, 900), r.randrange(0, 400), r.randrange(4, 40), r.randrange(4, 30))
        else:
            g.download(r.randrange(320, 900), r.randrange(0, 400), r.randrange(2, 16), r.randrange(2, 8))
    g.rs()
    if trace_tail:
        g.w(trace_tail)


def suite_smoke(g):
    g.setup()
    g.rs()
    g.fill(0, 0, 64, 64)
    g.download(8, 8, 8, 4)
    g.texset(2, 5, 0)
    g.e1(tx=5, depth=2)
    g.poly(0x2C, [(10, 10), (80, 12), (14, 70), (90, 80)], uvs=[(0, 0), (30, 0), (0, 30), (30, 30)], tpage=5 | (2 << 7), depth=2)
    g.line(0x50, [(5, 100), (150, 120)])
    g.rect(0x60, 100, 30, 24, 16)
    g.copy(0, 0, 150, 60, 40, 30)
    g.poly(0x30, [(120, 100), (200, 110), (150, 190)])
    g.rs()


def suite_xfer(g, count):
    """Transfer commands (fill, upload, copy, download) with random sizes, overlaps and wraps, and GP1 01 (clear FIFO)
    in the middle of an upload or a download."""
    r = g.r
    g.setup()
    g.upload(0, 0, 64, 64)
    for _ in range(count):
        k = r.randrange(8)
        x, y = r.randrange(1024), r.randrange(512)
        w = r.choice([0, 1, 2, 3, 4, 5, 7, 8, 15, 16, 17, 31, 63, 64, 100, 255, 256, 511, 513, 1023])
        h = r.choice([0, 1, 2, 3, 5, 8, 16, 33])
        if k == 0:
            g.fill(x & ~15, y, w, h)
        elif k == 1:
            g.upload(x, y, w, h)
        elif k == 2:
            g.download(x, y, w, h)
        elif k == 3:
            g.copy(x, y, (x + r.choice([0, 1, 2, 3, 7, 64, w, 1023])) & 1023, (y + r.choice([0, 1, 3, 100, 511])) & 511, w, h)
        elif k == 4:
            g.copy(x, y, (x - r.choice([0, 1, 2, 3, 7, 64, w, 1023])) & 1023, y, w, h)
        elif k == 5:
            # upload cut short, then clear FIFO
            n = (((w or 1024) * (h or 512)) + 1) // 2
            have = r.randrange(n)
            g.t("upload")
            g.q([0xA0000000, xy(x, y), (h << 16) | w] + [r.randrange(1 << 32) for _ in range(have)])
            g.w(r.randrange(10, 120))
            g.g1(0x01000000)
            g.idle()
            g.fill(0, 0, 16, 1)
        elif k == 6:
            # download read only partly, then clear FIFO
            n = (((w or 1024) * (h or 512)) + 1) // 2
            g.t("download")
            g.q([0xC0000000, xy(x, y), (h << 16) | w])
            g.out.append("RD %d" % r.randrange(1, min(n, 40) + 1))
            g.w(r.randrange(0, 200))
            g.g1(0x01000000)
            g.idle()
            g.download(x, y, 8, 2)
        else:
            g.fill(x & ~15, y, w, h)
            g.rs()
    g.rs()


# (hres1, hres2, vres, interlace, pal, depth24, offx, offy, vstart, vend, options) per seed. An interlaced window
# stays within 256 lines: the golden's unused async path raises a range error above 512 doubled lines.
VIDEO_MODES = [
    (0, 0, 0, 0, 0, 0, 0, 0, 16, 256, ()),
    (1, 0, 0, 0, 0, 0, 3, 5, 16, 256, ()),
    (2, 0, 0, 0, 1, 0, 0, 0, 20, 308, ()),
    (3, 0, 1, 1, 0, 0, 0, 1, 16, 256, ()),
    (0, 1, 0, 0, 0, 0, 2, 0, 16, 256, ()),
    (1, 0, 0, 0, 0, 1, 1, 0, 16, 256, ()),
    (3, 0, 1, 1, 1, 1, 0, 0, 20, 276, ()),
    (0, 0, 0, 0, 0, 1, 2, 3, 16, 256, ()),
    (2, 0, 1, 1, 0, 0, 1, 0, 16, 256, ()),
    (1, 0, 0, 0, 1, 0, 0, 0, 8, 250, ()),
    (1, 0, 0, 0, 0, 0, 1, 0, 4, 250, ("toggle",)),
    (1, 0, 0, 0, 1, 0, 0, 0, 20, 308, (("pal60", 1),)),
    (3, 0, 1, 1, 0, 0, 0, 0, 16, 256, (("syncInterlace", 1),)),
    (1, 0, 0, 0, 0, 0, 0, 0, 16, 256, (("fixedVBlank", 1),)),
    (1, 0, 1, 1, 1, 0, 3, 2, 20, 276, ()),
    (2, 0, 1, 0, 0, 0, 0, 0, 16, 256, ()),
]


def suite_video(g, seed):
    """Display configurations over a painted VRAM, then idle frames; tb_diff compares the video outputs every clk2x."""
    (hres, hres2, vres, il, pal, d24, ox, oy, vs, ve, opts) = VIDEO_MODES[(seed - 1) % len(VIDEO_MODES)]
    r = g.r
    g.g1(0x00000000)
    g.g1(0x04000000)
    for o in opts:
        if o != "toggle":
            g.out.append("OPT %s %d" % o)
    if pal:
        g.out.append("OPT isPal 1")
    g.g1(0x08000000 | hres | vres << 2 | pal << 3 | d24 << 4 | il << 5 | hres2 << 6)
    g.g1(0x05000000 | (oy << 10) | ox)
    g.g1(0x07000000 | vs | (ve << 10))
    g.g1(0x03000000)
    g.e1(depth=2)
    g.area(0, 0, 1023, 511)
    g.offset(0, 0)
    # colour bands (fill widths are multiples of 16) and random rows over the displayed area
    for i in range(8):
        g.fill(i * 128, 0, 128, 512)
    for y in (oy, oy + 1, oy + 2, oy + 7, oy + 30, oy + 119, oy + 120, oy + 239):
        g.upload(0, y, 640, 1)
    g.upload(ox & ~3, oy + 3, 8, 2)
    g.idle()
    g.out.append("VC 1")
    frames = 3
    per_frame = 580000 if not pal else 690000
    for f in range(frames):
        g.w(per_frame // 2)
        if "toggle" in opts and f == 0:
            g.g1(0x03000001)
            g.w(150000)
            g.g1(0x03000000)
            g.out.append("OPT videoout_on 0")
            g.w(150000)
            g.out.append("OPT videoout_on 1")
        elif f == 0:
            g.g1(0x05000000 | ((oy + 1) << 10) | (ox + 1))
        elif f == 1:
            g.g1(0x07000000 | (vs + 3) | ((ve - 5) << 10))
        g.w(per_frame // 2)
    g.out.append("VC 0")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--suite", required=True, choices=["directed", "edge", "random", "uniform", "game", "smoke", "video", "xfer"])
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--count", type=int, default=2000)
    ap.add_argument("--tail", type=int, default=0, help="idle clk1x cycles appended to the game suite (video scan-out)")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    g = Gen(a.seed * 7919 + sum(map(ord, a.suite)))
    name = a.suite
    if name == "directed":
        suite_directed(g)
    elif name == "edge":
        suite_edge(g)
    elif name == "video":
        suite_video(g, a.seed)
    elif name == "xfer":
        suite_xfer(g, a.count // 4)
    elif name == "uniform":
        suite_uniform(g, a.count)
    elif name == "game":
        suite_game(g, a.count, a.tail)
    elif name == "random":
        suite_uniform(g, a.count // 2)
        suite_game(g, a.count - a.count // 2, a.tail)
    else:
        suite_smoke(g)
    with open(a.out, "w") as f:
        f.write("SUITE %s\n" % name)
        f.write("\n".join(g.out) + "\n")
    sys.stderr.write("%s seed=%d primitives=%d lines=%d\n" % (name, a.seed, g.nprim, len(g.out)))


if __name__ == "__main__":
    main()
