`timescale 1ns/1ps
// Behavioural AS4C32M16SB model for simulation: BL4 (fixed), CAS latency from the mode register,
// 4 banks, timing checks in ns. Storage is 2^21 words; rows above bit 8 are not modelled.
module sdram_model #(
    parameter real TCK   = 9.842,
    parameter real T_RCD = 20.0,
    parameter real T_RP  = 20.0,
    parameter real T_RAS = 42.0,
    parameter real T_RC  = 63.0,
    parameter real T_RFC = 63.0,
    parameter real T_WR  = 14.0,
    parameter real T_RRD = 14.0,
    parameter real T_AC  = 5.4,
    parameter real T_OH  = 2.7
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
    integer i;

    reg        open [0:3];
    reg [12:0] orow [0:3];
    real       t_act [0:3];
    real       t_pre [0:3];
    real       t_wr_end [0:3];
    real       t_any_act = -1000.0;
    real       t_ref = -1000.0;
    real       t_last_ref = 0.0;
    integer    cl = 0, bl = 0;
    reg        mrs_done = 0;
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
            open[i] = 0; orow[i] = 0; t_act[i] = -1000.0; t_pre[i] = -1000.0; t_wr_end[i] = -1000.0;
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

        // ---- read data out
        for (s = 0; s < 8; s = s + 1) if (rd_used[s]) begin
            b = edge_cnt - rd_start[s] - cl;
            if (b >= 0 && b < 4) begin
                beat_due = 1;
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
                            if ($realtime - t_wr_end[s] < T_WR - 0.001) viol("tWR (PRE all)");
                        end
                        open[s] = 0; t_pre[s] = $realtime;
                    end
                    pre_all_seen = 1;
                end else begin
                    if (open[ba]) begin
                        if ($realtime - t_act[ba] < T_RAS - 0.001) viol("tRAS");
                        if ($realtime - t_wr_end[ba] < T_WR - 0.001) viol("tWR");
                    end
                    open[ba] = 0; t_pre[ba] = $realtime;
                end
            end
            3'b001: begin // AUTO REFRESH
                for (s = 0; s < 4; s = s + 1) if (open[s]) viol("REFRESH with open bank");
                if ($realtime - t_ref < T_RFC - 0.001) viol("tRFC");
                t_ref = $realtime; t_last_ref = $realtime; nref = nref + 1;
            end
            3'b000: begin // MODE REGISTER SET
                if (nref < 2) viol("MRS before two refreshes");
                if (!pre_all_seen) viol("MRS before precharge all");
                bl = (a[2:0] == 3'd2) ? 4 : (a[2:0] == 3'd1) ? 2 : 0;
                cl = a[6:4];
                mrs_done = 1;
                t_last_ref = $realtime;
                $display("%0t SDRAM mode register: BL=%0d CL=%0d", $time, bl, cl);
            end
            default: ;
        endcase

        if (mrs_done && ($realtime - t_last_ref > 9 * 7812.5)) begin
            viol("refresh interval exceeded");
            t_last_ref = $realtime;
        end
    end
endmodule
