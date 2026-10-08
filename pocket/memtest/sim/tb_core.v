`timescale 1ns/10fs
// Whole-core simulation: memtest_core with behavioural SDRAM, PSRAM and SRAM models.
// Reduced test sizes unless FULL is defined (SDFULL: the SDRAM and scan-out sizes of FULL, everything else reduced).
// SDRAM_135 runs the 135.4752 MHz variant. Prints the result table and checks it.
`ifndef MAXC
`define MAXC 60000000
`endif
module tb_core;
    `include "memtest_defs.vh"
`ifdef SDRAM_135
    parameter real TCK = 1000.0 / 135.4752;
`else
    parameter real TCK = 9.842;
`endif
`ifdef FULL
    localparam SD_REG_BITS = 17, SD_RND_LOG2 = 16, SC_LINES = 96, SC_Y_WRAP = 480, PS_REG_BITS = 19, PS_SEQ_LOG2 = 16,
               PS_RND_LOG2 = 14, PS_SWEEP_LOG2 = 11, DMA_LOG2 = 16, SR_SWEEP_LOG2 = 10, SR_N_LOG2 = 16,
               SD_INIT = `MT_SD_INIT;
`elsif SDFULL
    localparam SD_REG_BITS = 17, SD_RND_LOG2 = 16, SC_LINES = 96, SC_Y_WRAP = 480, PS_REG_BITS = 8, PS_SEQ_LOG2 = 8,
               PS_RND_LOG2 = 8, PS_SWEEP_LOG2 = 6, DMA_LOG2 = 8, SR_SWEEP_LOG2 = 7, SR_N_LOG2 = 9,
               SD_INIT = 300;
`else
    localparam SD_REG_BITS = 11, SD_RND_LOG2 = 10, SC_LINES = 4, SC_Y_WRAP = 8, PS_REG_BITS = 8, PS_SEQ_LOG2 = 8,
               PS_RND_LOG2 = 8, PS_SWEEP_LOG2 = 6, DMA_LOG2 = 8, SR_SWEEP_LOG2 = 7, SR_N_LOG2 = 9,
               SD_INIT = 300;
`endif
`ifdef LATE
    localparam SC_NUM = 500, SC_DEN = 1;    // shorter than the 640 cycles one line needs: every line is late
`else
    localparam SC_NUM = `MT_LINE_NUM, SC_DEN = `MT_LINE_DEN;
`endif
`ifdef PS_TAA
    localparam real PS_T_AA = `PS_TAA;     // slower PSRAM: the sweep must find a larger wait
`else
    localparam real PS_T_AA = 70.0;
`endif
`ifdef PS_STUCK_BIT
    localparam integer STUCK = `PS_STUCK_BIT;   // word address bit stuck in the PSRAM model
`else
    localparam integer STUCK = -1;
`endif
`ifdef PS_BRIDGE_BIT
    localparam integer BRIDGE = `PS_BRIDGE_BIT; // word address bits BRIDGE and BRIDGE+1 shorted in the PSRAM model
    `define PS_ADDR_FAULT
`else
    localparam integer BRIDGE = -1;
`endif
`ifdef PS_STUCK_BIT
    `define PS_ADDR_FAULT
`endif
`ifdef PS_STUCK_HI
    localparam STUCK_V = 1'b1;
`else
    localparam STUCK_V = 1'b0;
`endif
`ifdef SYNC
    localparam SYNC_EN = 1;
`else
    localparam SYNC_EN = 0;
`endif

    reg clk = 0;
    always #(TCK/2) clk = ~clk;
    // SDRAM clock = system clock here. The capture clock sits inside the read data window, after the
    // system clock edge that ends the CL + 3 cycle read latency, as the hardware phases do (docs/pocket/MEMTEST.md).
    // 101 MHz: half a period late, with the pad and routing delays of the read path folded into the model.
    // 135 MHz: the datasheet model with no added delay, capture 0.26 ns late (middle of tAC .. tOH).
`ifdef SDRAM_135
    wire clk_cap;
    assign #0.26 clk_cap = clk;
`else
    wire clk_cap = ~clk;
`endif
    reg rst = 1;

    // ---- APF bridge throughput bench (SLOT): slot_bench on a 74.25 MHz clock against a host model that answers
    // target_dataslot_read at a fixed rate (MEMTEST.md, Bridge throughput bench)
`ifdef SLOT
    localparam real T74 = 1000.0 / 74.25;
    localparam integer SL_N = 16;                   // requests per mode
    localparam integer SL_L_SEQ = 550;              // clk_74a cycles from command to the first word: sequential / random
    localparam integer SL_L_RND = 4500;
    localparam integer SL_WORD = 30;                // clk_74a cycles per 32-bit word (588 words per request)
    localparam integer SL_LAG = 270;                // last word to done
`ifdef SLOT_NOFILE
    localparam integer SL_FILE = 0;
`else
    localparam integer SL_FILE = 9000000;
`endif
    localparam [31:0] SL_FILE_Q = SL_FILE;
    reg clk74 = 0;
    always #(T74/2) clk74 = ~clk74;
    reg sl_reset_n = 0, sl_go = 0;
    reg sl_wr = 0; reg [31:0] sl_addr = 0;
    reg sl_done = 1, sl_ack = 0; reg [2:0] sl_err = 0;
    wire        sl_read; wire [15:0] sl_id; wire [31:0] sl_off, sl_baddr, sl_len;
    wire slot_tog; wire [6:0] slot_wa; wire [32:0] slot_wd;
    slot_bench #(.N_REQ(SL_N), .START_DELAY(2000), .TIMEOUT(2000000)) sb (
        .clk(clk74), .reset_n(sl_reset_n), .go_tog(sl_go), .bridge_wr(sl_wr), .bridge_addr(sl_addr),
        .dt_addr(), .dt_q(SL_FILE_Q),
        .tgt_read(sl_read), .tgt_id(sl_id), .tgt_off(sl_off), .tgt_baddr(sl_baddr), .tgt_len(sl_len),
        .tgt_ack(sl_ack), .tgt_done(sl_done), .tgt_err(sl_err),
        .res_tog(slot_tog), .res_wa(slot_wa), .res_wd(slot_wd));

    // host model; expected figures are accumulated from the model's own timestamps ($realtime), per mode
    reg sl_read_d = 0;
    event sl_cmd;
    always @(posedge clk74) begin sl_read_d <= sl_read; if (sl_read && !sl_read_d) -> sl_cmd; end
    integer sl_req = 0, sl_prev_end = 0, sl_bad_cmd = 0, sl_seq_n = 0, sl_rnd_n = 0, sl_bytes0 = 0, sl_bytes1 = 0;
    real sl_t_cmd, sl_t_last, sl_t_done;
    real sl_sum0 = 0, sl_sum1 = 0, sl_wl0 = 0, sl_wl1 = 0, sl_wd0 = 0, sl_wd1 = 0;
    integer sl_w, sl_words, sl_mode;
    initial forever begin
        @(sl_cmd);
        sl_t_cmd = $realtime - T74;       // the bench stamped the command one cycle before this event
        sl_mode = (sl_req >= SL_N);
        if (sl_id !== 16'd1 || sl_len !== 32'd2352 || sl_baddr !== 32'h20000000 || sl_off + sl_len > SL_FILE
            || sl_off % 2352 != 0) begin
            sl_bad_cmd = sl_bad_cmd + 1;
            $display("  CHECK FAILED: request %0d id %0d offset %0d length %0d window %h", sl_req, sl_id, sl_off, sl_len, sl_baddr);
        end
        // sequential after the previous one: the short latency
        sl_words = sl_len / 4;
`ifdef SLOT_SHORT
        if (sl_mode) sl_words = sl_words - 1;
`endif
        repeat (3) @(posedge clk74);
        sl_done <= 0; sl_ack <= 0;
        repeat ((sl_off == sl_prev_end) ? SL_L_SEQ : SL_L_RND) @(posedge clk74);
        sl_ack <= 1;
        for (sl_w = 0; sl_w < sl_words; sl_w = sl_w + 1) begin
            @(posedge clk74); sl_wr <= 1; sl_addr <= sl_baddr + 4 * sl_w;
            @(posedge clk74); sl_wr <= 0;
            repeat (SL_WORD - 2) @(posedge clk74);
        end
        sl_t_last = $realtime - (SL_WORD - 2) * T74;     // the cycle after the last word's write pulse starts (the bench's view)
        repeat (SL_LAG) @(posedge clk74);
        sl_done <= 1; sl_err <= 0;
        @(posedge clk74); sl_t_done = $realtime;
        @(posedge clk74); sl_ack <= 0;
        sl_prev_end = sl_off + sl_len;
        if (!sl_mode) begin
            sl_sum0 = sl_sum0 + (sl_t_done - sl_t_cmd); sl_bytes0 = sl_bytes0 + 4 * sl_words;
            if (sl_t_last - sl_t_cmd > sl_wl0) sl_wl0 = sl_t_last - sl_t_cmd;
            if (sl_t_done - sl_t_cmd > sl_wd0) sl_wd0 = sl_t_done - sl_t_cmd;
        end else begin
            sl_sum1 = sl_sum1 + (sl_t_done - sl_t_cmd); sl_bytes1 = sl_bytes1 + 4 * sl_words;
            if (sl_t_last - sl_t_cmd > sl_wl1) sl_wl1 = sl_t_last - sl_t_cmd;
            if (sl_t_done - sl_t_cmd > sl_wd1) sl_wd1 = sl_t_done - sl_t_cmd;
        end
        sl_req = sl_req + 1;
    end
`else
    wire slot_tog = 1'b0; wire [6:0] slot_wa = 7'd0; wire [32:0] slot_wd = 33'd0;
`endif

    wire [12:0] dram_a; wire [1:0] dram_ba; wire [15:0] dram_dq; wire [1:0] dram_dqm;
    wire dram_ras_n, dram_cas_n, dram_we_n;
    wire [21:16] cram_a; wire [15:0] cram0_dq, cram1_dq;
    wire cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n, cram_oe_n, cram_we_n;
    wire cram0_ub_n, cram0_lb_n, cram1_ub_n, cram1_lb_n;
    wire [16:0] sram_a; wire [15:0] sram_dq; wire sram_oe_n, sram_we_n, sram_ub_n, sram_lb_n;

    wire [32:0] rq, rq_b; wire [1:0] run_state;
    reg  [6:0] ra = 0;

    memtest_core #(.SD_REG_BITS(SD_REG_BITS), .SD_RND_LOG2(SD_RND_LOG2), .SC_LINES(SC_LINES), .SC_Y_WRAP(SC_Y_WRAP), .SC_LINE_NUM(SC_NUM), .SC_LINE_DEN(SC_DEN),
                   .PS_REG_BITS(PS_REG_BITS), .PS_SEQ_LOG2(PS_SEQ_LOG2), .PS_RND_LOG2(PS_RND_LOG2), .PS_SWEEP_LOG2(PS_SWEEP_LOG2),
                   .DMA_LOG2(DMA_LOG2), .SR_SWEEP_LOG2(SR_SWEEP_LOG2), .SR_N_LOG2(SR_N_LOG2),
                   .SD_INIT_CYCLES(SD_INIT), .WD_BITS(25)) dut (
        .clk(clk), .clk_cap(clk_cap), .rst(rst), .seed_in(32'h1234ABCD),
        .cfg_sync_en(SYNC_EN[0]), .cfg_lc(3'd3), .cfg_phase(2'd2), .cfg_loop(1'b0),
        .res_ra(ra), .res_rq(rq), .res_clk_b(clk), .res_rb(7'd0), .res_rq_b(rq_b), .run_state(run_state),
        .slot_tog(slot_tog), .slot_wa(slot_wa), .slot_wd(slot_wd),
        .dram_a(dram_a), .dram_ba(dram_ba), .dram_dq(dram_dq), .dram_dqm(dram_dqm),
        .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_we_n(dram_we_n),
        .cram_a(cram_a), .cram0_dq(cram0_dq), .cram1_dq(cram1_dq), .cram_clk(cram_clk), .cram_adv_n(cram_adv_n),
        .cram_cre(cram_cre), .cram_ce0_n(cram_ce0_n), .cram_ce1_n(cram_ce1_n), .cram_oe_n(cram_oe_n),
        .cram_we_n(cram_we_n), .cram0_ub_n(cram0_ub_n), .cram0_lb_n(cram0_lb_n),
        .cram1_ub_n(cram1_ub_n), .cram1_lb_n(cram1_lb_n),
        .sram_a(sram_a), .sram_dq(sram_dq), .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n),
        .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n)
    );

`ifdef SDRAM_135
    sdram_model #(.TCK(TCK)) sdram (.clk(clk), .a(dram_a), .ba(dram_ba), .dq(dram_dq), .dqm(dram_dqm),
                       .ras_n(dram_ras_n), .cas_n(dram_cas_n), .we_n(dram_we_n));
`else
    // pad and routing delays of the read path folded into the model: data valid tAC + 4.2 ns after the
    // clock edge, held until tOH + 3.7 ns after the next one (as seen at the capture register)
    sdram_model #(.TCK(TCK), .T_AC(`SDT_TAC_NS + 4.2), .T_OH(`SDT_TOH_NS + 3.7)) sdram (.clk(clk), .a(dram_a), .ba(dram_ba), .dq(dram_dq), .dqm(dram_dqm),
                       .ras_n(dram_ras_n), .cas_n(dram_cas_n), .we_n(dram_we_n));
`endif
    psram_model #(.T_AA(PS_T_AA), .STUCK_BIT(STUCK), .STUCK_VAL(STUCK_V), .BRIDGE_BIT(BRIDGE)) pr0 (.a(cram_a), .dq(cram0_dq), .wait_o(), .clk(cram_clk), .adv_n(cram_adv_n), .cre(cram_cre),
                     .ce0_n(cram_ce0_n), .ce1_n(cram_ce1_n), .oe_n(cram_oe_n), .we_n(cram_we_n),
                     .ub_n(cram0_ub_n), .lb_n(cram0_lb_n));
    psram_model #(.T_AA(PS_T_AA), .STUCK_BIT(STUCK), .STUCK_VAL(STUCK_V), .BRIDGE_BIT(BRIDGE)) pr1 (.a(cram_a), .dq(cram1_dq), .wait_o(), .clk(cram_clk), .adv_n(cram_adv_n), .cre(cram_cre),
                     .ce0_n(cram_ce0_n), .ce1_n(cram_ce1_n), .oe_n(cram_oe_n), .we_n(cram_we_n),
                     .ub_n(cram1_ub_n), .lb_n(cram1_lb_n));
    sram_model sram (.a(sram_a), .dq(sram_dq), .oe_n(sram_oe_n), .we_n(sram_we_n), .ub_n(sram_ub_n), .lb_n(sram_lb_n));

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

    // The bench counts the cycles of every SDRAM engine step itself, to check the reported MB/s.
    integer bc [0:63];
    integer ii;
    initial for (ii = 0; ii < 64; ii = ii + 1) bc[ii] = 0;
    always @(posedge clk) if (dut.sdt.busy) bc[dut.step] = bc[dut.step] + 1;

    integer mb_diff = 0;
    // reported MB/s x10 against bytes x clock / cycles counted here
    task check_mbps;
        input [255:0] name;
        input integer i;
        input integer step;
        input integer bytes;
        reg [32:0] v;
        real e;
        integer want;
        begin
            v = res(i);
            e = bytes * (`MT_CLK_HZ / 1.0e5) / bc[step];
            want = $rtoi(e);
            $display("  %-18s step %0d: %0d cycles counted here, %0d bytes -> %0d (x0.1 MB/s) by the bench, %0d reported", name, step, bc[step], bytes, want, v[31:0]);
            if (!v[32] || v[31:0] !== want) begin
                mb_diff = mb_diff + 1;
                fails = fails + 1;
                $display("  CHECK FAILED: %0s MB/s: reported %0d, bench count gives %0d", name, v[31:0], want);
            end
        end
    endtask

    integer cycles = 0;

`ifdef SLOT
    // the bench's reported kB/s and latencies against the host model's own timestamps
    task slot_wait_done;
        input integer first;       // 1: the state word may still read 0 (not yet started)
        integer n;
        reg [32:0] v;
        begin
            n = 0;
            v = res(`R_SL_FILE + 1);
            while (!(v[32] && v[31:0] >= 2) && n < 40000000) begin @(posedge clk); n = n + 1; v = res(`R_SL_FILE + 1); end
            repeat (200) @(posedge clk);
        end
    endtask

    task slot_expect_mode;
        input [255:0] name;
        input integer base;          // R_SL_SEQ or R_SL_RND
        input integer basex;
        input real sum_ns;
        input real wl_ns;
        input real wd_ns;
        input integer bytes;
        input integer want_bad;
        reg [32:0] k, l, b, d, nr, rb;
        integer want_k, want_l, want_d;
        begin
            k = res(base); l = res(base + 1); b = res(base + 2); d = res(basex); nr = res(basex + 1); rb = res(basex + 2);
            want_k = $rtoi(bytes * 1.0e6 / sum_ns);
            want_l = $rtoi(wl_ns / 1000.0);
            want_d = $rtoi(wd_ns / 1000.0);
            $display("  %-10s kB/s %0d (model %0d)  worst last-byte us %0d (model %0d)  worst done us %0d (model %0d)  requests %0d  bytes %0d  bad %0d",
                     name, k[31:0], want_k, l[31:0], want_l, d[31:0], want_d, nr[31:0], rb[31:0], b[31:0]);
            if (!k[32] || !l[32] || !b[32] || !d[32] || !nr[32] || !rb[32]) begin fails = fails + 1; $display("  CHECK FAILED: %0s slot results not valid", name); end
            // 0.3 % on the rate, 1 us on a latency (the bench counts clk_74a cycles, the model $realtime)
            if (k[31:0] + k[31:0] / 300 + 2 < want_k || k[31:0] > want_k + want_k / 300 + 2) begin fails = fails + 1; $display("  CHECK FAILED: %0s kB/s", name); end
            if (l[31:0] + 1 < want_l || l[31:0] > want_l + 1) begin fails = fails + 1; $display("  CHECK FAILED: %0s worst last-byte latency", name); end
            if (d[31:0] + 1 < want_d || d[31:0] > want_d + 1) begin fails = fails + 1; $display("  CHECK FAILED: %0s worst done latency", name); end
            if (nr[31:0] !== SL_N) begin fails = fails + 1; $display("  CHECK FAILED: %0s request count", name); end
            if (rb[31:0] !== bytes) begin fails = fails + 1; $display("  CHECK FAILED: %0s bytes received", name); end
            if (b[31:0] !== want_bad) begin fails = fails + 1; $display("  CHECK FAILED: %0s bad requests %0d, expected %0d", name, b[31:0], want_bad); end
        end
    endtask

    task slot_checks;
        begin
`ifdef SLOT_NOFILE
            $display("slot bench, no file:");
            slot_wait_done(1);
            expect_eq("slot seq kB/s = no file", `R_SL_SEQ, 32'hFFFFFFFF);
            expect_eq("slot rnd kB/s = no file", `R_SL_RND, 32'hFFFFFFFF);
            expect_eq("slot state = no file", `R_SL_FILE + 1, 3);
            expect_eq("slot file size", `R_SL_FILE, 0);
            if (sl_req != 0) begin fails = fails + 1; $display("  CHECK FAILED: %0d requests issued without a file", sl_req); end
`else
            $display("slot bench (host model: %0d cycles to the first word, %0d random, %0d per word, %0d to done):", SL_L_SEQ, SL_L_RND, SL_WORD, SL_LAG);
            slot_wait_done(1);
            expect_eq("slot state = done", `R_SL_FILE + 1, 2);
            expect_eq("slot file size", `R_SL_FILE, SL_FILE);
            expect_eq("slot expected bytes", `R_SL_FILE + 2, SL_N * 2352);
            slot_expect_mode("sequential", `R_SL_SEQ, `R_SL_SEQX, sl_sum0, sl_wl0, sl_wd0, sl_bytes0, 0);
`ifdef SLOT_SHORT
            // a request that falls short has no last byte: its last-byte latency is its done latency
            slot_expect_mode("random", `R_SL_RND, `R_SL_RNDX, sl_sum1, sl_wd1, sl_wd1, sl_bytes1, SL_N);
`else
            slot_expect_mode("random", `R_SL_RND, `R_SL_RNDX, sl_sum1, sl_wl1, sl_wd1, sl_bytes1, 0);
`endif
            if (sl_bad_cmd != 0) fails = fails + 1;
            if (sl_req != 2 * SL_N) begin fails = fails + 1; $display("  CHECK FAILED: %0d requests, expected %0d", sl_req, 2 * SL_N); end
`ifndef SLOT_SHORT
            // restart: the bench runs again from scratch and reports the same way
            sl_req = 0; sl_prev_end = 0; sl_sum0 = 0; sl_sum1 = 0; sl_wl0 = 0; sl_wl1 = 0; sl_wd0 = 0; sl_wd1 = 0; sl_bytes0 = 0; sl_bytes1 = 0;
            sl_go = ~sl_go;
            begin : rs
                integer n; reg [32:0] v;
                n = 0; v = res(`R_SL_FILE + 1);
                while (!(v[32] && v[31:0] == 1) && n < 100000) begin @(posedge clk); n = n + 1; v = res(`R_SL_FILE + 1); end
                if (n >= 100000) begin fails = fails + 1; $display("  CHECK FAILED: the restart did not invalidate the slot results"); end
            end
            slot_wait_done(1);
            $display("after a restart:");
            expect_eq("slot state = done", `R_SL_FILE + 1, 2);
            slot_expect_mode("sequential", `R_SL_SEQ, `R_SL_SEQX, sl_sum0, sl_wl0, sl_wd0, sl_bytes0, 0);
            slot_expect_mode("random", `R_SL_RND, `R_SL_RNDX, sl_sum1, sl_wl1, sl_wd1, sl_bytes1, 0);
`endif
`endif
        end
    endtask
`endif
`ifdef TRACE_DMA
    integer acc = 0;
    always @(posedge clk) if (dut.step == 6'd12 && dut.sdram.req_valid && dut.sdram.req_ready && acc < 4) begin
        acc = acc + 1;
        $display("%0t ACCEPT c_addr=%h a_addr=%h d_req_addr=%h b_addr=%h sel_b=%b b_valid=%b", $time, dut.c_addr, dut.a_addr, dut.d_req_addr, dut.b_addr, dut.arb.sel_b, dut.b_valid);
    end
    integer dcnt = 0;
    always @(posedge clk) if (dut.step == 6'd12 && dut.ph == 4'd2) begin
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
    always @(posedge clk) if (dut.ph == 4'd2 && dut.step == 6'd10 && tr < 60) begin
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
`ifdef SLOT
        sl_reset_n = 1;
`endif
        while (run_state != 2 && cycles < `MAXC) begin @(posedge clk); cycles = cycles + 1; end
        repeat (200) @(posedge clk);
        $display("run_state=%0d after %0d cycles (%0.1f us)", run_state, cycles, cycles * TCK / 1000.0);
        $display("                        primary      errors         aux");
        show("SD seq write", `R_SD_SW);
        show("SD seq read", `R_SD_SR);
        show("SD random read", `R_SD_RR);
        show("SD mixed", `R_SD_MX);
        show("SD byte mask", `R_SD_BE);
        show("scan alone", `R_SC_ALONE);
        show("scan under mix", `R_SC_MIX);
        show("mixed under scan", `R_SD_MXS);
        show("scan data errs", `R_SC_ERR);
        show("PS write", `R_PS_WR);
        show("PS sweep", `R_PS_SWEEP);
        show("PS addr walk", `R_PS_AW);
        show("PS random rd", `R_PS_RR);
        show("PS rd wall", `R_PS_RW);
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
`ifdef SDRAM_135
        // 4 words per 4 cycles at 135.4752 MHz is 270.9 MB/s
        expect_range("SD seq write MB/s x10", `R_SD_SW, 2520, 2710);
        expect_range("SD seq read MB/s x10", `R_SD_SR, 2520, 2710);
        expect_range("SD random read MB/s x10", `R_SD_RR, 700, 2600);
`else
        expect_range("SD seq write MB/s x10", `R_SD_SW, 1900, 2035);
        expect_range("SD seq read MB/s x10", `R_SD_SR, 1900, 2035);
        expect_range("SD random read MB/s x10", `R_SD_RR, 700, 1900);
`endif
        expect_eq("SD byte-enable readback errors", `R_SD_BE + 1, 0);
        expect_range("SD byte-enable write MB/s x10", `R_SD_BE, 500, 2710);
        check_mbps("SD seq write", `R_SD_SW, 1, 8 << SD_REG_BITS);
        check_mbps("SD seq read", `R_SD_SR, 2, 8 << SD_REG_BITS);
        check_mbps("SD random read", `R_SD_RR, 3, 8 << SD_RND_LOG2);
        check_mbps("SD mixed", `R_SD_MX, 4, 8 << SD_RND_LOG2);
        check_mbps("MIXED UNDER SCAN", `R_SD_MXS, 6, 8 << SD_RND_LOG2);
        check_mbps("SD byte-enable write", `R_SD_BE, 24, 8 << SD_REG_BITS);
        begin : mbs
            reg [32:0] m1, m2;
            m1 = res(`R_SD_MX); m2 = res(`R_SD_MXS);
            $display("MIXED MB/s = %0d.%0d", m1[31:0] / 10, m1[31:0] % 10);
            $display("MIXED UNDER SCAN MB/s = %0d.%0d", m2[31:0] / 10, m2[31:0] % 10);
        end
`ifndef PS_TAA
  `ifdef SDRAM_135
        expect_range("PSRAM random read ns x10", `R_PS_RR, 900, 1300);
        expect_range("PSRAM random read wall ns x10", `R_PS_RW, 1100, 1300);
  `else
        expect_range("PSRAM random read ns x10", `R_PS_RR, 1000, 1400);
        expect_range("PSRAM random read wall ns x10", `R_PS_RW, 1300, 1500);
  `endif
`endif
        expect_range("PSRAM write ns x10", `R_PS_WR, 800, 1300);
        expect_range("SRAM read ns x10", `R_SR_RD, 400, 900);
`ifndef PS_TAA
        expect_range("DMA async MB/s x10", `R_DMA_A, 300, 500);
`endif
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
`ifdef PS_TAA
        // a slow part: the sweep must see the larger wait, and the wait used is one more
        expect_range("PSRAM sweep min wait (slow part)", `R_PS_SWEEP, 9, 20);
        begin : slow_chk
            reg [32:0] mn, us;
            mn = res(`R_PS_SWEEP); us = res(`R_PS_SWEEP + 2);
            if (us[31:0] !== mn[31:0] + 1) begin fails = fails + 1; $display("  CHECK FAILED: wait used %0d != min %0d + 1", us[31:0], mn[31:0]); end
        end
`else
  `ifdef SDRAM_135
        // 70 ns access: 9 cycles of 7.38 ns are 66 ns, 10 are 74 ns
        expect_eq("PSRAM sweep min wait", `R_PS_SWEEP, 10);
        expect_eq("PSRAM sweep run wait", `R_PS_SWEEP + 2, 11);
  `else
        expect_eq("PSRAM sweep min wait", `R_PS_SWEEP, 8);
        expect_eq("PSRAM sweep run wait", `R_PS_SWEEP + 2, 9);
  `endif
`endif
`ifdef PS_ADDR_FAULT
        expect_range("PS walk errors, addr fault", `R_PS_AW + 1, 1, 1000000);
`else
        expect_eq("PSRAM address walk errors", `R_PS_AW + 1, 0);
`endif
`ifndef PS_STUCK_BIT   // the injected fault corrupts word 0, which later tests read
        expect_eq("PSRAM random errors", `R_PS_RR + 1, 0);
`endif
`ifndef PS_STUCK_BIT   // the injected fault corrupts word 0, which later tests read
        expect_eq("PSRAM seq errors", `R_PS_SR + 1, 0);
`endif
`ifdef SDRAM_135
        // 25 ns access, 15 ns write pulse: 4 cycles (29.5 ns) and 3 cycles (22.1 ns) at 7.38 ns
        expect_eq("SRAM min read wait", `R_SR_SWEEP, 4);
        expect_eq("SRAM min write wait", `R_SR_SWEEP + 1, 3);
`else
        expect_eq("SRAM min read wait", `R_SR_SWEEP, 3);
        expect_eq("SRAM min write wait", `R_SR_SWEEP + 1, 2);
`endif
        expect_eq("SRAM read errors", `R_SR_RD + 1, 0);
`ifndef PS_STUCK_BIT   // the injected fault corrupts word 0, which later tests read
        expect_eq("DMA async errors", `R_DMA_A + 1, 0);
`endif
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
`ifdef PS_ADDR_FAULT   // with PS_BRIDGE_BIT only the walk sees the fault: the random reads stay clean
        expect_eq("gate psram fails, addr fault", `R_GATE + 0, 2);
`elsif PS_TAA
  `ifdef PS_GATE_PASS
        expect_eq("gate psram passes at 177 ns wall clock", `R_GATE + 0, 1);
  `else
        expect_eq("gate psram fails for a slow part", `R_GATE + 0, 2);
  `endif
`else
        expect_eq("gate psram", `R_GATE + 0, 1);
`endif
`ifdef SLOT
        slot_checks;
`endif
        $display("model violations: sdram=%0d psram0=%0d psram1=%0d sram=%0d (short SRAM pulses ignored: %0d)", sdram.violations, pr0.violations, pr1.violations, sram.violations, sram.short_pulses);
        if (sdram.violations + pr0.violations + pr1.violations + sram.violations != 0) fails = fails + 1;
        if (fails == 0) $display("PASS"); else $display("FAIL (%0d)", fails);
        $finish;
    end
endmodule
