// SDRAM read-capture calibration: a boot eye sweep and a periodic tracking check of the capture clock's
// phase (the PLL's dynamic phase shift). It borrows the controller's request port while it runs.
// Contract, constants and the PLL handshake: docs/pocket/MEMTEST.md, "Calibration contract".
`include "mem_defs.vh"
module sdram_cal #(
    parameter SWMAX   = `MT_CAL_SWMAX,
    parameter NOM     = `MT_CAL_NOM,
    parameter READS   = `MT_CAL_READS,
    parameter K       = `MT_CAL_K,
    parameter DEB     = `MT_CAL_DEB,
    parameter EYE_MIN = `MT_CAL_EYE_MIN,
    parameter [24:0] ROW = `MT_CAL_ADDR,
    parameter SETTLE  = 1024               // cycles after the PLL locks before the first phase step
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        pll_locked,
    input  wire        ctl_ready,          // the controller finished its power-up sequence
    input  wire        quiet,              // controller: no request pending, no read in flight

    // request port: owned while `own` is set; `hold` keeps the other requesters off
    output reg         own,
    output reg         hold,
    output reg         q_valid,
    output reg         q_we,
    output reg  [24:0] q_addr,
    output wire [63:0] q_wdata,
    input  wire        q_ready,
    input  wire        rd_valid,           // read return of the controller
    input  wire [63:0] rd_data,

    input  wire        tick,               // one pulse per tracking window
    output reg         done,               // boot sweep finished
    output reg         ok,                 // eye at least EYE_MIN steps wide
    output reg  [6:0]  width,
    output reg  [6:0]  boot_c,
    output reg  [6:0]  centre,
    output reg  [6:0]  cmin,
    output reg  [6:0]  cmax,
    output reg  [15:0] moves,
    output reg  [3:0]  flags,              // bit 0 no eye, 1 eye touches 0 or SWMAX, 2 PLL handshake timeout (stops the calibration), 3 tracker re-swept

    // PLL dynamic phase shift, clk_scan domain
    input  wire        clk_scan,
    output reg         ps_en,
    output reg         ps_up,
    input  wire        ps_done
);
    // beats toggle every DQ on every beat; the first beat is the low word
    localparam [63:0] PAT = 64'h5555AAAA5555AAAA;
    assign q_wdata = PAT;

    localparam [3:0] S_LOCK = 4'd0, S_START = 4'd1, S_MOVE = 4'd2, S_MREQ = 4'd3, S_MREL = 4'd4, S_WR = 4'd5,
                     S_WRW = 4'd6, S_PINIT = 4'd7, S_PROBE = 4'd8, S_PDONE = 4'd9, S_FIND = 4'd10, S_FIN = 4'd11,
                     S_RUN = 4'd12, S_TQ = 4'd13, S_TDEC = 4'd14, S_TFIN = 4'd15;
    localparam [1:0] M_SWEEP = 2'd0, M_TLO = 2'd1, M_THI = 2'd2;

    reg [3:0]  state = S_LOCK;
    reg [1:0]  mode = M_SWEEP;
    reg [3:0]  ret = S_LOCK;
    reg [6:0]  pos = 7'd0;                 // capture step now in the PLL; survives a reset, cleared when the PLL unlocks
    reg [6:0]  tgt = 7'd0;
    reg [10:0] lock_cnt = 11'd0;
    reg        rst_l = 1'b1;
    reg        booted = 1'b0;
    reg        tick_pend = 1'b0;
    reg        ps_req = 1'b0, ps_dir = 1'b0;
    reg [1:0]  ack_s = 2'b00;
    reg [1:0]  derr_s = 2'b00;
    reg        ack_scan = 1'b0;            // clk_scan domain: step done
    reg        derr = 1'b0;                // clk_scan domain: this step's phase_done handshake timed out; valid with ack_scan
    reg [3:0]  wi;
    reg [6:0]  nreq, nrsp;
    reg        err;
    reg [63:0] eye = 64'd0;
    reg        p_lo, p_hi;
    reg [6:0]  fi, run_len, run_start, best_len, best_start;
    reg [1:0]  up_c, dn_c, lost_c;
    reg [6:0]  nc, cn;
    reg        resweep;
    reg        moved;                      // the last tracking decision moved the centre; counted in S_TFIN
    reg        c_lt, c_gt;                 // centre < cmin, centre > cmax, a cycle late: centre is set two states before S_FIN / S_TFIN

    wire [6:0] lo_t = (centre >= K) ? centre - K : 7'd0;
    wire [6:0] hi_t = (centre + K > SWMAX) ? SWMAX : centre + K;

    always @(posedge clk) begin
        c_lt <= (centre < cmin); c_gt <= (centre > cmax);
        ack_s  <= {ack_s[0], ack_scan};
        derr_s <= {derr_s[0], derr};
        if (rst) rst_l <= 1'b1;
        if (!pll_locked) begin pos <= 7'd0; lock_cnt <= 11'd0; flags[2] <= 1'b0; end
        if (tick && done) tick_pend <= 1'b1;

        // a reset is taken between phase steps only, so `pos` always matches the PLL
        if (rst_l && state != S_MREQ && state != S_MREL) begin
            rst_l <= 1'b0; state <= S_LOCK; lock_cnt <= 11'd0; hold <= 1'b1; own <= 1'b0; q_valid <= 1'b0;
            done <= 1'b0; booted <= 1'b0; tick_pend <= 1'b0; ps_req <= 1'b0; ok <= 1'b0;
            up_c <= 2'd0; dn_c <= 2'd0; lost_c <= 2'd0; flags[1:0] <= 2'b00; flags[3] <= 1'b0;   // flags[2] survives: `pos` is still unknown
        end else case (state)
            S_LOCK: begin
                if (pll_locked) begin
                    if (lock_cnt != SETTLE) lock_cnt <= lock_cnt + 1'b1;
                    else if (ctl_ready) state <= S_START;
                end
            end
            S_START: if (quiet) begin
                own <= 1'b1; tgt <= 7'd0; mode <= M_SWEEP; wi <= 4'd0; ret <= S_WR; state <= S_MOVE;
            end

            // one PLL step per pass, only with no read in flight. After a handshake timeout `pos` may be one step off the
            // PLL: every move then counts as done without a step, until the PLL loses lock.
            S_MOVE: begin
                if (pos == tgt || flags[2]) state <= ret;
                else if (quiet) begin ps_dir <= (pos < tgt); ps_req <= 1'b1; state <= S_MREQ; end
            end
            S_MREQ: if (ack_s[1]) begin
                ps_req <= 1'b0; pos <= ps_dir ? pos + 1'b1 : pos - 1'b1; state <= S_MREL;
                if (derr_s[1]) begin flags[2] <= 1'b1; ok <= 1'b0; end
            end
            S_MREL: if (!ack_s[1]) state <= S_MOVE;

            // the pattern: eight bursts at the start of the reserved row
            S_WR: begin
                if (!q_valid) begin q_valid <= 1'b1; q_we <= 1'b1; q_addr <= ROW + {wi[2:0], 2'b00}; end
                else if (q_ready) begin
                    q_valid <= 1'b0; wi <= wi + 1'b1;
                    if (wi == 4'd7) state <= S_WRW;
                end
            end
            S_WRW: if (quiet && !q_valid) state <= S_PINIT;

            // READS reads at the current step; any word that differs from the pattern fails the step
            S_PINIT: begin nreq <= 7'd0; nrsp <= 7'd0; err <= 1'b0; state <= S_PROBE; end
            S_PROBE: begin
                if (nreq != READS) begin
                    if (!q_valid) begin q_valid <= 1'b1; q_we <= 1'b0; q_addr <= ROW + {nreq[2:0], 2'b00}; end
                    else if (q_ready) begin q_valid <= 1'b0; nreq <= nreq + 1'b1; end
                end
                if (rd_valid) begin
                    nrsp <= nrsp + 1'b1;
                    if (rd_data == PAT) ; else err <= 1'b1;
                end
                if (nrsp == READS) state <= S_PDONE;
            end
            S_PDONE: begin
                case (mode)
                    M_SWEEP: begin
                        eye[pos] <= !err;
                        if (pos >= SWMAX || flags[2]) begin   // a frozen PLL never reaches SWMAX
                            fi <= 7'd0; run_len <= 7'd0; run_start <= 7'd0; best_len <= 7'd0; best_start <= 7'd0;
                            state <= S_FIND;
                        end else begin tgt <= pos + 1'b1; ret <= S_PINIT; state <= S_MOVE; end
                    end
                    M_TLO: begin p_lo <= !err; mode <= M_THI; tgt <= hi_t; ret <= S_PINIT; state <= S_MOVE; end
                    default: begin p_hi <= !err; state <= S_TDEC; end
                endcase
            end

            // longest run of passing steps; the first one wins a tie. `eye` is shifted out (the next sweep rewrites it)
            S_FIND: begin
                if (fi <= SWMAX) begin
                    eye <= eye >> 1;
                    if (eye[0]) begin
                        run_len <= run_len + 1'b1;
                        if (run_len == 0) run_start <= fi;
                        if (run_len + 1'b1 > best_len) begin
                            best_len <= run_len + 1'b1; best_start <= (run_len == 0) ? fi : run_start;
                        end
                    end else run_len <= 7'd0;
                    fi <= fi + 1'b1;
                end else begin
                    width <= best_len;
                    ok    <= (best_len >= EYE_MIN) && !flags[2];
                    flags[0] <= (best_len == 0);
                    flags[1] <= (best_len != 0) && (best_start == 0 || best_start + best_len > SWMAX);
                    cn = (best_len == 0) ? NOM : best_start + ((best_len - 1'b1) >> 1);
                    if (cn < 1) cn = 7'd1;
                    if (cn > SWMAX - 1) cn = SWMAX - 1;
                    centre <= cn; tgt <= cn; ret <= S_FIN; state <= S_MOVE;
                end
            end
            S_FIN: begin
                if (!booted) begin
                    boot_c <= centre; cmin <= centre; cmax <= centre; moves <= 16'd0; booted <= 1'b1;
                end else begin
                    moves <= moves + 1'b1;
                    if (c_lt) cmin <= centre;
                    if (c_gt) cmax <= centre;
                end
                done <= 1'b1; own <= 1'b0; hold <= 1'b0; state <= S_RUN;
            end

            // tracking: probe centre - K and centre + K, step the centre toward the side that still passes
            S_RUN: if (tick_pend) begin tick_pend <= 1'b0; if (!flags[2]) begin hold <= 1'b1; state <= S_TQ; end end
            S_TQ: if (quiet) begin
                own <= 1'b1; mode <= M_TLO; tgt <= lo_t; ret <= S_PINIT; state <= S_MOVE;
            end
            S_TDEC: begin
                nc = centre; resweep = 1'b0;
                if (p_lo && p_hi) begin up_c <= 2'd0; dn_c <= 2'd0; lost_c <= 2'd0; end
                else if (!p_lo && p_hi) begin
                    dn_c <= 2'd0; lost_c <= 2'd0;
                    if (up_c == DEB - 1) begin up_c <= 2'd0; if (centre < SWMAX - 1) nc = centre + 1'b1; end
                    else up_c <= up_c + 1'b1;
                end else if (p_lo && !p_hi) begin
                    up_c <= 2'd0; lost_c <= 2'd0;
                    if (dn_c == DEB - 1) begin dn_c <= 2'd0; if (centre > 1) nc = centre - 1'b1; end
                    else dn_c <= dn_c + 1'b1;
                end else begin
                    up_c <= 2'd0; dn_c <= 2'd0;
                    if (lost_c == DEB - 1) begin lost_c <= 2'd0; resweep = 1'b1; end
                    else lost_c <= lost_c + 1'b1;
                end
                if (resweep) begin
                    flags[3] <= 1'b1; mode <= M_SWEEP; tgt <= 7'd0; ret <= S_PINIT; state <= S_MOVE;
                end else begin
                    moved <= (nc != centre); centre <= nc; tgt <= nc; ret <= S_TFIN; state <= S_MOVE;
                end
            end
            S_TFIN: begin
                if (moved) begin
                    moves <= moves + 1'b1;
                    if (c_lt) cmin <= centre;
                    if (c_gt) cmax <= centre;
                end
                own <= 1'b0; hold <= 1'b0; state <= S_RUN;
            end
            default: state <= S_LOCK;
        endcase
    end

    initial begin
        own = 1'b0; hold = 1'b1; q_valid = 1'b0; q_we = 1'b0; q_addr = 25'd0; done = 1'b0; ok = 1'b0;
        width = 7'd0; boot_c = 7'd0; centre = 7'd0; cmin = 7'd0; cmax = 7'd0; moves = 16'd0; flags = 4'd0;
    end

    // ---- clk_scan domain: one PLL step per request, handshake with the PLL's phase_done
    reg [1:0]  rq_s = 2'b00;
    reg [1:0]  sst = 2'd0;
    reg [11:0] tmo = 12'd0;
    initial begin ps_en = 1'b0; ps_up = 1'b0; end
    always @(posedge clk_scan) begin
        rq_s <= {rq_s[0], ps_req};
        ps_en <= 1'b0;
        case (sst)
            2'd0: if (rq_s[1]) begin ps_up <= ps_dir; ps_en <= 1'b1; tmo <= 12'd0; derr <= 1'b0; sst <= 2'd1; end
            2'd1: begin                                   // phase_done must fall ...
                tmo <= tmo + 1'b1;
                if (!ps_done) begin sst <= 2'd2; tmo <= 12'd0; end
                else if (tmo == 12'd31) begin sst <= 2'd2; tmo <= 12'd0; derr <= 1'b1; end
            end
            2'd2: begin                                   // ... and rise again
                tmo <= tmo + 1'b1;
                if (ps_done) sst <= 2'd3;
                else if (tmo == 12'd4095) begin sst <= 2'd3; derr <= 1'b1; end
            end
            default: begin
                ack_scan <= 1'b1;
                if (!rq_s[1]) begin ack_scan <= 1'b0; sst <= 2'd0; end
            end
        endcase
    end
endmodule
