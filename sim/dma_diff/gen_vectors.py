#!/usr/bin/env python3
"""Vector generator for tb_dma.vhd: channel programming of the 7 DMA channels.

usage: gen_vectors.py --suite NAME --seed N [--count N] --out FILE
suites: directed  every channel x direction x sync mode x step x chopping, one short transfer each
        random    random scenarios (1..3 channels programmed back to back), random device timing
        boundary  addresses at 1 KB page edges (ram_cnt 0..3), long transfers, bit-23 addresses, BCR 0
        turbo     random scenarios with TURBO / TURBO_CACHE / ram8mb / ignoreCDTiming set
        reset     reset (8..70 cycles) in the middle of transfers
        smoke     a few of each, for the self-test
        wild      random scenarios plus register accesses at random times (run with G_MODE=1)
Commands (one per line, '#' comments):
  REQ gpu mdec_w mdec_r spu  force the device request levels (they then flip at the DEV rates)
  CFG turbo turbo_cache ram8mb ignorecd        DEV gpu_flip mdw_flip mdr_flip spu_flip fifo_p lat1_min lat1_max lat2_min lat2_max busy_p
  CDT memctrl8 com0_delay spu_timing_on spu_timing_value                     MEM byte_addr hex_word
  BW addr7 data / BR addr7  bus write / read      GAP n   IDLE   RST n   PAUSE n   END
"""
import argparse
import random
import sys

# channel -> allowed directions (1 = RAM to device). 0: MDEC in, 1: MDEC out, 2: GPU, 3: CD, 4: SPU, 5: PIO, 6: OTC
DIRS = {0: (1,), 1: (0,), 2: (0, 1), 3: (0, 1), 4: (0, 1), 5: (0, 1), 6: (0, 1)}
PRIMARY = {0: (1,), 1: (0,), 2: (0, 1), 3: (0,), 4: (0, 1), 5: (0,), 6: (0,)}


class Prog:
    def __init__(self, rng):
        self.rng = rng
        self.lines = []
        self.nodes = 0
        self.scen = 0
        self.xfers = {}

    def add(self, s):
        self.lines.append(s)

    def bw(self, a, d):
        self.add("BW %02x %08x" % (a, d & 0xFFFFFFFF))

    def br(self, a):
        self.add("BR %02x" % a)

    def gap(self, n):
        if n > 0:
            self.add("GAP %d" % n)

    def idle(self):
        self.add("IDLE")

    def mem(self, a, v):
        self.add("MEM %x %08x" % (a, v & 0xFFFFFFFF))

    def dev(self, **k):
        r = self.rng
        flips = (1, 2, 3, 5, 10, 25, 50, 90)
        lat = r.choice([(0, 0, 0, 0), (1, 3, 0, 2), (2, 6, 1, 5), (4, 12, 2, 10), (8, 30, 5, 25)])
        self.add("DEV %d %d %d %d %d %d %d %d %d %d" % (
            k.get("gpu", r.choice(flips)), k.get("mdw", r.choice(flips)), k.get("mdr", r.choice(flips)),
            k.get("spu", r.choice(flips)), k.get("fifo", r.choice((4, 10, 30, 70, 100))),
            lat[0], lat[1], lat[2], lat[3], k.get("busy", r.choice((0, 3, 10)))))
        self.add("CDT %d %d %d %d" % (r.randint(0, 1), r.randint(0, 15), r.randint(0, 1), r.randint(0, 15)))

    def cfg(self, turbo=0, tc=0, r8=0, icd=0):
        self.add("CFG %d %d %d %d" % (turbo, tc, r8, icd))


def madr_pick(r, boundary=False):
    """Word-aligned byte address below 2 MB; at a 1 KB page edge when boundary."""
    if boundary:
        page = r.randrange(0x1000, 0x1F0000, 0x400)
        word = r.choice((0xFC, 0xFD, 0xFE, 0xFF, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0xFB))
        return page + word * 4
    return r.randrange(0x1000, 0x1F0000, 4)


def chcr(todev, neg=0, chop=0, sync=0, cdma=0, ccpu=0, start=1, trig=None):
    if trig is None:
        trig = 1 if sync == 0 else 0
    return todev | neg << 1 | chop << 8 | sync << 9 | cdma << 16 | ccpu << 20 | start << 24 | trig << 28


def build_list(p, r, nodes, maxlen, region=None, todev=1):
    """Linked list of NODES nodes in RAM; returns the byte address of the first node."""
    base = region if region is not None else r.randrange(0x2000, 0x180000, 0x1000)
    addrs = []
    a = base
    for _ in range(nodes):
        addrs.append(a)
        a += 4 * (maxlen + 2 + r.randint(0, 6))
    for k, a in enumerate(addrs):
        ln = r.randint(0, maxlen)
        if r.random() < 0.1:
            ln = 0
        nxt = addrs[k + 1] if k + 1 < len(addrs) else r.choice((0xFFFFFF, 0xFFFFFF, 0x800000 | r.randrange(0, 0x7FFFFF, 4)))
        if k + 1 < len(addrs) and r.random() < 0.03:
            nxt = 0xFFFFFF
        p.mem(a, ln << 24 | (nxt & 0xFFFFFF))
    return addrs[0]


def clear_all(p):
    """CHCR start bits cleared on every channel, twice around an idle wait: a start already requested still runs and
    may leave channelOn set (the golden starts it although the clear write cancelled the trigger). Channel 0 keeps
    its direction bit so that such a leftover start is a legal one (MDEC in)."""
    for _ in range(2):
        for c in range(7):
            p.bw(c * 16 + 8, 1 if c == 0 else 0)
        if _ == 0:
            p.idle()


def program_channel(p, r, ch, todev, sync, neg, chop, size, madr=None, boundary=False, order=None, extra_trig=False):
    """Write MADR, BCR, CHCR of one channel; returns the number of words the transfer should move (informational)."""
    cdma = r.randint(0, 7)
    ccpu = r.randint(0, 7)
    if sync == 2:
        nodes = r.randint(1, 6)
        madr = build_list(p, r, nodes, min(size, 12), todev=todev)
        bcr = r.randint(1, 8) | r.randint(1, 3) << 16     # unused by a list; kept small for a later retarget
    elif sync == 1:
        blocks = r.randint(1, 5)
        bsize = size
        bcr = blocks << 16 | bsize
        madr = madr if madr is not None else madr_pick(r, boundary)
    else:
        bcr = size & 0xFFFF
        madr = madr if madr is not None else madr_pick(r, boundary)
        if r.random() < 0.05:
            madr |= 0x800000
    c = chcr(todev, neg, chop if sync == 0 else 0, sync, cdma, ccpu, 1, 1 if (sync == 0 or extra_trig) else 0)
    if r.random() < 0.15:
        c |= r.getrandbits(32) & 0x60000000          # unused-bit noise: bits 29, 30
    ops = [(ch * 16, madr), (ch * 16 + 4, bcr)]
    if order is None:
        order = r.random() < 0.5
    if order:
        ops.reverse()
    for a, d in ops:
        p.bw(a, d)
        p.gap(r.choice((0, 0, 1, 3)))
    p.bw(ch * 16 + 8, c)
    p.xfers[(ch, todev, sync)] = p.xfers.get((ch, todev, sync), 0) + 1


def dpcr_dicr(p, r, enable_mask, rand_all=True):
    v = 0
    for c in range(7):
        pr = r.randint(0, 7)
        en = 1 if (enable_mask >> c) & 1 or (rand_all and r.random() < 0.3) else 0
        v |= (pr | en << 3) << (4 * c)
    v |= r.choice((0, 0, 8)) << 28 if r.random() < 0.3 else 0
    p.bw(0x70, v)
    d = r.getrandbits(32) & 0x00FFFFFF
    if r.random() < 0.7:
        d |= 0x00800000 | (enable_mask << 16)
    d &= ~0x8000 if r.random() < 0.9 else 0xFFFFFFFF
    p.bw(0x74, d | (r.getrandbits(7) << 24 if r.random() < 0.3 else 0))


def readback(p, r, chans):
    for c in chans:
        for w in (0, 4, 8):
            p.br(c * 16 + w)
    p.br(0x70)
    p.br(0x74)
    if r.random() < 0.5:
        p.br(r.choice((0x0C, 0x1C, 0x7C, 0x78, 0x5C, 0x6C)))
        p.br(0x70 + r.choice((8, 12)))


def size_for(r, ch, sync, todev, big=False):
    if sync == 2:
        return r.randint(1, 12)
    if ch == 3:
        return r.choice((1, 2, 3, 4, 8, 16, 33, 64, 200)) if not big else r.randint(200, 1500)
    if ch == 4:
        return r.choice((1, 2, 3, 4, 8, 16, 33, 64)) if not big else r.randint(100, 400)
    if ch == 6:
        return r.choice((1, 2, 3, 4, 8, 16, 33, 64, 130, 300)) if not big else r.randint(500, 3000)
    return r.choice((1, 2, 3, 4, 5, 8, 16, 32, 65, 100)) if not big else r.randint(100, 800)


def scenario(p, r, suite):
    """One random scenario: 1..3 channels programmed back to back, then wait."""
    p.scen += 1
    p.add("# scenario %d" % p.scen)
    if r.random() < 0.6:
        p.dev()
    n = r.choice((1, 1, 1, 2, 2, 3))
    chans = r.sample(range(7), n)
    clear_all(p)                             # no trigger or channelOn left over from an earlier scenario
    mask = 0
    for c in chans:
        mask |= 1 << c
    dpcr_dicr(p, r, mask)
    for c in chans:
        todev = r.choice(DIRS[c]) if r.random() < 0.4 else r.choice(PRIMARY[c])
        if c in (0, 1):
            todev = 1 if c == 0 else 0
        sync = r.choice((0, 0, 1, 2)) if (todev or c in (2,)) else r.choice((0, 0, 1))
        if sync == 2 and not todev:
            sync = 1
        if c == 5:
            sync = r.choice((0, 1, 2))
        chop = 1 if (sync == 0 and r.random() < 0.3) else 0
        program_channel(p, r, c, todev, sync, r.random() < 0.3, chop, size_for(r, c, sync, todev, big=r.random() < 0.08 and suite != "wild"),
                        boundary=r.random() < 0.3)
        p.gap(r.choice((0, 0, 2, 7)))
    if suite == "wild":
        for _ in range(r.randint(2, 8)):
            p.gap(r.randint(0, 40))
            chan = r.choice(chans)
            kind = r.random()
            if kind < 0.35:
                p.br(chan * 16 + r.choice((0, 4, 8)))
            elif kind < 0.45:
                p.br(r.choice((0x70, 0x74, 0x7C, 0x0C)))
            elif kind < 0.7:
                if r.random() < 0.5:
                    p.bw(chan * 16, r.randrange(0, 0x1F0000, 4))
                else:
                    p.bw(chan * 16 + 4, (r.getrandbits(32) & 0x0003003F) | 0x00010001)
            elif kind < 0.85:
                sync = r.choice((0, 1))
                dd = 1 if chan == 0 else 0 if chan == 1 else r.randint(0, 1)
                p.bw(chan * 16 + 4, (r.getrandbits(32) & 0x0003003F) | 0x00010001)   # a chopped transfer leaves BCR = 0
                p.bw(chan * 16 + 8, chcr(dd, r.randint(0, 1), 0, sync, r.randint(0, 7), r.randint(0, 7), r.randint(0, 1), r.randint(0, 1)))
            else:
                p.bw(0x74, r.getrandbits(32))
    if r.random() < 0.15:
        p.add("PAUSE %d" % r.randint(1, 30))
    p.idle()
    readback(p, r, chans)
    p.gap(r.randint(0, 20))


def directed(p, r):
    p.dev(gpu=5, mdw=5, mdr=5, spu=5, fifo=100, busy=3)
    p.add("DEV 3 3 3 3 100 1 3 0 2 3")
    for ch in range(7):
        for todev in DIRS[ch]:
            for sync in (0, 1, 2):
                if sync == 2 and not todev:
                    continue
                for neg in (0, 1):
                    for chop in ((0, 1) if sync == 0 else (0,)):
                        p.scen += 1
                        p.add("# directed ch=%d todev=%d sync=%d neg=%d chop=%d" % (ch, todev, sync, neg, chop))
                        clear_all(p)
                        dpcr_dicr(p, r, 1 << ch, rand_all=False)
                        program_channel(p, r, ch, todev, sync, neg, chop, r.choice((3, 5, 9, 17, 40)), order=(neg == 1))
                        p.idle()
                        readback(p, r, [ch])
    # chopping edges: BCR around the slice size, and BCR = 0 (65536 words)
    p.add("# chop edges")
    for cdma in (0, 1, 3, 7):
        cs = 1 << cdma
        for bcr in sorted({cs - 1 if cs > 1 else 2, cs, cs + 1, 2 * cs, 2 * cs + 1, 3 * cs}):
            clear_all(p)
            dpcr_dicr(p, r, 1 << 6, rand_all=False)
            p.bw(0x60, madr_pick(r))
            p.bw(0x64, bcr)
            p.bw(0x68, chcr(0, 1, 1, 0, cdma, r.randint(0, 3)))
            p.idle()
            p.br(0x64)
            p.br(0x60)
    clear_all(p)
    dpcr_dicr(p, r, 1 << 6, rand_all=False)
    p.bw(0x60, 0x100000)
    p.bw(0x64, 0)
    p.bw(0x68, chcr(0, 1, 1, 0, 7, 0))
    p.idle()
    p.br(0x64)
    # a register write of the starting channel around the start cycle: the golden loads the old values and writes
    # its working copy back at the end
    p.add("# write at start")
    p.add("DEV 0 0 0 0 100 1 3 0 2 0")
    for ch, req in ((2, "1 0 0 0"), (4, "0 0 0 1"), (0, "0 1 0 0"), (1, "0 0 1 0")):
        for n in range(0, 7):
            for what in (0, 4, 8):
                clear_all(p)
                p.add("REQ 0 0 0 0")
                dpcr_dicr(p, r, 1 << ch, rand_all=False)
                dd = 1 if ch in (0, 2, 4) else 0
                p.bw(ch * 16, madr_pick(r))
                p.bw(ch * 16 + 4, 0x00020006)
                p.bw(ch * 16 + 8, chcr(dd, 0, 0, 1, 0, 0, 1, 0))
                p.add("REQ " + req)
                p.gap(n)
                if what == 8:
                    p.bw(ch * 16 + 8, chcr(dd, 1, 0, 1, 0, 0, r.randint(0, 1), 0))
                else:
                    p.bw(ch * 16 + what, 0x00030004 if what == 4 else madr_pick(r))
                p.idle()
                p.add("REQ 0 0 0 0")
                p.br(ch * 16)
                p.br(ch * 16 + 4)
                p.br(ch * 16 + 8)
    p.add("DEV 3 3 3 3 100 1 3 0 2 3")
    # register file: every address, write patterns, read back, DPCR/DICR corner cases
    p.add("# register file")
    for ch in range(8):
        for w in (0, 4, 8, 12):
            p.br(ch * 16 + w)
    for ch in range(7):
        for pat in (0xFFFFFFFF, 0x00000000, 0xA5A5A5A5, 0x5A5A5A5A):
            p.bw(ch * 16, pat)
            p.bw(ch * 16 + 4, pat)
            p.br(ch * 16)
            p.br(ch * 16 + 4)
    for ch in range(7):
        for pat in (0x0, 0x00000002, 0x01000200, 0x00070707):
            dd = 1 if ch == 0 else 0 if ch == 1 else pat & 1
            p.bw(ch * 16 + 8, (pat & ~0x11000001) | dd)
            p.br(ch * 16 + 8)
    for pat in (0xFFFFFFFF, 0, 0x76543210, 0x80FF0000, 0x00FF8000, 0x7F000000, 0x00800000 | 0x7F0000, 0x00007F00):
        p.bw(0x70, pat)
        p.br(0x70)
        p.bw(0x74, pat)
        p.br(0x74)
    for a in (0x78, 0x7C, 0x0C, 0x1C, 0x6C):
        p.bw(a, 0xFFFFFFFF)
        p.br(a)
    # DICR interrupt flags: transfers on every channel with the enable bits set, then acknowledge
    p.add("# irq")
    p.bw(0x70, 0x0FEDCBA9 | 0x08888888)
    p.bw(0x74, 0x00FF0000)
    for ch in (0, 1, 2, 3, 4, 6):
        program_channel(p, r, ch, 1 if ch == 0 else 0, 0, 0, 0, 4)
        p.idle()
        p.br(0x74)
    p.bw(0x74, 0x7F000000 | 0x00FF0000)
    p.br(0x74)
    p.bw(0x74, 0x00FF8000)
    p.br(0x74)


def boundary(p, r, count):
    """Start addresses at the 1 KB page edges (ram_cnt 0..3, both step directions, to and from the device)."""
    p.dev(fifo=70, busy=3)
    offs = (0xFC, 0xFD, 0xFE, 0xFF, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0xFB)
    for k in range(count):
        p.scen += 1
        p.add("# boundary %d" % k)
        clear_all(p)
        ch = (2, 4, 0, 2, 4, 6, 3, 1)[k % 8]
        todev = 1 if ch == 0 else 0 if ch == 1 else (k // 8) % 2 if ch in (2, 4) else r.choice(DIRS[ch])
        sync = r.choice((0, 0, 1))
        neg = (k // 3) % 2
        dpcr_dicr(p, r, 1 << ch, rand_all=False)
        if r.random() < 0.2:
            p.dev(fifo=r.choice((3, 5, 100)))
        size = r.choice((1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 31, 63, 64, 65, 129)) if ch != 6 else r.choice((1, 2, 255, 256, 257, 520))
        if ch == 6 and k % 17 == 0:
            size = 0                      # 65536 words
        madr = r.randrange(0x1000, 0x1F0000, 0x400) + offs[(k * 5 + k // 11) % len(offs)] * 4
        program_channel(p, r, ch, todev, sync, neg, 1 if (sync == 0 and r.random() < 0.2) else 0, size, madr=madr)
        p.idle()
        readback(p, r, [ch])


def turbo_suite(p, r, count):
    for k in range(count):
        p.cfg(r.randint(0, 1), r.randint(0, 1), r.randint(0, 1), r.randint(0, 1))
        scenario(p, r, "random")


def reset_suite(p, r, count):
    for k in range(count):
        p.scen += 1
        p.add("# reset %d" % k)
        clear_all(p)
        p.dev()
        ch = r.choice((2, 3, 4, 6, 0, 1))
        todev = 1 if ch == 0 else 0 if ch == 1 else r.choice(DIRS[ch])
        sync = r.choice((0, 1, 2)) if todev else r.choice((0, 1))
        dpcr_dicr(p, r, 1 << ch)
        program_channel(p, r, ch, todev, sync, r.randint(0, 1), 1 if (sync == 0 and r.random() < 0.3) else 0,
                        size_for(r, ch, sync, todev, big=True))
        p.gap(r.randint(0, 400))
        p.add("RST %d" % r.choice((8, 9, 12, 30, 61, 70)))
        p.gap(r.randint(0, 10))
        readback(p, r, [ch])
        scenario(p, r, "random")


def contention(p, r, count):
    """Several channels armed with the device requests low, then all requests rise together: arbitration by DPCR
    priority, ties to the higher channel, chop waits holding some channels back."""
    for k in range(count):
        p.scen += 1
        p.add("# contention %d" % k)
        p.add("DEV 0 0 0 0 %d 1 3 0 2 3" % r.choice((30, 100)))
        p.add("REQ 0 0 0 0")
        clear_all(p)
        n = r.randint(2, 4)
        chans = r.sample([0, 1, 2, 4], n) if r.random() < 0.8 else r.sample([0, 1, 2, 3, 4, 6], n)
        mask = 0
        for c in chans:
            mask |= 1 << c
        v = 0
        for c in range(7):
            pr = r.choice((0, 1, 1, 2, 3, 7)) if r.random() < 0.5 else r.randint(0, 7)
            v |= (pr | (8 if (mask >> c) & 1 else 0)) << (4 * c)
        p.bw(0x70, v)
        p.bw(0x74, r.getrandbits(32) & 0x00FFFFFF)
        for c in chans:
            todev = 1 if c == 0 else 0 if c == 1 else r.randint(0, 1)
            sync = 1 if c in (0, 1, 2, 4) else 0
            if c in (3, 6):
                todev = 0
                sync = 0
            if c in (2, 4) and todev and r.random() < 0.3:
                sync = 2
            # armed: start bit set, trigger bit clear so the channel waits for its request line (manual channels
            # cannot wait: they start at once)
            program_channel(p, r, c, todev, sync, r.randint(0, 1), 0, r.choice((2, 3, 5, 9)), extra_trig=False)
            p.gap(r.randint(0, 3))
        p.add("REQ 1 1 1 1")
        p.idle()
        p.add("REQ 0 0 0 0")
        readback(p, r, chans)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--suite", required=True)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--count", type=int, default=200)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    r = random.Random(a.seed * 7919 + 13)
    p = Prog(r)
    p.cfg()
    p.dev()
    for ch in range(8):                                # power-on state of every register
        for w in (0, 4, 8, 12):
            p.br(ch * 16 + w)
    p.br(0x78)
    if a.suite == "directed":
        directed(p, r)
    elif a.suite in ("random", "wild"):
        for _ in range(a.count):
            scenario(p, r, a.suite)
    elif a.suite == "contention":
        contention(p, r, a.count)
    elif a.suite == "boundary":
        boundary(p, r, a.count)
    elif a.suite == "turbo":
        turbo_suite(p, r, a.count)
    elif a.suite == "reset":
        reset_suite(p, r, max(4, a.count // 4))
    elif a.suite == "smoke":
        for ch in (2, 3, 4, 6):
            dpcr_dicr(p, r, 1 << ch)
            program_channel(p, r, ch, 0, 0, 0, 0, 12)
            p.idle()
        for _ in range(6):
            scenario(p, r, "random")
    else:
        sys.exit("unknown suite " + a.suite)
    p.add("END")
    open(a.out, "w").write("\n".join(p.lines) + "\n")
    sys.stderr.write("scenarios=%d lines=%d\n" % (p.scen, len(p.lines)))


if __name__ == "__main__":
    main()
