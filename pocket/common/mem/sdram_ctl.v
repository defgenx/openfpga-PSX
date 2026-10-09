// SDRAM controller for the Pocket's AS4C32M16SB: BL4, CL3, open-page, 4 banks.
// One request is decoded while the previous burst is still on the bus.
// Every datasheet timing is a cycle count from sdram_timing.vh (selected in mem_defs.vh);
// timing, byte enables, the pin and capture pipeline stages and the read-data alignment are
// explained in docs/pocket/MEMTEST.md; the calibrated read capture (sdram_cal.v) in its "Calibration contract".
`include "mem_defs.vh"
module sdram_ctl #(
    parameter CL          = `SDT_CL,
    parameter BL          = `SDT_BL,      // the 64-bit request port is four 16-bit beats
    parameter INIT_CYCLES = `MT_SD_INIT,
    parameter REF_CYCLES  = `MT_SD_REF,
    parameter T_RCD = `MT_SD_TRCD,
    parameter T_RP  = `MT_SD_TRP,
    parameter T_RAS = `MT_SD_TRAS,
    parameter T_RC  = `MT_SD_TRC,
    parameter T_RFC = `MT_SD_TRFC,
    parameter T_WR  = `MT_SD_TWR,
    parameter T_RRD = `MT_SD_TRRD,
    parameter T_MRD = `MT_SD_TMRD
) (
    input  wire        clk,
    input  wire        clk_cap,        // read data is captured here: a PLL output whose phase sdram_cal moves
    input  wire        rst,
    output wire        init_done,      // initialised and the capture phase calibrated

    // request: word address (16-bit words), burst of four words, in-order
    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_we,
    input  wire [24:0] req_addr,
    input  wire [63:0] req_wdata,
    input  wire [7:0]  req_be,         // write byte enables, bit 2k+j = byte j of word k; a clear bit is masked by DQM
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
    output reg         dram_we_n,

    // calibrated read capture (sdram_cal.v)
    input  wire        pll_locked,     // PLL lock, clk domain
    input  wire        cal_tick,       // one pulse per tracking window (vblank)
    input  wire        clk_scan,       // PLL scanclk, a related clock <= 100 MHz
    output wire        ps_en,          // PLL phase_en, clk_scan domain
    output wire        ps_up,          // PLL updn: 1 delays clk_cap by one step
    input  wire        ps_done,        // PLL phase_done, clk_scan domain
    output wire        cal_done,
    output wire        cal_ok,         // eye at least MT_CAL_EYE_MIN steps wide
    output wire [6:0]  cal_width,
    output wire [6:0]  cal_boot,       // centre chosen by the boot sweep
    output wire [6:0]  cal_centre,
    output wire [6:0]  cal_min,        // lowest and highest centre since the boot sweep
    output wire [6:0]  cal_max,
    output wire [15:0] cal_moves,
    output wire [3:0]  cal_flags
);

    localparam S_INIT = 4'd0, S_PREALL = 4'd1, S_WAIT = 4'd2, S_REF = 4'd3, S_MRS = 4'd4,
               S_RUN = 4'd5, S_RPRE = 4'd6, S_RREF = 4'd7;

    // {ras_n, cas_n, we_n}
    localparam [2:0] C_NOP = 3'b111, C_ACT = 3'b011, C_RD = 3'b101, C_WR = 3'b100,
                     C_PRE = 3'b010, C_REF = 3'b001, C_MRS = 3'b000;

    // mode register: A[6:4] CL, A[3] sequential, A[2:0] burst length code
    localparam [2:0] BL_CODE = (BL == 1) ? 3'd0 : (BL == 2) ? 3'd1 : (BL == 4) ? 3'd2 : 3'd3;
    localparam [12:0] MODE_REG = {6'b000000, CL[2:0], 1'b0, BL_CODE};
    // command-to-command spacing, in cycles, from the burst length and CL (docs/pocket/MEMTEST.md)
    localparam [3:0] COL_GAP    = BL;              // CAS to CAS
    localparam [3:0] RD_TO_WR   = CL + BL + 2;     // read CAS to write CAS: no overlap with read data on the bus
    localparam [3:0] RD_TO_PRE  = BL;              // read CAS to PRECHARGE
    localparam [3:0] WR_TO_PRE  = BL - 1 + T_WR;   // write CAS to PRECHARGE: last beat, then tWR
    // One register stage between the decision logic and the I/O-cell registers of the pins, and two between the
    // capture registers in the I/O cells and the system clock (the second sits next to the transfer to the system
    // clock): the routing between I/O cells and the core takes several ns, so neither side can have logic in front of
    // or behind its I/O register at 135 MHz.
    localparam LAT = CL + 3 + 1 + 1 + 1;           // decision to registered read data, in cycles
    localparam RDV_LAST = LAT + BL - 1;            // rdv/tagd tap of the last beat

    reg        init_core;
    reg [3:0]  state, nstate;
    reg [15:0] wcnt;
    reg [3:0]  icnt;

    // current request
    reg        cur_valid, cur_we, cur_tag;
    reg [12:0] cur_row;
    reg [1:0]  cur_bank;
    reg [9:0]  cur_col;
    reg [63:0] cur_wdata;
    reg [7:0]  cur_be;

    // per-bank state
    reg [3:0]  open;
    reg [12:0] orow0, orow1, orow2, orow3;
    reg [3:0]  rcd0, rcd1, rcd2, rcd3;      // cycles until a column command is allowed
    reg [3:0]  pre0, pre1, pre2, pre3;      // cycles until precharge is allowed
    reg [3:0]  rp0, rp1, rp2, rp3;          // cycles until activate is allowed (after precharge)
    reg [3:0]  rc0, rc1, rc2, rc3;          // cycles until activate is allowed (tRC since the last activate)
    reg [3:0]  rrd, rd_ok, wr_ok;

    reg [15:0] ref_cnt;
    reg        ref_due;

    // data bus
    reg [15:0] dq_out;
    reg        dq_oe;
    reg [31:0] wsh;                         // beats 2 and 3 of a write burst
    reg [3:0]  bsh;                         // their byte enables
    reg [1:0]  wleft;
    reg [15:0] dq_cap, dq_cap2, dq_cap3;
    reg [15:0] dq_r;
    // pin register stage (the pins themselves are loaded from these, one cycle later)
    reg [2:0]  cmd_p;
    reg [12:0] a_p;
    reg [1:0]  ba_p, dqm_p;
    reg [15:0] dq_out_p;
    reg        dq_oe_p;
    reg [RDV_LAST:0] rdv;
    reg [RDV_LAST:0] tagd;
    reg [63:0] sh;
    reg        rv_cal;

    // Request port: the calibration borrows it (own) with the other requesters held off (hold).
    wire        cal_own, cal_hold, cq_valid, cq_we;
    wire [24:0] cq_addr;
    wire [63:0] cq_wdata;
    wire        rq_ready = (state == S_RUN) && !cur_valid && !ref_due;
    wire        rq_valid = cal_own ? cq_valid : (req_valid && !cal_hold);
    wire        rq_we    = cal_own ? cq_we : req_we;
    wire [24:0] rq_addr  = cal_own ? cq_addr : req_addr;
    wire [63:0] rq_wdata = cal_own ? cq_wdata : req_wdata;
    wire [7:0]  rq_be    = cal_own ? 8'hFF : req_be;
    wire        rq_tag   = cal_own ? 1'b0 : req_tag;
    assign req_ready = rq_ready && !cal_own && !cal_hold;
    assign init_done = init_core && cal_done;

    assign dram_dq = dq_oe ? dq_out : 16'hzzzz;
    always @(posedge clk_cap) begin
        dq_cap  <= dram_dq;      // in the I/O cell
        dq_cap2 <= dq_cap;       // in the fabric, same clock, next to the I/O cell
        dq_cap3 <= dq_cap2;      // same clock, next to dq_r: crosses to clk next
    end

    // The current request's bank state: its open row is compared once, when the request is accepted, and the
    // flags follow the request's own PRECHARGE and ACTIVATE (nothing else touches its bank while it is pending).
    reg         hit_open, row_hit;
    // Timing flags, registered: "this counter is 0 in this cycle", computed one cycle ahead from counter <= 1.
    // A flag is stale in the cycle after a command loads its counter, so no command is decided in that cycle (blk);
    // commands of one request are at least 3 cycles apart, so nothing is lost.
    reg  [3:0]  rcd_ok, pre_ok, rp_ok, rc_ok;
    reg         rrd_ok, rd_ok_f, wr_ok_f, blk;
    reg         acc_open;
    reg  [12:0] acc_orow;
    always @(*) begin
        case (rq_addr[11:10])
            2'd0: begin acc_open = open[0]; acc_orow = orow0; end
            2'd1: begin acc_open = open[1]; acc_orow = orow1; end
            2'd2: begin acc_open = open[2]; acc_orow = orow2; end
            default: begin acc_open = open[3]; acc_orow = orow3; end
        endcase
    end


    wire win = |rdv[LAT +: BL];      // the beats of a burst reach dq_r in these cycles

    wire do_cas    = (state == S_RUN) && cur_valid && !blk && row_hit && rcd_ok[cur_bank] && (cur_we ? wr_ok_f : rd_ok_f);
    wire do_pre    = (state == S_RUN) && cur_valid && !blk && hit_open && !row_hit && pre_ok[cur_bank];
    wire do_act    = (state == S_RUN) && cur_valid && !blk && !hit_open && rp_ok[cur_bank] && rc_ok[cur_bank] && rrd_ok;
    wire all_pre_ok = (&pre_ok) && !blk;     // every PRECHARGE timer is 0 (the flags are stale in the cycle after a command)

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
    reg [1:0]  dqm_n;
    always @(*) begin
        cmd_n = C_NOP; ba_n = cur_bank;
        a_n = row_hit ? {3'b000, cur_col} : cur_row;
        case (state)
            S_PREALL: begin cmd_n = C_PRE; a_n = 13'h0400; end
            S_REF, S_RREF: cmd_n = C_REF;
            S_MRS: begin cmd_n = C_MRS; a_n = MODE_REG; ba_n = 2'd0; end    // BL4, sequential, CL3, burst writes
            S_RPRE: if (all_pre_ok && wleft == 0) begin cmd_n = C_PRE; a_n = 13'h0400; end
            S_RUN: begin
                if (do_cas) cmd_n = cur_we ? C_WR : C_RD;
                if (do_pre) cmd_n = C_PRE;
                if (do_act) cmd_n = C_ACT;
            end
            default: ;
        endcase
        // beat 0 leaves with the WRITE decision, beat 1 one cycle later straight from the request (still intact:
        // the next request is accepted at the end of that cycle), beats 2 and 3 from wsh, loaded in that cycle
        dq_out_n = (wleft == 2'd3) ? cur_wdata[31:16] : (wleft != 0) ? wsh[15:0] : cur_wdata[15:0];
        dq_oe_n  = issue_wr | (wleft != 0);
        // DQM has write latency 0 (same beat as the data) and is low for every read beat
        dqm_n    = (wleft == 2'd3) ? ~cur_be[3:2] : (wleft != 0) ? ~bsh[1:0] : issue_wr ? ~cur_be[1:0] : 2'b00;
    end

    always @(posedge clk) begin
        dqm_p    <= dqm_n;
        cmd_p    <= cmd_n;
        a_p      <= a_n;
        ba_p     <= ba_n;
        dq_out_p <= dq_out_n;
        dq_oe_p  <= dq_oe_n;
        dram_dqm <= dqm_p;
        {dram_ras_n, dram_cas_n, dram_we_n} <= cmd_p;
        dram_a   <= a_p;
        dram_ba  <= ba_p;
        dq_out   <= dq_out_p;
        dq_oe    <= dq_oe_p;
        rd_valid <= 1'b0;
        rv_cal   <= 1'b0;

        // read return
        dq_r <= dq_cap3;
        rdv  <= {rdv[RDV_LAST-1:0], issue_rd};
        tagd <= {tagd[RDV_LAST-1:0], issue_rd & cur_tag};
        if (win) sh <= {dq_r, sh[63:16]};
        rd_valid <= rdv[RDV_LAST] & ~cal_own;      // the calibration's own reads do not reach the requesters
        rv_cal   <= rdv[RDV_LAST];
        rd_data  <= {dq_r, sh[63:16]};
        rd_tag   <= tagd[RDV_LAST];

        // counters and their flags
        blk <= do_cas | do_pre | do_act;
        rcd_ok <= {rcd3 <= 1, rcd2 <= 1, rcd1 <= 1, rcd0 <= 1};
        pre_ok <= {pre3 <= 1, pre2 <= 1, pre1 <= 1, pre0 <= 1};
        rp_ok  <= {rp3 <= 1, rp2 <= 1, rp1 <= 1, rp0 <= 1};
        rc_ok  <= {rc3 <= 1, rc2 <= 1, rc1 <= 1, rc0 <= 1};
        rrd_ok <= rrd <= 1; rd_ok_f <= rd_ok <= 1; wr_ok_f <= wr_ok <= 1;
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
        if (rc0 != 0) rc0 <= rc0 - 1'b1;
        if (rc1 != 0) rc1 <= rc1 - 1'b1;
        if (rc2 != 0) rc2 <= rc2 - 1'b1;
        if (rc3 != 0) rc3 <= rc3 - 1'b1;
        if (rrd != 0) rrd <= rrd - 1'b1;
        if (rd_ok != 0) rd_ok <= rd_ok - 1'b1;
        if (wr_ok != 0) wr_ok <= wr_ok - 1'b1;

        // write data
        if (issue_wr) wleft <= BL - 1;
        else if (wleft != 0) wleft <= wleft - 1'b1;
        if (wleft == 2'd3) begin
            wsh <= cur_wdata[63:32]; bsh <= cur_be[7:4];
        end else begin
            wsh <= {16'd0, wsh[31:16]}; bsh <= {2'b00, bsh[3:2]};
        end

        // refresh timer
        ref_cnt <= ref_cnt + 1'b1;
        if (ref_cnt >= REF_CYCLES - 1) ref_due <= 1'b1;

        if (rst) begin
            state <= S_INIT; wcnt <= 16'd0; icnt <= 4'd0; init_core <= 1'b0;
            cur_valid <= 1'b0; open <= 4'd0; ref_cnt <= 16'd0; ref_due <= 1'b0;
            rcd0 <= 0; rcd1 <= 0; rcd2 <= 0; rcd3 <= 0;
            pre0 <= 0; pre1 <= 0; pre2 <= 0; pre3 <= 0;
            rp0 <= 0; rp1 <= 0; rp2 <= 0; rp3 <= 0;
            rc0 <= 0; rc1 <= 0; rc2 <= 0; rc3 <= 0;
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
                    init_core <= 1'b1;
                    ref_cnt <= 16'd0; ref_due <= 1'b0;
                end
                S_RUN: begin
                    if (rq_valid && rq_ready) begin
                        cur_valid <= 1'b1; cur_we <= rq_we; cur_tag <= rq_tag;
                        cur_row <= rq_addr[24:12]; cur_bank <= rq_addr[11:10];
                        cur_col <= {rq_addr[9:2], 2'b00}; cur_wdata <= rq_wdata; cur_be <= rq_be;
                        hit_open <= acc_open; row_hit <= acc_open && (acc_orow == rq_addr[24:12]);
                    end
                    if (do_cas) begin
                        cur_valid <= 1'b0;
                        // the counters hold (cycles to wait) - 1
                        if (cur_we) begin
                            rd_ok <= COL_GAP - 1; wr_ok <= COL_GAP - 1;
                            case (cur_bank)
                                2'd0: pre0 <= WR_TO_PRE;
                                2'd1: pre1 <= WR_TO_PRE;
                                2'd2: pre2 <= WR_TO_PRE;
                                default: pre3 <= WR_TO_PRE;
                            endcase
                        end else begin
                            rd_ok <= COL_GAP - 1; wr_ok <= RD_TO_WR - 1;
                            case (cur_bank)
                                2'd0: if (pre0 < RD_TO_PRE) pre0 <= RD_TO_PRE;
                                2'd1: if (pre1 < RD_TO_PRE) pre1 <= RD_TO_PRE;
                                2'd2: if (pre2 < RD_TO_PRE) pre2 <= RD_TO_PRE;
                                default: if (pre3 < RD_TO_PRE) pre3 <= RD_TO_PRE;
                            endcase
                        end
                    end
                    if (do_pre) begin
                        open[cur_bank] <= 1'b0; hit_open <= 1'b0; row_hit <= 1'b0;
                        case (cur_bank)
                            2'd0: rp0 <= T_RP - 1;
                            2'd1: rp1 <= T_RP - 1;
                            2'd2: rp2 <= T_RP - 1;
                            default: rp3 <= T_RP - 1;
                        endcase
                    end
                    if (do_act) begin
                        open[cur_bank] <= 1'b1; hit_open <= 1'b1; row_hit <= 1'b1;
                        rrd <= T_RRD - 1;
                        case (cur_bank)
                            2'd0: begin orow0 <= cur_row; rcd0 <= T_RCD - 1; pre0 <= T_RAS - 1; rc0 <= T_RC - 1; end
                            2'd1: begin orow1 <= cur_row; rcd1 <= T_RCD - 1; pre1 <= T_RAS - 1; rc1 <= T_RC - 1; end
                            2'd2: begin orow2 <= cur_row; rcd2 <= T_RCD - 1; pre2 <= T_RAS - 1; rc2 <= T_RC - 1; end
                            default: begin orow3 <= cur_row; rcd3 <= T_RCD - 1; pre3 <= T_RAS - 1; rc3 <= T_RC - 1; end
                        endcase
                    end
                    if (ref_due && !cur_valid && !(rq_valid && rq_ready)) state <= S_RPRE;
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

    // No request pending and no read between the READ command and the registered read data: the capture phase may move.
    wire quiet = !cur_valid && (rdv == 0) && !rv_cal;

    sdram_cal cal (
        .clk(clk), .rst(rst), .pll_locked(pll_locked), .ctl_ready(init_core), .quiet(quiet),
        .own(cal_own), .hold(cal_hold), .q_valid(cq_valid), .q_we(cq_we), .q_addr(cq_addr), .q_wdata(cq_wdata),
        .q_ready(rq_ready && cal_own), .rd_valid(rv_cal), .rd_data(rd_data),
        .tick(cal_tick), .done(cal_done), .ok(cal_ok), .width(cal_width), .boot_c(cal_boot), .centre(cal_centre),
        .cmin(cal_min), .cmax(cal_max), .moves(cal_moves), .flags(cal_flags),
        .clk_scan(clk_scan), .ps_en(ps_en), .ps_up(ps_up), .ps_done(ps_done)
    );

endmodule
