#!/usr/bin/env bash
# Build the PSX Pocket shell with Quartus Lite (native or in Docker) and lay it out for the SD card.
#   pocket/psx/build.sh                  compile + package
#   pocket/psx/build.sh compile          compile revision ap_core (135.4752 MHz SDRAM system clock), 10-40 minutes under x86 emulation
#   pocket/psx/build.sh package          package fpga/output_files/ap_core.rbf; refuses a missing or negative-slack timing summary
#                                        unless ALLOW_TIMING_FAIL=1
#   pocket/psx/build.sh timing           print the worst slack per clock and model of a finished compile
#   pocket/psx/build.sh check            validate the dist JSON (no bitstream needed)
#   pocket/psx/build.sh sim              stub and bridge testbenches (Icarus Verilog) and the mixed-language spike (nvc)
# Layout and clocks: docs/pocket/POCKET_TOP.md, "Shell skeleton".
set -euo pipefail
cd "$(dirname "$0")"

QUARTUS_IMAGE=${QUARTUS_IMAGE:-raetro/quartus:21.1}
CORE=defgenx.PSX
REV=ap_core

# the generated SDRAM timing files must match common/tools/sdram_timing.py's table
timing_check() {
	python3 ../common/tools/sdram_timing.py --check
}

compile() {
	timing_check
	if command -v quartus_sh >/dev/null; then
		(cd fpga && quartus_sh --flow compile ap_core -c "$REV")
	else
		# mount the repository root, as the other Pocket builds do
		docker run --rm --platform linux/amd64 --name "psx_$REV" -v "$PWD/../..":/build \
			-w /build/pocket/psx/fpga "$QUARTUS_IMAGE" quartus_sh --flow compile ap_core -c "$REV"
	fi
}

# "slack<TAB>clock and model" per entry of the analyser's summary, worst first
slacks() {
	local f=fpga/output_files/$REV.sta.summary
	[ -f "$f" ] || { echo "missing $f - compile first" >&2; exit 1; }
	awk '/^Type/ {t=$0; sub(/^Type  : /,"",t)} /^Slack/ {print $3 "\t" t}' "$f" | sort -n
}

timing() {
	slacks | head -${LINES_SHOWN:-40}
}

# refuse a missing timing summary or a negative slack (ALLOW_TIMING_FAIL=1 overrides)
timing_gate() {
	local worst
	if ! worst=$(slacks 2>&1 | head -1) || [ -z "$worst" ] || [[ $worst == missing* ]]; then
		echo "no timing summary for $REV: ${worst:-empty fpga/output_files/$REV.sta.summary}" >&2
		[ "${ALLOW_TIMING_FAIL:-}" = 1 ] || { echo "refusing to package; ALLOW_TIMING_FAIL=1 overrides" >&2; exit 1; }
		return
	fi
	if awk -F'\t' '{exit !($1 < 0)}' <<<"$worst"; then
		echo "$REV fails timing, worst slack ${worst%%$'\t'*} ns (${worst#*$'\t'})" >&2
		[ "${ALLOW_TIMING_FAIL:-}" = 1 ] || { echo "refusing to package; ALLOW_TIMING_FAIL=1 overrides" >&2; exit 1; }
		echo "ALLOW_TIMING_FAIL=1: packaging with a failing timing summary" >&2
	else
		echo "$REV timing met, worst slack ${worst%%$'\t'*} ns (${worst#*$'\t'})"
	fi
}

package() {
	local rbf=fpga/output_files/$REV.rbf
	[ -f "$rbf" ] || { echo "missing $rbf - compile first" >&2; exit 1; }
	timing_gate
	python3 tools/reverse_bits.py "$rbf" "dist/Cores/$CORE/psx.rbf_r"
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
	vvp "$1" | tee "$log"
	grep -qx PASS "$log"
}

simulate() {
	timing_check
	python3 tools/check_json.py --no-bitstream
	mkdir -p sim/out
	iverilog -g2005 -DSDRAM_135 -o sim/out/stub.vvp -I ../common/mem sim/tb_stub.v fpga/core/psx_top_stub.v
	vvp_pass sim/out/stub.vvp
	iverilog -g2005 -o sim/out/bridge.vvp sim/tb_bridge.v fpga/core/core_bridge_cmd.v ../common/apf/common.v
	vvp_pass sim/out/bridge.vvp
	sim/mixed/run.sh
}

case "${1:-all}" in
	all) compile; package ;;
	compile) compile ;;
	package) package ;;
	timing) timing ;;
	check) python3 tools/check_json.py --no-bitstream ;;
	sim) simulate ;;
	*) echo "usage: $0 [all|compile|package|timing|check|sim]" >&2; exit 1 ;;
esac
