#!/usr/bin/env python3
"""Aggregate run logs of harnesses that use trace_cmp_pkg: per-run RESULT lines, summed counters, exit 1 on any FAIL.

A run fails on a RESULT line ending in FAIL, a simulator "** Error"/"** Failure"/"** Fatal" line, or no RESULT.
The total fails when there are no runs or no compares. Up to N "MISMATCH name cycle=.. gold=.. dut=.. mask=.."
lines per run are printed for a failing run. --min SUITE=N fails unless the runs named SUITE_s<seed> together
ran at least N compares.

usage: summarize.py [--quiet] [--min SUITE=N]... RUNDIR...
       (each RUNDIR holds run.log)
"""
import collections
import sys

import diffsum


def main():
    cli = diffsum.parse_cli(__doc__)
    if cli.need_cov:
        diffsum.usage(__doc__, "unknown option --require-coverage")
    tot = collections.Counter()
    per_suite = collections.Counter()
    fail = False
    for d in cli.dirs:
        run = diffsum.Run(d)
        if diffsum.report_run(run, cli.quiet):
            fail = True
        if run.result:
            f = run.fields()
            tot.update(f)
            per_suite[diffsum.suite_of(run.name)] += f.get("compares", 0)
    checks = []
    if not cli.dirs:
        checks.append("no runs")
    elif tot["compares"] == 0:
        checks.append("no compares ran")
    diffsum.check_mins(per_suite, cli.mins, checks, "compares")
    fail = diffsum.finish(checks, fail)
    print("TOTAL " + " ".join("%s=%d" % kv for kv in sorted(tot.items())) + " " + ("FAIL" if fail else "PASS"))
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()
