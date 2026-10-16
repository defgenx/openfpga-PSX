#!/usr/bin/env python3
"""Aggregate cd_diff run logs: per-run RESULT lines, summed coverage, exit 1 on any FAIL.

A run fails on a RESULT line ending in FAIL, a simulator "** Error"/"** Failure"/"** Fatal" line, or no RESULT.
The total fails when there are no runs or no compares. --min SUITE=N fails unless the runs named SUITE_s<seed> together ran
at least N commands (the commands the golden took from the bus). With --require-coverage every coverage counter summed over
all runs must be non-zero, and every command code 0x00..0x1F must have been issued.

usage: summarize.py [--quiet] [--require-coverage] [--min SUITE=N]... RUNDIR...
       (each RUNDIR holds run.log)
"""
import collections
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "common"))
import diffsum  # noqa: E402

# counters that a correct design must reach; the others are informational
OPTIONAL = {"error", "xa_eof"}


def main():
    cli = diffsum.parse_cli(__doc__)
    tot = collections.Counter()
    per_suite = collections.Counter()
    cov = collections.Counter()
    cmds = collections.Counter()
    names = []
    fail = False
    for d in cli.dirs:
        run = diffsum.Run(d)
        for ln in run.lines or []:
            if ln.startswith("COVNAMES "):
                names = ln.split()[1:]
            elif ln.startswith("COV "):
                for n, v in zip(names, ln.split()[1:]):
                    cov[n] += int(v)
            elif ln.startswith("CMDS "):
                for i, v in enumerate(ln.split()[1:]):
                    cmds[i] += int(v)
        if diffsum.report_run(run, cli.quiet):
            fail = True
        if run.result:
            f = run.fields()
            if "clocks" not in f:
                f["clocks"] = f.get("compares", 0) // 15
            smoke = run.name.startswith(("noxa_", "fixed_"))   # amputation smoke runs: differences are expected and not counted
            for k in ("cycles", "clocks", "mismatches", "cmds", "gold_meta", "idle_viol"):
                tot["smoke_" + k if smoke else k] += f.get(k, 0)
            if not smoke:
                per_suite[diffsum.suite_of(run.name)] += f.get("cmds", 0)
    checks = []
    if not cli.dirs:
        checks.append("no runs")
    elif tot["clocks"] == 0:
        checks.append("no compares ran")
    diffsum.check_mins(per_suite, cli.mins, checks)
    if cli.need_cov:
        zeros = sorted(n for n in names if cov[n] == 0 and n not in OPTIONAL)
        if not names:
            checks.append("coverage required but no COV lines")
        elif zeros:
            checks.append("coverage counters zero over all runs: " + ", ".join(zeros))
        missing = [c for c in range(0x20) if cmds[c] == 0]
        if missing:
            checks.append("commands never issued: " + " ".join("%02X" % c for c in missing))
    fail = diffsum.finish(checks, fail)
    print("TOTAL cycles=%d compares=%d mismatches=%d commands=%d gold_meta=%d idle_viol=%d %s" % (
        tot["cycles"], tot["clocks"] * 15, tot["mismatches"], tot["cmds"], tot["gold_meta"], tot["idle_viol"],
        "FAIL" if fail else "PASS"))
    if tot["smoke_cmds"]:
        print("SMOKE (NO_XA, FIXED_CD_TIMING; not compared) cycles=%d commands=%d gold_meta=%d" % (tot["smoke_cycles"], tot["smoke_cmds"], tot["smoke_gold_meta"]))
    if names and not cli.quiet:
        print("COVERAGE (summed over runs)")
        print("  " + " ".join("%s=%d" % (n, cov[n]) for n in names))
        print("  commands: " + " ".join("%02X=%d" % (c, cmds[c]) for c in range(0x20)) + " other=%d" % sum(v for c, v in cmds.items() if c >= 0x20))
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()
