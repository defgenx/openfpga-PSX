// SDRAM clock pin driven from a DDIO output register, so it sees the same pin delay as the
// data and command registers. See docs/pocket/MEMTEST.md.
module sd_clk_out (
	input  wire clk,
	output wire pin
);
	altddio_out #(
		.extend_oe_disable("OFF"),
		.intended_device_family("Cyclone V"),
		.invert_output("OFF"),
		.lpm_hint("UNUSED"),
		.lpm_type("altddio_out"),
		.oe_reg("UNREGISTERED"),
		.power_up_high("OFF"),
		.width(1)
	) ddio (
		.datain_h (1'b1),
		.datain_l (1'b0),
		.outclock (clk),
		.dataout  (pin),
		.aclr (1'b0),
		.aset (1'b0),
		.oe (1'b1),
		.oe_out (),
		.outclocken (1'b1),
		.sclr (1'b0),
		.sset (1'b0)
	);
endmodule
