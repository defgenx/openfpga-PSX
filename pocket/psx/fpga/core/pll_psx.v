// Port names of the generated PLL (pll_psx_dps.v, from tools/gen_pll.sh). One 812.8512 MHz fractional VCO:
// clk_sys, clk_sd, clk_cap /6; clk1x /24; clk2x /12; clk3x /8; placeholder pixel clock /128 and its 90 degree copy.
// clk_cap is counter 2 and the calibration moves it; clk1x is its scan clock. docs/pocket/POCKET_TOP.md, "Clocks".
module pll_psx (
	input  wire refclk,
	input  wire rst,
	output wire clk_sys,
	output wire clk_sd,
	output wire clk_cap,
	output wire clk1x,
	output wire clk2x,
	output wire clk3x,
	output wire clk_vid,
	output wire clk_vid_90,
	output wire locked,
	input  wire phase_en,       // clk1x domain
	input  wire updn,           // 1: delay clk_cap by one step
	output wire phase_done      // clk1x domain
);

	pll_psx_dps pll (
		.refclk     (refclk),
		.rst        (rst),
		.outclk_0   (clk_sys),
		.outclk_1   (clk_sd),
		.outclk_2   (clk_cap),
		.outclk_3   (clk1x),
		.outclk_4   (clk2x),
		.outclk_5   (clk3x),
		.outclk_6   (clk_vid),
		.outclk_7   (clk_vid_90),
		.locked     (locked),
		.phase_en   (phase_en),
		.scanclk    (clk1x),
		.updn       (updn),
		.cntsel     (5'd2),
		.phase_done (phase_done)
	);

endmodule
