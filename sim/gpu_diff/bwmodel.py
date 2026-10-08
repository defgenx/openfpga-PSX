#!/usr/bin/env python3
"""Replay a gpu_diff VRAM trace against the Pocket's 16-bit SDRAM and report its load, or predict
memtest's closed-loop MIXED / MIXED UNDER SCAN throughput with the same controller model.

Model and assumptions: docs/pocket/GPU.md ("SDRAM bandwidth").
  bwmodel.py [options] TRACE...
  bwmodel.py --mixed [--scan] [--rnd-read] [options]
Timings come from pocket/memtest/fpga/core/sdram_timing.json (generated from the datasheet table);
they are converted per clock, so --mhz alone changes the clock.
Exit status 1 when --max-util is given and any trace's peak window utilisation exceeds it; 2 when a trace
has no accesses or is shorter than one window.
"""
import argparse
import json
import math
import os
import sys

CLK2X_MHZ = 67.7376
LINE_US = 63.5555          # NTSC scanline
HERE = os.path.dirname(os.path.abspath(__file__))
TIMING_JSON = os.path.join(HERE, '..', '..', 'pocket', 'memtest', 'fpga', 'core', 'sdram_timing.json')
NAMES = ('tRCD', 'tRP', 'tRAS', 'tRC', 'tWR', 'tRRD', 'tRFC')

# memtest scan-out: 640 x 16-bit pixels = 160 bursts per line, 400 pixels at 6.3504 MHz per line
SC_BURSTS = 160
SC_LINE_US = 400 / 6.3504
SC_Y_WRAP = 480


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
    p.add_argument('--spu-mbps', type=float, default=5.0, help='SPU RAM traffic sharing the SDRAM')
    p.add_argument('--window-us', type=float, default=1000.0, help='utilisation window')
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
        self.rmw_cycles = 0             # read-modify-write cost charged: must stay 0 (DQM masks partial writes)

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

    def access(self, a, write, bank, row):
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
        self.rd_ok = c + 4
        if write:
            self.wr_ok = c + 4
            self.pre_ok[bank] = c + 4 + T['tWR']    # 3 + tWR after the write command
        else:
            self.wr_ok = c + self.cl + 6            # bus turnaround: CL + 5 after the read command
            if self.pre_ok[bank] - c < 4:
                self.pre_ok[bank] = c + 5
        self.prev_cas = c
        self._busy(d0, c + 4)                       # busy from decode to the end of the data slot
        return c, c + self.cl + 6


class TraceError(Exception):
    pass


def windows(busy, total, win):
    """Peak and mean utilisation over consecutive windows of `win` cycles.

    The peak covers complete windows only: a trailing partial window divided by `win` under-reports,
    divided by its own length it over-reports a short tail. A trace without one complete window has no peak."""
    n = int(total // win) + 1
    if n < 2:
        raise TraceError(f"trace is {total / win:.3f} of one window")
    acc = [0.0] * n
    for s, e in busy:
        while s < e:
            i = int(s // win)
            if (i + 1) * win <= s:     # float rounding at a window boundary
                i += 1
            edge = min(e, (i + 1) * win)
            acc[i] += edge - s
            s = edge
    return max(acc[:-1]) / win, sum(acc) / total


def vram_bank_row(byte_addr):
    """VRAM line y = byte address / 2048: bank y%4, row y//4."""
    y = (byte_addr >> 11) & 0x1FF
    return y % 4, y // 4


def run(path, a, table):
    ratio = a.mhz / CLK2X_MHZ
    sd = Sdram(a, table)
    scan_lat = []
    wait = 0
    last = 0
    n_acc = n_partial = 0
    with open(path) as f:
        for line in f:
            if not line.strip() or line.startswith('#'):
                continue
            cyc, rw, addr, beats, be = line.split()
            n_acc += 1
            write = rw == 'W'
            beats = int(beats)
            if write and int(be, 16) != 0xFF:
                n_partial += 1                      # DQM masks the bytes: costs nothing extra
            t = math.ceil(int(cyc) * ratio)
            base = int(addr, 16)
            e = 0
            for i in range(beats):                  # one 64-bit beat = one BL4 burst
                bank, row = vram_bank_row(base + 8 * i)
                acc = sd.accept_time(t)
                wait = max(wait, acc - t)
                c, e = sd.access(acc, write, bank, row)
            last = max(last, e if not write else sd.prev_cas + 4)
            if not write and beats >= 64:           # line-sized reads: scan-out (and copies)
                scan_lat.append((e - t) / a.mhz)
    if n_acc == 0:
        raise TraceError("no accesses")
    assert sd.rmw_cycles == 0, "a read-modify-write was charged: DQM has zero write latency, partial writes are free"
    total = last
    spu = a.spu_mbps / (2 * a.mhz)                  # SPU traffic as a uniform extra load
    peak, mean = windows(sd.busy, total, a.window_us * a.mhz)
    line_peak, _ = windows(sd.busy, total, LINE_US * a.mhz)
    return {
        'trace': path, 'accesses': n_acc, 'ms': total / a.mhz / 1000, 'partial': n_partial,
        'mean': mean + spu, 'peak': peak + spu, 'line_peak': line_peak + spu,
        'scan_max_us': max(scan_lat, default=0.0), 'scan_reads': len(scan_lat),
        'max_wait_us': wait / a.mhz, 'refreshes': sd.refreshes,
    }


def xs32(x):
    x ^= (x << 13) & 0xFFFFFFFF
    x ^= x >> 17
    x ^= (x << 5) & 0xFFFFFFFF
    return x


def run_mixed(a, table):
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
        c, e = sd.access(acc, write, (word >> 10) & 3, word >> 12)
        last_b = False
        last_end = max(last_end, e)
        done_ops += 1
        t_a = acc + 1
    assert sd.rmw_cycles == 0
    cycles = last_end + 12                           # read return, then the 11-cycle drain
    return {'ops': a.ops, 'cycles': cycles, 'mbps': 8 * a.ops * a.mhz / cycles, 'lines': lines,
            'late': late, 'worst_us': worst / a.mhz, 'refreshes': sd.refreshes}


def main(argv):
    a = parse_args(argv)
    table = load_table()
    check_table(table)
    if a.mixed:
        r = run_mixed(a, table)
        name = ('SDRAM random read' if a.rnd_read else 'MIXED') + (' UNDER SCAN' if a.scan else '')
        extra = f"  scan-out lines {r['lines']} late {r['late']} worst {r['worst_us']:.1f} us" if a.scan else ''
        print(f"BW {name} @ {a.mhz:g} MHz: {r['ops']} bursts in {r['cycles']} cycles "
              f"= {r['mbps']:.1f} MB/s (bench bytes only){extra}  refreshes {r['refreshes']}")
        return 0
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
              f"partial writes {r['partial']} (no cost)")
    verdict = ''
    if a.max_util is not None:
        verdict = 'PASS' if worst <= a.max_util else 'FAIL'
    print(f"BW worst peak {100*worst:.1f}% at {a.mhz:g} MHz {verdict}".rstrip())
    return 1 if verdict == 'FAIL' else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
