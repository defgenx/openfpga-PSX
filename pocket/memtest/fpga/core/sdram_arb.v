// Round-robin arbiter between the test engine (A) and the scan-out stream (B).
// Read data goes back to whoever asked; see docs/pocket/MEMTEST.md.
module sdram_arb (
    input  wire        clk,
    input  wire        rst,

    input  wire        a_valid,
    output wire        a_ready,
    input  wire        a_we,
    input  wire [24:0] a_addr,
    input  wire [63:0] a_wdata,

    input  wire        b_valid,
    output wire        b_ready,
    input  wire [24:0] b_addr,

    output wire        a_rvalid,
    output wire        b_rvalid,
    output wire [63:0] r_data,

    output wire        c_valid,
    input  wire        c_ready,
    output wire        c_we,
    output wire [24:0] c_addr,
    output wire [63:0] c_wdata,
    output wire        c_tag,
    input  wire        c_rvalid,
    input  wire [63:0] c_rdata,
    input  wire        c_rtag
);
    reg last_b;
    wire sel_b = b_valid & (~a_valid | ~last_b);

    assign c_valid = a_valid | b_valid;
    assign c_we    = sel_b ? 1'b0 : a_we;
    assign c_addr  = sel_b ? b_addr : a_addr;
    assign c_wdata = a_wdata;
    assign c_tag   = sel_b;
    assign a_ready = c_ready & ~sel_b & a_valid;
    assign b_ready = c_ready &  sel_b;

    assign a_rvalid = c_rvalid & ~c_rtag;
    assign b_rvalid = c_rvalid &  c_rtag;
    assign r_data   = c_rdata;

    always @(posedge clk) begin
        if (rst) last_b <= 1'b0;
        else if (c_valid && c_ready) last_b <= sel_b;
    end
endmodule
