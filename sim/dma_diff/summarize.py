#!/usr/bin/env python3
"""Aggregate tb_dma run logs: per-run RESULT lines, summed coverage, exit 1 on any FAIL.

A run fails on a RESULT line ending in FAIL, a simulator "** Error"/"** Failure"/"** Fatal" line, an IDLE
timeout, or no RESULT. The total fails when there are no runs or no compares. With --require-coverage every COV
counter below must be non-zero summed over all runs. --min SUITE=N fails unless the runs named SUITE_s<seed>
together made at least N compares.

usage: summarize.py [--quiet] [--require-coverage] [--min SUITE=N]... RUNDIR...
       (each RUNDIR holds run.log and status)
"""
import collections
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "common"))
import diffsum  # noqa: E402

COV = re.compile(r"^COV (\S+)\s+(\d+)$")
# counters that must be reached over the whole gate; err_cpu and err_fifo only occur under illegal stimulus
REQUIRED = (["xfer_c%d_%s" % (c, d) for c in range(7) for d in ("from", "to")
             if (c, d) not in ((0, "from"), (1, "to"), (5, "from"), (5, "to"))]
            + ["ram_rd", "ram_wr", "gpu_w", "mdec_w", "spu_w", "gpu_r", "mdec_r", "cd_r", "spu_r", "irq", "err_chop",
               "bus_w", "bus_r", "reset", "pause", "stall", "cnt0", "cnt1", "cnt2", "cnt3", "buscoin", "gpuwait", "fiford"])


def main():
    cli = diffsum.parse_cli(__doc__)
    tot = collections.Counter()
    cov = collections.Counter()
    per_suite = collections.Counter()
    fail = False
    for d in cli.dirs:
        run = diffsum.Run(d)
        for ln in run.lines or []:
            m = COV.match(ln)
            if m:
                cov[m.group(1)] += int(m.group(2))
        if diffsum.report_run(run, cli.quiet):
            fail = True
        if run.lines and any(ln.startswith("ERROR") or "ERROR IDLE" in ln for ln in run.lines):
            print("%-22s ERROR line in log" % run.name)
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
    if cli.need_cov:
        zeros = [k for k in REQUIRED if cov[k] == 0]
        if zeros:
            checks.append("coverage counters zero: " + ", ".join(zeros))
    fail = diffsum.finish(checks, fail)
    print("TOTAL " + " ".join("%s=%d" % kv for kv in sorted(tot.items())) + " " + ("FAIL" if fail else "PASS"))
    if not cli.quiet and cov:
        xf = sum(v for k, v in cov.items() if k.startswith("xfer_"))
        print("COVERAGE transfers=%d  ram_rd_beats=%d ram_wr_words=%d dev_writes=%d irq=%d bus=%d/%d resets=%d" % (
            xf, cov["ram_rd"], cov["ram_wr"], cov["gpu_w"] + cov["mdec_w"] + cov["spu_w"], cov["irq"], cov["bus_w"],
            cov["bus_r"], cov["reset"]))
        print("  per channel (from-device/to-device): " + " ".join(
            "c%d=%d/%d" % (c, cov["xfer_c%d_from" % c], cov["xfer_c%d_to" % c]) for c in range(7)))
        print("  other: " + " ".join("%s=%d" % (k, cov[k]) for k in ("err_chop", "err_cpu", "err_fifo", "pause", "stall",
                                                                   "cnt0", "cnt1", "cnt2", "cnt3", "buscoin", "gpuwait", "fiford", "wdog", "timeout")))
        zeros = [k for k in REQUIRED if cov[k] == 0]
        print("  required counters zero: " + (", ".join(zeros) if zeros else "none"))
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()
