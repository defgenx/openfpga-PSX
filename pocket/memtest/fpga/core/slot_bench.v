// APF bridge throughput bench, all on clk_74a. Reads a data slot with target_dataslot_read in 2,352-byte
// requests (N_REQ sequential, then N_REQ at random sector-aligned offsets), counts the bytes that land in
// the sink window and times every request. Method, window, result slots and assumptions:
// docs/pocket/MEMTEST.md, "Bridge throughput bench".
`include "memtest_defs.vh"
module slot_bench #(
    parameter N_REQ       = 256,
    parameter START_DELAY = 7425000,        // clk_74a cycles from reset release to the first request (0.1 s)
    parameter TIMEOUT     = 74250000,       // clk_74a cycles a request may take (1 s)
    parameter [15:0] SLOT_ID   = 16'd1,
    parameter [31:0] WIN       = 32'h20000000,   // sink window: bridge writes with this top byte are counted
    parameter [9:0]  SIZE_ADDR = 10'd1       // data table word that holds the size of the slot at table position 0
) (
    input  wire        clk,                 // clk_74a
    input  wire        reset_n,
    input  wire        go_tog,              // any change (re)starts the bench

    // bridge write bus (sink)
    input  wire        bridge_wr,
    input  wire [31:0] bridge_addr,

    // data table, read port A
    output wire [9:0]  dt_addr,
    input  wire [31:0] dt_q,

    // target command interface of core_bridge_cmd
    output reg         tgt_read,
    output reg  [15:0] tgt_id,
    output reg  [31:0] tgt_off,
    output reg  [31:0] tgt_baddr,
    output reg  [31:0] tgt_len,
    input  wire        tgt_ack,
    input  wire        tgt_done,
    input  wire [2:0]  tgt_err,

    // result writes towards the result store: a write is announced by a change of res_tog and held for 9 cycles
    output reg         res_tog,
    output reg  [6:0]  res_wa,
    output reg  [32:0] res_wd
);
    localparam [31:0] REQ = 32'd2352;
    localparam [4:0]  NRES = 5'd15;

    localparam [3:0] S_IDLE = 4'd0, S_DELAY = 4'd1, S_INIT = 4'd2, S_CLR = 4'd3, S_SIZE = 4'd4, S_NSEC = 4'd5,
                     S_OFF = 4'd6, S_ISSUE = 4'd7, S_HOLD = 4'd8, S_WAIT = 4'd9, S_GUARD = 4'd10, S_ACC = 4'd11,
                     S_CALC = 4'd12, S_WRITE = 4'd13, S_END = 4'd14;

    assign dt_addr = SIZE_ADDR;

    reg [31:0] now = 32'd0;
    always @(posedge clk) now <= now + 1'b1;

    // ---------------------------------------------------------------- sink
    reg        active = 1'b0;
    reg [31:0] rx = 32'd0, t_last = 32'd0;
    reg        got_last = 1'b0;
    wire       in_win = bridge_wr && (bridge_addr[31:24] == WIN[31:24]);
    reg [3:0]  st = S_IDLE;
    always @(posedge clk) begin
        if (st == S_ISSUE) begin rx <= 32'd0; got_last <= 1'b0; end
        else if (active && in_win) begin
            rx <= rx + 32'd4;
            if (!got_last && rx + 32'd4 >= REQ) begin got_last <= 1'b1; t_last <= now; end
        end
    end

    // ---------------------------------------------------------------- 64 / 32 divider, 64 cycles
    reg         d_start = 1'b0, d_run = 1'b0, d_done = 1'b0;
    reg  [63:0] d_num = 64'd0, d_n = 64'd0, d_q = 64'd0;
    reg  [31:0] d_den = 32'd0, d_d = 32'd0;
    reg  [32:0] d_r = 33'd0;
    reg  [6:0]  d_cnt = 7'd0;
    wire [32:0] d_sh = {d_r[31:0], d_n[63]};
    wire        d_ge = d_sh >= {1'b0, d_d};
    always @(posedge clk) begin
        d_done <= 1'b0;
        if (d_start) begin
            d_n <= d_num; d_d <= d_den; d_r <= 33'd0; d_q <= 64'd0; d_cnt <= 7'd0; d_run <= 1'b1;
        end else if (d_run) begin
            d_r <= d_ge ? d_sh - {1'b0, d_d} : d_sh;
            d_q <= {d_q[62:0], d_ge};
            d_n <= {d_n[62:0], 1'b0};
            d_cnt <= d_cnt + 1'b1;
            if (d_cnt == 7'd63) begin d_run <= 1'b0; d_done <= 1'b1; end
        end
    end
    wire [31:0] d_res = (d_d == 32'd0) ? 32'd0 : (d_q[63:32] != 32'd0) ? 32'hFFFFFFFF : d_q[31:0];

    // ---------------------------------------------------------------- run state
    reg        seen = 1'b0, armed = 1'b1, rerun = 1'b0, nofile = 1'b0, tmo = 1'b0, tmo_any = 1'b0, m = 1'b0;
    reg [31:0] dly = 32'd0, size = 32'd0, nsec = 32'd0, smask = 32'd0, idx = 32'd0, off = 32'd0;
    reg [31:0] rng = 32'd0, t_issue = 32'd0, t_done = 32'd0;
    reg [3:0]  hc = 4'd0, wi = 4'd0, wh = 4'd0;
    reg [2:0]  cs = 3'd0, err_l = 3'd0;
    reg        cph = 1'b0;
    reg [2:0]  code = 3'd0;
    // per mode, [31:0] sequential and [63:32] random
    reg [63:0] sum_done = 64'd0, rx_tot = 64'd0, w_last = 64'd0, w_done = 64'd0, bad = 64'd0, nreq = 64'd0;
    reg [191:0] r_q = 192'd0;       // six division results: kB/s, worst last-byte us, worst done us, per mode

    wire [31:0] lat_d = t_done - t_issue;
    wire [31:0] lat_l = got_last ? (t_last - t_issue) : lat_d;
    wire [31:0] sum_m = sum_done[m*32 +: 32];
    wire [31:0] rx_m  = rx_tot[m*32 +: 32];
    wire [31:0] wl_m  = w_last[m*32 +: 32];
    wire [31:0] wd_m  = w_done[m*32 +: 32];
    wire [31:0] smear = d_res | (d_res >> 1) | (d_res >> 2) | (d_res >> 3) | (d_res >> 4) | (d_res >> 5) | (d_res >> 6) | (d_res >> 7)
                      | (d_res >> 8) | (d_res >> 9) | (d_res >> 10) | (d_res >> 11) | (d_res >> 12) | (d_res >> 13) | (d_res >> 14)
                      | (d_res >> 15) | (d_res >> 16) | (d_res >> 17) | (d_res >> 18) | (d_res >> 19) | (d_res >> 20) | (d_res >> 21)
                      | (d_res >> 22) | (d_res >> 23) | (d_res >> 24) | (d_res >> 25) | (d_res >> 26) | (d_res >> 27) | (d_res >> 28)
                      | (d_res >> 29) | (d_res >> 30) | (d_res >> 31);
    wire [31:0] rng_n = rng ^ (rng << 13) ^ ((rng ^ (rng << 13)) >> 17) ^ (((rng ^ (rng << 13)) ^ ((rng ^ (rng << 13)) >> 17)) << 5);
    wire [31:0] sec   = rng_n & smask;
    wire [31:0] off_r = (sec << 11) + (sec << 8) + (sec << 5) + (sec << 4);   // sec * 2352

    // calculation job cs: 0 kB/s, 1 worst last-byte, 2 worst done for the sequential mode; 3 .. 5 the same for random
    wire        cm = (cs >= 3'd3);
    wire [1:0]  cj = cm ? cs - 3'd3 : cs[1:0];
    wire [31:0] c_rx  = rx_tot[cm*32 +: 32];
    wire [31:0] c_sum = sum_done[cm*32 +: 32];
    wire [31:0] c_wl  = w_last[cm*32 +: 32];
    wire [31:0] c_wd  = w_done[cm*32 +: 32];
    wire [48:0] kprod = c_rx * 17'd74250;           // bytes x clk_74a per ms
    wire [33:0] c_us  = {c_wd[31:0], 2'b00};

    // result value of word wi, in the order of memtest_defs.vh R_SL_*
    function [31:0] rval;
        input [3:0] i;
        case (i)
            4'd0:  rval = nofile ? 32'hFFFFFFFF : r_q[0*32 +: 32];
            4'd1:  rval = r_q[1*32 +: 32];
            4'd2:  rval = bad[31:0];
            4'd3:  rval = nofile ? 32'hFFFFFFFF : r_q[3*32 +: 32];
            4'd4:  rval = r_q[4*32 +: 32];
            4'd5:  rval = bad[63:32];
            4'd6:  rval = r_q[2*32 +: 32];
            4'd7:  rval = nreq[31:0];
            4'd8:  rval = rx_tot[31:0];
            4'd9:  rval = r_q[5*32 +: 32];
            4'd10: rval = nreq[63:32];
            4'd11: rval = rx_tot[63:32];
            4'd12: rval = size;
            4'd13: rval = {29'd0, code};
            default: rval = N_REQ * REQ;
        endcase
    endfunction

    initial begin
        tgt_read = 1'b0; tgt_id = 16'd0; tgt_off = 32'd0; tgt_baddr = 32'd0; tgt_len = 32'd0;
        res_tog = 1'b0; res_wa = 7'd0; res_wd = 33'd0;
    end

    always @(posedge clk) begin
        d_start <= 1'b0;
        if (!reset_n) begin
            st <= S_IDLE; armed <= 1'b1; seen <= go_tog; rerun <= 1'b0; tgt_read <= 1'b0; active <= 1'b0;
        end else begin
            if (st == S_IDLE) begin
                if (armed || go_tog != seen) begin armed <= 1'b0; seen <= go_tog; dly <= 32'd0; st <= S_DELAY; end
            end else if (go_tog != seen) begin
                seen <= go_tog; rerun <= 1'b1;
            end

            case (st)
                S_DELAY: begin
                    dly <= dly + 1'b1;
                    if (dly == START_DELAY) st <= S_INIT;
                end
                S_INIT: begin
                    sum_done <= 64'd0; rx_tot <= 64'd0; w_last <= 64'd0; w_done <= 64'd0; bad <= 64'd0; nreq <= 64'd0;
                    r_q <= 192'd0; nofile <= 1'b0; tmo_any <= 1'b0; code <= 3'd1; wi <= 4'd0; wh <= 4'd0;
                    rng <= 32'h2545F491; size <= 32'd0; rerun <= 1'b0;
                    st <= S_CLR;
                end

                // invalidate every slot (the state word reads "running"), then look up the file size
                S_CLR, S_WRITE: begin
                    wh <= wh + 1'b1;
                    if (wh == 4'd0) begin
                        res_wa <= `R_SL_BASE + {3'd0, wi};
                        res_wd <= {(st == S_WRITE) || (wi == 4'd13), rval(wi)};
                    end
                    if (wh == 4'd2) res_tog <= ~res_tog;
                    if (wh == 4'd11) begin
                        wh <= 4'd0; wi <= wi + 1'b1;
                        if (wi == NRES - 1) begin
                            wi <= 4'd0; hc <= 4'd0;
                            st <= (st == S_WRITE) ? S_END : S_SIZE;
                        end
                    end
                end

                S_SIZE: begin
                    hc <= hc + 1'b1;
                    if (hc == 4'd5) begin
                        size <= dt_q;
                        d_start <= 1'b1; d_num <= {32'd0, dt_q}; d_den <= REQ;
                        st <= S_NSEC;
                    end
                end
                S_NSEC: if (d_done) begin
                    nsec <= d_res;
                    smask <= {1'b0, smear[31:1]};      // 2^k - 1, 2^k <= the sector count
                    m <= 1'b0; idx <= 32'd0;
                    if (d_res == 32'd0) begin nofile <= 1'b1; st <= S_CALC; cs <= 3'd6; end
                    else st <= S_OFF;
                end

                // next request: sequential offsets run on from the last one and wrap before the end of the file;
                // random offsets are sector aligned in the first 2^k sectors, 2^k <= the sector count
                S_OFF: begin
                    if (!m) off <= (idx == 32'd0) ? 32'd0 : (off + 2 * REQ <= size) ? off + REQ : 32'd0;
                    else begin rng <= rng_n; off <= off_r; end
                    st <= S_ISSUE;
                end
                S_ISSUE: begin
                    tgt_id <= SLOT_ID; tgt_off <= off; tgt_baddr <= WIN; tgt_len <= REQ;
                    tgt_read <= 1'b1; t_issue <= now; active <= 1'b1; tmo <= 1'b0; hc <= 4'd0;
                    st <= S_HOLD;
                end
                // the command handler clears done a few cycles after the rising edge: do not look at done before
                S_HOLD: begin
                    hc <= hc + 1'b1;
                    if (hc == 4'd3) tgt_read <= 1'b0;
                    if (hc == 4'd7) st <= S_WAIT;
                end
                S_WAIT: begin
                    if (tgt_done) begin t_done <= now; err_l <= tgt_err; hc <= 4'd0; st <= S_GUARD; end
                    else if (now - t_issue >= TIMEOUT) begin tmo <= 1'b1; t_done <= now; hc <= 4'd0; st <= S_GUARD; end
                end
                // let bridge writes that trail the done flag land
                S_GUARD: begin
                    hc <= hc + 1'b1;
                    if (hc == 4'd15) st <= S_ACC;
                end
                S_ACC: begin
                    active <= 1'b0;
                    sum_done[m*32 +: 32] <= sum_m + lat_d;
                    rx_tot[m*32 +: 32]   <= rx_m + rx;
                    if (lat_l > wl_m) w_last[m*32 +: 32] <= lat_l;
                    if (lat_d > wd_m) w_done[m*32 +: 32] <= lat_d;
                    bad[m*32 +: 32]  <= bad[m*32 +: 32] + ((tmo || err_l != 3'd0 || rx != REQ) ? 32'd1 : 32'd0);
                    nreq[m*32 +: 32] <= nreq[m*32 +: 32] + 32'd1;
                    idx <= idx + 1'b1;
                    if (tmo) begin tmo_any <= 1'b1; cs <= 3'd0; cph <= 1'b0; st <= S_CALC; end
                    else if (idx + 1'b1 == N_REQ) begin
                        idx <= 32'd0;
                        if (!m) begin m <= 1'b1; st <= S_OFF; end
                        else begin cs <= 3'd0; cph <= 1'b0; st <= S_CALC; end
                    end else st <= S_OFF;
                end

                // kB/s = bytes x 74250 / cycles, microseconds = cycles x 4 / 297
                S_CALC: begin
                    if (cs == 3'd6) begin
                        code <= nofile ? 3'd3 : tmo_any ? 3'd4 : 3'd2;
                        wi <= 4'd0; wh <= 4'd0; st <= S_WRITE;
                    end else if (!cph) begin
                        d_start <= 1'b1; d_den <= (cj == 2'd0) ? c_sum : 32'd297;
                        d_num <= (cj == 2'd0) ? {15'd0, kprod} : (cj == 2'd1) ? {30'd0, c_wl, 2'b00} : {30'd0, c_us};
                        cph <= 1'b1;
                    end else if (d_done) begin
                        r_q[cj*32 + (cm ? 96 : 0) +: 32] <= d_res;
                        cs <= cs + 1'b1; cph <= 1'b0;
                    end
                end
                S_END: begin
                    if (rerun) st <= S_INIT;
                    else st <= S_IDLE;
                end
                default: ;
            endcase
        end
    end
endmodule
