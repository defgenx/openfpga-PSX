#!/usr/bin/env python3
"""bwmodel.py regression: pins the figures with every v2 option off, then checks each option's direction.
  bwselftest.py [RUNDIR]        RUNDIR holds trace_s1.txt, trace_s2.txt, trace_s3.txt (default: run/ here); seeds 2 and 3 are pinned when present
Exit status 1 on the first mismatch group."""
import os
import re
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL = os.path.join(HERE, 'bwmodel.py')
LINE = re.compile(r'BW (\S+): (\d+) accesses over ([\d.]+) ms\s+mean ([\d.]+)%\s+peak/1000us ([\d.]+)%')
HEAD_LINES = 150000          # about 16 ms of s1, enough for several 1 ms windows

# (SDRAM MHz, extra options) -> peak/1000us on s1, s2, s3, with every v2 option off
PINS = [
    (135.4752, [], (91.2, 91.2, 90.9)),
    (116.1223, [], (98.7, 98.4, 99.2)),
    (121.9277, [], (98.2, 97.3, 98.7)),
    (101.6064, [], (99.9, 99.5, 99.7)),
    (116.1223, ['--spu-voices', '0'], (87.8, 86.9, 86.4)),
]

fails = []
checks = 0


def check(ok, what):
    global checks
    checks += 1
    print(('ok    ' if ok else 'FAIL  ') + what)
    if not ok:
        fails.append(what)


def model(mhz, opts, traces):
    out = subprocess.run([sys.executable, MODEL, '--mhz', str(mhz)] + opts + list(traces),
                         capture_output=True, text=True)
    if out.returncode:
        raise SystemExit(f"bwmodel failed ({out.returncode}): {opts}\n{out.stderr[-600:]}")
    return out.stdout


def rows(text):
    return [(m[1], int(m[2]), float(m[3]), float(m[4]), float(m[5])) for m in map(LINE.search, text.splitlines()) if m]


def field(text, pat, cast=float):
    m = re.search(pat, text)
    return cast(m[1]) if m else None


def write_trace(path, lines):
    with open(path, 'w') as f:
        f.write(''.join(f'{c} {rw} {a:07X} {b} FF\n' for c, rw, a, b in lines))


def main():
    run = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(HERE, 'run')
    full = [p for p in (os.path.join(run, f'trace_s{i}.txt') for i in (1, 2, 3)) if os.path.exists(p)]
    if not full or not full[0].endswith('trace_s1.txt'):
        print(f'bwselftest: no trace_s1.txt in {run}', file=sys.stderr)
        return 1
    tmp = tempfile.mkdtemp(prefix='bwselftest')
    head = os.path.join(tmp, 'head.txt')
    with open(full[0]) as f, open(head, 'w') as g:
        for _, line in zip(range(HEAD_LINES), f):
            g.write(line)

    # synthetic traces: SPU only (writes far apart), and a texture-read pattern with a write in the middle
    spu_only = os.path.join(tmp, 'spu_only.txt')
    write_trace(spu_only, [(0, 'W', 0x100000, 1), (80000, 'W', 0x100000, 1)])
    texpat = os.path.join(tmp, 'texpat.txt')
    seq = []
    for i in range(700):
        seq.append((i * 100, 'R', 0x1000 + 8 * (i % 5), 1))        # 5 lines read round and round
    seq.insert(350, (35000, 'W', 0x1000 + 8 * 2, 1))                 # evicts line 2 once
    write_trace(texpat, sorted(seq, key=lambda x: x[0]))
    noread = os.path.join(tmp, 'noread.txt')
    write_trace(noread, [(i * 100, 'W', 0x1000 + 8 * (i % 64), 1) for i in range(700)])

    jobs = {}
    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as ex:
        def go(key, mhz, opts, traces):
            jobs[key] = ex.submit(model, mhz, opts, traces)
        for i, (mhz, opts, _) in enumerate(PINS):
            go(('pin', i), mhz, opts, full)
        go('fast', 135.4752, [], [full[0]])
        go('engine', 135.4752, ['--force-engine'], [full[0]])
        for name, opts in (('base', []), ('c1', ['--spu-cache', '1x']), ('c4', ['--spu-cache', '4x']),
                           ('cm', ['--spu-cache', 'mixed']), ('c4la', ['--spu-cache', '4x', '--lookahead']),
                           ('la', ['--lookahead']), ('c4q', ['--spu-cache', '4x', '--qos']),
                           ('c4d', ['--spu-cache', '4x', '--deadlines']), ('q', ['--qos']),
                           ('c4cl', ['--spu-cache', '4x', '--closed-loop']),
                           ('tex', ['--tex-lines', '1000000']), ('tex256', ['--tex-lines', '256'])):
            go(name, 135.4752, opts, [head])
        go('spuq', 135.4752, ['--spu-cache', '4x', '--qos', '--window-us', '10'], [spu_only])
        go('texpat', 135.4752, ['--spu-voices', '0', '--tex-lines', '1000000', '--window-us', '100'], [texpat])
        go('noread', 135.4752, ['--spu-voices', '0', '--closed-loop', '--window-us', '100'], [noread])
        res = {k: v.result() for k, v in jobs.items()}

    # 1. pins: every option off
    for i, (mhz, opts, want) in enumerate(PINS):
        got = {os.path.basename(r[0]): r[4] for r in rows(res[('pin', i)])}
        want = {f'trace_s{n}.txt': w for n, w in zip((1, 2, 3), want) if os.path.exists(os.path.join(run, f'trace_s{n}.txt'))}
        check(got == want, f"pin {mhz:g} MHz {' '.join(opts)}: peak by trace {got} == {want}")
    fast, eng = res['fast'], res['engine']
    strip = lambda t: [l for l in t.splitlines() if not l.startswith('BW options')]
    check(rows(fast) != [] and strip(fast) == strip(eng), 'event engine with every option off prints the same as the plain replay (s1)')

    # 2. --spu-cache
    pk = lambda k: rows(res[k])[0][4]
    base, c1, c4, cm = pk('base'), pk('c1'), pk('c4'), pk('cm')
    check(c1 < c4 < base, f"--spu-cache: 1x {c1} < 4x {c4} < uncached {base} (head of s1)")
    check(c1 <= cm <= c4, f"--spu-cache mixed {cm} between 1x and 4x")
    r1, r4 = field(res['c1'], r'= ([\d.]+) M reads/s'), field(res['c4'], r'= ([\d.]+) M reads/s')
    check(r1 == 0.08 and r4 == 0.30, f"--spu-cache reads/s: 1x {r1} M, 4x {r4} M (24 voices x 2 bursts / 28 samples x pitch)")

    # 3. --tex-lines
    exp_hits = 0
    seen = set()
    with open(texpat) as f:
        for line in f:
            _, rw, a, b, _be = line.split()
            key = int(a, 16) >> 3
            if rw == 'W':
                seen.discard(key)
            elif key in seen:
                exp_hits += 1
            else:
                seen.add(key)
    got_hits = field(res['texpat'], r'(\d+) single-beat reads dropped', int)
    check(got_hits == exp_hits, f"--tex-lines huge: {got_hits} repeats dropped on a 5-line pattern with one eviction, expect {exp_hits}")
    exp_head = 0
    seen = set()
    with open(head) as f:
        for line in f:
            _, rw, a, b, _be = line.split()
            base_key = int(a, 16) >> 3
            if rw == 'W':
                for i in range(int(b)):
                    seen.discard(base_key + i)
            elif int(b) == 1:
                if base_key in seen:
                    exp_head += 1
                else:
                    seen.add(base_key)
    got_head = field(res['tex'], r'(\d+) single-beat reads dropped', int)
    check(got_head == exp_head, f"--tex-lines huge on s1 head: {got_head} dropped, independent count {exp_head}")
    t256 = field(res['tex256'], r'(\d+) single-beat reads dropped', int)
    check(0 < t256 < got_head, f"--tex-lines 256 drops {t256} < huge {got_head}")

    # 4. --lookahead never adds time or peak
    for a, b, what in (('base', 'la', 'default SPU'), ('c4', 'c4la', '4x cached SPU')):
        ra, rb = rows(res[a])[0], rows(res[b])[0]
        check(rb[4] <= ra[4] and rb[2] <= ra[2], f"--lookahead {what}: peak {ra[4]} -> {rb[4]}, time {ra[2]} -> {rb[2]} ms")

    # 5. --qos
    ov = lambda k: (field(res[k], r'overruns (\d+) of', int), field(res[k], r'late scan-out lines (\d+) of', int))
    o_fifo, o_qos = ov('c4d'), ov('c4q')
    check(o_qos[0] == 0 and o_qos[1] == 0, f"--qos 4x cached SPU: overruns/late lines {o_qos}")
    check(o_fifo[0] > 0, f"no QoS: {o_fifo[0]} SPU overruns (a 63-beat read outlasts a slot)")
    o_none = ov('spuq')
    reads = field(res['spuq'], r'overruns \d+ of (\d+)', int)
    check(o_none == (0, 0) and reads > 0, f"--qos with no GPU traffic: overruns/late {o_none} over {reads} SPU reads")
    check(ov('q')[0] == 0, f"--qos default SPU: {ov('q')[0]} overruns")

    # 6. --closed-loop
    infl = field(res['c4cl'], r'inflation ([+-][\d.]+)%')
    check(infl is not None and infl >= 0, f"--closed-loop: inflation {infl:+.1f}% >= 0 on s1 head")
    zero = field(res['noread'], r'inflation ([+-][\d.]+)%')
    check(zero is not None and abs(zero) < 1.0, f"--closed-loop with no reads: inflation {zero:+.1f}% (write drain only)")

    print(f"bwselftest: {checks - len(fails)}/{checks} checks passed")
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
