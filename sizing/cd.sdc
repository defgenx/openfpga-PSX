# Single PLL clock.
create_clock -name clk1x -period 29.526 [get_ports clk1x]   ;# 33.8688 MHz
derive_clock_uncertainty
