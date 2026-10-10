#!/usr/bin/env bash
# Build the PSX memory test core with Quartus Lite (native or in Docker) and lay it out for the SD card.
#   pocket/memtest/build.sh              compile both variants + package the release variant
#   pocket/memtest/build.sh compile      compile the 101.6064 MHz variant (revision ap_core), 3-8 minutes under x86 emulation
#   pocket/memtest/build.sh compile135   compile the 135.4752 MHz variant (revision ap_core_135, macro SDRAM_135)
#   pocket/memtest/build.sh package [101|135]   package an existing fpga/output_files/<revision>.rbf (default: $RELEASE);
#                                        refuses if its .sta.summary is missing or has a negative slack, unless ALLOW_TIMING_FAIL=1
#   pocket/memtest/build.sh timing [101|135]    print the worst slack per clock and model of a finished compile
#   pocket/memtest/build.sh sim          run the simulations (Icarus Verilog)
# Variants and the release choice: docs/pocket/MEMTEST.md, "Build".
set -euo pipefail
cd "$(dirname "$0")"

QUARTUS_IMAGE=${QUARTUS_IMAGE:-raetro/quartus:21.1}
CORE=defgenx.PSXMemTest
RELEASE=${RELEASE:-135}      # the variant `package` ships when none is named

# the generated SDRAM timing files must match common/tools/sdram_timing.py's table (MEMTEST.md, SDRAM timing table)
timing_check() {
	python3 ../common/tools/sdram_timing.py --check
}

# revision of a variant: 101 = ap_core, 135 = ap_core_135 (ap_core plus VERILOG_MACRO SDRAM_135=1)
revision() {
	case "${1:-$RELEASE}" in
		101) echo ap_core ;;
		135) echo ap_core_135 ;;
		*) echo "unknown variant '$1' (101 or 135)" >&2; exit 1 ;;
	esac
}

compile() {
	local rev; rev=$(revision "$1")
	timing_check
	if command -v quartus_sh >/dev/null; then
		(cd fpga && quartus_sh --flow compile ap_core -c "$rev")
	else
		# mount the repository root, as the other Pocket builds do
		docker run --rm --platform linux/amd64 --name "memtest_$rev" -v "$PWD/../..":/build \
			-w /build/pocket/memtest/fpga "$QUARTUS_IMAGE" quartus_sh --flow compile ap_core -c "$rev"
	fi
}

# "slack<TAB>clock and model" per entry of the analyser's summary, worst first
slacks() {
	local f=fpga/output_files/$(revision "$1").sta.summary
	[ -f "$f" ] || { echo "missing $f - compile first" >&2; exit 1; }
	awk '/^Type/ {t=$0; sub(/^Type  : /,"",t)} /^Slack/ {print $3 "\t" t}' "$f" | sort -n
}

# worst slack per clock and model, from the analyser's summary
timing() {
	slacks "$1" | head -${LINES_SHOWN:-40}
}

# refuse a variant whose timing summary is missing or has a negative slack (ALLOW_TIMING_FAIL=1 overrides)
timing_gate() {
	local rev; rev=$(revision "$1")
	local worst
	if ! worst=$(slacks "$1" 2>&1 | head -1) || [ -z "$worst" ] || [[ $worst == missing* ]]; then
		echo "no timing summary for $rev: ${worst:-empty fpga/output_files/$rev.sta.summary}" >&2
		[ "${ALLOW_TIMING_FAIL:-}" = 1 ] || { echo "refusing to package; ALLOW_TIMING_FAIL=1 overrides" >&2; exit 1; }
		return
	fi
	if awk -F'\t' '{exit !($1 < 0)}' <<<"$worst"; then
		echo "$rev fails timing, worst slack ${worst%%$'\t'*} ns (${worst#*$'\t'})" >&2
		[ "${ALLOW_TIMING_FAIL:-}" = 1 ] || { echo "refusing to package; ALLOW_TIMING_FAIL=1 overrides" >&2; exit 1; }
		echo "ALLOW_TIMING_FAIL=1: packaging with a failing timing summary" >&2
	else
		echo "$rev timing met, worst slack ${worst%%$'\t'*} ns (${worst#*$'\t'})"
	fi
}

package() {
	local rev; rev=$(revision "$1")
	local rbf=fpga/output_files/$rev.rbf
	[ -f "$rbf" ] || { echo "missing $rbf - compile first" >&2; exit 1; }
	timing_gate "$1"
	python3 tools/reverse_bits.py "$rbf" "dist/Cores/$CORE/memtest.rbf_r"
	# the Pocket refuses the whole core if any definition file breaks an APF limit
	python3 tools/check_json.py
	rm -rf release && mkdir -p release
	cp -R dist/Cores dist/Platforms dist/Assets release/
	find release -name .keep -delete
	(cd release && zip -qr "../$CORE.zip" .)
	echo "packaged $CORE.zip ($rev) - unzip it onto the root of the Pocket SD card"
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
	# 135.4752 MHz variant: full-size SDRAM and scan-out tests with the datasheet model (MEMTEST.md, Verification)
	sim/run.sh sd135
	# random byte-enable masks against the model with a shadow memory, both clocks, plus an injected fault that must be caught
	sim/run.sh be
	# calibrated read capture: boot sweep, tracking under drift, both clamps, lost eye, resets, PLL timeout, no step with a read in flight, injected fault
	sim/run.sh cal
	# the same whole-core run with a tracking window every raster frame: the probes must not disturb any test (MEMTEST.md, Calibration contract)
	EXTRA="-DCAL_FRAMES=1" sim/run.sh sd135
	# APF bridge throughput bench against a host model: normal, no file, short reads, 135 variant (MEMTEST.md, Bridge throughput bench)
	sim/run.sh slot
	iverilog -g2012 -o sim/out/div.vvp sim/tb_div.v fpga/core/div32.v
	vvp_pass sim/out/div.vvp
	iverilog -g2012 -o sim/out/screen.vvp -I fpga/core -I ../common/mem sim/tb_screen.v fpga/core/{res_ram,report_fmt,video_text}.v
	vvp_pass sim/out/screen.vvp
	iverilog -g2012 -o sim/out/screen135.vvp -DSDRAM_135 -I fpga/core -I ../common/mem sim/tb_screen.v fpga/core/{res_ram,report_fmt,video_text}.v
	vvp_pass sim/out/screen135.vvp
}

case "${1:-all}" in
	all) compile 101; compile 135; package ;;
	compile) compile 101 ;;
	compile135) compile 135 ;;
	package) package "${2:-}" ;;
	timing) timing "${2:-}" ;;
	sim) simulate ;;
	*) echo "usage: $0 [all|compile|compile135|package [101|135]|timing [101|135]|sim]" >&2; exit 1 ;;
esac
