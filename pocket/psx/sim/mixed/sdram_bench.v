// sdram_ctl and the SDRAM model behind one boundary without inout ports: nvc instantiates Verilog from VHDL
// only through input and output ports, so the dram_dq bus stays inside this module.
module sdram_bench (
    input  wire        clk,
    input  wire        clk_cap,
    input  wire        clk_sd,
    input  wire        rst,
    output wire        init_done,
    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_we,
    input  wire [24:0] req_addr,
    input  wire [63:0] req_wdata,
    input  wire [7:0]  req_be,
    input  wire        req_tag,
    output wire        rd_valid,
    output wire [63:0] rd_data,
    output wire        rd_tag
);
    wire [12:0] dram_a;
    wire [1:0]  dram_ba, dram_dqm;
    wire [15:0] dram_dq;
    wire        dram_ras_n, dram_cas_n, dram_we_n;

    sdram_ctl sdc (
        .clk(clk), .clk_cap(clk_cap), .rst(rst), .init_done(init_done),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we), .req_addr(req_addr),
        .req_wdata(req_wdata), .req_be(req_be), .req_tag(req_tag),
        .rd_valid(rd_valid), .rd_data(rd_data), .rd_tag(rd_tag),
        .dram_a(dram_a), .dram_ba(dram_ba), .dram_dq(dram_dq), .dram_dqm(dram_dqm),
        .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_we_n(dram_we_n)
    );

    sdram_simple mdl (
        .clk(clk_sd), .a(dram_a), .ba(dram_ba), .dq(dram_dq), .dqm(dram_dqm),
        .ras_n(dram_ras_n), .cas_n(dram_cas_n), .we_n(dram_we_n)
    );
endmodule
