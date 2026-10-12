`timescale 1ns/1ps
// bios_loader + ram_adapter + psram32 + PSRAM model: a 512 KB image written through the APF bridge (74.25 MHz), big-endian
// words, lands byte-swapped at word 0x200000 of the PSRAM. Run from the repository root:
//   mkdir -p pocket/psx/sim/out
//   sed -e 's/\[0:524287\]/[0:1048575]/g' -e 's/524288/1048576/g' -e 's/addr\[18:0\]/{addr[21],addr[18:0]}/g' \
//       -e "s/addr\[21:19\] != 0/1'b0/" pocket/memtest/sim/psram_model.v > pocket/psx/sim/out/psram_model_ram.v
//   iverilog -g2012 -DSDRAM_135 -I pocket/common/mem -o pocket/psx/sim/out/tb_bios_loader.vvp pocket/psx/sim/tb_bios_loader.v \
//       pocket/psx/fpga/core/bios_loader.v pocket/psx/fpga/core/ram_adapter.v pocket/common/mem/psram32.v pocket/psx/sim/out/psram_model_ram.v
//   vvp pocket/psx/sim/out/tb_bios_loader.vvp | tee pocket/psx/sim/out/tb_bios_loader.log      (prints PASS or FAIL ...)
// Bridge pace for the image: one write per PACE clk_74a (default 9, 121 ns, just above the PSRAM write time); +define+PACE=n overrides.
module tb_bios_loader;
`ifndef PACE
`define PACE 9
`endif
    reg clk_74a = 0, clk1x = 0, clk3x = 0, clk_sys = 0;
    always #6.734 clk_74a = ~clk_74a;
    always #14.7636 clk1x = ~clk1x;
    initial #1.7 forever #4.9212 clk3x = ~clk3x;
    initial #3.1 forever #3.6910 clk_sys = ~clk_sys;
    reg rst = 1;

    reg         bridge_wr = 0;
    reg  [31:0] bridge_addr = 0, bridge_wr_data = 0;
    wire        ld_valid, ld_ready, err;
    wire [22:0] ld_addr;
    wire [31:0] ld_data;
    wire [17:0] words;

    bios_loader ldr (
        .rst(rst), .clk_74a(clk_74a), .clk_sys(clk_sys),
        .bridge_wr(bridge_wr), .bridge_addr(bridge_addr), .bridge_wr_data(bridge_wr_data),
        .ld_valid(ld_valid), .ld_ready(ld_ready), .ld_addr(ld_addr), .ld_data(ld_data), .words(words), .err(err)
    );

    wire        cmd_valid, cmd_ready, cmd_we, cmd_cfg, rd_valid, done;
    wire [22:0] cmd_addr;
    wire [4:0]  cmd_len;
    wire [31:0] cmd_wdata, rd_data;
    wire [3:0]  cmd_be;
    ram_adapter ad (
        .rst(rst), .clk1x(clk1x), .clk3x(clk3x), .clk_sys(clk_sys),
        .ram_ena(1'b0), .ram_rnw(1'b1), .ram_Adr(25'd0), .ram_dataWrite(32'd0), .ram_be(4'd0), .ram_dma(1'b0), .ram_cache(1'b0),
        .ram_cntDMA(2'd0), .ram_done(), .ram_dataRead32(), .dma_wr(), .dma_reqprocessed(), .dma_data(),
        .cache_wr(), .cache_data(), .cache_addr(),
        .ram_dmafifo_empty(1'b1), .ram_dmafifo_adr(23'd0), .ram_dmafifo_data(32'd0), .ram_dmafifo_read(),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_we(cmd_we), .cmd_cfg(cmd_cfg), .cmd_addr(cmd_addr), .cmd_len(cmd_len),
        .cmd_wdata(cmd_wdata), .cmd_be(cmd_be), .rd_valid(rd_valid), .rd_data(rd_data), .done(done),
        .ld_valid(ld_valid), .ld_ready(ld_ready), .ld_addr(ld_addr), .ld_data(ld_data),
        .dbg_req(), .dbg_fill(), .dbg_dmaw()
    );

    wire [21:16] cram_a; wire [15:0] cram0_dq, cram1_dq;
    wire cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n, cram_oe_n, cram_we_n;
    wire cram0_ub_n, cram0_lb_n, cram1_ub_n, cram1_lb_n;
    psram32 psram (
        .clk(clk_sys), .rst(rst),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_we(cmd_we), .cmd_cfg(cmd_cfg), .cmd_addr(cmd_addr),
        .cmd_len(cmd_len), .cmd_wdata(cmd_wdata), .cmd_be(cmd_be),
        .sync_mode(1'b0), .rd_wait(5'd12), .sync_lc(3'd3), .sync_phase(2'd0),
        .rd_valid(rd_valid), .rd_data(rd_data), .done(done),
        .cram_a(cram_a), .cram0_dq(cram0_dq), .cram1_dq(cram1_dq), .cram_clk(cram_clk),
        .cram_adv_n(cram_adv_n), .cram_cre(cram_cre), .cram_ce0_n(cram_ce0_n), .cram_ce1_n(cram_ce1_n),
        .cram_oe_n(cram_oe_n), .cram_we_n(cram_we_n),
        .cram0_ub_n(cram0_ub_n), .cram0_lb_n(cram0_lb_n), .cram1_ub_n(cram1_ub_n), .cram1_lb_n(cram1_lb_n)
    );
    psram_model pr0 (.a(cram_a), .dq(cram0_dq), .wait_o(), .clk(cram_clk), .adv_n(cram_adv_n), .cre(cram_cre),
                     .ce0_n(cram_ce0_n), .ce1_n(cram_ce1_n), .oe_n(cram_oe_n), .we_n(cram_we_n), .ub_n(cram0_ub_n), .lb_n(cram0_lb_n));
    psram_model pr1 (.a(cram_a), .dq(cram1_dq), .wait_o(), .clk(cram_clk), .adv_n(cram_adv_n), .cre(cram_cre),
                     .ce0_n(cram_ce0_n), .ce1_n(cram_ce1_n), .oe_n(cram_oe_n), .we_n(cram_we_n), .ub_n(cram1_ub_n), .lb_n(cram1_lb_n));

    // expected BIOS image as the PSX sees it (little-endian words), and what the bridge sends (big-endian words)
    reg [31:0] exp [0:131071];
    function [31:0] swap (input [31:0] d); swap = {d[7:0], d[15:8], d[23:16], d[31:24]}; endfunction
    function [31:0] got (input integer k);
        got = {pr1.mem0[{1'b1, k[18:0]}], pr0.mem0[{1'b1, k[18:0]}]};
    endfunction

    integer errors = 0;
    task fail (input [255:0] msg);
        begin errors = errors + 1; if (errors < 20) $display("%0t FAIL: %0s", $time, msg); end
    endtask

    // loader port monitor: accepted writes, drain time
    integer n_acc = 0, bad_addr = 0;
    realtime m_t0 = 0, m_t1 = 0;
    integer  meas = 0, m_n = 0;
    always @(posedge clk_sys) if (ld_valid && ld_ready) begin
        if (meas) begin if (m_n == 0) m_t0 = $realtime; m_t1 = $realtime; m_n = m_n + 1; end
        n_acc = n_acc + 1;
        if (ld_addr < 23'h200000 || ld_addr > 23'h21FFFF) bad_addr = bad_addr + 1;
    end

    task bridge_write (input [31:0] a, input [31:0] d, input integer pace);
        begin
            @(posedge clk_74a); #0.5;
            bridge_wr = 1; bridge_addr = a; bridge_wr_data = d;
            @(posedge clk_74a); #0.5;
            bridge_wr = 0; bridge_addr = 32'hxxxxxxxx; bridge_wr_data = 32'hxxxxxxxx;
            repeat (pace - 1) @(posedge clk_74a);
        end
    endtask

    task wait_idle;
        integer t;
        begin
            t = 0;
            repeat (40) @(posedge clk_sys);
            while ((ld_valid || cmd_valid || !cmd_ready) && t < 20000) begin @(posedge clk_sys); t = t + 1; end
            repeat (60) @(posedge clk_sys);
        end
    endtask

    task check_image (input [255:0] what);
        integer k, bad;
        begin
            bad = 0;
            for (k = 0; k < 131072; k = k + 1)
                if (got(k) !== exp[k]) begin
                    if (bad < 3) $display("   %0s word %0d got %h exp %h", what, k, got(k), exp[k]);
                    bad = bad + 1;
                end
            if (bad != 0) fail(what);
        end
    endtask

    reg [31:0] x = 32'h9E3779B9;
    function [31:0] rnd (input dummy);
        begin x = x ^ (x << 13); x = x ^ (x >> 17); x = x ^ (x << 5); rnd = x; end
    endfunction

    integer k, n_before;
    reg [31:0] be_word;
    initial begin
        for (k = 0; k < 131072; k = k + 1) exp[k] = 32'hxxxxxxxx;
        repeat (40) @(posedge clk_sys);
        rst = 0;
        repeat (40) @(posedge clk_sys);

        // ---- the whole image, one write per PACE clk_74a
        $display("image: 131072 words, one bridge write per %0d clk_74a (%0.1f ns)", `PACE, `PACE * 13.468);
        for (k = 0; k < 131072; k = k + 1) begin
            be_word = rnd(0);                          // what the bridge delivers: first file byte in [31:24]
            exp[k] = swap(be_word);
            bridge_write(32'h20000000 + 4 * k, be_word, `PACE);
        end
        wait_idle;
        if (words !== 18'd131072) begin fail("words"); $display("   words %0d", words); end
        if (err !== 1'b0) fail("err after the image");
        if (n_acc !== 131072) begin fail("loader writes"); $display("   %0d", n_acc); end
        if (bad_addr != 0) fail("loader address outside region 0");
        check_image("image");
        $display("image loaded: %0d words, err=%0b", words, err);

        // ---- writes outside the window are ignored
        n_before = n_acc;
        bridge_write(32'h20080000, 32'hDEADBEEF, 12);
        bridge_write(32'h2007FFFC + 32'h8, 32'hDEADBEEF, 12);
        bridge_write(32'h1FFFFFFC, 32'hDEADBEEF, 12);
        bridge_write(32'h00000000, 32'hDEADBEEF, 12);
        bridge_write(32'h80000100, 32'hDEADBEEF, 12);
        bridge_write(32'h30000000, 32'hDEADBEEF, 12);
        wait_idle;
        if (n_acc !== n_before) fail("write outside the window reached the loader");
        if (words !== 18'd131072) fail("words changed by outside writes");
        check_image("image after outside writes");

        // ---- a burst of 500 back-to-back writes fits in the FIFO; it also measures the drain rate; it restarts the word count
        $display("burst: 500 writes, one per clk_74a");
        n_before = n_acc; meas = 1; m_n = 0;
        for (k = 0; k < 500; k = k + 1) begin
            be_word = rnd(0);
            exp[k] = swap(be_word);
            bridge_write(32'h20000000 + 4 * k, be_word, 1);
        end
        wait_idle;
        if (err !== 1'b0) fail("err after a 500-word burst");
        if (n_acc - n_before !== 500) fail("burst writes lost");
        if (words !== 18'd500) begin fail("words after the burst"); $display("   words %0d", words); end
        check_image("image after burst");
        meas = 0;
        $display("loader port drain: %0.1f ns per write while backlogged (%0d writes)", (m_t1 - m_t0) / (m_n - 1), m_n);

        // ---- a burst longer than the FIFO overflows: dropped words, sticky err
        $display("burst: 800 writes, one per clk_74a");
        for (k = 0; k < 800; k = k + 1) bridge_write(32'h20000000 + 4 * (1000 + k), rnd(0), 1);
        wait_idle;
        if (err !== 1'b1) fail("no err after overflow");
        for (k = 0; k < 300; k = k + 1) bridge_write(32'h20001000 + 4 * k, rnd(0), 12);
        wait_idle;
        if (err !== 1'b1) fail("err not sticky");
        $display("overflow: err=%0b", err);

        if (pr0.violations != 0 || pr1.violations != 0) fail("PSRAM model violations");
        if (errors == 0) $display("PASS"); else $display("FAIL: %0d errors", errors);
        $finish;
    end

    initial begin #400_000_000; $display("FAIL: global timeout"); $finish; end
endmodule
