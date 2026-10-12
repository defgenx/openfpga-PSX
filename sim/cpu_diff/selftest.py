#!/usr/bin/env python3
"""Self-test of the cpu_diff harness: it must catch injected bugs.

usage: selftest.py GOLDEN_LIB RUNDIR [--no-mutants]

1. Comparator faults (tb_diff generic G_FAULT): the DUT side of the golden-vs-golden flavour has one output bit
   flipped from cycle G_FAULT_CYCLE; the run must FAIL and the first MISMATCH must name that output.
2. RTL mutants: single-line mutations of rtl/cpu_pocket.vhd (mutants.py) are built and run against the golden on a
   short mixed stimulus; every mutant must be reported as a mismatch. A mutant whose pattern does not match exactly once
   fails the self-test (the list must follow the RTL).
The unmutated pocket and the golden-vs-golden flavour must PASS.
"""
import concurrent.futures as cf
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "common"))
import selftest_lib as st  # noqa: E402

RTL = os.path.abspath(os.path.join(HERE, "..", "..", "rtl"))
NVC = ["nvc", "--std=2008", "--ieee-warnings=off"]
BUILD = os.path.join(HERE, "build")

# fault -> (name expected in the first MISMATCH, suite whose image exercises it)
FAULTS = {
    1: ("mem_dataWrite", "smoke"), 2: ("cpu_export", "smoke"), 3: ("stallNext", "smoke"), 4: ("mem_request", "smoke"),
    5: ("mem_addressInstr", "smoke"), 6: ("mem_oldtagvalids", "smoke"), 7: ("SS_idle", "smoke"), 8: ("error2", "smoke"),
    9: ("gte_cmdEna", "gte"), 10: ("gte_writeData", "gte"), 11: ("cpu_done", "smoke"), 12: ("mem_writeMask", "smoke"),
    13: ("mem_isData", "smoke"), 14: ("mem_rnw", "smoke"), 15: ("mem_isCache", "smoke"), 16: ("error", "smoke"),
    17: ("gte_readEna", "gte"),
}


def gen(suite, seed, out, extra=()):
    subprocess.run([sys.executable, os.path.join(HERE, "gen_prog.py"), "--suite", suite, "--seed", str(seed), "--out", out] + list(extra),
                   check=True, stderr=subprocess.DEVNULL)


def run(lib, rundir, name, image, gens, libdirs=(BUILD,)):
    d = os.path.join(rundir, name)
    os.makedirs(d, exist_ok=True)
    cmd = NVC + ["-H", "256m", "--work=work:" + lib]
    for l in libdirs:
        cmd += ["-L", l]
    cmd += ["-e", "--no-save", "-g", "G_IMAGE=" + image]
    for k, v in gens.items():
        cmd += ["-g", "%s=%s" % (k, v)]
    cmd += ["tb_diff", "-r"]
    p = subprocess.run(cmd, cwd=d, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    open(os.path.join(d, "run.log"), "w").write(p.stdout)
    return p.stdout, p.returncode


RES = re.compile(r"^RESULT cycles=(\d+) compares=(\d+) mismatches=(\d+) (PASS|FAIL)", re.M)
FIRST = re.compile(r"^MISMATCH (\w+)", re.M)


def parse(out):
    m = RES.search(out)
    if not m:
        return None
    f = FIRST.search(out)
    return dict(cycles=int(m.group(1)), mm=int(m.group(3)), verdict=m.group(4), first=f.group(1) if f else None)


def comparator_tests(lib, rundir):
    images = {}
    for suite in ("smoke", "gte"):
        images[suite] = os.path.join(rundir, "img_%s.txt" % suite)
        gen(suite, 1, images[suite])
    tests = []
    base = parse(run(lib, rundir, "base", images["smoke"], {"G_CYCLES": 20000})[0])
    tests.append(("base", {}, lambda r: r["verdict"] == "PASS" and r["mm"] == 0, "golden vs golden: 0 mismatches"))
    results = {"base": base}
    for k, (name, suite) in sorted(FAULTS.items()):
        gens = {"G_CYCLES": 40000, "G_FAULT": k, "G_FAULT_CYCLE": 4000}
        r = parse(run(lib, rundir, "fault%d" % k, images[suite], gens)[0])
        results["fault%d" % k] = r
        tests.append(("fault%d" % k, gens, (lambda r, n=name: r["verdict"] == "FAIL" and r["first"] == n),
                      "flip of %s is reported as %s" % (name, name)))
    return tests, results


def mutant_tests(rundir, workers):
    sys.path.insert(0, HERE)
    import mutants  # noqa: E402
    src = open(os.path.join(RTL, "cpu_pocket.vhd")).read()
    pocket_lib = os.path.join(BUILD, "pocket")
    # (name, suite, seed, generator args, testbench generics)
    plan = [
        ("random5", "random", 5, (), {"G_CYCLES": 60000}),
        ("random6", "random", 6, (), {"G_CYCLES": 60000, "G_FIFO_THR": 2, "G_FIFO_DRAIN": 10}),
        ("exc5", "exc", 5, (), {"G_CYCLES": 60000}),
        ("gte5", "gte", 5, (), {"G_CYCLES": 60000}),
        ("cache5", "cache", 5, (), {"G_CYCLES": 60000}),
        ("dmem", "directed", 5, ("--parts", "mem,branch"), {"G_CYCLES": 150000, "G_FIFO_THR": 2, "G_FIFO_DRAIN": 10}),
        ("dexc", "directed", 5, ("--parts", "exc,cop0"), {"G_CYCLES": 150000}),
        ("dgte", "directed", 5, ("--parts", "gte"), {"G_CYCLES": 150000}),
        ("dmuldiv", "directed", 5, ("--parts", "muldiv"), {"G_CYCLES": 200000}),
        ("dcache", "directed", 5, ("--parts", "cache"), {"G_CYCLES": 150000}),
        ("reset", "random", 7, ("--bp",), {"G_CYCLES": 120000, "G_RESET_EVERY": 4000, "G_LONGWAIT": 2500}),
    ]
    images = []
    for name, suite, seed, extra, gens in plan:
        img = os.path.join(rundir, "mimg_%s.txt" % name)
        gen(suite, seed, img, extra)
        images.append((name, img, gens))
    base_srcs = [os.path.join(HERE, "cpu_dut.vhd"), os.path.join(HERE, "dut_pocket.vhd")]

    def one(m):
        name, pat, rep = m
        n = len(re.findall(pat, src, flags=re.S))
        if n != 1:
            return name, None, "pattern matches %d times" % n
        mut = re.sub(pat, rep, src, count=1, flags=re.S)
        d = os.path.join(rundir, "mut_" + name)
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d)
        lib = os.path.join(d, "work")
        shutil.copytree(pocket_lib, lib)
        mf = os.path.join(d, "cpu_pocket.vhd")
        open(mf, "w").write(mut)
        p = subprocess.run(NVC + ["-H", "256m", "--work=work:" + lib, "-L", BUILD, "-a", mf, base_srcs[1]], stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True)
        if p.returncode != 0:
            return name, None, "mutant does not analyse: " + p.stdout[-300:]
        for iname, img, gens in images:
            g = dict(gens)
            g.update({"G_STOP_FAILS": 1, "G_NO_COP0_DEBUG": "false"})
            out, rc = run(lib, d, "r_" + iname, img, g)
            r = parse(out)
            if r is None:
                if "Fatal" in out or "Error" in out or "Failure" in out:
                    return name, True, "simulator error (%s)" % iname
                return name, None, "no result (%s)" % iname
            if r["mm"] > 0:
                return name, True, "caught by %s on %s" % (iname, r["first"])
        return name, False, "SURVIVED"

    results = []
    with cf.ThreadPoolExecutor(max_workers=workers) as ex:
        for r in ex.map(one, mutants.MUTANTS):
            results.append(r)
            print("mutant %-28s %s" % (r[0], r[2]), flush=True)
    return results


def main():
    lib, rundir = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    os.makedirs(rundir, exist_ok=True)
    tests, results = comparator_tests(lib, rundir)
    ok = True
    for name, gens, chk, desc in tests:
        r = results[name]
        good = bool(r) and chk(r)
        ok &= good
        print("selftest %-10s %s  %s  %s" % (name, "ok  " if good else "FAIL", desc, r if not good else ""))
    if "--no-mutants" not in sys.argv and os.path.exists(os.path.join(HERE, "mutants.py")) and os.path.isdir(os.path.join(BUILD, "pocket")):
        res = mutant_tests(rundir, int(os.environ.get("MUTANT_JOBS", "6")))
        bad = [r for r in res if r[1] is not True]
        for r in bad:
            print("selftest mutant %s: %s" % (r[0], r[2]))
        ok &= not bad
        print("mutants: %d caught of %d" % (sum(1 for r in res if r[1] is True), len(res)))
    print("SELFTEST " + ("PASS" if ok else "FAIL"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
