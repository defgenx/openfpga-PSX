#!/usr/bin/env python3
"""Fault-injection self-test for tb_diff: golden vs golden with one injected fault per run.

usage: selftest.py LIBDIR BUILDDIR RUNDIR     (LIBDIR: nvc work library of the golden flavour, BUILDDIR holds mem/)
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DBG = ["R:\\\\debug_gpufifo_sim.txt", "R:\\\\debug_pixel_sim.txt", "R:\\\\debug_vram2cpu_sim.txt"]
RES = re.compile(r"^RESULT commands=(\d+) prims=(\d+) words=(\d+) wr_mismatches=(\d+) span_mismatches=(\d+) "
                 r"vram_mismatches=(\d+) rd_mismatches=(\d+) stim_errors=(\d+) timing_diffs=(\d+) stat_diffs=(\d+) "
                 r"timing_maxdelta=(\d+) cycles=(\d+) (PASS|FAIL)", re.M)
KEYS = ["commands", "prims", "words", "wr", "span", "vram", "rd", "stim", "tdiff", "sdiff", "tmax", "cycles"]
STREAM = re.compile(r"^STREAM .*?writes_gold=(\d+)", re.M)


def run(lib, build, rundir, name, gens):
    d = os.path.join(rundir, name)
    os.makedirs(d, exist_ok=True)
    for n in DBG:
        link = os.path.join(d, n)
        if not os.path.lexists(link):
            os.symlink("/dev/null", link)
    cmd = ["nvc", "--std=2008", "--ieee-warnings=off", "-H", "256m", "--work=work:" + lib, "-L", build, "-e", "--no-save",
           "-g", "G_VECFILE=../smoke.txt"]
    for k, v in gens.items():
        cmd += ["-g", "%s=%s" % (k, v)]
    cmd += ["tb_diff", "-r"]
    p = subprocess.run(cmd, cwd=d, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    open(os.path.join(d, "run.log"), "w").write(p.stdout)
    m = RES.search(p.stdout)
    s = STREAM.search(p.stdout)
    if not m or not s:
        return None
    r = dict(zip(KEYS, (int(m.group(i)) for i in range(1, 13))))
    r.update(verdict=m.group(13), rc=p.returncode, writes=int(s.group(1)))
    return r


def only(r, **want):
    """Every mismatch counter other than those named is zero and the named ones equal."""
    for k in ("wr", "span", "vram", "rd", "stim", "tdiff", "sdiff"):
        if r[k] != want.get(k, 0):
            return False
    return True


def main():
    lib, build, rundir = (os.path.abspath(a) for a in sys.argv[1:4])
    os.makedirs(rundir, exist_ok=True)
    smoke = os.path.join(rundir, "smoke.txt")
    subprocess.run([sys.executable, os.path.join(HERE, "gen_vectors.py"), "--suite", "smoke", "--seed", "1", "--out", smoke],
                   check=True, stderr=subprocess.DEVNULL)
    base = run(lib, build, rundir, "base", {})
    if not base:
        print("SELFTEST FAIL (base run produced no RESULT)")
        sys.exit(1)
    nw = base["writes"]
    k_mid = nw // 2
    tests = [
        ("base", {}, lambda r: r["verdict"] == "PASS" and r["rc"] == 0 and only(r),
         "no fault: no mismatches of any class"),
        ("wr_bit", {"G_FAULT_WR_MON": k_mid, "G_FAULT_BIT": 3},
         lambda r: r["verdict"] == "FAIL" and r["rc"] == 1 and only(r, wr=1),
         "bit flipped in the observed write #%d: exactly 1 pixel-stream mismatch" % k_mid),
        ("vram_bit", {"G_FAULT_WR_MEM": nw - 1, "G_FAULT_BIT": 5},
         lambda r: r["verdict"] == "FAIL" and only(r, vram=1),
         "bit flipped in the stored data of the last write: exactly 1 final-VRAM mismatch"),
        ("rd_bit", {"G_FAULT_RD_IDX": 0},
         lambda r: r["verdict"] == "FAIL" and only(r, rd=1),
         "bit flipped in the first compared bus read: exactly 1 read mismatch"),
        ("span_bit", {"G_FAULT_SPAN_IDX": 7},
         lambda r: r["verdict"] == "FAIL" and only(r, span=1),
         "bit flipped in DUT span #7: exactly 1 span mismatch"),
        ("idle_delay", {"G_FAULT_IDLE_PRIM": 6, "G_FAULT_IDLE_DELAY": 37},
         lambda r: r["verdict"] == "FAIL" and only(r, tdiff=1) and r["tmax"] == 37,
         "DUT idle seen 37 clk2x late for primitive 6: exactly 1 timing difference of 37"),
        ("idle_delay_lenient", {"G_FAULT_IDLE_PRIM": 6, "G_FAULT_IDLE_DELAY": 37, "G_TIMING_STRICT": "false"},
         lambda r: r["verdict"] == "PASS" and r["rc"] == 0 and only(r, tdiff=1) and r["tmax"] == 37,
         "same with G_TIMING_STRICT=false: still reported, run passes"),
    ]
    ok = True
    for name, gens, chk, desc in tests:
        r = base if name == "base" else run(lib, build, rundir, name, gens)
        good = bool(r) and chk(r)
        ok &= good
        print("selftest %-18s %s  %s  %s" % (name, "ok  " if good else "FAIL", desc, r if (r and not good) else ""))
    print("SELFTEST " + ("PASS" if ok else "FAIL"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
