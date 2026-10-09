#!/usr/bin/env bash
# Regenerate the two PLL cores (fpga/core/pll_mem_101.v, pll_mem_135.v) with the Quartus IP generator, in Docker.
#   tools/gen_pll.sh
# Altera PLL, fractional, 74.25 MHz in, VCO 812.8512 MHz, dynamic phase shift ports on. Outputs:
#   0 system clock, 1 SDRAM pin clock (static phase), 2 SDRAM read-capture clock (the one the calibration shifts),
#   3 pixel clock 6.3504 MHz, 4 its 90 degree copy, 5 scan clock 33.8688 MHz (system clock / 4, or / 3 at 101.6064 MHz).
# The SDRAM pin phase is 1/8 of the VCO period per step: docs/pocket/MEMTEST.md, "Clocks and pins".
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE=${QUARTUS_IMAGE:-raetro/quartus:21.1}
out=$(mktemp -d)
gen() {   # name, system MHz, SDRAM pin phase ps
	docker run --rm --platform linux/amd64 -v "$out":/w -w /w "$IMAGE" ip-generate --component-name=altera_pll \
		--output-directory=/w/$1 --file-set=QUARTUS_SYNTH --output-name=$1 --remove-qsys-generate-warning \
		--component-param=device_family="Cyclone V" --component-param=device=5CEBA4F23C8 --component-param=gui_device_speed_grade=8 \
		--component-param=gui_pll_mode="Fractional-N PLL" --component-param=gui_reference_clock_frequency=74.25 \
		--component-param=gui_operation_mode=direct --component-param=gui_fractional_cout=24 \
		--component-param=gui_use_locked=true --component-param=gui_en_dps_ports=true --component-param=gui_number_of_clocks=6 \
		--component-param=gui_output_clock_frequency0=$2 --component-param=gui_phase_shift0=0 \
		--component-param=gui_output_clock_frequency1=$2 --component-param=gui_phase_shift1=$3 \
		--component-param=gui_output_clock_frequency2=$2 --component-param=gui_phase_shift2=0 \
		--component-param=gui_output_clock_frequency3=6.3504 --component-param=gui_phase_shift3=0 \
		--component-param=gui_output_clock_frequency4=6.3504 --component-param=gui_phase_shift4=39368 \
		--component-param=gui_output_clock_frequency5=33.8688 --component-param=gui_phase_shift5=0
	cp "$out/$1/$1.v" fpga/core/$1.v
}
gen pll_mem_101 101.6064 7689
gen pll_mem_135 135.4752 4460
rm -rf "$out"
