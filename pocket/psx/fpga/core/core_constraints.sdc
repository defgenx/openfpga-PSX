#
# user core constraints
#
# pll_psx outputs (derive_pll_clocks): [0] clk1x, [1] clk2x, [2] clk3x, [3] clk_sys, [4] clk_sd, [5] clk_cap,
# [6] clk_vid, [7] clk_vid_90. clk1x/2x/3x are one related group, clk_sys/clk_sd/clk_cap another.
#

set PLL "ic|pll|altera_pll_i|general"
set CLK_1X  "$PLL\[0\].gpll~PLL_OUTPUT_COUNTER|divclk"
set CLK_2X  "$PLL\[1\].gpll~PLL_OUTPUT_COUNTER|divclk"
set CLK_3X  "$PLL\[2\].gpll~PLL_OUTPUT_COUNTER|divclk"
set CLK_SYS "$PLL\[3\].gpll~PLL_OUTPUT_COUNTER|divclk"
set CLK_SD  "$PLL\[4\].gpll~PLL_OUTPUT_COUNTER|divclk"
set CLK_CAP "$PLL\[5\].gpll~PLL_OUTPUT_COUNTER|divclk"
set CLK_VID "$PLL\[6\].gpll~PLL_OUTPUT_COUNTER|divclk"
set CLK_V90 "$PLL\[7\].gpll~PLL_OUTPUT_COUNTER|divclk"

# SDRAM (AS4C32M16SB-7): dram_clk leaves through a DDIO register driven by clk_sd, so the pin
# clock is a generated clock that includes the same I/O delay as the data pins.
# tAC, tOH, tIS and tIH come from the generated sdram_timing.sdc.
source ../../common/mem/sdram_timing.sdc
create_generated_clock -name dram_clk_pin -source [get_pins "$CLK_SD"] [get_ports {dram_clk}]
set_input_delay  -clock dram_clk_pin -max $SDT_TAC [get_ports {dram_dq[*]}]
set_input_delay  -clock dram_clk_pin -min $SDT_TOH [get_ports {dram_dq[*]}]
set_output_delay -clock dram_clk_pin -max $SDT_TIS [get_ports {dram_dq[*] dram_a[*] dram_ba[*] dram_dqm[*] dram_ras_n dram_cas_n dram_we_n}]
set_output_delay -clock dram_clk_pin -min -$SDT_TIH [get_ports {dram_dq[*] dram_a[*] dram_ba[*] dram_dqm[*] dram_ras_n dram_cas_n dram_we_n}]
# Read data is captured by clk_cap in the I/O cell, on the second cap edge after the one the analyser picks.
set_multicycle_path -from [get_clocks dram_clk_pin] -to [get_clocks $CLK_CAP] -setup 2

# PSRAM and SRAM are asynchronous devices: the controllers hold every signal for whole cycles.
set_false_path -to   [get_ports {cram0_* cram1_* sram_*}]
set_false_path -from [get_ports {cram0_dq[*] cram1_dq[*] cram0_wait cram1_wait sram_dq[*]}]

# The core clocks are integer divisions of one VCO and stay one timed group; the SDRAM clocks, the pixel clocks
# and the APF clocks are crossed through registers.
set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group [get_clocks "$CLK_1X $CLK_2X $CLK_3X"] \
 -group [get_clocks "$CLK_SYS $CLK_SD $CLK_CAP dram_clk_pin"] \
 -group [get_clocks "$CLK_VID $CLK_V90"]

derive_clock_uncertainty
