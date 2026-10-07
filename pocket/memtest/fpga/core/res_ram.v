// Result store: 128 x {valid, 32-bit value}. Written by the sequencer; read by the screen
// formatter (clk) and the APF bridge (clk_b). Two copies give each reader its own port.
module res_ram (
    input  wire        clk,
    input  wire        we,
    input  wire [6:0]  wa,
    input  wire [32:0] wd,
    input  wire [6:0]  ra,
    output reg  [32:0] rq,
    input  wire        clk_b,
    input  wire [6:0]  rb,
    output reg  [32:0] rq_b
);
    reg [32:0] ma [0:127];
    reg [32:0] mb [0:127];
    integer i;
    initial for (i = 0; i < 128; i = i + 1) begin ma[i] = 33'd0; mb[i] = 33'd0; end

    always @(posedge clk) begin
        if (we) begin ma[wa] <= wd; mb[wa] <= wd; end
        rq <= ma[ra];
    end
    always @(posedge clk_b) rq_b <= mb[rb];
endmodule
