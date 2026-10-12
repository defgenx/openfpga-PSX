// PSX main-RAM interface (ram_*, clk1x/clk3x) onto psram32 (clk_sys). Protocol and CDC: docs/pocket/POCKET_TOP.md.
// Every crossing is a toggle handshake: the data regs are written only when the other side has acknowledged,
// so a multi-bit value is read only while it is stable. Hold rst for at least 16 clk1x cycles.

// two-flop synchroniser
module ram_sync (input wire clk, input wire d, output wire q);
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [1:0] f = 2'b00;
    always @(posedge clk) f <= {f[0], d};
    assign q = f[1];
endmodule

module ram_adapter (
    input  wire        rst,                 // asynchronous assert, released synchronously in each domain
    input  wire        clk1x,
    input  wire        clk3x,
    input  wire        clk_sys,

    // core side, clk1x
    input  wire        ram_ena,             // one-cycle request pulse, fields valid in that cycle
    input  wire        ram_rnw,
    input  wire [24:0] ram_Adr,             // byte address, [1:0] = 0
    input  wire [31:0] ram_dataWrite,
    input  wire [3:0]  ram_be,
    input  wire        ram_dma,
    input  wire        ram_cache,
    input  wire [1:0]  ram_cntDMA,          // DMA words - 1
    output reg         ram_done,
    output reg  [31:0] ram_dataRead32,
    output reg         dma_wr,
    output reg         dma_reqprocessed,
    output reg  [31:0] dma_data,

    // icache fill port, clk3x
    output reg  [3:0]  cache_wr,
    output reg  [31:0] cache_data,
    output reg  [7:0]  cache_addr,

    // DMA write FIFO (fall-through, owned by the core), clk3x
    input  wire        ram_dmafifo_empty,
    input  wire [22:0] ram_dmafifo_adr,
    input  wire [31:0] ram_dmafifo_data,
    output reg         ram_dmafifo_read,

    // psram32 command port, clk_sys
    output wire        cmd_valid,
    input  wire        cmd_ready,
    output wire        cmd_we,
    output wire        cmd_cfg,
    output wire [22:0] cmd_addr,
    output wire [4:0]  cmd_len,
    output wire [31:0] cmd_wdata,
    output wire [3:0]  cmd_be,
    input  wire        rd_valid,
    input  wire [31:0] rd_data,
    input  wire        done,

    // loader write port, clk_sys (highest priority)
    input  wire        ld_valid,
    output wire        ld_ready,
    input  wire [22:0] ld_addr,             // word address
    input  wire [31:0] ld_data,

    // debug counters, clk1x
    output reg  [15:0] dbg_req,
    output reg  [15:0] dbg_fill,
    output reg  [15:0] dbg_dmaw
);
    // per-domain reset: asserted asynchronously, released synchronously
    reg [1:0] rr1 = 2'b11, rr3 = 2'b11, rrs = 2'b11;
    always @(posedge clk1x  or posedge rst) if (rst) rr1 <= 2'b11; else rr1 <= {rr1[0], 1'b0};
    always @(posedge clk3x  or posedge rst) if (rst) rr3 <= 2'b11; else rr3 <= {rr3[0], 1'b0};
    always @(posedge clk_sys or posedge rst) if (rst) rrs <= 2'b11; else rrs <= {rrs[0], 1'b0};
    wire rst1 = rr1[1], rst3 = rr3[1], rsts = rrs[1];

    // ---------------------------------------------------------------- toggles
    reg req_t, acc_t, rsp_t, rack_t, rpa_t, dw_t;      // clk1x->sys: req, rack, rpa; sys->clk1x: acc, rsp, dw
    reg cf_t, cfd_t, h_t, hack_t;                      // sys->clk3x: cf, hack; clk3x->clk1x: cfd; clk3x->sys: h
    wire req_s, acc_s, rsp_s, rack_s, rpa_s, dw_s, cf_s, cfd_s, h_s, hack_s, fe_s;
    ram_sync s_req  (clk_sys, req_t,  req_s);
    ram_sync s_rack (clk_sys, rack_t, rack_s);
    ram_sync s_rpa  (clk_sys, rpa_t,  rpa_s);
    ram_sync s_h    (clk_sys, h_t,    h_s);
    ram_sync s_fe   (clk_sys, ram_dmafifo_empty, fe_s);
    ram_sync s_acc  (clk1x,   acc_t,  acc_s);
    ram_sync s_rsp  (clk1x,   rsp_t,  rsp_s);
    ram_sync s_dw   (clk1x,   dw_t,   dw_s);
    ram_sync s_cfd  (clk1x,   cfd_t,  cfd_s);
    ram_sync s_cf   (clk3x,   cf_t,   cf_s);
    ram_sync s_hack (clk3x,   hack_t, hack_s);

    // ---------------------------------------------------------------- response data (written in clk_sys)
    reg [31:0] r_w0, r_w1, r_w2, r_w3;
    reg [1:0]  r_kind;                  // 1 plain read, 2 icache fill, 3 DMA read
    reg [1:0]  r_cnt;                   // words - 1
    reg [1:0]  r_sw;                    // first line word of a fill
    reg [7:0]  r_ca;                    // icache line index
    function [31:0] rw (input [1:0] i, input [31:0] a, b, c, d);
        rw = i[1] ? (i[0] ? d : c) : (i[0] ? b : a);
    endfunction

    // ================================================================ clk1x
    reg [24:0] cap_adr;
    reg [31:0] cap_wdata;
    reg [3:0]  cap_be;
    reg        cap_rnw, cap_dma, cap_cache;
    reg [1:0]  cap_cnt;
    reg        acc_q, rsp_q, cfd_q, dw_q;
    reg        emit;
    reg [1:0]  em_i;

    always @(posedge clk1x) begin
        acc_q <= acc_s; rsp_q <= rsp_s; cfd_q <= cfd_s; dw_q <= dw_s;
        ram_done <= 1'b0; dma_reqprocessed <= 1'b0; dma_wr <= 1'b0;
        if (rst1) begin
            req_t <= 1'b0; rack_t <= 1'b0; rpa_t <= 1'b0; emit <= 1'b0;
            dbg_req <= 16'd0; dbg_fill <= 16'd0; dbg_dmaw <= 16'd0;
        end else begin
            if (ram_ena) begin
                cap_adr <= ram_Adr; cap_wdata <= ram_dataWrite; cap_be <= ram_be; cap_rnw <= ram_rnw;
                cap_dma <= ram_dma; cap_cache <= ram_cache; cap_cnt <= ram_cntDMA;
                req_t <= ~req_t;
                dbg_req <= dbg_req + 1'b1;
                if (ram_rnw && ram_cache && !ram_dma) dbg_fill <= dbg_fill + 1'b1;
            end
            if (dw_s != dw_q) dbg_dmaw <= dbg_dmaw + 1'b1;
            // accepted by the sys side: a write is acknowledged, a DMA read is "processed"
            if (acc_s != acc_q) begin
                if (!cap_rnw) ram_done <= 1'b1;
                else if (cap_dma) begin dma_reqprocessed <= 1'b1; rpa_t <= ~rpa_t; end
            end
            // plain read data, or the start of a DMA burst
            if (rsp_s != rsp_q) begin
                if (r_kind == 2'd3) begin emit <= 1'b1; em_i <= 2'd0; end
                else begin ram_dataRead32 <= r_w0; ram_done <= 1'b1; rack_t <= ~rack_t; end
            end
            // icache fill: every cache write has happened in clk3x
            if (cfd_s != cfd_q) begin ram_dataRead32 <= r_w0; ram_done <= 1'b1; rack_t <= ~rack_t; end
            // DMA words on consecutive cycles
            if (emit) begin
                dma_wr <= 1'b1; dma_data <= rw(em_i, r_w0, r_w1, r_w2, r_w3);
                em_i <= em_i + 1'b1;
                if (em_i == r_cnt) begin emit <= 1'b0; rack_t <= ~rack_t; end
            end
        end
    end

    // ================================================================ clk3x
    reg        cf_q, hack_q, h_full, cs_run, cs_fin;
    reg [1:0]  fs, cs_i;
    reg [22:0] h_adr;
    reg [31:0] h_data;

    always @(posedge clk3x) begin
        cf_q <= cf_s; hack_q <= hack_s;
        ram_dmafifo_read <= 1'b0; cache_wr <= 4'd0;
        if (rst3) begin
            h_t <= 1'b0; cfd_t <= 1'b0; h_full <= 1'b0; fs <= 2'd0; cs_run <= 1'b0; cs_fin <= 1'b0;
        end else begin
            // DMA FIFO head -> hold regs, one entry at a time; the FIFO is read after the copy
            if (hack_s != hack_q) h_full <= 1'b0;
            case (fs)
                2'd0: if (!ram_dmafifo_empty && !h_full) begin
                    h_adr <= ram_dmafifo_adr; h_data <= ram_dmafifo_data;
                    ram_dmafifo_read <= 1'b1; h_full <= 1'b1; h_t <= ~h_t; fs <= 2'd1;
                end
                2'd1: fs <= 2'd2;       // the FIFO takes the read this cycle
                2'd2: fs <= 2'd0;       // and its empty flag has settled
                default: fs <= 2'd0;
            endcase
            // icache fill words
            if (cf_s != cf_q) begin cs_run <= 1'b1; cs_i <= 2'd0; end
            if (cs_run) begin
                cache_wr   <= 4'b0001 << (r_sw + cs_i);
                cache_data <= rw(cs_i, r_w0, r_w1, r_w2, r_w3);
                cache_addr <= r_ca;
                cs_i <= cs_i + 1'b1;
                if (cs_i == r_cnt) begin cs_run <= 1'b0; cs_fin <= 1'b1; end
            end
            if (cs_fin) begin cs_fin <= 1'b0; cfd_t <= ~cfd_t; end
        end
    end

    // ================================================================ clk_sys
    reg        st;                      // 0 idle, 1 command running
    reg [2:0]  a_kind;                  // running command: 0 write, 1 plain, 2 fill, 3 DMA
    reg [1:0]  wcnt;
    reg        resp_pend, rsp_busy, rp_wait;
    reg        req_seen, h_seen, rack_q, rpa_q;

    wire req_pend = (req_s != req_seen);
    wire h_pend   = (h_s != h_seen);
    wire sel_ld   = ld_valid;
    wire sel_f    = !ld_valid && h_pend;
    wire sel_r    = !ld_valid && !h_pend && fe_s && req_pend && !rsp_busy && !resp_pend;
    assign cmd_valid = (st == 1'b0) && (sel_ld || sel_f || sel_r);
    wire   accept    = cmd_valid && cmd_ready;
    assign ld_ready  = (st == 1'b0) && cmd_ready;

    // a fill reads to the end of its 16-byte line
    wire [2:0] fill_len = 3'd4 - {1'b0, cap_adr[3:2]};
    wire [4:0] req_len  = !cap_rnw ? 5'd1 : cap_dma ? {3'd0, cap_cnt} + 5'd1 : cap_cache ? {2'd0, fill_len} : 5'd1;

    assign cmd_cfg   = 1'b0;
    assign cmd_we    = sel_ld | sel_f | !cap_rnw;
    assign cmd_addr  = sel_ld ? ld_addr : sel_f ? {2'b00, h_adr[22:2]} : cap_adr[24:2];
    assign cmd_len   = (sel_ld | sel_f) ? 5'd1 : req_len;
    assign cmd_wdata = sel_ld ? ld_data : sel_f ? h_data : cap_wdata;
    assign cmd_be    = (sel_ld | sel_f) ? 4'hF : cap_be;

    always @(posedge clk_sys) begin
        rack_q <= rack_s; rpa_q <= rpa_s;
        if (rsts) begin
            st <= 1'b0; acc_t <= 1'b0; rsp_t <= 1'b0; dw_t <= 1'b0; cf_t <= 1'b0; hack_t <= 1'b0;
            req_seen <= 1'b0; h_seen <= 1'b0; resp_pend <= 1'b0; rsp_busy <= 1'b0; rp_wait <= 1'b0;
        end else begin
            if (rack_s != rack_q) rsp_busy <= 1'b0;
            if (rpa_s != rpa_q)   rp_wait  <= 1'b0;

            if (accept) begin
                st <= 1'b1; wcnt <= 2'd0;
                a_kind <= 3'd0;
                if (sel_f) begin
                    h_seen <= h_s; hack_t <= ~hack_t; dw_t <= ~dw_t;
                end else if (sel_r) begin
                    req_seen <= req_s; acc_t <= ~acc_t;
                    if (cap_rnw) begin
                        r_cnt <= cap_dma ? cap_cnt : cap_cache ? (2'd3 - cap_adr[3:2]) : 2'd0;
                        r_sw  <= cap_adr[3:2]; r_ca <= cap_adr[11:4];
                        r_kind <= cap_dma ? 2'd3 : cap_cache ? 2'd2 : 2'd1;
                        a_kind <= cap_dma ? 3'd3 : cap_cache ? 3'd2 : 3'd1;
                        if (cap_dma) rp_wait <= 1'b1;
                    end
                end
            end

            if (st && rd_valid) begin
                case (wcnt)
                    2'd0: r_w0 <= rd_data;
                    2'd1: r_w1 <= rd_data;
                    2'd2: r_w2 <= rd_data;
                    default: r_w3 <= rd_data;
                endcase
                wcnt <= wcnt + 1'b1;
                if (a_kind != 3'd0 && wcnt == r_cnt) resp_pend <= 1'b1;
            end
            if (st && done) st <= 1'b0;

            // send the response once the last word is in (a DMA burst only after dma_reqprocessed)
            if (resp_pend && !rp_wait) begin
                resp_pend <= 1'b0; rsp_busy <= 1'b1;
                if (r_kind == 2'd2) cf_t <= ~cf_t; else rsp_t <= ~rsp_t;
            end
        end
    end
endmodule
