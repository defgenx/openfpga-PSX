#!/usr/bin/env python3
"""Self-test of the DMA harness: faults injected into the compare path and bugs injected into a copy of dma_pocket.vhd.

usage: selftest.py BUILDDIR RUNDIR
  BUILDDIR  sim/dma_diff/build (holds mem/, golden/ and dma_sim.vhd)
  RUNDIR    scratch directory

1. golden vs golden, no fault: 0 mismatches.
2. golden vs golden with one DUT output bit flipped at one compare sample: exactly 1 mismatch, for 8 outputs.
3. one injected bug per run in a copy of rtl/dma_pocket.vhd (mutants): every one must be reported (mismatches > 0).
"""
import concurrent.futures
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "common"))
import selftest_lib as st  # noqa: E402

RTL = os.path.abspath(os.path.join(HERE, "..", "..", "rtl"))
NVC = ["nvc", "--std=2008", "--ieee-warnings=off", "-H", "256m"]
RES = re.compile(r"^RESULT cycles=(\d+) compares=(\d+) mismatches=(\d+) (PASS|FAIL)", re.M)

# name, (regex, replacement), description. The pattern must match exactly once.
MUTANTS = [
    ("madr_step", (r"(else\n\s+s_madr <= s_madr) \+ 4;", r"\1 + 8;"), "forward address step 4 -> 8"),
    ("prio_tie", (r"(DPCR\(\(i \* 4\) \+ 2 downto \(i \* 4\)\)\) <=) prio", r"\1 prio - 1"), "arbitration tie rule"),
    ("chop_gpu_wait", (r"chop_unext \+ 10;", "chop_unext + 11;"), "GPU CHCR write chop wait 10 -> 11"),
    ("chop_header", (r"chop_v  := to_unsigned\(3, 7\);", "chop_v  := to_unsigned(4, 7);"), "linked-list pause wait 3 -> 4"),
    ("chop_block", (r"(if \(s_bcr\(31 downto 16\) = 1\) then\n.*?\n.*?\n\s+else\n.*?\n.*?\n\s+chop_v  :=) to_unsigned\(2, 7\);",
                    r"\1 to_unsigned(3, 7);"), "request-mode block gap 2 -> 3"),
    ("chop_list", (r"(if \(read_accu\(23\) = '1'\) then\n.*?\n.*?\n\s+else\n.*?\n.*?\n\s+chop_v  :=) to_unsigned\(2, 7\);",
                   r"\1 to_unsigned(3, 7);"), "linked-list node gap 2 -> 3"),
    ("chop_slice", (r"chop_v  := chopwaittime\(6 downto 0\);", "chop_v  := chopwaittime(6 downto 0) + 1;"), "chopping wait + 1"),
    ("chop_tick", (r"chop_unext   <= chop_u when cpuPaused = '1' else chop_uinc;", "chop_unext   <= chop_uinc;"),
     "load stamp ignores whether this cycle ticks"),
    ("rep_refresh", (r"(REP_target   <= REP_target) \+ 6;(\n\s+REP_required <= '1';\n\s+end if;\n\s+-- special)",
                     r"\1 + 5;\2"), "SDRAM refresh timing +6 -> +5"),
    ("ram_cnt", (r'"10" when \(directionNeg = \'0\' and ram_adr\(9 downto 2\) = x"FD"\)',
                 '"01" when (directionNeg = \'0\' and ram_adr(9 downto 2) = x"FD")'), "burst length near a page end"),
    ("chcr_flags", (r"chcr32\(rd_chcr, f24\(channel\), f28\(channel\)\)", "chcr32(rd_chcr, f28(channel), f24(channel))"),
     "CHCR read: bits 24 / 28 swapped"),
    ("dpcr_reset", (r'x"07654321"', 'x"07654320"'), "DPCR reset value"),
    ("writeback", (r"wr_madr_d <= s_madr;", "wr_madr_d <= s_madr + 4;"), "MADR written back +4"),
    ("otc_last", (r"if \(wordcount = 1\) then\n(\s+fifoOut_Din\(31 downto 0\) <= x\"00FFFFFF\")",
                  r"if (wordcount = 2) then\n\1"), "OTC terminator on the wrong word"),
    ("blocks_end", (r"if \(s_bcr\(31 downto 16\) = 1\) then", "if (s_bcr(31 downto 16) = 2) then"), "request mode: last block"),
    ("chon_stop", (r"chOn\(activeChannel\) <= '0';", "null;"), "channelOn not cleared at the end"),
    ("spu_slow", (r"slowcnt  <= 1;", "slowcnt  <= 2;"), "SPU write pacing"),
    ("accu_share", (r"read_accu\(15 downto 0\) <= DMA_SPU_read;", "read_accu(15 downto 0) <= not DMA_SPU_read;"), "SPU read word"),
    ("preload_at_start", (r"                  else\n(\s+s_chcr <= chcr32\(rd_chcr)", r"                  end if;\n                  if (true) then\n\1"),
     "working copy reloaded in the start cycle"),
    ("reset_copy", (r"            s_madr         <= \(others => '0'\);\n", ""), "working copy not cleared by reset"),
    ("irq_flag", (r"DICR_IRQs\(activeChannel\) <= '1';\n(\s+if \(DICR\(23\) = '1'\) then\n\s+irqOut <= '1';\n\s+end if;\n\s+end if;\n\s+end if;\n\n\s+else)",
                  r"DICR_IRQs(activeChannel) <= '0';\n\1"), "IRQ flag not set after a transfer (first site)"),
]


def run(cmd, cwd, log):
    p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    open(log, "w").write(p.stdout)
    return p.stdout, p.returncode


def result(out):
    m = RES.search(out)
    return None if not m else dict(cycles=int(m.group(1)), compares=int(m.group(2)), mm=int(m.group(3)), verdict=m.group(4))


def gen(suite, seed, count, path):
    subprocess.run([sys.executable, os.path.join(HERE, "gen_vectors.py"), "--suite", suite, "--seed", str(seed),
                    "--count", str(count), "--out", path], stderr=subprocess.DEVNULL, check=True)


def fault_runs(build, rundir, vec):
    lib = os.path.join(build, "golden")
    tests = [("base", {}, lambda r: r["mm"] == 0 and r["verdict"] == "PASS", "no fault: 0 mismatches")]
    sigs = ["bus_dataRead", "ram_Adr", "dmaOn", "dma_cache_data", "ram_dmafifo_data", "irqOut", "ram_dmafifo_adr", "dmaRequest"]
    for k, name in enumerate(sigs):
        tests.append(("fault_" + name, {"G_FAULT_AT": 4000 + 111 * k, "G_FAULT_SIG": k},
                      lambda r: r["mm"] == 1 and r["verdict"] == "FAIL", "one flipped %s sample: exactly 1 mismatch" % name))
    tests.append(("fault_ram_cnt", {"G_FAULT_AT": 4999, "G_FAULT_SIG": 8},
                  lambda r: r["mm"] == 1 and r["verdict"] == "FAIL", "one flipped ram_cnt sample: exactly 1 mismatch"))

    def runner(name, gens):
        d = os.path.join(rundir, name)
        os.makedirs(d, exist_ok=True)
        cmd = NVC + ["--work=work:" + lib, "-L", build, "-e", "--no-save", "-g", "G_VECFILE=" + vec, "-g", "G_DUT=golden"]
        for k, v in gens.items():
            cmd += ["-g", "%s=%s" % (k, v)]
        out, _ = run(cmd + ["tb_dma", "-r"], d, os.path.join(d, "run.log"))
        return result(out)
    return tests, runner


def mutant_run(args):
    build, rundir, name, (pat, rep), vec = args
    d = os.path.join(rundir, "mut_" + name)
    os.makedirs(d, exist_ok=True)
    src = open(os.path.join(RTL, "dma_pocket.vhd")).read()
    n = len(re.findall(pat, src))
    if n != 1:
        return name, None, "pattern matched %d times" % n
    open(os.path.join(d, "dma_pocket.vhd"), "w").write(re.sub(pat, rep, src))
    lib = os.path.join(d, "work")
    tb = [os.path.join(HERE, f) for f in ("dma_diff_pkg.vhd", "dma_side.vhd", "tb_dma.vhd")]
    out, rc = run(NVC + ["--work=work:" + lib, "-L", build, "-a", os.path.join(build, "dma_sim.vhd"), os.path.join(d, "dma_pocket.vhd")], d,
                  os.path.join(d, "an1.log"))
    if rc:
        return name, None, "mutant does not analyse"
    out, rc = run(NVC + ["--work=work:" + lib, "-L", build, "-a", "--relaxed", os.path.join(HERE, "..", "common", "trace_cmp_pkg.vhd")] + tb,
                  d, os.path.join(d, "an2.log"))
    if rc:
        return name, None, "testbench does not analyse"
    out, rc = run(NVC + ["--work=work:" + lib, "-L", build, "-e", "--no-save", "-g", "G_VECFILE=" + vec, "-g", "G_DUT=pocket",
                         "tb_dma", "-r"], d, os.path.join(d, "run.log"))
    r = result(out)
    if r is None and re.search(r"^\*\* (Failure|Fatal|Error)", out, re.M):
        return name, dict(cycles=0, compares=0, mm=1, verdict="FAIL"), "crash"
    return name, r, ""


def main():
    build, rundir = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    os.makedirs(rundir, exist_ok=True)
    smoke = os.path.join(rundir, "smoke.txt")
    gen("smoke", 1, 20, smoke)
    tests, runner = fault_runs(build, rundir, smoke)
    ok = True
    for name, gens, chk, desc in tests:
        r = runner(name, gens)
        good = bool(r) and chk(r)
        ok &= good
        print("selftest %-20s %s  %s  %s" % (name, "ok  " if good else "FAIL", desc, r if (r and not good) else ""))
    # mutants run against a directed + random vector set
    vec = os.path.join(rundir, "mut.txt")
    parts = []
    for suite, seed, count in (("directed", 1, 0), ("random", 7, 30), ("boundary", 3, 48), ("contention", 5, 10), ("reset", 6, 150)):
        pth = os.path.join(rundir, "part_%s.txt" % suite)
        gen(suite, seed, count, pth)
        parts.append(open(pth).read().replace("END\n", ""))
    open(vec, "w").write("".join(parts) + "END\n")
    jobs = [(build, rundir, n, m, vec) for n, m, _ in MUTANTS]
    desc = {n: d for n, _, d in MUTANTS}
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, (os.cpu_count() or 4) - 1)) as ex:
        for name, r, why in ex.map(mutant_run, jobs):
            good = bool(r) and r["mm"] > 0 and r["verdict"] == "FAIL"
            ok &= good
            print("selftest mut_%-16s %s  %s  %s" % (name, "ok  " if good else "FAIL", desc[name],
                                                      ("(%d mismatches)" % r["mm"] if r["compares"] else "(simulator error)") if r else why))
    print("SELFTEST " + ("PASS" if ok else "FAIL"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
