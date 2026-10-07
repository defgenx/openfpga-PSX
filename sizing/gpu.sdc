# Related, edge-aligned PLL clocks; paths between them are analysed, not cut.
create_clock -name clk1x  -period 29.525 [get_ports clk1x]   ;# 33.8688 MHz
create_clock -name clk2x  -period 14.762 [get_ports clk2x]   ;# 67.7376 MHz
create_clock -name clkvid -period 18.624 [get_ports clkvid]  ;# 53.693 MHz
# clkvid comes from a separate PLL on the Pocket; the GPU crosses into it through dual-clock RAMs.
set_clock_groups -asynchronous -group {clk1x clk2x} -group {clkvid}
derive_clock_uncertainty
