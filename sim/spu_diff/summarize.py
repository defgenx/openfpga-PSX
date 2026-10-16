#!/usr/bin/env python3
"""Aggregate spu_diff run logs: per-run RESULT lines, summed coverage, exit 1 on any FAIL.

A run fails on a RESULT line ending in FAIL, a simulator "** Error"/"** Failure"/"** Fatal" line, or no RESULT.
The total fails when there are no runs or no compares. --min SUITE=N fails unless the runs named SUITE_s<seed> together
ran at least N samples. With --require-coverage every golden-internals counter (COV, named by --names FILE) and every
stimulus counter (TCOV) outside OPTIONAL must be non-zero summed over all runs, and the golden must have produced
non-zero sound output. --bw prints the SDRAM request counts per 1 ms window of the given runs (BW lines).

usage: summarize.py [--quiet] [--require-coverage] [--names FILE] [--min SUITE=N]... RUNDIR...
       summarize.py --bw RUNDIR...
       (each RUNDIR holds run.log)
"""
import collections
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "common"))
import diffsum  # noqa: E402

# counters that need not be reached by every configuration (reverb engine states run only with reverb on)
OPTIONAL = {"rev_read1", "rev_write1", "rev_write2", "sat_out", "irq_direct_off"}
TOPTIONAL = {"reset_pulse", "ce_low", "hot_overlap", "none21"}


def bw(dirs):
    for d in dirs:
        run = diffsum.Run(d)
        rows = [ln.split() for ln in run.lines or [] if ln.startswith("BW ")]
        sums = [ln for ln in run.lines or [] if ln.startswith("BWSUM")]
        print("%s: %s" % (run.name, sums[-1] if sums else "no BWSUM"))
        if rows:
            print("  window gold dut: " + " ".join("%s:%s/%s" % (r[1], r[2], r[3]) for r in rows[:12]) + (" ..." if len(rows) > 12 else ""))


def main():
    argv = sys.argv[1:]
    if argv and argv[0] == "--bw":
        bw(argv[1:])
        return
    names_file = None
    if "--names" in argv:
        i = argv.index("--names")
        names_file = argv[i + 1]
        del argv[i:i + 2]
    cli = diffsum.parse_cli(__doc__, argv)
    names = open(names_file).read().split() if names_file and os.path.exists(names_file) else []
    tot = collections.Counter()
    cov = collections.Counter()
    tcov = collections.Counter()
    tnames = []
    per_suite = collections.Counter()
    fail = False
    for d in cli.dirs:
        run = diffsum.Run(d)
        for ln in run.lines or []:
            if ln.startswith("COV "):
                for i, v in enumerate(ln.split()[1:]):
                    cov[i] += int(v)
            elif ln.startswith("TCOVNAMES "):
                tnames = ln.split()[1:]
            elif ln.startswith("TCOV "):
                for i, v in enumerate(ln.split()[1:]):
                    tcov[i] += int(v)
        if diffsum.report_run(run, cli.quiet):
            fail = True
        if run.result:
            f = run.fields()
            tot.update(f)
            if not run.name.startswith(("rev_", "l1_")):
                per_suite[diffsum.suite_of(run.name)] += f.get("samples", 0)
    checks = []
    if not cli.dirs:
        checks.append("no runs")
    elif tot["compares"] == 0:
        checks.append("no compares ran")
    diffsum.check_mins(per_suite, cli.mins, checks, "samples")
    if cli.need_cov:
        if not names:
            checks.append("coverage required but no --names file")
        zeros = [n for i, n in enumerate(names) if cov[i] == 0 and n not in OPTIONAL]
        if zeros:
            checks.append("golden coverage counters zero over all runs: " + ", ".join(zeros))
        tz = [n for i, n in enumerate(tnames) if tcov[i] == 0 and n not in TOPTIONAL]
        if tz:
            checks.append("stimulus counters zero over all runs: " + ", ".join(tz))
        if tot["nonzero"] == 0:
            checks.append("the golden never produced non-zero sound output")
    fail = diffsum.finish(checks, fail)
    print("TOTAL " + " ".join("%s=%d" % kv for kv in sorted(tot.items())) + " " + ("FAIL" if fail else "PASS"))
    if not cli.quiet and names:
        print("COVERAGE golden internals (clocks, summed over runs)")
        print("  " + " ".join("%s=%d" % (n, cov[i]) for i, n in enumerate(names)))
        print("COVERAGE stimulus")
        print("  " + " ".join("%s=%d" % (n, tcov[i]) for i, n in enumerate(tnames)))
        print("  zero: " + (", ".join(n for i, n in enumerate(names) if cov[i] == 0) or "none") + " | " +
              (", ".join(n for i, n in enumerate(tnames) if tcov[i] == 0) or "none"))
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()
