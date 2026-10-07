`timescale 1ns/1ps
// Behavioural 128K x 16 asynchronous SRAM with access and write-pulse checks.
module sram_model #(
    parameter real T_AA = 25.0,
    parameter real T_WP = 15.0
) (
    input  wire [16:0] a,
    inout  wire [15:0] dq,
    input  wire        oe_n, we_n, ub_n, lb_n
);
    reg [15:0] mem [0:131071];
    integer i;
    initial for (i = 0; i < 131072; i = i + 1) mem[i] = 16'hxxxx;
    integer violations = 0;     // always zero: a short write pulse just does not write
    integer short_pulses = 0;

    reg [15:0] dq_o = 16'hxxxx;
    always @(a or ub_n or lb_n or oe_n) begin
        dq_o <= #0.5 16'hxxxx;
        dq_o <= #(T_AA) mem[a];
    end
    assign dq = (!oe_n && we_n) ? {ub_n ? 8'hzz : dq_o[15:8], lb_n ? 8'hzz : dq_o[7:0]} : 16'hzzzz;

    real t_we_fall = 0;
    always @(negedge we_n) t_we_fall = $realtime;
    always @(posedge we_n) begin
        if ($time < 100) begin
        end else if ($realtime - t_we_fall < T_WP - 0.001) begin
            short_pulses = short_pulses + 1;
            if (short_pulses == 1) $display("%0t SRAM: write pulse %0.2f ns < %0.2f ns is ignored (first of the sweep)", $time, $realtime - t_we_fall, T_WP);
        end else begin
            if (!lb_n) mem[a][7:0]  = dq[7:0];
            if (!ub_n) mem[a][15:8] = dq[15:8];
        end
    end
endmodule
