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

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "common"))
import diffsum  # noqa: E402

ASR = re.compile(r"^ASSERTS mul=(\d+) divshift=(\d+) divrange=(\d+) checked_mul=(\d+) checked_div=(\d+)")
PAU = re.compile(r"^PAUSES fired=(\d+) while_busy=(\d+)")
COV = re.compile(r"^COV (\S+) (\S+) (\d+)$")


def main():
    cli = diffsum.parse_cli(__doc__)
    tot = collections.Counter()
    per_suite = collections.Counter()
    cov = collections.defaultdict(collections.Counter)
    fail = False
    for d in cli.dirs:
        run = diffsum.Run(d)
        for ln in run.lines or []:
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
        if diffsum.report_run(run, cli.quiet):
            fail = True
        if run.result:
            f = run.fields()
            for k in ("mismatches", "busy_diffs", "assert_fails", "commands"):
                tot[k] += f[k]
            per_suite[diffsum.suite_of(run.name)] += f["commands"]
    checks = []
    if not cli.dirs:
        checks.append("no runs")
    elif tot["commands"] == 0:
        checks.append("no commands ran")
    else:
        if tot["chk_mul"] == 0:
            checks.append("golden multiply checks never sampled")
        if tot["chk_div"] == 0:
            checks.append("golden divide checks never sampled")
    diffsum.check_mins(per_suite, cli.mins, checks)
    if cli.need_cov and not cov:
        checks.append("coverage required but no COV lines")
    elif cli.need_cov:
        summed = collections.Counter()
        for c in cov.values():
            summed.update(c)
        zeros = sorted(k for k, v in summed.items() if v == 0)
        if zeros:
            checks.append("coverage counters zero over all suites: " + ", ".join(zeros))
    fail = diffsum.finish(checks, fail)
    print("TOTAL mismatches=%d busy_diffs=%d assert_fails=%d commands=%d (mul checks=%d, div checks=%d, pauses=%d, while busy=%d) %s" % (
        tot["mismatches"], tot["busy_diffs"], tot["assert_fails"], tot["commands"], tot["chk_mul"], tot["chk_div"],
        tot["pauses"], tot["pauses_busy"], "FAIL" if fail else "PASS"))
    if cov and not cli.quiet:
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
                                          " (required: FAIL)" if cli.need_cov and zeros else ""))
        if os.environ.get("COV_FULL"):
            for suite in sorted(cov):
                for k, v in cov[suite].items():
                    print("    %s %s %d" % (suite, k, v))
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()
