#!/usr/bin/env python3
"""Generate gte_serial's microcode (rtl/gte_serial_ucode.vhd) from a transcription of gte.vhd.

Design and timing model: docs/pocket/GTE.md ("Sequencer", "Schedule").
Field positions and source codes mirror rtl/gte_serial_pkg.vhd: change both together.

    python3 rtl/gen/gte_ucode.py [--L 1] [--out rtl/gte_serial_ucode.vhd] [--report FILE]
"""
import argparse
import sys
from collections import defaultdict

# ---------------------------------------------------------------- package mirror
UW = 97
RD_LSB = (0, 12)
RD_EN, RD_BASE, RD_OFF, RD_DST, RD_W = 0, 1, 3, 9, 12
BASES = {"ABS": 0, "MAT": 1, "VEC": 2, "TRV": 3}
L_LSB = (24, 55)
L_V, L_M0, L_ROW, L_ASEL, L_BSEL, L_XS, L_SSEL, L_K, L_ADD, L_SUB, L_SWAP, L_WB = \
    0, 1, 2, 4, 10, 16, 17, 21, 23, 26, 27, 28
SE_RGB, SE_OTZ, SE_SZ, SE_HSLOT, SE_SXY, SE_SNAP, SE_VSNAP, W_HALT = 86, 87, 88, 89, 92, 93, 95, 96

K = {0: 0, 4: 1, 12: 2, "SF12": 3}
ADD = {"ZERO": 0, "ACC": 1, "MACLAST": 2, "S": 3, "S_SH12": 4}
WB = {"NONE": 0, "STD": 1, "RTP3": 2, "FC": 3, "MVBUG": 4}

A_FF = {"IR1": 17, "IR2": 18, "IR3": 19, "IR0": 20, "SX0": 21, "SX1": 22, "SX2": 23,
        "SZ0": 24, "SZ1": 25, "SZ2": 26, "SZ3": 27, "RGBC_R": 28, "RGBC_G": 29, "RGBC_B": 30,
        "RGB0_R": 31, "RGB0_G": 32, "RGB0_B": 33, "RSH4": 34, "RSH4_NEG": 35,
        "SNAP1_0": 36, "SNAP1_1": 37, "SNAP2_0": 38, "SNAP2_1": 39, "ZERO": 0}
B_FF = {"IR1": 17, "IR2": 18, "IR3": 19, "IR0": 20, "RGBC_R": 21, "RGBC_G": 22, "RGBC_B": 23,
        "VSNAP0": 24, "VSNAP1": 25, "VSNAP2": 26, "DIV": 27, "SY0": 28, "SY1": 29, "SY2": 30,
        "C1000": 31, "C10000": 32, "ZERO": 0}
S_FF = {"ZERO": 0, "MAC1": 9, "MAC2": 10, "MAC3": 11}
NSTG = 8

# ---------------------------------------------------------------- operand symbols
# ("ram16", base, off, half) | ("ram32", base, off) | ("ff", name, read_time or None) | ("c", value)


def r16(word, half, base="ABS"):
    return ("ram16", base, word, half)


def r32(word, base="ABS"):
    return ("ram32", base, word)


def ff(name, t=None):
    return ("ff", name, t)


def c(v):
    return ("c", v)


ZERO = ff("ZERO")


def mat_el(base_word, i, j):
    """Element (i, j), 1-based, of a 3x3 matrix stored from base_word (RT/LL/LC layout)."""
    n = 3 * (i - 1) + (j - 1)
    return r16(base_word + n // 2, n % 2)


RT = lambda i, j: mat_el(32, i, j)
LL = lambda i, j: mat_el(40, i, j)
LC = lambda i, j: mat_el(48, i, j)


def V(v, j):
    """Vector v (0..2), element j (0 = X, 1 = Y, 2 = Z)."""
    return r16(2 * v + j // 2, j % 2)


TR = lambda r: r32(37 + r)
BK = lambda r: r32(45 + r)
FC = lambda r: r32(53 + r)
OFX, OFY, DQB = r32(56), r32(57), r32(60)
H, DQA, ZSF3, ZSF4 = r16(58, 0), r16(59, 0), r16(61, 0), r16(62, 0)
COLOR = ["R", "G", "B"]

# ff symbols -> golden register read (None = constant)
FF_GREG = {
    "IR1": "REG_IR1", "IR2": "REG_IR2", "IR3": "REG_IR3", "IR0": "REG_IR0",
    "SX0": "SXY", "SX1": "SXY", "SX2": "SXY", "SY0": "SXY", "SY1": "SXY", "SY2": "SXY",
    "SZ0": "SZF", "SZ1": "SZF", "SZ2": "SZF", "SZ3": "SZF",
    "RGB0_R": "RGBF", "RGB0_G": "RGBF", "RGB0_B": "RGBF",
    "SNAP1_0": "snap0", "SNAP2_0": "snap0", "SNAP1_1": "snap1", "SNAP2_1": "snap1",
    "VSNAP0": "vsnap", "VSNAP1": "vsnap", "VSNAP2": "vsnap", "DIV": "div",
    "MACRES1": "macres1", "MACRES2": "macres2", "MACRES3": "macres3",
    "REGMAC1": "REG_MAC1", "REGMAC2": "REG_MAC2", "REGMAC3": "REG_MAC3",
}
# golden register -> serial register
G2S = {"REG_IR1": "IR1", "REG_IR2": "IR2", "REG_IR3": "IR3", "REG_IR0": "IR0",
       "macres1": "MAC1", "macres2": "MAC2", "macres3": "MAC3",
       "REG_MAC1": "MAC1", "REG_MAC2": "MAC2", "REG_MAC3": "MAC3", "REG_MAC0": "MAC0",
       "acc1": "acc1", "acc2": "acc2", "acc3": "acc3", "mac3sh": "acc3",
       "maclast1": "maclast1", "maclast2": "maclast2", "maclast3": "maclast3",
       "acc0": "acc0", "mac0last": "mac0last",
       "SXY": "SXY", "SZF": "SZF", "RGBF": "RGBF", "OTZ": "OTZ", "div": "div",
       "snap0": "snap0", "snap1": "snap1", "vsnap": "vsnap"}
INTERNAL = {"macres1", "macres2", "macres3", "acc1", "acc2", "acc3", "mac3sh",
            "maclast1", "maclast2", "maclast3", "acc0", "mac0last", "div"}

# ---------------------------------------------------------------- golden actions


class G:
    """One golden action at absolute step k (the golden runs step k at edge k+1)."""

    def __init__(self, kind, k, **kw):
        self.kind, self.k = kind, k
        self.__dict__.update(kw)


def mac(k, row, a, b, add=None, sub=0, swap=0, ures=0, wb="NONE"):
    return G("mac", k, row=row, a=a, b=b, add=add, sub=sub, swap=swap, ures=ures, wb=wb)


def mac0(k, a, b, add=None, sub=0, ures=0, useir=0, ovf=0):
    return G("mac0", k, a=a, b=b, add=add, sub=sub, swap=0, ures=ures, useir=useir, ovf=ovf)


def side(kind, k, **kw):
    return G(kind, k, **kw)


def rows3(k, fa, fb, **kw):
    """The golden's MAC1/2/3 requests of one step; fa/fb map row -> operand, kw values may be per-row dicts."""
    out = []
    for r in (1, 2, 3):
        kk = {n: (v[r] if isinstance(v, dict) else v) for n, v in kw.items()}
        out.append(mac(k, r, fa(r), fb(r), **kk))
    return out


# --- transcriptions of gte.vhd, one function per command (line refs are gte.vhd)

def rtp_vertex(t, v):
    """RTPS/RTPT per-vertex MAC1-3 requests at steps t..t+2 (:622-632)."""
    acts = rows3(t, lambda r: RT(r, 1), lambda r: V(v, 0), add={1: ("TR", 0), 2: ("TR", 1), 3: ("TR", 2)})
    acts += rows3(t + 1, lambda r: RT(r, 2), lambda r: V(v, 1), ures=1)
    acts += rows3(t + 2, lambda r: RT(r, 3), lambda r: V(v, 2), ures=1, wb={1: "STD", 2: "STD", 3: "RTP3"})
    return acts


def prog_rtps():
    a = rtp_vertex(0, 0)
    a.append(side("sz", 3))
    a.append(mac0(12, ff("IR1", 11), ff("DIV"), OFX, ovf=1))     # IR1aspect lags IR1 by one edge
    a.append(mac0(13, ff("IR2"), ff("DIV"), OFY, ovf=1))
    a.append(side("sxy", 14))
    a.append(mac0(15, DQA, ff("DIV"), DQB, useir=1, ovf=1))
    return a


def prog_rtpt():
    a = rtp_vertex(0, 0) + [side("sz", 3)]
    a += rtp_vertex(3, 1) + [side("sz", 6), side("snap", 6, slot=0)]
    a += rtp_vertex(6, 2) + [side("sz", 9), side("snap", 9, slot=1)]
    a += [mac0(12, ff("SNAP1_0"), ff("DIV"), OFX, ovf=1), mac0(13, ff("SNAP2_0"), ff("DIV"), OFY, ovf=1),
          side("sxy", 14),
          mac0(15, ff("SNAP1_1"), ff("DIV"), OFX, ovf=1), mac0(16, ff("SNAP2_1"), ff("DIV"), OFY, ovf=1),
          side("sxy", 17),
          mac0(18, ff("IR1", 17), ff("DIV"), OFX, ovf=1), mac0(19, ff("IR2"), ff("DIV"), OFY, ovf=1),
          side("sxy", 20),
          mac0(21, DQA, ff("DIV"), DQB, useir=1, ovf=1)]
    return a


def prog_nclip():  # :718-723
    return [mac0(0, ff("SX0"), ff("SY1")),
            mac0(1, ff("SX1"), ff("SY2"), ures=1),
            mac0(2, ff("SX2"), ff("SY0"), ures=1),
            mac0(3, ff("SX0"), ff("SY2"), sub=1, ures=1),
            mac0(4, ff("SX1"), ff("SY0"), sub=1, ures=1),
            mac0(5, ff("SX2"), ff("SY1"), sub=1, ures=1, ovf=1)]


def prog_op():  # :732-738
    a = [mac(0, 1, RT(2, 2), ff("IR3")), mac(0, 2, RT(3, 3), ff("IR1")), mac(0, 3, RT(1, 1), ff("IR2"))]
    a += [mac(1, 1, RT(3, 3), ff("IR2"), sub=1, ures=1, wb="STD"),
          mac(1, 2, RT(1, 1), ff("IR3"), sub=1, ures=1, wb="STD"),
          mac(1, 3, RT(2, 2), ff("IR1"), sub=1, ures=1, wb="STD")]
    return a


def prog_dpcs(batches):  # :748-773; DPCT reads RGB0 at each batch start
    a = []
    for b in range(batches):
        t = 9 * b
        if batches == 1:
            col = lambda r: ff("RGBC_" + COLOR[r - 1])
        else:
            col = (lambda tt: (lambda r: ff("RGB0_" + COLOR[r - 1], tt - 1)))(t)
        a += rows3(t, col, lambda r: c(0x10000))
        a += rows3(t + 1, lambda r: FC(r - 1), lambda r: c(0x1000), sub=1, swap=1, ures=1, wb="FC")
        a += rows3(t + 4, lambda r: ff("IR%d" % r), lambda r: ff("IR0"), add="MACLAST", wb="STD")
        a.append(side("rgb", t + 5))
    return a


def prog_intpl():  # :780-792
    a = rows3(0, lambda r: ff("IR%d" % r), lambda r: c(0x1000))
    a += rows3(1, lambda r: FC(r - 1), lambda r: c(0x1000), sub=1, swap=1, ures=1, wb="FC")
    a += rows3(4, lambda r: ff("IR%d" % r), lambda r: ff("IR0"), add="MACLAST", wb="STD")
    a.append(side("rgb", 5))
    return a


def prog_mvmva(mm3, mv3, tv):  # :801-867
    """tv: 'N' (cv 0/1), 'B' (cv 2, buggy), 'Z' (cv 3, zero translation)."""
    def m(i, j):  # matrix(i, j), 0-based, read at step 0
        if not mm3:
            n = 3 * i + j
            return r16(n // 2, n % 2, "MAT")
        if i == 0:
            return [ff("RSH4_NEG"), ff("RSH4"), ff("IR0")][j]
        return RT(1, 3) if i == 1 else RT(2, 2)

    def vec(j):
        if mv3:
            return ff("VSNAP%d" % j)
        return r16(j // 2, j % 2, "VEC")

    a = []
    if mv3:
        a.append(side("vsnap", 0))
    trans = (lambda r: ZERO) if tv == "Z" else (lambda r: r32(r - 1, "TRV"))
    a += rows3(1, trans, lambda r: c(0x1000))
    if tv == "B":
        a += rows3(2, lambda r: m(r - 1, 0), lambda r: vec(0), ures=1, wb="MVBUG")
        a += rows3(3, lambda r: m(r - 1, 1), lambda r: vec(1))
    else:
        a += rows3(2, lambda r: m(r - 1, 0), lambda r: vec(0), ures=1)
        a += rows3(3, lambda r: m(r - 1, 1), lambda r: vec(1), ures=1)
    a += rows3(4, lambda r: m(r - 1, 2), lambda r: vec(2), ures=1, wb="STD")
    return a


def light_ll(t, v):
    """LLM x V at t+1..t+3 (:881-891)."""
    a = rows3(t + 1, lambda r: LL(r, 1), lambda r: V(v, 0))
    a += rows3(t + 2, lambda r: LL(r, 2), lambda r: V(v, 1), ures=1)
    a += rows3(t + 3, lambda r: LL(r, 3), lambda r: V(v, 2), ures=1, wb="STD")
    return a


def light_lc(t0, t1):
    """BK at t0, then LCM x IR at t1..t1+2 (:894-908)."""
    a = rows3(t0, lambda r: BK(r - 1), lambda r: c(0x1000))
    a += rows3(t1, lambda r: LC(r, 1), lambda r: ff("IR1"), ures=1)
    a += rows3(t1 + 1, lambda r: LC(r, 2), lambda r: ff("IR2"), ures=1)
    a += rows3(t1 + 2, lambda r: LC(r, 3), lambda r: ff("IR3"), ures=1, wb="STD")
    return a


def rgbc_ir(t):
    return rows3(t, lambda r: ff("IR%d" % r), lambda r: ff("RGBC_" + COLOR[r - 1]))


def mac_x16(t, wb):
    return rows3(t, lambda r: ff("MACRES%d" % r), lambda r: c(0x10), wb=wb)


def fc_ir0(t_fc, t_ir0):
    a = rows3(t_fc, lambda r: FC(r - 1), lambda r: c(0x1000), sub=1, swap=1, ures=1, wb="FC")
    a += rows3(t_ir0, lambda r: ff("IR%d" % r), lambda r: ff("IR0"), add="MACLAST", wb="STD")
    return a


def prog_ncd(batches):  # :873-941, batch length 22
    a = []
    for b in range(batches):
        t = 22 * b
        a += light_ll(t, b) + light_lc(t + 4, t + 6) + rgbc_ir(t + 11) + mac_x16(t + 13, "NONE")
        a += fc_ir0(t + 14, t + 17) + [side("rgb", t + 18)]
    return a


def prog_cdp():  # :949-983
    return light_lc(0, 1) + rgbc_ir(6) + mac_x16(8, "NONE") + fc_ir0(9, 12) + [side("rgb", 13)]


def prog_ncc(batches):  # :992-1051, batch length 18
    a = []
    for b in range(batches):
        t = 18 * b
        a += light_ll(t, b) + light_lc(t + 4, t + 6) + rgbc_ir(t + 11) + mac_x16(t + 13, "STD")
        a.append(side("rgb", t + 14))
    return a


def prog_cc():  # :1059-1084
    return light_lc(0, 1) + rgbc_ir(6) + mac_x16(8, "STD") + [side("rgb", 9)]


def prog_nc(batches):  # :1093-1142, batch length 13
    a = []
    for b in range(batches):
        t = 13 * b
        a += light_ll(t, b) + light_lc(t + 4, t + 6) + [side("rgb", t + 9)]
    return a


def prog_sqr():  # :1149-1151
    return rows3(0, lambda r: ff("IR%d" % r), lambda r: ff("IR%d" % r), wb="STD")


def prog_dpcl():  # :1161-1178
    return rgbc_ir(0) + mac_x16(2, "NONE") + fc_ir0(3, 6) + [side("rgb", 7)]


def prog_avsz(n):  # :1186-1201
    zsf = ZSF3 if n == 3 else ZSF4
    first = 1 if n == 3 else 0
    a = [mac0(i, ff("SZ%d" % (first + i)), zsf, ures=1 if i else 0, ovf=1) for i in range(n)]
    return a + [side("otz", n)]


def prog_gpf():  # :1209-1213
    return rows3(0, lambda r: ff("IR%d" % r), lambda r: ff("IR0"), wb="STD") + [side("rgb", 1)]


def prog_gpl():  # :1221-1235
    a = rows3(1, lambda r: ff("REGMAC%d" % r), lambda r: c("SHIFTVALUE"))
    a += rows3(2, lambda r: ff("IR%d" % r), lambda r: ff("IR0"), ures=1, wb="STD")
    return a + [side("rgb", 3)]


OPS = {0x01: "RTPS", 0x06: "NCLIP", 0x0C: "OP", 0x10: "DPCS", 0x11: "INTPL", 0x12: "MVMVA",
       0x13: "NCDS", 0x14: "CDP", 0x16: "NCDT", 0x1B: "NCCS", 0x1C: "CC", 0x1E: "NCS", 0x20: "NCT",
       0x28: "SQR", 0x29: "DPCL", 0x2A: "DPCT", 0x2D: "AVSZ3", 0x2E: "AVSZ4", 0x30: "RTPT",
       0x3D: "GPF", 0x3E: "GPL", 0x3F: "NCCT"}
BUSY = {"RTPS": 26, "NCLIP": 12, "OP": 8, "DPCS": 11, "INTPL": 11, "MVMVA": 11, "NCDS": 34, "CDP": 21,
        "NCDT": 84, "NCCS": 30, "CC": 17, "NCS": 23, "NCT": 55, "SQR": 6, "DPCL": 11, "DPCT": 29,
        "AVSZ3": 6, "AVSZ4": 8, "RTPT": 42, "GPF": 5, "GPL": 6, "NCCT": 74}


def programs():
    p = {"RTPS": prog_rtps(), "RTPT": prog_rtpt(), "NCLIP": prog_nclip(), "OP": prog_op(),
         "DPCS": prog_dpcs(1), "DPCT": prog_dpcs(3), "INTPL": prog_intpl(),
         "NCDS": prog_ncd(1), "NCDT": prog_ncd(3), "CDP": prog_cdp(), "NCCS": prog_ncc(1),
         "NCCT": prog_ncc(3), "CC": prog_cc(), "NCS": prog_nc(1), "NCT": prog_nc(3), "SQR": prog_sqr(),
         "DPCL": prog_dpcl(), "AVSZ3": prog_avsz(3), "AVSZ4": prog_avsz(4), "GPF": prog_gpf(),
         "GPL": prog_gpl()}
    for mm3 in (0, 1):
        for mv3 in (0, 1):
            for tv in "NBZ":
                p["MVMVA_%d%d%s" % (mm3, mv3, tv)] = prog_mvmva(mm3, mv3, tv)
    return p


def busy_of(name):
    return BUSY["MVMVA" if name.startswith("MVMVA") else name]

# ---------------------------------------------------------------- golden timing


def golden_rw(g):
    """(reads, writes) of a golden action as [(greg, time)], with gte.vhd's timing (GTE.md "Schedule")."""
    k, rd, wr = g.k, [], []

    def opnd(o):
        if o[0] == "ff" and o[1] in FF_GREG:
            rd.append((FF_GREG[o[1]], k if o[2] is None else o[2]))

    if g.kind == "mac":
        r = g.row
        opnd(g.a)
        opnd(g.b)
        if g.ures:
            rd.append(("acc%d" % r, k + 1))
        if g.add == "MACLAST":
            rd.append(("maclast%d" % r, k))
        wr += [("acc%d" % r, k + 2), ("maclast%d" % r, k + 2), ("macres%d" % r, k + 2), ("REG_MAC%d" % r, k + 3)]
        if r == 3:
            wr.append(("mac3sh", k + 2))
        if g.wb != "NONE":
            wr.append(("REG_IR%d" % r, k + 3))
    elif g.kind == "mac0":
        opnd(g.a)
        opnd(g.b)
        if g.ures:
            rd.append(("acc0", k + 1))
        wr += [("acc0", k + 2), ("mac0last", k + 2), ("REG_MAC0", k + 3)]
        if g.useir:
            wr.append(("REG_IR0", k + 3))
    elif g.kind == "rgb":
        rd += [("macres1", k + 1), ("macres2", k + 1), ("macres3", k + 1), ("RGBF", k + 1)]
        wr.append(("RGBF", k + 2))
    elif g.kind == "otz":
        rd.append(("acc0", k + 1))
        wr.append(("OTZ", k + 2))
    elif g.kind == "sz":
        rd += [("mac3sh", k + 1), ("SZF", k + 1)]
        wr += [("SZF", k + 2), ("div", k + 9)]
    elif g.kind == "sxy":
        rd += [("mac0last", k + 1), ("acc0", k + 1), ("SXY", k + 1)]
        wr.append(("SXY", k + 2))
    elif g.kind == "snap":       # :676, :689
        rd += [("REG_IR1", k - 1), ("REG_IR2", k)]
        wr.append(("snap%d" % g.slot, k + 1))
    elif g.kind == "vsnap":      # :824
        rd += [("REG_IR1", k), ("REG_IR2", k), ("REG_IR3", k)]
        wr.append(("vsnap", k + 1))
    return rd, wr

# ---------------------------------------------------------------- serial actions


class S:
    """A serial action: lane op, side effect or RAM read."""
    _n = 0

    def __init__(self, kind, g=None):
        S._n += 1
        self.id, self.kind, self.g = S._n, kind, g
        self.reads, self.writes = [], []    # [(sreg, offset)], offsets relative to issue cycle
        self.words = []                     # RAM words needed in staging at issue
        self.cyc = None
        self.slots = {}                     # word -> staging slot used


def ram_key(o):
    return (o[1], o[2])   # (base, word offset)


def serial_of(g, L):
    s = S(g.kind, g)
    if g.kind in ("mac", "mac0"):
        m0 = g.kind == "mac0"
        row = 0 if m0 else g.row
        f = dict(m0=int(m0), row=row, asel=ZERO, bsel=ZERO, xs=0, ssel=ZERO, k=0,
                 add="ZERO", sub=g.sub, swap=g.swap)
        a, b = g.a, g.b
        pow2 = {0x1000: 12, 0x10: 4, "SHIFTVALUE": "SF12"}
        is32 = a[0] == "ram32" or (a[0] == "ff" and (a[1].startswith("MACRES") or a[1].startswith("REGMAC")))
        if not m0 and b[0] == "c" and b[1] in pow2 and (is32 or a == ZERO):
            f["xs"], f["ssel"], f["k"] = 1, a, pow2[b[1]]
        else:
            f["asel"], f["bsel"] = a, b
            if b[0] == "c":
                assert b[1] in (0x1000, 0x10000), (g.k, b)
                f["bsel"] = ff("C1000" if b[1] == 0x1000 else "C10000")
        if g.add is None:
            f["add"] = "ACC" if g.ures else "ZERO"
        elif g.add == "MACLAST":
            assert not g.ures
            f["add"] = "MACLAST"
        elif isinstance(g.add, tuple) and g.add[0] == "TR":
            assert not g.ures and not f["xs"]
            f["add"], f["ssel"] = "S_SH12", TR(g.add[1])
        else:                                    # MAC0 32-bit addend
            assert m0 and not g.ures and not f["xs"]
            f["add"], f["ssel"] = "S", g.add
        if m0:
            f["wb"] = (1 if g.useir else 0) | (2 if g.ovf else 0)
        else:
            f["wb"] = WB[g.wb]
        s.f = f
        # serial reads
        for o in (f["asel"], f["bsel"], f["ssel"]):
            if o[0] in ("ram16", "ram32"):
                s.words.append(ram_key(o))
            elif o[0] == "ff" and o[1] in FF_GREG:
                s.reads.append((G2S[FF_GREG[o[1]]], 0))
        if f["add"] == "ACC":
            s.reads.append(("acc0" if m0 else "acc%d" % row, L))
        if f["add"] == "MACLAST":
            s.reads.append(("maclast%d" % row, L))
        if m0:
            s.writes += [("acc0", L + 1), ("mac0last", L + 1), ("MAC0", L + 1)]
            if g.useir:
                s.writes.append(("IR0", L + 2))
        else:
            s.writes += [("acc%d" % row, L + 1), ("maclast%d" % row, L + 1), ("MAC%d" % row, L + 1)]
            if g.wb != "NONE":
                s.writes.append(("IR%d" % row, L + 2))
        s.flag_t = L + 2
    else:
        s.flag_t = 1
        if g.kind == "rgb":
            s.reads += [("MAC1", 0), ("MAC2", 0), ("MAC3", 0), ("RGBF", 0)]
            s.writes.append(("RGBF", 1))
        elif g.kind == "otz":
            s.reads.append(("acc0", 0))
            s.writes.append(("OTZ", 1))
        elif g.kind == "sz":
            s.reads += [("acc3", 0), ("SZF", 0)]
            s.writes += [("SZF", 1), ("div", 8)]
            s.words.append(ram_key(H))
            s.flag_t = 9                          # divide error lands one edge after the result
        elif g.kind == "sxy":
            s.reads += [("mac0last", 0), ("acc0", 0), ("SXY", 0)]
            s.writes.append(("SXY", 1))
        elif g.kind == "snap":
            s.reads += [("IR1", 0), ("IR2", 0)]
            s.writes.append(("snap%d" % g.slot, 1))
        elif g.kind == "vsnap":
            s.reads += [("IR1", 0), ("IR2", 0), ("IR3", 0)]
            s.writes.append(("vsnap", 1))
    return s

# ---------------------------------------------------------------- scheduler


class Fail(Exception):
    pass


def schedule(name, gacts, L, max_lookback=40):
    busy = busy_of(name)
    S._n = 0
    acts = [serial_of(g, L) for g in gacts]

    # golden versions
    gwrites = defaultdict(list)   # greg -> [(time, idx)]
    greads = []                   # (idx, greg, time)
    for i, g in enumerate(gacts):
        rd, wr = golden_rw(g)
        for greg, t in wr:
            gwrites[greg].append((t, i))
            if t > busy:
                raise Fail("%s: golden write of %s at %d after IDLE edge %d (transcription?)" % (name, greg, t, busy))
        for greg, t in rd:
            greads.append((i, greg, t))
    for greg in gwrites:
        gwrites[greg].sort()

    def gversion(greg, t):
        v = None
        for wt, i in gwrites.get(greg, []):
            if wt <= t:
                v = i
        return v

    # serial writer order per serial register, by golden write time
    swriters = defaultdict(list)
    for greg, lst in gwrites.items():
        sreg = G2S[greg]
        for t, i in lst:
            if i not in [x for _, x in swriters[sreg]]:
                swriters[sreg].append((t, i))
    for sreg in swriters:
        swriters[sreg].sort()
        swriters[sreg] = [i for _, i in swriters[sreg]]

    def soff(i, sreg, kind):
        lst = [o for r, o in (acts[i].writes if kind == "w" else acts[i].reads) if r == sreg]
        if not lst:
            raise Fail("%s: action %d (%s k=%d) has no serial %s of %s" % (name, i, gacts[i].kind, gacts[i].k, kind, sreg))
        return lst[0]

    edges = defaultdict(list)    # pred -> [(succ, delta)]: cyc[succ] >= cyc[pred] + delta

    def edge(p, s_, d):
        if p == s_:
            if d > 0:
                raise Fail("%s: self constraint %d on action %d" % (name, d, p))
            return
        edges[p].append((s_, d))

    for i, greg, t in greads:
        sreg = G2S[greg]
        v = gversion(greg, t)
        if v is None and greg in INTERNAL:
            raise Fail("%s: action %d (%s k=%d) reads %s left over from a previous command" % (name, i, gacts[i].kind, gacts[i].k, greg))
        ro = soff(i, sreg, "r")
        ws = swriters.get(sreg, [])
        if v is not None:
            edge(v, i, soff(v, sreg, "w") - ro)
            pos = ws.index(v)
            nxt = ws[pos + 1] if pos + 1 < len(ws) else None
        else:
            nxt = ws[0] if ws else None
        if nxt is not None and nxt != i:
            edge(i, nxt, ro + 1 - soff(nxt, sreg, "w"))
    for sreg, ws in swriters.items():
        for a_, b_ in zip(ws, ws[1:]):
            edge(a_, b_, soff(a_, sreg, "w") + 1 - soff(b_, sreg, "w"))

    # Placement in golden-step order. Constraints may form cycles (anti-dependencies between rows),
    # so a pass places each action at its earliest legal cycle given the actions already placed,
    # then violated constraints raise the successor's floor and the pass reruns.
    order = sorted(range(len(acts)), key=lambda i: (gacts[i].k, i))
    preds = defaultdict(list)
    for p_, lst in edges.items():
        for s_, d in lst:
            preds[s_].append((p_, d))
    floor = [0] * len(acts)
    for _it in range(400):
        res = place(name, acts, order, preds, floor, busy, max_lookback)
        bad = False
        for p_, lst in edges.items():
            for s_, d in lst:
                if acts[s_].cyc < acts[p_].cyc + d:
                    floor[s_] = max(floor[s_], acts[p_].cyc + d)
                    bad = True
        if not bad:
            break
    else:
        raise Fail("%s: constraints did not converge" % name)
    reads, lanes, slots = res

    last_w = 0
    for a in acts:
        for _, o in a.writes:
            last_w = max(last_w, a.cyc + o)
        last_w = max(last_w, a.cyc + a.flag_t)
    if last_w > busy:
        raise Fail("%s: last serial write at %d after the golden IDLE edge %d" % (name, last_w, busy))
    if sum(1 for cr, _, _ in reads if cr == -1) > 2:
        raise Fail("%s: prefetch overflow" % name)
    length = max([a.cyc for a in acts] + [cr for cr, _, _ in reads]) + 1
    return dict(name=name, acts=acts, reads=reads, lanes=lanes, length=length, last_w=last_w, busy=busy,
                slots_used=sum(1 for s in slots if s))


def place(name, acts, order, preds, floor, busy, max_lookback):
    lanes = defaultdict(list)          # cycle -> [action]
    sides = defaultdict(set)           # cycle -> {kind}
    ports = defaultdict(int)           # read cycle -> reads used
    slots = [[] for _ in range(NSTG)]  # [{'key','w','u'}]
    reads = []                         # (cycle, key, slot)
    placed = set()

    def slot_free(s, w, u):
        return all(iv["u"] < w or iv["w"] > u for iv in slots[s])

    def find_word(key, t, tent):
        """A resident copy of key readable at t, or a new read landing by t."""
        for s in range(NSTG):
            if any(x[1] == s for x in tent):
                continue
            ivs = sorted(slots[s], key=lambda iv: iv["w"])
            for n, iv in enumerate(ivs):
                if iv["key"] == key and iv["w"] <= t:
                    nxt_w = ivs[n + 1]["w"] if n + 1 < len(ivs) else 10 ** 9
                    if t < nxt_w:
                        return ("reuse", s, iv)
        for cr in range(t - 2, max(-2, t - 2 - max_lookback), -1):
            used = ports[cr] + sum(1 for x in tent if x[0] == "new" and x[2] == cr)
            if used >= 2:
                continue
            for s in range(NSTG):
                if slot_free(s, cr + 2, t) and not any(x[1] == s for x in tent):
                    return ("new", s, cr)
        return None

    for i in order:
        a = acts[i]
        a.slots = {}
        cyc = max(0, floor[i], *[acts[p].cyc + d for p, d in preds[i] if p in placed] or [0])
        while True:
            if cyc > busy + 5:
                raise Fail("%s: cannot place action %d (%s k=%d) by cycle %d" % (name, i, a.kind, a.g.k, cyc))
            ok = True
            if a.kind in ("mac", "mac0"):
                row = "m0" if a.kind == "mac0" else a.g.row
                if len(lanes[cyc]) >= 2 or any(("m0" if b.kind == "mac0" else b.g.row) == row for b in lanes[cyc]):
                    ok = False
            elif a.kind in sides[cyc]:
                ok = False
            tent = []
            if ok:
                for key in dict.fromkeys(a.words):
                    r = find_word(key, cyc, tent)
                    if r is None:
                        ok = False
                        break
                    tent.append((r[0], r[1], r[2], key))
            if ok:
                break
            cyc += 1
        a.cyc = cyc
        placed.add(i)
        for kind, s, x, key in tent:
            if kind == "reuse":
                x["u"] = max(x["u"], cyc)
            else:
                slots[s].append({"key": key, "w": x + 2, "u": cyc})
                ports[x] += 1
                reads.append((x, key, s))
            a.slots[key] = s
        if a.kind in ("mac", "mac0"):
            lanes[cyc].append(a)
        else:
            sides[cyc].add(a.kind)
    return reads, lanes, slots


# ---------------------------------------------------------------- encoding


def src_code(o, table, slots, half_ok=True):
    if o[0] == "ff":
        return table[o[1]]
    if o[0] == "ram16":
        return 1 + 2 * slots[ram_key(o)] + o[3]
    if o[0] == "ram32":
        return 1 + slots[ram_key(o)]
    raise ValueError(o)


def put(word, lsb, width, val):
    assert 0 <= val < (1 << width), (lsb, width, val)
    return word | (val << lsb)


def encode(sch):
    words = [0] * sch["length"]
    pf = []
    for cr, key, s in sorted(sch["reads"]):
        base, off = key
        fld = (1 << RD_EN) | (BASES[base] << RD_BASE) | (off << RD_OFF) | (s << RD_DST)
        if cr == -1:
            pf.append(fld)
            continue
        p = 0 if not (words[cr] >> RD_LSB[0]) & 1 else 1
        assert not (words[cr] >> RD_LSB[p]) & 1
        words[cr] |= fld << RD_LSB[p]
    for cyc, ops in sch["lanes"].items():
        for ln, a in enumerate(ops):
            f, lsb, w = a.f, L_LSB[ln], 0
            w = put(w, L_V, 1, 1)
            w = put(w, L_M0, 1, f["m0"])
            w = put(w, L_ROW, 2, f["row"])
            w = put(w, L_ASEL, 6, src_code(f["asel"], A_FF, a.slots))
            w = put(w, L_BSEL, 6, src_code(f["bsel"], B_FF, a.slots))
            w = put(w, L_XS, 1, f["xs"])
            ssel = f["ssel"]
            if ssel[0] == "ff":
                scode = S_FF[ssel[1].replace("MACRES", "MAC").replace("REGMAC", "MAC")]
            else:
                scode = src_code(ssel, None, a.slots)
            w = put(w, L_SSEL, 4, scode)
            w = put(w, L_K, 2, K[f["k"]])
            w = put(w, L_ADD, 3, ADD[f["add"]])
            w = put(w, L_SUB, 1, f["sub"])
            w = put(w, L_SWAP, 1, f["swap"])
            w = put(w, L_WB, 3, f["wb"])
            words[cyc] |= w << lsb
    for a in sch["acts"]:
        if a.kind in ("mac", "mac0"):
            continue
        bit = {"rgb": SE_RGB, "otz": SE_OTZ, "sz": SE_SZ, "sxy": SE_SXY}.get(a.kind)
        if bit is not None:
            words[a.cyc] |= 1 << bit
        if a.kind == "sz":
            words[a.cyc] |= a.slots[ram_key(H)] << SE_HSLOT
        if a.kind == "snap":
            words[a.cyc] |= (a.g.slot + 1) << SE_SNAP
        if a.kind == "vsnap":
            words[a.cyc] |= 1 << SE_VSNAP
    words[-1] |= 1 << W_HALT
    while len(pf) < 2:
        pf.append(0)
    return words, pf

# ---------------------------------------------------------------- output


def vhdl(progs, L):
    rom, starts, pfs = [], {}, {}
    for name in sorted(progs):
        words, pf = encode(progs[name])
        starts[name] = len(rom)
        pfs[name] = pf
        rom += words
    out = ["-- Generated by rtl/gen/gte_ucode.py (G_L = %d): do not edit." % L,
           "-- Format and timing: docs/pocket/GTE.md (\"Sequencer and micro-op format\").",
           "library IEEE;", "use IEEE.std_logic_1164.all;", "use IEEE.numeric_std.all;",
           "use work.gte_serial_pkg.all;", "", "package gte_serial_ucode is", "",
           "   constant UCODE_DEPTH : integer := %d;" % len(rom),
           "   type t_ucode is array (0 to UCODE_DEPTH-1) of std_logic_vector(UW-1 downto 0);",
           "   constant UCODE : t_ucode := ("]
    for n, w in enumerate(rom):
        out.append('      "%s"%s' % (format(w, "0%db" % UW), "," if n + 1 < len(rom) else ""))
    out += ["   );", "",
            "   function prog_start(cmd : unsigned(31 downto 0)) return integer;",
            "   function prog_prefetch(cmd : unsigned(31 downto 0); p : integer) return std_logic_vector;",
            "", "end package;", "", "package body gte_serial_ucode is", "",
            "   function prog_name(cmd : unsigned(31 downto 0)) return integer is",
            "      variable mx, v, cv : integer;", "   begin",
            "      mx := to_integer(cmd(18 downto 17)); v := to_integer(cmd(16 downto 15)); cv := to_integer(cmd(14 downto 13));",
            "      case to_integer(cmd(5 downto 0)) is"]
    names = sorted(progs)
    idx = {n: i for i, n in enumerate(names)}
    for op, nm in sorted(OPS.items()):
        if nm == "MVMVA":
            out.append("         when 16#%02X# =>" % op)
            for mm3 in (0, 1):
                for mv3 in (0, 1):
                    for tv, cond in (("N", "cv <= 1"), ("B", "cv = 2"), ("Z", "cv = 3")):
                        out.append("            if %s and %s and %s then return %d; end if;" % (
                            "mx = 3" if mm3 else "mx /= 3", "v = 3" if mv3 else "v /= 3", cond,
                            idx["MVMVA_%d%d%s" % (mm3, mv3, tv)]))
            out.append("            return -1;")
        else:
            out.append("         when 16#%02X# => return %d;  -- %s" % (op, idx[nm], nm))
    out += ["         when others => return -1;", "      end case;", "   end function;", "",
            "   type t_int_arr is array (0 to %d) of integer;" % (len(names) - 1),
            "   type t_rd_arr is array (0 to %d) of std_logic_vector(RD_W-1 downto 0);" % (len(names) - 1),
            "   constant STARTS : t_int_arr := (%s);" % ", ".join(str(starts[n]) for n in names),
            "   constant PF0 : t_rd_arr := (%s);" % ", ".join('"%s"' % format(pfs[n][0], "012b") for n in names),
            "   constant PF1 : t_rd_arr := (%s);" % ", ".join('"%s"' % format(pfs[n][1], "012b") for n in names),
            "",
            "   function prog_start(cmd : unsigned(31 downto 0)) return integer is",
            "      variable n : integer;", "   begin",
            "      n := prog_name(cmd);", "      if n < 0 then return -1; end if;", "      return STARTS(n);",
            "   end function;", "",
            "   function prog_prefetch(cmd : unsigned(31 downto 0); p : integer) return std_logic_vector is",
            "      variable n : integer;", "   begin",
            "      n := prog_name(cmd);",
            "      if n < 0 then return std_logic_vector(to_unsigned(0, RD_W)); end if;",
            "      if p = 0 then return PF0(n); end if;", "      return PF1(n);",
            "   end function;", "", "end package body;", ""]
    return "\n".join(out), len(rom)


def describe(o, slots):
    if o[0] == "ff":
        return o[1]
    if o[0] == "c":
        return hex(o[1])
    if o[0] == "ram16":
        return "s%d.%s" % (slots[ram_key(o)], "hi" if o[3] else "lo")
    return "s%d" % slots[ram_key(o)]


def report(progs, depth, L):
    lines = ["| Program | golden edges | program words | last write | slack | lane ops | lane use | staging slots |",
             "|---|---|---|---|---|---|---|---|"]
    for name in sorted(progs):
        p = progs[name]
        nops = sum(len(v) for v in p["lanes"].values())
        lines.append("| %s | %d | %d | %d | %d | %d | %d%% | %d |" % (
            name, p["busy"], p["length"], p["last_w"], p["busy"] - p["last_w"], nops,
            round(100 * nops / (2 * p["length"])), p["slots_used"]))
    lines.append("")
    lines.append("ROM: %d words x %d bits (G_L = %d)." % (depth, UW, L))
    return "\n".join(lines)


def listing(p):
    out = ["== %s (busy %d, words %d, last write %d)" % (p["name"], p["busy"], p["length"], p["last_w"])]
    by = defaultdict(list)
    for cr, key, s in p["reads"]:
        by[cr].append("rd %s+%d->s%d" % (key[0], key[1], s))
    for a in p["acts"]:
        g = a.g
        if a.kind in ("mac", "mac0"):
            f = a.f
            if f["xs"]:
                x = "%s<<%s" % (describe(f["ssel"], a.slots), f["k"])
            else:
                x = "%s*%s" % (describe(f["asel"], a.slots), describe(f["bsel"], a.slots))
            add = f["add"] if f["add"] not in ("S", "S_SH12") else "%s(%s)" % (f["add"], describe(f["ssel"], a.slots))
            tag = "MAC0" if f["m0"] else "MAC%d" % f["row"]
            by[a.cyc].append("%s[k%d] %s %s%s wb%d" % (tag, g.k, x, add, " sub" if f["sub"] else "", f["wb"]))
        else:
            by[a.cyc].append("%s[k%d]" % (a.kind, g.k))
    for cyc in sorted(by):
        out.append("  %3d: %s" % (cyc, " | ".join(by[cyc])))
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--L", type=int, default=1)
    ap.add_argument("--out", default=None)
    ap.add_argument("--report", default=None)
    ap.add_argument("--listing", default=None)
    args = ap.parse_args()
    progs, bad = {}, []
    for name, g in programs().items():
        try:
            progs[name] = schedule(name, g, args.L)
        except Fail as e:
            bad.append(str(e))
    for b in bad:
        print("FAIL:", b, file=sys.stderr)
    if bad:
        sys.exit(1)
    text, depth = vhdl(progs, args.L)
    if args.out:
        with open(args.out, "w") as fh:
            fh.write(text)
    rep = report(progs, depth, args.L)
    print(rep)
    if args.report:
        with open(args.report, "w") as fh:
            fh.write(rep + "\n")
    if args.listing:
        with open(args.listing, "w") as fh:
            fh.write("\n\n".join(listing(progs[n]) for n in sorted(progs)) + "\n")


if __name__ == "__main__":
    main()
