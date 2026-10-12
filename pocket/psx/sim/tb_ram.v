`timescale 1ns/1ps
// ram_adapter against the real psram32 and the memtest PSRAM model, 135.4752 MHz system clock. Run from the repository root:
//   mkdir -p pocket/psx/sim/out
//   sed -e 's/\[0:524287\]/[0:1048575]/g' -e 's/524288/1048576/g' -e 's/addr\[18:0\]/{addr[21],addr[18:0]}/g' \
//       -e "s/addr\[21:19\] != 0/1'b0/" pocket/memtest/sim/psram_model.v > pocket/psx/sim/out/psram_model_ram.v
//   iverilog -g2012 -DSDRAM_135 -I pocket/common/mem -o pocket/psx/sim/out/tb_ram.vvp pocket/psx/sim/tb_ram.v \
//       pocket/psx/fpga/core/ram_adapter.v pocket/common/mem/psram32.v pocket/psx/sim/out/psram_model_ram.v
//   vvp pocket/psx/sim/out/tb_ram.vvp | tee pocket/psx/sim/out/tb_ram.log      (prints PASS or FAIL ...)
// -DEXACT uses the exact 1:3:4 clock ratio; the default detunes the three clocks so every phase relation is visited.
// The sed copy of the model stores 2^20 words per die (index {w[21], w[18:0]}), enough for the BIOS window at word 0x200000;
// the test therefore keeps word address bits 20:19 zero. Zones: main RAM words 0..0x3FFFF CPU and DMA reads, 0x40000..0x7FFFF
// DMA-FIFO writes; BIOS words 0x200000..0x27FFFF (region 3 is written by the loader); die 1 from word 0x400000.
module tb_ram;
`ifdef EXACT
    localparam real T1 = 1000.0 / 33.8688, T3 = 1000.0 / 101.6064, TS = 1000.0 / 135.4752;
`else
    localparam real T1 = 29.5271, T3 = 9.8412, TS = 7.3829;
`endif
    reg clk1x = 0, clk3x = 0, clk_sys = 0;
    always #(T1/2) clk1x = ~clk1x;
    initial #1.7 forever #(T3/2) clk3x = ~clk3x;
    initial #3.1 forever #(TS/2) clk_sys = ~clk_sys;

    reg rst = 1;

    // ---- DUT core side
    reg         ram_ena = 0, ram_rnw = 1, ram_dma = 0, ram_cache = 0;
    reg  [24:0] ram_Adr = 0;
    reg  [31:0] ram_dataWrite = 0;
    reg  [3:0]  ram_be = 0;
    reg  [1:0]  ram_cntDMA = 0;
    wire        ram_done, dma_wr, dma_reqprocessed;
    wire [31:0] ram_dataRead32, dma_data;
    wire [3:0]  cache_wr;
    wire [31:0] cache_data;
    wire [7:0]  cache_addr;
    wire        ram_dmafifo_read;
    reg         ram_dmafifo_empty = 1;
    reg  [22:0] ram_dmafifo_adr = 0;
    reg  [31:0] ram_dmafifo_data = 0;

    wire        cmd_valid, cmd_ready, cmd_we, cmd_cfg, rd_valid, done;
    wire [22:0] cmd_addr;
    wire [4:0]  cmd_len;
    wire [31:0] cmd_wdata, rd_data;
    wire [3:0]  cmd_be;
    reg         ld_valid = 0;
    wire        ld_ready;
    reg  [22:0] ld_addr = 0;
    reg  [31:0] ld_data = 0;
    wire [15:0] dbg_req, dbg_fill, dbg_dmaw;

    ram_adapter dut (
        .rst(rst), .clk1x(clk1x), .clk3x(clk3x), .clk_sys(clk_sys),
        .ram_ena(ram_ena), .ram_rnw(ram_rnw), .ram_Adr(ram_Adr), .ram_dataWrite(ram_dataWrite), .ram_be(ram_be),
        .ram_dma(ram_dma), .ram_cache(ram_cache), .ram_cntDMA(ram_cntDMA), .ram_done(ram_done), .ram_dataRead32(ram_dataRead32),
        .dma_wr(dma_wr), .dma_reqprocessed(dma_reqprocessed), .dma_data(dma_data),
        .cache_wr(cache_wr), .cache_data(cache_data), .cache_addr(cache_addr),
        .ram_dmafifo_empty(ram_dmafifo_empty), .ram_dmafifo_adr(ram_dmafifo_adr), .ram_dmafifo_data(ram_dmafifo_data),
        .ram_dmafifo_read(ram_dmafifo_read),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_we(cmd_we), .cmd_cfg(cmd_cfg), .cmd_addr(cmd_addr), .cmd_len(cmd_len),
        .cmd_wdata(cmd_wdata), .cmd_be(cmd_be), .rd_valid(rd_valid), .rd_data(rd_data), .done(done),
        .ld_valid(ld_valid), .ld_ready(ld_ready), .ld_addr(ld_addr), .ld_data(ld_data),
        .dbg_req(dbg_req), .dbg_fill(dbg_fill), .dbg_dmaw(dbg_dmaw)
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

    // ---- shadow memory: three groups of 2^19 words (RAM, BIOS window, die 1)
    reg [31:0] sh [0:(3<<19)-1];
    function integer sidx (input [22:0] w);
        sidx = (w[22] ? 2 : w[21] ? 1 : 0) * 524288 + w[18:0];
    endfunction
    function [19:0] midx (input [22:0] w);
        midx = {w[21], w[18:0]};
    endfunction
    function [31:0] bd_get (input [22:0] w);
        bd_get = w[22] ? {pr1.mem1[midx(w)], pr0.mem1[midx(w)]} : {pr1.mem0[midx(w)], pr0.mem0[midx(w)]};
    endfunction
    task bd_set (input [22:0] w, input [31:0] v);
        begin
            if (w[22]) begin pr0.mem1[midx(w)] = v[15:0]; pr1.mem1[midx(w)] = v[31:16]; end
            else       begin pr0.mem0[midx(w)] = v[15:0]; pr1.mem0[midx(w)] = v[31:16]; end
        end
    endtask

    // ---- random numbers
    reg [31:0] xs = 32'h2545F491;
    function [31:0] rnd (input dummy);
        begin
            xs = xs ^ (xs << 13); xs = xs ^ (xs >> 17); xs = xs ^ (xs << 5);
            rnd = xs;
        end
    endfunction

    integer errors = 0;
    task fail (input [255:0] msg);
        begin errors = errors + 1; if (errors < 20) $display("%0t FAIL: %0s", $time, msg); end
    endtask

    // ---- clk1x monitors
    integer cyc = 0;
    integer ena_cyc = 0, done_cyc = 0, n_ena = 0, n_fill = 0, n_done = 0;
    reg        done_seen = 0;
    reg [31:0] done_data = 0;
    integer    n_rp = 0, n_dw = 0;
    integer    rp_cyc [0:15];
    integer    dw_cyc [0:63];
    reg [31:0] dw_dat [0:63];
    always @(posedge clk1x) begin
        cyc <= cyc + 1;
        if (ram_ena) begin
            ena_cyc <= cyc; n_ena <= n_ena + 1;
            if (ram_rnw && ram_cache && !ram_dma) n_fill <= n_fill + 1;
        end
        if (ram_done) begin done_seen <= 1; done_cyc <= cyc; done_data <= ram_dataRead32; n_done <= n_done + 1; end
        if (dma_reqprocessed) begin rp_cyc[n_rp % 16] <= cyc; n_rp <= n_rp + 1; end
        if (dma_wr) begin dw_cyc[n_dw % 64] <= cyc; dw_dat[n_dw % 64] <= dma_data; n_dw <= n_dw + 1; end
    end
    event ev_rp;
    always @(posedge clk1x) if (dma_reqprocessed) -> ev_rp;

    // ---- icache fill monitor, clk3x
    reg        fl_active = 0;
    reg [3:0]  fl_mask = 0;
    reg [22:0] fl_w = 0;
    integer    fl_i;
    always @(posedge clk3x) if (|cache_wr) begin
        if (!fl_active) fail("cache write outside a fill");
        else begin
            fl_i = cache_wr[0] ? 0 : cache_wr[1] ? 1 : cache_wr[2] ? 2 : 3;
            if (cache_wr != (4'd1 << fl_i)) fail("cache_wr not one-hot");
            if (fl_i < fl_w[1:0]) fail("cache write below the requested word");
            if (fl_mask[fl_i]) fail("cache word written twice");
            fl_mask[fl_i] = 1;
            if (cache_data !== sh[sidx({fl_w[22:2], 2'b00} + fl_i)]) fail("cache data");
            if (cache_addr !== fl_w[9:2]) fail("cache_addr");
        end
    end

    // ---- DMA FIFO model on clk3x (logic of rtl/SyncFifoFallThrough.vhd, 64 entries)
    reg         f_wr = 0;
    reg  [22:0] f_adr = 0;
    reg  [31:0] f_dat = 0;
    reg  [54:0] fmem [0:63];
    reg  [5:0]  fwp = 0, frp = 0, fcnt = 0;
    reg  [5:0]  fnew;
    integer     n_pop = 0;
    wire        fempty_w = (fcnt == 0), ffull_w = (fcnt == 6'd63);
    always @(posedge clk3x) begin
        fnew = fcnt;
        if (f_wr && !ffull_w) begin if (!ram_dmafifo_read || fempty_w) fnew = fnew + 1; end
        else if (ram_dmafifo_read && !fempty_w) fnew = fnew - 1;
        if (f_wr && !ffull_w) begin fmem[fwp] <= {f_adr, f_dat}; fwp <= fwp + 1; end
        if (ram_dmafifo_read && !fempty_w) begin
            frp <= frp + 1; {ram_dmafifo_adr, ram_dmafifo_data} <= fmem[frp + 6'd1]; n_pop <= n_pop + 1;
        end else {ram_dmafifo_adr, ram_dmafifo_data} <= fmem[frp];
        ram_dmafifo_empty <= (fnew == 0) || fempty_w || (fcnt == 1 && ram_dmafifo_read);
        fcnt <= fnew;
    end

    // ---- CPU-side operations
    integer lat;
    task issue (input rnw, input [22:0] w, input [31:0] wd, input [3:0] be, input dma, input cache, input [1:0] cnt);
        begin
            @(posedge clk1x); #1;
            done_seen = 0;
            if (cache && rnw && !dma) begin fl_active = 1; fl_mask = 0; fl_w = w; end
            ram_ena = 1; ram_rnw = rnw; ram_Adr = {w, 2'b00}; ram_dataWrite = wd; ram_be = be;
            ram_dma = dma; ram_cache = cache; ram_cntDMA = cnt;
            @(posedge clk1x); #1; ram_ena = 0;
        end
    endtask
    task wait_done;
        integer t;
        begin
            t = 0;
            while (!done_seen && t < 3000) begin @(posedge clk1x); t = t + 1; end
            if (!done_seen) fail("timeout waiting for ram_done");
            @(posedge clk1x); #1;           // let the monitor's nonblocking updates settle
            lat = done_cyc - ena_cyc;
            // a request in the next cycle is legal; random idle gap
            repeat (rnd(0) % 4) @(posedge clk1x);
        end
    endtask

    integer lat_rd_min = 1000, lat_rd_sum = 0, lat_rd_n = 0, lat_wr_min = 1000, lat_wr_sum = 0, lat_wr_n = 0;
    integer lat_fl_min = 1000, lat_fl_sum = 0, lat_fl_n = 0, lat_fl4_min = 1000;
    integer c_rd = 0, c_wr = 0, c_fl = 0, c_dma = 0, c_dmaw = 0, c_ld = 0, c_bios = 0, c_die1 = 0, c_be [0:15];
    integer k;
    initial for (k = 0; k < 16; k = k + 1) c_be[k] = 0;

    task op_read (input [22:0] w);
        begin
            issue(1, w, 0, 0, 0, 0, 0);
            wait_done;
            if (done_data !== sh[sidx(w)]) begin fail("plain read data"); $display("   w=%h got %h exp %h", w, done_data, sh[sidx(w)]); end
            lat_rd_n = lat_rd_n + 1; lat_rd_sum = lat_rd_sum + lat; if (lat < lat_rd_min) lat_rd_min = lat;
            c_rd = c_rd + 1; if (w[21]) c_bios = c_bios + 1; if (w[22]) c_die1 = c_die1 + 1;
        end
    endtask
    reg [31:0] wv;
    task op_write (input [22:0] w, input [31:0] d, input [3:0] be);
        begin
            wv = sh[sidx(w)];
            if (be[0]) wv[7:0] = d[7:0];   if (be[1]) wv[15:8] = d[15:8];
            if (be[2]) wv[23:16] = d[23:16]; if (be[3]) wv[31:24] = d[31:24];
            sh[sidx(w)] = wv;
            issue(0, w, d, be, 0, 0, 0);
            wait_done;
            lat_wr_n = lat_wr_n + 1; lat_wr_sum = lat_wr_sum + lat; if (lat < lat_wr_min) lat_wr_min = lat;
            c_wr = c_wr + 1; c_be[be] = c_be[be] + 1; if (w[22]) c_die1 = c_die1 + 1;
        end
    endtask
    task op_fill (input [22:0] w);
        begin
            issue(1, w, 0, 0, 0, 1, 0);
            wait_done;
            if (done_data !== sh[sidx(w)]) begin fail("fill first word"); $display("   w=%h got %h exp %h", w, done_data, sh[sidx(w)]); end
            if (fl_mask !== (4'hF << w[1:0]) && fl_mask !== ((4'hF << w[1:0]) & 4'hF)) begin
                fail("done before all cache writes"); $display("   w=%h mask %b", w, fl_mask);
            end
            fl_active = 0;
            lat_fl_n = lat_fl_n + 1; lat_fl_sum = lat_fl_sum + lat; if (lat < lat_fl_min) lat_fl_min = lat;
            if (w[1:0] == 0 && lat < lat_fl4_min) lat_fl4_min = lat;
            c_fl = c_fl + 1;
        end
    endtask

    // chain of DMA reads as dma.vhd issues them: the next request the cycle after dma_reqprocessed
    integer di, dj, dtotal, dbase_dw, dbase_rp, dk;
    reg [22:0] dw_adr [0:7];
    integer    dcnt [0:7];
    task op_dma (input [22:0] w0, input integer nreq);
        begin
            dbase_dw = n_dw; dbase_rp = n_rp; dtotal = 0;
            for (di = 0; di < nreq; di = di + 1) begin
                dcnt[di] = rnd(0) % 4;
                dw_adr[di] = (di == 0) ? w0 : dw_adr[di-1] + dcnt[di-1] + 1;
                dtotal = dtotal + dcnt[di] + 1;
            end
            for (di = 0; di < nreq; di = di + 1) begin
                if (di == 0) issue(1, dw_adr[0], 0, 0, 1, 0, dcnt[0]);
                else begin
                    @(ev_rp); #1;
                    ram_ena = 1; ram_Adr = {dw_adr[di], 2'b00}; ram_cntDMA = dcnt[di];
                    @(posedge clk1x); #1; ram_ena = 0;
                end
            end
            dk = 0;
            while ((n_dw - dbase_dw) < dtotal && dk < 3000) begin @(posedge clk1x); dk = dk + 1; end
            @(posedge clk1x); #1;
            if ((n_dw - dbase_dw) !== dtotal) fail("DMA word count");
            if ((n_rp - dbase_rp) !== nreq) fail("dma_reqprocessed count");
            dj = 0;
            for (di = 0; di < nreq; di = di + 1) begin
                for (dk = 0; dk <= dcnt[di]; dk = dk + 1) begin
                    if (dw_dat[(dbase_dw + dj) % 64] !== sh[sidx(dw_adr[di] + dk)]) begin
                        fail("DMA data"); $display("   w=%h got %h exp %h", dw_adr[di] + dk, dw_dat[(dbase_dw + dj) % 64], sh[sidx(dw_adr[di] + dk)]);
                    end
                    if (dk > 0 && dw_cyc[(dbase_dw + dj) % 64] !== dw_cyc[(dbase_dw + dj - 1) % 64] + 1) fail("DMA words not consecutive");
                    if (dk == 0 && dw_cyc[(dbase_dw + dj) % 64] <= rp_cyc[(dbase_rp + di) % 16]) fail("DMA data before reqprocessed");
                    dj = dj + 1;
                end
            end
            repeat (rnd(0) % 3) @(posedge clk1x);
            c_dma = c_dma + 1;
        end
    endtask

    // ---- FIFO and loader threads
    reg        run_f = 0, run_l = 0;
    integer    n_push = 0, n_ldw = 0;
    reg        f_busy = 0, l_busy = 0;
    task push_word (input [22:0] w, input [31:0] d);
        begin
            while (fcnt > 6'd56) @(posedge clk3x);
            @(posedge clk3x); #0.5;
            f_wr = 1; f_adr = {w[20:0], 2'b00}; f_dat = d; sh[sidx(w)] = d;
            @(posedge clk3x); #0.5; f_wr = 0;
            n_push = n_push + 1;
        end
    endtask
    integer fb;
    task fifo_burst (input integer n);
        begin
            for (fb = 0; fb < n; fb = fb + 1) begin
                push_word(23'h40000 + (rnd(0) % 23'h40000), rnd(0));
                if (rnd(0) % 4 == 0) repeat (rnd(0) % 6) @(posedge clk3x);
            end
        end
    endtask
    task ld_word (input [22:0] w, input [31:0] d);
        begin
            @(posedge clk_sys); #0.5;
            ld_valid = 1; ld_addr = w; ld_data = d; sh[sidx(w)] = d;
            @(posedge clk_sys);
            while (!ld_ready) @(posedge clk_sys);       // accepted at the edge where ld_ready is high
            #0.5; ld_valid = 0;
            n_ldw = n_ldw + 1; c_ld = c_ld + 1;
        end
    endtask
    integer lb;
    task ld_burst (input integer n);
        begin
            for (lb = 0; lb < n; lb = lb + 1) begin
                ld_word(23'h260000 + (rnd(0) % 23'h2000), rnd(0));
                if (rnd(0) % 3 == 0) repeat (rnd(0) % 20) @(posedge clk_sys);
            end
        end
    endtask

    integer fcount = 0, lcount = 0;
    initial begin : fifo_thread
        wait (run_f);
        while (run_f) begin
            f_busy = 1;
            fifo_burst(1 + rnd(0) % 24);
            f_busy = 0;
            repeat (rnd(0) % 400) @(posedge clk3x);
        end
    end
    initial begin : ld_thread
        wait (run_l);
        while (run_l) begin
            l_busy = 1;
            ld_burst(1 + rnd(0) % 12);
            l_busy = 0;
            repeat (rnd(0) % 800) @(posedge clk_sys);
        end
    end

    // ---- CPU thread helpers
    function [22:0] pick_ram (input dummy);  pick_ram  = rnd(0) % 23'h3FFF0; endfunction
    function [22:0] pick_die1 (input dummy); pick_die1 = 23'h400000 + (rnd(0) % 23'h3FFF0); endfunction
    function [22:0] pick_bios (input integer max_region);
        pick_bios = 23'h200000 + (rnd(0) % (max_region * 23'h20000));
    endfunction
    reg [31:0] r;
    reg [22:0] a;
    integer i, n;
    task cpu_ops (input integer n, input integer bios_regions);
        integer j;
        begin
            for (j = 0; j < n; j = j + 1) begin
                r = rnd(0);
                case (r[7:0] % 10)
                    0, 1: op_read(pick_ram(0));
                    2:    op_read(pick_bios(bios_regions));
                    3:    op_read(pick_die1(0));
                    4, 5: op_write(pick_ram(0), rnd(0), rnd(0));
                    6:    op_write(pick_die1(0), rnd(0), rnd(0));
                    7, 8: op_fill(pick_ram(0));
                    default: op_dma(pick_ram(0), 1 + rnd(0) % 4);
                endcase
            end
        end
    endtask

    task compare_zone (input [22:0] base, input integer n, input [255:0] what);
        integer j;
        begin
            for (j = 0; j < n; j = j + 1)
                if (bd_get(base + j) !== sh[sidx(base + j)]) begin
                    fail(what); $display("   w=%h got %h exp %h", base + j, bd_get(base + j), sh[sidx(base + j)]); j = n;
                end
        end
    endtask

    integer tries, nbe;
    task print_lat (input [511:0] what);
        begin
            $display("latency, %0s (clk1x cycles, ena to done): plain read min %0d avg %0d; write ack min %0d avg %0d; fill min %0d avg %0d (Adr[3:2]=0 min %0d)",
                     what, lat_rd_min, lat_rd_sum / lat_rd_n, lat_wr_min, lat_wr_sum / lat_wr_n, lat_fl_min, lat_fl_sum / lat_fl_n, lat_fl4_min);
            lat_rd_min = 1000; lat_rd_sum = 0; lat_rd_n = 0; lat_wr_min = 1000; lat_wr_sum = 0; lat_wr_n = 0;
            lat_fl_min = 1000; lat_fl_sum = 0; lat_fl_n = 0; lat_fl4_min = 1000;
        end
    endtask
    initial begin
        $display("tb_ram: clocks %0.4f / %0.4f / %0.4f ns", T1, T3, TS);
        // known contents everywhere the test can touch
        for (i = 0; i < 3 * 524288; i = i + 1) sh[i] = 32'hxxxxxxxx;
        for (i = 0; i < 524288; i = i + 1) begin
            sh[i] = rnd(0);                bd_set(i, sh[i]);
            sh[524288 + i] = rnd(0);       bd_set(23'h200000 + i, sh[524288 + i]);
            sh[2*524288 + i] = rnd(0);     bd_set(23'h400000 + i, sh[2*524288 + i]);
        end
        repeat (40) @(posedge clk1x);
        rst = 0;
        repeat (60) @(posedge clk1x);

        // ---- phase 1: CPU traffic alone, latencies
        $display("phase 1: CPU requests only");
        for (i = 0; i < 4; i = i + 1) op_read(pick_ram(0));
        for (i = 0; i < 4; i = i + 1) begin op_fill(23'h100 + 4 * i + 0); op_fill(23'h200 + 4 * i + 1); op_fill(23'h300 + 4 * i + 2); op_fill(23'h400 + 4 * i + 3); end
        for (i = 0; i < 16; i = i + 1) op_write(pick_ram(0), rnd(0), i[3:0]);     // every byte-enable pattern
        for (i = 0; i < 16; i = i + 1) begin a = pick_ram(0); op_write(a, rnd(0), i[3:0]); op_read(a); end
        for (i = 0; i < 4; i = i + 1) begin op_dma(pick_ram(0), 1); end
        for (i = 0; i < 4; i = i + 1) op_dma(23'h1000 + i, 6);
        for (i = 0; i < 4; i = i + 1) op_read(23'h200000 + 23'h20000 * i + 5);
        cpu_ops(1500, 4);
        $display("  phase 1 done: %0d requests", n_ena);
        print_lat("phase 1 (idle memory)");

        // ---- phase 2: CPU traffic with DMA-FIFO writes and loader writes running concurrently
        $display("phase 2: CPU + DMA FIFO writes + loader writes");
        run_f = 1; run_l = 1;
        cpu_ops(3500, 3);
        run_f = 0; run_l = 0;
        wait (!f_busy && !l_busy);
        $display("  phase 2 done: %0d requests, %0d FIFO words, %0d loader words", n_ena, n_push, n_ldw);

        // ---- phase 3: drain, read back through the adapter, compare the whole model
        $display("phase 3: drain and verify");
        tries = 0;
        while ((ram_dmafifo_empty == 0 || ld_valid || cmd_valid || !cmd_ready) && tries < 2000) begin @(posedge clk1x); tries = tries + 1; end
        repeat (20) @(posedge clk1x);
        if (n_pop !== n_push) fail("FIFO entries popped differ from pushed");
        for (i = 0; i < 400; i = i + 1) begin
            a = 23'h40000 + (rnd(0) % 23'h40000); op_read(a);
            a = 23'h260000 + (rnd(0) % 23'h2000); op_read(a);
        end
        // pushes followed by reads two cycles later (the shortest legal gap): the read must see the new data
        for (i = 0; i < 40; i = i + 1) begin
            a = 23'h40000 + (rnd(0) % 23'h40000);
            push_word(a, rnd(0));
            repeat (2) @(posedge clk1x);
            op_read(a);
        end
        repeat (50) @(posedge clk1x);
        compare_zone(23'h000000, 524288, "RAM model contents");
        compare_zone(23'h200000, 524288, "BIOS window model contents");
        compare_zone(23'h400000, 524288, "die 1 model contents");
        if (dbg_req   !== n_ena[15:0])  begin fail("dbg_req");  $display("   %0d vs %0d", dbg_req, n_ena); end
        if (dbg_fill  !== n_fill[15:0]) begin fail("dbg_fill"); $display("   %0d vs %0d", dbg_fill, n_fill); end
        if (dbg_dmaw  !== n_push[15:0]) begin fail("dbg_dmaw"); $display("   %0d vs %0d", dbg_dmaw, n_push); end
        if (n_ena !== n_done + n_rp) begin fail("done count"); $display("   ena %0d done %0d rp %0d", n_ena, n_done, n_rp); end

        $display("ops: %0d requests (%0d plain reads incl. %0d BIOS-window and die 1, %0d writes, %0d fills, %0d DMA chains), %0d FIFO writes, %0d loader writes",
                 n_ena, c_rd, c_bios + c_die1, c_wr, c_fl, c_dma, n_push, n_ldw);
        nbe = 0;
        for (i = 0; i < 16; i = i + 1) if (c_be[i] > 0) nbe = nbe + 1;
        $display("byte-enable patterns seen: %0d of 16", nbe);
        print_lat("phase 2 (FIFO and loader writes competing)");
        $display("model violations: %0d %0d", pr0.violations, pr1.violations);
        if (pr0.violations != 0 || pr1.violations != 0) fail("PSRAM model violations");
        if (n_ena < 5000) fail("fewer than 5000 requests");
        if (errors == 0) $display("PASS"); else $display("FAIL: %0d errors", errors);
        $finish;
    end

    initial begin #60_000_000; $display("FAIL: global timeout"); $finish; end
endmodule
