// Verilog leaf
module vmod(input wire clk, input wire [7:0] a, output reg [7:0] q);
  always @(posedge clk) q <= a + 8'd1;
endmodule
