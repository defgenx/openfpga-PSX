`timescale 1ns/1ps
// Simulation stand-in for the PLL's dynamic phase shift (docs/pocket/MEMTEST.md, Calibration contract):
// clk_scan is clk divided by SCAN_DIV, aligned to it; each phase_en pulse moves clk_cap one step (1/8 VCO period)
// later (updn = 1) or earlier, and phase_done stays low for DONE_LOW clk_scan cycles, or for as long as `stall` is set.
module pll_dps_model #(
    parameter real    STEP_NS  = 0.153846,
    parameter integer SCAN_DIV = 4,
    parameter integer DONE_LOW = 3,
    parameter integer MAX_STEP = 63        // a shift outside 0 .. MAX_STEP is flagged
) (
    input  wire       clk,
    output reg        clk_scan,
    input  wire       phase_en,
    input  wire       updn,
    input  wire [4:0] cntsel,
    output reg        phase_done,
    output reg        clk_cap
);
    integer steps = 0;                     // current shift of clk_cap, in steps
    integer nsteps = 0;                    // phase_en pulses taken
    integer range_viol = 0;
    real    dly = 0.0;
    integer low_cnt = 0;
    integer dcnt = 0;
    reg     stall = 1'b0;                  // set by the testbench: phase_done does not rise

    initial begin clk_scan = 1'b0; phase_done = 1'b1; clk_cap = 1'b0; end

    always @(posedge clk) begin
        dcnt <= (dcnt == SCAN_DIV - 1) ? 0 : dcnt + 1;
        clk_scan <= (((dcnt == SCAN_DIV - 1) ? 0 : dcnt + 1) < (SCAN_DIV + 1) / 2);
    end

    always @(posedge clk_scan) begin
        if (phase_en && phase_done && cntsel == 5'd2) begin
            steps = steps + (updn ? 1 : -1);
            nsteps = nsteps + 1;
            if (steps < 0 || steps > MAX_STEP) range_viol = range_viol + 1;
            dly = steps * STEP_NS;
            phase_done <= 1'b0;
            low_cnt = DONE_LOW;
        end else if (low_cnt > 0 && !stall) begin
            low_cnt = low_cnt - 1;
            if (low_cnt == 0) phase_done <= 1'b1;
        end
    end

    always @(clk) clk_cap <= #(dly) clk;
endmodule
