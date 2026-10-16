#!/usr/bin/env python3
"""Fault-injection self-test of the cd_diff harness, and the helper that builds the "self" flavour.

usage: selftest.py --rename SRCDIR DSTDIR   write the patched golden renamed to cd_pocket / cd_pocket_xa (the "self" flavour)
       selftest.py BUILD RUNDIR             run the self-test (make selftest; needs the self flavour and the golden library)

Two kinds of fault, each must be reported:
  * output faults: one compared DUT output is inverted for exactly one clock (tb generics G_FAULT_SIG, G_FAULT_CYC);
    the run must report exactly one mismatch, on that output. This proves every compare path.
  * RTL mutants: one edit of the renamed golden, run against the unmodified golden; the run must FAIL. This proves that the
    stimulus reaches the behaviour (timing constants, response bytes, option paths, XA, CD-DA, libcrypt, ...).
The unmodified renamed golden must pass first (base).
"""
import concurrent.futures
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

GENERICS = "generic (NO_XA : boolean := false; FIXED_CD_TIMING : boolean := false; NO_LIBCRYPT : boolean := false; NO_CD_PEAK : boolean := false);"


def rename(src, dst):
    os.makedirs(dst, exist_ok=True)
    t = open(os.path.join(src, "cd_top.vhd")).read()
    t = t.replace("entity cd_top is\n   port", "entity cd_pocket is\n   " + GENERICS + "\n   port")
    t = t.replace("architecture arch of cd_top is", "architecture arch of cd_pocket is")
    t = t.replace("entity work.cd_xa\n", "entity work.cd_pocket_xa\n")
    x = open(os.path.join(src, "cd_xa.vhd")).read()
    x = x.replace("entity cd_xa is", "entity cd_pocket_xa is").replace("architecture arch of cd_xa is", "architecture arch of cd_pocket_xa is")
    assert "cd_pocket_xa" in t and "entity cd_pocket is" in t and "entity cd_pocket_xa is" in x
    open(os.path.join(dst, "cd_pocket.vhd"), "w").write(t)
    open(os.path.join(dst, "cd_pocket_xa.vhd"), "w").write(x)


# output faults: G_FAULT_SIG index (see tb_diff.vhd) -> the name of the compare that must fire
FAULTS = [
    (0, "bus_dataRead"), (1, "irqOut"), (2, "dma_readdata"), (3, "cd_left"), (4, "cd_right"), (5, "cd_hps_req"),
    (6, "cd_hps_lba"), (7, "pauseCD"), (8, "Pause_idle_cd"), (9, "fullyIdle"), (10, "cdSlow"), (11, "resetFromCD"),
    (12, "region_out"), (13, "LBAdisplay"), (14, "error"),
]

# RTL mutants: name, file (top|xa), old text, new text, runs to try (suite, seed/scenario, count), first one that fails wins
R_RAND = [("random", 1, 1500), ("random", 2, 1500)]
MUTANTS = [
    # the delay constants hide behind the time compression: only the real-time suite sees them
    ("cmd_delay",      "top", "cmd_delay  <= 25000 - 2;", "cmd_delay  <= 25001 - 2;", [("realtime", 0, 1)]),
    ("pause_wait",     "top", "pause_target_v := pause_rotation_ticks - (2 * driveREADSPEED);", "pause_target_v := pause_rotation_ticks - (3 * driveREADSPEED);", [("realtime", 22, 1)]),
    ("getid_char",     "top", "natural(character'pos('S'))", "natural(character'pos('T'))", [("directed", 0, 2)] + R_RAND),
    ("getlocp_byte",   "top", "FifoResponse_Din <= subdata(1);", "FifoResponse_Din <= subdata(2);", R_RAND),
    ("libcrypt_pair",  "top", "= 14105 or (lastReadSector + 2) = 14110", "= 14105 or (lastReadSector + 2) = 14111", [("directed", 4, 1)]),
    ("libcrypt_last",  "top", "(lastReadSector + 2) = 16172", "(lastReadSector + 2) = 16173", [("directed", 4, 1)]),
    ("xa_filter",      "top", "XaFilterFile /= subheader(7 downto 0))) then", "XaFilterFile = subheader(7 downto 0))) then", [("directed", 3, 1)]),
    ("irq_timeout",    "top", "elsif (irqTimeout < 10000) then", "elsif (irqTimeout < 9999) then", [("directed", 3, 1)] + R_RAND),
    ("volume_cross",   "top", "soundmul2 <= unsigned(cdvol_10);", "soundmul2 <= unsigned(cdvol_01);", [("directed", 3, 1, 1)]),
    ("seek_time",      "top", "elsif (diffLBA < 32) then\n                  seekTimeMul <= 5;", "elsif (diffLBA < 33) then\n                  seekTimeMul <= 5;", [("realtime", 21, 1)]),
    ("spt_table",      "top", "elsif (mm <= 4) then return 9;", "elsif (mm <= 4) then return 10;", [("directed", 0, 2)] + R_RAND),
    ("slow_timeout",   "top", "slow_timeout <= 16777215;", "slow_timeout <= 16777214;", [("realtime", 9, 1)]),
    ("pausecd",        "top", "driveDelay < 32768", "driveDelay < 3000", [("realtime", 9, 1)]),
    ("status_resp",    "top", "CDROM_STATUS(5) <= not FifoResponse_Empty;", "CDROM_STATUS(5) <= FifoResponse_Empty;", R_RAND),
    ("xa_resample",    "xa",  "resampleSum <= resampleSum + resampleMul;", "resampleSum <= resampleSum + resampleMul + 1;", [("directed", 3, 1)]),
    ("subchannel_bcd", "top", "if (sub_SecondsLow < 9) then", "if (sub_SecondsLow < 8) then", [("directed", 0, 2)] + R_RAND),
    ("adpcm_clamp",    "xa",  "elsif (sample > 32767) then clamped <= x\"7FFF\";", "elsif (sample > 32767) then clamped <= x\"7F00\";", [("directed", 3, 1, 1)]),
    ("header_mode",    "top", "if (fetchcount = 3 and checkData(31 downto 24) /= x\"02\")", "if (fetchcount = 3 and checkData(31 downto 24) /= x\"03\")", R_RAND + [("directed", 3, 1)]),
    ("copy_byte",      "top", "FifoData_Din <= sectorBuffers_DataB(7 downto 0);", "FifoData_Din <= sectorBuffers_DataB(15 downto 8);", [("directed", 1, 1)] + R_RAND),
    ("track_search",   "top", "lastReadSector <= endLBA) then", "lastReadSector < endLBA) then", [("directed", 4, 1)] + R_RAND),
    ("peak_flag",      "top", "FifoResponse_Din <= '1' & std_logic_vector(peakvolumeR(14 downto 8));", "FifoResponse_Din <= '0' & std_logic_vector(peakvolumeR(14 downto 8));", [("directed", 3, 1)]),
    ("cdslow_limit",   "top", "driveDelay < 128 and slow_block = '0'", "driveDelay < 127 and slow_block = '0'", [("directed", 2, 1)] + R_RAND),
    ("fast_forward",   "top", "fastForwardRate <= fastForwardRate + 4;", "fastForwardRate <= fastForwardRate + 3;", [("directed", 3, 1)] + R_RAND),
    ("cd_left_clamp",  "top", "if (soundsum < -32768) then cd_left <= x\"8000\";", "if (soundsum < -32768) then cd_left <= x\"8001\";", [("directed", 3, 1, 1)]),
    ("lba_display",    "top", "LBAdisplay  <= to_unsigned(currentLBA, 20);", "LBAdisplay  <= to_unsigned(currentLBA + 1, 20);", R_RAND),
    ("reset_from_cd",  "top", "resetFromCD <= trackinfo_data(18) and (not LIDopen);", "resetFromCD <= trackinfo_data(18);", R_RAND + [("directed", 3, 1)]),
    ("dma_empty",      "top", "dma_readdata <= FifoData_Dout when (FifoData_Empty = '0') else (others => '0');", "dma_readdata <= FifoData_Dout when (FifoData_Empty = '0') else (others => '1');", [("directed", 1, 1)]),
    ("getparam_mode",  "top", "if (cmd_delay = 4)  then FifoResponse_Wr <= '1'; FifoResponse_Din <= modeReg; end if;", "if (cmd_delay = 4)  then FifoResponse_Wr <= '1'; FifoResponse_Din <= modeReg or x\"01\"; end if;", R_RAND),
    ("pregap_pos",     "top", "positionInIndex <= lastReadSector - startLBA - PREGAPSIZE;", "positionInIndex <= lastReadSector - startLBA - PREGAPSIZE + 1;", [("directed", 1, 1)]),
    ("hps_lba",        "top", "cd_hps_lba       <= std_logic_vector(to_unsigned(lastReadSector, 32));", "cd_hps_lba       <= std_logic_vector(to_unsigned(lastReadSector + 1, 32));", R_RAND),
]


def sh(cmd, cwd=None, log=None):
    p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if log:
        open(log, "w").write(p.stdout)
    return p


def build_mutant(build, name, which, old, new, mem_srcs):
    """Analyse the renamed golden with one edit into build/mut_<name>/{dut,work}."""
    d = os.path.join(build, "mut_" + name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    srcs = {"top": os.path.join(build, "selfsrc", "cd_pocket.vhd"), "xa": os.path.join(build, "selfsrc", "cd_pocket_xa.vhd")}
    texts = {k: open(v).read() for k, v in srcs.items()}
    assert texts[which].count(old) == 1, "mutant %s: pattern found %d times" % (name, texts[which].count(old))
    texts[which] = texts[which].replace(old, new)
    for k, t in texts.items():
        open(os.path.join(d, k + ".vhd"), "w").write(t)
    nvc = ["nvc", "--std=2008", "--ieee-warnings=off", "-H", "256m"]
    zig = os.path.join(HERE, "..", "..", "rtl", "cd_xa_zigzag.vhd")
    tb = [os.path.join(HERE, "..", "common", "trace_cmp_pkg.vhd"), os.path.join(HERE, "cd_diff_pkg.vhd"), os.path.join(HERE, "tb_diff.vhd")]
    for cmd in (nvc + ["--work=dut:" + os.path.join(d, "dut"), "-L", build, "-a", "--relaxed"] + mem_srcs,
                nvc + ["--work=dut:" + os.path.join(d, "dut"), "-L", build, "-a", zig, os.path.join(d, "xa.vhd"), os.path.join(d, "top.vhd")],
                nvc + ["--work=work:" + os.path.join(d, "work"), "-L", os.path.join(build, "gold"), "-L", d, "-L", build, "-a"] + tb):
        p = sh(cmd, log=os.path.join(d, "build.log"))
        if p.returncode != 0:
            return None
    return d


def run_tb(build, libdir, rundir, name, suite, seed, count, extra=(), rseed=None):
    """Run tb_diff of the flavour in LIBDIR (holds dut/ and work/); returns (RESULT fields dict or None, MISMATCH names, log)."""
    d = os.path.join(rundir, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    nvc = ["nvc", "--std=2008", "--ieee-warnings=off", "-H", "256m", "--work=work:" + os.path.join(libdir, "work"),
           "-L", os.path.join(build, "gold"), "-L", libdir, "-L", build, "-e", "--no-save",
           "-g", "G_SUITE=" + suite, "-g", "G_SCEN=%d" % seed, "-g", "G_SEED=%d" % (seed if rseed is None else rseed), "-g", "G_COUNT=%d" % count] + list(extra) + ["tb_diff", "-r"]
    p = sh(nvc, cwd=d, log=os.path.join(d, "run.log"))
    res = None
    names = []
    for ln in p.stdout.splitlines():
        m = re.match(r"^RESULT ((?:\w+=\d+ )*)(PASS|FAIL)", ln)
        if m:
            res = {k: int(v) for k, v in (kv.split("=") for kv in m.group(1).split())}
            res["verdict"] = m.group(2)
        m = re.match(r"^MISMATCH (\w+) ", ln)
        if m:
            names.append(m.group(1))
        if re.match(r"^\*\* (Error|Failure|Fatal)", ln):
            res = res or {"verdict": "FAIL", "mismatches": 0}
            res["simerr"] = 1
    return res, names


def main():
    build, rundir = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    os.makedirs(rundir, exist_ok=True)
    mem_srcs = [s for s in os.environ.get("MEM_SRCS", "").split() if s]
    jobs = int(os.environ.get("SELFTEST_JOBS", "4"))
    selfdir = os.path.join(build, "self")
    ok = True

    def report(name, good, text):
        nonlocal ok
        ok &= good
        print("selftest %-18s %s  %s" % (name, "ok  " if good else "FAIL", text), flush=True)

    res, _ = run_tb(build, selfdir, rundir, "base", "random", 1, 200)
    report("base", bool(res) and res["verdict"] == "PASS" and res["mismatches"] == 0,
           "renamed golden against the golden: 0 mismatches %s" % (res or "no result"))

    # output faults
    def fault(item):
        sig, name = item
        r, names = run_tb(build, selfdir, rundir, "fault_" + name, "random", 1, 60, ["-g", "G_FAULT_SIG=%d" % sig, "-g", "G_FAULT_CYC=20000"])
        return name, r, names

    with concurrent.futures.ThreadPoolExecutor(jobs) as ex:
        for name, r, names in ex.map(fault, FAULTS):
            good = bool(r) and r["verdict"] == "FAIL" and r["mismatches"] == 1 and names == [name]
            report("fault_" + name, good, "one inverted clock on %s: exactly one mismatch, on that output %s" % (name, "" if good else (r, names)))

    # RTL mutants
    def mutant(item):
        name, which, old, new, runs = item
        d = build_mutant(build, name, which, old, new, mem_srcs)
        if d is None:
            return name, "build", None
        for suite, seed, count, *rs in runs:
            r, names = run_tb(build, d, rundir, "mut_%s_%s%d" % (name, suite, seed), suite, seed, count, rseed=(rs[0] if rs else None))
            if r is None or r.get("verdict") == "FAIL":
                return name, "%s s%d" % (suite, seed), (r, sorted(set(names))[:4])
        return name, None, None

    with concurrent.futures.ThreadPoolExecutor(jobs) as ex:
        for name, how, info in ex.map(mutant, MUTANTS):
            report("mut_" + name, how not in (None, "build"), ("caught by %s: %s" % (how, info)) if how not in (None, "build") else
                   ("mutant did not build" if how == "build" else "SURVIVED"))

    print("SELFTEST " + ("PASS" if ok else "FAIL"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--rename":
        rename(sys.argv[2], sys.argv[3])
    else:
        main()
