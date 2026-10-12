#
# user core constraints
#
# pll_psx_dps outputs (derive_pll_clocks): [0] clk_sys, [1] clk_sd, [2] clk_cap, [3] clk1x, [4] clk2x, [5] clk3x,
# [6] clk_vid, [7] clk_vid_90. clk1x/2x/3x and the pixel clocks (clk1x is the calibration scan clock) are one related group,
# clk_sys/clk_sd/clk_cap another.
#

set PLL "ic|pll|pll|altera_pll_i|cyclonev_pll"
set CLK_SYS  "$PLL|counter\[0\].output_counter|divclk"
set CLK_SD   "$PLL|counter\[1\].output_counter|divclk"
set CLK_CAP  "$PLL|counter\[2\].output_counter|divclk"
set CLK_1X   "$PLL|counter\[3\].output_counter|divclk"
set CLK_2X   "$PLL|counter\[4\].output_counter|divclk"
set CLK_3X   "$PLL|counter\[5\].output_counter|divclk"
set CLK_VID  "$PLL|counter\[6\].output_counter|divclk"
set CLK_V90  "$PLL|counter\[7\].output_counter|divclk"

# SDRAM (AS4C32M16SB-7): dram_clk leaves through a DDIO register driven by clk_sd, so the pin
# clock is a generated clock that includes the same I/O delay as the data pins.
# tAC, tOH, tIS and tIH come from the generated sdram_timing.sdc.
source ../../common/mem/sdram_timing.sdc
create_generated_clock -name dram_clk_pin -source [get_pins "$CLK_SD"] [get_ports {dram_clk}]
set_input_delay  -clock dram_clk_pin -max $SDT_TAC [get_ports {dram_dq[*]}]
set_input_delay  -clock dram_clk_pin -min $SDT_TOH [get_ports {dram_dq[*]}]
set_output_delay -clock dram_clk_pin -max $SDT_TIS [get_ports {dram_dq[*] dram_a[*] dram_ba[*] dram_dqm[*] dram_ras_n dram_cas_n dram_we_n}]
set_output_delay -clock dram_clk_pin -min -$SDT_TIH [get_ports {dram_dq[*] dram_a[*] dram_ba[*] dram_dqm[*] dram_ras_n dram_cas_n dram_we_n}]
# Read data is captured by clk_cap in the I/O cell, whose phase the calibration sets at run time (docs/pocket/MEMTEST.md,
# Calibration contract). The one exception: the path from the dram_dq pins to the capture registers is not analysed.
set_false_path -from [get_ports {dram_dq[*]}] -to [get_clocks $CLK_CAP]

# PSRAM and SRAM are asynchronous devices: the controllers hold every signal for whole cycles.
set_false_path -to   [get_ports {cram0_* cram1_* sram_*}]
set_false_path -from [get_ports {cram0_dq[*] cram1_dq[*] cram0_wait cram1_wait sram_dq[*]}]

# clk1x/2x/3x and clk_vid (clk2x / 10) are integer divisions of one VCO and stay one timed group, so video_fl.v samples the
# GPU's clk2x outputs with one register; clk_sys/clk_sd/clk_cap are another. The groups and the APF clocks are crossed through
# registers; the calibration handshake between clk_sys and its scan
# clock clk1x uses two-flop synchronisers (sdram_cal.v).
set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group [get_clocks "$CLK_1X $CLK_2X $CLK_3X $CLK_VID $CLK_V90"] \
 -group [get_clocks "$CLK_SYS $CLK_SD $CLK_CAP dram_clk_pin"]

derive_clock_uncertainty

# The capture clock swings by up to SDT_CAL_SWING after its static phase (0), so the transfer from clk_cap to the
# system clock (dq_cap3 -> dq_r) gets that much less setup time.
set_clock_uncertainty -setup -add -from [get_clocks $CLK_CAP] -to [get_clocks $CLK_SYS] $SDT_CAL_SWING
