#!/usr/bin/env python3
"""Fault-injection self-test of the spu_diff harness, and the helper that builds the "self" flavour.

usage: selftest.py --rename SRCDIR DSTDIR   write the patched golden renamed to spu_pocket (the "self" flavour)
       selftest.py BUILD RUNDIR             run the self-test (make selftest; needs the self flavour and the golden library)

Two kinds of fault, each must be reported:
  * output faults: one compared DUT output is inverted for exactly one clock (tb generics G_FAULT_SIG, G_FAULT_CYC);
    the run must report exactly one mismatch, on that output. This proves every compare path.
  * RTL mutants: one edit of the renamed golden, run against the unmodified golden; the run must FAIL. This proves that the
    stimulus reaches the behaviour.
The unmodified renamed golden must pass first (base).
"""
import concurrent.futures
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

GENERICS = "generic (NO_REVERB : boolean := true; L1_CACHE : boolean := false);"


def rename(src, dst):
    os.makedirs(dst, exist_ok=True)
    t = open(os.path.join(src, "spu.vhd")).read()
    assert t.count("entity spu is\n   port") == 1 and t.count("architecture arch of spu is") == 1
    t = t.replace("entity spu is\n   port", "entity spu_pocket is\n   " + GENERICS + "\n   port")
    t = t.replace("architecture arch of spu is", "architecture arch of spu_pocket is")
    open(os.path.join(dst, "spu_pocket.vhd"), "w").write(t)


# output faults: G_FAULT_SIG index (see tb_diff.vhd) -> the name of the compare that must fire
FAULTS = [
    (0, "sound_out_left"), (1, "sound_out_right"), (2, "bus_dataRead"), (3, "irqOut"), (4, "spu_tick"), (5, "sound_timeout"),
    (6, "spu_dmaRequest"), (7, "dma_readdata"), (8, "sdram_ena"), (9, "sdram_Adr"), (10, "sdram_rnw"), (11, "sdram_dataWrite"),
    (12, "sdram_be"), (13, "mem_request"), (14, "SS_idle"),
]

# RTL mutants of the golden copy: name, old text, new text, runs to try (suite, scenario/seed, count[, G_SEED]); the first run that fails wins
R = [("random", 1, 200), ("random", 2, 200), ("random", 3, 200), ("random", 4, 200)] + [("directed", n, 150) for n in range(7)] + [("wild", 1, 150), ("wild", 2, 150)]
D = lambda n: []
REV = [("random", 1, 200, {"extra": ["-g", "G_NO_REVERB=0"]}), ("directed", 4, 150, {"extra": ["-g", "G_NO_REVERB=0"]}), ("random", 2, 200, {"extra": ["-g", "G_NO_REVERB=0"]})]
MUTANTS = [
    ("filter_pos1",     "constant filtertablePos : tfilterArray := ( 0, 60, 115, 98, 122 );", "constant filtertablePos : tfilterArray := ( 0, 61, 115, 98, 122 );", R),
    ("filter_neg2",     "constant filtertableNeg : tfilterArray := ( 0, 0, -52, -55, -60 );", "constant filtertableNeg : tfilterArray := ( 0, 0, -52, -55, -61 );", R),
    ("shift_clamp",     "if (unsigned(ram_dataRead(3 downto 0)) > 12) then", "if (unsigned(ram_dataRead(3 downto 0)) > 13) then", R),
    ("filter_clamp",    "if (unsigned(ram_dataRead(6 downto 4)) > 4) then", "if (unsigned(ram_dataRead(6 downto 4)) > 5) then", R),
    ("pick_shift",      "sample     <= resize(shift_right(interpol1 + interpol2 + interpol3 + interpol4, 15), 16);", "sample     <= resize(shift_right(interpol1 + interpol2 + interpol3 + interpol4, 14), 16);", R),
    ("noise_taps",      "(noiseLevel(15) xor noiseLevel(12) xor noiseLevel(11) xor noiseLevel(10) xor '1')", "(noiseLevel(15) xor noiseLevel(12) xor noiseLevel(11) xor noiseLevel(9) xor '1')", R),
    ("noise_step",      "when \"01\" => noiseCnt <= noiseCnt + 84;", "when \"01\" => noiseCnt <= noiseCnt + 85;", R),
    ("adsr_mul",        "adsr_volumeCalc      := resize(shift_right(sample * adsrVolume, 15), 17);", "adsr_volumeCalc      := resize(shift_right(sample * adsrVolume, 14), 17);", R),
    ("pmon_base",       "step <= resize(shift_right(unsigned(RamVoice_dataB(1)) * unsigned(voice_lastVolume + x\"8000\"), 15), 16);", "step <= resize(shift_right(unsigned(RamVoice_dataB(1)) * unsigned(voice_lastVolume + x\"8100\"), 15), 16);", R),
    ("pmon_index0",     "if (index > 0 and PITCHMODENA(index) = '1') then", "if (index > 1 and PITCHMODENA(index) = '1') then", R),
    ("step_limit",      "if (step < 16#3FFF#) then", "if (step < 16#3000#) then", R),
    ("block_len",       "if (voice.adpcmSamplePos(19 downto 12) >= 28) then", "if (voice.adpcmSamplePos(19 downto 12) >= 29) then", R),
    ("loop_off",        "if (loopRepeat = '0' and NOISEMODE(index) = '0') then", "if (loopRepeat = '0') then", R),
    ("endx_set",        "ENDX(index)           <= '1';", "ENDX(index)           <= '0';", R),
    ("attack_target",   "adsr_target(ADSR_ATTACK ) <= (others => '1');", "adsr_target(ADSR_ATTACK ) <= (14 => '0', others => '1');", R),
    ("decay_target",    "adsr_target(ADSR_DECAY) <= (adsrSetting(3 downto 0) + 1) & \"00000000000\";", "adsr_target(ADSR_DECAY) <= (adsrSetting(3 downto 0) + 2) & \"00000000000\";", R),
    ("exp_slow_thr",    "if (adsr_rate(adsr_index) < 40) then", "if (adsr_rate(adsr_index) < 42) then", R),
    ("exp_fast_thr",    "elsif (adsr_rate(adsr_index) >= 44) then", "elsif (adsr_rate(adsr_index) >= 46) then", R),
    ("sweep_exp_thr",   "if (envVolume >= 16#6000#) then", "if (envVolume >= 16#6800#) then", R),
    ("sweep_step",      "env_step <=  shift_left(to_signed( 7, 16) - to_integer(env_rate(1 downto 0)), env_rateshift);", "env_step <=  shift_left(to_signed( 6, 16) - to_integer(env_rate(1 downto 0)), env_rateshift);", R),
    ("release_ticks",   "voice.adsrTicks <= adsr_ticks(ADSR_RELEASE);\n                     end if;\n                  end if;", "voice.adsrTicks <= adsr_ticks(ADSR_SUSTAIN);\n                     end if;\n                  end if;", R),
    ("keyon_addr",      "voice.currentAddr       <= unsigned(RamVoice_dataB(1)(15 downto 1)) & '0';\n                     voice.adsrphase         <= ADSRPHASE_ATTACK;", "voice.currentAddr       <= unsigned(RamVoice_dataB(1)(15 downto 0));\n                     voice.adsrphase         <= ADSRPHASE_ATTACK;", R),
    ("loop_addr",       "voice.currentAddr     <= unsigned(RamVoice_dataB(1)(15 downto 1)) & '0';\n                           if (loopRepeat", "voice.currentAddr     <= unsigned(RamVoice_dataB(1)(15 downto 0));\n                           if (loopRepeat", R),
    ("repeat_flag",     "if (ram_dataRead(10) = '1' and voice.adpcmDecodePtr = 0 and voice.ignoreLoopWB = '0') then", "if (ram_dataRead(10) = '1' and voice.adpcmDecodePtr = 0) then", R),
    ("mute_bit",        "if (cnt(14) = '1') then -- mute voices", "if (cnt(13) = '1') then -- mute voices", R),
    ("cd_volume",       "soundmul2 <= signed(CDAUDIO_VOL_L);", "soundmul2 <= signed(CDAUDIO_VOL_R);", R),
    ("out_clamp",       "if (soundmulresult15 < -32768) then sound_out_left <= x\"8000\";", "if (soundmulresult15 < -32768) then sound_out_left <= x\"8001\";", R),
    ("fifo_nearfull",   "if (CNT(5 downto 4) = \"11\" and FifoOut_NearFull = '0') then\n                     state           <= RAM_READ;", "if (CNT(5 downto 4) = \"11\") then\n                     state           <= RAM_READ;", R),
    ("xfer_step",       "ramTransferAddr <= ramTransferAddr + 2;\n                  elsif (FifoIn_Empty = '0') then", "ramTransferAddr <= ramTransferAddr + 4;\n                  elsif (FifoIn_Empty = '0') then", R),
    ("irq_cmp",         "(IRQ_ADDR = ram_Adr(18 downto 3)) and irq9 = '0'", "(IRQ_ADDR = ram_Adr(18 downto 3)) and irq9 = '1'", R),
    ("irq_en",          "and cnt(15) = '1' and cnt(6) = '1' and (IRQ_ADDR", "and cnt(15) = '1' and (IRQ_ADDR", R),
    ("irq_voice_mask",  "if (irqVoicetrigger = '1' or (state /= VOICE_EVALHEADER and state /= VOICE_EVALSAMPLE)) then", "if (true) then", R),
    ("irq_ack",         "if (bus_dataWrite(6) = '0') then\n                           IRQ9 <= '0';", "if (bus_dataWrite(5) = '0') then\n                           IRQ9 <= '0';", R),
    ("capture_cd",      "ram_dataWrite <= std_logic_vector(cd_left);", "ram_dataWrite <= std_logic_vector(cd_right);", R),
    ("capture_vol3",    "ram_dataWrite <= std_logic_vector(voice_lastVolume3);", "ram_dataWrite <= std_logic_vector(voice_lastVolume1);", R),
    ("envx_clear",      "KEYON(index)            <= '0';\n                     ENDX(index)             <= '0';", "KEYON(index)            <= '0';", R),
    ("stat_busy",       "STAT(10) <= busy;", "STAT(10) <= '0';", R),
    ("stat_dma",        "STAT( 8) <= '1' when (CNT(5 downto 4) = \"11\" and FifoOut_NearFull = '1') else '0';", "STAT( 8) <= '0';", R),
    ("read_ffff",       "bus_dataRead <= (others => '1');\n               if (bus_addr < 16#180#) then", "bus_dataRead <= (others => '0');\n               if (bus_addr < 16#180#) then", R),
    ("reverb_read",     "when 16#1E4# => bus_dataRead <= REVERB_mLDIFF; ", "when 16#1E4# => bus_dataRead <= REVERB_mRDIFF; ", R),
    ("mbase_write",     "when 16#1A2# => REVERB_mBASE              <= bus_dataWrite; reverbCurrentAddress <= unsigned(bus_dataWrite) & \"00\";", "when 16#1A2# => REVERB_mBASE              <= bus_dataWrite; reverbCurrentAddress <= unsigned(bus_dataWrite) & \"01\";", R),
    ("sound_off_mix",   "soundleft  <= soundleft  + resize(chanLeft , 24);", "soundleft  <= soundleft  + resize(chanRight, 24);", R),
    ("reverb_addr",     "REVERB_dDIFF  <= unsigned(REVERB_dRDIFF ) when (reverbRight = '0') else unsigned(REVERB_dLDIFF );", "REVERB_dDIFF  <= unsigned(REVERB_dLDIFF ) when (reverbRight = '0') else unsigned(REVERB_dRDIFF );", REV),
    ("timeout_limit",   "if (stashedSamples < 15) then", "if (stashedSamples < 14) then", [("random", 1, 150, {"extra": ["-g", "G_LATMIN=11", "-g", "G_LATMAX=12"]}), ("wild", 1, 200, {"extra": ["-g", "G_LATMIN=11", "-g", "G_LATMAX=12"]})]),
    ("dma_fifo_drop",   "if (FifoIn_Full = '0') then\n               FifoIn_Wr  <= '1';\n               FifoIn_Din <= dma_writedata;", "if (true) then\n               FifoIn_Wr  <= '1';\n               FifoIn_Din <= dma_writedata;", R),
]


def sh(cmd, cwd=None, log=None):
    p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if log:
        open(log, "w").write(p.stdout)
    return p


def build_mutant(build, name, old, new, mem_srcs):
    """Analyse the renamed golden with one edit into build/mut_<name>/{dut,work}."""
    d = os.path.join(build, "mut_" + name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    text = open(os.path.join(build, "selfsrc", "spu_pocket.vhd")).read()
    assert text.count(old) == 1, "mutant %s: pattern found %d times" % (name, text.count(old))
    open(os.path.join(d, "spu_pocket.vhd"), "w").write(text.replace(old, new))
    nvc = ["nvc", "--std=2008", "--ieee-warnings=off", "-H", "256m"]
    rtl = os.path.join(HERE, "..", "..", "rtl")
    tb = [os.path.join(HERE, "..", "common", "trace_cmp_pkg.vhd"), os.path.join(HERE, "spu_diff_pkg.vhd"),
          os.path.join(HERE, "spu_ram_model.vhd"), os.path.join(HERE, "tb_diff.vhd")]
    for cmd in (nvc + ["--work=dut:" + os.path.join(d, "dut"), "-L", build, "-a", "--relaxed"] + mem_srcs,
                nvc + ["--work=dut:" + os.path.join(d, "dut"), "-L", build, "-a", os.path.join(rtl, "spu_ram.vhd"),
                       os.path.join(rtl, "spu_gauss.vhd"), os.path.join(d, "spu_pocket.vhd")],
                nvc + ["--work=work:" + os.path.join(d, "work"), "-L", os.path.join(build, "gold"), "-L", d, "-L", build, "-a"] + tb):
        p = sh(cmd, log=os.path.join(d, "build.log"))
        if p.returncode != 0:
            return None
    return d


def run_tb(build, libdir, rundir, name, suite, scen, count, extra=(), seed=None):
    """Run tb_diff of the flavour in LIBDIR (holds dut/ and work/); returns (RESULT fields dict or None, MISMATCH names)."""
    d = os.path.join(rundir, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    nvc = ["nvc", "--std=2008", "--ieee-warnings=off", "-H", "256m", "--work=work:" + os.path.join(libdir, "work"),
           "-L", os.path.join(build, "gold"), "-L", libdir, "-L", build, "-e", "--no-save",
           "-g", "G_SUITE=" + suite, "-g", "G_SCEN=%d" % scen, "-g", "G_SEED=%d" % (scen if seed is None else seed), "-g", "G_COUNT=%d" % count] + list(extra) + ["tb_diff", "-r"]
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

    res, _ = run_tb(build, selfdir, rundir, "base", "random", 1, 60)
    report("base", bool(res) and res["verdict"] == "PASS" and res["mismatches"] == 0,
           "renamed golden against the golden: 0 mismatches %s" % (res or "no result"))

    def fault(item):
        sig, name = item
        r, names = run_tb(build, selfdir, rundir, "fault_" + name, "random", 1, 80, ["-g", "G_FAULT_SIG=%d" % sig, "-g", "G_FAULT_CYC=40000"])
        return name, r, names

    only_f = os.environ.get("SELFTEST_ONLY")
    with concurrent.futures.ThreadPoolExecutor(jobs) as ex:
        for name, r, names in ex.map(fault, [] if only_f else FAULTS):
            good = bool(r) and r["verdict"] == "FAIL" and r["mismatches"] == 1 and names == [name]
            report("fault_" + name, good, "one inverted clock on %s: exactly one mismatch, on that output %s" % (name, "" if good else (r, names)))

    def mutant(item):
        name, old, new, runs = item
        d = build_mutant(build, name, old, new, mem_srcs)
        if d is None:
            return name, "build", None
        for suite, scen, count, *rs in runs:
            o = rs[0] if rs else {}
            r, names = run_tb(build, d, rundir, "mut_%s_%s%d" % (name, suite, scen), suite, scen, count, extra=o.get("extra", ()), seed=o.get("seed"))
            if r is None or r.get("verdict") == "FAIL":
                return name, "%s s%d" % (suite, scen), (r, sorted(set(names))[:4])
        return name, None, None

    n_caught = 0
    only = [x for x in os.environ.get("SELFTEST_ONLY", "").split(",") if x]
    todo = [m for m in MUTANTS if not only or m[0] in only]
    with concurrent.futures.ThreadPoolExecutor(jobs) as ex:
        for name, how, info in ex.map(mutant, todo):
            caught = how not in (None, "build")
            n_caught += caught
            report("mut_" + name, caught, ("caught by %s: %s" % (how, info)) if caught else
                   ("mutant did not build" if how == "build" else "SURVIVED"))

    print("MUTANTS caught %d of %d" % (n_caught, len(todo)))
    print("SELFTEST " + ("PASS" if ok else "FAIL"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--rename":
        rename(sys.argv[2], sys.argv[3])
    else:
        main()
