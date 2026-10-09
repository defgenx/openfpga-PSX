// sdram_ctl and the SDRAM model behind one boundary without inout ports: nvc instantiates Verilog from VHDL
// only through input and output ports, so the dram_dq bus stays inside this module. The PLL's dynamic phase shift is
// a stand-in (pll_dps_nvc.v; it makes clk_scan and clk_cap from clk); a tracking window is requested every TICK_EVERY cycles.
module sdram_bench #(
    parameter integer TICK_EVERY = 20000
) (
    input  wire        clk,
    input  wire        clk_sd,
    input  wire        clk_dq,
    input  wire        rst,
    output wire        init_done,
    output wire        cal_ok,
    output wire [6:0]  cal_width,
    output wire [6:0]  cal_centre,
    output wire [15:0] cal_moves,
    output wire [3:0]  cal_flags,
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

    wire clk_cap, clk_scan, ps_en, ps_up, ps_done;
    pll_dps_nvc #(.SCAN_DIV(4)) pll (.clk(clk), .clk_scan(clk_scan), .phase_en(ps_en), .updn(ps_up),
        .cntsel(5'd2), .phase_done(ps_done), .clk_cap(clk_cap));

    integer tick_cnt = 0;
    reg     cal_tick = 1'b0;
    always @(posedge clk) begin
        tick_cnt <= (rst || tick_cnt == TICK_EVERY - 1) ? 0 : tick_cnt + 1;
        cal_tick <= (tick_cnt == TICK_EVERY - 1);
    end

    wire cal_done;
    wire [6:0] cal_boot, cal_min, cal_max;
    sdram_ctl sdc (
        .clk(clk), .clk_cap(clk_cap), .rst(rst), .init_done(init_done),
        .pll_locked(1'b1), .cal_tick(cal_tick), .clk_scan(clk_scan), .ps_en(ps_en), .ps_up(ps_up), .ps_done(ps_done),
        .cal_done(cal_done), .cal_ok(cal_ok), .cal_width(cal_width), .cal_boot(cal_boot), .cal_centre(cal_centre),
        .cal_min(cal_min), .cal_max(cal_max), .cal_moves(cal_moves), .cal_flags(cal_flags),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we), .req_addr(req_addr),
        .req_wdata(req_wdata), .req_be(req_be), .req_tag(req_tag),
        .rd_valid(rd_valid), .rd_data(rd_data), .rd_tag(rd_tag),
        .dram_a(dram_a), .dram_ba(dram_ba), .dram_dq(dram_dq), .dram_dqm(dram_dqm),
        .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_we_n(dram_we_n)
    );

    sdram_simple mdl (
        .clk(clk_sd), .clk_dq(clk_dq), .a(dram_a), .ba(dram_ba), .dq(dram_dq), .dqm(dram_dqm),
        .ras_n(dram_ras_n), .cas_n(dram_cas_n), .we_n(dram_we_n)
    );
endmodule
