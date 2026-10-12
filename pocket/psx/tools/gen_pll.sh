#!/usr/bin/env bash
# Regenerate the PLL core fpga/core/pll_psx_dps.v with the Quartus IP generator, in Docker.
#   tools/gen_pll.sh
# Altera PLL, fractional, 74.25 MHz in, VCO 812.8512 MHz, dynamic phase shift ports on. Outputs:
#   0 clk_sys 135.4752, 1 clk_sd (SDRAM pin, static phase), 2 clk_cap (the one the calibration shifts; cntsel 2),
#   3 clk1x 33.8688 (also the calibration scan clock), 4 clk2x, 5 clk3x, 6 pixel clock 6.77376 (clk2x / 10, the GPU's 320-wide dot rate), 7 its 90 degree copy.
# The SDRAM pin phase is the memtest 135 MHz one, 29 steps of 1/8 VCO period: docs/pocket/MEMTEST.md, "Phases, and why".
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE=${QUARTUS_IMAGE:-raetro/quartus:21.1}
out=$(mktemp -d)
name=pll_psx_dps
docker run --rm --platform linux/amd64 -v "$out":/w -w /w "$IMAGE" ip-generate --component-name=altera_pll \
	--output-directory=/w/$name --file-set=QUARTUS_SYNTH --output-name=$name --remove-qsys-generate-warning \
	--component-param=device_family="Cyclone V" --component-param=device=5CEBA4F23C8 --component-param=gui_device_speed_grade=8 \
	--component-param=gui_pll_mode="Fractional-N PLL" --component-param=gui_reference_clock_frequency=74.25 \
	--component-param=gui_operation_mode=direct --component-param=gui_fractional_cout=24 \
	--component-param=gui_use_locked=true --component-param=gui_en_dps_ports=true --component-param=gui_number_of_clocks=8 \
	--component-param=gui_output_clock_frequency0=135.4752 --component-param=gui_phase_shift0=0 \
	--component-param=gui_output_clock_frequency1=135.4752 --component-param=gui_phase_shift1=4460 \
	--component-param=gui_output_clock_frequency2=135.4752 --component-param=gui_phase_shift2=0 \
	--component-param=gui_output_clock_frequency3=33.8688 --component-param=gui_phase_shift3=0 \
	--component-param=gui_output_clock_frequency4=67.7376 --component-param=gui_phase_shift4=0 \
	--component-param=gui_output_clock_frequency5=101.6064 --component-param=gui_phase_shift5=0 \
	--component-param=gui_output_clock_frequency6=6.77376 --component-param=gui_phase_shift6=0 \
	--component-param=gui_output_clock_frequency7=6.77376 --component-param=gui_phase_shift7=36908
cp "$out/$name/$name.v" fpga/core/$name.v
rm -rf "$out"
