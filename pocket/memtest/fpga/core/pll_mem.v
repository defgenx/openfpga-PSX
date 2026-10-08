// Clocks from the 74.25 MHz reference, one 812.85 MHz VCO: system clock, SDRAM pin clock, SDRAM read
// capture clock, pixel 6.3504 MHz and its 90 degree copy. The system clock is 101.6064 MHz (VCO / 8) or,
// in the SDRAM_135 variant, 135.4752 MHz (VCO / 6); the SDRAM clock phases are per variant.
// Phase shifts are multiples of 1/8 VCO period (153.8 ps). See docs/pocket/MEMTEST.md.
`ifdef SDRAM_135
  `define PLL_SYS_MHZ "135.4752 MHz"
  `define PLL_SD_PS   "4767 ps"
  `define PLL_CAP_PS  "2614 ps"
`else
  `define PLL_SYS_MHZ "101.6064 MHz"
  `define PLL_SD_PS   "6151 ps"
  `define PLL_CAP_PS  "307 ps"
`endif
`timescale 1ns/10ps
module pll_mem (
	input  wire refclk,
	input  wire rst,
	output wire clk_sys,
	output wire clk_sd,
	output wire clk_cap,
	output wire clk_vid,
	output wire clk_vid_90,
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("true"),
		.reference_clock_frequency("74.25 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(5),
		.output_clock_frequency0(`PLL_SYS_MHZ),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1(`PLL_SYS_MHZ),
		.phase_shift1(`PLL_SD_PS),
		.duty_cycle1(50),
		.output_clock_frequency2(`PLL_SYS_MHZ),
		.phase_shift2(`PLL_CAP_PS),
		.duty_cycle2(50),
		.output_clock_frequency3("6.3504 MHz"),
		.phase_shift3("0 ps"),
		.duty_cycle3(50),
		.output_clock_frequency4("6.3504 MHz"),
		.phase_shift4("39368 ps"),
		.duty_cycle4(50),
		.output_clock_frequency5("0 MHz"),
		.phase_shift5("0 ps"),
		.duty_cycle5(50),
		.output_clock_frequency6("0 MHz"),
		.phase_shift6("0 ps"),
		.duty_cycle6(50),
		.output_clock_frequency7("0 MHz"),
		.phase_shift7("0 ps"),
		.duty_cycle7(50),
		.output_clock_frequency8("0 MHz"),
		.phase_shift8("0 ps"),
		.duty_cycle8(50),
		.output_clock_frequency9("0 MHz"),
		.phase_shift9("0 ps"),
		.duty_cycle9(50),
		.output_clock_frequency10("0 MHz"),
		.phase_shift10("0 ps"),
		.duty_cycle10(50),
		.output_clock_frequency11("0 MHz"),
		.phase_shift11("0 ps"),
		.duty_cycle11(50),
		.output_clock_frequency12("0 MHz"),
		.phase_shift12("0 ps"),
		.duty_cycle12(50),
		.output_clock_frequency13("0 MHz"),
		.phase_shift13("0 ps"),
		.duty_cycle13(50),
		.output_clock_frequency14("0 MHz"),
		.phase_shift14("0 ps"),
		.duty_cycle14(50),
		.output_clock_frequency15("0 MHz"),
		.phase_shift15("0 ps"),
		.duty_cycle15(50),
		.output_clock_frequency16("0 MHz"),
		.phase_shift16("0 ps"),
		.duty_cycle16(50),
		.output_clock_frequency17("0 MHz"),
		.phase_shift17("0 ps"),
		.duty_cycle17(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst      (rst),
		.outclk   ({clk_vid_90, clk_vid, clk_cap, clk_sd, clk_sys}),
		.locked   (locked),
		.fboutclk (),
		.fbclk    (1'b0),
		.refclk   (refclk)
	);

endmodule
