#
# user core constraints
#
# pll_mem outputs (derive_pll_clocks): [0] clk_sys, [1] clk_sd, [2] clk_cap, [3] clk_vid, [4] clk_vid_90, [5] clk_scan.
# clk_sys, clk_sd, clk_cap and clk_scan are one related group; clk_vid and clk_vid_90 are another.
#

set PLL "ic|pll|pll|altera_pll_i|cyclonev_pll"
set CLK_SYS  "$PLL|counter\[0\].output_counter|divclk"
set CLK_SD   "$PLL|counter\[1\].output_counter|divclk"
set CLK_CAP  "$PLL|counter\[2\].output_counter|divclk"
set CLK_VID  "$PLL|counter\[3\].output_counter|divclk"
set CLK_V90  "$PLL|counter\[4\].output_counter|divclk"
set CLK_SCAN "$PLL|counter\[5\].output_counter|divclk"

# SDRAM (AS4C32M16SB-7): dram_clk leaves through a DDIO register driven by clk_sd, so the pin
# clock is a generated clock that includes the same I/O delay as the data pins.
# tAC, tOH, tIS and tIH come from the SDRAM timing table (docs/pocket/MEMTEST.md), read from the
# generated sdram_timing.sdc; the same constraints hold for both clock variants.
source ../../common/mem/sdram_timing.sdc
create_generated_clock -name dram_clk_pin -source [get_pins "$CLK_SD"] [get_ports {dram_clk}]
set_input_delay  -clock dram_clk_pin -max $SDT_TAC [get_ports {dram_dq[*]}]
set_input_delay  -clock dram_clk_pin -min $SDT_TOH [get_ports {dram_dq[*]}]
set_output_delay -clock dram_clk_pin -max $SDT_TIS [get_ports {dram_dq[*] dram_a[*] dram_ba[*] dram_dqm[*] dram_ras_n dram_cas_n dram_we_n}]
set_output_delay -clock dram_clk_pin -min -$SDT_TIH [get_ports {dram_dq[*] dram_a[*] dram_ba[*] dram_dqm[*] dram_ras_n dram_cas_n dram_we_n}]
# Read data is captured by clk_cap in the I/O cell, whose phase the calibration sets at run time
# (docs/pocket/MEMTEST.md, Calibration contract). The one exception: the path from the dram_dq pins to the capture
# registers is not analysed, because its slack is a function of the phase the PLL is set to, not of the static one.
set_false_path -from [get_ports {dram_dq[*]}] -to [get_clocks $CLK_CAP]
# PSRAM and SRAM are asynchronous devices: the controllers hold every signal for whole
# cycles and sample read data after a counted number of cycles, so the pins are not timed.
# The synchronous PSRAM read samples at a counted phase of cram_clk (half the system clock).
set_false_path -to   [get_ports {cram0_* cram1_* sram_*}]
set_false_path -from [get_ports {cram0_dq[*] cram1_dq[*] cram0_wait cram1_wait sram_dq[*]}]

set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group [get_clocks "$CLK_SYS $CLK_SD $CLK_CAP $CLK_SCAN dram_clk_pin"] \
 -group [get_clocks "$CLK_VID $CLK_V90"]

derive_clock_uncertainty

# Everything else stays analysed. The capture clock swings by up to SDT_CAL_SWING after the static phase (0), so the
# transfer from clk_cap to the system clock (dq_cap3 -> dq_r) gets that much less setup time.
set_clock_uncertainty -setup -add -from [get_clocks $CLK_CAP] -to [get_clocks $CLK_SYS] $SDT_CAL_SWING
