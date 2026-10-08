`timescale 1ns/1ps
// Behavioural AS4C32M16SB model for simulation: BL4 (fixed), CAS latency from the mode register,
// 4 banks, timing checks in ns. Storage is 2^21 words; rows above bit 8 are not modelled.
// Every figure defaults to the SDRAM timing table (sdram_timing.vh, docs/pocket/MEMTEST.md); TCK is the
// test's clock period, used for the minimum-clock-count rules.
`include "sdram_timing.vh"
module sdram_model #(
    parameter real TCK   = `SDT_TCK_NS,
    parameter real T_RCD = `SDT_TRCD_NS,
    parameter real T_RP  = `SDT_TRP_NS,
    parameter real T_RAS = `SDT_TRAS_NS,
    parameter real T_RC  = `SDT_TRC_NS,
    parameter real T_RFC = `SDT_TRFC_NS,
    parameter real T_WR  = `SDT_TWR_NS,
    parameter real T_RRD = `SDT_TRRD_NS,
    parameter real T_REFI = `SDT_TREFI_NS,
    parameter real T_AC  = `SDT_TAC_NS,
    parameter real T_OH  = `SDT_TOH_NS,
    parameter real T_CK_MIN = `SDT_TCK_NS,
    parameter integer N_MRD = `SDT_TMRD_CLK,     // clocks after the mode register set
    parameter integer N_WR  = `SDT_TWR_CLK       // clocks from the last write beat to PRECHARGE
) (
    input  wire        clk,
    input  wire [12:0] a,
    input  wire [1:0]  ba,
    inout  wire [15:0] dq,
    input  wire [1:0]  dqm,
    input  wire        ras_n, cas_n, we_n
);
    reg [15:0] mem [0:(1<<21)-1];
    integer violations = 0;
    // tWR is the longer of the ns figure and the clock count at the test's clock
    real T_WR_EFF;
    initial T_WR_EFF = (N_WR * TCK > T_WR) ? N_WR * TCK : T_WR;
    integer i;

    reg        open [0:3];
    reg [12:0] orow [0:3];
    real       t_act [0:3];
    real       t_pre [0:3];
    real       t_wr_end [0:3];
    real       t_any_act = -1000.0;
    real       t_ref = -1000.0;
    real       t_ref_base = 0.0;   // refresh debt = (now - t_ref_base) / T_REFI
    integer    rd_edge [0:3];      // edge of the last READ per bank
    integer    cl = 0, bl = 0;
    reg        mrs_done = 0;
    integer    mrs_edge = -1000;
    real       t_clk_prev = -1000.0;
    reg [1:0]  dqm_h1 = 2'b00, dqm_h2 = 2'b00;   // DQM at the previous two edges (read latency 2)
    integer    nref = 0;
    reg        pre_all_seen = 0;

    // read bursts in flight
    integer    edge_cnt = 0;
    integer    rd_start [0:7];
    reg [1:0]  rd_ba [0:7];
    reg [12:0] rd_row [0:7];
    reg [9:0]  rd_col [0:7];
    reg        rd_used [0:7];
    // write burst in progress
    integer    wr_left = 0;
    reg [1:0]  wr_ba;
    reg [12:0] wr_row;
    reg [9:0]  wr_col;
    integer    wr_beat = 0;

    reg [15:0] dq_o = 16'hxxxx;
    reg        dq_en = 0;
    assign dq = dq_en ? dq_o : 16'hzzzz;

    initial begin
        for (i = 0; i < 4; i = i + 1) begin
            open[i] = 0; orow[i] = 0; t_act[i] = -1000.0; t_pre[i] = -1000.0; t_wr_end[i] = -1000.0; rd_edge[i] = -1000;
        end
        for (i = 0; i < 8; i = i + 1) rd_used[i] = 0;
    end

    function [20:0] idx;
        input [1:0] b; input [12:0] r; input [9:0] c;
        begin
            idx = {b, r[8:0], c};
        end
    endfunction

    task viol;
        input [255:0] msg;
        begin
            violations = violations + 1;
            $display("%0t SDRAM VIOLATION: %0s", $time, msg);
        end
    endtask

    reg [2:0] cmd;
    reg beat_due;
    integer s, b;
    reg [15:0] w;

    always @(posedge clk) begin
        edge_cnt = edge_cnt + 1;
        cmd = {ras_n, cas_n, we_n};
        beat_due = 0;
        if ($realtime - t_clk_prev < T_CK_MIN - 0.001 && t_clk_prev > 0) viol("tCK below the CL3 minimum");
        t_clk_prev = $realtime;
        if (mrs_done && cmd != 3'b111 && edge_cnt - mrs_edge < N_MRD) viol("tMRD");

        // ---- read data out
        for (s = 0; s < 8; s = s + 1) if (rd_used[s]) begin
            b = edge_cnt - rd_start[s] - cl;
            if (b >= 0 && b < 4) begin
                beat_due = 1;
                // DQM has read latency 2: DQM high two edges before a beat leaves would mask it
                if (dqm_h2 != 2'b00) viol("DQM high on a read beat");
                dq_en <= 1;
                dq_o <= #(T_OH) 16'hxxxx;
                dq_o <= #(T_AC) mem[idx(rd_ba[s], rd_row[s], rd_col[s] + b[9:0])];
            end
            if (b >= 4) rd_used[s] = 0;
        end
        if (!beat_due && dq_en) begin
            dq_en <= #(T_OH) 0;
        end

        // ---- write data in
        if (wr_left > 0) begin
            w = dq;
            if (^w === 1'bx) viol("write data unknown");
            if (!dqm[0]) mem[idx(wr_ba, wr_row, wr_col + wr_beat[9:0])][7:0]  = w[7:0];
            if (!dqm[1]) mem[idx(wr_ba, wr_row, wr_col + wr_beat[9:0])][15:8] = w[15:8];
            wr_beat = wr_beat + 1; wr_left = wr_left - 1;
            if (wr_left == 0) t_wr_end[wr_ba] = $realtime;
        end

        // ---- commands (NOP = 111)
        case (cmd)
            3'b011: begin // ACTIVE
                if (!mrs_done) viol("ACT before MRS");
                if (open[ba]) viol("ACT to open bank");
                if ($realtime - t_pre[ba] < T_RP - 0.001) viol("tRP");
                if ($realtime - t_act[ba] < T_RC - 0.001) viol("tRC");
                if ($realtime - t_any_act < T_RRD - 0.001) viol("tRRD");
                if ($realtime - t_ref < T_RFC - 0.001) viol("tRFC (ACT)");
                if (a[12:9] != 0) viol("model: row above 9 bits used");
                open[ba] = 1; orow[ba] = a; t_act[ba] = $realtime; t_any_act = $realtime;
            end
            3'b101, 3'b100: begin // READ / WRITE
                if (!open[ba]) viol("column command to closed bank");
                if ($realtime - t_act[ba] < T_RCD - 0.001) viol("tRCD");
                if (a[10]) viol("auto precharge not used");
                if (bl != 4) viol("burst length not 4");
                if (cmd == 3'b101) begin
                    rd_edge[ba] = edge_cnt;
                    for (s = 0; s < 8; s = s + 1) if (!rd_used[s]) begin
                        rd_used[s] = 1; rd_start[s] = edge_cnt; rd_ba[s] = ba; rd_row[s] = orow[ba]; rd_col[s] = a[9:0];
                        s = 8;
                    end
                    if (wr_left > 0) viol("READ during write burst");
                end else begin
                    wr_left = 4; wr_beat = 0; wr_ba = ba; wr_row = orow[ba]; wr_col = a[9:0];
                    // first beat is on the bus with the command
                    w = dq;
                    if (^w === 1'bx) viol("write data unknown (beat 0)");
                    if (!dqm[0]) mem[idx(ba, orow[ba], a[9:0])][7:0]  = w[7:0];
                    if (!dqm[1]) mem[idx(ba, orow[ba], a[9:0])][15:8] = w[15:8];
                    wr_beat = 1; wr_left = 3;
                    for (s = 0; s < 8; s = s + 1) if (rd_used[s]) begin
                        b = edge_cnt - rd_start[s] - cl;
                        if (b < 4) viol("WRITE while read data in flight");
                    end
                end
            end
            3'b010: begin // PRECHARGE
                if (a[10]) begin
                    for (s = 0; s < 4; s = s + 1) begin
                        if (open[s]) begin
                            if ($realtime - t_act[s] < T_RAS - 0.001) viol("tRAS (PRE all)");
                            if ($realtime - t_wr_end[s] < T_WR_EFF - 0.001) viol("tWR (PRE all)");
                            if (edge_cnt - rd_edge[s] < bl) viol("READ to PRE under BL (PRE all)");
                            if (wr_left > 0 && wr_ba == s) viol("PRE during write burst (PRE all)");
                        end
                        open[s] = 0; t_pre[s] = $realtime;
                    end
                    pre_all_seen = 1;
                end else begin
                    if (open[ba]) begin
                        if ($realtime - t_act[ba] < T_RAS - 0.001) viol("tRAS");
                        if ($realtime - t_wr_end[ba] < T_WR_EFF - 0.001) viol("tWR");
                        if (edge_cnt - rd_edge[ba] < bl) viol("READ to PRE under BL");
                        if (wr_left > 0 && wr_ba == ba) viol("PRE during write burst");
                    end
                    open[ba] = 0; t_pre[ba] = $realtime;
                end
            end
            3'b001: begin // AUTO REFRESH
                for (s = 0; s < 4; s = s + 1) begin
                    if (open[s]) viol("REFRESH with open bank");
                    if ($realtime - t_pre[s] < T_RP - 0.001) viol("tRP (REFRESH)");
                end
                if ($realtime - t_ref < T_RFC - 0.001) viol("tRFC");
                t_ref = $realtime; nref = nref + 1;
                // at most 8 refreshes may be pulled in
                if (mrs_done) t_ref_base = (t_ref_base + T_REFI > $realtime + 8 * T_REFI) ? $realtime + 8 * T_REFI : t_ref_base + T_REFI;
            end
            3'b000: begin // MODE REGISTER SET
                if (nref < 2) viol("MRS before two refreshes");
                if ($realtime - t_ref < T_RFC - 0.001) viol("tRFC (MRS)");
                mrs_edge = edge_cnt;
                if (!pre_all_seen) viol("MRS before precharge all");
                bl = (a[2:0] == 3'd2) ? 4 : (a[2:0] == 3'd1) ? 2 : 0;
                cl = a[6:4];
                mrs_done = 1;
                t_ref_base = $realtime;
                $display("%0t SDRAM mode register: BL=%0d CL=%0d", $time, bl, cl);
            end
            default: ;
        endcase

        dqm_h2 = dqm_h1; dqm_h1 = dqm;

        // JEDEC: average tREFI, at most 8 refreshes postponed
        if (mrs_done && ($realtime - t_ref_base > 9 * T_REFI)) begin
            viol("refresh debt above 8");
            t_ref_base = $realtime;
        end
    end
endmodule
