#!/usr/bin/env python3
"""Aggregate cpu_diff run logs: per-run RESULT/STATS lines, summed retires and coverage counters, exit 1 on any FAIL.

A run fails on a RESULT line ending in FAIL, a simulator "** Error"/"** Failure"/"** Fatal" line, a missing RESULT, or
an ABORT. --require-coverage fails unless every counter in COVERAGE is non-zero in the sum over the runs;
--min-retires N fails unless the runs retired at least N instruction slots (cpu_done cycles of the golden);
--label tags the TOTAL line.

usage: summarize.py [--quiet] [--require-coverage] [--min-retires N] [--label L] RUNDIR...
       (each RUNDIR holds run.log)
"""
import collections
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "common"))
import diffsum  # noqa: E402

# counter index -> name (tb_diff.vhd, "coverage"); EXEMPT: counters that need a stimulus the suites do not all have
COVERAGE = {
    0: "fetch_stall", 1: "execute_stall", 2: "memory_stall", 3: "load_use_stall", 4: "dma_stall",
    5: "branch_taken", 6: "branch_not_taken", 7: "mult", 8: "multu", 9: "div", 10: "divu", 11: "div_special",
    12: "exception_execute", 13: "interrupt", 14: "overflow", 15: "address_error", 16: "syscall", 17: "break",
    18: "reserved_instr", 19: "cop_unusable", 20: "exception_in_delay_slot", 21: "cop0_breakpoint_hit",
    22: "cop0_write", 23: "rfe", 24: "scratchpad_read", 25: "cachecontrol_read", 26: "lwl", 27: "lwr", 28: "byte_load",
    29: "half_load", 30: "lwc2", 31: "partial_store", 32: "scratchpad_store", 33: "isolated_store", 34: "late_read_bypass",
    35: "late_read_write", 36: "late_read_stall", 37: "late_read_waw", 38: "decode_late_stall", 39: "block_load_forward",
    40: "icache_hit", 41: "icache_hit_last", 42: "tag_invalidate", 43: "irq_block", 44: "hilo_read_stall",
    45: "gte_read_stall", 46: "gte_cmd_stall", 47: "gte_cmd", 48: "gte_write", 49: "gte_read", 50: "breakpoint_fetch",
    51: "fetch_cached", 52: "fetch_uncached", 53: "data_write", 54: "data_read", 55: "fetch_biostag", 56: "fifo_full",
    57: "error_300", 58: "error2_starve", 59: "hilo_stall_dup", 60: "irq_high",
    61: "tag18_alias_seen", 62: "tag18_alias_valid", 63: "tag13_key_match_20bit_miss",
    64: "store_while_fifo_full",
}
EXEMPT_DEBUG = {21, 50}   # breakpoint counters: zero under NO_COP0_DEBUG
EXEMPT_ALWAYS = {55, 59, 62, 63}   # 62 must stay 0 (checked below); 55 BIOS tag merge, 59 duplicates 44, 63 informational


def main():
    argv = sys.argv[1:]
    quiet = "--quiet" in argv
    need_cov = "--require-coverage" in argv
    minret = 0
    label = ""
    dirs = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--min-retires":
            minret = int(argv[i + 1]); i += 1
        elif a == "--label":
            label = argv[i + 1]; i += 1
        elif a in ("--quiet", "--require-coverage"):
            pass
        elif a.startswith("-"):
            diffsum.usage(__doc__, "unknown option " + a)
        else:
            dirs.append(a)
        i += 1
    tot = collections.Counter()
    cov = collections.Counter()
    per_suite = collections.Counter()
    fail = False
    for d in dirs:
        run = diffsum.Run(d)
        if diffsum.report_run(run, quiet):
            fail = True
        if run.lines and any(ln.startswith("ABORT") for ln in run.lines):
            fail = True
        if run.result:
            f = run.fields()
            tot.update(f)
        if run.lines:
            for ln in run.lines:
                m = re.match(r"STATS cycles=(\d+) retires=(\d+) cmpcycles=(\d+)", ln)
                if m:
                    tot["retires"] += int(m.group(2))
                    per_suite[diffsum.suite_of(run.name)] += int(m.group(2))
                if ln.startswith("COVER"):
                    for k, v in re.findall(r"c(\d+)=(\d+)", ln):
                        cov[int(k)] += int(v)
    checks = []
    if not dirs:
        checks.append("no runs")
    elif tot["compares"] == 0:
        checks.append("no compares ran")
    if minret and tot["retires"] < minret:
        checks.append("retired %d slots, minimum %d" % (tot["retires"], minret))
    if need_cov:
        nodebug = "nodebug1" in label
        zero = [COVERAGE[k] for k in sorted(COVERAGE) if cov[k] == 0 and k not in EXEMPT_ALWAYS and not (nodebug and k in EXEMPT_DEBUG)]
        if zero:
            checks.append("coverage counters at zero: " + ", ".join(zero))
    if cov[62] != 0:
        checks.append("18-bit tag proof violated: %d fetches would hit on a 18-bit tag but miss on the 20-bit tag" % cov[62])
    fail = diffsum.finish(checks, fail)
    print("COVERAGE " + " ".join("%s=%d" % (COVERAGE[k], cov[k]) for k in sorted(COVERAGE)))
    print("SUITES retires: " + " ".join("%s=%d" % kv for kv in sorted(per_suite.items())))
    print("TOTAL %s " % label + " ".join("%s=%d" % kv for kv in sorted(tot.items())) + " " + ("FAIL" if fail else "PASS"))
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()
