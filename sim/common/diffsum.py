"""Shared pieces of the differential-harness summarizers (sim/*_diff/summarize.py).

A run directory holds run.log; its last RESULT line is "RESULT k=v ... PASS|FAIL". Simulator "** Error",
"** Failure" and "** Fatal" lines fail a run. Block-specific summarizers import this and add their own
counters and checks; summarize.py next to this file is the generic one for trace_cmp_pkg logs.
"""
import os
import re
import sys

SIMERR = re.compile(r"^\*\* (Error|Failure|Fatal)")
RESULT = re.compile(r"^RESULT ((?:\w+=\d+ )*)(PASS|FAIL)")
DETAIL = ("MISMATCH", "TIMING DIFF", "TIMEOUT", "ERROR")


class Cli:
    def __init__(self, quiet, need_cov, mins, dirs):
        self.quiet, self.need_cov, self.mins, self.dirs = quiet, need_cov, mins, dirs


def usage(doc, msg):
    sys.stderr.write("summarize.py: %s\nusage: %s" % (msg, doc.split("usage: ")[1]))
    sys.exit(2)


def parse_cli(doc, argv=None):
    """--quiet, --require-coverage, --min SUITE=N, RUNDIR...; an unknown option exits 2 (it must not turn a check off)."""
    argv = list(sys.argv[1:] if argv is None else argv)
    mins, dirs, quiet, need_cov = {}, [], False, False
    while argv:
        a = argv.pop(0)
        if a == "--min":
            m = re.fullmatch(r"(\w+)=(\d+)", argv.pop(0) if argv else "")
            if not m:
                usage(doc, "--min takes SUITE=N")
            mins[m.group(1)] = int(m.group(2))
        elif a == "--quiet":
            quiet = True
        elif a == "--require-coverage":
            need_cov = True
        elif a.startswith("-"):
            usage(doc, "unknown option " + a)
        else:
            dirs.append(a)
    return Cli(quiet, need_cov, mins, dirs)


class Run:
    def __init__(self, path):
        self.name = os.path.basename(path.rstrip("/"))
        try:
            self.lines = open(os.path.join(path, "run.log"), errors="replace").read().splitlines()
        except OSError:
            self.lines = None
        self.simerr = [ln for ln in self.lines or [] if SIMERR.match(ln)]
        self.details = [ln for ln in self.lines or [] if ln.startswith(DETAIL)]
        self.result = None  # last matching RESULT line, as a re.Match
        for ln in self.lines or []:
            m = RESULT.match(ln)
            if m:
                self.result = m

    def fields(self):
        """Counters of the RESULT line as a dict of ints."""
        return {k: int(v) for k, v in (kv.split("=") for kv in self.result.group(1).split())}

    def verdict(self):
        return self.result.group(2)


def suite_of(name):
    """Run directory SUITE_s<seed> -> SUITE."""
    return re.sub(r"_s\d+$", "", name)


def report_run(run, quiet, result_text=None):
    """Print the per-run line (and details of a failing run). Returns True when the run failed, including
    a missing log or RESULT."""
    if run.lines is None:
        print("%-22s NO LOG" % run.name)
        return True
    if not run.result:
        print("%-22s NO RESULT (crash or elaboration error)" % run.name)
        for ln in run.lines[-8:]:
            print("    " + ln)
        return True
    bad = run.verdict() != "PASS" or bool(run.simerr)
    print("%-22s %s%s" % (run.name, (result_text or run.result.group(0))[7:],
                          " (simulator errors: %d)" % len(run.simerr) if run.simerr else ""))
    if bad and not quiet:
        for ln in (run.simerr[:5] + run.details)[:20]:
            print("    " + ln)
    return bad


def check_mins(per_suite, mins, checks, unit="commands"):
    for suite, n in sorted(mins.items()):
        if per_suite[suite] < n:
            checks.append("suite %s ran %d %s, minimum %d" % (suite, per_suite[suite], unit, n))


def finish(checks, fail):
    """Print the CHECK FAIL lines; returns the overall failure flag."""
    for c in checks:
        print("CHECK FAIL: " + c)
    return fail or bool(checks)
