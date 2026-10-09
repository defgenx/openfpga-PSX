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

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "common"))
import diffsum  # noqa: E402

STREAM = re.compile(r"^STREAM .*?writes_gold=(\d+)")
TIMING = re.compile(r"^TIMING (\S+) n=(\d+) gold=(\d+) dut=(\d+) maxdelta=(\d+) diffs=(\d+)")
SETUP = re.compile(r"^SETUP (\S+) gold_n=(\d+) gold_sum=(\d+) gold_max=(\d+) dut_n=(\d+) dut_sum=(\d+) dut_max=(\d+)")
COV = re.compile(r"^COV (\S+) (\S+) (\d+)$")
SETUPCHK = re.compile(r"^SETUPCHK checked=(\d+) violations=(\d+) worst_excess=(\d+) dut_max=(\d+)")
REQ_CLASS = ["poly_wrote", "poly_nowrite", "line_wrote", "rect_wrote", "fill_wrote", "copy_wrote", "upload_wrote"]
REQ_TAGS = ["tag_tri", "tag_quad", "tag_flat", "tag_gouraud", "tag_textured", "tag_raw", "tag_modulated", "tag_semi",
            "tag_tex4", "tag_tex8", "tag_tex15", "tag_dither", "tag_cull_expect", "tag_line", "tag_polyline",
            "tag_rect", "tag_fill", "tag_copy", "tag_upload", "tag_download"]


def main():
    cli = diffsum.parse_cli(__doc__)
    tot = collections.Counter()
    per_suite = collections.Counter()
    timing = collections.defaultdict(lambda: [0, 0, 0, 0, 0])
    setup = collections.defaultdict(lambda: [0] * 6)
    setup_max = collections.defaultdict(lambda: [0, 0])
    sc = [0, 0, 0]                                   # setup criterion: checked, violations, worst excess
    cov = collections.Counter()
    fail = False
    for d in cli.dirs:
        run = diffsum.Run(d)
        for ln in run.lines or []:
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
            m = SETUPCHK.match(ln)
            if m:
                sc[0] += int(m.group(1)); sc[1] += int(m.group(2)); sc[2] = max(sc[2], int(m.group(3)))
            m = COV.match(ln)
            if m:
                cov[m.group(2)] += int(m.group(3))
        if diffsum.report_run(run, cli.quiet):
            fail = True
        if run.result:
            vals = run.fields()
            for k, v in vals.items():
                if k == "timing_maxdelta":
                    tot[k] = max(tot[k], v)
                else:
                    tot[k] += v
            per_suite[diffsum.suite_of(run.name)] += vals["commands"]
    checks = []
    if not cli.dirs:
        checks.append("no runs")
    elif tot["commands"] == 0:
        checks.append("no commands ran")
    elif tot["writes"] == 0:
        checks.append("no VRAM writes on the golden side")
    diffsum.check_mins(per_suite, cli.mins, checks)
    if cli.need_cov:
        if not cov:
            checks.append("coverage required but no COV lines")
        else:
            req = [k for k in cov if k.startswith("op_")] + REQ_CLASS + REQ_TAGS
            zeros = sorted(k for k in set(req) if cov[k] == 0)
            if zeros:
                checks.append("coverage counters zero over all suites: " + ", ".join(zeros))
    fail = diffsum.finish(checks, fail)
    print("TOTAL commands=%d prims=%d wr_mismatches=%d span_mismatches=%d vram_mismatches=%d rd_mismatches=%d stim_errors=%d "
          "timing_diffs=%d stat_diffs=%d timing_maxdelta=%d writes=%d cycles=%d %s" % (
              tot["commands"], tot["prims"], tot["wr_mismatches"], tot["span_mismatches"], tot["vram_mismatches"],
              tot["rd_mismatches"], tot["stim_errors"], tot["timing_diffs"], tot["stat_diffs"], tot["timing_maxdelta"],
              tot["writes"], tot["cycles"], "FAIL" if fail else "PASS"))
    if not cli.quiet and timing:
        print("TIMING per class (clk2x from last command word to GPUSTAT idle; golden vs DUT totals)")
        for c, (n, g, du, mx, df) in timing.items():
            if n:
                print("  %-9s n=%-6d gold=%-10d dut=%-10d maxdelta=%-4d prims_with_delta=%d" % (c, n, g, du, mx, df))
    if not cli.quiet and setup:
        print("POLY SETUP (clk2x from ISSUE to first drawn span; per triangle)")
        for c, s in setup.items():
            print("  %-17s gold n=%-6d avg=%-7.1f max=%-5d | dut n=%-6d avg=%-7.1f max=%d" % (
                c, s[0], s[1] / s[0] if s[0] else 0.0, setup_max[c][0], s[3], s[4] / s[3] if s[3] else 0.0, setup_max[c][1]))
    if not cli.quiet and sc[0]:
        print("SETUP CRITERION (per triangle: DUT <= max(golden, reference), docs/pocket/GPU.md) checked=%d "
              "violations=%d worst_excess=%d" % tuple(sc))
    if not cli.quiet and cov:
        zeros = sorted(k for k, v in cov.items() if v == 0 and (k.startswith("op_") or k in REQ_CLASS))
        print("COVERAGE zero counters: %s" % (", ".join(zeros) if zeros else "none"))
        print("  commands: " + " ".join("%s=%d" % (k[4:], cov[k]) for k in sorted(cov) if k.startswith("tag_")))
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()
