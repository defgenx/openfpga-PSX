// SDRAM controller for the Pocket's AS4C32M16SB: BL4, CL3, open-page, 4 banks.
// One request is decoded while the previous burst is still on the bus.
// Timing constants and the read-data alignment are explained in docs/pocket/MEMTEST.md.
module sdram_ctl #(
    parameter CL          = 3,
    parameter INIT_CYCLES = 20600,   // > 200 us at 101.6 MHz
    parameter REF_CYCLES  = 700,     // one auto refresh per 6.9 us (8192 rows in 64 ms)
    parameter T_RCD = 3,
    parameter T_RP  = 3,
    parameter T_RAS = 5,
    parameter T_RFC = 8,
    parameter T_WR  = 3,
    parameter T_RRD = 2,
    parameter T_MRD = 3
) (
    input  wire        clk,
    input  wire        clk_cap,        // clk delayed by half a period: read data is captured here
    input  wire        rst,
    output reg         init_done,

    // request: word address (16-bit words), burst of four words, in-order
    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_we,
    input  wire [24:0] req_addr,
    input  wire [63:0] req_wdata,
    input  wire        req_tag,

    // read return, one pulse per burst, in request order
    output reg         rd_valid,
    output reg  [63:0] rd_data,
    output reg         rd_tag,

    // SDRAM pins (chip select is tied low on the Pocket)
    output reg  [12:0] dram_a,
    output reg  [1:0]  dram_ba,
    inout  wire [15:0] dram_dq,
    output reg  [1:0]  dram_dqm,
    output reg         dram_ras_n,
    output reg         dram_cas_n,
    output reg         dram_we_n
);

    localparam S_INIT = 4'd0, S_PREALL = 4'd1, S_WAIT = 4'd2, S_REF = 4'd3, S_MRS = 4'd4,
               S_RUN = 4'd5, S_RPRE = 4'd6, S_RREF = 4'd7;

    // {ras_n, cas_n, we_n}
    localparam [2:0] C_NOP = 3'b111, C_ACT = 3'b011, C_RD = 3'b101, C_WR = 3'b100,
                     C_PRE = 3'b010, C_REF = 3'b001, C_MRS = 3'b000;

    reg [3:0]  state, nstate;
    reg [15:0] wcnt;
    reg [3:0]  icnt;

    // current request
    reg        cur_valid, cur_we, cur_tag;
    reg [12:0] cur_row;
    reg [1:0]  cur_bank;
    reg [9:0]  cur_col;
    reg [63:0] cur_wdata;

    // per-bank state
    reg [3:0]  open;
    reg [12:0] orow0, orow1, orow2, orow3;
    reg [3:0]  rcd0, rcd1, rcd2, rcd3;      // cycles until a column command is allowed
    reg [3:0]  pre0, pre1, pre2, pre3;      // cycles until precharge is allowed
    reg [3:0]  rp0, rp1, rp2, rp3;          // cycles until activate is allowed
    reg [3:0]  rrd, rd_ok, wr_ok;

    reg [15:0] ref_cnt;
    reg        ref_due;

    // data bus
    reg [15:0] dq_out;
    reg        dq_oe;
    reg [47:0] wsh;
    reg [1:0]  wleft;
    reg [15:0] dq_cap;
    reg [15:0] dq_r;
    reg [CL+6:0] rdv;
    reg [CL+6:0] tagd;
    reg [63:0] sh;

    assign dram_dq = dq_oe ? dq_out : 16'hzzzz;
    always @(posedge clk_cap) dq_cap <= dram_dq;

    wire [3:0]  b_open = open;
    wire        hit_open = open[cur_bank];
    reg  [12:0] b_orow;
    reg  [3:0]  b_rcd, b_pre, b_rp;
    always @(*) begin
        case (cur_bank)
            2'd0: begin b_orow = orow0; b_rcd = rcd0; b_pre = pre0; b_rp = rp0; end
            2'd1: begin b_orow = orow1; b_rcd = rcd1; b_pre = pre1; b_rp = rp1; end
            2'd2: begin b_orow = orow2; b_rcd = rcd2; b_pre = pre2; b_rp = rp2; end
            default: begin b_orow = orow3; b_rcd = rcd3; b_pre = pre3; b_rp = rp3; end
        endcase
    end

    assign req_ready = (state == S_RUN) && !cur_valid && !ref_due;

    wire win = rdv[CL+3] | rdv[CL+4] | rdv[CL+5] | rdv[CL+6];

    wire row_hit   = hit_open && (b_orow == cur_row);
    wire do_cas    = (state == S_RUN) && cur_valid && row_hit && (b_rcd == 0) && (cur_we ? (wr_ok == 0) : (rd_ok == 0));
    wire do_pre    = (state == S_RUN) && cur_valid && hit_open && !row_hit && (b_pre == 0);
    wire do_act    = (state == S_RUN) && cur_valid && !hit_open && (b_rp == 0) && (rrd == 0);
    wire all_pre_ok = (pre0 == 0) && (pre1 == 0) && (pre2 == 0) && (pre3 == 0);

    wire issue_rd = do_cas && !cur_we;
    wire issue_wr = do_cas && cur_we;

    // Command, address and data pins are plain registers loaded every cycle from these next
    // values, so the fitter can place them in the I/O cells. Address and data do not depend on
    // the command decision: they are don't-care whenever the command is a NOP.
    reg [2:0]  cmd_n;
    reg [12:0] a_n;
    reg [1:0]  ba_n;
    reg [15:0] dq_out_n;
    reg        dq_oe_n;
    always @(*) begin
        cmd_n = C_NOP; ba_n = cur_bank;
        a_n = row_hit ? {3'b000, cur_col} : cur_row;
        case (state)
            S_PREALL: begin cmd_n = C_PRE; a_n = 13'h0400; end
            S_REF, S_RREF: cmd_n = C_REF;
            S_MRS: begin cmd_n = C_MRS; a_n = 13'h0032; ba_n = 2'd0; end    // BL4, sequential, CL3, burst writes
            S_RPRE: if (all_pre_ok && wleft == 0) begin cmd_n = C_PRE; a_n = 13'h0400; end
            S_RUN: begin
                if (do_cas) cmd_n = cur_we ? C_WR : C_RD;
                if (do_pre) cmd_n = C_PRE;
                if (do_act) cmd_n = C_ACT;
            end
            default: ;
        endcase
        dq_out_n = (wleft != 0) ? wsh[15:0] : cur_wdata[15:0];
        dq_oe_n  = issue_wr | (wleft != 0);
    end

    always @(posedge clk) begin
        dram_dqm <= 2'b00;
        {dram_ras_n, dram_cas_n, dram_we_n} <= cmd_n;
        dram_a  <= a_n;
        dram_ba <= ba_n;
        dq_out  <= dq_out_n;
        dq_oe   <= dq_oe_n;
        rd_valid <= 1'b0;

        // read return
        dq_r <= dq_cap;
        rdv  <= {rdv[CL+5:0], issue_rd};
        tagd <= {tagd[CL+5:0], issue_rd & cur_tag};
        if (win) sh <= {dq_r, sh[63:16]};
        rd_valid <= rdv[CL+6];
        rd_data  <= {dq_r, sh[63:16]};
        rd_tag   <= tagd[CL+6];

        // counters
        if (rcd0 != 0) rcd0 <= rcd0 - 1'b1;
        if (rcd1 != 0) rcd1 <= rcd1 - 1'b1;
        if (rcd2 != 0) rcd2 <= rcd2 - 1'b1;
        if (rcd3 != 0) rcd3 <= rcd3 - 1'b1;
        if (pre0 != 0) pre0 <= pre0 - 1'b1;
        if (pre1 != 0) pre1 <= pre1 - 1'b1;
        if (pre2 != 0) pre2 <= pre2 - 1'b1;
        if (pre3 != 0) pre3 <= pre3 - 1'b1;
        if (rp0 != 0) rp0 <= rp0 - 1'b1;
        if (rp1 != 0) rp1 <= rp1 - 1'b1;
        if (rp2 != 0) rp2 <= rp2 - 1'b1;
        if (rp3 != 0) rp3 <= rp3 - 1'b1;
        if (rrd != 0) rrd <= rrd - 1'b1;
        if (rd_ok != 0) rd_ok <= rd_ok - 1'b1;
        if (wr_ok != 0) wr_ok <= wr_ok - 1'b1;

        // write data
        if (issue_wr) begin
            wsh    <= cur_wdata[63:16];
            wleft  <= 2'd3;
        end else if (wleft != 0) begin
            wsh    <= {16'd0, wsh[47:16]};
            wleft  <= wleft - 1'b1;
        end

        // refresh timer
        ref_cnt <= ref_cnt + 1'b1;
        if (ref_cnt >= REF_CYCLES - 1) ref_due <= 1'b1;

        if (rst) begin
            state <= S_INIT; wcnt <= 16'd0; icnt <= 4'd0; init_done <= 1'b0;
            cur_valid <= 1'b0; open <= 4'd0; ref_cnt <= 16'd0; ref_due <= 1'b0;
            rcd0 <= 0; rcd1 <= 0; rcd2 <= 0; rcd3 <= 0;
            pre0 <= 0; pre1 <= 0; pre2 <= 0; pre3 <= 0;
            rp0 <= 0; rp1 <= 0; rp2 <= 0; rp3 <= 0;
            rrd <= 0; rd_ok <= 0; wr_ok <= 0;
            wleft <= 2'd0; rdv <= 0; tagd <= 0;
        end else begin
            case (state)
                S_INIT: begin
                    wcnt <= wcnt + 1'b1;
                    if (wcnt == INIT_CYCLES) state <= S_PREALL;
                end
                S_PREALL: begin
                    wcnt <= T_RP - 2; nstate <= S_REF; state <= S_WAIT;
                end
                S_WAIT: begin
                    if (wcnt == 0) state <= nstate;
                    else wcnt <= wcnt - 1'b1;
                end
                S_REF: begin
                    icnt <= icnt + 1'b1;
                    wcnt <= T_RFC - 2; state <= S_WAIT;
                    nstate <= (icnt == 4'd7) ? S_MRS : S_REF;
                end
                S_MRS: begin
                    wcnt <= T_MRD - 2; nstate <= S_RUN; state <= S_WAIT;
                    init_done <= 1'b1;
                    ref_cnt <= 16'd0; ref_due <= 1'b0;
                end
                S_RUN: begin
                    if (req_valid && req_ready) begin
                        cur_valid <= 1'b1; cur_we <= req_we; cur_tag <= req_tag;
                        cur_row <= req_addr[24:12]; cur_bank <= req_addr[11:10];
                        cur_col <= {req_addr[9:2], 2'b00}; cur_wdata <= req_wdata;
                    end
                    if (do_cas) begin
                        cur_valid <= 1'b0;
                        if (cur_we) begin
                            rd_ok <= 4'd3; wr_ok <= 4'd3;
                            case (cur_bank)
                                2'd0: pre0 <= 4'd3 + T_WR;
                                2'd1: pre1 <= 4'd3 + T_WR;
                                2'd2: pre2 <= 4'd3 + T_WR;
                                default: pre3 <= 4'd3 + T_WR;
                            endcase
                        end else begin
                            rd_ok <= 4'd3; wr_ok <= CL + 5;   // bus turnaround: no overlap with the read data
                            case (cur_bank)
                                2'd0: if (pre0 < 4) pre0 <= 4'd4;
                                2'd1: if (pre1 < 4) pre1 <= 4'd4;
                                2'd2: if (pre2 < 4) pre2 <= 4'd4;
                                default: if (pre3 < 4) pre3 <= 4'd4;
                            endcase
                        end
                    end
                    if (do_pre) begin
                        open[cur_bank] <= 1'b0;
                        case (cur_bank)
                            2'd0: rp0 <= T_RP - 1;
                            2'd1: rp1 <= T_RP - 1;
                            2'd2: rp2 <= T_RP - 1;
                            default: rp3 <= T_RP - 1;
                        endcase
                    end
                    if (do_act) begin
                        open[cur_bank] <= 1'b1;
                        rrd <= T_RRD - 1;
                        case (cur_bank)
                            2'd0: begin orow0 <= cur_row; rcd0 <= T_RCD - 1; pre0 <= T_RAS - 1; end
                            2'd1: begin orow1 <= cur_row; rcd1 <= T_RCD - 1; pre1 <= T_RAS - 1; end
                            2'd2: begin orow2 <= cur_row; rcd2 <= T_RCD - 1; pre2 <= T_RAS - 1; end
                            default: begin orow3 <= cur_row; rcd3 <= T_RCD - 1; pre3 <= T_RAS - 1; end
                        endcase
                    end
                    if (ref_due && !cur_valid && !(req_valid && req_ready)) state <= S_RPRE;
                end
                S_RPRE: begin
                    if (all_pre_ok && wleft == 0) begin
                        open <= 4'd0;
                        wcnt <= T_RP - 2; nstate <= S_RREF; state <= S_WAIT;
                    end
                end
                S_RREF: begin
                    ref_cnt <= 16'd0; ref_due <= 1'b0;
                    wcnt <= T_RFC - 2; nstate <= S_RUN; state <= S_WAIT;
                end
                default: state <= S_INIT;
            endcase
        end
    end

endmodule
