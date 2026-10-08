# Related, edge-aligned PLL clocks; paths between them are analysed, not cut.
# Periods are exact multiples (3 x 9.842 = 2 x 14.763 = 29.526) so coincident edges do not give a 1 ps
# setup relationship between the clocks.
create_clock -name clk1x -period 29.526 [get_ports clk1x]   ;# 33.8688 MHz
create_clock -name clk2x -period 14.763 [get_ports clk2x]   ;# 67.7376 MHz
create_clock -name clk3x -period 9.842  [get_ports clk3x]   ;# 101.6064 MHz
derive_clock_uncertainty
