#!/usr/bin/env python3
"""Replay a gpu_diff VRAM trace against the Pocket's 16-bit SDRAM and report its load.

Model and assumptions: docs/pocket/GPU.md ("SDRAM bandwidth").
  bwmodel.py [options] TRACE...
Exit status 1 when --max-util is given and any trace's peak window utilisation exceeds it.
"""
import argparse
import sys

CLK2X_MHZ = 67.7376
LINE_US = 63.5555          # NTSC scanline


def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('traces', nargs='+')
    p.add_argument('--mhz', type=float, default=101.6064, help='SDRAM clock (3x clk1x)')
    p.add_argument('--cl', type=int, default=3, help='CAS latency, cycles')
    p.add_argument('--trcd', type=int, default=2)
    p.add_argument('--trp', type=int, default=2)
    p.add_argument('--trc', type=int, default=7, help='activate to activate, same bank')
    p.add_argument('--twr', type=int, default=2, help='write recovery before precharge')
    p.add_argument('--trfc', type=int, default=7, help='auto refresh cycle')
    p.add_argument('--refresh-us', type=float, default=7.8125, help='one auto refresh per interval')
    p.add_argument('--spu-mbps', type=float, default=5.0, help='SPU RAM traffic sharing the SDRAM')
    p.add_argument('--window-us', type=float, default=1000.0, help='utilisation window')
    p.add_argument('--max-util', type=float, default=None, help='fail if any window exceeds this (0..1)')
    return p.parse_args(argv)


class Sdram:
    """One command stream in arrival order; 4 banks; VRAM line y -> bank y%4, row y//4."""

    def __init__(self, a):
        self.a = a
        self.free = 0.0                # first cycle the controller can start the next access
        self.open_row = [None] * 4
        self.act_at = [-1e9] * 4       # last activate per bank
        self.wr_end = [-1e9] * 4       # last write data cycle per bank
        self.busy = []                 # (start, end) of every access, for the windows
        self.next_refresh = a.refresh_us * a.mhz

    def _refresh_until(self, t):
        a = self.a
        while self.next_refresh <= t:
            s = max(self.free, self.next_refresh)
            # precharge all, then refresh; rows are closed afterwards
            e = s + a.trp + a.trfc
            self.busy.append((s, e))
            self.free = e
            self.open_row = [None] * 4
            self.next_refresh += a.refresh_us * a.mhz

    def access(self, t, write, byte_addr, beats):
        a = self.a
        self._refresh_until(max(t, self.free))
        y = (byte_addr >> 11) & 0x1FF
        bank, row = y % 4, y // 4
        s = max(t, self.free)
        c = s
        if self.open_row[bank] != row:
            if self.open_row[bank] is not None:
                c = max(c, self.wr_end[bank] + a.twr)
                c += a.trp
            c = max(c, self.act_at[bank] + a.trc)
            self.act_at[bank] = c
            c += a.trcd
            self.open_row[bank] = row
        words = 4 * beats              # one 64-bit beat is four 16-bit words
        if write:
            e = c + words
            self.wr_end[bank] = e
        else:
            e = c + a.cl + words
        self.busy.append((s, e))
        self.free = e
        return s, e


def windows(busy, total, win):
    """Peak and mean utilisation over consecutive windows of `win` cycles."""
    n = int(total // win) + 1
    acc = [0.0] * n
    for s, e in busy:
        while s < e:
            i = int(s // win)
            if (i + 1) * win <= s:     # float rounding at a window boundary
                i += 1
            edge = min(e, (i + 1) * win)
            acc[i] += edge - s
            s = edge
    full = acc[:-1] if len(acc) > 1 else acc
    return max(full) / win, sum(acc) / total if total else 0.0


def run(path, a):
    ratio = a.mhz / CLK2X_MHZ
    sd = Sdram(a)
    scan_lat = []
    wait = 0.0
    last = 0.0
    with open(path) as f:
        for line in f:
            if not line.strip() or line.startswith('#'):
                continue
            cyc, rw, addr, beats, _be = line.split()
            t = int(cyc) * ratio
            s, e = sd.access(t, rw == 'W', int(addr, 16), int(beats))
            wait = max(wait, s - t)
            if rw == 'R' and int(beats) >= 64:   # line-sized reads: scan-out (and copies)
                scan_lat.append((e - t) / a.mhz)
            last = max(last, e)
    total = last
    # SPU traffic as a uniform extra load
    spu = a.spu_mbps / (2 * a.mhz)
    peak, mean = windows(sd.busy, total, a.window_us * a.mhz)
    line_peak, _ = windows(sd.busy, total, LINE_US * a.mhz)
    return {
        'trace': path, 'accesses': len(sd.busy), 'ms': total / a.mhz / 1000,
        'mean': mean + spu, 'peak': peak + spu, 'line_peak': line_peak + spu,
        'scan_max_us': max(scan_lat, default=0.0), 'scan_reads': len(scan_lat),
        'max_wait_us': wait / a.mhz,
    }


def main(argv):
    a = parse_args(argv)
    worst = 0.0
    for t in a.traces:
        r = run(t, a)
        worst = max(worst, r['peak'])
        print(f"BW {r['trace']}: {r['accesses']} accesses over {r['ms']:.2f} ms  "
              f"mean {100*r['mean']:.1f}%  peak/{a.window_us:g}us {100*r['peak']:.1f}%  "
              f"peak/line {100*r['line_peak']:.1f}%  scan-out reads {r['scan_reads']} "
              f"max latency {r['scan_max_us']:.2f} us  max queue wait {r['max_wait_us']:.2f} us")
    verdict = ''
    if a.max_util is not None:
        verdict = 'PASS' if worst <= a.max_util else 'FAIL'
    print(f"BW worst peak {100*worst:.1f}% {verdict}".rstrip())
    return 1 if verdict == 'FAIL' else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
