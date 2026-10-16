// Two clients on the SDRAM controller request port: A (vram_adapter) and B (spu_adapter). B goes first: it has one
// request outstanding and holds it until accepted, so A is delayed by one request at most. The tag marks B's reads
// and routes the returns. Latency bound: docs/pocket/POCKET_TOP.md, "SPU RAM".
module psx_sdram_arb (
    input  wire        a_valid,
    output wire        a_ready,
    input  wire        a_we,
    input  wire [24:0] a_addr,
    input  wire [63:0] a_wdata,
    input  wire [7:0]  a_be,

    input  wire        b_valid,
    output wire        b_ready,
    input  wire        b_we,
    input  wire [24:0] b_addr,
    input  wire [63:0] b_wdata,
    input  wire [7:0]  b_be,

    output wire        c_valid,
    input  wire        c_ready,
    output wire        c_we,
    output wire [24:0] c_addr,
    output wire [63:0] c_wdata,
    output wire [7:0]  c_be,
    output wire        c_tag,

    input  wire        c_rvalid,
    input  wire        c_rtag,
    output wire        a_rvalid,
    output wire        b_rvalid
);
    assign c_valid = a_valid | b_valid;
    assign c_we    = b_valid ? b_we    : a_we;
    assign c_addr  = b_valid ? b_addr  : a_addr;
    assign c_wdata = b_valid ? b_wdata : a_wdata;
    assign c_be    = b_valid ? b_be    : a_be;
    assign c_tag   = b_valid;
    assign b_ready = c_ready & b_valid;
    assign a_ready = c_ready & ~b_valid;
    assign a_rvalid = c_rvalid & ~c_rtag;
    assign b_rvalid = c_rvalid &  c_rtag;
endmodule
