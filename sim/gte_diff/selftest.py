#!/usr/bin/env python3
"""Fault-injection self-test for tb_diff: golden vs golden with one injected fault per run.

usage: selftest.py LIBDIR RUNDIR     (LIBDIR: nvc work library holding the golden flavour)
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DBG = "R:\\\\debug_gte_sim.txt"
RES = re.compile(r"^RESULT mismatches=(\d+) busy_diffs=(\d+) assert_fails=(\d+) commands=(\d+) (PASS|FAIL)", re.M)
ASR = re.compile(r"^ASSERTS mul=(\d+) divshift=(\d+) divrange=(\d+)", re.M)


def run(lib, rundir, name, gens):
    d = os.path.join(rundir, name)
    os.makedirs(d, exist_ok=True)
    link = os.path.join(d, DBG)
    if not os.path.lexists(link):
        os.symlink("/dev/null", link)
    cmd = ["nvc", "--std=2008", "--work=work:" + lib, "-e", "--no-save", "-g", "G_VECFILE=../smoke.txt"]
    for k, v in gens.items():
        cmd += ["-g", "%s=%s" % (k, v)]
    cmd += ["tb_diff", "-r"]
    p = subprocess.run(cmd, cwd=d, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    open(os.path.join(d, "run.log"), "w").write(p.stdout)
    m = RES.search(p.stdout)
    a = ASR.search(p.stdout)
    if not m or not a:
        return None
    mm, bd, af, cmds = (int(m.group(i)) for i in range(1, 5))
    return dict(mm=mm, bd=bd, af=af, cmds=cmds, verdict=m.group(5), mul=int(a.group(1)), shift=int(a.group(2)),
                rng=int(a.group(3)), rc=p.returncode)


def main():
    lib, rundir = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    os.makedirs(rundir, exist_ok=True)
    smoke = os.path.join(rundir, "smoke.txt")
    p = subprocess.run([sys.executable, os.path.join(HERE, "gen_vectors.py"), "--suite", "smoke", "--seed", "1", "--out", smoke],
                       stderr=subprocess.PIPE, text=True)
    m = re.search(r"seq_cmds=(\d+) total_cmds=(\d+)", p.stderr)
    seq, total = int(m.group(1)), int(m.group(2))
    kcpu = seq + 2

    # name, generics, check(result) -> bool, description
    tests = [
        ("base", {}, lambda r: r["verdict"] == "PASS" and r["rc"] == 0 and (r["mm"], r["bd"], r["af"]) == (0, 0, 0),
         "no fault: 0 mismatches, 0 busy diffs, 0 assertion failures"),
        ("xor_seq", {"G_FAULT_XOR_CMD": 5, "G_FAULT_XOR_REG": 25, "G_FAULT_XOR_BIT": 3},
         lambda r: r["verdict"] == "FAIL" and r["rc"] == 1 and (r["mm"], r["bd"], r["af"]) == (1, 0, 0),
         "one flipped bit in a dump read: exactly 1 mismatch"),
        ("xor_cpu", {"G_FAULT_XOR_CMD": kcpu, "G_FAULT_XOR_REG": 24, "G_FAULT_XOR_BIT": 0},
         lambda r: r["verdict"] == "FAIL" and (r["mm"], r["bd"], r["af"]) == (1, 0, 0),
         "one flipped bit on the CPU-timing read path: exactly 1 mismatch"),
        ("busy_delay", {"G_FAULT_BUSY_CMD": kcpu},
         lambda r: r["verdict"] == "FAIL" and (r["mm"], r["af"]) == (0, 0) and r["bd"] == 2 * (total - kcpu),
         "golden busy delayed 1 clk1x from command %d: exactly %d busy diffs" % (kcpu, 2 * (total - kcpu))),
        ("assert_mul", {"G_FAULT_MUL": 100},
         lambda r: r["verdict"] == "FAIL" and (r["mm"], r["bd"]) == (0, 0) and (r["mul"], r["shift"], r["rng"]) == (1, 0, 0),
         "bad multiply operand: only the multiply invariant fires, once"),
        ("assert_divshift", {"G_FAULT_DIVSHIFT": 3},
         lambda r: r["verdict"] == "FAIL" and (r["mm"], r["bd"]) == (0, 0) and (r["mul"], r["shift"], r["rng"]) == (0, 1, 0),
         "bad divider shift: only the shift check fires, once"),
        ("assert_divrange", {"G_FAULT_DIVRANGE": 5},
         lambda r: r["verdict"] == "FAIL" and (r["mm"], r["bd"]) == (0, 0) and (r["mul"], r["shift"], r["rng"]) == (0, 0, 1),
         "out-of-range divider value: only the range check fires, once"),
    ]
    ok = True
    for name, gens, chk, desc in tests:
        r = run(lib, rundir, name, gens)
        good = bool(r) and chk(r)
        ok &= good
        print("selftest %-16s %s  %s  %s" % (name, "ok  " if good else "FAIL", desc, r if (r and not good) else ""))
    print("SELFTEST " + ("PASS" if ok else "FAIL"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
