module vtop(input wire clk, input wire [7:0] a, output wire [7:0] q);
  wire [7:0] m;
  vhmod u (.clk(clk), .d(a), .q(m));
  vmod  w (.clk(clk), .a(m), .q(q));
endmodule
