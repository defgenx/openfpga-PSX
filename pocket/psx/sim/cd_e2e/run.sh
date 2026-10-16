#!/usr/bin/env bash
# End-to-end CD path (nvc): cd_pocket + cd_loader against an APF host model, driven through the 0x1F801800-3 registers.
#   sim/cd_e2e/run.sh       makes a synthetic disc with tools/cue2pocket.py under sim/out/cd_e2e/, runs the bench; passes on a PASS line
# docs/pocket/POCKET_TOP.md, "CD loader".
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
P=$(cd "$HERE/../.." && pwd)               # pocket/psx
R=$(cd "$P/../.." && pwd)                  # repository root
OUT=$P/sim/out/cd_e2e
NVC="nvc --std=2008 -H 512m"

rm -rf "$OUT"; mkdir -p "$OUT"
cd "$OUT"
python3 "$HERE/gen_disc.py" "$OUT/disc" >/dev/null
MEMS="$R/sim/system/src/mem/dpram.vhd $R/sim/system/src/mem/RamMLAB.vhd $R/sim/system/src/mem/SyncFifo.vhd $R/rtl/SyncFifoFallThrough.vhd $R/rtl/SyncFifoFallThroughMLAB.vhd"
$NVC --work=mem:$OUT/mem -a --relaxed $MEMS 2>/dev/null
$NVC --work=work:$OUT/work -L $OUT -a --relaxed $MEMS
$NVC --work=work:$OUT/work -L $OUT -a "$R/rtl/cd_xa_zigzag.vhd" "$R/rtl/cd_pocket_fifo.vhd" "$R/rtl/cd_pocket_xa.vhd" "$R/rtl/cd_pocket.vhd"
$NVC --work=work:$OUT/work -L $OUT -a "$P/fpga/core/cd_loader.v" "$HERE/tb_cd_e2e.vhd"
$NVC --work=work:$OUT/work -L $OUT -e tb_cd_e2e -gBIN_FILE="$OUT/disc/disc.bin" -gTRK_FILE="$OUT/disc/disc.trk" -gEXP_FILE="$OUT/disc/expect.txt" -gTRK2_FILE="$OUT/disc/disc2.trk" -gEXP2_FILE="$OUT/disc/expect2.txt"
$NVC --work=work:$OUT/work -L $OUT -r --ieee-warnings=off tb_cd_e2e 2>&1 | tee "$OUT/run.log" | grep -E "Note|Error|Fatal|Failure|PASS|FAIL" || true
grep -q "Note: .*: PASS" "$OUT/run.log" && ! grep -q "Error:" "$OUT/run.log"
