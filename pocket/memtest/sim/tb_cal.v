`timescale 1ns/10fs
// Calibrated read capture (sdram_cal.v) against the SDRAM model, whose read-data window is placed by PAD_NS and moved
// by `drift`, and the PLL stand-in. Tests, in order:
//   sweep    the boot sweep finds the model's window (width, centre, PLL left at the centre)
//   follow   traffic runs, ticks arrive, the window drifts later: the tracker follows it, no read is wrong
//   top      the window drifts to the top of the range: the centre never goes above SWMAX - 1
//   clamp    the window drifts to the bottom of the range: the centre never goes below step 1
//   lost     no window at all: the tracker re-sweeps, falls back to the nominal centre and flags it
//   reset    an APF reset: a full re-sweep, the PLL position kept, the eye found again; then resets mid-step and mid-probe
//   timeout  phase_done stalls: flag bit 2, no further step, the port released; kept by a reset, cleared by a PLL relock
//   inflight no phase step while a read is in flight (CAL_FAULT forces the controller's "quiet" and must be caught)
// Every phase checks that no PLL shift leaves 0 .. SWMAX, the range the clk_cap -> clk transfer is timed for.
// SDRAM_135 selects the 135.4752 MHz variant. See docs/pocket/MEMTEST.md, Calibration contract.
module tb_cal;
    `include "mem_defs.vh"
    `include "cal_sim.vh"
`ifdef SDRAM_135
    parameter real TCK = 1000.0 / 135.4752;
`else
    parameter real TCK = 9.842;
`endif
    localparam real STEP = 0.153846;
    localparam integer SWMAX = `MT_CAL_SWMAX;
    localparam integer TICK_EVERY = 3000;     // system cycles between tracking windows

    reg clk = 0;
    always #(TCK/2) clk = ~clk;
    reg rst = 1;
    reg tick = 0;
    reg locked = 1;

    wire clk_cap, clk_scan, ps_en, ps_up, ps_done;
    pll_dps_model #(.SCAN_DIV(`SIM_SCAN_DIV), .MAX_STEP(SWMAX)) pll (.clk(clk), .clk_scan(clk_scan), .phase_en(ps_en), .updn(ps_up),
        .cntsel(5'd2), .phase_done(ps_done), .clk_cap(clk_cap));

    reg         req_valid = 0, req_we = 0;
    wire        req_ready, rd_valid, rd_tag, init_done;
    reg  [24:0] req_addr = 0;
    reg  [63:0] req_wdata = 0;
    wire [63:0] rd_data;
    wire [12:0] dram_a; wire [1:0] dram_ba; wire [15:0] dram_dq; wire [1:0] dram_dqm;
    wire dram_ras_n, dram_cas_n, dram_we_n;
    wire cal_done, cal_ok;
    wire [6:0] cal_width, cal_boot, cal_centre, cal_min, cal_max;
    wire [15:0] cal_moves;
    wire [3:0] cal_flags;

    sdram_ctl #(.INIT_CYCLES(300)) dut (
        .clk(clk), .clk_cap(clk_cap), .rst(rst), .init_done(init_done),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we), .req_addr(req_addr),
        .req_wdata(req_wdata), .req_be(8'hFF), .req_tag(1'b0),
        .rd_valid(rd_valid), .rd_data(rd_data), .rd_tag(rd_tag),
        .dram_a(dram_a), .dram_ba(dram_ba), .dram_dq(dram_dq), .dram_dqm(dram_dqm),
        .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_we_n(dram_we_n),
        .pll_locked(locked), .cal_tick(tick), .clk_scan(clk_scan), .ps_en(ps_en), .ps_up(ps_up), .ps_done(ps_done),
        .cal_done(cal_done), .cal_ok(cal_ok), .cal_width(cal_width), .cal_boot(cal_boot), .cal_centre(cal_centre),
        .cal_min(cal_min), .cal_max(cal_max), .cal_moves(cal_moves), .cal_flags(cal_flags)
    );
    sdram_model #(.TCK(TCK), .PAD_NS(`SIM_PAD_NS)) sdram (.clk(clk), .a(dram_a), .ba(dram_ba), .dq(dram_dq), .dqm(dram_dqm),
        .ras_n(dram_ras_n), .cas_n(dram_cas_n), .we_n(dram_we_n));

`ifdef CAL_FAULT
    initial force dut.cal.quiet = 1'b1;     // the calibration may step the PLL with reads in flight
`endif

    // ---- the window the model presents, in capture steps
    function integer exp_lo;
        input real dr;
        real t;
        begin
            t = (`SDT_TAC_NS + `SIM_PAD_NS + dr - TCK) / STEP;
            exp_lo = (t <= 0.0) ? 0 : $rtoi(t) + 1;
        end
    endfunction
    function integer exp_hi;
        input real dr;
        real t;
        begin
            t = (`SDT_TOH_NS + `SIM_PAD_NS + dr) / STEP;
            exp_hi = (t >= SWMAX) ? SWMAX : (t < 0.0) ? -1 : $rtoi(t);
        end
    endfunction

    // ---- traffic with a shadow: writes and reads over a hot set of 48 bursts {row, bank 0..2, column}
    reg         traffic = 0;
    reg [63:0]  shd [0:63];
    reg [63:0]  exp_q [0:63];
    reg [63:0]  known = 64'd0;
    integer     qw = 0, qr = 0;
    integer     reads = 0, writes = 0, mism = 0;
    integer     seed = 32'h51ED0001;
    reg [31:0]  x;
    reg [5:0]   bid, nb;
    reg         acc;
    always @(posedge clk) if (!rst) begin
        acc = req_valid && req_ready;
        if (acc) begin
            bid = {req_addr[12], req_addr[11:10], req_addr[4:2]};
            if (req_we) begin shd[bid] = req_wdata; known[bid] = 1'b1; writes = writes + 1; end
            else begin exp_q[qw[5:0]] = shd[bid]; qw = qw + 1; reads = reads + 1; end
            req_valid <= 0;
        end
        if (traffic && init_done && (!req_valid || acc) && (qw - qr) < 8) begin
            x = $random(seed);
            nb = {x[8], (x[10:9] == 2'd3) ? 2'd0 : x[10:9], x[7:5]};
            req_addr <= {12'd0, nb[5], nb[4:3], 5'd0, nb[2:0], 2'b00};
            if (!known[nb] || x[12:11] == 2'b00) begin req_we <= 1; req_wdata <= {$random(seed), $random(seed)}; end
            else req_we <= 0;
            req_valid <= 1;
        end
        if (rd_valid) begin
            if (rd_data !== exp_q[qr[5:0]]) begin
                mism = mism + 1;
                if (mism <= 5) $display("%0t READ MISMATCH: got %h want %h", $time, rd_data, exp_q[qr[5:0]]);
            end
            qr = qr + 1;
        end
    end

    // ---- ticks and the in-flight monitor
    integer tc = 0;
    reg     tick_en = 0;
    always @(posedge clk) begin
        tick <= 1'b0;
        if (tick_en) begin
            tc = tc + 1;
            if (tc >= TICK_EVERY) begin tc = 0; tick <= 1'b1; end
        end
    end
    integer step_viol = 0, steps_seen = 0;
    always @(pll.nsteps) steps_seen = steps_seen + 1;
    always @(posedge dut.cal.ps_req)                          // a phase step requested, or taken, with a read in flight
        if (dut.rdv != 0 || dut.rv_cal || dut.cur_valid) step_viol = step_viol + 1;
    always @(pll.nsteps) if (dut.rdv != 0 || dut.rv_cal) step_viol = step_viol + 1;
    real t_init = 0.0, t_done = 0.0, t_hold = 0.0, hold_max = 0.0, hold_sum = 0.0;
    integer holds = 0;
    always @(posedge dut.init_core) t_init = $realtime;
    always @(posedge cal_done) t_done = $realtime;
    always @(posedge dut.cal.hold) t_hold = $realtime;
    always @(negedge dut.cal.hold) if (cal_done && t_hold > t_done) begin
        holds = holds + 1; hold_sum = hold_sum + ($realtime - t_hold);
        if ($realtime - t_hold > hold_max) hold_max = $realtime - t_hold;
    end
    integer rd_viol = 0;                                      // a requester's read data while the calibration owns the port
    always @(posedge clk) if (rd_valid && dut.cal_own) rd_viol = rd_viol + 1;

    // ---- the tests
    integer fails = 0;
    task check;
        input [1023:0] name;
        input ok;
        begin
            if (!ok) begin fails = fails + 1; $display("  CHECK FAILED: %0s", name); end
            else $display("  ok: %0s", name);
        end
    endtask
    task cyc;
        input integer n;
        begin repeat (n) @(posedge clk); end
    endtask
    task wait_done;
        integer t;
        begin
            t = 0;
            while (!(cal_done && init_done) && t < 400000) begin @(posedge clk); t = t + 1; end
        end
    endtask

    task wait_state;                                          // until the calibration is in state st
        input [3:0] st;
        integer t;
        begin
            t = 0;
            while (dut.cal.state != st && t < 400000) begin @(posedge clk); t = t + 1; end
        end
    endtask
    task pulse_rst;
        begin rst = 1; cyc(3); rst = 0; end
    endtask

    // stop the ticks and wait until the calibration is idle (not in a probe, a sweep or a move); the caller starts them again
    task wait_idle;
        integer t;
        begin
            tick_en = 0; tick = 0; t = 0;
            cyc(2);
            while ((dut.cal.state != 4'd12 || dut.cal.hold || dut.cal.tick_pend) && t < 200000) begin @(posedge clk); t = t + 1; end
            cyc(20);
        end
    endtask

    integer lo, hi, w, ctr, i, m0;
    integer boot_steps, n0;
    real    dr;
    // drift that puts the window's bottom edge at step 18, at step 28, and its top edge at step 2
    real    dr_up  = 18 * STEP - (`SDT_TAC_NS + `SIM_PAD_NS - TCK);
    real    dr_top = 27.5 * STEP - (`SDT_TAC_NS + `SIM_PAD_NS - TCK);
    real    dr_low = 2.5 * STEP - (`SDT_TOH_NS + `SIM_PAD_NS);
    initial begin
        for (i = 0; i < 64; i = i + 1) shd[i] = 64'd0;
        cyc(10); rst = 0;
        wait_done;
        // ---- sweep
        $display("sweep: window model 0.0 ns drift");
        lo = exp_lo(0.0); hi = exp_hi(0.0); w = hi - lo + 1; ctr = (lo + hi) / 2;
        $display("  model window steps %0d .. %0d (%0d wide), centre %0d; calibration: width %0d, boot centre %0d, flags %b, PLL at %0d after %0d pulses",
                 lo, hi, w, ctr, cal_width, cal_boot, cal_flags, pll.steps, pll.nsteps);
        $display("  boot calibration: %0d cycles (%0.1f us) from the end of the SDRAM power-up sequence to init_done", (t_done - t_init) / TCK, (t_done - t_init) / 1000.0);
        check("boot sweep finished", cal_done && init_done);
        check("eye width within 1 step of the model window", cal_width + 1 >= w && cal_width <= w + 1);
        check("boot centre within 1 step of the window centre (clamped to 1 .. SWMAX-1)",
              cal_boot + 1 >= ((ctr < 1) ? 1 : ctr) && cal_boot <= ((ctr < 1) ? 1 : ctr) + 1);
        check("PLL left at the centre", pll.steps == cal_boot && cal_centre == cal_boot);
        check("eye at least MT_CAL_EYE_MIN wide", cal_ok);
        check("no PLL timeout", cal_flags[2] == 0);
        boot_steps = pll.steps;

        // ---- follow: traffic, ticks, a window that drifts later by 2.3 ns (15 steps)
        $display("follow: traffic with the window drifting later by %0.2f ns", dr_up);
        traffic = 1; tick_en = 1;
        m0 = cal_moves;
        for (i = 1; i <= 15; i = i + 1) begin
            sdram.drift = dr_up * i / 15;
            cyc(6 * TICK_EVERY);
        end
        cyc(8 * TICK_EVERY); wait_idle;
        dr = dr_up;
        lo = exp_lo(dr); hi = exp_hi(dr);
        $display("  window now %0d .. %0d; calibration: width %0d, boot %0d, centre %0d, min %0d, max %0d, moves %0d; %0d reads, %0d writes, %0d wrong",
                 lo, hi, cal_width, cal_boot, cal_centre, cal_min, cal_max, cal_moves, reads, writes, mism);
        check("tracker moved the centre up", cal_centre > boot_steps + 2 && cal_moves > m0);
        check("centre inside the window", cal_centre >= lo && cal_centre <= hi);
        check("min is the boot centre, max the current centre", cal_min == cal_boot && cal_max == cal_centre);
        check("no read returned wrong data", mism == 0 && reads > 200);
        check("PLL position matches the centre", pll.steps == cal_centre);

        // ---- top: the window runs to the top of the range (eye 28 .. SWMAX)
        $display("top: window drifts to the top of the range");
        tick_en = 1;
        for (i = 1; i <= 10; i = i + 1) begin
            sdram.drift = dr_up + (dr_top - dr_up) * i / 10;
            cyc(6 * TICK_EVERY);
        end
        cyc(8 * TICK_EVERY); wait_idle;
        dr = dr_top;
        lo = exp_lo(dr); hi = exp_hi(dr);
        $display("  window now %0d .. %0d; calibration: centre %0d, max %0d, flags %b, PLL at %0d; %0d reads, %0d wrong",
                 lo, hi, cal_centre, cal_max, cal_flags, pll.steps, reads, mism);
        check("the window is at the top", lo == 28 && hi == SWMAX);
        check("centre not above SWMAX - 1", cal_centre == SWMAX - 1 && cal_max == SWMAX - 1 && pll.steps == SWMAX - 1);
        check("no PLL shift outside 0 .. SWMAX", pll.range_viol == 0);
        check("no read returned wrong data", mism == 0);

        // ---- clamp: the window runs to the bottom of the range (eye 0 .. 2)
        $display("clamp: window drifts to the bottom of the range");
        traffic = 0; cyc(2000); tick_en = 1;
        for (i = 1; i <= 18; i = i + 1) begin
            sdram.drift = dr_top + (dr_low - dr_top) * i / 18;
            cyc(10 * TICK_EVERY);
        end
        wait_idle;
        dr = sdram.drift;
        lo = exp_lo(dr); hi = exp_hi(dr);
        $display("  window now %0d .. %0d; calibration: width %0d, centre %0d, min %0d, flags %b, PLL at %0d, re-sweeps flagged %0d",
                 lo, hi, cal_width, cal_centre, cal_min, cal_flags, pll.steps, cal_flags[3]);
        check("the window is narrow and at the bottom", lo == 0 && hi <= 4);
        check("centre not below step 1", cal_centre >= 1 && cal_min >= 1 && pll.steps >= 1);
        check("no PLL shift outside 0 .. SWMAX", pll.range_viol == 0);
        check("centre inside the narrow window", cal_centre <= hi + 1);

        // ---- lost: no window at all
        $display("lost: no data window");
        sdram.drift = 30.0; tick_en = 1;
        cyc(8 * TICK_EVERY); wait_idle;
        $display("  calibration: width %0d, centre %0d, flags %b, PLL at %0d", cal_width, cal_centre, cal_flags, pll.steps);
        check("re-swept and flagged: no eye", cal_flags[0] && cal_flags[3] && cal_width == 0 && !cal_ok);
        check("parked at the nominal centre", cal_centre == `MT_CAL_NOM && pll.steps == `MT_CAL_NOM);

        // ---- reset: a window again, then an APF reset
        $display("reset: full re-sweep after a reset");
        sdram.drift = 0.0; tick_en = 0; tick = 0;
        cyc(2000);
        boot_steps = pll.steps;
        rst = 1; cyc(5); rst = 0;
        cyc(20);
        check("calibration restarts: not done, requesters held off", !cal_done && !init_done && !req_ready);
        wait_done;
        lo = exp_lo(0.0); hi = exp_hi(0.0);
        $display("  after the reset: width %0d, boot centre %0d, flags %b, window %0d .. %0d, PLL pulses %0d (position before the reset %0d)",
                 cal_width, cal_boot, cal_flags, lo, hi, pll.nsteps, boot_steps);
        check("eye found again", cal_done && cal_ok && cal_width + 1 >= hi - lo + 1 && cal_width <= hi - lo + 2);
        check("statistics restarted at the new boot centre", cal_min == cal_boot && cal_max == cal_boot && cal_moves == 0);
        check("no PLL shift outside 0 .. SWMAX", pll.range_viol == 0);

        // a reset while a step is in the handshake waits for it; one in the middle of a probe is taken at once
        pulse_rst; wait_state(4'd3);
        $display("  reset during a step (state %0d, PLL at %0d)", dut.cal.state, pll.steps);
        check("reset arrives during a step", dut.cal.state == 4'd3);
        pulse_rst; wait_done;
        check("after a reset mid-step: eye found, PLL position counted", cal_done && cal_ok && pll.steps == dut.cal.pos && pll.steps == cal_centre);
        pulse_rst; wait_state(4'd8);
        while (dut.cal.state == 4'd8 && dut.cal.nreq < 4) @(posedge clk);
        $display("  reset during a probe (state %0d, %0d reads issued)", dut.cal.state, dut.cal.nreq);
        check("reset arrives during a probe", dut.cal.state == 4'd8 && dut.cal.nreq >= 4);
        pulse_rst; wait_done;
        check("after a reset mid-probe: eye found, PLL position counted", cal_done && cal_ok && pll.steps == dut.cal.pos && pll.steps == cal_centre);
        check("no PLL shift outside 0 .. SWMAX", pll.range_viol == 0);

        // ---- timeout: phase_done stops rising during a tracking window
        $display("timeout: phase_done stalls in a tracking window");
        tick_en = 1; pll.stall = 1;
        i = 0;
        while (!cal_flags[2] && i < 400000) begin @(posedge clk); i = i + 1; end
        pll.stall = 0; n0 = pll.nsteps;
        cyc(6 * TICK_EVERY); wait_idle;
        $display("  calibration: done %0d, ok %0d, flags %b, centre %0d; PLL at %0d, pulses %0d (at the timeout %0d)",
                 cal_done, cal_ok, cal_flags, cal_centre, pll.steps, pll.nsteps, n0);
        check("timeout flagged, eye no longer trusted", cal_flags[2] && !cal_ok);
        check("no PLL step after the timeout", pll.nsteps == n0);
        check("requesters released", cal_done && init_done && !dut.cal_own && !dut.cal_hold);
        check("no PLL shift outside 0 .. SWMAX", pll.range_viol == 0);
        pulse_rst; wait_done;
        $display("  after a reset: done %0d, init %0d, ok %0d, flags %b, pulses %0d, state %0d", cal_done, init_done, cal_ok, cal_flags, pll.nsteps, dut.cal.state);
        check("a reset keeps the stop: flagged, no step, done", cal_done && cal_flags[2] && !cal_ok && pll.nsteps == n0);
        // a PLL relock restores the static phase (step 0) and clears the stop
        rst = 1; locked = 0; cyc(5); pll.steps = 0; pll.dly = 0.0; locked = 1; cyc(5); rst = 0;
        wait_done;
        lo = exp_lo(0.0); hi = exp_hi(0.0);
        $display("  after a relock: width %0d, centre %0d, flags %b, PLL at %0d", cal_width, cal_centre, cal_flags, pll.steps);
        check("relock: flag cleared, eye found again", cal_done && cal_ok && !cal_flags[2] && cal_width + 1 >= hi - lo + 1);
        check("relock: PLL at the centre", pll.steps == cal_centre && dut.cal.pos == cal_centre);
        check("no PLL shift outside 0 .. SWMAX", pll.range_viol == 0);

        // ---- in flight
        check("PLL stepped (every pulse counted)", steps_seen > 100 && steps_seen == pll.nsteps);
        check("no phase step with a read in flight", step_viol == 0);
        check("no calibration read reached a requester", rd_viol == 0);
        check("SDRAM model: no violation", sdram.violations == 0);
        $display("tracking windows: %0d, requesters held off %0.0f cycles (%0.2f us) on average, %0.0f cycles (%0.2f us) at most",
                 holds, hold_sum / holds / TCK, hold_sum / holds / 1000.0, hold_max / TCK, hold_max / 1000.0);
        $display("PLL pulses %0d, steps with a read in flight %0d, model violations %0d", pll.nsteps, step_viol, sdram.violations);
`ifdef CAL_FAULT
        if (step_viol > 0) $display("PASS (fault caught)"); else $display("FAIL (injected fault not caught)");
`else
        if (fails == 0) $display("PASS"); else $display("FAIL (%0d)", fails);
`endif
        $finish;
    end

    initial begin
        #2000000000;
        $display("FAIL (timeout)");
        $finish;
    end
endmodule
