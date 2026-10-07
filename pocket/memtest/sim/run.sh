#!/usr/bin/env bash
# Whole-core simulation (Icarus Verilog). Usage: sim/run.sh [fast|sync|late|full|fullsync]
# late: scan-out line period shortened below what one line needs, the late-line counter must fire
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
  *) echo "usage: $0 [fast|sync|late|full|fullsync]" >&2; exit 1 ;;
esac
mkdir -p sim/out
iverilog -g2012 -o sim/out/core_$mode.vvp -I fpga/core $defs -DMAXC=${MAXC:-60000000} \
  sim/tb_core.v sim/sdram_model.v sim/psram_model.v sim/sram_model.v \
  fpga/core/{memtest_core,res_ram,sdram_ctl,sdram_arb,sd_traffic,sd_scan,psram32,ps_traffic,sram_test,dma_eng,div32}.v
vvp sim/out/core_$mode.vvp
