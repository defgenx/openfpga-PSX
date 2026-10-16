#!/usr/bin/env bash
# System simulation of the first-light build (nvc): the real core, the shell's adapters and video, behavioural memories,
# booting a BIOS. Frames land in sim/system/out/frame_<n>.ppm.
#   sim/system/run.sh [BIOS file] [ms]     default: the bundled OpenBIOS, 100 ms of emulated time
# Analysis recipe as sim/none_smoke/run.sh (altera_mf stub, mem library, the two to_unsigned patches). docs/pocket/POCKET_TOP.md.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
P=$(cd "$HERE/../.." && pwd)               # pocket/psx
R=$(cd "$P/../.." && pwd)                  # repository root
OUT=$HERE/out
BIOS=$(cd "$(dirname "${1:-$P/dist/Assets/psx/defgenx.PSX/psxbios.bin}")" && pwd)/$(basename "${1:-psxbios.bin}")
MS=${2:-100}
NVC="nvc --std=2008 -H 2g"

mkdir -p "$OUT"
cd "$OUT"
python3 "$HERE/gen_tb.py" >/dev/null
$NVC --work=altera_mf:$OUT/altera_mf -a "$R/sim/common/altera_mf_stub.vhd"
MEMS="$R/sim/system/src/mem/dpram.vhd $R/sim/system/src/mem/RamMLAB.vhd $R/sim/system/src/mem/SyncFifo.vhd $R/rtl/SyncFifoFallThrough.vhd $R/rtl/SyncFifoFallThroughMLAB.vhd"
$NVC --work=mem:$OUT/mem -a --relaxed $MEMS 2>/dev/null
sed 's/to_unsigned(positionInIndex, 20)/to_unsigned(abs(positionInIndex), 20)/' "$R/rtl/cd_top.vhd" > cd_top_sim.vhd
sed -E '400,700s/to_unsigned\((.*), 9\)/to_unsigned(abs(\1), 9)/' "$R/rtl/gpu_videoout_async.vhd" > gpu_videoout_async_sim.vhd
FILES=$(sed -n '/VHDL_FILE/p' "$R/sizing/psx_pocket_a6.qsf" | sed 's#.*\.\./rtl/##; /^set_global/d' | grep -v 'SyncFifo\|dpram.vhd\|RamMLAB' | sed "s#^#$R/rtl/#; s#$R/rtl/cd_top.vhd#$OUT/cd_top_sim.vhd#; s#$R/rtl/gpu_videoout_async.vhd#$OUT/gpu_videoout_async_sim.vhd#")
$NVC --work=work:$OUT/work -L $OUT -a --relaxed $MEMS "$R/rtl/spu_none.vhd" "$R/rtl/cd_none.vhd" $FILES \
	"$R/rtl/cd_pocket_fifo.vhd" "$R/rtl/cd_pocket_xa.vhd" "$R/rtl/cd_pocket.vhd" \
	"$R/rtl/spu_pocket_gauss.vhd" "$R/rtl/spu_pocket_sdp.vhd" "$R/rtl/spu_pocket_fifo.vhd" "$R/rtl/spu_pocket_ram.vhd" "$R/rtl/spu_pocket.vhd" \
	"$R/rtl/divider_pocket.vhd" "$R/rtl/cpu_pocket.vhd" "$R/rtl/dma_pocket.vhd" \
	"$P/fpga/core/psx_top_pocket_flat.vhd" 2>&1 | { grep -A5 "Error:" || true; }
$NVC --work=work:$OUT/work -L $OUT -a --relaxed "$P/fpga/core/async_fifo.v" "$P/fpga/core/vram_adapter.v" \
	"$P/fpga/core/ram_adapter.v" "$P/fpga/core/video_fl.v" "$P/fpga/core/spu_adapter.v" "$P/fpga/core/psx_sdram_arb.v"
$NVC --work=work:$OUT/work -L $OUT -a "$HERE/models.vhd" "$HERE/tb_system.vhd"
$NVC --work=work:$OUT/work -L $OUT -e tb_system -gBIOS_FILE="$BIOS" -gRUN_MS="$MS"
$NVC --work=work:$OUT/work -L $OUT -r --ieee-warnings=off tb_system 2>&1 | tee "$OUT/run.log" | grep -E "ms:|frame|released|FINISH|Error|Fatal|preloaded" || true
grep -q FINISH "$OUT/run.log"
