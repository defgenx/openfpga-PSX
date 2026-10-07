`timescale 1ns/1ps
// Whole-core simulation: memtest_core with behavioural SDRAM, PSRAM and SRAM models.
// Reduced test sizes unless FULL is defined. Prints the result table and checks it.
`ifndef MAXC
`define MAXC 60000000
`endif
module tb_core;
    parameter real TCK = 9.842;
`ifdef FULL
    localparam SD_REG_BITS = 17, SD_RND_LOG2 = 16, SC_LINES = 96, SC_Y_WRAP = 480, PS_REG_BITS = 16,
               PS_RND_LOG2 = 14, PS_SWEEP_LOG2 = 11, DMA_LOG2 = 16, SR_SWEEP_LOG2 = 10, SR_N_LOG2 = 16,
               SD_INIT = 20600;
`else
    localparam SD_REG_BITS = 11, SD_RND_LOG2 = 10, SC_LINES = 4, SC_Y_WRAP = 8, PS_REG_BITS = 8,
               PS_RND_LOG2 = 8, PS_SWEEP_LOG2 = 6, DMA_LOG2 = 8, SR_SWEEP_LOG2 = 7, SR_N_LOG2 = 9,
               SD_INIT = 300;
`endif
`ifdef LATE
    localparam SC_LINE = 500;       // shorter than the 640 cycles one line needs: every line is late
`else
    localparam SC_LINE = 6400;
`endif
`ifdef SYNC
    localparam SYNC_EN = 1;
`else
    localparam SYNC_EN = 0;
`endif

    reg clk = 0;
    always #(TCK/2) clk = ~clk;
    // SDRAM clock = system clock here. The capture clock is half a period late, which gives the same
    // CL + 3 cycle read latency as the hardware phases (pin clock 3.7 ns early, capture 1.1 ns late).
    wire clk_cap = ~clk;
    reg rst = 1;

    wire [12:0] dram_a; wire [1:0] dram_ba; wire [15:0] dram_dq; wire [1:0] dram_dqm;
    wire dram_ras_n, dram_cas_n, dram_we_n;
    wire [21:16] cram_a; wire [15:0] cram0_dq, cram1_dq;
    wire cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n, cram_oe_n, cram_we_n;
    wire cram0_ub_n, cram0_lb_n, cram1_ub_n, cram1_lb_n;
    wire [16:0] sram_a; wire [15:0] sram_dq; wire sram_oe_n, sram_we_n, sram_ub_n, sram_lb_n;

    wire [32:0] rq, rq_b; wire [1:0] run_state;
    reg  [6:0] ra = 0;

    memtest_core #(.SD_REG_BITS(SD_REG_BITS), .SD_RND_LOG2(SD_RND_LOG2), .SC_LINES(SC_LINES), .SC_Y_WRAP(SC_Y_WRAP), .SC_LINE_CYCLES(SC_LINE),
                   .PS_REG_BITS(PS_REG_BITS), .PS_RND_LOG2(PS_RND_LOG2), .PS_SWEEP_LOG2(PS_SWEEP_LOG2),
                   .DMA_LOG2(DMA_LOG2), .SR_SWEEP_LOG2(SR_SWEEP_LOG2), .SR_N_LOG2(SR_N_LOG2),
                   .SD_INIT_CYCLES(SD_INIT), .WD_BITS(24)) dut (
        .clk(clk), .clk_cap(clk_cap), .rst(rst), .seed_in(32'h1234ABCD),
        .cfg_sync_en(SYNC_EN[0]), .cfg_lc(3'd3), .cfg_phase(2'd2), .cfg_loop(1'b0),
        .res_ra(ra), .res_rq(rq), .res_clk_b(clk), .res_rb(7'd0), .res_rq_b(rq_b), .run_state(run_state),
        .dram_a(dram_a), .dram_ba(dram_ba), .dram_dq(dram_dq), .dram_dqm(dram_dqm),
        .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_we_n(dram_we_n),
        .cram_a(cram_a), .cram0_dq(cram0_dq), .cram1_dq(cram1_dq), .cram_clk(cram_clk), .cram_adv_n(cram_adv_n),
        .cram_cre(cram_cre), .cram_ce0_n(cram_ce0_n), .cram_ce1_n(cram_ce1_n), .cram_oe_n(cram_oe_n),
        .cram_we_n(cram_we_n), .cram0_ub_n(cram0_ub_n), .cram0_lb_n(cram0_lb_n),
        .cram1_ub_n(cram1_ub_n), .cram1_lb_n(cram1_lb_n),
        .sram_a(sram_a), .sram_dq(sram_dq), .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n),
        .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n)
    );

    // pad and routing delays of the read path folded into the model: data valid 10.6 ns after the
    // clock edge, held until 6.9 ns after the next one (tAC 6.4 + 4.2, tOH 3.2 + 3.7 as seen at the capture register)
    sdram_model #(.T_AC(10.6), .T_OH(6.9)) sdram (.clk(clk), .a(dram_a), .ba(dram_ba), .dq(dram_dq), .dqm(dram_dqm),
                       .ras_n(dram_ras_n), .cas_n(dram_cas_n), .we_n(dram_we_n));
    psram_model pr0 (.a(cram_a), .dq(cram0_dq), .wait_o(), .clk(cram_clk), .adv_n(cram_adv_n), .cre(cram_cre),
                     .ce0_n(cram_ce0_n), .ce1_n(cram_ce1_n), .oe_n(cram_oe_n), .we_n(cram_we_n),
                     .ub_n(cram0_ub_n), .lb_n(cram0_lb_n));
    psram_model pr1 (.a(cram_a), .dq(cram1_dq), .wait_o(), .clk(cram_clk), .adv_n(cram_adv_n), .cre(cram_cre),
                     .ce0_n(cram_ce0_n), .ce1_n(cram_ce1_n), .oe_n(cram_oe_n), .we_n(cram_we_n),
                     .ub_n(cram1_ub_n), .lb_n(cram1_lb_n));
    sram_model sram (.a(sram_a), .dq(sram_dq), .oe_n(sram_oe_n), .we_n(sram_we_n), .ub_n(sram_ub_n), .lb_n(sram_lb_n));

    `include "memtest_defs.vh"
    function [32:0] res;
        input integer i;
        res = dut.rres.ma[i];
    endfunction

    task show;
        input [255:0] name;
        input integer i;
        reg [32:0] v0, v1, v2;
        begin
            v0 = res(i); v1 = res(i+1); v2 = res(i+2);
            $write("  %-16s", name);
            if (v0[32]) $write(" %10d", v0[31:0]); else $write("          -");
            if (v1[32]) $write(" %10d", v1[31:0]); else $write("          -");
            if (v2[32]) $write(" %10d", v2[31:0]); else $write("          -");
            $write("\n");
        end
    endtask

    integer fails = 0;
    task expect_eq;
        input [255:0] name;
        input integer i;
        input integer want;
        reg [32:0] v;
        begin
            v = res(i);
            if (!v[32] || v[31:0] !== want) begin
                fails = fails + 1;
                $display("  CHECK FAILED: %0s result[%0d] = %0d (valid %0d), expected %0d", name, i, v[31:0], v[32], want);
            end
        end
    endtask

    task expect_range;
        input [255:0] name;
        input integer i;
        input integer lo;
        input integer hi;
        reg [32:0] v;
        begin
            v = res(i);
            if (!v[32] || v[31:0] < lo || v[31:0] > hi) begin
                fails = fails + 1;
                $display("  CHECK FAILED: %0s result[%0d] = %0d (valid %0d), expected %0d..%0d", name, i, v[31:0], v[32], lo, hi);
            end
        end
    endtask

    integer cycles = 0;
`ifdef TRACE_DMA
    integer acc = 0;
    always @(posedge clk) if (dut.step == 6'd11 && dut.sdram.req_valid && dut.sdram.req_ready && acc < 4) begin
        acc = acc + 1;
        $display("%0t ACCEPT c_addr=%h a_addr=%h d_req_addr=%h b_addr=%h sel_b=%b b_valid=%b", $time, dut.c_addr, dut.a_addr, dut.d_req_addr, dut.b_addr, dut.arb.sel_b, dut.b_valid);
    end
    integer dcnt = 0;
    always @(posedge clk) if (dut.step == 6'd11 && dut.ph == 4'd2) begin
        dcnt = dcnt + 1;
        if (dcnt % 300 == 0 && dcnt < 6000) begin
            $display("%0t SD open=%b bank=%0d row=%h we=%b hit=%b rcd=%0d pre=%0d rp=%0d rrd=%0d rd_ok=%0d wr_ok=%0d orow0=%h orow1=%h orow2=%h orow3=%h", $time, dut.sdram.open, dut.sdram.cur_bank, dut.sdram.cur_row, dut.sdram.cur_we, dut.sdram.row_hit, dut.sdram.b_rcd, dut.sdram.b_pre, dut.sdram.b_rp, dut.sdram.rrd, dut.sdram.rd_ok, dut.sdram.wr_ok, dut.sdram.orow0, dut.sdram.orow1, dut.sdram.orow2, dut.sdram.orow3);
            $display("%0t DMA req_addr=%h wdata=%h paddr=%h half=%b wp=%0d rp=%0d c_valid=%b c_addr=%h", $time, dut.d_req_addr, dut.d_req_wdata, dut.dma.paddr, dut.dma.half, dut.dma.wp, dut.dma.rp, dut.c_valid, dut.c_addr);
            $display("%0t dma st=%0d words_left=%0d fcnt=%0d req_valid=%b a_ready=%b sd_state=%0d cur_valid=%b ref_due=%b pcmd_valid=%b pc_ready=%b psel=%0d asel=%b",
                $time, dut.dma.st, dut.dma.words_left, dut.dma.fcnt, dut.d_req_valid, dut.a_ready, dut.sdram.state, dut.sdram.cur_valid, dut.sdram.ref_due,
                dut.pd_valid, dut.pc_ready, dut.psel, dut.asel);
        end
    end
`endif
`ifdef TRACE_PS
    integer tr = 0;
    always @(posedge clk) if (dut.ph == 4'd2 && dut.step == 6'd9 && tr < 60) begin
        tr = tr + 1;
        $display("%0t ps st=%0d s=%0d ce0=%b ce1=%b adv=%b oe=%b we=%b a=%h dq0=%h dq1=%h oe_en=%b valid=%b data=%h wait=%0d",
                 $time, dut.psram.st, dut.psram.s, cram_ce0_n, cram_ce1_n, cram_adv_n, cram_oe_n, cram_we_n, cram_a, cram0_dq, cram1_dq,
                 dut.psram.dq_oe, dut.pr_valid, dut.pr_data, dut.pt_wait);
    end
`endif
    reg [5:0] last_step = 6'h3f;
    always @(posedge clk) if (dut.step !== last_step || (dut.ph == 4'd9 && 0)) begin
        last_step = dut.step;
        $display("%0t step %0d (ph %0d) sd_init=%0d", $time, dut.step, dut.ph, dut.sd_init_done);
    end
    initial begin
        repeat (10) @(posedge clk);
        rst = 0;
        while (run_state != 2 && cycles < `MAXC) begin @(posedge clk); cycles = cycles + 1; end
        repeat (200) @(posedge clk);
        $display("run_state=%0d after %0d cycles (%0.1f us)", run_state, cycles, cycles * TCK / 1000.0);
        $display("                        primary      errors         aux");
        show("SD seq write", `R_SD_SW);
        show("SD seq read", `R_SD_SR);
        show("SD random read", `R_SD_RR);
        show("SD mixed", `R_SD_MX);
        show("scan alone", `R_SC_ALONE);
        show("scan under mix", `R_SC_MIX);
        show("mixed under scan", `R_SD_MXS);
        show("scan data errs", `R_SC_ERR);
        show("PS write", `R_PS_WR);
        show("PS sweep", `R_PS_SWEEP);
        show("PS random rd", `R_PS_RR);
        show("PS seq rd", `R_PS_SR);
        show("PS sync seq", `R_PS_SYR);
        show("PS sync rnd", `R_PS_SYN);
        show("SR sweep", `R_SR_SWEEP);
        show("SR write", `R_SR_WR);
        show("SR read", `R_SR_RD);
        show("DMA async", `R_DMA_A);
        show("DMA sync", `R_DMA_S);
        show("gates", `R_GATE);
        show("status", `R_STATUS);
        show("cfg", `R_CFG);

        expect_eq("run done", `R_STATUS, 2);
        // throughput and latency arithmetic: 4 words per 4 cycles peak is 203 MB/s, one PSRAM read ~12 cycles
        expect_range("SD seq write MB/s x10", `R_SD_SW, 1900, 2035);
        expect_range("SD seq read MB/s x10", `R_SD_SR, 1900, 2035);
        expect_range("SD random read MB/s x10", `R_SD_RR, 700, 1900);
        expect_range("PSRAM random read ns x10", `R_PS_RR, 1000, 1400);
        expect_range("PSRAM write ns x10", `R_PS_WR, 800, 1300);
        expect_range("SRAM read ns x10", `R_SR_RD, 400, 900);
        expect_range("DMA async MB/s x10", `R_DMA_A, 300, 500);
        expect_eq("SD seq read errors", `R_SD_SR + 1, 0);
        expect_eq("SD random read errors", `R_SD_RR + 1, 0);
        expect_eq("SD mixed errors", `R_SD_MX + 1, 0);
`ifdef LATE
        expect_range("scan alone late lines (forced)", `R_SC_ALONE, 1, 1000000);
        expect_range("scan mix late lines (forced)", `R_SC_MIX, 1, 1000000);
`else
        expect_eq("scan alone late", `R_SC_ALONE, 0);
        expect_eq("scan mix late", `R_SC_MIX, 0);
`endif
        expect_eq("scan data errors alone", `R_SC_ERR, 0);
        expect_eq("scan data errors mixed", `R_SC_ERR + 1, 0);
        expect_eq("mixed-under-scan errors", `R_SD_MXS + 1, 0);
        expect_eq("PSRAM sweep min wait", `R_PS_SWEEP, 8);
        expect_eq("PSRAM sweep run wait", `R_PS_SWEEP + 2, 9);
        expect_eq("PSRAM random errors", `R_PS_RR + 1, 0);
        expect_eq("PSRAM seq errors", `R_PS_SR + 1, 0);
        expect_eq("SRAM min read wait", `R_SR_SWEEP, 3);
        expect_eq("SRAM min write wait", `R_SR_SWEEP + 1, 2);
        expect_eq("SRAM read errors", `R_SR_RD + 1, 0);
        expect_eq("DMA async errors", `R_DMA_A + 1, 0);
`ifdef SYNC
        expect_range("PSRAM sync burst ns x10", `R_PS_SYR, 200, 350);
        expect_range("DMA sync MB/s x10", `R_DMA_S, 1000, 1800);
        expect_eq("PSRAM sync seq errors", `R_PS_SYR + 1, 0);
        expect_eq("PSRAM sync rnd errors", `R_PS_SYN + 1, 0);
        expect_eq("DMA sync errors", `R_DMA_S + 1, 0);
`endif
`ifdef LATE
        expect_eq("gate scan-out fails when lines are late", `R_GATE + 2, 2);
`else
        expect_eq("gate scan-out", `R_GATE + 2, 1);
`endif
        expect_eq("gate psram", `R_GATE + 0, 1);
        $display("model violations: sdram=%0d psram0=%0d psram1=%0d sram=%0d (short SRAM pulses ignored: %0d)", sdram.violations, pr0.violations, pr1.violations, sram.violations, sram.short_pulses);
        if (sdram.violations + pr0.violations + pr1.violations + sram.violations != 0) fails = fails + 1;
        if (fails == 0) $display("PASS"); else $display("FAIL (%0d)", fails);
        $finish;
    end
endmodule
