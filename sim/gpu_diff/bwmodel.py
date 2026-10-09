#!/usr/bin/env python3
"""Replay a gpu_diff VRAM trace against the Pocket's 16-bit SDRAM and report its load, or predict
memtest's closed-loop MIXED / MIXED UNDER SCAN throughput with the same controller model.

Model and assumptions: docs/pocket/GPU.md ("SDRAM bandwidth").
  bwmodel.py [options] TRACE...
  bwmodel.py --mixed [--scan] [--rnd-read] [options]
Timings come from pocket/common/mem/sdram_timing.json (generated from the datasheet table);
they are converted per clock, so --mhz alone changes the clock.
The peak is over a sliding window (any start cycle, complete windows only). SPU traffic is interleaved on
spu.vhd's per-sample schedule, one BL4 burst per 16-bit access (--spu-voices, --spu-reverb, --spu-dma).
Each trace is replayed a second time with every byte enable forced to 0xFF and must produce identical busy
intervals (partial writes are free).
Model v2 options (all off by default; the printed figures then do not change): --spu-cache, --tex-lines,
--lookahead, --closed-loop, --qos, --deadlines. Assumptions: docs/pocket/GPU.md ("SDRAM bandwidth").
Exit status 1 when --max-util is given and any trace's peak window utilisation exceeds it; 2 when a trace
has no accesses or is shorter than one window.
"""
import argparse
import json
import math
import bisect
import collections
import os
import sys

CLK2X_MHZ = 67.7376
LINE_US = 63.5555          # NTSC scanline
HERE = os.path.dirname(os.path.abspath(__file__))
TIMING_JSON = os.path.join(HERE, '..', '..', 'pocket', 'common', 'mem', 'sdram_timing.json')
NAMES = ('tRCD', 'tRP', 'tRAS', 'tRC', 'tWR', 'tRRD', 'tRFC')

# memtest scan-out: 640 x 16-bit pixels = 160 bursts per line, 400 pixels at 6.3504 MHz per line
SC_BURSTS = 160
SC_LINE_US = 400 / 6.3504
SC_Y_WRAP = 480
SPU_ROW0 = 128             # first row past VRAM's 128 rows per bank
CLK1X_MHZ = 33.8688
SPU_SAMPLE = 768           # clk1x cycles per 44.1 kHz sample (spu.vhd sampleticks)
SPU_SLOT = 23              # clk1x cycles per voice slot with useSDRAM = '1' (spu.vhd RAM_WAIT)
G_READ_LAT = 8             # clk2x cycles from accept to first read beat in vram_model.vhd
SPU_BLOCK_SAMPLES = 28     # one 16-byte ADPCM block
SPU_PITCH = {'1x': (1.0,), '4x': (4.0,), 'mixed': (1.0, 2.0, 4.0)}   # voice i has pitch[i % len]


def load_table():
    with open(TIMING_JSON) as f:
        return json.load(f)


def to_cycles(entry, mhz):
    """The table's rule: cycles = max(min_clk, ceil(ns * MHz / 1000))."""
    return max(entry['min_clk'], math.ceil(entry['ns'] * mhz / 1000 - 1e-9))


def ref_cycles(table, mhz):
    return math.floor(table['refi_target_ns'] * mhz / 1000 + 1e-9)


def timings(table, mhz):
    t = {n: to_cycles(table['timing'][n], mhz) for n in NAMES}
    t['REF'] = ref_cycles(table, mhz)
    return t


def check_table(table):
    """The rule applied here must reproduce the table's own precomputed cycles."""
    for key, want in table['cycles'].items():
        got = timings(table, float(key))
        for n in NAMES + ('REF',):
            assert got[n] == want[n], f"{n} at {key} MHz: rule gives {got[n]}, table has {want[n]}"


def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('traces', nargs='*')
    p.add_argument('--mhz', type=float, default=135.4752, help='SDRAM clock')
    for n in NAMES:
        p.add_argument('--' + n.lower(), type=int, default=None, help=f'override the table\'s {n}, cycles (what-if)')
    p.add_argument('--cl', type=int, default=None, help='override the table\'s CAS latency, cycles (what-if)')
    p.add_argument('--refresh-us', type=float, default=None, help='override the refresh interval (what-if)')
    p.add_argument('--spu-voices', type=int, default=24, choices=range(25), metavar='0..24',
                   help='voices whose ADPCM data is in SDRAM: 2 halfword reads each per sample (0: no SPU traffic)')
    p.add_argument('--spu-reverb', choices=('onchip', 'sdram'), default='onchip',
                   help='reverb work area in the on-chip top 64 KiB, or in SDRAM: 10 reads + 4 writes per sample')
    p.add_argument('--spu-dma', type=int, default=0, choices=range(25), metavar='0..24',
                   help='SPU RAM transfer accesses per sample (one per voice slot at most)')
    p.add_argument('--spu-dma-write', action='store_true', help='with --spu-dma: transfers are writes')
    p.add_argument('--spu-cache', choices=sorted(SPU_PITCH), default=None, metavar='1x|4x|mixed',
                   help='per-voice 16-byte block cache: one 2-burst fill per 28/pitch samples instead of 2 reads per '
                        'sample; pitch 1x, 4x (every voice) or mixed (1x, 2x, 4x by voice). Reverb and transfers unchanged')
    p.add_argument('--tex-lines', type=int, default=0, metavar='N',
                   help='what-if: LRU of N 8-byte lines behind the trace\'s texture cache; single-beat reads that hit are dropped, '
                        'a write to a line evicts it')
    p.add_argument('--lookahead', action='store_true',
                   help='bank-aware early PRE/ACT for the next queued request, one request deep')
    p.add_argument('--closed-loop', action='store_true',
                   help='worst-case bound: each read blocks the next request until its data returns; prints the '
                        'draw-time inflation against a memory with G_READ_LAT fixed latency')
    p.add_argument('--qos', action='store_true',
                   help='arbiter priority: SPU, then scan-out reads (>= 64 beats), above GPU draw, at beat boundaries')
    p.add_argument('--deadlines', action='store_true',
                   help='count SPU slot overruns and late scan-out lines (always on with --qos)')
    p.add_argument('--force-engine', action='store_true', help=argparse.SUPPRESS)
    p.add_argument('--window-us', type=float, default=1000.0, help='sliding utilisation window')
    p.add_argument('--max-util', type=float, default=None, help='fail if any window exceeds this (0..1)')
    p.add_argument('--mixed', action='store_true', help="predict memtest's SDRAM mixed test instead of replaying traces")
    p.add_argument('--scan', action='store_true', help='with --mixed: scan-out stream active (MIXED UNDER SCAN)')
    p.add_argument('--rnd-read', action='store_true', help='with --mixed: reads only (SDRAM random read)')
    p.add_argument('--ops', type=int, default=1 << 16, help='with --mixed: bursts per run')
    p.add_argument('--seed', type=lambda s: int(s, 0), default=0x1234ABCD, help='with --mixed: traffic seed')
    a = p.parse_args(argv)
    if not a.mixed and not a.traces:
        p.error('give at least one TRACE, or --mixed')
    return a


class Sdram:
    """sdram_ctl's command timing, one request at a time: a request is decoded while the previous burst is
    on the bus, then PRE / ACT / CAS as its bank allows; no early row open for the next request.
    All times are SDRAM clock cycles; every request is one BL4 burst (four 16-bit words)."""

    def __init__(self, a, table):
        t = timings(table, a.mhz)
        for n in NAMES:
            v = getattr(a, n.lower())
            if v is not None:
                t[n] = v
        if a.refresh_us is not None:
            t['REF'] = math.floor(a.refresh_us * a.mhz)
        self.t = t
        self.cl = a.cl if a.cl is not None else table['cl']
        self.bl = table['bl']
        self.open_row = [None] * 4
        self.act_t = [-10**9] * 4       # last ACT per bank
        self.pre_ok = [0] * 4           # first cycle a PRE is allowed
        self.rcd_ok = [0] * 4           # first cycle a column command is allowed
        self.last_act = -10**9
        self.rd_ok = self.wr_ok = 0
        self.prev_cas = -2
        self.due_vis = t['REF'] + 1     # first cycle the refresh timer is visibly due
        self.busy = []                  # merged (start, end)
        self.refreshes = 0

    def _busy(self, s, e):
        if self.busy and s <= self.busy[-1][1]:
            if e > self.busy[-1][1]:
                self.busy[-1] = (self.busy[-1][0], e)
        else:
            self.busy.append((s, e))

    def accept_time(self, t):
        """Cycle at which a request that is valid from cycle t is taken (req_ready), refreshing first if due."""
        T = self.t
        a = max(t, self.prev_cas + 1)
        while a >= self.due_vis:
            start = max(self.prev_cas + 2, self.due_vis + 1)
            p = max(start, max(self.pre_ok))        # PRE ALL once every bank may precharge
            r = p + T['tRP']                        # REF
            run = r + T['tRFC']
            self._busy(start, run)
            self.open_row = [None] * 4
            self.due_vis = r + T['REF'] + 1
            self.refreshes += 1
            a = max(a, run)
        return a

    def write_slot(self, partial):
        """Data-bus cycles of one write burst. DQM masks bytes with zero latency, so a partial mask costs nothing."""
        return self.bl

    def access(self, a, write, bank, row, partial=False):
        """One BL4 burst accepted at cycle a. Returns (cas cycle, last read-data cycle)."""
        T = self.t
        d0 = a + 1                                  # the request is in the decode register
        if self.open_row[bank] == row:
            c0 = max(d0, self.rcd_ok[bank])
        else:
            if self.open_row[bank] is not None:
                p = max(d0, self.pre_ok[bank])
                act_min = p + T['tRP']
            else:
                act_min = d0
            at = max(act_min, self.act_t[bank] + T['tRC'], self.last_act + T['tRRD'])
            self.act_t[bank] = self.last_act = at
            self.open_row[bank] = row
            self.rcd_ok[bank] = at + T['tRCD']
            self.pre_ok[bank] = at + T['tRAS']
            c0 = self.rcd_ok[bank]
        c = max(c0, self.wr_ok if write else self.rd_ok)
        bl = self.bl
        self.rd_ok = c + bl
        if write:
            slot = self.write_slot(partial)
            self.wr_ok = c + slot
            self.pre_ok[bank] = c + slot + T['tWR']     # sdram_ctl loads BL - 1 + tWR; PRE issues when it reaches 0
        else:
            self.wr_ok = c + self.cl + bl + 2           # read-to-write turnaround, RD_TO_WR in sdram_ctl
            if self.pre_ok[bank] - c < bl:
                self.pre_ok[bank] = c + bl + 1
        self.prev_cas = c
        self._busy(d0, c + bl)                      # busy from decode to the end of the data slot
        return c, c + self.cl + bl + 2


    def preopen(self, bank, row, after):
        """Lookahead: PRE / ACT the next queued request's row from cycle `after`, under the same bank limits."""
        if self.open_row[bank] == row:
            return
        T = self.t
        if self.open_row[bank] is not None:
            act_min = max(after, self.pre_ok[bank]) + T['tRP']
        else:
            act_min = after
        at = max(act_min, self.act_t[bank] + T['tRC'], self.last_act + T['tRRD'])
        self.act_t[bank] = self.last_act = at
        self.open_row[bank] = row
        self.rcd_ok[bank] = at + T['tRCD']
        self.pre_ok[bank] = at + T['tRAS']


class TraceError(Exception):
    pass


def windows(busy, total, win):
    """Peak utilisation over any window of `win` cycles inside [0, total], and the mean over [0, total].

    Busy time in [t, t + win] is piecewise linear in t and peaks where t is an interval start or t + win an
    interval end (or at the trace edges), so those candidates are evaluated exactly from prefix sums.
    Only complete windows count; a trace shorter than one window has no peak."""
    if total < win:
        raise TraceError(f"trace is {total / win:.3f} of one window")
    starts = [s for s, _ in busy]
    pre = [0]
    for s, e in busy:
        pre.append(pre[-1] + (e - s))

    def F(x):                                   # busy cycles in [0, x]
        k = bisect.bisect_right(starts, x) - 1
        if k < 0:
            return 0
        return pre[k] + min(busy[k][1], x) - busy[k][0]

    cand = {0, total - win}
    for s, e in busy:
        cand.update((s, e - win))
    peak = max(F(t + win) - F(t) for t in cand if 0 <= t <= total - win)
    return peak / win, F(total) / total


def vram_bank_row(byte_addr):
    """VRAM line y = byte address / 2048: bank y%4, row y//4."""
    y = (byte_addr >> 11) & 0x1FF
    return y % 4, y // 4


def spu_sample(a):
    """One sample's SPU RAM accesses that reach SDRAM: (clk1x offset, write, kind), in spu.vhd's order.
    Voice slot i (from 23 i): header read, then a data read in the same 16-byte block, then the slot's
    transfer access; reverb after the 24 slots. Capture writes and the top 64 KiB are on-chip (spu_ram.vhd).
    With --spu-cache the voices' reads are replaced by block fills (spu_stream); transfers and reverb stay."""
    acc = []
    for i in range(24):
        if i < a.spu_voices and not a.spu_cache:
            acc += [(SPU_SLOT * i, False, 'hdr'), (SPU_SLOT * i, False, 'data')]
        if i < a.spu_dma:
            acc.append((SPU_SLOT * i, a.spu_dma_write, 'dma'))
    if a.spu_reverb == 'sdram':
        rv = 24 * SPU_SLOT
        acc += [(rv, False, 'rev')] * 4 + [(rv, True, 'rev')] * 2 + [(rv, False, 'rev')] * 6 + [(rv, True, 'rev')] * 2
    return acc


def spu_pitch(a, i):
    p = SPU_PITCH[a.spu_cache]
    return p[i % len(p)]


def spu_rate(a):
    """SPU SDRAM accesses per second: (reads, writes). A cached voice fills 2 bursts per 28 / pitch samples."""
    acc = spu_sample(a)
    w = sum(1 for _, wr, _ in acc if wr)
    rd = len(acc) - w
    if a.spu_cache:
        return rd * 44100.0 + sum(2 * spu_pitch(a, i) / SPU_BLOCK_SAMPLES for i in range(a.spu_voices)) * 44100.0, w * 44100.0
    return rd * 44100.0, w * 44100.0


def spu_stream(a):
    """Every SPU access in time order as (clk1x time, write, kind, word). word None: drawn from the random
    stream by the consumer. A cached voice keeps a phase in samples and a sequential block pointer (halfwords):
    each time the phase passes 28 it fills the next 16-byte block, two BL4 bursts, in its own slot."""
    sample = spu_sample(a)
    if not a.spu_cache:
        if not sample:
            return
        k = 0
        while True:
            for off, write, kind in sample:
                yield k * SPU_SAMPLE + off, write, kind, None
            k += 1
    rnd = 0x9E3779B1
    ptr, phase = [], []
    for i in range(a.spu_voices):
        rnd = xs32(rnd)
        ptr.append(rnd & 0x3FFF8)                           # 16-byte aligned, 512 KiB
        phase.append((rnd >> 20) % SPU_BLOCK_SAMPLES)
    rest = sample
    k = 0
    while True:
        out = []
        for i in range(a.spu_voices):
            phase[i] += spu_pitch(a, i)
            if phase[i] >= SPU_BLOCK_SAMPLES:
                phase[i] -= SPU_BLOCK_SAMPLES
                out += [(SPU_SLOT * i, False, 'fill', ptr[i]), (SPU_SLOT * i, False, 'fill', ptr[i] + 4)]
                ptr[i] = (ptr[i] + 8) & 0x3FFFF
        out += [(off, wr, kind, None) for off, wr, kind in rest]
        out.sort(key=lambda x: x[0])
        for off, write, kind, word in out:
            yield k * SPU_SAMPLE + off, write, kind, word
        k += 1


def spu_addr(kind, word, cur, rnd):
    """The halfword address of an SPU access and the next random state."""
    if word is not None:
        return word, xs32(rnd)
    if kind == 'data':
        return cur + 1 + (rnd & 6), xs32(rnd)             # same 16-byte block as the header
    return ((rnd & 0x3FFF8) if kind == 'hdr' else rnd & 0x3FFFF), xs32(rnd)


def replay_fast(path, a, table, full_mask=False):
    """Replay one trace (open loop) with the SPU accesses interleaved by time. full_mask forces every BE to 0xFF."""
    ratio = a.mhz / CLK2X_MHZ
    sd = Sdram(a, table)
    sample = spu_sample(a)
    spu_cyc = a.mhz / CLK1X_MHZ                             # SDRAM cycles per clk1x cycle
    spu_n = 0                                               # next access, counted over all samples
    spu_ready = 0                                           # one SPU request outstanding at a time
    spu_rnd = 0x2545F491
    spu_word = 0
    scan_lat = []
    wait = 0
    last = 0
    n_acc = n_partial = 0

    def spu_until(t):
        nonlocal spu_n, spu_ready, spu_rnd, spu_word
        while sample:
            k, i = divmod(spu_n, len(sample))
            off, write, kind = sample[i]
            due = max(math.ceil((k * SPU_SAMPLE + off) * spu_cyc), spu_ready)
            if due > t:
                return
            if kind == 'data':
                spu_word += 1 + (spu_rnd & 6)                   # same 16-byte block as the header
            else:
                spu_word = (spu_rnd & 0x3FFF8) if kind == 'hdr' else spu_rnd & 0x3FFFF   # random, 512 KiB
            spu_rnd = xs32(spu_rnd)
            c, e = sd.access(sd.accept_time(due), write, (spu_word >> 10) & 3, SPU_ROW0 + (spu_word >> 12))
            spu_ready = (c + sd.bl if write else e) + 1
            spu_n += 1

    with open(path) as f:
        for line in f:
            if not line.strip() or line.startswith('#'):
                continue
            cyc, rw, addr, beats, be = line.split()
            n_acc += 1
            write = rw == 'W'
            beats = int(beats)
            n_partial += write and int(be, 16) != 0xFF
            if full_mask:
                be = 'FF'
            partial = write and int(be, 16) != 0xFF
            t = math.ceil(int(cyc) * ratio)
            spu_until(t)
            base = int(addr, 16)
            e = 0
            for i in range(beats):                  # one 64-bit beat = one BL4 burst
                bank, row = vram_bank_row(base + 8 * i)
                acc = sd.accept_time(t)
                wait = max(wait, acc - t)
                c, e = sd.access(acc, write, bank, row, partial)
            last = max(last, e if not write else sd.prev_cas + sd.bl)
            if not write and beats >= 64:           # line-sized reads: scan-out (and copies)
                scan_lat.append((e - t) / a.mhz)
    if n_acc == 0:
        raise TraceError("no accesses")
    return sd, last, n_acc, n_partial, scan_lat, wait


def load_items(path, a, ratio, full_mask):
    """The trace as [arrival, write, byte address, beats, partial, scan-out, beats issued] per access.
    --tex-lines: single-beat reads that hit an LRU of 8-byte lines are dropped; a write evicts the lines it covers."""
    items = []
    n_acc = n_partial = hits = 0
    lru = collections.OrderedDict() if a.tex_lines > 0 else None
    with open(path) as f:
        for line in f:
            if not line.strip() or line.startswith('#'):
                continue
            cyc, rw, addr, beats, be = line.split()
            n_acc += 1
            write = rw == 'W'
            beats = int(beats)
            base = int(addr, 16)
            partial = write and int(be, 16) != 0xFF
            n_partial += partial
            if lru is not None:
                if write:
                    for i in range(beats):
                        lru.pop((base >> 3) + i, None)
                elif beats == 1:
                    key = base >> 3
                    if key in lru:
                        lru.move_to_end(key)
                        hits += 1
                        continue
                    lru[key] = 1
                    if len(lru) > a.tex_lines:
                        lru.popitem(last=False)
            items.append([math.ceil(int(cyc) * ratio), write, base, beats, partial and not full_mask,
                          not write and beats >= 64, 0])
    return items, n_acc, n_partial, hits


def replay_engine(path, a, table, full_mask=False):
    """Event-driven replay of the same open-loop model plus the v2 options. Sources: the GPU trace (scan-out
    reads are the >= 64-beat reads) and the SPU. Without --qos the oldest request goes first, a GPU access in
    one train; with it, a beat at a time: SPU, then scan-out, then draw. --closed-loop holds the next trace
    access until the previous read's data has returned and moves every later access by the stall."""
    ratio = a.mhz / CLK2X_MHZ
    sd = Sdram(a, table)
    items, n_acc, n_partial, tex_hits = load_items(path, a, ratio, full_mask)
    if n_acc == 0 or not items:
        raise TraceError("no accesses")
    n = len(items)
    spu_cyc = a.mhz / CLK1X_MHZ
    line_cyc = LINE_US * a.mhz
    qos, closed, look = a.qos, a.closed_loop, a.lookahead
    count = a.qos or a.deadlines
    lat0 = math.ceil(G_READ_LAT * ratio)
    ref_total = 0
    if closed:                                              # the same serialisation on a memory with G_READ_LAT latency
        shift = ready = 0
        for it in items:
            te = max(it[0] + shift, ready)
            shift = te - it[0]
            ready = te if it[1] else te + lat0
            ref_total = max(ref_total, ready)
    stream = spu_stream(a)
    spu_cur = next(stream, None)
    spu_ts = math.ceil(spu_cur[0] * spu_cyc) if spu_cur else 0
    spu_blocked = False
    spu_word, spu_rnd = 0, 0x2545F491
    spu_reads = spu_over = scan_late = 0
    qs, qd = collections.deque(), collections.deque()
    gi = 0
    shift = ready = 0
    gblocked = False
    inprog = None
    t_end = None
    free = 0
    wait = last = 0
    scan_lat = []
    SPU = 'S'

    def spu_avail(t):
        return spu_cur is not None and not spu_blocked and spu_ts <= t and (t_end is None or spu_ts <= t_end)

    def admit(t):
        nonlocal gi, shift, gblocked, t_end
        while gi < n and not gblocked:
            it = items[gi]
            te = max(it[0] + shift, ready)
            if te > t:
                return
            shift = te - it[0]
            it[0] = te
            (qs if qos and it[5] else qd).append(it)
            gi += 1
            if gi == n:
                t_end = te
            if closed and not it[1]:
                gblocked = True

    def choose(t):
        if inprog is not None:
            return inprog
        sp = spu_avail(t)
        if qos:
            if sp:
                return SPU
            if qs:
                return qs[0]
            return qd[0] if qd else None
        g = qd[0] if qd else None
        if sp and (g is None or spu_ts <= g[0]):
            return SPU
        return g

    while True:
        admit(free)
        if inprog is None and not qs and not qd and not spu_avail(free):
            cand = []
            if gi < n and not gblocked:
                cand.append(max(items[gi][0] + shift, ready))
            if spu_cur is not None and not spu_blocked and (t_end is None or spu_ts <= t_end):
                cand.append(spu_ts)
            if not cand:
                break
            free = max(free, min(cand))
        t = sd.accept_time(free)
        admit(t)
        cur = choose(t)
        if cur is None:
            free = t + 1
            continue
        nxt = None
        if cur is SPU:
            t1x, write, kind, word = spu_cur
            spu_word, spu_rnd = spu_addr(kind, word, spu_word, spu_rnd)
            bank, row = (spu_word >> 10) & 3, SPU_ROW0 + (spu_word >> 12)
            spu_blocked = True
            partial = False
        else:
            write = cur[1]
            bank, row = vram_bank_row(cur[2] + 8 * cur[6])
            partial = cur[4]
            cur[6] += 1
            done = cur[6] == cur[3]
            if done:
                (qs if qos and cur[5] else qd).popleft()
                if inprog is cur:
                    inprog = None
            elif not qos:
                inprog = cur
            wait = max(wait, t - cur[0])
            if closed and done and not write:
                gblocked = True
        if look:
            nx = choose(t)
            if nx is SPU:
                w, _ = spu_addr(spu_cur[2], spu_cur[3], spu_word, spu_rnd)
                nxt = ((w >> 10) & 3, SPU_ROW0 + (w >> 12))
            elif nx is not None:
                nxt = vram_bank_row(nx[2] + 8 * nx[6])
        c, e = sd.access(t, write, bank, row, partial)
        if nxt is not None:
            sd.preopen(nxt[0], nxt[1], t + 1)
        free = sd.prev_cas + 1
        if cur is SPU:
            spu_ready = (c + sd.bl if write else e) + 1
            if count and not write:
                spu_reads += 1
                spu_over += e > math.ceil((t1x + SPU_SLOT) * spu_cyc)
            spu_cur = next(stream, None)
            if spu_cur is not None:
                spu_ts = max(math.ceil(spu_cur[0] * spu_cyc), spu_ready)
            spu_blocked = False
        else:
            last = max(last, e if not write else sd.prev_cas + sd.bl)
            if done:
                if closed and not write:
                    ready = e
                    gblocked = False
                if cur[5]:
                    scan_lat.append((e - cur[0]) / a.mhz)
                    scan_late += e - cur[0] > line_cyc
    return {'sd': sd, 'total': last, 'n_acc': n_acc, 'n_partial': n_partial, 'scan_lat': scan_lat, 'wait': wait,
            'tex_hits': tex_hits, 'spu_reads': spu_reads, 'spu_over': spu_over, 'scan_late': scan_late,
            'ref_total': ref_total}


def replay(path, a, table, full_mask=False):
    if not (a.force_engine or a.spu_cache or a.tex_lines or a.lookahead or a.closed_loop or a.qos or a.deadlines):
        sd, total, n_acc, n_partial, scan_lat, wait = replay_fast(path, a, table, full_mask)
        return {'sd': sd, 'total': total, 'n_acc': n_acc, 'n_partial': n_partial, 'scan_lat': scan_lat,
                'wait': wait, 'tex_hits': 0, 'spu_reads': 0, 'spu_over': 0, 'scan_late': 0, 'ref_total': 0}
    return replay_engine(path, a, table, full_mask)


def run(path, a, table):
    r = replay(path, a, table)
    sd, total = r['sd'], r['total']
    full = replay(path, a, table, full_mask=True)
    assert sd.busy == full['sd'].busy and total == full['total'], \
        "partial byte enables changed the timing: DQM has zero write latency, partial writes must be free"
    peak, mean = windows(sd.busy, total, a.window_us * a.mhz)
    line_peak, _ = windows(sd.busy, total, LINE_US * a.mhz)
    scan_lat = r['scan_lat']
    return {
        'trace': path, 'accesses': r['n_acc'], 'ms': total / a.mhz / 1000, 'partial': r['n_partial'],
        'mean': mean, 'peak': peak, 'line_peak': line_peak,
        'scan_max_us': max(scan_lat, default=0.0), 'scan_reads': len(scan_lat),
        'max_wait_us': r['wait'] / a.mhz, 'refreshes': sd.refreshes, 'full_mask_diff': total - full['total'],
        'tex_hits': r['tex_hits'], 'spu_reads': r['spu_reads'], 'spu_over': r['spu_over'],
        'scan_late': r['scan_late'], 'inflation': total / r['ref_total'] - 1 if r['ref_total'] else None,
        'ref_ms': r['ref_total'] / a.mhz / 1000,
    }


def xs32(x):
    x ^= (x << 13) & 0xFFFFFFFF
    x ^= x >> 17
    x ^= (x << 5) & 0xFFFFFFFF
    return x


def run_mixed(a, table, full_mask=False):
    """memtest's closed loop (sd_traffic.v, sd_scan.v, sdram_arb.v): the test engine always has its next burst
    waiting; with the scan-out stream fetching, the round-robin arbiter alternates the two. A burst is a
    word address {row[24:12], bank[11:10], col[9:0]}; the test uses 2^17 bursts from address 0."""
    sd = Sdram(a, table)
    cl = sd.cl
    line_cycles = round(SC_LINE_US * a.mhz)
    rnd = a.seed | 1
    t_a = 1                                          # the test engine's request is valid
    next_wrap = line_cycles
    b_active = False
    b_issued = 0
    b_valid = 0
    b_y = 0
    b_start = 0
    last_b = False
    lines = late = 0
    worst = 0
    last_end = 0
    done_ops = 0
    while done_ops < a.ops:
        acc = sd.accept_time(t_a)
        if not b_active and a.scan and next_wrap <= acc:
            b_active, b_issued, b_start, b_valid = True, 0, next_wrap, next_wrap + 2
            next_wrap += line_cycles
        if b_active and b_valid <= acc and not last_b:
            word = (b_y << 10) | (b_issued << 2)
            c, e = sd.access(acc, False, (word >> 10) & 3, word >> 12)
            last_b = True
            b_issued += 1
            b_valid = acc + 1
            if b_issued == SC_BURSTS:
                done = e + 2
                b_active = False
                b_y = 0 if b_y == SC_Y_WRAP - 1 else b_y + 1
                lines += 1
                worst = max(worst, done - b_start)
                if done > b_start + line_cycles:
                    late += 1
                    next_wrap = (done // line_cycles + 1) * line_cycles
            continue                                 # the test engine's request stays valid, taken next
        # test engine: its next burst is valid the cycle after this one is taken
        idx = rnd & 0x1FFFF
        write = False if a.rnd_read else bool((rnd >> 20) & 1)
        rnd = xs32(rnd)
        word = idx << 2
        c, e = sd.access(acc, write, (word >> 10) & 3, word >> 12, partial=write and not full_mask)  # MIXED writes carry random masks
        last_b = False
        last_end = max(last_end, e)
        done_ops += 1
        t_a = acc + 1
    cycles = last_end + 12                           # read return, then the 11-cycle drain
    return {'ops': a.ops, 'cycles': cycles, 'mbps': 8 * a.ops * a.mhz / cycles, 'lines': lines,
            'late': late, 'worst_us': worst / a.mhz, 'refreshes': sd.refreshes}


def main(argv):
    a = parse_args(argv)
    table = load_table()
    check_table(table)
    if a.mixed:
        r = run_mixed(a, table)
        assert r['cycles'] == run_mixed(a, table, full_mask=True)['cycles'], \
            "partial byte enables changed the timing: DQM has zero write latency, partial writes must be free"
        name = ('SDRAM random read' if a.rnd_read else 'MIXED') + (' UNDER SCAN' if a.scan else '')
        extra = f"  scan-out lines {r['lines']} late {r['late']} worst {r['worst_us']:.1f} us" if a.scan else ''
        print(f"BW {name} @ {a.mhz:g} MHz: {r['ops']} bursts in {r['cycles']} cycles "
              f"= {r['mbps']:.1f} MB/s (bench bytes only){extra}  refreshes {r['refreshes']}")
        return 0
    rd, wr = spu_rate(a)
    cache = f", block cache at {a.spu_cache} pitch" if a.spu_cache else ''
    print(f"BW SPU: {a.spu_voices} voices{cache}, reverb {a.spu_reverb}, {a.spu_dma} transfers per sample"
          f" = {rd / 1e6:.2f} M reads/s + {wr / 1e6:.2f} M writes/s, one BL4 burst each")
    opts = [o for o, on in (('lookahead', a.lookahead), ('closed-loop', a.closed_loop), ('qos', a.qos),
                            (f'tex-lines {a.tex_lines}', a.tex_lines)) if on]
    if opts:
        print(f"BW options: {', '.join(opts)}")
    worst = 0.0
    for t in a.traces:
        try:
            r = run(t, a, table)
        except TraceError as e:
            print(f"BW ERROR {t}: {e} (window {a.window_us:g} us)", file=sys.stderr)
            return 2
        worst = max(worst, r['peak'])
        print(f"BW {r['trace']}: {r['accesses']} accesses over {r['ms']:.2f} ms  "
              f"mean {100*r['mean']:.1f}%  peak/{a.window_us:g}us {100*r['peak']:.1f}%  "
              f"peak/line {100*r['line_peak']:.1f}%  scan-out reads {r['scan_reads']} "
              f"max latency {r['scan_max_us']:.2f} us  max queue wait {r['max_wait_us']:.2f} us  "
              f"partial writes {r['partial']} (cycles vs full-mask run: {r['full_mask_diff']:+d})")
        if a.tex_lines:
            print(f"BW   tex-lines {a.tex_lines}: {r['tex_hits']} single-beat reads dropped")
        if a.closed_loop:
            print(f"BW   closed-loop: {r['ms']:.2f} ms vs {r['ref_ms']:.2f} ms at G_READ_LAT = {G_READ_LAT} clk2x"
                  f" = inflation {100*r['inflation']:+.1f}%")
        if a.qos or a.deadlines:
            print(f"BW   deadlines: SPU slot overruns {r['spu_over']} of {r['spu_reads']} reads, "
                  f"late scan-out lines {r['scan_late']} of {r['scan_reads']}")
    verdict = ''
    if a.max_util is not None:
        verdict = 'PASS' if worst <= a.max_util else 'FAIL'
    print(f"BW worst peak {100*worst:.1f}% at {a.mhz:g} MHz {verdict}".rstrip())
    return 1 if verdict == 'FAIL' else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
