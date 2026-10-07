#!/usr/bin/env python3
"""Aggregate tb_diff run logs: per-run RESULT lines, summed coverage, exit 1 on any FAIL.

usage: summarize.py [--quiet] RUNDIR...   (each RUNDIR holds run.log and status)
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


def main():
    args = [a for a in sys.argv[1:] if a != "--quiet"]
    quiet = "--quiet" in sys.argv
    tot = collections.Counter()
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
        for ln in lines:
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
        bad = res.group(5) != "PASS"
        fail |= bad
        print("%-22s %s" % (name, res.group(0)[7:]))
        if bad and not quiet:
            for ln in extra[:20]:
                print("    " + ln)
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
        if os.environ.get("COV_FULL"):
            for suite in sorted(cov):
                for k, v in cov[suite].items():
                    print("    %s %s %d" % (suite, k, v))
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()
