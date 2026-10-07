#!/usr/bin/env python3
"""Aggregate tb_diff run logs: per-run RESULT lines, summed timing/setup/coverage, exit 1 on any FAIL.

A run also fails on any simulator "** Error" or "** Failure" line (assertions included).
The total fails when there are no runs, no commands, or no VRAM writes on the golden side.
With --require-coverage, every required opcode counter, class counter and tag must be non-zero summed over all runs.
--min SUITE=N fails unless the runs named SUITE_s<seed> together ran at least N commands.

usage: summarize.py [--quiet] [--require-coverage] [--min SUITE=N]... RUNDIR...
       (each RUNDIR holds run.log and status)
"""
import collections
import os
import re
import sys

RES = re.compile(r"^RESULT commands=(\d+) prims=(\d+) words=(\d+) wr_mismatches=(\d+) span_mismatches=(\d+) "
                 r"vram_mismatches=(\d+) rd_mismatches=(\d+) stim_errors=(\d+) timing_diffs=(\d+) stat_diffs=(\d+) "
                 r"timing_maxdelta=(\d+) cycles=(\d+) (PASS|FAIL)")
FIELDS = ["commands", "prims", "words", "wr_mismatches", "span_mismatches", "vram_mismatches", "rd_mismatches",
          "stim_errors", "timing_diffs", "stat_diffs", "timing_maxdelta", "cycles"]
STREAM = re.compile(r"^STREAM .*?writes_gold=(\d+)")
TIMING = re.compile(r"^TIMING (\S+) n=(\d+) gold=(\d+) dut=(\d+) maxdelta=(\d+) diffs=(\d+)")
SETUP = re.compile(r"^SETUP (\S+) gold_n=(\d+) gold_sum=(\d+) gold_max=(\d+) dut_n=(\d+) dut_sum=(\d+) dut_max=(\d+)")
COV = re.compile(r"^COV (\S+) (\S+) (\d+)$")
DETAIL = ("MISMATCH", "TIMING DIFF", "TIMEOUT", "ERROR")
SIMERR = re.compile(r"^\*\* (Error|Failure|Fatal)")
REQ_CLASS = ["poly_wrote", "poly_nowrite", "line_wrote", "rect_wrote", "fill_wrote", "copy_wrote", "upload_wrote"]
REQ_TAGS = ["tag_tri", "tag_quad", "tag_flat", "tag_gouraud", "tag_textured", "tag_raw", "tag_modulated", "tag_semi",
            "tag_tex4", "tag_tex8", "tag_tex15", "tag_dither", "tag_cull_expect", "tag_line", "tag_polyline",
            "tag_rect", "tag_fill", "tag_copy", "tag_upload", "tag_download"]


def usage(msg):
    sys.stderr.write("summarize.py: %s\nusage: %s" % (msg, __doc__.split("usage: ")[1]))
    sys.exit(2)


def main():
    argv = sys.argv[1:]
    mins = {}
    args = []
    quiet = need_cov = False
    while argv:
        a = argv.pop(0)
        if a == "--min":
            m = re.fullmatch(r"(\w+)=(\d+)", argv.pop(0) if argv else "")
            if not m:
                usage("--min takes SUITE=N")
            mins[m.group(1)] = int(m.group(2))
        elif a == "--quiet":
            quiet = True
        elif a == "--require-coverage":
            need_cov = True
        elif a.startswith("-"):
            usage("unknown option " + a)  # an unknown option must not silently turn a check off
        else:
            args.append(a)
    tot = collections.Counter()
    per_suite = collections.Counter()
    timing = collections.defaultdict(lambda: [0, 0, 0, 0, 0])
    setup = collections.defaultdict(lambda: [0] * 6)
    setup_max = collections.defaultdict(lambda: [0, 0])
    cov = collections.Counter()
    fail = False
    for d in args:
        name = os.path.basename(d.rstrip("/"))
        try:
            lines = open(os.path.join(d, "run.log"), errors="replace").read().splitlines()
        except OSError:
            print("%-22s NO LOG" % name)
            fail = True
            continue
        res = None
        extra, simerr = [], []
        for ln in lines:
            if SIMERR.match(ln):
                simerr.append(ln)
            m = RES.match(ln)
            if m:
                res = m
            m = STREAM.match(ln)
            if m:
                tot["writes"] += int(m.group(1))
            m = TIMING.match(ln)
            if m:
                t = timing[m.group(1)]
                n, g, du, mx, df = (int(m.group(i)) for i in range(2, 7))
                t[0] += n; t[1] += g; t[2] += du; t[3] = max(t[3], mx); t[4] += df
            m = SETUP.match(ln)
            if m:
                v = [int(m.group(i)) for i in range(2, 8)]
                s = setup[m.group(1)]
                for i in (0, 1, 3, 4):
                    s[i] += v[i]
                setup_max[m.group(1)][0] = max(setup_max[m.group(1)][0], v[2])
                setup_max[m.group(1)][1] = max(setup_max[m.group(1)][1], v[5])
            m = COV.match(ln)
            if m:
                cov[m.group(2)] += int(m.group(3))
            if ln.startswith(DETAIL):
                extra.append(ln)
        if not res:
            print("%-22s NO RESULT (crash or elaboration error)" % name)
            for ln in lines[-8:]:
                print("    " + ln)
            fail = True
            continue
        vals = dict(zip(FIELDS, (int(res.group(i)) for i in range(1, 13))))
        for k, v in vals.items():
            if k == "timing_maxdelta":
                tot[k] = max(tot[k], v)
            else:
                tot[k] += v
        per_suite[re.sub(r"_s\d+$", "", name)] += vals["commands"]
        bad = res.group(13) != "PASS" or bool(simerr)
        fail |= bad
        print("%-22s %s%s" % (name, res.group(0)[7:], " (simulator errors: %d)" % len(simerr) if simerr else ""))
        extra = simerr[:5] + extra
        if bad and not quiet:
            for ln in extra[:20]:
                print("    " + ln)
    checks = []
    if not args:
        checks.append("no runs")
    elif tot["commands"] == 0:
        checks.append("no commands ran")
    elif tot["writes"] == 0:
        checks.append("no VRAM writes on the golden side")
    for suite, n in sorted(mins.items()):
        if per_suite[suite] < n:
            checks.append("suite %s ran %d commands, minimum %d" % (suite, per_suite[suite], n))
    if need_cov:
        if not cov:
            checks.append("coverage required but no COV lines")
        else:
            req = [k for k in cov if k.startswith("op_")] + REQ_CLASS + REQ_TAGS
            zeros = sorted(k for k in set(req) if cov[k] == 0)
            if zeros:
                checks.append("coverage counters zero over all suites: " + ", ".join(zeros))
    for c in checks:
        print("CHECK FAIL: " + c)
    fail |= bool(checks)
    print("TOTAL commands=%d prims=%d wr_mismatches=%d span_mismatches=%d vram_mismatches=%d rd_mismatches=%d stim_errors=%d "
          "timing_diffs=%d stat_diffs=%d timing_maxdelta=%d writes=%d cycles=%d %s" % (
              tot["commands"], tot["prims"], tot["wr_mismatches"], tot["span_mismatches"], tot["vram_mismatches"],
              tot["rd_mismatches"], tot["stim_errors"], tot["timing_diffs"], tot["stat_diffs"], tot["timing_maxdelta"],
              tot["writes"], tot["cycles"], "FAIL" if fail else "PASS"))
    if not quiet and timing:
        print("TIMING per class (clk2x from last command word to GPUSTAT idle; golden vs DUT totals)")
        for c, (n, g, du, mx, df) in timing.items():
            if n:
                print("  %-9s n=%-6d gold=%-10d dut=%-10d maxdelta=%-4d prims_with_delta=%d" % (c, n, g, du, mx, df))
    if not quiet and setup:
        print("POLY SETUP (clk2x from ISSUE to first drawn span; per triangle)")
        for c, s in setup.items():
            print("  %-17s gold n=%-6d avg=%-7.1f max=%-5d | dut n=%-6d avg=%-7.1f max=%d" % (
                c, s[0], s[1] / s[0] if s[0] else 0.0, setup_max[c][0], s[3], s[4] / s[3] if s[3] else 0.0, setup_max[c][1]))
    if not quiet and cov:
        zeros = sorted(k for k, v in cov.items() if v == 0 and (k.startswith("op_") or k in REQ_CLASS))
        print("COVERAGE zero counters: %s" % (", ".join(zeros) if zeros else "none"))
        print("  commands: " + " ".join("%s=%d" % (k[4:], cov[k]) for k in sorted(cov) if k.startswith("tag_")))
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()
