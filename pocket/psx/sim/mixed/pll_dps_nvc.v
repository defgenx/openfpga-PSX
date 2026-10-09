`timescale 1ps/1ps
// The memtest PLL stand-in (memtest/sim/pll_dps_model.v) in integer picoseconds: nvc evaluates its real-valued
// delay as 0. clk_scan is clk / SCAN_DIV; each phase_en pulse moves clk_cap one step (153.846 ps) later (updn = 1) or
// earlier; phase_done stays low for DONE_LOW clk_scan cycles.
module pll_dps_nvc #(
    parameter integer SCAN_DIV = 4,
    parameter integer DONE_LOW = 3
) (
    input  wire       clk,
    output reg        clk_scan,
    input  wire       phase_en,
    input  wire       updn,
    input  wire [4:0] cntsel,
    output reg        phase_done,
    output reg        clk_cap
);
    integer steps = 0;
    integer dly_ps = 0;
    integer low_cnt = 0;
    integer dcnt = 0;

    initial begin clk_scan = 1'b0; phase_done = 1'b1; clk_cap = 1'b0; end

    always @(posedge clk) begin
        dcnt <= (dcnt == SCAN_DIV - 1) ? 0 : dcnt + 1;
        clk_scan <= (((dcnt == SCAN_DIV - 1) ? 0 : dcnt + 1) < (SCAN_DIV + 1) / 2);
    end

    always @(posedge clk_scan) begin
        if (phase_en && phase_done && cntsel == 5'd2) begin
            steps = steps + (updn ? 1 : -1);
            dly_ps = (steps * 153846) / 1000;
            phase_done <= 1'b0;
            low_cnt = DONE_LOW;
        end else if (low_cnt > 0) begin
            low_cnt = low_cnt - 1;
            if (low_cnt == 0) phase_done <= 1'b1;
        end
    end

    always @(clk) clk_cap <= #(dly_ps) clk;
endmodule
