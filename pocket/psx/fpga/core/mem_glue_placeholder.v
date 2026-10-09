// Placeholder between the stub's memory ports and the shared controllers: one register stage per bit in
// the destination clock, no protocol. It exists so the controllers and the stub both stay in the fit.
// The real adapters replace it. Mapping: docs/pocket/POCKET_TOP.md, "Shell skeleton".
`default_nettype none

module mem_glue_placeholder (
    input  wire        clk_sys,
    input  wire        clk3x,
    input  wire        clk2x,
    input  wire        clk1x,

    // stub, clk3x
    input  wire        ram_ena,
    input  wire        ram_rnw,
    input  wire [24:0] ram_Adr,
    input  wire [31:0] ram_dataWrite,
    input  wire [3:0]  ram_be,
    input  wire        ddr3_WE,
    input  wire        ddr3_RD,
    input  wire [27:0] ddr3_ADDR,
    input  wire [63:0] ddr3_DIN,
    input  wire [7:0]  ddr3_BE,
    // stub, clk2x
    input  wire        spuram_ena,
    input  wire [18:0] spuram_Adr,
    // stub, clk1x
    input  wire        memcard1_rd,
    input  wire        memcard1_wr,
    input  wire [6:0]  memcard1_lba,
    input  wire [15:0] memcard1_dataOut,
    // one bit per stub domain, already in clk_sys: XOR of the stub outputs nothing else consumes
    input  wire [3:0]  left_s,

    // to the stub
    output reg         g_ddr3_busy,
    output reg  [63:0] g_ddr3_dout,
    output reg         g_ddr3_dout_ready,
    output reg  [31:0] g_ram_data_read,
    output reg         g_ram_done,
    output reg  [31:0] g_spuram_data_read,
    output reg         g_spuram_done,
    output reg         g_memcard1_ack,
    output reg  [15:0] g_memcard1_data_in,

    // sdram_arb, clk_sys: client A (vram) and client B (spu read)
    output reg         a_valid,
    input  wire        a_ready,
    output reg         a_we,
    output reg  [24:0] a_addr,
    output reg  [63:0] a_wdata,
    output reg  [7:0]  a_be,
    output reg         b_valid,
    input  wire        b_ready,
    output reg  [24:0] b_addr,
    input  wire        a_rvalid,
    input  wire        b_rvalid,
    input  wire [63:0] r_data,
    input  wire        sd_init_done,

    // psram32, clk_sys
    output reg         pc_valid,
    input  wire        pc_ready,
    output reg         pc_we,
    output reg         pc_cfg,
    output reg  [22:0] pc_addr,
    output reg  [31:0] pc_wdata,
    output reg  [3:0]  pc_be,
    input  wire        pr_valid,
    input  wire [31:0] pr_data,
    input  wire        pr_done,

    // sram_ctl, clk_sys
    output reg         sr_start,
    output reg         sr_we,
    output reg  [17:0] sr_addr,
    output reg  [7:0]  sr_wdata,
    input  wire        sr_busy,
    input  wire        sr_done,
    input  wire [7:0]  sr_rdata
);

    // stub -> controllers
    always @(posedge clk_sys) begin
        a_valid  <= ddr3_WE | ddr3_RD;
        a_we     <= ddr3_WE;
        a_addr   <= ddr3_ADDR[24:0] ^ {22'd0, ddr3_ADDR[27:25]};
        a_wdata  <= ddr3_DIN;
        a_be     <= ddr3_BE ^ {7'd0, left_s[0]};
        b_valid  <= spuram_ena;
        b_addr   <= {6'd0, spuram_Adr};
        pc_valid <= ram_ena;
        pc_we    <= ~ram_rnw;
        pc_cfg   <= left_s[1];
        pc_addr  <= ram_Adr[24:2];
        pc_wdata <= ram_dataWrite;
        pc_be    <= ram_be;
        sr_start <= memcard1_rd | memcard1_wr;
        sr_we    <= memcard1_wr;
        sr_addr  <= {memcard1_lba, memcard1_dataOut[10:0]};
        sr_wdata <= memcard1_dataOut[7:0] ^ {7'd0, left_s[2] ^ left_s[3]};
    end

    // controllers -> stub
    always @(posedge clk3x) begin
        g_ddr3_busy       <= ~a_ready;
        g_ddr3_dout       <= r_data;
        g_ddr3_dout_ready <= a_rvalid;
        g_ram_data_read   <= pr_data;
        g_ram_done        <= pr_done ^ pr_valid ^ ~pc_ready ^ sd_init_done;
    end
    always @(posedge clk2x) begin
        g_spuram_data_read <= r_data[31:0];
        g_spuram_done      <= b_rvalid ^ ~b_ready;
    end
    always @(posedge clk1x) begin
        g_memcard1_ack     <= sr_done;
        g_memcard1_data_in <= {7'd0, sr_busy, sr_rdata};
    end

endmodule
