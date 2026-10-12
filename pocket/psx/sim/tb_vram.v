// Testbench for vram_adapter: GPU-like driver on clk2x, behavioural sdram_ctl request port on clk_sys.
// Run from the repo root (three configurations: nominal clocks, drifting clk_sys, drifting + tiny FIFOs):
//   iverilog -g2012 -o pocket/psx/sim/out/vram.vvp pocket/psx/sim/tb_vram.v pocket/psx/fpga/core/vram_adapter.v pocket/psx/fpga/core/async_fifo.v && vvp pocket/psx/sim/out/vram.vvp
//   iverilog -g2012 -DSKEW -o pocket/psx/sim/out/vram_skew.vvp ... same sources ... && vvp pocket/psx/sim/out/vram_skew.vvp
//   iverilog -g2012 -DSKEW -DSMALL -o pocket/psx/sim/out/vram_small.vvp ... same sources ... && vvp pocket/psx/sim/out/vram_small.vvp
// Optional: -DNREQ=<requests> (default 30000), -DSEED=<n>. Prints PASS on its own line, or FAIL ....
`timescale 1ns/1ps
`ifndef NREQ
`define NREQ 30000
`endif
`ifndef SEED
`define SEED 1
`endif
`ifdef SMALL
`define CAW 3
`define RAW 2
`else
`define CAW 5
`define RAW 8
`endif
module tb_vram;
    localparam NREQ  = `NREQ;
    localparam QN    = 1 << 18;            // qwords modelled (2 MB)
    localparam STALL_AT = 3000;            // sdram request count at which the long stall starts
    localparam STALL_LEN = 2600;

    reg clk2x = 0, clk_sys = 0;
    real psys = 7.381;
    always #7.381 clk2x = ~clk2x;
    initial begin #3.1; forever #(psys/2.0) clk_sys = ~clk_sys; end
`ifdef SKEW
    initial begin
        forever begin
            #500 psys = 7.381 * 1.0013 * (1.0 + 0.002 * $sin($realtime / 30000.0));
        end
    end
`endif

    integer errs = 0;
    task err(input [8*40-1:0] what);
        begin
            errs = errs + 1;
            if (errs < 20) $display("ERR @%0t: %0s", $time, what);
        end
    endtask

    integer seed_d = `SEED, seed_m = `SEED + 1000;
    function integer rnd_d(input integer n); begin rnd_d = {$random(seed_d)} % n; end endfunction
    function integer rnd_m(input integer n); begin rnd_m = {$random(seed_m)} % n; end endfunction

    function [63:0] merge(input [63:0] o, input [63:0] n, input [7:0] be);
        integer b;
        begin
            merge = o;
            for (b = 0; b < 8; b = b + 1) if (be[b]) merge[b*8 +: 8] = n[b*8 +: 8];
        end
    endfunction
    function [63:0] initv(input integer i);
        begin initv = {i[31:0] ^ 32'hA5A5A5A5, i[31:0] * 32'h9E3779B1}; end
    endfunction

    // ---------------- DUT ----------------
    reg         ddr3_RD = 0, ddr3_WE = 0;
    reg  [27:0] ddr3_ADDR = 0;
    reg  [63:0] ddr3_DIN = 0;
    reg  [7:0]  ddr3_BE = 0, ddr3_BURSTCNT = 0;
    wire        ddr3_BUSY, ddr3_DOUT_READY;
    wire [63:0] ddr3_DOUT;
    reg         init_done = 0;
    wire        req_valid, req_we;
    reg         req_ready = 0;
    wire [24:0] req_addr;
    wire [63:0] req_wdata;
    wire [7:0]  req_be;
    reg         rd_valid = 0;
    reg  [63:0] rd_data = 0;
    wire [15:0] dbg_reads, dbg_writes;

    vram_adapter #(.CAW(`CAW), .RAW(`RAW)) dut (
        .clk2x(clk2x), .clk_sys(clk_sys),
        .ddr3_RD(ddr3_RD), .ddr3_WE(ddr3_WE), .ddr3_ADDR(ddr3_ADDR), .ddr3_DIN(ddr3_DIN), .ddr3_BE(ddr3_BE),
        .ddr3_BURSTCNT(ddr3_BURSTCNT), .ddr3_BUSY(ddr3_BUSY), .ddr3_DOUT(ddr3_DOUT), .ddr3_DOUT_READY(ddr3_DOUT_READY),
        .init_done(init_done), .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we), .req_addr(req_addr),
        .req_wdata(req_wdata), .req_be(req_be), .rd_valid(rd_valid), .rd_data(rd_data),
        .dbg_reads(dbg_reads), .dbg_writes(dbg_writes)
    );

    // ---------------- SDRAM request port model (clk_sys) ----------------
    reg [63:0] smem [0:QN-1];
    reg [63:0] qdat [0:1023];
    integer    qdue [0:1023];
    integer    qh = 0, qt = 0, cyc = 0, lastdue = 0;
    integer    m_acc = 0, m_wr = 0, m_rd = 0, stall = 0, cool = 0, stalled_long = 0;
    integer    wait_run = 0, wait_max = 0, stall_done = 0, ord_err = 0;
    integer    max_clevel = 0, max_rlevel = 0;
    reg        acc_m;
    integer    ix, due;

    always @(posedge clk_sys) begin
        cyc = cyc + 1;
        if (!init_done && cyc == 300) init_done <= 1'b1;
        if (dut.clevel > max_clevel) max_clevel = dut.clevel;
        if (dut.rlevel > max_rlevel) max_rlevel = dut.rlevel;
        acc_m = req_valid && req_ready;
        if (req_valid && !req_ready) begin
            wait_run = wait_run + 1;
            if (wait_run > wait_max) wait_max = wait_run;
        end else wait_run = 0;
        rd_valid <= 1'b0;
        if (acc_m) begin
            if (!init_done) err("request before init_done");
            if (req_addr[1:0] != 0 || req_addr[24:20] != 0) err("bad req_addr");
            ix = req_addr[19:2];
            m_acc = m_acc + 1;
            if (req_we) begin
                smem[ix] = merge(smem[ix], req_wdata, req_be);
                m_wr = m_wr + 1;
            end else begin
                m_rd = m_rd + 1;
                due = cyc + 8 + rnd_m(24) + ((rnd_m(50) == 0) ? rnd_m(200) : 0);
                if (due < lastdue + ((rnd_m(2) == 0) ? 1 : 4)) due = lastdue + ((rnd_m(2) == 0) ? 1 : 4);
                lastdue = due;
                qdat[qt % 1024] = smem[ix];
                qdue[qt % 1024] = due;
                qt = qt + 1;
            end
            cool = rnd_m(6);
            if (rnd_m(1500) == 0) stall = 20 + rnd_m(300);
            if (m_acc == STALL_AT && !stall_done) begin stall = STALL_LEN; stall_done = 1; end
        end else if (cool > 0) cool = cool - 1;
        if (stall > 0) stall = stall - 1;
        req_ready <= init_done && stall == 0 && cool == 0 && (rnd_m(100) < 60);
        if (qh != qt && cyc >= qdue[qh % 1024]) begin
            rd_valid <= 1'b1;
            rd_data  <= qdat[qh % 1024];
            qh = qh + 1;
        end
        if (qt - qh > 1000) err("model queue overflow");
    end

    // ---------------- GPU-like driver (clk2x) ----------------
    reg [63:0] shadow [0:QN-1];
    reg [63:0] expq [0:127];
    integer ops = 0, acc_r = 0, acc_w = 0, beats = 0, exp_beats = 0, rcnt = 0, rburst = 0, gap = 0, wrun = 0;
    integer hot = 1000, q, lastq = 0, burst, k;
    reg     rd_active = 0, started = 0, done = 0;
    reg [7:0] nbe;
    reg [63:0] wd;
    wire    acc_d = (ddr3_RD | ddr3_WE) & ~ddr3_BUSY;
    wire    can   = (~ddr3_RD & ~ddr3_WE) | ~ddr3_BUSY;
    integer wcheck = 0;

    always @(posedge clk2x) begin
        if (!ddr3_BUSY && !init_done) err("BUSY low before init_done");
        if (ddr3_BUSY && init_done) wcheck = wcheck + 1;
        // accepted request
        if (acc_d) begin
            if (ddr3_WE) acc_w = acc_w + 1; else acc_r = acc_r + 1;
            ddr3_RD <= 1'b0;
            ddr3_WE <= 1'b0;
        end
        // new request: same cycle as the acceptance of the previous one, like the GPU
        if (ops < NREQ && can && !rd_active && gap == 0 && started) begin
            if (ops % 300 == 0) hot = rnd_d(QN - 1024);
            if (gap == 0 && wrun == 0 && rnd_d(100) < 40) begin
                // read
                case (rnd_d(10))
                    0, 1, 2, 3, 4: burst = 1 + rnd_d(8);
                    5, 6, 7:       burst = 9 + rnd_d(24);
                    8:             burst = 33 + rnd_d(96);
                    default:       burst = 128;
                endcase
                q = (rnd_d(100) < 75) ? hot + rnd_d(512) : rnd_d(QN);
                if (q > QN - burst) q = QN - burst;
                for (k = 0; k < burst; k = k + 1) expq[k] = shadow[q + k];
                ddr3_RD <= 1'b1; ddr3_WE <= 1'b0;
                ddr3_ADDR <= {7'd0, q[17:0], 3'b000};
                ddr3_BURSTCNT <= burst[7:0];
                ddr3_DIN <= {$random(seed_d), $random(seed_d)};
                ddr3_BE  <= rnd_d(256);
                rd_active = 1; rcnt = 0; rburst = burst; exp_beats = exp_beats + burst;
            end else begin
                if (wrun == 0) begin wrun = 1 + rnd_d(4); lastq = (rnd_d(100) < 75) ? hot + rnd_d(512) : rnd_d(QN); end
                else case (rnd_d(10)) 0, 1, 2: ; 3, 4, 5, 6: lastq = lastq + 1; default: lastq = hot + rnd_d(512); endcase
                if (lastq >= QN) lastq = 0;
                q = lastq;
                case (rnd_d(6)) 0: nbe = 8'hFF; 1: nbe = 8'h00; default: nbe = rnd_d(256); endcase
                wd = {$random(seed_d), $random(seed_d)};
                ddr3_DIN <= wd;
                ddr3_WE <= 1'b1; ddr3_RD <= 1'b0;
                ddr3_ADDR <= {7'd0, q[17:0], 3'b000};
                ddr3_BURSTCNT <= 8'd1;
                ddr3_BE <= nbe;
                wrun = wrun - 1;
                shadow[q] = merge(shadow[q], wd, nbe);
            end
            ops = ops + 1;
            gap = (rnd_d(10) == 0) ? 1 + rnd_d(5) : 0;
        end else if (gap > 0 && !rd_active) gap = gap - 1;
        // returned beats
        if (ddr3_DOUT_READY) begin
            if (!rd_active) err("unexpected beat");
            else begin
                if (ddr3_DOUT !== expq[rcnt]) begin
                    err("read data mismatch");
                    if (errs < 5) $display("  beat %0d/%0d got %h exp %h", rcnt, rburst, ddr3_DOUT, expq[rcnt]);
                end
                rcnt = rcnt + 1; beats = beats + 1;
                if (rcnt == rburst) rd_active = 0;
            end
        end
        if (ops == NREQ && !rd_active && !ddr3_RD && !ddr3_WE) done <= 1'b1;
    end

    // ---------------- sequence ----------------
    integer i, mism;
    initial begin
        for (i = 0; i < QN; i = i + 1) begin smem[i] = initv(i); shadow[i] = initv(i); end
        repeat (20) @(posedge clk2x);
        started = 1;
        fork
            begin : wd_t
                #(200_000_000);
                $display("FAIL timeout: ops=%0d beats=%0d/%0d m_acc=%0d", ops, beats, exp_beats, m_acc);
                $finish;
            end
            begin
                wait (done);
                // let the writes drain into the model
                i = 0;
                while ((m_wr != acc_w || m_rd != exp_beats || qh != qt) && i < 400000) begin @(posedge clk_sys); i = i + 1; end
                repeat (50) @(posedge clk2x);
                mism = 0;
                for (i = 0; i < QN; i = i + 1) if (smem[i] !== shadow[i]) mism = mism + 1;
                if (mism != 0) err("final memory mismatch");
                if (m_wr != acc_w) err("write count");
                if (m_rd != exp_beats || beats != exp_beats) err("beat count");
                if (dbg_reads !== acc_r[15:0] || dbg_writes !== acc_w[15:0]) err("dbg counters");
                if (wait_max < 2000) err("long stall not exercised");
                if (!stall_done) err("stall not reached");
                $display("requests=%0d (reads=%0d writes=%0d) beats=%0d sdram_req=%0d max_valid_wait=%0d cycles", ops, acc_r, acc_w, beats, m_acc, wait_max);
                $display("max cmd fifo level=%0d max rd fifo level=%0d final mem mismatches=%0d dbg_reads=%0d dbg_writes=%0d", max_clevel, max_rlevel, mism, dbg_reads, dbg_writes);
                if (errs == 0) $display("PASS"); else $display("FAIL errors=%0d", errs);
                $finish;
            end
        join
    end
endmodule
