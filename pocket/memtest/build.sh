#!/usr/bin/env bash
# Build the PSX memory test core with Quartus Lite (native or in Docker) and lay it out for the SD card.
#   pocket/memtest/build.sh            compile + package
#   pocket/memtest/build.sh compile    compile only (3-8 minutes under x86 emulation on an Apple-silicon Mac)
#   pocket/memtest/build.sh package    package an existing fpga/output_files/ap_core.rbf
#   pocket/memtest/build.sh sim        run the simulations (Icarus Verilog)
set -euo pipefail
cd "$(dirname "$0")"

QUARTUS_IMAGE=${QUARTUS_IMAGE:-raetro/quartus:21.1}
CORE=defgenx.PSXMemTest

# the generated SDRAM timing files must match tools/sdram_timing.py's table (MEMTEST.md, SDRAM timing table)
timing_check() {
	python3 tools/sdram_timing.py --check
}

compile() {
	timing_check
	if command -v quartus_sh >/dev/null; then
		(cd fpga && quartus_sh --flow compile ap_core)
	else
		# mount the repository root, as the other Pocket builds do
		docker run --rm --platform linux/amd64 --name psxmemtest-build -v "$PWD/../..":/build \
			-w /build/pocket/memtest/fpga "$QUARTUS_IMAGE" quartus_sh --flow compile ap_core
	fi
}

package() {
	local rbf=fpga/output_files/ap_core.rbf
	[ -f "$rbf" ] || { echo "missing $rbf - compile first" >&2; exit 1; }
	python3 tools/reverse_bits.py "$rbf" "dist/Cores/$CORE/memtest.rbf_r"
	# the Pocket refuses the whole core if any definition file breaks an APF limit
	python3 tools/check_json.py
	rm -rf release && mkdir -p release
	cp -R dist/Cores dist/Platforms dist/Assets release/
	find release -name .keep -delete
	(cd release && zip -qr "../$CORE.zip" .)
	echo "packaged $CORE.zip - unzip it onto the root of the Pocket SD card"
}

# vvp exits 0 whatever the result: a testbench passes only if it prints PASS on a line of its own
vvp_pass() {
	local log=sim/out/$(basename "$1" .vvp).log
	vvp "$1" | grep -v '^|' | tee "$log"
	grep -qx PASS "$log"
}

simulate() {
	timing_check
	python3 tools/gen_font.py
	python3 tools/gen_screen.py
	sim/run.sh fast
	sim/run.sh sync
	sim/run.sh late
	# 180NS gate and address walk; each run asserts its expected gate value (MEMTEST.md, Verification)
	EXTRA="-DPS_TAA=110 -DPS_GATE_PASS" sim/run.sh fast
	EXTRA="-DPS_TAA=120" sim/run.sh fast
	EXTRA="-DPS_STUCK_BIT=16" sim/run.sh fast
	EXTRA="-DPS_STUCK_BIT=18" sim/run.sh fast
	EXTRA="-DPS_BRIDGE_BIT=16" sim/run.sh fast
	iverilog -g2012 -o sim/out/div.vvp sim/tb_div.v fpga/core/div32.v
	vvp_pass sim/out/div.vvp
	iverilog -g2012 -o sim/out/screen.vvp -I fpga/core sim/tb_screen.v fpga/core/{res_ram,report_fmt,video_text}.v
	vvp_pass sim/out/screen.vvp
}

case "${1:-all}" in
	all) compile; package ;;
	compile) compile ;;
	package) package ;;
	sim) simulate ;;
	*) echo "usage: $0 [all|compile|package|sim]" >&2; exit 1 ;;
esac
