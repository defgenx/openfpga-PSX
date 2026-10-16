#!/usr/bin/env python3
"""Prepare the frozen golden for the nvc harness: write a patched copy of spu.vhd.

usage: prep_golden.py RTLDIR OUTDIR     (writes OUTDIR/spu.vhd)

Each pattern must be found exactly once, so a change of the golden fails here. The patches change no synthesised behaviour:
  - the translate_off debug output (file R:\\debug_sound_sim.txt) is removed
  - the harness-only vector cov_flags (coverage of golden internals, read by tb_diff through external names) is added
  - integer ranges that hardware wraps (and nvc reports as errors) are widened where a run showed they are exceeded
"""
import os
import sys

# name, condition (VHDL boolean over golden signals); bit i of cov_flags
COV = [
    ("adsr_attack_tick",  "state = VOICE_APPLYADSR and voice.adsrphase = ADSRPHASE_ATTACK and voice.adsrTicks < 2"),
    ("adsr_decay_tick",   "state = VOICE_APPLYADSR and voice.adsrphase = ADSRPHASE_DECAY and voice.adsrTicks < 2"),
    ("adsr_sustain_tick", "state = VOICE_APPLYADSR and voice.adsrphase = ADSRPHASE_SUSTAIN and voice.adsrTicks < 2"),
    ("adsr_release_tick", "state = VOICE_APPLYADSR and voice.adsrphase = ADSRPHASE_RELEASE and voice.adsrTicks < 2"),
    ("adsr_exp_dec",      "state = VOICE_APPLYADSR and voice.adsrTicks < 2 and voice.adsrphase /= ADSRPHASE_OFF and voice.adsrphase <= ADSRPHASE_RELEASE and adsr_exp(to_integer(voice.adsrphase)) = '1' and adsr_dec(to_integer(voice.adsrphase)) = '1'"),
    ("adsr_exp_inc_slow", "state = VOICE_APPLYADSR and voice.adsrTicks < 2 and voice.adsrphase /= ADSRPHASE_OFF and voice.adsrphase <= ADSRPHASE_RELEASE and adsr_exp(to_integer(voice.adsrphase)) = '1' and adsr_dec(to_integer(voice.adsrphase)) = '0' and adsrVolume >= 16#6000# and adsr_rate(to_integer(voice.adsrphase)) < 40"),
    ("adsr_exp_inc_mid",  "state = VOICE_APPLYADSR and voice.adsrTicks < 2 and voice.adsrphase /= ADSRPHASE_OFF and voice.adsrphase <= ADSRPHASE_RELEASE and adsr_exp(to_integer(voice.adsrphase)) = '1' and adsr_dec(to_integer(voice.adsrphase)) = '0' and adsrVolume >= 16#6000# and adsr_rate(to_integer(voice.adsrphase)) >= 40 and adsr_rate(to_integer(voice.adsrphase)) < 44"),
    ("adsr_exp_inc_fast", "state = VOICE_APPLYADSR and voice.adsrTicks < 2 and voice.adsrphase /= ADSRPHASE_OFF and voice.adsrphase <= ADSRPHASE_RELEASE and adsr_exp(to_integer(voice.adsrphase)) = '1' and adsr_dec(to_integer(voice.adsrphase)) = '0' and adsrVolume >= 16#6000# and adsr_rate(to_integer(voice.adsrphase)) >= 44"),
    ("sw_att_dec",        "state = VOICE_APPLYVOLUME and bus_write = '0' and voice.adsrphase = ADSRPHASE_ATTACK and to_integer(adsrVolumeNew) >= 32767"),
    ("sw_dec_sus",        "state = VOICE_APPLYVOLUME and bus_write = '0' and voice.adsrphase = ADSRPHASE_DECAY and to_integer(adsrVolumeNew) <= to_integer(adsr_target(ADSR_DECAY))"),
    ("sw_rel_off",        "state = VOICE_APPLYVOLUME and bus_write = '0' and voice.adsrphase = ADSRPHASE_RELEASE and to_integer(adsrVolumeNew) <= 0"),
    ("keyon",             "state = VOICE_CHECKKEY and KEYON(index) = '1'"),
    ("keyoff",            "state = VOICE_CHECKKEY and KEYOFF(index) = '1' and voice.adsrphase /= ADSRPHASE_OFF"),
    ("loop_end_off",      "state = VOICE_CHECKEND and bus_write = '0' and voice.adpcmSamplePos(19 downto 12) >= 28 and loopEnd = '1' and loopRepeat = '0' and NOISEMODE(index) = '0'"),
    ("loop_end_repeat",   "state = VOICE_CHECKEND and bus_write = '0' and voice.adpcmSamplePos(19 downto 12) >= 28 and loopEnd = '1' and (loopRepeat = '1' or NOISEMODE(index) = '1')"),
    ("block_next",        "state = VOICE_CHECKEND and bus_write = '0' and voice.adpcmSamplePos(19 downto 12) >= 28 and loopEnd = '0'"),
    ("repeat_update",     "state = VOICE_APPLYVOLUME and bus_write = '0' and updateRepeat = '1'"),
    ("shift_clamp",       "state = VOICE_EVALHEADER and ram_done = '1' and unsigned(ram_dataRead(3 downto 0)) > 12"),
    ("filter_clamp",      "state = VOICE_EVALHEADER and ram_done = '1' and unsigned(ram_dataRead(6 downto 4)) > 4"),
    ("decode_f1",         "state = VOICE_DECODESAMPLE and adpcmFilter = 1"),
    ("decode_f2",         "state = VOICE_DECODESAMPLE and adpcmFilter = 2"),
    ("decode_f3",         "state = VOICE_DECODESAMPLE and adpcmFilter = 3"),
    ("decode_f4",         "state = VOICE_DECODESAMPLE and adpcmFilter = 4"),
    ("decode_big_shift",  "state = VOICE_DECODESAMPLE and adpcmShift >= 9"),
    ("pitch_mod",         "state = VOICE_APPLYADSR and index > 0 and PITCHMODENA(index) = '1'"),
    ("noise_voice",       "state = VOICE_PICKSAMPLE and NOISEMODE(index) = '1'"),
    ("step_clamp",        "state = VOICE_APPLYVOLUME and bus_write = '0' and step >= 16#3FFF#"),
    ("sweep_any",         "envelopeState = ENV_START and volumeSetting(15) = '1'"),
    ("sweep_exp_inc",     "envelopeState = ENV_CALC and envTicks < 2 and volumeSetting(14) = '1' and volumeSetting(13) = '0' and envVolume >= 16#6000#"),
    ("sweep_exp_dec",     "envelopeState = ENV_CALC and envTicks < 2 and volumeSetting(14) = '1' and volumeSetting(13) = '1'"),
    ("sweep_lin_dec",     "envelopeState = ENV_CALC and envTicks < 2 and volumeSetting(14) = '0' and volumeSetting(13) = '1'"),
    ("xfer_read",         "state = RAM_READ and ram_done = '1'"),
    ("xfer_write",        "state = RAM_WRITE and ram_done = '1'"),
    ("rev_read1",         "state = REVERB_READ1"),
    ("rev_write1",        "state = REVERB_WRITE1"),
    ("rev_write2",        "state = REVERB_WRITE2"),
    ("rev_read2",         "state = REVERB_READ2"),
    ("capture",           "state = CAPTURE3"),
    ("irq_saved",         "sampleticks = 767 and irqSaved = '1' and ce = '1'"),
    ("timeout",           "sampleticks = 0 and state /= IDLE and stashedSamples = 15 and ce = '1'"),
    ("stash",             "stashedSamples > 0"),
    ("mute",              "state = RAM_WAIT and index = 23 and cnt(14) = '0'"),
    ("cd_add",            "state = RAM_WAIT and index = 23 and cnt(0) = '1'"),
    ("cd_reverb",         "state = RAM_WAIT and index = 23 and cnt(0) = '1' and cnt(2) = '1'"),
    ("fifoin_full_drop",  "dma_write = '1' and FifoIn_Full = '1'"),
    ("fifoout_nearfull",  "FifoOut_NearFull = '1'"),
    ("irq_match",         "(ram_request = '1' or ram_check_irq = '1') and cnt(15) = '1' and cnt(6) = '1' and IRQ_ADDR = ram_Adr(18 downto 3) and irq9 = '0'"),
    ("irq_voice_masked",  "(ram_request = '1' or ram_check_irq = '1') and cnt(15) = '1' and cnt(6) = '1' and IRQ_ADDR = ram_Adr(18 downto 3) and irq9 = '0' and irqVoicetrigger = '0' and (state = VOICE_EVALHEADER or state = VOICE_EVALSAMPLE)"),
    ("noise_update",      "state = CAPTURE3 and noiseCnt >= noiseCheck"),
    ("reset_adsr",        "state = VOICE_EVALSAMPLE and reset_adsr = '1'"),
    ("repeat_write",      "state = VOICE_START and voice_repeatWrite(index) = '1'"),
    ("busy_stat",         "busy = '1'"),
    ("rev_on_voice",      "state = VOICE_END and REVERBON(index) = '1'"),
    ("vol_neg",           "state = VOICE_APPLYVOLUME and volume < 0"),
    ("irq_direct_off",    "irqOut = '1' and irqSaved = '0'"),
]
assert len(COV) <= 64


def once(text, old, new, name):
    assert text.count(old) == 1, "pattern not found exactly once: " + name
    return text.replace(old, new)


def cut(text, start, end, name):
    assert text.count(start) == 1, "pattern not found exactly once: " + name
    i = text.index(start)
    j = text.index(end, i) + len(end)
    return text[:i] + text[j:]


def prep(t):
    t = cut(t, "   -- synthesis translate_off\n\n   goutput : if 1 = 1 generate", "   end generate goutput;\n   \n   -- synthesis translate_on", "debug output")
    assert "debug_sound_sim" not in t
    t = once(t, "   -- debug_out\n   type outtype is record",
             "   signal cov_flags : std_logic_vector(63 downto 0) := (others => '0');\n\n   -- debug_out\n   type outtype is record", "cov decl")
    stmts = "".join("   cov_flags(%d) <= '1' when (%s) else '0';\n" % (i, c) for i, (n, c) in enumerate(COV))
    t = once(t, "begin \n\n   ififoIn: entity mem.SyncFifoFallThrough", "begin \n\n" + stmts + "\n   ififoIn: entity mem.SyncFifoFallThrough", "cov stmts")
    return t


def main():
    rtl, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    open(os.path.join(out, "spu.vhd"), "w").write(prep(open(os.path.join(rtl, "spu.vhd")).read()))
    open(os.path.join(out, "cov_names.txt"), "w").write(" ".join(n for n, _ in COV) + "\n")


if __name__ == "__main__":
    main()
