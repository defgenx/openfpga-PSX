#!/usr/bin/env python3
"""Program image generator for the CPU differential harness.

usage: gen_prog.py --suite SUITE --seed N --out image.txt [--no-cop0-debug] [--size N]

SUITE: directed  hand-built streams, every opcode and the hazard cases (load-use, delay slots, exceptions, COP0,
                 GTE transfers, cache isolation, aliased code addresses); the seed varies operands and layout
       edge      operand matrix: every ALU/shift/mult/div/slt op over the edge values
       random    random instruction soup with hazard macros
       exc       random soup with a high rate of exceptions, interrupts and SR changes
       cache     random soup over aliased code addresses, partial lines, KSEG1 code and isolation
       gte       random soup weighted to COP2 transfers and commands
       wild      random instruction words (COP0 forms the golden asserts on are repaired), branches and jumps anywhere
       smoke     a short mixed program

Image: lines "AAAAAAAA DDDDDDDD" (physical byte address, word); the testbench maps RAM below 0x800000 (2 MB mirrored)
and the BIOS at 0x1FC00000. Memory map: reset code at BIOS+0 (KSEG1), exception vectors 0x40/0x80 (BEV=0) and
BIOS+0x180 (BEV=1), resume override word at 0x1000, code from 0x10000, data from 0x20000.
Register use: r15 jump target helper, r18-r25 bases, r26/r27 exception handler. --no-cop0-debug excludes the COP0
breakpoint registers (BPC, BDA, DCIC, BDAM, BPCM) from every stream: the NO_COP0_DEBUG stimulus mask.
"""
import argparse
import random
import sys

from isa import *  # noqa: F401,F403

MAIN = 0x10000
CODE_BASE = 0x40000
DATA = 0x20000
SNIP = 0x30000
BIOS = 0x1FC00000
RESUME = 0x1000

EDGE = [0, 1, 2, 3, 0x7F, 0x80, 0xFF, 0x100, 0x7FF, 0x800, 0xFFF, 0x1000, 0x7FFF, 0x8000, 0xFFFF, 0x10000,
        0x12345678, 0x55555555, 0xAAAAAAAA, 0x7FFFFFFF, 0x80000000, 0x80000001, 0xFFFFFFFF, 0xFFFFFFFE,
        0xFFFF8000, 0xFFFF0000, 0xFFF00000, 0xFFFFF800, 0x000FFFFF, 0x0000F000, 0x3FFFFFFF, 0xC0000000]

SR_POOL = [0x40000001, 0x40000401, 0x40000000, 0x00000401, 0x40000F01, 0x400004C1, 0x50000403, 0x50000401,
           0x40010401, 0x40400001, 0x40400401, 0x00000001, 0x40000301, 0x40000701, 0x40020401, 0x60000401]

BASES = {
    18: 0xBFC00400, 19: 0x1FC00400, 20: 0x80020000, 21: 0xA0020000, 22: 0x1F800000, 23: 0x9F800000, 24: 0xBF801000,
    25: 0xFFFE0100,
}
WORK = list(range(1, 15)) + [16, 17, 28, 29, 30, 31]
DEBUG_REGS = (C0_BPC, C0_BDA, C0_DCIC, C0_BDAM, C0_BPCM)
ALLOW_BP = False


class Image:
    def __init__(self):
        self.mem = {}

    def place(self, addr, words):
        for i, w in enumerate(words):
            self.mem[addr + 4 * i] = w & 0xFFFFFFFF

    def write(self, path):
        with open(path, "w") as f:
            for a in sorted(self.mem):
                f.write("%08X %08X\n" % (a, self.mem[a]))


def handler():
    c = Code()
    c.emit(MFC0(K0, C0_CAUSE), NOP, MTC0(R0, C0_CAUSE))
    c.emit(ANDI(K0, K0, 0x7C), MFC0(K1, C0_EPC), NOP)
    c.br(lambda o: BEQ(K0, R0, o), "ret")
    c.emit(NOP)
    c.emit(LW(K0, RESUME, R0), ADDIU(K1, K1, 4), NOP)
    c.br(lambda o: BEQ(K0, R0, o), "ret")
    c.emit(NOP)
    c.emit(ADDU(K1, K0, R0))
    c.label("ret")
    c.emit(JR(K1), RFE)
    return c.link()


def prelude(rng, sr, entry_addr):
    c = Code()
    c.emit(li(1, sr), MTC0(1, C0_SR), NOP)
    for r, v in BASES.items():
        c.emit(li(r, v))
    for r in WORK:
        c.emit(li(r, rng.choice(EDGE) if rng.random() < 0.5 else rng.getrandbits(32)))
    c.emit(MTHI(1), MTLO(2))
    c.emit(li(15, entry_addr), JR(15), NOP)
    return c.link()


def alias_addr(rng, phys, kinds="all"):
    """An address that runs the same physical code through a different cache tag or segment."""
    opts = [0x80000000, 0x00000000, 0xA0000000, 0x80200000, 0x80400000, 0x80600000, 0x00200000, 0x00400000, 0x00600000]
    if kinds == "cached":
        opts = [o for o in opts if (o >> 29) != 5]
    return rng.choice(opts) | phys


class Soup:
    """Random instruction soup. Branch targets are forward inside the block; the block ends with a jump out."""

    def __init__(self, rng, nodebug, w):
        self.rng = rng
        self.nodebug = nodebug
        self.w = w       # weight dict
        self.c = Code()
        self.want = {}   # slot -> label
        self.nlab = 0

    def reg(self):
        return self.rng.choice(WORK)

    def src(self):
        r = self.rng.random()
        if r < 0.08:
            return 0
        if r < 0.12:
            return self.rng.choice([15, 20, 21])
        return self.rng.choice(WORK)

    def off(self, size, base):
        rng = self.rng
        if base in (18, 19, 20, 21):
            o = rng.randrange(-64, 0x3FF)
        elif base in (22, 23):
            o = rng.randrange(0, 0x41F) if rng.random() < 0.1 else rng.randrange(0, 0x3FF)
        elif base == 24:
            o = rng.randrange(0, 0x60)
        else:
            o = rng.choice([0x30, 0x30, 0x30, 0x2C, 0x34, 0, 0x10, 0x31])
        if rng.random() < 0.9:
            o &= ~(size - 1)
        return o

    def mem_addr(self, size, store=False):
        rng = self.rng
        if rng.random() < 0.02:
            return R0, rng.choice([0x300, 0x300, 0x304, 0x2FC, 0x80, 0xFFC, 0x0]) & ~(size - 1 if rng.random() < 0.9 else 0)
        pool = [18, 19, 20, 20, 20, 21, 21, 22, 22, 23, 24, 25] if not store else [20, 20, 20, 21, 21, 22, 22, 23, 24, 25]
        base = rng.choice(pool)
        return base, self.off(size, base)

    def branch_target(self, i, n):
        if i + 3 >= n:
            return None
        j = self.rng.randrange(i + 2, min(n, i + 40))
        if j not in self.want:
            self.nlab += 1
            self.want[j] = "L%d" % self.nlab
        return self.want[j]

    def debug_value(self, reg):
        rng = self.rng
        if reg == C0_DCIC:
            # a breakpoint match livelocks the CPU until the next reset: enabled only where the suite resets
            if not ALLOW_BP or rng.random() < 0.8:
                return rng.getrandbits(32) & 0x007F0F3F      # enable bits clear
            return 0xE1800000 | (rng.getrandbits(32) & 0x007F0F3F)
        if reg == C0_BPCM:
            return rng.choice([0xFFFFFFFF, 0xFFFFFFF0, 0xFFFFF000, 0xFFFFFFFC, 0xFFFFFFFF, 0xFFFF0000])
        if reg == C0_BPC:
            return rng.choice([0x80010000, 0x80010004, 0x80010010, 0x80010100]) + 4 * rng.randrange(0, 64)
        return rng.getrandbits(32)

    def cop0_reg(self):
        rng = self.rng
        while True:
            r = rng.choice([3, 5, 6, 7, 8, 9, 11, 12, 12, 13, 13, 14, 15, 0, 1, 2, 4, 10, 16, 31])
            if self.nodebug and r in DEBUG_REGS:
                continue
            return r

    def one(self, i, n):
        """Emit one random unit starting at slot i; returns the number of slots used (1)."""
        rng, c, w = self.rng, self.c, self.w
        kinds = list(w.keys())
        k = rng.choices(kinds, [w[x] for x in kinds])[0]
        rd, rs, rt = self.reg(), self.src(), self.src()
        if k == "alu_r":
            f = rng.choice([0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2A, 0x2B])
            c.emit(R(f, rs, rt, rd))
        elif k == "alu_i":
            op = rng.choice([0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E])
            imm = rng.choice([0, 1, 0x7FFF, 0x8000, 0xFFFF, 0xFFFE, 0x1234, rng.getrandbits(16)])
            c.emit(I(op, rs, rd, imm))
        elif k == "lui":
            c.emit(LUI(rd, rng.choice([0, 0x7FFF, 0x8000, 0xFFFF, rng.getrandbits(16)])))
        elif k == "shift":
            f = rng.choice([0x00, 0x02, 0x03, 0x04, 0x06, 0x07])
            c.emit(R(f, rs, rt, rd, rng.choice([0, 1, 7, 15, 16, 31, rng.getrandbits(5)])))
        elif k == "muldiv":
            f = rng.choice([0x18, 0x19, 0x1A, 0x1B])
            c.emit(R(f, rs, rt))
        elif k == "hilo":
            f = rng.choice([0x10, 0x12, 0x10, 0x12, 0x11, 0x13])
            if f in (0x10, 0x12):
                c.emit(R(f, 0, 0, rd))
            else:
                c.emit(R(f, rs))
        elif k == "load":
            op = rng.choice([0x20, 0x21, 0x22, 0x23, 0x23, 0x24, 0x25, 0x26])
            size = {0x20: 1, 0x24: 1, 0x21: 2, 0x25: 2}.get(op, 4)
            base, off = self.mem_addr(size)
            c.emit(I(op, base, rd, off))
        elif k == "store":
            op = rng.choice([0x28, 0x29, 0x2A, 0x2B, 0x2B, 0x2E])
            size = {0x28: 1, 0x29: 2}.get(op, 4)
            base, off = self.mem_addr(size, True)
            c.emit(I(op, base, rt, off))
        elif k == "branch":
            lab = self.branch_target(i, n)
            if lab is None:
                c.emit(NOP)
                return 1
            b = rng.choice(["beq", "bne", "blez", "bgtz", "regimm", "beq", "bne"])
            if b == "beq":
                c.br(lambda o, a=rs, t=rt: BEQ(a, t, o), lab)
            elif b == "bne":
                c.br(lambda o, a=rs, t=rt: BNE(a, t, o), lab)
            elif b == "blez":
                c.br(lambda o, a=rs: BLEZ(a, o), lab)
            elif b == "bgtz":
                c.br(lambda o, a=rs: BGTZ(a, o), lab)
            else:
                rtf = rng.choice([0, 1, 16, 17, rng.getrandbits(5)])
                c.br(lambda o, a=rs, t=rtf: I(0x01, a, t, o), lab)
            # delay slot: any simple instruction, occasionally a hazard or a branch
            r = rng.random()
            if r < 0.05:
                c.emit(I(0x23, 20, rd, self.off(4, 20)))
            elif r < 0.08:
                c.emit(R(0x20, rs, rt, rd))
            elif r < 0.10:
                c.emit(BEQ(rs, rt, 1))
            else:
                c.emit(R(rng.choice([0x21, 0x25, 0x24, 0x2A]), self.src(), self.src(), self.reg()))
            return 2
        elif k == "jump":
            # jr/jalr r15 to a forward label in this block: bgezal r0,+1 ; nop ; addiu r15,r31,delta
            lab = self.branch_target(i + 4, n)
            if lab is None:
                c.emit(NOP)
                return 1
            c.emit(BGEZAL(0, 1), NOP)
            c.fix.append((len(c.w), lab, None))
            c.w.append(0)
            self.fixups15 = getattr(self, "fixups15", [])
            c.emit(rng.choice([JR(15), JALR(rng.choice([16, 17, 31]), 15)]), rng.choice([NOP, ADDU(rd, rs, rt), SLT(rd, rs, rt)]))
            return 5
        elif k == "cop0":
            r = rng.random()
            reg = self.cop0_reg()
            if r < 0.45:
                c.emit(MFC0(rd, reg))
            elif r < 0.60 and reg == C0_SR:
                c.emit(li(rt if rt else 1, rng.choice(SR_POOL)), MTC0(rt if rt else 1, C0_SR))
                return 3
            elif r < 0.70 and reg == C0_CAUSE:
                c.emit(li(1, rng.choice([0, 0x100, 0x200, 0x300])), MTC0(1, C0_CAUSE))
                return 3
            elif r < 0.95:
                if reg in (C0_SR, C0_CAUSE):
                    c.emit(MFC0(rd, reg))
                elif reg in DEBUG_REGS:
                    c.emit(li(1, self.debug_value(reg)), MTC0(1, reg))
                    return 3
                else:
                    c.emit(MTC0(rt, reg))
            else:
                c.emit(RFE)
        elif k == "cop2":
            r = rng.random()
            if r < 0.25:
                c.emit(MFC2(rd, rng.getrandbits(5)))
            elif r < 0.40:
                c.emit(CFC2(rd, rng.getrandbits(5)))
            elif r < 0.60:
                c.emit(MTC2(rt, rng.getrandbits(5)))
            elif r < 0.72:
                c.emit(CTC2(rt, rng.getrandbits(5)))
            elif r < 0.84:
                c.emit(COP2CMD(rng.getrandbits(25)))
            elif r < 0.92:
                base, off = self.mem_addr(4)
                c.emit(LWC2(rng.getrandbits(5), off, base))
            else:
                base, off = self.mem_addr(4, True)
                c.emit(SWC2(rng.getrandbits(5), off, base))
        elif k == "copnop":
            c.emit(rng.choice([I(0x11, rng.getrandbits(5), rng.getrandbits(5), rng.getrandbits(16)),
                               I(0x13, rng.getrandbits(5), rng.getrandbits(5), rng.getrandbits(16)),
                               I(rng.choice([0x30, 0x31, 0x33, 0x38, 0x39, 0x3B]), 20, rng.getrandbits(5), 0x10)]))
        elif k == "excite":
            r = rng.random()
            if r < 0.3:
                c.emit(SYSCALL if rng.random() < 0.5 else BREAK)
            elif r < 0.6:
                c.emit(rng.choice([R(0x20, rs, rt, rd), R(0x22, rs, rt, rd), ADDI(rd, rs, 0x7FFF)]))
            else:
                c.emit(rng.choice([I(0x23, 20, rd, 0x1E + rng.randrange(0, 3)), I(0x2B, 20, rt, 0x22 + rng.randrange(0, 3)),
                                   I(0x21, 21, rd, 0x11), I(0x29, 21, rt, 0x13)]))
        elif k == "illegal":
            r = rng.random()
            if r < 0.4:
                c.emit(I(rng.choice([0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x27, 0x2C, 0x2D,
                                     0x2F, 0x34, 0x35, 0x36, 0x37, 0x3C, 0x3D, 0x3E, 0x3F]), rs, rt, rng.getrandbits(16)))
            elif r < 0.7:
                c.emit(R(rng.choice([0x01, 0x05, 0x0A, 0x0B, 0x0E, 0x0F, 0x14, 0x15, 0x16, 0x17, 0x1C, 0x1D, 0x28, 0x29, 0x2C, 0x30,
                                     0x3F]), rs, rt, rd, rng.getrandbits(5)))
            else:
                c.emit(I(0x10, 16, 0, rng.choice([1, 2, 4, 8])))
        elif k == "hazard":
            return self.hazard(i, n)
        else:
            c.emit(NOP)
        return 1

    def hazard(self, i, n):
        rng, c = self.rng, self.c
        k = rng.choice(["loaduse", "lwlwr", "stld", "muldiv", "gte", "ldld", "edge", "ldbase", "isolate", "mthi"])
        rd = self.reg()
        if k == "loaduse":
            base, off = self.mem_addr(4)
            c.emit(I(0x23, base, rd, off & ~3))
            for _ in range(rng.choice([0, 0, 1, 2])):
                c.emit(R(0x21, self.src(), self.src(), self.reg()))
            c.emit(rng.choice([R(0x21, rd, self.src(), self.reg()), R(0x25, self.src(), rd, self.reg()),
                               SW(rd, 8, 20), BEQ(rd, 0, 0), I(0x23, rd, self.reg(), 0)]))
            return 4
        if k == "lwlwr":
            base = rng.choice([20, 21, 22, 23])
            off = rng.randrange(0, 0x3F0)
            c.emit(I(0x22, base, rd, off + 3), I(0x26, base, rd, off))
            if rng.random() < 0.5:
                c.emit(R(0x21, rd, rd, self.reg()))
            return 3
        if k == "stld":
            base = rng.choice([20, 21, 22, 23])
            off = rng.randrange(0, 0x3F0) & ~3
            st = rng.choice([SW, SH, SB, SWL, SWR])
            ld = rng.choice([LW, LH, LBU, LB, LHU, LWL, LWR])
            c.emit(st(self.src(), off + rng.choice([0, 0, 1, 2, 3]), base))
            for _ in range(rng.choice([0, 0, 1])):
                c.emit(NOP)
            c.emit(ld(rd, off + rng.choice([0, 0, 1, 2, 3]), base))
            return 3
        if k == "muldiv":
            f = rng.choice([0x18, 0x19, 0x1A, 0x1B])
            c.emit(R(f, self.src(), self.src()))
            for _ in range(rng.choice([0, 1, 2, 4, 6, 8, 12, 14, 20, 30, 36])):
                c.emit(R(0x21, self.src(), self.src(), self.reg()) if rng.random() < 0.8 else NOP)
            c.emit(rng.choice([MFHI(rd), MFLO(rd), MTHI(self.src()), MTLO(self.src()), R(f, self.src(), self.src()), MFLO(rd)]))
            if rng.random() < 0.5:
                c.emit(rng.choice([MFHI(rd), MFLO(rd), R(0x21, rd, rd, rd)]))
            return 4
        if k == "gte":
            c.emit(COP2CMD(rng.getrandbits(25)))
            for _ in range(rng.choice([0, 0, 1, 3])):
                c.emit(R(0x21, self.src(), self.src(), self.reg()))
            r = rng.random()
            if r < 0.3:
                c.emit(MTC2(self.src(), rng.getrandbits(5)))
            elif r < 0.5:
                c.emit(MFC2(rd, rng.getrandbits(5)), R(0x21, rd, rd, rd))
            elif r < 0.65:
                c.emit(CTC2(self.src(), rng.getrandbits(5)))
            elif r < 0.8:
                c.emit(COP2CMD(rng.getrandbits(25)))
            elif r < 0.9:
                base, off = self.mem_addr(4)
                c.emit(LWC2(rng.getrandbits(5), off & ~3, base))
            else:
                base, off = self.mem_addr(4, True)
                c.emit(SWC2(rng.getrandbits(5), off & ~3, base))
            return 4
        if k == "ldld":
            base, off = self.mem_addr(4)
            r2 = self.reg()
            c.emit(I(0x23, base, rd, off & ~3), I(rng.choice([0x23, 0x24, 0x22]), base, rng.choice([rd, r2]), (off + 4) & ~3 & 0xFFFF))
            if rng.random() < 0.6:
                c.emit(R(0x21, rd, r2, self.reg()))
            return 3
        if k == "edge":
            c.emit(li(rd, rng.choice(EDGE)))
            return 2
        if k == "ldbase":
            c.emit(I(0x23, 20, rd, rng.randrange(0, 0x3F0) & ~3), I(0x23, rd, self.reg(), 0))
            return 2
        if k == "isolate":
            c.emit(li(1, 0x40010401), MTC0(1, C0_SR), NOP)
            for _ in range(rng.choice([1, 2, 3])):
                base, off = self.mem_addr(4, True)
                c.emit(SW(self.src(), off & ~3, rng.choice([20, 21, 20])))
            c.emit(li(1, rng.choice([0x40000401, 0x40000001])), MTC0(1, C0_SR), NOP)
            return 8
        if k == "mthi":
            c.emit(R(rng.choice([0x18, 0x19, 0x1A, 0x1B]), self.src(), self.src()))
            for _ in range(rng.randrange(0, 16)):
                c.emit(NOP)
            c.emit(rng.choice([MTHI(self.src()), MTLO(self.src())]), rng.choice([MFHI(rd), MFLO(rd)]))
            return 4
        c.emit(NOP)
        return 1

    def build(self, n):
        c = self.c
        i = 0
        while i < n:
            if i in self.want:
                c.label(self.want[i])
            used = self.one(i, n)
            i += max(1, used)
        # labels beyond the end land on the tail
        for j, lab in self.want.items():
            if lab not in c.labels:
                c.label(lab)
        return c


def resolve_jump_fixups(c, rng):
    """The 'jump' macro leaves (index, label, None) fixups: addiu r15,r31,delta where r31 = address of that slot."""
    out = []
    for idx, label, builder in c.fix:
        if builder is None:
            # slot idx holds addiu r15,r31,delta; r31 = (idx)*4 (bgezal at idx-2 links idx-2+2 = idx)
            delta = (c.labels[label] - idx) * 4
            c.w[idx] = ADDIU(15, 31, delta & 0xFFFF)
        else:
            out.append((idx, label, builder))
    c.fix = out


def finish_block(c):
    resolve_jump_fixups(c, None)
    return c.link()


WEIGHTS = {
    "random": dict(alu_r=22, alu_i=18, lui=3, shift=8, muldiv=3, hilo=3, load=13, store=9, branch=8, jump=2, cop0=2, cop2=3,
                   copnop=1, excite=1, illegal=1, hazard=9),
    "exc": dict(alu_r=14, alu_i=10, lui=2, shift=4, muldiv=2, hilo=2, load=10, store=7, branch=7, jump=2, cop0=9, cop2=4,
                copnop=1, excite=12, illegal=6, hazard=7),
    "cache": dict(alu_r=16, alu_i=12, lui=2, shift=5, muldiv=2, hilo=2, load=12, store=10, branch=9, jump=5, cop0=3, cop2=2,
                  copnop=1, excite=1, illegal=1, hazard=12),
    "gte": dict(alu_r=10, alu_i=8, lui=2, shift=4, muldiv=2, hilo=2, load=9, store=7, branch=6, jump=1, cop0=2, cop2=30,
                copnop=1, excite=1, illegal=1, hazard=14),
}


def random_program(rng, suite, nodebug, nblocks, blocklen):
    """Chains of soup blocks at alias addresses; the chain loops."""
    img = Image()
    w = WEIGHTS["random" if suite == "smoke" else suite]
    img.place(0x40, [J_(0x80 >> 2), NOP])
    img.place(0x80, handler())
    img.place(BIOS + 0x180, handler())
    img.place(RESUME, [0])
    sr = rng.choice([0x40000401, 0x40000001, 0x40000401, 0x40400401])
    phys = []
    addr = MAIN
    for b in range(nblocks):
        s = Soup(rng, nodebug, w)
        n = blocklen if suite != "cache" else rng.choice([blocklen, blocklen // 2, 40, 90])
        c = s.build(n)
        phys.append((addr, c))
        addr += (len(c) + 12) * 4 + rng.choice([0, 0, 4, 8, 12, 20, 36])
        addr = (addr + 3) & ~3
    base = None
    if ALLOW_BP and suite != "smoke":
        # breakpoint block: BPC on its own 4th NOP, exact mask, enabled; the match livelocks the CPU until the next reset
        c = Code()
        base = addr
        c.emit(li(2, 0x80000000 | (base + 4 * 14)), MTC0(2, C0_BPC), li(3, 0xFFFFFFFF), MTC0(3, C0_BPCM), li(4, 0xE1800000),
               MTC0(4, C0_DCIC))
        c.emit([NOP] * 12)
        c.emit(MTC0(0, C0_DCIC))
        phys.insert(rng.randrange(0, len(phys) + 1), (base, c))
        addr += 0x100
    # chain: the block ends with lui/ori r15, jr r15 to the next block through an alias
    for k, (a, c) in enumerate(phys):
        nxt = phys[(k + 1) % len(phys)][0]
        if ALLOW_BP and nxt == base:
            tgt = 0x80000000 | nxt
        elif suite in ("cache",):
            tgt = alias_addr(rng, nxt)
        elif suite == "smoke":
            tgt = 0x80000000 | nxt
        else:
            tgt = rng.choice([0x80000000, 0x80000000, 0x00000000, 0xA0000000]) | nxt
        c.emit(li(15, tgt), JR(15), NOP)
        words = finish_block(c)
        img.place(a, words)
        assert a + 4 * len(words) < DATA, "code overflows into the data region"
    # random data
    for i in range(0x4000):
        r = rng.random()
        v = rng.choice([0, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 1]) if r < 0.1 else rng.getrandbits(32)
        img.mem[DATA + 4 * i] = v
    for i in range(0x400):
        img.mem[BIOS + 0x400 + 4 * i] = rng.getrandbits(32)
    entry = 0x80000000 | phys[0][0]
    img.place(BIOS, prelude(rng, sr, entry))
    return img


# ---------------------------------------------------------------- directed streams

_LOOPS = [0]


def loop(c, n, body):
    """Run body n times in a row (r30 counts), so the later passes execute from the instruction cache with no fetch stalls."""
    _LOOPS[0] += 1
    lab = "lp%d" % _LOOPS[0]
    c.emit(ADDIU(30, 0, n))
    c.label(lab)
    body(c)
    c.emit(ADDIU(30, 30, -1))
    c.br(lambda o: BNE(30, 0, o), lab)
    c.emit(NOP)


def d_alu(rng, c):
    """Every ALU op over edge pairs (r1, r2 -> r3)."""
    vals = rng.sample(EDGE, 12)
    for a in vals:
        for b in rng.sample(EDGE, 6):
            c.emit(li(1, a), li(2, b))
            for f in (0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2A, 0x2B):
                c.emit(R(f, 1, 2, 3))
            c.emit(R(0x04, 1, 2, 4), R(0x06, 1, 2, 5), R(0x07, 1, 2, 6))
            for op in (0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E):
                c.emit(I(op, 1, 7, rng.choice([0, 1, 0x7FFF, 0x8000, 0xFFFF, rng.getrandbits(16)])))
            c.emit(LUI(8, b & 0xFFFF), SLL(9, 1, rng.choice([0, 1, 5, 31])), SRL(10, 1, rng.choice([0, 1, 5, 31])),
                   SRA(11, 1, rng.choice([0, 1, 5, 31])))
            # write to r0 and forwarding chains
            c.emit(ADDU(0, 1, 2), ADDU(3, 0, 1), ADDU(4, 3, 3), ADDU(5, 4, 3), ADDU(6, 5, 4))


def d_muldiv(rng, c):
    pairs = [(a, b) for a in rng.sample(EDGE, 10) for b in rng.sample(EDGE, 5)]
    pairs += [(0x80000000, 0xFFFFFFFF), (5, 0), (0xFFFFFFFB, 0), (0x80000000, 0), (0xFFFFFFFF, 0xFFFFFFFF), (0x7FFFFFFF, 2)]
    for a, b in pairs:
        def body(c, a=a, b=b):
            c.emit(li(1, a), li(2, b))
            f = rng.choice([0x18, 0x19, 0x1A, 0x1B])
            c.emit(R(f, 1, 2))
            pad = rng.choice([0, 1, 2, 3, 5, 6, 7, 8, 9, 10, 13, 14, 15, 30, 33, 34, 35, 36, 37, 38])
            c.emit([NOP] * pad)
            c.emit(MFHI(3), MFLO(4))
            c.emit(R(0x18, 1, 2), R(0x19, 2, 1), MFLO(5), MFHI(6))          # restart while busy
            c.emit(R(0x1A, 1, 2), MTHI(1), MTLO(2), MFHI(7), MFLO(8))       # mthi/mtlo during a divide
            c.emit(R(0x1B, 1, 2), [NOP] * rng.randrange(0, 40), MTHI(2), MFHI(9), MFLO(10))
            c.emit(R(0x18, 1, 2), [NOP] * rng.randrange(0, 16), MTLO(1), MFLO(11), MFHI(12))
            c.emit(MTHI(1), MTLO(2), MFHI(13), MFLO(14), MFHI(13))
        loop(c, 2, body)


def mem_matrix(rng, c):
    regions = [(20, 0x40, 0), (21, 0x40, 0), (22, 0x40, 0), (23, 0x44, 0), (24, 0x20, 0), (18, 0x40, 0), (19, 0x40, 0),
               (25, 0x30, 0), (25, 0x2C, 0), (25, 0x34, 0), (0, 0x300, 0), (0, 0x200, 0),
               (22, 0x3F8, 0), (22, 0x3FC, 0), (22, 0x400, 0), (22, 0x404, 0), (22, -8, 0), (22, -4, 0), (23, 0x3FC, 0), (23, 0x400, 0),
               (23, -4, 0)]
    for base, off, _ in regions:
        for al in range(4):
            for ld in (LB, LBU, LH, LHU, LW, LWL, LWR):
                size = {LB: 1, LBU: 1, LH: 2, LHU: 2}.get(ld, 4)
                if size == 2 and al & 1 and rng.random() < 0.7:
                    continue
                if size == 4 and ld is LW and al and rng.random() < 0.7:
                    continue
                r = rng.random()
                seed_val = rng.getrandbits(32)

                def body(c, ld=ld, off=off, al=al, base=base, r=r, seed_val=seed_val):
                    c.emit(li(1, seed_val))
                    c.emit(ld(1, off + al, base))
                    if r < 0.3:
                        c.emit(ADDU(2, 1, 1))
                    elif r < 0.5:
                        c.emit(NOP, ADDU(2, 1, 1))
                    elif r < 0.6:
                        c.emit(NOP, NOP, ADDU(2, 1, 1))
                    elif r < 0.7:
                        c.emit(ld(1, off + 4, base), ADDU(2, 1, 1))
                    elif r < 0.8:
                        c.emit(LW(3, off & ~3, base), LW(1, (off + 4) & ~3, base), ADDU(4, 1, 3))
                    elif r < 0.9:
                        c.emit(ADDU(1, 2, 3), ADDU(2, 1, 1))     # WAW against the load
                    else:
                        c.emit(ld(0, off + al, base), ADDU(2, 0, 0))
                loop(c, 3, body)
            for st in (SB, SH, SW, SWL, SWR):
                size = {SB: 1, SH: 2}.get(st, 4)
                if size == 2 and al & 1 and rng.random() < 0.7:
                    continue
                if st is SW and al and rng.random() < 0.7:
                    continue
                if base in (18, 19):
                    continue
                v = rng.getrandbits(32)
                r = rng.random()

                def body(c, st=st, off=off, al=al, base=base, v=v, r=r):
                    c.emit(li(3, v))
                    c.emit(st(3, off + al, base))
                    if r < 0.5:
                        c.emit(LW(4, (off & ~3), base), ADDU(5, 4, 3))
                    else:
                        c.emit(SW(3, (off + 8) & ~3, base), SW(3, (off + 12) & ~3, base), SB(3, off + 1, base), LBU(4, off + 1, base))
                loop(c, 3, body)


def d_mem(rng, c):
    mem_matrix(rng, c)
    # unaligned word pairs
    for al in range(4):
        c.emit(LWL(1, 3 + al, 20), LWR(1, al, 20), ADDU(2, 1, 1))
        c.emit(LWR(1, al, 21), LWL(1, 3 + al, 21), ADDU(2, 1, 1))
        c.emit(SWL(1, 3 + al, 20), SWR(1, al, 20), LW(2, 0, 20))
        c.emit(LWL(3, 3 + al, 22), LWR(3, al, 22), SWL(3, 3 + al, 23), SWR(3, al, 23), LW(4, 0, 23))
    # store bursts (write FIFO), cachecontrol, load-after-store same address
    for i in range(24):
        c.emit(SW(1, 4 * i, 20))
    c.emit(LW(2, 0x5C, 20), ADDU(3, 2, 2))
    c.emit(SW(1, 0x30, 25), LW(2, 0x30, 25), LW(3, 0x30, 25), ADDU(4, 3, 2))
    c.emit(li(5, 0x0001E988), SW(5, 0x30, 25), LW(6, 0x30, 25), NOP)
    # back-to-back loads to the same target, different targets, ram vs scratchpad mixes
    c.emit(LW(1, 0, 20), LW(1, 4, 20), LW(2, 8, 20), ADDU(3, 1, 2))
    c.emit(LW(1, 0, 20), LW(2, 0, 22), ADDU(3, 1, 2), LW(1, 4, 22), LW(2, 12, 20), ADDU(3, 1, 2))
    c.emit(LW(1, 0, 20), LW(1, 0, 22), ADDU(3, 1, 1))
    c.emit(LW(1, 0, 22), LW(1, 0, 20), ADDU(3, 1, 1), LW(1, 8, 21), SW(1, 12, 21), LW(2, 12, 21))
    c.emit(LW(1, 0, 20), ADDU(1, 1, 1), ADDU(2, 1, 1))
    c.emit(LW(1, 0, 20), LW(2, 0, 20), LW(3, 0, 20), LW(4, 0, 20), ADDU(5, 1, 4))
    c.emit(LW(1, 0, 20), SW(1, 4, 20), LW(2, 4, 20), ADDU(3, 2, 2))
    c.emit(LW(1, 0, 20), BEQ(1, 0, 1), NOP, ADDU(2, 1, 1))
    c.emit(LW(1, 0, 20), JR(15) if False else NOP, ADDU(2, 1, 1))
    c.emit(LW(1, 0, 20), MTC0(1, C0_SR) if False else NOP, MFHI(2))
    c.emit(LW(1, 0, 20), MFLO(2), MULT(1, 1), MFLO(3), MFHI(4))
    c.emit(LW(1, 0, 20), MTC2(1, 3), LW(2, 4, 20), MTC2(2, 4))
    c.emit(LW(0, 0, 20), ADDU(1, 0, 0), LW(1, 0, 20), ADDIU(0, 1, 5), ADDU(2, 0, 0))
    # LWC2 right after a load whose target equals the LWC2's rt field (the rt field is a GTE register, not a GPR)
    for base in (20, 22):
        c.emit(LW(5, 0, 20), LWC2(5, 4, base), ADDU(6, 5, 5))
        c.emit(LW(5, 0, 20), LWC2(5, 4, base), LWC2(5, 8, base), ADDU(6, 5, 5), ADDU(7, 5, 6))
        c.emit(LW(5, 0, 22), LWC2(5, 4, base), NOP, ADDU(6, 5, 5))


def d_branch(rng, c, n):
    ops = [
        lambda o: BEQ(1, 2, o), lambda o: BNE(1, 2, o), lambda o: BLEZ(1, o), lambda o: BGTZ(1, o),
        lambda o: BLTZ(1, o), lambda o: BGEZ(1, o), lambda o: BLTZAL(1, o), lambda o: BGEZAL(1, o),
        lambda o: I(1, 1, 2, o), lambda o: I(1, 1, 5, o), lambda o: I(1, 1, 31, o), lambda o: I(1, 1, 18, o)]
    slots = [lambda: NOP, lambda: ADDU(1, 1, 2), lambda: ADDIU(2, 0, 7), lambda: LW(1, 0, 20), lambda: SW(1, 0, 20),
             lambda: MFHI(1), lambda: ADD(1, 3, 3), lambda: MTC2(1, 4), lambda: SYSCALL, lambda: LW(3, 2, 20),
             lambda: MFC0(1, C0_SR), lambda: MULT(1, 2), lambda: COP2CMD(0x180001)]
    for a, b in [(0, 0), (1, 1), (1, 2), (5, 0xFFFFFFFB), (0x80000000, 0), (0xFFFFFFFF, 1), (0x7FFFFFFF, 0x7FFFFFFF), (0, 5)]:
        for bi, bo in enumerate(ops):
            n += 1
            slot = rng.choice(slots)()
            lab = "t%d" % n

            def body(c, a=a, b=b, bo=bo, slot=slot, lab=lab):
                c.emit(li(1, a), li(2, b), li(31, 0))
                c.br(bo, lab)
                c.emit(slot)
                c.emit(ADDIU(5, 5, 1), ADDIU(5, 5, 1))
                c.label(lab)
                c.emit(ADDU(6, 31, 5))
            loop(c, 2, body)
    # branch in a delay slot, jumps and links
    for k in range(6):
        n += 1
        la, lb = "u%d" % n, "v%d" % n
        c.emit(li(1, rng.choice([0, 1, 0xFFFFFFFF])), li(2, rng.choice([0, 1])))
        c.br(lambda o: BEQ(1, 2, o), la)
        c.br(lambda o: BNE(1, 2, o), lb)
        c.emit(ADDIU(7, 7, 1))
        c.label(la)
        c.emit(ADDIU(7, 7, 2))
        c.label(lb)
        c.emit(ADDIU(7, 7, 4), NOP)
    n += 1
    c.emit(BGEZAL(0, 1), NOP, ADDIU(15, 31, 24), JALR(16, 15), ADDIU(9, 9, 1), ADDIU(9, 9, 2), ADDIU(9, 9, 3), ADDIU(9, 9, 4))
    c.emit(BGEZAL(0, 1), NOP, ADDIU(15, 31, 20), JALR(31, 15), NOP, ADDIU(9, 9, 2), ADDIU(9, 9, 3), ADDIU(9, 9, 4))
    c.emit(BGEZAL(0, 1), NOP, ADDIU(15, 31, 16), JR(15), ADDU(10, 31, 31), ADDIU(9, 9, 3), ADDIU(9, 9, 4))
    c.emit(BGEZAL(0, 1), NOP, ADDIU(15, 31, 16), JR(15), LW(10, 0, 20), ADDIU(9, 9, 3), ADDU(11, 10, 10))
    c.emit(BGEZAL(0, 1), NOP, ADDIU(15, 31, 12), JR(15), ADD(10, 3, 3) if False else NOP, ADDIU(9, 9, 4))
    return n


def d_exc(rng, c, n, nodebug):
    """Exceptions in every slot context, with the delay slot variants and interrupts."""
    big = li(1, 0x7FFFFFFF)
    cases = [
        [big, ADDI(2, 1, 1)], [big, ADD(2, 1, 1)], [li(1, 0x80000000), SUB(2, 1, 1) if False else SUB(2, 1, 3)],
        [SYSCALL], [BREAK], [I(0x1C, 0, 0, 0)], [R(0x3F)], [I(0x10, 16, 0, 1)], [I(0x10, 16, 0, 2)],
        [LW(2, 1, 20)], [LW(2, 2, 20)], [LH(2, 1, 20)], [LHU(2, 3, 20)], [SW(2, 1, 20)], [SW(2, 3, 20)], [SH(2, 1, 20)],
        [SH(2, 3, 21)], [MTC2(2, 3), ADD(3, 1, 1)], [MULT(1, 1), ADD(3, 1, 1), MFHI(4)],
        [LW(2, 0, 20), ADD(3, 1, 1), ADDU(5, 2, 2)], [LW(2, 0, 22), ADD(3, 1, 1), ADDU(5, 2, 2)], [DIV(1, 3), ADDI(3, 1, 1), MFLO(5)],
        [COP2CMD(0x180001), ADD(3, 1, 1)], [SW(2, 0, 20), ADD(3, 1, 1)], [LWC2(1, 0, 20), ADD(3, 1, 1)],
        [I(0x2C, 1, 2, 0)], [I(0x2D, 1, 2, 0)], [I(0x2F, 1, 2, 0)],
    ]
    for cs in cases:
        for ctx in range(4):
            n += 1
            lab = "e%d" % n

            def body(c, cs=cs, ctx=ctx, lab=lab):
                c.emit(li(1, 0x7FFFFFFF), li(3, 0x80000000))
                if ctx == 0:
                    c.emit(cs)
                elif ctx == 1:      # delay slot of a taken branch
                    c.br(lambda o: BEQ(0, 0, o), lab)
                    c.emit(cs)
                    c.emit(NOP)
                    c.label(lab)
                elif ctx == 2:      # delay slot of a not-taken branch
                    c.br(lambda o: BNE(0, 0, o), lab)
                    c.emit(cs)
                    c.label(lab)
                else:               # delay slot of jal
                    c.emit(BGEZAL(0, 1), NOP, ADDIU(15, 31, 20), JR(15))
                    c.emit(cs)
                    c.emit(NOP, NOP)
                c.emit(ADDU(8, 8, 1), ADDU(9, 8, 8))
            loop(c, 2, body)
    # JR to a misaligned address, resume through the override word
    c.emit(li(1, 0), li(2, 0))
    c.emit(BGEZAL(0, 1), NOP, ADDIU(2, 31, 20), SW(2, RESUME, 0), ADDIU(3, 2, 1), JR(3), NOP, ADDIU(9, 9, 1), ADDIU(9, 9, 2),
           SW(0, RESUME, 0))
    c.emit(BGEZAL(0, 1), NOP, ADDIU(2, 31, 20), SW(2, RESUME, 0), ADDIU(3, 2, 2), JALR(4, 3), NOP, ADDIU(9, 9, 1), ADDIU(9, 9, 2),
           SW(0, RESUME, 0))
    c.emit(BGEZAL(0, 1), NOP, ADDIU(2, 31, 20), SW(2, RESUME, 0), ADDIU(3, 2, 2), JR(3), NOP, ADDIU(9, 9, 1), ADDIU(9, 9, 2),
           SW(0, RESUME, 0))
    c.emit(BGEZAL(0, 1), NOP, ADDIU(2, 31, 24), SW(2, RESUME, 0), ADDIU(3, 2, 3), BEQ(0, 0, 1), JR(3), ADDIU(9, 9, 1),
           ADDIU(9, 9, 2), SW(0, RESUME, 0))
    # Cause write mask: only the software interrupt bits 9:8 stay
    for v in (0xFFFFFFFF, 0x200, 0x300, 0x100, 0x400, 0):
        c.emit(li(2, v), MTC0(2, C0_CAUSE), MFC0(3, C0_CAUSE), ADDU(4, 3, 3), MTC0(0, C0_CAUSE))
    # software interrupts: IM bit 8/9, Cause SW bits, in every pipeline context
    for ctx in range(8):
        c.emit(li(1, 0x40000301), MTC0(1, C0_SR), li(2, 0x100 if ctx < 6 else 0x200), NOP)
        pre = [[], [LW(3, 0, 20)], [MULT(1, 1)], [COP2CMD(0x180001)], [SW(1, 0, 20), SW(1, 4, 20)], [LW(3, 0, 22)],
               [DIV(1, 1)], [MTC2(1, 1)]][ctx]
        c.emit(pre)
        c.emit(MTC0(2, C0_CAUSE), ADDU(4, 4, 1), ADDU(4, 4, 1), LW(5, 8, 20), ADDU(4, 5, 5), NOP, NOP, NOP, NOP, NOP, NOP,
               NOP, NOP, NOP)
        c.emit(li(1, 0x40000001), MTC0(1, C0_SR), NOP)
    return n


def d_cop0(rng, c, nodebug):
    c.emit(li(1, 0xFFFFFFFF))
    for reg in range(32):
        if nodebug and reg in DEBUG_REGS:
            continue
        if reg in (C0_SR, C0_CAUSE):
            c.emit(MFC0(2, reg), ADDU(3, 2, 2), MFC0(4, reg))
            continue
        if reg == C0_DCIC:
            c.emit(li(6, 0x007F0F3F), MTC0(6, reg), MFC0(2, reg), ADDU(3, 2, 2))     # breakpoint enable bits stay clear
        else:
            c.emit(MTC0(1, reg), MFC0(2, reg), ADDU(3, 2, 2))
        c.emit(MTC0(0, reg), MFC0(2, reg), NOP, MFC0(4, reg), ADDU(5, 4, 4))
    c.emit(li(1, 0x12345678))
    for sr in rng.sample(SR_POOL, 10):
        c.emit(li(2, sr), MTC0(2, C0_SR), MFC0(3, C0_SR), ADDU(4, 3, 3), MTC0(2, C0_SR), RFE, MFC0(5, C0_SR), NOP)
        c.emit(li(2, 0x40000401), MTC0(2, C0_SR), NOP)
    c.emit(RFE, RFE, MFC0(2, C0_SR), li(2, 0x500000FF), MTC0(2, C0_SR), MFC0(3, C0_SR), RFE, MFC0(3, C0_SR), li(2, 0x40000401),
           MTC0(2, C0_SR))
    if not nodebug:
        # debug registers read back; the breakpoint enable bits stay clear (a match livelocks the CPU until a reset)
        c.emit(MTC0(1, C0_BDA), MTC0(1, C0_BDAM), MFC0(2, C0_BDA), MFC0(3, C0_BDAM), MFC0(4, C0_DCIC))
        c.emit(li(2, 0x007F0F3F), MTC0(2, C0_DCIC), MFC0(3, C0_DCIC), li(2, 0x0F000000), MTC0(2, C0_BPCM), MFC0(3, C0_BPCM),
               MTC0(0, C0_DCIC), MTC0(0, C0_BPCM), MFC0(3, C0_DCIC))


def d_gte(rng, c):
    for k in range(64):
        c.emit(MFC2(1, k & 31), ADDU(2, 1, 1), CFC2(3, k & 31), ADDU(4, 3, 3), MTC2(2, k & 31), CTC2(4, k & 31))
    cmds = [0x180001, 0x1400006, 0x0480012, 0x0E80030, 0x0100002]
    for cm in cmds:
        for gap in (0, 1, 2, 3, 5, 8, 12, 20, 40):
            for follow in (MTC2(2, 3), MFC2(1, 3), CFC2(1, 5), CTC2(2, 5), LWC2(4, 0, 20), SWC2(5, 0, 20), COP2CMD(cm), LW(1, 0, 20), ADDU(1, 1, 1)):
                loop(c, 3, lambda c, cm=cm, gap=gap, follow=follow: c.emit(COP2CMD(cm), [NOP] * gap, follow, ADDU(6, 1, 1)))
    # lwc2/swc2 from every memory class
    for base in (20, 21, 22, 23, 24):
        for k in range(4):
            c.emit(LWC2(k, 4 * k, base), SWC2(k, 16 + 4 * k, base) if base not in (24,) else NOP, MFC2(1, k), ADDU(2, 1, 1))
    c.emit(LWC2(1, 0, 20), LWC2(2, 4, 20), MFC2(3, 1), MFC2(4, 2))
    c.emit(LWC2(1, 0, 22), LWC2(2, 4, 20), LWC2(3, 8, 22), MFC2(4, 1))
    c.emit(MFC2(1, 5), MFC2(2, 6), MTC2(1, 7), MFC2(3, 7), SWC2(7, 0, 20), SWC2(8, 4, 20), LWC2(7, 4, 20), SWC2(7, 8, 20))
    # COP2 disabled
    c.emit(li(1, 0x00000401), MTC0(1, C0_SR), NOP)
    for ins in (MFC2(2, 1), CFC2(2, 1), MTC2(2, 1), CTC2(2, 1), COP2CMD(1), LWC2(1, 0, 20), SWC2(1, 0, 20)):
        c.emit(ins, ADDU(3, 3, 1))
    c.emit(li(1, 0x40000401), MTC0(1, C0_SR), NOP)


def d_cache(rng, img, c, nodebug):
    """Snippets at chosen physical addresses, called through aliases; isolation and invalidation."""
    snips = []
    base = SNIP
    # entry words 0..3 of a line, runs 7 instructions, returns by jr r31
    for k in range(4):
        a = base + 0x100 * k + 4 * k
        body = [ADDIU(10, 10, 1)] * 6 + [JR(31), NOP]
        img.place(a, body)
        snips.append(a)
    # BIOS-class copies of the first snippets (same words at the same line offsets): cached BIOS fetches hit on the RAM
    # snippet's cache data, which holds the same words
    bios_snips = []
    for k in range(4):
        a = base + 0x100 * k + 4 * k
        b = BIOS + 0x2000 + 0x100 * k + 4 * k
        img.place(b, [ADDIU(10, 10, 1)] * 6 + [JR(31), NOP])
        bios_snips.append((a, b))
    # same line index, different physical page (aliasing in the 4 KB cache)
    for k in range(4):
        a = base + 0x1000 * (k + 1) + 0x20
        img.place(a, [ADDIU(11, 11, 1)] * 6 + [JR(31), NOP])
        snips.append(a)
    # a snippet whose first word sits at the last word of a line
    a = base + 0x2000 + 12
    img.place(a, [ADDIU(12, 12, 1)] * 9 + [JR(31), NOP])
    snips.append(a)
    for _ in range(3):
        for a in snips:
            for seg in (0x80000000, 0x80400000, 0x80000000, 0x00000000, 0xA0000000, 0x80200000, 0x80000000, 0x80600000, 0x00400000):
                c.emit(li(15, seg | a), JALR(31, 15), NOP)
        # enter into the middle of a line, then at its start (tag match, word invalid)
        a0 = base + 0x100 * 0
        for seg in (0x80000000, 0xA0000000, 0x80000000):
            c.emit(li(15, seg | (a0 + 8)), JALR(31, 15), NOP, li(15, seg | a0), JALR(31, 15), NOP)
    for _ in range(3):
        for a, b in bios_snips:
            c.emit(li(15, 0x80000000 | a), JALR(31, 15), NOP)
            for seg in (0x80000000, 0x80000000, 0x00000000, 0xA0000000, 0x80000000):
                c.emit(li(15, seg | b), JALR(31, 15), NOP)
            c.emit(li(15, 0x80000000 | a), JALR(31, 15), NOP)
    # 18-bit tag evidence: run T uncached (KSEG1); its isolated stores invalidate the tag lines of T's own page with the
    # KSEG1 fetch address as tag (bits 30:29 = 01), then run T cached (KSEG0): the line holds a tag equal to the fetch
    # address except in bits 30:29, with all valid bits clear
    t_addr = base + 0x3000 + 0x40
    t_body = Code()
    t_body.emit(li(1, 0x40010401), MTC0(1, C0_SR), NOP, NOP)
    for k in range(6):
        t_body.emit(li(2, 0x80020000 + (t_addr & 0xFF0) + 16 * k), SW(0, 0, 2))
    t_body.emit(li(1, 0x40000401), MTC0(1, C0_SR), NOP, NOP, JR(31), NOP)
    img.place(t_addr, t_body.link())
    for rep in range(4):
        for seg in (0xA0000000, 0x80000000, 0x80000000, 0xA0000000, 0x80000000):
            c.emit(li(15, seg | t_addr), JALR(31, 15), NOP)
        c.emit(li(15, 0x00000000 | t_addr), JALR(31, 15), NOP)
    # compact-tag guard: after S is cached, fetch the same line index and page bits through an address that is neither a RAM
    # nor a BIOS address (bits 28:23 mixed): the golden misses and gets SYSCALL from the bus model, which resumes through
    # the override word; a tag compare that ignored bits 27:23 would hit on S
    for b in (23, 24, 25, 26, 27, 28):
        for s_addr in snips[:5]:
            a_bad = (1 << b) | s_addr
            c.emit(li(15, 0x80000000 | s_addr), JALR(31, 15), NOP)
            c.emit(BGEZAL(0, 1), NOP, ADDIU(2, 31, 24), SW(2, RESUME, 0), li(15, 0x80000000 | a_bad), JALR(16, 15), NOP, SW(0, RESUME, 0))
            c.emit(li(15, 0x00000000 | a_bad), BGEZAL(0, 1), NOP, ADDIU(2, 31, 16), SW(2, RESUME, 0), JALR(16, 15), NOP,
                   SW(0, RESUME, 0))
    # isolation: stores invalidate tag lines of the loop code
    c.emit(li(1, 0x40010401), MTC0(1, C0_SR), NOP, NOP)
    for k in range(40):
        c.emit(SW(0, 0x10 * k, 20), SW(0, 0x10 * k + 4, 21))
    c.emit(li(1, 0x40000401), MTC0(1, C0_SR), NOP, NOP)
    c.emit(li(1, 0x40010401), MTC0(1, C0_SR), NOP, NOP)
    for k in range(0, 0x1000, 0x10 * 7):
        c.emit(li(2, 0x80010000 + k), SW(0, 0, 2))
    c.emit(li(1, 0x40000401), MTC0(1, C0_SR), NOP, NOP)
    # swc/sb in isolation mode
    c.emit(li(1, 0x40010401), MTC0(1, C0_SR), NOP, NOP, SB(1, 3, 20), SH(1, 6, 20), SWL(1, 9, 20), SWR(1, 10, 21), LW(2, 0, 20),
           SWC2(1, 0, 20), SW(1, 0, 22), li(1, 0x40000401), MTC0(1, C0_SR), NOP)


def directed_program(rng, nodebug, only=None):
    img = Image()
    img.place(0x40, [J_(0x80 >> 2), NOP])
    img.place(0x80, handler())
    img.place(BIOS + 0x180, handler())
    img.place(RESUME, [0])
    parts = []
    n = [0]

    def part(fn):
        c = Code()
        fn(c)
        parts.append(c)

    def want(name):
        return only is None or name in only

    if want("alu"):
        part(lambda c: d_alu(rng, c))
    if want("muldiv"):
        part(lambda c: d_muldiv(rng, c))
    if want("mem"):
        part(lambda c: d_mem(rng, c))

    def br(c):
        n[0] = d_branch(rng, c, n[0])
    if want("branch"):
        part(br)

    def ex(c):
        n[0] = d_exc(rng, c, n[0] + 1000, nodebug)
    if want("exc"):
        part(ex)
    if want("cop0"):
        part(lambda c: d_cop0(rng, c, nodebug))
    if want("gte"):
        part(lambda c: d_gte(rng, c))
    cache_part_index = -1
    if want("cache"):
        cache_part_index = len(parts)
        part(lambda c: d_cache(rng, img, c, nodebug))
    # each part is its own block; blocks chain by jr through the aliases
    addr = CODE_BASE
    placed = []
    for c in parts:
        words = c.link()
        placed.append((addr, words))
        addr += (len(words) + 16) * 4
    for k, (a, words) in enumerate(placed):
        nxt = placed[(k + 1) % len(placed)][0]
        tail = Code()
        # the cache part runs uncached so its own fetches leave the cached test lines alone
        nxt_is_cache = (k + 1) % len(placed) == cache_part_index
        tail.emit(li(15, (0xA0000000 if nxt_is_cache else rng.choice([0x80000000, 0x00000000, 0xA0000000])) | nxt), JR(15), NOP)
        words = words + tail.link()
        img.place(a, words)
        assert a + 4 * len(words) < 0x1F0000, "directed code too large"
        # the data area (0x20000) is reused for code here, so the directed program keeps its data elsewhere
    return img, placed


def fix_cop0(rng, w, nodebug):
    """Repair the COP0 forms the golden asserts on (it stops the simulation on them; hardware ignores them)."""
    op = w >> 26
    rs = (w >> 21) & 31
    if op == 0x10:
        if rs & 0x10:
            w = (w & ~0x7F) | rng.choice([1, 2, 4, 8, 16])
            w = (w & ~(31 << 21)) | (16 << 21)
        elif rs not in (0, 4):
            w = (w & ~(31 << 21)) | rng.choice([0, 4]) << 21
        if nodebug and ((w >> 11) & 31) in DEBUG_REGS and ((w >> 21) & 31) in (0, 4):
            w = (w & ~(31 << 11)) | (C0_SR << 11)
    return w


def wild_program(rng, nodebug):
    """Random 32-bit words everywhere (code, data, BIOS data), run through the usual handler; nothing structured."""
    img = Image()
    img.place(0x40, [J_(0x80 >> 2), NOP])
    img.place(0x80, handler())
    img.place(BIOS + 0x180, handler())
    img.place(RESUME, [0])
    words = []
    for i in range(0x2000):
        w = rng.getrandbits(32)
        if rng.random() < 0.5:                    # bias the opcode toward the implemented ones
            w = (w & 0x03FFFFFF) | rng.choice([0x00, 0x00, 0x08, 0x09, 0x0C, 0x0D, 0x0F, 0x20, 0x21, 0x23, 0x24, 0x25, 0x28, 0x29, 0x2B,
                                                0x04, 0x05, 0x06, 0x07, 0x01, 0x02, 0x03, 0x22, 0x26, 0x2A, 0x2E, 0x10, 0x12, 0x32, 0x3A]) << 26
        words.append(fix_cop0(rng, w, nodebug))
    img.place(MAIN, words)
    t = Code()
    t.emit(li(15, 0x80000000 | MAIN), JR(15), NOP)
    img.place(MAIN + 4 * len(words), t.link())
    for i in range(0x4000):
        img.mem[DATA + 4 * i] = fix_cop0(rng, rng.getrandbits(32), nodebug)
    for i in range(0x400):
        img.mem[BIOS + 0x400 + 4 * i] = fix_cop0(rng, rng.getrandbits(32), nodebug)
    return img


def edge_program(rng, nodebug):
    """Operand matrix: a block per op family, full cross product of the edge values."""
    img = Image()
    img.place(0x40, [J_(0x80 >> 2), NOP])
    img.place(0x80, handler())
    img.place(BIOS + 0x180, handler())
    img.place(RESUME, [0])
    c = Code()
    vals = rng.sample(EDGE, 20)
    for a in vals:
        for b in vals:
            c.emit(li(1, a), li(2, b))
            for f in (0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2A, 0x2B, 0x04, 0x06, 0x07):
                c.emit(R(f, 1, 2, 3))
            c.emit(MULT(1, 2), MFHI(4), MFLO(5), MULTU(1, 2), MFLO(6), MFHI(7))
            c.emit(DIV(1, 2), [NOP] * 36, MFHI(8), MFLO(9), DIVU(1, 2), [NOP] * 36, MFLO(10), MFHI(11))
    words = c.link()
    img.place(CODE_BASE, words)
    assert CODE_BASE + 4 * len(words) < 0x1F0000
    t = Code()
    t.emit(li(15, 0x80000000 | CODE_BASE), JR(15), NOP)
    img.place(CODE_BASE + 4 * len(words), t.link())
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--suite", required=True)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", required=True)
    ap.add_argument("--no-cop0-debug", action="store_true")
    ap.add_argument("--size", type=int, default=0, help="instructions per block (random suites)")
    ap.add_argument("--blocks", type=int, default=0)
    ap.add_argument("--parts", default="", help="directed suite: comma separated parts (alu muldiv mem branch exc cop0 gte cache)")
    ap.add_argument("--bp", action="store_true", help="allow enabled COP0 breakpoints (the run needs warm resets)")
    a = ap.parse_args()
    rng = random.Random(a.seed * 7919 + sum(map(ord, a.suite)))
    nd = a.no_cop0_debug
    global ALLOW_BP
    ALLOW_BP = a.bp and not nd
    if a.suite == "directed":
        img, placed = directed_program(rng, nd, a.parts.split(',') if a.parts else None)
        sr = 0x40000401
        entry = 0x80000000 | placed[0][0]
        img.place(BIOS, prelude(rng, sr, entry))
        for i in range(0x4000):
            img.mem[DATA + 4 * i] = rng.getrandbits(32) if rng.random() > 0.1 else rng.choice(EDGE)
        for i in range(0x400):
            img.mem[BIOS + 0x400 + 4 * i] = rng.getrandbits(32)
        sys.stderr.write("directed words=%d\n" % sum(len(w) for _, w in placed))
    elif a.suite == "edge":
        img = edge_program(rng, nd)
        img.place(BIOS, prelude(rng, 0x40000401, 0x80000000 | CODE_BASE))
        for i in range(0x4000):
            img.mem[DATA + 4 * i] = rng.getrandbits(32)
    elif a.suite == "wild":
        img = wild_program(rng, nd)
        img.place(BIOS, prelude(rng, rng.choice([0x40000401, 0x40000001, 0x00000401]), 0x80000000 | MAIN))
    elif a.suite in ("random", "exc", "cache", "gte", "smoke"):
        nb = a.blocks or (2 if a.suite == "smoke" else 6)
        bl = a.size or (150 if a.suite == "smoke" else 400)
        img = random_program(rng, a.suite, nd, nb, bl)
    else:
        sys.exit("unknown suite " + a.suite)
    img.write(a.out)


if __name__ == "__main__":
    main()
