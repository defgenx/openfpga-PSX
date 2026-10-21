#!/usr/bin/env python3
"""RTL mutants of the gpu_pocket units: one text edit of one file, run against the unmodified golden; the run must be
reported (a mismatch, a simulator error, or a timing difference in a class that is cycle exact by design).

usage: mutants.py [-j N] [NAME...]        (make mutants; needs build/pocket, i.e. make diff ran once)

A mutant that survives means the stimulus does not reach that behaviour: add a directed case to gen_vectors.py.
"""
import concurrent.futures
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.abspath(os.path.join(HERE, "..", "..", "rtl"))
BUILD = os.path.join(HERE, "build")
RUN = os.path.join(HERE, "run", "mutants")
DBG = ["R:\\\\debug_gpufifo_sim.txt", "R:\\\\debug_pixel_sim.txt", "R:\\\\debug_vram2cpu_sim.txt"]
RESULT = re.compile(r"^RESULT (.*) (PASS|FAIL)", re.M)
TIMING = re.compile(r"^TIMING (\S+) n=(\d+) gold=(\d+) dut=(\d+) maxdelta=(\d+) diffs=(\d+)", re.M)
EXACT = ("rect", "fill", "copy", "upload")      # classes whose cycle counts equal the golden's

S_DIR = ("directed", 1, 2000)
S_EDGE = ("edge", 1, 2000)
S_RAND = ("random", 1, 600)
S_RAND2 = ("random", 2, 600)
S_CACHE = ("cache", 1, 800)
S_CACHE2 = ("cache", 2, 800)
PP = "gpu_pixelpipeline_pocket.vhd"

# name, file, old text (must occur once), new text, runs (suite, seed, count); the first run that reports the mutant ends it
MUTANTS = [
]


def sh(cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def build_mutant(name, fname, old, new):
    d = os.path.join(BUILD, "mut_" + name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    text = open(os.path.join(RTL, fname)).read()
    assert text.count(old) == 1, "mutant %s: pattern found %d times" % (name, text.count(old))
    src = os.path.join(d, fname)
    open(src, "w").write(text.replace(old, new))
    shutil.copytree(os.path.join(BUILD, "pocket"), os.path.join(d, "work"))
    p = sh(["nvc", "--std=2008", "--ieee-warnings=off", "-H", "256m", "--work=work:" + os.path.join(d, "work"), "-L", BUILD, "-a", src])
    open(os.path.join(d, "build.log"), "w").write(p.stdout)
    return d if p.returncode == 0 else None


def run_one(d, name, suite, seed, count):
    rd = os.path.join(RUN, "%s_%s%d" % (name, suite, seed))
    shutil.rmtree(rd, ignore_errors=True)
    os.makedirs(rd)
    for n in DBG:
        os.symlink("/dev/null", os.path.join(rd, n))
    vec = os.path.join(rd, "vec.txt")
    p = sh([sys.executable, os.path.join(HERE, "gen_vectors.py"), "--suite", suite, "--seed", str(seed), "--count", str(count), "--out", vec])
    if p.returncode != 0:
        return "generator failed: " + p.stdout[-200:]
    p = sh(["nvc", "--std=2008", "--ieee-warnings=off", "-H", "256m", "--work=work:" + os.path.join(d, "work"), "-L", BUILD, "-e", "--no-save",
            "-g", "G_VECFILE=" + vec, "-g", "G_TIMING_STRICT=false", "tb_diff", "-r"], cwd=rd)
    open(os.path.join(rd, "run.log"), "w").write(p.stdout)
    os.remove(vec)
    if re.search(r"^\*\* (Error|Failure|Fatal)", p.stdout, re.M):
        return "simulator error"
    m = RESULT.search(p.stdout)
    if not m:
        return "no result"
    if m.group(2) == "FAIL":
        return "mismatch " + " ".join(kv for kv in m.group(1).split() if re.match(r"\w+_mismatches=[1-9]", kv))
    for t in TIMING.finditer(p.stdout):
        if t.group(1) in EXACT and int(t.group(6)) > 0:
            return "timing of %s differs in %s prims" % (t.group(1), t.group(6))
    return None


def main():
    args = sys.argv[1:]
    jobs = 4
    if args[:1] == ["-j"]:
        jobs = int(args[1])
        args = args[2:]
    sel = [m for m in MUTANTS if not args or m[0] in args]
    if not os.path.isdir(os.path.join(BUILD, "pocket")):
        print("build/pocket missing: run make diff first")
        sys.exit(2)
    os.makedirs(RUN, exist_ok=True)

    def one(m):
        name, fname, old, new, runs = m
        d = build_mutant(name, fname, old, new)
        if d is None:
            return name, "build", None
        for suite, seed, count in runs:
            r = run_one(d, name, suite, seed, count)
            if r:
                return name, "%s s%d" % (suite, seed), r
        return name, None, None

    ok = True
    with concurrent.futures.ThreadPoolExecutor(jobs) as ex:
        for name, how, info in ex.map(one, sel):
            good = how not in (None, "build")
            ok &= good
            print("mutant %-22s %s  %s" % (name, "caught" if good else "FAIL  ",
                                          ("by %s: %s" % (how, info)) if good else ("did not build" if how == "build" else "SURVIVED")), flush=True)
    print("MUTANTS " + ("PASS" if ok else "FAIL") + " (%d)" % len(sel))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
