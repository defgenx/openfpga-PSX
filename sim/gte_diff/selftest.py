#!/usr/bin/env python3
"""Fault-injection self-test for tb_diff: golden vs golden with one injected fault per run.

usage: selftest.py LIBDIR RUNDIR     (LIBDIR: nvc work library holding the golden flavour)
"""
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "common"))
import selftest_lib as st  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DBG = "R:\\\\debug_gte_sim.txt"
RES = re.compile(r"^RESULT mismatches=(\d+) busy_diffs=(\d+) assert_fails=(\d+) commands=(\d+) (PASS|FAIL)", re.M)
ASR = re.compile(r"^ASSERTS mul=(\d+) divshift=(\d+) divrange=(\d+)", re.M)


def run(lib, rundir, name, gens):
    out, rc = st.run_tb(lib, rundir, name, gens, "../smoke.txt", [DBG])
    m = RES.search(out)
    a = ASR.search(out)
    if not m or not a:
        return None
    mm, bd, af, cmds = (int(m.group(i)) for i in range(1, 5))
    return dict(mm=mm, bd=bd, af=af, cmds=cmds, verdict=m.group(5), mul=int(a.group(1)), shift=int(a.group(2)),
                rng=int(a.group(3)), rc=rc)


def main():
    lib, rundir = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    os.makedirs(rundir, exist_ok=True)
    smoke = os.path.join(rundir, "smoke.txt")
    err = st.gen_vectors(os.path.join(HERE, "gen_vectors.py"), smoke)
    m = re.search(r"seq_cmds=(\d+) total_cmds=(\d+)", err)
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
    st.run_tests(tests, lambda name, gens: run(lib, rundir, name, gens))


if __name__ == "__main__":
    main()
