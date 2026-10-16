#!/usr/bin/env python3
"""Prepare the frozen golden for the nvc harness: write patched copies of cd_top.vhd and cd_xa.vhd.

usage: prep_golden.py RTLDIR OUTDIR     (writes OUTDIR/cd_top.vhd and OUTDIR/cd_xa.vhd)

The patches change no synthesised behaviour; each pattern must be found exactly once, so a change of the golden fails here:
  - positionInIndex gets an initial value
  - the savestate read-out assignments (ss_out(...) <= ...) are removed: the harness never reads the savestate port, and they
    cost simulation time (a negative positionInIndex is also a fatal conversion error under nvc)
  - the simulation-only override "pregap not present in simulation" is removed: the harness compares against the behaviour
    the synthesised design has (positionInIndex = lastReadSector - startLBA - PREGAPSIZE on track 1)
  - LBA registers wrap modulo 2^19 (seekLBA, readLBA, playLBA, subchannelSector), as the 19-bit registers do
  - fifoParamCount is a five-bit register: it counts modulo 32 (the simulation-only guard at 16 and the range 0 to 16 are removed)
  - phy_oldOffset takes the low five bits of the difference, as the five-bit register does (a larger difference is a range
    error under nvc)
  - the simulation-only cd_hps_lba_sim assignment (not compared; a negative offset is a conversion error under nvc)
  - the translate_off debug output (files R:\\debug_*.txt) and the simulation-only sectorBuffers array are removed
"""
import os
import re
import sys


def cut(text, start, end, name):
    assert text.count(start) == 1, "pattern not found exactly once: " + name
    i = text.index(start)
    j = text.index(end, i) + len(end)
    return text[:i] + text[j:]


def once(text, old, new, name):
    assert text.count(old) == 1, "pattern not found exactly once: " + name
    return text.replace(old, new)


def prep_top(t):
    t = once(t, "signal positionInIndex           : integer range -524288 to 524287;",
             "signal positionInIndex           : integer range -524288 to 524287 := 0;", "positionInIndex init")
    # LBA registers are 19 bits wide: the arithmetic wraps in hardware and is a range error under nvc
    t = once(t, "seekLBA <= to_integer(setLocMinute) * FRAMES_PER_MINUTE + to_integer(setLocSecond) * FRAMES_PER_SECOND + to_integer(setLocFrame);",
             "seekLBA <= (to_integer(setLocMinute) * FRAMES_PER_MINUTE + to_integer(setLocSecond) * FRAMES_PER_SECOND + to_integer(setLocFrame)) mod 524288;", "seekLBA wrap")
    t = once(t, "readLBA      <= lastReadSector + 1;", "readLBA      <= (lastReadSector + 1) mod 524288;", "readLBA + 1 wrap")
    t = once(t, "readLBA <= lastReadSector + to_integer(fastForwardRate);", "readLBA <= (lastReadSector + to_integer(fastForwardRate)) mod 524288;", "readLBA ff wrap")
    t = once(t, "                              playLBA   <= to_integer(unsigned(trackInfo_DataOutA(18 downto 0))) + PREGAPSIZE;",
             "                              playLBA   <= (to_integer(unsigned(trackInfo_DataOutA(18 downto 0))) + PREGAPSIZE) mod 524288;", "playLBA wrap")
    t = once(t, "subchannelSector <= lastReadSector +2;", "subchannelSector <= (lastReadSector + 2) mod 524288;", "subchannelSector wrap")
    t = once(t, "signal fifoParamCount            : integer range 0 to 16;", "signal fifoParamCount            : integer range 0 to 31;", "fifoParamCount range")
    old = ("            -- synthesis translate_off\n            if (fifoParamCount < 16) then\n            -- synthesis translate_on\n"
           "               fifoParamCount <= fifoParamCount + 1;\n            -- synthesis translate_off\n            end if;\n"
           "            -- synthesis translate_on\n         elsif (FifoParam_Rd = '1') then\n            fifoParamCount <= fifoParamCount - 1; ")
    t = once(t, old, "            fifoParamCount <= (fifoParamCount + 1) mod 32;\n         elsif (FifoParam_Rd = '1') then\n            fifoParamCount <= (fifoParamCount + 31) mod 32;", "fifoParamCount count")
    n0 = t.count("ss_out(")
    t = re.sub(r"   gSS\w+: for .*?end generate;\n", "", t, flags=re.S)
    t = re.sub(r"^[ \t]*ss_out\(.*\n", "", t, flags=re.M)
    assert t.count("ss_out(") == 1 and n0 > 50, "savestate read-out assignments"   # the SS_DataRead read of the array remains
    t = once(t, "phy_oldOffset <= physicalLBA - phy_base;", "phy_oldOffset <= (physicalLBA - phy_base) mod 32;", "phy_oldOffset wrap")
    t = cut(t, "-- synthesis translate_off\n                           positionInIndex <= lastReadSector - startLBA; -- pregap not present in simulation\n",
            "-- synthesis translate_on\n", "pregap override")
    t = cut(t, "                  -- synthesis translate_off\n                  cd_hps_lba_sim(23 downto 0)", "-- synthesis translate_on\n", "cd_hps_lba_sim")
    t = cut(t, "   -- debug\n   -- synthesis translate_off\n   type tsectorBuffer ", "-- synthesis translate_on", "sectorBuffers decl")
    t = cut(t, "                  -- synthesis translate_off\n                  sectorBuffers(to_integer(writeSectorPointer))(procCount)",
            "-- synthesis translate_on\n", "sectorBuffers write")
    t = cut(t, "               -- synthesis translate_off\n               if ((to_integer(SS_Adr) mod 2048) < 588) then",
            "-- synthesis translate_on\n", "sectorBuffers savestate write")
    t = cut(t, "   -- synthesis translate_off\n\n   goutput : if 1 = 1 generate", "   end generate goutputcdda;", "debug output")
    assert "sectorBuffers(" not in t, "sectorBuffers still used"
    return t


def prep_xa(t):
    return cut(t, "   -- synthesis translate_off\n\n   goutput : if 1 = 1 generate", "   end generate goutput;", "xa debug output")


def main():
    rtl, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    top = prep_top(open(os.path.join(rtl, "cd_top.vhd")).read())
    xa = prep_xa(open(os.path.join(rtl, "cd_xa.vhd")).read())
    assert "debug_" not in top and "debug_" not in xa
    open(os.path.join(out, "cd_top.vhd"), "w").write(top)
    open(os.path.join(out, "cd_xa.vhd"), "w").write(xa)


if __name__ == "__main__":
    main()
