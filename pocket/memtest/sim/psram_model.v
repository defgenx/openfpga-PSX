`timescale 1ns/1ps
// Behavioural model of one PSRAM chip (two dies, address/data multiplexed) with the
// asynchronous protocol and a synchronous burst-read mode entered through the bus
// configuration register. Timing checks are in ns. Storage: 2^19 words per die (2 MiB).
module psram_model #(
    parameter real T_AA   = 70.0,   // address (ADV# low) to data
    parameter real T_OE   = 20.0,   // OE# low to data
    parameter real T_WP   = 45.0,   // WE# low pulse
    parameter real T_DW   = 20.0,   // data setup before WE# high
    parameter real T_AW   = 70.0,   // ADV# low to WE# high
    parameter real T_VP   = 5.0,    // ADV# low pulse
    parameter real T_AVS  = 5.0,    // address setup before ADV# high
    parameter real T_AVH  = 2.0,    // address hold after ADV# high
    parameter real T_KHQV = 7.0,    // clock to data valid (sync)
    parameter real T_KHQX = 2.0,    // clock to data invalid (sync)
    parameter integer STUCK_BIT = -1,  // fault injection: word address bit forced to STUCK_VAL on array accesses, -1 = none
    parameter STUCK_VAL = 1'b0,
    parameter integer BRIDGE_BIT = -1  // fault injection: word address bits BRIDGE_BIT and BRIDGE_BIT+1 shorted (wired-OR), -1 = none
) (
    input  wire [21:16] a,
    inout  wire [15:0]  dq,
    output wire         wait_o,
    input  wire         clk,
    input  wire         adv_n, cre, ce0_n, ce1_n, oe_n, we_n, ub_n, lb_n
);
    reg [15:0] mem0 [0:524287];
    reg [15:0] mem1 [0:524287];
    integer violations = 0;
    integer i;
    initial for (i = 0; i < 524288; i = i + 1) begin mem0[i] = 16'hxxxx; mem1[i] = 16'hxxxx; end

    assign wait_o = 1'b0;

    wire ce_n = ce0_n & ce1_n;
    reg  die = 0;                    // die selected when the address was latched
    reg  wr_pending = 0;
    reg  cre_l = 0;                  // CRE# state when the address was latched

    reg [15:0] dq_o = 16'hxxxx;
    reg        dq_en = 0;
    assign dq = dq_en ? dq_o : 16'hzzzz;

    reg        sync_mode = 0;
    reg [15:0] bcr = 16'h9D1F;
    integer    lc = 3;
    reg [21:0] addr;
    reg        addr_ok = 0;
    real       t_adv_fall = -1e6, t_adv_rise = -1e6, t_oe_fall = -1e6, t_we_fall = -1e6, t_dq_change = -1e6;
    real       t_a_change = -1e6;
    integer    n_edges = 0;
    reg        burst = 0;

    task latch_addr;
        begin
            addr = {a, dq};
            if (STUCK_BIT >= 0 && !cre) addr[STUCK_BIT] = STUCK_VAL;
            if (BRIDGE_BIT >= 0 && !cre) begin
                addr[BRIDGE_BIT] = addr[BRIDGE_BIT] | addr[BRIDGE_BIT + 1];
                addr[BRIDGE_BIT + 1] = addr[BRIDGE_BIT];
            end
        end
    endtask

    task viol;
        input [255:0] msg;
        begin
            violations = violations + 1;
            $display("%0t PSRAM VIOLATION: %0s", $time, msg);
        end
    endtask

    always @(dq) t_dq_change = $realtime;
    always @(a)  t_a_change  = $realtime;

    // ---- address latch (asynchronous)
    always @(negedge adv_n) t_adv_fall = $realtime;
    always @(posedge adv_n) begin
        t_adv_rise = $realtime;
        if (!ce_n && !sync_mode) begin
            if (!ce0_n && !ce1_n) viol("both dies selected");
            if ($realtime - t_adv_fall < T_VP - 0.001) viol("tVP (ADV# pulse too short)");
            if ($realtime - t_dq_change < T_AVS - 0.001 || $realtime - t_a_change < T_AVS - 0.001) viol("tAVS (address setup)");
            if (^dq === 1'bx) viol("address unknown");
            latch_addr; addr_ok = 1; die = ~ce1_n; cre_l = cre;
            if (!cre_l && addr[21:19] != 0) viol("model: address above 2^19 words");
        end
    end
    // address hold: the multiplexed address must stay for T_AVH after ADV# rises
    always @(dq or a) if (!ce_n && !sync_mode && adv_n && ($realtime - t_adv_rise) < T_AVH - 0.001) viol("tAVH (address hold)");


    // ---- asynchronous read
    real t_valid;
    reg  rd_active;
    always @(negedge oe_n) if (!ce_n && we_n && addr_ok && !sync_mode) begin
        t_oe_fall = $realtime;
        t_valid = (t_adv_fall + T_AA > t_oe_fall + T_OE) ? t_adv_fall + T_AA : t_oe_fall + T_OE;
        rd_active = 1;
`ifdef PSDBG
        $display("%0t PSRAM %m read die=%0d addr=%h adv_fall=%f oe_fall=%f t_valid=%f mem=%h", $time, die, addr, t_adv_fall, t_oe_fall, t_valid, die ? mem1[addr[18:0]] : mem0[addr[18:0]]);
`endif
        #3;
        while (rd_active) begin
            if (oe_n || ce_n) rd_active = 0;
            else begin
                dq_en = 1;
                dq_o = ($realtime >= t_valid) ? (die ? mem1[addr[18:0]] : mem0[addr[18:0]]) : 16'hxxxx;
                #1;
            end
        end
        #1 dq_en = 0;
    end

    // ---- asynchronous write and register write (committed when WE# or CE# rises)
    always @(negedge we_n) begin t_we_fall = $realtime; wr_pending = 1; end
    always @(posedge we_n or posedge ce_n) begin
        if (wr_pending && addr_ok && !sync_mode) begin
            wr_pending = 0;
            if ($realtime - t_we_fall < T_WP - 0.001) viol("tWP (WE# pulse too short)");
            if ($realtime - t_adv_fall < T_AW - 0.001) viol("tAW (write too soon after ADV#)");
            if (cre_l) begin
                if (addr[19:18] == 2'b10) begin
                    bcr = addr[15:0];
                    sync_mode = ~bcr[15];
                    lc = bcr[13:11];
                    $display("%0t PSRAM BCR=%h sync=%0d latency=%0d fixed=%0d", $time, bcr, sync_mode, lc, bcr[14]);
                end
            end else begin
                if ($realtime - t_dq_change < T_DW - 0.001) viol("tDW (data setup)");
                if (^dq === 1'bx) viol("write data unknown");
`ifdef PSDBG
                if ($time < 700000000) $display("%0t PSRAM %m write die=%0d addr=%h dq=%h lb=%b ub=%b", $time, die, addr, dq, lb_n, ub_n);
`endif
                if (!lb_n) begin
                    if (die) mem1[addr[18:0]][7:0] = dq[7:0]; else mem0[addr[18:0]][7:0] = dq[7:0];
                end
                if (!ub_n) begin
                    if (die) mem1[addr[18:0]][15:8] = dq[15:8]; else mem0[addr[18:0]][15:8] = dq[15:8];
                end
            end
        end
        if (ce_n) begin addr_ok = 0; burst = 0; wr_pending = 0; end
    end

    // ---- synchronous burst read (fixed latency, 16-word bursts without wrap)
    always @(posedge clk) if (sync_mode && !ce_n) begin
        if (!adv_n && !burst) begin
            latch_addr; burst = 1; n_edges = 0; addr_ok = 1; die = ~ce1_n;
            if (^dq === 1'bx) viol("sync address unknown");
        end else if (burst) begin
            n_edges = n_edges + 1;
            if (n_edges >= lc && !oe_n && (n_edges - lc) < 16) begin
                dq_en <= 1;
                dq_o <= #(T_KHQX) 16'hxxxx;
                dq_o <= #(T_KHQV) (die ? mem1[addr[18:0] + (n_edges - lc)] : mem0[addr[18:0] + (n_edges - lc)]);
            end else begin
                dq_en <= #(T_KHQX) 0;
            end
        end
    end
    always @(posedge ce_n) if (sync_mode) dq_en <= #5 0;
endmodule
