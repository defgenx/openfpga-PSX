#!/usr/bin/env python3
"""Aggregate tb_diff run logs: per-run RESULT lines, summed coverage, exit 1 on any FAIL.

A run also fails on any simulator "** Error" or "** Failure" line (RTL assertions included).
The total fails when there are no runs or no commands, or when the golden-side multiply or
divide checks never sampled (checked_mul or checked_div summed to zero).
With --require-coverage, coverage lines must be present and every counter summed over all
suites must be non-zero (a single suite may legitimately leave some at zero, e.g. game-like
never clamps).
--min SUITE=N fails unless the runs named SUITE_s<seed> together ran at least N commands.

usage: summarize.py [--quiet] [--require-coverage] [--min SUITE=N]... RUNDIR...
       (each RUNDIR holds run.log and status)
"""
import collections
import os
import re
import sys

RES = re.compile(r"^RESULT mismatches=(\d+) busy_diffs=(\d+) assert_fails=(\d+) commands=(\d+) (PASS|FAIL)")
ASR = re.compile(r"^ASSERTS mul=(\d+) divshift=(\d+) divrange=(\d+) checked_mul=(\d+) checked_div=(\d+)")
PAU = re.compile(r"^PAUSES fired=(\d+) while_busy=(\d+)")
COV = re.compile(r"^COV (\S+) (\S+) (\d+)$")
DETAIL = ("MISMATCH", "BUSY DIFF", "ASSERT ", "TIMEOUT", "ERROR", "INDEX")
SIMERR = re.compile(r"^\*\* (Error|Failure)")


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
            # an unknown option must not silently turn a check off
            usage("unknown option " + a)
        else:
            args.append(a)
    tot = collections.Counter()
    per_suite = collections.Counter()
    cov = collections.defaultdict(collections.Counter)
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
        extra = []
        simerr = []
        for ln in lines:
            if SIMERR.match(ln):
                simerr.append(ln)
            m = RES.match(ln)
            if m:
                res = m
            m = ASR.match(ln)
            if m:
                tot["chk_mul"] += int(m.group(4))
                tot["chk_div"] += int(m.group(5))
            m = PAU.match(ln)
            if m:
                tot["pauses"] += int(m.group(1))
                tot["pauses_busy"] += int(m.group(2))
            m = COV.match(ln)
            if m:
                cov[m.group(1)][m.group(2)] += int(m.group(3))
            if ln.startswith(DETAIL):
                extra.append(ln)
        if not res:
            print("%-22s NO RESULT (crash or elaboration error)" % name)
            for ln in lines[-8:]:
                print("    " + ln)
            fail = True
            continue
        mm, bd, af, cmds = (int(res.group(i)) for i in range(1, 5))
        tot["mismatches"] += mm
        tot["busy_diffs"] += bd
        tot["assert_fails"] += af
        tot["commands"] += cmds
        per_suite[re.sub(r"_s\d+$", "", name)] += cmds
        bad = res.group(5) != "PASS" or bool(simerr)
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
    else:
        if tot["chk_mul"] == 0:
            checks.append("golden multiply checks never sampled")
        if tot["chk_div"] == 0:
            checks.append("golden divide checks never sampled")
    for suite, n in sorted(mins.items()):
        if per_suite[suite] < n:
            checks.append("suite %s ran %d commands, minimum %d" % (suite, per_suite[suite], n))
    if need_cov and not cov:
        checks.append("coverage required but no COV lines")
    elif need_cov:
        summed = collections.Counter()
        for c in cov.values():
            summed.update(c)
        zeros = sorted(k for k, v in summed.items() if v == 0)
        if zeros:
            checks.append("coverage counters zero over all suites: " + ", ".join(zeros))
    for c in checks:
        print("CHECK FAIL: " + c)
    if checks:
        fail = True
    print("TOTAL mismatches=%d busy_diffs=%d assert_fails=%d commands=%d (mul checks=%d, div checks=%d, pauses=%d, while busy=%d) %s" % (
        tot["mismatches"], tot["busy_diffs"], tot["assert_fails"], tot["commands"], tot["chk_mul"], tot["chk_div"],
        tot["pauses"], tot["pauses_busy"], "FAIL" if fail else "PASS"))
    if cov and not quiet:
        print("COVERAGE (summed over runs; zero counters listed)")
        for suite in sorted(cov):
            c = cov[suite]
            zeros = sorted(k for k, v in c.items() if v == 0)
            print("  %-9s commands=%d zero=%s" % (suite, sum(v for k, v in c.items() if k.startswith("op_")),
                                                   ", ".join(zeros) if zeros else "none"))
        total = collections.Counter()
        for suite in cov:
            for k, v in cov[suite].items():
                total[k] += v
        zeros = sorted(k for k, v in total.items() if v == 0)
        print("  all suites zero=%s%s" % (", ".join(zeros) if zeros else "none",
                                          " (required: FAIL)" if need_cov and zeros else ""))
        if os.environ.get("COV_FULL"):
            for suite in sorted(cov):
                for k, v in cov[suite].items():
                    print("    %s %s %d" % (suite, k, v))
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()
