#
# user core constraints
#
# pll_mem outputs (derive_pll_clocks): [0] clk_sys, [1] clk_sd, [2] clk_cap, [3] clk_vid, [4] clk_vid_90.
# clk_sys, clk_sd and clk_cap are one related group; clk_vid and clk_vid_90 are another.
#

set PLL "ic|pll|altera_pll_i|general"
set CLK_SYS "$PLL\[0\].gpll~PLL_OUTPUT_COUNTER|divclk"
set CLK_SD  "$PLL\[1\].gpll~PLL_OUTPUT_COUNTER|divclk"
set CLK_CAP "$PLL\[2\].gpll~PLL_OUTPUT_COUNTER|divclk"
set CLK_VID "$PLL\[3\].gpll~PLL_OUTPUT_COUNTER|divclk"
set CLK_V90 "$PLL\[4\].gpll~PLL_OUTPUT_COUNTER|divclk"

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
# Read data is captured by clk_cap in the I/O cell. It is the second cap edge after the one the analyser
# picks by default; the hold check keeps its default (the edge before), which is the real hazard:
# the next word arriving before this one is captured.
set_multicycle_path -from [get_clocks dram_clk_pin] -to [get_clocks $CLK_CAP] -setup 2

# PSRAM and SRAM are asynchronous devices: the controllers hold every signal for whole
# cycles and sample read data after a counted number of cycles, so the pins are not timed.
# The synchronous PSRAM read samples at a counted phase of cram_clk (half the system clock).
set_false_path -to   [get_ports {cram0_* cram1_* sram_*}]
set_false_path -from [get_ports {cram0_dq[*] cram1_dq[*] cram0_wait cram1_wait sram_dq[*]}]

set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group [get_clocks "$CLK_SYS $CLK_SD $CLK_CAP dram_clk_pin"] \
 -group [get_clocks "$CLK_VID $CLK_V90"]

derive_clock_uncertainty
