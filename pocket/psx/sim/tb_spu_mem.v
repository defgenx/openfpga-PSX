// spu_adapter + psx_sdram_arb + vram_adapter against a behavioural sdram_ctl request port (clk_sys): the GPU side issues random
// writes and read bursts up to 128 beats back to back, the SPU side random 16-bit reads and writes, one outstanding.
// Checks data of both clients against shadow memories and asserts the SPU's latency (ena to done) <= BUDGET clk1x cycles.
// The controller model: a request is accepted when idle and no refresh is due, held 4..16 cycles (worst row miss: tRAS wait,
// PRE, ACT, CAS), read data 12 cycles after that, in order; a refresh every 934 cycles blocks for 23. See docs/pocket/POCKET_TOP.md.
//   cd pocket/psx && iverilog -g2012 -o sim/out/spu_mem.vvp sim/tb_spu_mem.v fpga/core/spu_adapter.v fpga/core/psx_sdram_arb.v \
//       fpga/core/vram_adapter.v fpga/core/async_fifo.v && vvp sim/out/spu_mem.vvp      (prints PASS on its own line)
// Optional: -DNSPU=<ops> (default 6000), -DSEED=<n>.
`timescale 1ns/1ps
`ifndef NSPU
`define NSPU 6000
`endif
`ifndef SEED
`define SEED 1
`endif
module tb_spu_mem;
    localparam NSPU = `NSPU;
    localparam BUDGET = 23;                    // clk1x cycles, per voice slot
    localparam [24:0] BASE = 25'h0800000;

    reg clk1x = 0, clk2x = 0, clk_sys = 0;
    always #7.381 clk2x = ~clk2x;
    always #14.762 clk1x = ~clk1x;
    initial begin #2.2; forever #3.6905 clk_sys = ~clk_sys; end

    integer errs = 0, seed_g = `SEED, seed_s = `SEED + 77, seed_m = `SEED + 999;
    function integer rg(input integer n); begin rg = {$random(seed_g)} % n; end endfunction
    function integer rs(input integer n); begin rs = {$random(seed_s)} % n; end endfunction
    function integer rm(input integer n); begin rm = {$random(seed_m)} % n; end endfunction

    // ---------------- memory model, qwords; GPU region words < 2^17 qwords, SPU region at BASE ----------------
    reg [63:0] mem [0:(1<<17)+(1<<16)-1];
    function integer midx(input [24:0] a);       // word address -> model index
        begin midx = a[23] ? ((1 << 17) + a[17:2]) : a[18:2]; end
    endfunction
    function [63:0] initv(input integer i); begin initv = {i[31:0] ^ 32'h5A5A1234, i[31:0] * 32'h9E3779B1}; end endfunction
    integer ii;
    initial for (ii = 0; ii < (1<<17)+(1<<16); ii = ii + 1) mem[ii] = initv(ii);

    // ---------------- DUTs ----------------
    reg         ddr3_RD = 0, ddr3_WE = 0;
    reg  [27:0] ddr3_ADDR = 0;
    reg  [63:0] ddr3_DIN = 0;
    reg  [7:0]  ddr3_BE = 0, ddr3_BURSTCNT = 0;
    wire        ddr3_BUSY, ddr3_DOUT_READY;
    wire [63:0] ddr3_DOUT;
    wire        a_valid, a_ready, a_we, a_rvalid, b_valid, b_ready, b_we, b_rvalid;
    wire [24:0] a_addr, b_addr;
    wire [63:0] a_wdata, b_wdata;
    wire [7:0]  a_be, b_be;
    wire        c_valid, c_we, c_tag;
    reg         c_ready = 0, c_rvalid = 0, c_rtag = 0;
    wire [24:0] c_addr;
    wire [63:0] c_wdata;
    wire [7:0]  c_be;
    reg  [63:0] c_rdata = 0;
    wire [15:0] dbg_r, dbg_w;
    reg         init_done = 0;

    vram_adapter vad (
        .clk2x(clk2x), .clk_sys(clk_sys), .init_done(init_done),
        .ddr3_RD(ddr3_RD), .ddr3_WE(ddr3_WE), .ddr3_ADDR(ddr3_ADDR), .ddr3_DIN(ddr3_DIN), .ddr3_BE(ddr3_BE),
        .ddr3_BURSTCNT(ddr3_BURSTCNT), .ddr3_BUSY(ddr3_BUSY), .ddr3_DOUT(ddr3_DOUT), .ddr3_DOUT_READY(ddr3_DOUT_READY),
        .req_valid(a_valid), .req_ready(a_ready), .req_we(a_we), .req_addr(a_addr), .req_wdata(a_wdata), .req_be(a_be),
        .rd_valid(a_rvalid), .rd_data(c_rdata), .dbg_reads(dbg_r), .dbg_writes(dbg_w)
    );

    reg         ena = 0, rnw = 1;
    reg  [18:0] adr = 0;
    reg  [31:0] dwr = 0;
    wire [31:0] drd;
    wire        done;
    spu_adapter #(.BASE(BASE)) sad (
        .clk1x(clk1x), .clk_sys(clk_sys), .ena(ena), .rnw(rnw), .adr(adr), .dataWrite(dwr), .dataRead(drd), .done(done),
        .req_valid(b_valid), .req_ready(b_ready), .req_we(b_we), .req_addr(b_addr), .req_wdata(b_wdata), .req_be(b_be),
        .rd_valid(b_rvalid), .rd_data(c_rdata)
    );

    psx_sdram_arb sarb (
        .a_valid(a_valid), .a_ready(a_ready), .a_we(a_we), .a_addr(a_addr), .a_wdata(a_wdata), .a_be(a_be),
        .b_valid(b_valid), .b_ready(b_ready), .b_we(b_we), .b_addr(b_addr), .b_wdata(b_wdata), .b_be(b_be),
        .c_valid(c_valid), .c_ready(c_ready), .c_we(c_we), .c_addr(c_addr), .c_wdata(c_wdata), .c_be(c_be), .c_tag(c_tag),
        .c_rvalid(c_rvalid), .c_rtag(c_rtag), .a_rvalid(a_rvalid), .b_rvalid(b_rvalid)
    );

    // ---------------- controller model, clk_sys ----------------
    integer busy = 0, refcnt = 0, refblk = 0;
    reg        cur_v = 0, cur_we = 0, cur_tag = 0;
    reg [24:0] cur_a;
    reg [63:0] cur_d;
    reg [7:0]  cur_b;
    // read return pipeline
    reg [63:0] rq_d [0:63];
    reg        rq_t [0:63];
    integer    rq_at [0:63];
    integer    rq_h = 0, rq_n = 0, rq_w = 0, cyc = 0;
    integer    b;
    reg [63:0] w;
    integer    max_busy_seen = 0;
    always @(posedge clk_sys) begin
        cyc = cyc + 1;
        c_rvalid <= 0;
        if (rq_n > 0 && cyc >= rq_at[rq_h]) begin
            c_rvalid <= 1; c_rdata <= rq_d[rq_h]; c_rtag <= rq_t[rq_h];
            rq_h = (rq_h + 1) % 64; rq_n = rq_n - 1;
        end
        if (init_done) begin
            refcnt = refcnt + 1;
            if (refcnt >= 934 && !cur_v) begin refcnt = 0; refblk = 23; end
            if (refblk > 0) refblk = refblk - 1;
            if (cur_v) begin
                if (busy > 0) busy = busy - 1;
                else begin
                    if (cur_we) begin
                        w = mem[midx(cur_a)];
                        for (b = 0; b < 8; b = b + 1) if (cur_b[b]) w[b*8 +: 8] = cur_d[b*8 +: 8];
                        mem[midx(cur_a)] = w;
                    end else begin
                        rq_d[rq_w] = mem[midx(cur_a)]; rq_t[rq_w] = cur_tag; rq_at[rq_w] = cyc + 12;
                        rq_w = (rq_w + 1) % 64; rq_n = rq_n + 1;
                    end
                    cur_v = 0;
                end
            end
            c_ready <= (!cur_v && refblk == 0) && !(c_ready && c_valid);   // one cycle high, then the request is taken
            if (c_ready && c_valid) begin
                cur_v = 1; cur_we = c_we; cur_tag = c_tag; cur_a = c_addr; cur_d = c_wdata; cur_b = c_be;
                busy = 4 + rm(13);
                if (busy > max_busy_seen) max_busy_seen = busy;
            end
        end else c_ready <= 0;
    end

    // ---------------- GPU driver, clk2x ----------------
    reg [63:0] gsh [0:(1<<17)-1];
    initial for (ii = 0; ii < (1<<17); ii = ii + 1) gsh[ii] = initv(ii);
    integer gops = 0, gexp_n = 0, gexp_i, gq [0:255];
    integer gnext;
    reg [63:0] gx;
    task gwait_free; begin while (ddr3_BUSY) @(posedge clk2x); end endtask
    // read data checker: the expected qwords in order
    integer gchk_h = 0, gchk_t = 0;
    reg [63:0] gexp [0:1023];
    always @(posedge clk2x) if (ddr3_DOUT_READY) begin
        if (gchk_h == gchk_t) begin errs = errs + 1; if (errs < 10) $display("ERR: GPU data without a request"); end
        else begin
            if (ddr3_DOUT !== gexp[gchk_h % 1024]) begin errs = errs + 1; if (errs < 10) $display("ERR @%0t: GPU read %h want %h", $time, ddr3_DOUT, gexp[gchk_h % 1024]); end
            gchk_h = gchk_h + 1;
        end
    end
    reg stop_g = 0;
    integer gi, gn, gaddr;
    initial begin
        wait (init_done);
        repeat (4) @(posedge clk2x);
        while (!stop_g) begin
            gwait_free;
            if (rg(4) == 0) begin                       // write one qword
                gaddr = rg(1 << 17) & ~7;
                gaddr = rg(1 << 17);
                ddr3_WE <= 1; ddr3_RD <= 0; ddr3_ADDR <= {3'd0, gaddr[16:0], 3'b000} ; ddr3_BURSTCNT <= 1;
                ddr3_DIN <= {$random(seed_g), $random(seed_g)}; ddr3_BE <= rg(256);
                @(posedge clk2x);
                gx = gsh[gaddr];
                for (gi = 0; gi < 8; gi = gi + 1) if (ddr3_BE[gi]) gx[gi*8 +: 8] = ddr3_DIN[gi*8 +: 8];
                gsh[gaddr] = gx;
                ddr3_WE <= 0;
            end else begin                               // read a burst (mostly long)
                gn = (rg(3) == 0) ? 1 + rg(8) : 100 + rg(29);
                gaddr = rg((1 << 17) - 128);
                for (gi = 0; gi < gn; gi = gi + 1) begin gexp[(gchk_t + gi) % 1024] = gsh[gaddr + gi]; end
                gchk_t = gchk_t + gn;
                ddr3_RD <= 1; ddr3_WE <= 0; ddr3_ADDR <= {3'd0, gaddr[16:0], 3'b000}; ddr3_BURSTCNT <= gn;
                @(posedge clk2x);
                ddr3_RD <= 0;
            end
            gops = gops + 1;
            // keep the queue from emptying: wait only while far ahead
            while ((gchk_t - gchk_h) > 300) @(posedge clk2x);
        end
    end

    // ---------------- SPU driver, clk1x ----------------
    reg [15:0] ssh [0:262143];                          // halfword shadow of the 512 KB
    initial for (ii = 0; ii < 262144; ii = ii + 1) begin gx = initv((1 << 17) + (ii >> 2)); ssh[ii] = gx[16*(ii & 3) +: 16]; end
    integer sn, lat, maxlat = 0, sum_lat = 0, nreads = 0, nwrites = 0, sa;
    reg [15:0] sd;
    initial begin
        wait (init_done);
        repeat (50) @(posedge clk1x);
        for (sn = 0; sn < NSPU; sn = sn + 1) begin
            repeat (rs(3) == 0 ? rs(60) : rs(8)) @(posedge clk1x);
            sa = rs(262144);
            if (rs(5) == 0) sa = sa & 16'hFFFF;          // locality
            if (rs(3) == 0) begin                        // write
                sd = rs(65536);
                rnw <= 0; adr <= {sa[17:0], 1'b0}; dwr <= {16'h0, sd};
                ena <= 1; @(posedge clk1x); ena <= 0;
                ssh[sa] = sd;
                nwrites = nwrites + 1;
            end else begin
                rnw <= 1; adr <= {sa[17:0], 1'b0}; dwr <= 32'hDEAD0000;
                ena <= 1; @(posedge clk1x); ena <= 0;
                nreads = nreads + 1;
            end
            lat = 1;
            while (!done) begin @(posedge clk1x); lat = lat + 1; end
            if (lat > maxlat) maxlat = lat;
            sum_lat = sum_lat + lat;
            if (rnw && drd !== {16'h0, ssh[sa]}) begin
                errs = errs + 1; if (errs < 10) $display("ERR @%0t: SPU read of %h = %h want %h", $time, {sa[17:0], 1'b0}, drd, ssh[sa]);
            end
            if (lat < 2) begin errs = errs + 1; $display("ERR: done within %0d clk of ena", lat); end
        end
        stop_g = 1;
        repeat (3000) @(posedge clk1x);
        $display("SPU: %0d reads, %0d writes; latency ena to done: max %0d, mean %0d.%0d clk1x (budget %0d); GPU: %0d ops; controller hold up to %0d",
                 nreads, nwrites, maxlat, sum_lat / NSPU, (sum_lat * 10 / NSPU) % 10, BUDGET, gops, max_busy_seen);
        if (maxlat > BUDGET) begin errs = errs + 1; $display("ERR: SPU latency %0d > %0d clk1x", maxlat, BUDGET); end
        if (gchk_h != gchk_t) begin errs = errs + 1; $display("ERR: GPU reads outstanding %0d", gchk_t - gchk_h); end
        if (errs == 0) $display("PASS"); else $display("FAIL (%0d)", errs);
        $finish;
    end
    initial begin #200; init_done = 1; end
    initial begin #400_000_000; $display("FAIL: timeout"); $finish; end
endmodule
