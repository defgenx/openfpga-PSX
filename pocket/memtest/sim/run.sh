#!/usr/bin/env bash
# Whole-core simulation (Icarus Verilog). Usage: [EXTRA="-D…"] sim/run.sh [fast|sync|late|full|fullsync|sd135|be|slot]
# Exits non-zero unless the testbench prints PASS (vvp itself exits 0 either way).
# late:  scan-out line period shortened below what one line needs, the late-line counter must fire
# sd135: the 135.4752 MHz variant (SDRAM_135): full-size SDRAM and scan-out tests, reduced PSRAM/SRAM/DMA
# slot:  the APF bridge throughput bench against a host model (default clock, no file, short reads, 135 variant, trailing
#        words, timeout, error code, wrong addresses; each also runs
#        the whole core test of `fast`)
# be:    tb_be, random byte-enable masks against the SDRAM model with a shadow memory, at both clocks
#        (be101, be135 run one clock; be runs both, then once more with an injected DQM fault that must be caught)
set -euo pipefail
cd "$(dirname "$0")/.."
mode=${1:-fast}
defs=""
case "$mode" in
  fast) ;;
  sync) defs="-DSYNC" ;;
  late) defs="-DLATE" ;;
  full) defs="-DFULL" ;;
  fullsync) defs="-DFULL -DSYNC" ;;
  sd135) defs="-DSDRAM_135 -DSDFULL" ;;
  be|be101|be135) ;;
  slot) ;;
  *) echo "usage: $0 [fast|sync|late|full|fullsync|sd135|be|be101|be135|slot]" >&2; exit 1 ;;
esac
mkdir -p sim/out

# one tb_be run: name, defines, expected verdict (PASS, or FAULT = the injected fault must be reported as caught)
be_run() {
  local name=$1 d=$2 want=$3
  iverilog -g2012 -o sim/out/$name.vvp -I fpga/core $d sim/tb_be.v sim/sdram_model.v fpga/core/sdram_ctl.v
  # the injected-fault run reports every violation it provokes; keep the log to the summary lines
  vvp sim/out/$name.vvp | { if [ "$want" = PASS ]; then cat; else grep -v VIOLATION; fi; } | tee sim/out/$name.log
  if [ "$want" = PASS ]; then grep -qx PASS sim/out/$name.log; else grep -qx "PASS (fault caught)" sim/out/$name.log; fi
}

case "$mode" in
  be101) be_run be101 "" PASS; exit 0 ;;
  be135) be_run be135 "-DSDRAM_135" PASS; exit 0 ;;
  be)
    be_run be101 "" PASS
    be_run be135 "-DSDRAM_135" PASS
    be_run be135_fault "-DSDRAM_135 -DBE_FAULT" FAULT
    exit 0 ;;
esac

# one whole-core run: name, defines
core_run() {
  local name=$1 d=$2
  iverilog -g2012 -o sim/out/core_$name.vvp -I fpga/core $d ${EXTRA:-} -DMAXC=${MAXC:-60000000} \
    sim/tb_core.v sim/sdram_model.v sim/psram_model.v sim/sram_model.v \
    fpga/core/{memtest_core,res_ram,sdram_ctl,sdram_arb,sd_traffic,sd_scan,psram32,ps_traffic,sram_test,dma_eng,div32,slot_bench}.v
  vvp sim/out/core_$name.vvp | tee sim/out/core_$name.log
  grep -qx PASS sim/out/core_$name.log
}

if [ "$mode" = slot ]; then
  core_run slot "-DSLOT"
  core_run slot_nofile "-DSLOT -DSLOT_NOFILE"
  core_run slot_short "-DSLOT -DSLOT_SHORT"
  core_run slot135 "-DSLOT -DSDRAM_135"
  core_run slot_trail "-DSLOT -DSLOT_TRAIL"
  core_run slot_tmo "-DSLOT -DSLOT_TMO"
  core_run slot_err "-DSLOT -DSLOT_ERR"
  core_run slot_addr "-DSLOT -DSLOT_ADDR"
  exit 0
fi
core_run $mode "$defs"
