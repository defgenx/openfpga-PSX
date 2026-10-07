#!/usr/bin/env python3
"""Vector generator for the GTE differential testbench (tb_diff.vhd).

Vector file: one item per line, hex fields "TT AA DDDDDDDD".

  01 00 CCCCCCCC  COP2 command word
  04 AA DDDDDDDD  MTC2/CTC2 write of register AA (0..63)
  05 AA 00000000  MFC2/CFC2 read of register AA
  02 00 0000000M  mode: bit0 = CPU-timing handshake, bit1 = dump after each command
  10 00 NNNNNNNN  gap: N idle clk1x cycles
  11 00 00000000  dump: read all 64 registers and compare
  12 00 00000000  reset pulse of one clk1x (applied while idle)
  13 00 NNNNNNNN  pause at an idle point, ce low for N clk1x, waits until it ended
  14 00 NNNNNNNN  race pause: armed on the edge the next op is issued
  15 00 000000SS  suite label: 0 directed 1 edge 2 reset 3 cpu 4 uniform 5 game 6 smoke 7 boundary
  16 00 NNNNNNNN  async pause: armed now, fires at the first idle point, no waiting
  17 AA DDDDDDDD  write of AA and read of AA on the same clk1x edge
  18 AA DDDDDDDD  write of AA and read of AA+1 on the same clk1x edge
  19 00 NNNNNNNN  pause of N clk1x (N >= 2) with a one-clk1x reset pulse while ce is low

This list is canonical; tb_diff.vhd implements it.

Suites: directed, edge, reset, cpu, random (uniform + game halves), smoke, boundary.
"""
import argparse
import random
import sys
from math import isqrt

WRITABLE = [r for r in range(64) if r not in (29, 31)]
VALID_OPC = [0x01, 0x06, 0x0C, 0x10, 0x11, 0x12, 0x13, 0x14, 0x16, 0x1B, 0x1C,
             0x1E, 0x20, 0x28, 0x29, 0x2A, 0x2D, 0x2E, 0x30, 0x3D, 0x3E, 0x3F]
DPC_OPC = [0x10, 0x11, 0x29, 0x2A, 0x3D, 0x3E]
COLOR_OPC = [0x10, 0x11, 0x13, 0x14, 0x16, 0x1B, 0x1C, 0x1E, 0x20, 0x29, 0x2A, 0x3D, 0x3E, 0x3F]
RT_OPC = [0x01, 0x30]

EXT16 = [0x7FFF, 0x8000, 0x0000, 0x0001, 0xFFFF, 0x4000, 0xC000, 0x1000, 0xF000, 0x0FFF]
EXT32 = [0x7FFFFFFF, 0x80000000, 0, 1, 0xFFFFFFFF, 0x40000000, 0xC0000000,
         0x00010000, 0xFFFF0000, 0x7FFF8000, 0x00001000, 0xFFFFF000]


def p16(lo, hi):
    return ((hi & 0xFFFF) << 16) | (lo & 0xFFFF)


class Gen:
    def __init__(self, seed, f):
        self.r = random.Random(seed)
        self.f = f
        self.buf = []
        self.n_cmd = 0

    def flush(self):
        self.f.writelines(self.buf)
        self.buf = []

    # ---------------------------------------------------------------- emit
    def line(self, t, a, d):
        self.buf.append("%02X %02X %08X\n" % (t, a, d & 0xFFFFFFFF))
        if len(self.buf) >= 65536:
            self.flush()

    def label(self, s):
        self.line(0x15, 0, s)

    def mode(self, m):
        self.line(0x02, 0, m)

    def write(self, reg, val):
        self.line(0x04, reg, val)

    def read(self, reg):
        self.line(0x05, reg, 0)

    def cmd(self, word):
        self.line(0x01, 0, word)
        self.n_cmd += 1

    def gap(self, n):
        if n > 0:
            self.line(0x10, 0, n)

    def dump(self):
        self.line(0x11, 0, 0)

    def reset(self):
        self.line(0x12, 0, 0)

    def pause(self, n):
        self.line(0x13, 0, n)

    def race(self, n):
        self.line(0x14, 0, n)

    def wr_rd(self, reg, val, same=True):
        self.line(0x17 if same else 0x18, reg, val)

    def pause_reset(self, n):
        self.line(0x19, 0, n)

    def apause(self, n):
        self.line(0x16, 0, n)

    # ---------------------------------------------------------------- command words
    def cmd_word(self, opc, sf=None, lm=None, mx=None, v=None, cv=None):
        r = self.r
        sf = r.getrandbits(1) if sf is None else sf
        lm = r.getrandbits(1) if lm is None else lm
        mx = r.randrange(4) if mx is None else mx
        v = r.randrange(4) if v is None else v
        cv = r.randrange(4) if cv is None else cv
        return 0x4A000000 | (sf << 19) | (mx << 17) | (v << 15) | (cv << 13) | (lm << 10) | opc

    def rand_cmd(self, opcs=None):
        return self.cmd_word(self.r.choice(opcs or VALID_OPC))

    # ---------------------------------------------------------------- register states
    def uniform_state(self):
        r = self.r
        return {reg: r.getrandbits(32) for reg in WRITABLE}

    def game_const(self):
        r = self.r
        s = {}

        def mat(base, lo, hi, row_norm=False):
            e = [r.randint(lo, hi) for _ in range(9)]
            s[base + 0] = p16(e[0], e[1])      # 11,12
            s[base + 1] = p16(e[2], e[3])      # 13,21
            s[base + 2] = p16(e[4], e[5])      # 22,23
            s[base + 3] = p16(e[6], e[7])      # 31,32
            s[base + 4] = p16(e[8], 0)         # 33

        mat(32, -0x1000, 0x1000)
        mat(40, -0x555, 0x555)
        mat(48, 0, 0x555)
        s[37] = r.randint(-0x800, 0x800)
        s[38] = r.randint(-0x800, 0x800)
        s[39] = r.randint(0x2000, 0x5000)
        for i in range(3):
            s[45 + i] = r.randint(0, 0x400)
            s[53 + i] = r.randint(0, 0xFFF)
        s[56] = (160 << 16) + r.randint(-0x10000, 0x10000)
        s[57] = (120 << 16) + r.randint(-0x10000, 0x10000)
        s[58] = r.randint(0x100, 0x400)
        s[59] = r.randint(-0x1000, 0x1000)
        s[60] = r.randint(0, 0x1000000)
        s[61] = r.randint(0x100, 0x200)
        s[62] = r.randint(0x80, 0x180)
        s[63] = 0
        s[30] = r.getrandbits(32)
        s[28] = r.getrandbits(15)
        return s

    def game_vary(self):
        r = self.r
        s = {}
        for base in (0, 2, 4):
            s[base] = p16(r.randint(-0x400, 0x400), r.randint(-0x400, 0x400))
            s[base + 1] = r.randint(-0x400, 0x400)
        s[6] = (r.randint(0x20, 0x3F) << 24) | (r.randint(0, 255) << 16) | (r.randint(0, 255) << 8) | r.randint(0, 255)
        s[7] = r.randint(0, 0x2000)
        s[8] = r.randint(0, 0x1000)
        for i in range(3):
            s[9 + i] = r.randint(0, 0x1000)
        for i in range(3):
            s[12 + i] = p16(r.randint(-0x200, 0x200), r.randint(-0x200, 0x200))
        for i in range(4):
            s[16 + i] = r.randint(0x200, 0x4000)
        for i in range(3):
            s[20 + i] = (r.randint(0x20, 0x3F) << 24) | r.getrandbits(24)
        s[23] = r.getrandbits(32)
        s[24] = r.randint(-0x1000, 0x1000)
        for i in range(3):
            s[25 + i] = r.randint(-0x1000, 0x1000)
        return s

    def game_state(self):
        s = self.game_const()
        s.update(self.game_vary())
        return s

    def ext16(self):
        return self.r.choice(EXT16)

    def ext32(self):
        return self.r.choice(EXT32)

    def emit_state(self, s):
        for reg in WRITABLE:
            if reg in s:
                self.write(reg, s[reg])

    # ---------------------------------------------------------------- edge scenarios
    def edge_state(self, kind):
        r = self.r
        s = self.game_state()
        e16, e32 = self.ext16, self.ext32

        def pk():
            return p16(e16(), e16())

        if kind == "mac":
            for reg in (32, 33, 34, 35, 40, 41, 42, 43, 48, 49, 50, 51, 0, 2, 4):
                s[reg] = pk()
            for reg in (36, 44, 52, 1, 3, 5, 9, 10, 11, 8):
                s[reg] = e16()
            for reg in (37, 38, 39, 45, 46, 47, 53, 54, 55, 25, 26, 27, 24):
                s[reg] = e32()
        elif kind == "ir":
            sign = r.choice((1, -1))
            for reg in (32, 33, 34, 35, 40, 41, 42, 43, 48, 49, 50, 51):
                s[reg] = p16(sign * r.randint(0x2000, 0x7FFF), r.choice((1, -1)) * r.randint(0x2000, 0x7FFF))
            for reg in (36, 44, 52):
                s[reg] = r.choice((1, -1)) * r.randint(0x2000, 0x7FFF)
            for base in (0, 2, 4):
                s[base] = p16(r.choice((1, -1)) * r.randint(0x400, 0x2000), r.choice((1, -1)) * r.randint(0x400, 0x2000))
                s[base + 1] = r.choice((1, -1)) * r.randint(0x400, 0x2000)
            for reg in (9, 10, 11):
                s[reg] = r.choice((1, -1)) * r.randint(0x4000, 0x7FFF)
            s[8] = r.choice((1, -1)) * r.randint(0x1000, 0x7FFF)
        elif kind == "color":
            for reg in (40, 41, 42, 43, 48, 49, 50, 51):
                s[reg] = p16(r.randint(-0x3000, 0x3000), r.randint(-0x3000, 0x3000))
            for reg in (44, 52):
                s[reg] = r.randint(-0x3000, 0x3000)
            for i in range(3):
                s[45 + i] = r.choice((1, -1)) * r.randint(0, 0x7FFFFFF)
            s[6] = (r.randint(0, 255) << 24) | (r.choice((0, 255, r.randint(0, 255))) * 0x010101)
            for reg in (9, 10, 11):
                s[reg] = r.choice((1, -1)) * r.randint(0x400, 0x7FFF)
        elif kind == "sz3":
            for reg in (35, 36):
                s[reg] = p16(r.choice((1, -1)) * r.randint(0x2000, 0x7FFF), r.choice((1, -1)) * r.randint(0x2000, 0x7FFF))
            s[39] = r.choice((e32(), r.randint(-0x20000, 0x20000) & 0xFFFFFFFF, 0xFFFF, 0x10000, 0xFFFFFFFF))
            s[58] = r.randint(0, 0xFFFF)
            s[61] = r.choice((0x7FFF, 0x8000, 0xFFFF, 0x1000, e16()))
            s[62] = r.choice((0x7FFF, 0x8000, 0xFFFF, 0x1000, e16()))
            for i in range(4):
                s[16 + i] = r.choice((0xFFFF, 0, r.getrandbits(16)))
        elif kind == "sxy":
            s[56] = e32()
            s[57] = e32()
            s[58] = r.randint(0x4000, 0xFFFF)
            s[39] = r.randint(0x100, 0x300)
            for reg in (35, 36):
                s[reg] = 0
            for reg in (9, 10, 11):
                s[reg] = e16()
            for base in (0, 2, 4):
                s[base] = p16(e16(), e16())
        elif kind == "div":
            for reg in range(32, 37):
                s[reg] = 0
            z = r.choice((0, 1, 2, 0x10, 0x100, 0x1234, 0x7FFF, 0xFFFF))
            s[39] = z
            h = r.choice((2 * z, 2 * z + 1, 2 * z - 1, 2 * z + 2, 0xFFFF, 0x8000, 0x7FFF, z, r.getrandbits(16)))
            s[58] = max(0, min(0xFFFF, h))
            for base in (0, 2, 4):
                s[base + 1] = 0
        elif kind == "zero":
            s = {reg: 0 for reg in WRITABLE}
        elif kind == "neg":
            for reg in WRITABLE:
                s[reg] = p16(-r.randint(1, 0x4000), -r.randint(1, 0x4000)) if reg < 56 else (-r.randint(1, 0x4000000)) & 0xFFFFFFFF
        elif kind == "dpc":
            for i in range(3):
                s[53 + i] = r.choice((0x7FFFFFFF, 0x80000000, 0x7FFFF000, 0x80001000, e32()))
            s[6] = (r.randint(0, 255) << 24) | r.choice((0xFFFFFF, 0, 0xFF00FF, r.getrandbits(24)))
            for reg in (20, 21, 22):
                s[reg] = (r.randint(0, 255) << 24) | r.choice((0xFFFFFF, 0, r.getrandbits(24)))
            s[8] = r.choice((0x1000, 0x7FFF, 0x8000, 0, 1, 0xFFFF, e16()))
            for reg in (9, 10, 11):
                s[reg] = e16()
            for reg in (25, 26, 27):
                s[reg] = r.choice((0x7FFFFFFF, 0x80000000, e32()))
        return s

    def edge_scenario(self):
        r = self.r
        kind = r.choices(["mac", "ir", "color", "sz3", "sxy", "div", "zero", "neg", "dpc"],
                         weights=[20, 15, 15, 8, 10, 8, 3, 3, 18])[0]
        st = self.edge_state(kind)
        if kind == "mac" or kind == "ir" or kind == "zero" or kind == "neg":
            opc = r.choice(VALID_OPC)
        elif kind == "color":
            opc = r.choice(COLOR_OPC)
        elif kind in ("sxy", "div"):
            opc = r.choice(RT_OPC)
        elif kind == "sz3":
            opc = r.choice(RT_OPC + [0x2D, 0x2E])
        else:
            opc = r.choice(DPC_OPC)
        self.emit_state(st)
        self.cmd(self.cmd_word(opc))

    # ---------------------------------------------------------------- suites
    def suite_directed(self, repeat):
        self.label(0)
        self.mode(0x2)
        for _ in range(repeat):
            for opc in range(64):
                for sf in (0, 1):
                    for lm in (0, 1):
                        st = self.uniform_state() if self.r.getrandbits(1) else self.game_state()
                        self.emit_state(st)
                        self.cmd(self.cmd_word(opc, sf=sf, lm=lm))
            for mx in range(4):
                for v in range(4):
                    for cv in range(4):
                        for sf in (0, 1):
                            for lm in (0, 1):
                                st = self.uniform_state() if self.r.getrandbits(1) else self.game_state()
                                self.emit_state(st)
                                self.cmd(self.cmd_word(0x12, sf=sf, lm=lm, mx=mx, v=v, cv=cv))

    def suite_edge(self, n):
        self.label(1)
        self.mode(0x2)
        for _ in range(n):
            self.edge_scenario()

    def suite_reset(self, n):
        self.label(2)
        self.mode(0x2)
        for _ in range(n):
            st = self.uniform_state() if self.r.getrandbits(1) else self.game_state()
            self.emit_state(st)
            for _ in range(self.r.randint(0, 2)):
                self.cmd(self.rand_cmd())
            if self.r.getrandbits(2) == 0:
                self.write(self.r.choice(WRITABLE), self.r.getrandbits(32))
            self.reset()
            self.dump()
            if self.r.getrandbits(1):
                self.cmd(self.rand_cmd())

    def suite_random(self, n_cmds):
        half = n_cmds // 2
        self.mode(0x2)
        self.label(4)
        r = self.r
        for i in range(half):
            if i % 16 == 0:
                self.emit_state(self.uniform_state())
            else:
                for reg in r.sample(WRITABLE, r.randint(6, 24)):
                    self.write(reg, r.getrandbits(32))
            self.cmd(self.cmd_word(r.choice(VALID_OPC)))
        self.label(5)
        const = None
        for i in range(n_cmds - half):
            if i % 8 == 0:
                const = self.game_const()
                self.emit_state(const)
            self.emit_state(self.game_vary())
            self.cmd(self.cmd_word(r.choice(VALID_OPC)))

    # ---------------------------------------------------------------- boundary suite
    # Every saturation point is driven to limit-1, limit and limit+1 on both sides. Each case rewrites
    # every input register, so no case depends on an earlier one; registers that are not inputs of the
    # command get random values.
    BND_NOISE = (7, 12, 13, 14, 15, 20, 21, 22, 23, 24, 25, 26, 27, 30, 63)
    BND_REGS = [r for r in WRITABLE if r != 28]

    def bnd_case(self, word, regs):
        r = self.r
        for reg in self.BND_REGS:
            if reg == 6:
                v = (regs.get(6, 0) & 0xFFFFFF) | (r.getrandbits(8) << 24)
            elif reg in regs:
                v = regs[reg]
            elif reg in self.BND_NOISE:
                v = r.getrandbits(32)
            else:
                v = 0
            self.write(reg, v)
        self.cmd(word)

    @staticmethod
    def set_half(regs, reg, hi, val):
        old = regs.get(reg, 0)
        if hi:
            regs[reg] = (old & 0xFFFF) | ((val & 0xFFFF) << 16)
        else:
            regs[reg] = (old & 0xFFFF0000) | (val & 0xFFFF)

    def set_mat(self, regs, base, i, j, val):
        e = 3 * i + j
        self.set_half(regs, base + e // 2, e & 1, val)

    def set_vec(self, regs, v, k, val):
        if k == 2:
            regs[2 * v + 1] = val & 0xFFFF
        else:
            self.set_half(regs, 2 * v, k, val)

    def fac_exact(self, t):
        """(a, b) with a*b == t, both int16."""
        r = self.r
        if t == 0:
            return (r.randint(-32768, 32767), 0) if r.getrandbits(1) else (0, r.randint(-32768, 32767))
        cand = []
        for d in range(1, isqrt(abs(t)) + 1):
            if abs(t) % d == 0:
                for a in (d, abs(t) // d):
                    for a2 in (a, -a):
                        b = t // a2
                        if -32768 <= a2 <= 32767 and -32768 <= b <= 32767 and a2 * b == t:
                            cand.append((a2, b))
        return r.choice(cand)

    def fac_range(self, lo, hi):
        """(a, b), int16, with lo <= a*b <= hi."""
        cand = []
        for a in range(1, 32768):
            b = -(-lo // a)
            if -32768 <= b <= 32767 and a * b <= hi:
                cand.append((a, b))
        return self.r.choice(cand)

    def prod(self, t, sf):
        """(a, b) with (a*b) >> (12 if sf else 0) == t."""
        if sf:
            return self.fac_range(t << 12, (t << 12) + 4095)
        return self.fac_exact(t)

    def split(self, s, k):
        r = self.r
        parts = []
        for i in range(k - 1):
            left = k - 1 - i
            parts.append(r.randint(max(0, s - 0xFFFF * left), min(0xFFFF, s)))
            s -= parts[-1]
        parts.append(s)
        r.shuffle(parts)
        return parts

    IR_T = [-32770, -32769, -32768, -32767, -2, -1, 0, 1, 2, 32766, 32767, 32768, 32769, 32770]
    RGB_T = [-17, -16, -1, 0, 1, 15, 16, 4079, 4080, 4095, 4096, 4097, 4111, 4112]
    OFS_T = [-0x4010000, -0x4000001, -0x4000000, -0x3FFFFFF, -0x3FF0000,
             0x3FEFFFF, 0x3FFFFFF, 0x4000000, 0x4000001, 0x400FFFF, 0x4010000]

    def bnd_gpf(self):
        # GPF: MACn = IRn*IR0 >> sf. IR1-3 clamp and flags (lm 0/1), colour clamp and flags 21..19
        for ch in range(3):
            for t in self.IR_T + self.RGB_T:
                for sf in (0, 1):
                    for lm in (0, 1):
                        a, b = self.prod(t, sf)
                        self.bnd_case(self.cmd_word(0x3D, sf=sf, lm=lm), {8: a, 9 + ch: b})

    def bnd_mvmva_ir(self):
        # MVMVA with no translation (cv 3) and with the FC path (cv 2): one product placed in each column
        for cv in (3, 2):
            for ch in range(3):
                for t in self.IR_T[1:-1]:
                    for sf in (0, 1):
                        lm = self.r.getrandbits(1)
                        col = self.r.randrange(3)
                        mx = self.r.randrange(3)
                        v = self.r.randrange(3)
                        a, b = self.prod(t, sf)
                        regs = {}
                        self.set_mat(regs, (32, 40, 48)[mx], ch, col, a)
                        self.set_vec(regs, v, col, b)
                        self.bnd_case(self.cmd_word(0x12, sf=sf, lm=lm, mx=mx, v=v, cv=cv), regs)

    def bnd_mac123(self):
        # MVMVA with TR/BK: TR*0x1000 sits at -2^43 or 2^43-4096, a product in one column moves it across the limit
        for ch in range(3):
            for base, sums in ((0x7FFFFFFF, (4094, 4095, 4096)), (0x80000000, (-1, 0, 1))):
                for s in sums:
                    for col in range(3):
                        for sf in (0, 1):
                            cv = self.r.randrange(2)
                            mx = self.r.randrange(3)
                            v = self.r.randrange(3)
                            a, b = self.fac_exact(s)
                            regs = {(37, 45)[cv] + ch: base}
                            self.set_mat(regs, (32, 40, 48)[mx], ch, col, a)
                            self.set_vec(regs, v, col, b)
                            self.bnd_case(self.cmd_word(0x12, sf=sf, lm=self.r.getrandbits(1), mx=mx, v=v, cv=cv), regs)

    def bnd_rtps(self):
        r = self.r
        rnd_v = lambda: {0: r.getrandbits(32), 1: r.getrandbits(16)}
        # IR0 = MAC0 >> 12 clamp 0..0x1000 (flag 12); MAC0 = DQB with DQA 0
        for t in (-4097, -4096, -4095, -1, 0, 1, 4095, 4096, 0xFFFFFF, 0x1000000, 0x1000FFF, 0x1001000, 0x1001001,
                  -0x7FFFFFFF, 0x7FFFFFFF):
            regs = rnd_v()
            regs.update({58: r.randint(1, 0xFFFF), 60: t})
            self.bnd_case(self.cmd_word(0x01), regs)
        # MAC0 32-bit overflow (flags 16/15): the divide overflows (SZ3 = 0), so q = 0x1FFFF and MAC0 = DQB + DQA*q
        for t in (0x7FFFFFFE, 0x7FFFFFFF, 0x80000000, 0x80000001, -0x80000002, -0x80000001, -0x80000000, -0x7FFFFFFF):
            for _ in range(2):
                dqa = r.randint(1, 16000) * (1 if t > 0 else -1)
                regs = rnd_v()
                regs.update({58: r.randint(1, 0xFFFF), 59: dqa, 60: (t - dqa * 0x1FFFF) & 0xFFFFFFFF})
                self.bnd_case(self.cmd_word(0x01), regs)
        # SZ3 clamp (flag 18) and IR3 flag, whose range check always uses the lower limit -32768: MAC3 = TRZ << 12
        for t in (-32770, -32769, -32768, -32767, -2, -1, 0, 1, 32766, 32767, 32768, 32769,
                  65534, 65535, 65536, 65537):
            for sf in (0, 1):
                for lm in (0, 1):
                    regs = rnd_v()
                    regs.update({58: r.randint(0, 0xFFFF), 39: t})
                    self.bnd_case(self.cmd_word(0x01, sf=sf, lm=lm), regs)
        # divide overflow (flag 17) when H >= 2*SZ3
        for s in (0, 1, 2, 3, 0x100, 0x1234, 0x4000, 0x7FFE, 0x7FFF, 0x8000, 0xFFFF):
            for h in (2 * s - 1, 2 * s, 2 * s + 1, s, 0, 0xFFFF):
                if 0 <= h <= 0xFFFF:
                    regs = rnd_v()
                    regs.update({58: h, 39: s})
                    self.bnd_case(self.cmd_word(0x01), regs)
        # SX2/SY2 clamp to -1024..1023 (flags 14/13): MAC0 = OFX / OFY, SX = MAC0 >> 16
        for i, x in enumerate(self.OFS_T):
            for k in range(len(self.OFS_T)):
                y = self.OFS_T[(i + 3 * k) % len(self.OFS_T)]
                regs = rnd_v()
                regs.update({56: x, 57: y, 58: r.randint(0, 0xFFFF)})
                self.bnd_case(self.cmd_word(0x01), regs)

    def bnd_otz(self):
        r = self.r
        sums = [0, 1, 2, 0xFFFE, 0xFFFF, 0x10000, 0x10001]
        for opc, n, zreg in ((0x2D, 3, 61), (0x2E, 4, 62)):
            first = 20 - n

            def go(z, s):
                regs = {zreg: z}
                for reg, part in zip(range(first, 20), self.split(s, n)):
                    regs[reg] = part
                if n == 3:
                    regs[16] = r.getrandbits(16)
                self.bnd_case(self.cmd_word(opc), regs)

            for s in sums:
                go(0x1000, s)
            for s in (0, 1, 2, 3):
                go(-0x1000, s)
            for t in (0xFFFF000, 0xFFFFFFF, 0x10000000):
                for _ in range(2):
                    z = r.randint(1366, 4095)
                    go(z, t // z)
                    go(z, -(-t // z))
            go(-1, 1)
            go(-r.randint(2, 4095), 1)

    def bnd_flag(self):
        # CPU write of FLAG (CTC2 63) read back before any command: bits 31..12 are stored, bit 31 is derived
        vals = [1 << b for b in range(32)] + [0xFFFFFFFF ^ (1 << b) for b in range(32)]
        vals += [0, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 0x7F87E000, 0x7F86E000, 0x00001000, 0x00FF0000,
                 0x7F800000, 0x0007E000, 0x00780000]
        for v in vals:
            self.write(63, v)
            self.read(63)
        self.write(63, 0)
        self.dump()

    def suite_boundary(self):
        self.label(7)
        self.mode(0x2)
        self.bnd_flag()
        self.bnd_gpf()
        self.bnd_mvmva_ir()
        self.bnd_mac123()
        self.bnd_rtps()
        self.bnd_otz()

    # CPU-timing streams
    def cpu_gap(self):
        r = self.r
        x = r.random()
        if x < 0.45:
            return 0
        if x < 0.85:
            return r.randint(1, 8)
        if x < 0.97:
            return r.randint(9, 40)
        return r.randint(41, 150)

    def cpu_stream(self, n_ops, race_weight=1.0):
        r = self.r
        self.label(3)
        self.mode(0x1)
        self.emit_state(self.game_state() if r.getrandbits(1) else self.uniform_state())
        since_dump = 0
        ops = 0
        while ops < n_ops:
            x = r.random()
            if x < 0.30:                       # write, often read back at once
                reg = r.choice(WRITABLE)
                self.write(reg, r.getrandbits(32))
                ops += 1
                if r.random() < 0.45:
                    self.gap(0 if r.random() < 0.8 else r.randint(1, 3))
                    self.read(reg)
                    ops += 1
            elif x < 0.55:                     # command, optionally with a result read
                self.cmd(self.rand_cmd())
                ops += 1
                if r.random() < 0.3:
                    self.gap(self.cpu_gap() if r.random() < 0.3 else 0)
                    self.read(r.choice((24, 25, 26, 27, 63, 9, 10, 11, 14, 19, 7, 22)))
                    ops += 1
            elif x < 0.65:                     # back-to-back commands
                for _ in range(r.randint(2, 5)):
                    self.cmd(self.rand_cmd())
                    ops += 1
                    if r.random() < 0.3:
                        self.gap(r.randint(0, 3))
            elif x < 0.73:                     # write burst then command at gap 0
                for _ in range(r.randint(1, 8)):
                    self.write(r.choice(WRITABLE), r.getrandbits(32))
                    ops += 1
                self.cmd(self.rand_cmd())
                ops += 1
            elif x < 0.80:                     # single random-register reads
                self.read(r.choice(WRITABLE + [29, 31]))
                ops += 1
            elif x < 0.83:                     # write and read strobes on the same edge
                self.wr_rd(r.choice(range(64)), r.getrandbits(32), same=r.random() < 0.7)
                ops += 1
            elif x < 0.84:                     # writes to read-only 29/31, LZCS extremes read back via 31
                reg = r.choice((29, 31, 30, 30, 30))
                self.write(reg, r.choice((0, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 1, 0x00010000, 0xFFFE0000))
                           if reg == 30 else r.getrandbits(32))
                self.read(31 if reg == 30 else reg)
                ops += 2
            elif x < 0.85:
                self.pause_reset(r.choice((2, 3, 5, 9)))
                ops += 1
            elif x < 0.88:
                self.reset()
                ops += 1
            elif x < 0.91:
                self.pause(r.choice((1, 1, 2, 3, 5, 9, 17)))
                ops += 1
            elif x < 0.91 + 0.06 * race_weight:     # race pause on the next command or write
                self.race(r.choice((1, 2, 3, 6, 12)))
                if r.random() < 0.8:
                    self.cmd(self.rand_cmd())
                else:
                    self.write(r.choice(WRITABLE), r.getrandbits(32))
                ops += 1
            elif x < 0.99:
                self.apause(r.choice((1, 2, 4, 8)))
                ops += 1
            else:
                self.dump()
                ops += 1
            g = self.cpu_gap()
            if g:
                self.gap(g)
            since_dump += 1
            if since_dump > 250:
                self.dump()
                since_dump = 0
        self.dump()

    def suite_smoke(self):
        r = self.r
        self.label(6)
        self.mode(0x2)
        seq_ops = [0x01, 0x30, 0x13, 0x12, 0x10, 0x3E, 0x2D, 0x28, 0x06, 0x0C, 0x11, 0x1C, 0x3F, 0x2E, 0x14, 0x01]
        for opc in seq_ops:
            self.emit_state(self.game_state())
            self.cmd(self.cmd_word(opc, sf=1, lm=0))
        self.emit_state(self.game_state())
        self.mode(0x1)
        # cpu section: every command is followed by a read of MAC0
        for i in range(16):
            self.write(r.choice(WRITABLE), r.getrandbits(32))
            self.gap(r.randint(0, 2))
            if i % 4 == 1:
                self.race(3)
            self.cmd(self.cmd_word(r.choice((0x01, 0x30, 0x06, 0x28, 0x10, 0x13)), sf=1, lm=0))
            self.gap(r.randint(0, 2))
            self.read(24)
            if i % 5 == 3:
                self.pause(2)
            self.gap(r.randint(0, 3))
        self.dump()
        return len(seq_ops)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--suite", required=True, choices=["directed", "edge", "reset", "cpu", "random", "smoke", "boundary"])
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--count", type=int, default=1000000, help="random suite: number of commands")
    ap.add_argument("--shard", default="0/1", help="random suite: i/n, count is split over n shards")
    ap.add_argument("--directed-repeat", type=int, default=1)
    ap.add_argument("--edge-count", type=int, default=4000)
    ap.add_argument("--reset-count", type=int, default=300)
    ap.add_argument("--cpu-count", type=int, default=20000, help="cpu suite: number of operations")
    ap.add_argument("--race-weight", type=float, default=1.0)
    ap.add_argument("--out", default="-")
    a = ap.parse_args()

    si, sn = (int(x) for x in a.shard.split("/"))
    count = a.count // sn + (1 if si < a.count % sn else 0)
    f = sys.stdout if a.out == "-" else open(a.out, "w")
    g = Gen(a.seed * 1000003 + si, f)
    if a.suite == "directed":
        g.suite_directed(a.directed_repeat)
    elif a.suite == "edge":
        g.suite_edge(a.edge_count)
    elif a.suite == "reset":
        g.suite_reset(a.reset_count)
    elif a.suite == "cpu":
        g.cpu_stream(a.cpu_count, a.race_weight)
    elif a.suite == "random":
        g.suite_random(count)
    elif a.suite == "boundary":
        g.suite_boundary()
        sys.stderr.write("boundary cmds=%d\n" % g.n_cmd)
    elif a.suite == "smoke":
        n = g.suite_smoke()
        sys.stderr.write("smoke seq_cmds=%d total_cmds=%d\n" % (n + 0, g.n_cmd))
    g.flush()
    if f is not sys.stdout:
        f.close()


if __name__ == "__main__":
    main()
