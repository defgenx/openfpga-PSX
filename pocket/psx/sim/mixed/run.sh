#!/usr/bin/env bash
# Mixed-language spike: the real psx_top_pocket (VHDL) beside the shell's Verilog modules, simulated by nvc.
#   sim/mixed/run.sh          analyse, elaborate and run tb_mixed; passes when the testbench prints PASS
#   sim/mixed/run.sh probe    show which instantiation directions nvc supports (tiny designs in probe/)
# Result and the structure it implies: docs/pocket/POCKET_TOP.md, "Shell skeleton".
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
P=$(cd "$HERE/../../.." && pwd)            # pocket/
R=$(cd "$P/.." && pwd)                     # repository root
OUT=$HERE/../out/mixed
NVC="nvc --std=2008 -H 512m"

if [ "${1:-}" = probe ]; then
	mkdir -p "$OUT/probe"; cd "$HERE/probe"
	W="--work=work:$OUT/probe/work"
	echo "VHDL top instantiating Verilog and VHDL leaves:"
	$NVC $W -a vh.vhd v.v tb_vhdl_top.vhd && $NVC $W -e tb_vhdl_top && $NVC $W -r tb_vhdl_top 2>&1 | grep -E "PASS|Error|Fatal" || true
	echo "Verilog top instantiating a VHDL entity:"
	$NVC $W -a vh.vhd v.v vtop.v && $NVC $W -e vtop 2>&1 | grep -E "Error|Fatal" || true
	echo "VHDL top instantiating a Verilog module with an inout port:"
	$NVC $W -a vio.v tb_inout.vhd && $NVC $W -e tb_inout 2>&1 | grep -E "Error|Fatal" || true
	exit 0
fi

mkdir -p "$OUT"
cd "$OUT"
# library altera_mf (behavioural altsyncram) and library mem, as sim/common/nvc.mk builds them
$NVC --work=altera_mf:$OUT/altera_mf -a "$R/sim/common/altera_mf_stub.vhd"
MEMS="$R/sim/system/src/mem/dpram.vhd $R/sim/system/src/mem/RamMLAB.vhd $R/sim/system/src/mem/SyncFifo.vhd $R/rtl/SyncFifoFallThrough.vhd $R/rtl/SyncFifoFallThroughMLAB.vhd"
$NVC --work=mem:$OUT/mem -a --relaxed $MEMS 2>/dev/null
# golden cd_top declares positionInIndex with a negative left bound; to_unsigned of that default aborts nvc at time 0
sed 's/to_unsigned(positionInIndex, 20)/to_unsigned(abs(positionInIndex), 20)/' "$R/rtl/cd_top.vhd" > cd_top_sim.vhd
FILES=$(sed -n '/VHDL_FILE/p' "$R/sizing/psx_pocket_a6.qsf" | sed 's#.*\.\./rtl/##; /^set_global/d' | grep -v 'SyncFifo\|dpram.vhd\|RamMLAB' | sed "s#^#$R/rtl/#; s#$R/rtl/cd_top.vhd#$OUT/cd_top_sim.vhd#")
$NVC --work=work:$OUT/work -L $OUT -a --relaxed $MEMS $FILES "$P/psx/fpga/core/psx_top_pocket_flat.vhd" 2>/dev/null
# the stub and the flat wrapper share one name; rename the stub copy so both live in one library
sed 's/^module psx_top_pocket_flat /module psx_top_stub_sim /' "$P/psx/fpga/core/psx_top_stub.v" > psx_top_stub_sim.v
$NVC --work=work:$OUT/work -L $OUT -a --relaxed -D SDRAM_135=1 -I "$P/common/mem" \
	"$OUT/psx_top_stub_sim.v" "$P/psx/fpga/core/mem_glue_placeholder.v" "$P/common/mem/sdram_arb.v" "$P/common/mem/sdram_ctl.v" "$P/common/mem/sdram_cal.v" "$HERE/pll_dps_nvc.v" \
	"$HERE/sdram_simple.v" "$HERE/sdram_bench.v" "$HERE/tb_mixed.vhd"
$NVC --work=work:$OUT/work -L $OUT -e tb_mixed
$NVC --work=work:$OUT/work -L $OUT -r --ieee-warnings=off tb_mixed 2>&1 | tee "$OUT/run.log" | grep -v 'metavalue\|^ *Function\|^ *Port conversion\|^ *Process\|^ *Procedure\|^$'
grep -q 'PASS' "$OUT/run.log"
