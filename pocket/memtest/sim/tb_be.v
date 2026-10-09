`timescale 1ns/10fs
// Byte-enable test of sdram_ctl against the SDRAM model, with a shadow memory: random bursts with random
// per-byte masks (including all-set and all-clear), many repeats of the same burst, reads interleaved.
// Every read burst is compared with the shadow, and at the end every word of the model's array is compared
// with it, so each masked byte is checked. SDRAM_135 selects the 135.4752 MHz variant; BE_FAULT inverts the
// DQM lane of the byte-enable pins and must be reported as caught. See docs/pocket/MEMTEST.md.
module tb_be;
    `include "memtest_defs.vh"
    `include "cal_sim.vh"
`ifdef SDRAM_135
    parameter real TCK = 1000.0 / 135.4752;
`else
    parameter real TCK = 9.842;
`endif
    localparam integer N_OPS = 40000;

    reg clk = 0;
    always #(TCK/2) clk = ~clk;
    // the capture clock comes from the PLL stand-in and is placed by the calibration
    wire clk_cap, clk_scan, ps_en, ps_up, ps_done;
    wire cal_done, cal_ok;
    wire [6:0] cal_width, cal_boot, cal_centre;
    wire [3:0] cal_flags;
    pll_dps_model #(.SCAN_DIV(`SIM_SCAN_DIV)) pll (.clk(clk), .clk_scan(clk_scan), .phase_en(ps_en), .updn(ps_up),
        .cntsel(5'd2), .phase_done(ps_done), .clk_cap(clk_cap));
    reg rst = 1;

    reg         req_valid = 0, req_we = 0, req_tag = 0;
    wire        req_ready;
    reg  [24:0] req_addr = 0;
    reg  [63:0] req_wdata = 0;
    reg  [7:0]  req_be = 8'hFF;
    wire        rd_valid, rd_tag, init_done;
    wire [63:0] rd_data;

    wire [12:0] dram_a; wire [1:0] dram_ba; wire [15:0] dram_dq; wire [1:0] dram_dqm;
    wire dram_ras_n, dram_cas_n, dram_we_n;

    sdram_ctl #(.INIT_CYCLES(300)) dut (
        .clk(clk), .clk_cap(clk_cap), .rst(rst), .init_done(init_done),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we), .req_addr(req_addr),
        .req_wdata(req_wdata), .req_be(req_be), .req_tag(req_tag),
        .rd_valid(rd_valid), .rd_data(rd_data), .rd_tag(rd_tag),
        .dram_a(dram_a), .dram_ba(dram_ba), .dram_dq(dram_dq), .dram_dqm(dram_dqm),
        .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_we_n(dram_we_n),
        .pll_locked(1'b1), .cal_tick(1'b0), .clk_scan(clk_scan), .ps_en(ps_en), .ps_up(ps_up), .ps_done(ps_done),
        .cal_done(cal_done), .cal_ok(cal_ok), .cal_width(cal_width), .cal_boot(cal_boot), .cal_centre(cal_centre),
        .cal_min(), .cal_max(), .cal_moves(), .cal_flags(cal_flags)
    );

`ifdef BE_FAULT
    wire [1:0] dqm_m = dram_dqm ^ 2'b01;
`else
    wire [1:0] dqm_m = dram_dqm;
`endif
    sdram_model #(.TCK(TCK), .PAD_NS(`SIM_PAD_NS)) sdram (.clk(clk), .a(dram_a), .ba(dram_ba), .dq(dram_dq), .dqm(dqm_m),
                       .ras_n(dram_ras_n), .cas_n(dram_cas_n), .we_n(dram_we_n));

    // shadow memory, indexed by the controller's word address {row[8:0], bank, col}
    reg [15:0] sh [0:(1<<21)-1];
    reg        known [0:(1<<19)-1];    // per burst
    integer i;
    initial for (i = 0; i < (1 << 19); i = i + 1) known[i] = 0;

    // reads in flight: expected data, in order
    reg [63:0] exp_q [0:63];
    reg [23:0] adr_q [0:63];
    integer    qw = 0, qr = 0;

    integer seed = 32'h1BADB002;
    integer ops_done = 0, writes = 0, reads = 0, partial = 0, zero_mask = 0, masked_bytes = 0;
    integer mism = 0, mism_bytes = 0;
    integer r, k;
    reg [31:0] x;
    reg [24:0] a;
    reg [63:0] d;
    reg [7:0]  m;
    reg        we;
    reg [18:0] b;

    function [63:0] merge;     // 64-bit view of the shadow words of the burst at word address w
        input [24:0] w;
        begin
            merge = {sh[w[20:0] + 3], sh[w[20:0] + 2], sh[w[20:0] + 1], sh[w[20:0]]};
        end
    endfunction

    task shadow_write;
        input [24:0] w;
        input [63:0] data;
        input [7:0]  be;
        integer j;
        begin
            for (j = 0; j < 4; j = j + 1) begin
                if (be[2*j])     sh[w[20:0] + j][7:0]  = data[16*j +: 8];
                if (be[2*j + 1]) sh[w[20:0] + j][15:8] = data[16*j + 8 +: 8];
            end
        end
    endtask

    // next operation: 70% from a small hot set (rows 0..3, banks 0..3, a few columns), 30% anywhere in 512 rows
    task pick;
        begin
            x = $random(seed);
            if (x[31:30] != 2'b00) begin
                a = {11'd0, x[9:8], x[7:6], 6'd0, x[5:4], 2'b00};                      // row 0..3, bank, col in {0,4,8,12}
            end else begin
                x = $random(seed);
                a = {4'd0, x[8:0], x[10:9], x[19:12], 2'b00};                          // row[8:0], bank, col (multiple of 4)
            end
            b = {a[20:12], a[11:10], a[9:2]};
            x = $random(seed);
            we = x[0];
            d = {$random(seed), $random(seed)};
            case (x[4:2])
                3'd0, 3'd1: m = 8'hFF;
                3'd2:       m = 8'h00;
                default:    m = $random(seed);
            endcase
            if (!known[b]) begin we = 1; m = 8'hFF; end
        end
    endtask

    reg        fin = 0;
    reg        acc;
    always @(posedge clk) if (!rst && !fin) begin
        acc = req_valid && req_ready;
        if (acc) begin
            if (req_we) begin
                shadow_write(req_addr, req_wdata, req_be);
                known[{req_addr[20:12], req_addr[11:10], req_addr[9:2]}] = 1;
                writes = writes + 1;
                if (req_be != 8'hFF && req_be != 8'h00) partial = partial + 1;
                if (req_be == 8'h00) zero_mask = zero_mask + 1;
                for (k = 0; k < 8; k = k + 1) if (!req_be[k]) masked_bytes = masked_bytes + 1;
            end else begin
                exp_q[qw[5:0]] = merge(req_addr); adr_q[qw[5:0]] = req_addr[23:0];
                qw = qw + 1; reads = reads + 1;
            end
            req_valid <= 0;
            ops_done = ops_done + 1;
        end
        if ((!req_valid || acc) && ops_done < N_OPS && init_done && (qw - qr) < 16) begin
            pick;
            req_valid <= 1; req_we <= we; req_addr <= a; req_wdata <= d; req_be <= m;
        end
        if (rd_valid) begin
            if (rd_data !== exp_q[qr[5:0]]) begin
                mism = mism + 1;
                for (k = 0; k < 8; k = k + 1) if (rd_data[8*k +: 8] !== exp_q[qr[5:0]][8*k +: 8]) mism_bytes = mism_bytes + 1;
                if (mism <= 5) $display("%0t READ MISMATCH at word %h: got %h want %h", $time, adr_q[qr[5:0]], rd_data, exp_q[qr[5:0]]);
            end
            qr = qr + 1;
        end
    end

    integer words = 0, bytes_cmp = 0, bad_words = 0, bad_bytes = 0;
    reg [15:0] mw, sw;
    reg [23:0] w21;
    integer bb;
    initial begin
        repeat (10) @(posedge clk);
        rst = 0;
        wait (ops_done >= N_OPS);
        wait (qr == qw);
        repeat (200) @(posedge clk);
        fin = 1;
        // every known word of the model's array against the shadow
        for (bb = 0; bb < (1 << 19); bb = bb + 1) if (known[bb]) begin
            for (k = 0; k < 4; k = k + 1) begin
                // burst index {row[8:0], bank, col[9:2]} -> word address {row, bank, col}
                w21 = {bb[18:10], bb[9:8], bb[7:0], 2'b00} + k;
                sw = sh[w21[20:0]];
                mw = sdram.mem[{w21[11:10], w21[20:12], w21[9:0]}];     // model index {bank, row, col}
                words = words + 1; bytes_cmp = bytes_cmp + 2;
                if (mw !== sw) begin
                    bad_words = bad_words + 1;
                    if (mw[7:0] !== sw[7:0]) bad_bytes = bad_bytes + 1;
                    if (mw[15:8] !== sw[15:8]) bad_bytes = bad_bytes + 1;
                    if (bad_words <= 5) $display("ARRAY MISMATCH at word %h: model %h shadow %h", w21, mw, sw);
                end
            end
        end
        $display("clock %0.4f MHz: %0d requests (%0d writes of which %0d partial masks and %0d all-masked, %0d masked bytes; %0d reads)",
                 1000.0 / TCK, ops_done, writes, partial, zero_mask, masked_bytes, reads);
        $display("read bursts mismatching the shadow: %0d (%0d bytes); model array: %0d words (%0d bytes) compared, %0d words (%0d bytes) wrong",
                 mism, mism_bytes, words, bytes_cmp, bad_words, bad_bytes);
        $display("model violations: sdram=%0d; capture eye %0d steps, centre %0d, flags %b, PLL steps %0d",
                 sdram.violations, cal_width, cal_centre, cal_flags, pll.nsteps);
`ifdef BE_FAULT
        if (mism + bad_words > 0) $display("PASS (fault caught)"); else $display("FAIL (injected fault not caught)");
`else
        if (mism + bad_words == 0 && sdram.violations == 0 && partial > 1000 && zero_mask > 100 && cal_done && cal_ok && pll.range_viol == 0) $display("PASS"); else $display("FAIL");
`endif
        $finish;
    end

    initial begin
        #2000000000;
        $display("FAIL (timeout)");
        $finish;
    end
endmodule
