#!/usr/bin/env bash
# Smoke test for G_SPU_IMPL/G_CD_IMPL = "none" (nvc).
#   sim/none_smoke/run.sh            analyse the core, run none/none and golden/golden, then the spu_none unit test
#   sim/none_smoke/run.sh smoke      only the two elaboration/run smoke tests
#   sim/none_smoke/run.sh unit       only the spu_none/cd_none/dma unit test
# Analysis recipe follows pocket/psx/sim/mixed/run.sh (altera_mf stub, mem library, qsf file list, cd_top patch).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$HERE/../.." && pwd)
OUT=$HERE/out
NVC="nvc --std=2008 -H 512m"
MODE=${1:-all}

mkdir -p "$OUT"
cd "$OUT"
$NVC --work=altera_mf:$OUT/altera_mf -a "$R/sim/common/altera_mf_stub.vhd"
MEMS="$R/sim/system/src/mem/dpram.vhd $R/sim/system/src/mem/RamMLAB.vhd $R/sim/system/src/mem/SyncFifo.vhd $R/rtl/SyncFifoFallThrough.vhd $R/rtl/SyncFifoFallThroughMLAB.vhd"
$NVC --work=mem:$OUT/mem -a --relaxed $MEMS 2>/dev/null
# golden cd_top declares positionInIndex with a negative left bound; to_unsigned of that default aborts nvc at time 0
sed 's/to_unsigned(positionInIndex, 20)/to_unsigned(abs(positionInIndex), 20)/' "$R/rtl/cd_top.vhd" > cd_top_sim.vhd
# before the display range is programmed the line arithmetic goes negative; to_unsigned of that aborts nvc
sed -E '400,700s/to_unsigned\((.*), 9\)/to_unsigned(abs(\1), 9)/' "$R/rtl/gpu_videoout_async.vhd" > gpu_videoout_async_sim.vhd
FILES=$(sed -n '/VHDL_FILE/p' "$R/sizing/psx_pocket_a6.qsf" | sed 's#.*\.\./rtl/##; /^set_global/d' | grep -v 'SyncFifo\|dpram.vhd\|RamMLAB' | sed "s#^#$R/rtl/#; s#$R/rtl/cd_top.vhd#$OUT/cd_top_sim.vhd#; s#$R/rtl/gpu_videoout_async.vhd#$OUT/gpu_videoout_async_sim.vhd#")
$NVC --work=work:$OUT/work -L $OUT -a --relaxed $MEMS "$R/rtl/spu_none.vhd" "$R/rtl/cd_none.vhd" $FILES \
	"$R/sizing/psx_pocket_wrap.vhd" "$HERE/tb_none_smoke.vhd" "$HERE/tb_none_units.vhd" 2>&1 | { grep -A5 "Error:" || true; }

if [ "$MODE" != unit ]; then
	echo "== none/none, NO_MDEC"
	$NVC --work=work:$OUT/work -L $OUT -e tb_none_smoke -gG_SPU_IMPL=none -gG_CD_IMPL=none -gG_NO_MDEC=true
	$NVC --work=work:$OUT/work -L $OUT -r --ieee-warnings=off tb_none_smoke 2>&1 | tee run_none.log | grep -v 'metavalue\|^ *Function\|^ *Port conversion\|^ *Process\|^ *Procedure\|^$'
	grep -q 'PASS none_smoke spu=none cd=none' run_none.log
	echo "== golden/golden, NO_MDEC"
	$NVC --work=work:$OUT/work -L $OUT -e tb_none_smoke -gG_SPU_IMPL=golden -gG_CD_IMPL=golden -gG_NO_MDEC=true
	$NVC --work=work:$OUT/work -L $OUT -r --ieee-warnings=off tb_none_smoke 2>&1 | tee run_golden.log | grep -v 'metavalue\|^ *Function\|^ *Port conversion\|^ *Process\|^ *Procedure\|^$'
	grep -q 'PASS none_smoke spu=golden cd=golden' run_golden.log
fi
if [ "$MODE" != smoke ]; then
	echo "== unit tests"
	$NVC --work=work:$OUT/work -L $OUT -e tb_none_units
	$NVC --work=work:$OUT/work -L $OUT -r --ieee-warnings=off tb_none_units 2>&1 | tee run_units.log | grep -v 'metavalue\|^$'
	grep -q 'PASS none_units' run_units.log
fi
