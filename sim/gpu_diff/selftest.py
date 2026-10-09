import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "common"))
import selftest_lib as st  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DBG = ["R:\\\\debug_gpufifo_sim.txt", "R:\\\\debug_pixel_sim.txt", "R:\\\\debug_vram2cpu_sim.txt"]
RES = re.compile(r"^RESULT commands=(\d+) prims=(\d+) words=(\d+) wr_mismatches=(\d+) span_mismatches=(\d+) "
                 r"vram_mismatches=(\d+) rd_mismatches=(\d+) stim_errors=(\d+) timing_diffs=(\d+) stat_diffs=(\d+) "
                 r"timing_maxdelta=(\d+) cycles=(\d+) (PASS|FAIL)", re.M)
KEYS = ["commands", "prims", "words", "wr", "span", "vram", "rd", "stim", "tdiff", "sdiff", "tmax", "cycles"]
STREAM = re.compile(r"^STREAM .*?writes_gold=(\d+)", re.M)
SETUPCHK = re.compile(r"^SETUPCHK checked=(\d+) violations=(\d+)", re.M)


def run(lib, build, rundir, name, gens):
    out, rc = st.run_tb(lib, rundir, name, gens, "../smoke.txt", DBG, libdirs=[build],
                        nvc_args=["--ieee-warnings=off", "-H", "256m"])
    m = RES.search(out)
    s = STREAM.search(out)
    if not m or not s:
        return None
    r = dict(zip(KEYS, (int(m.group(i)) for i in range(1, 13))))
    c = SETUPCHK.search(out)
    r.update(verdict=m.group(13), rc=rc, writes=int(s.group(1)), checked=int(c.group(1)) if c else 0,
             viol=int(c.group(2)) if c else -1)
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
    st.gen_vectors(os.path.join(HERE, "gen_vectors.py"), smoke)
    base = run(lib, build, rundir, "base", {})
    if not base:
        print("SELFTEST FAIL (base run produced no RESULT)")
        sys.exit(1)
    nw = base["writes"]
    k_mid = nw // 2
    tests = [
        ("base", {}, lambda r: r["verdict"] == "PASS" and r["rc"] == 0 and only(r) and r["viol"] == 0 and r["checked"] > 0,
         "no fault: no mismatches of any class"),
        ("wr_bit", {"G_FAULT_WR_MON": k_mid, "G_FAULT_BIT": 3},
         lambda r: r["verdict"] == "FAIL" and r["rc"] == 1 and only(r, wr=1),
         "bit flipped in the observed write #%d: exactly 1 pixel-stream mismatch" % k_mid),
        ("vram_bit", {"G_FAULT_WR_MEM": nw - 1, "G_FAULT_BIT": 5},
         lambda r: r["verdict"] == "FAIL" and only(r, vram=1),
         "bit flipped in the stored data of the last write: exactly 1 final-VRAM mismatch"),
        ("rd_stat_bit", {"G_FAULT_RD_IDX": 0},
         lambda r: r["verdict"] == "FAIL" and only(r, rd=1),
         "bit flipped in the first compared bus read (GPUSTAT): exactly 1 read mismatch"),
        ("rd_data_bit", {"G_FAULT_RD_IDX": 1},
         lambda r: r["verdict"] == "FAIL" and only(r, rd=1),
         "bit flipped in the first GPUREAD (VRAM to CPU) word: exactly 1 read mismatch"),
        ("setup_viol", {"G_FAULT_SETUP_TRI": 1, "G_FAULT_SETUP_ADD": 1000},
         lambda r: r["verdict"] == "FAIL" and r["rc"] == 1 and only(r) and r["viol"] == 1,
         "DUT setup of triangle 1 inflated by 1000 clk2x: exactly 1 setup-criterion violation"),
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
    st.run_tests(tests, lambda name, gens: run(lib, build, rundir, name, gens), base=base)


if __name__ == "__main__":
    main()
