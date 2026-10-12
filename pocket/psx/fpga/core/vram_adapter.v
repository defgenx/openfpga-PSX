// GPU VRAM port (ddr3_*, clk2x) onto the SDRAM controller request port (clk_sys); the clock groups are asynchronous.
// Command FIFO clk2x->clk_sys, read-data FIFO clk_sys->clk2x (async_fifo.v). Design notes: docs/pocket/POCKET_TOP.md.
module vram_adapter #(
    parameter CAW = 5,                  // log2 command FIFO depth (>= 3)
    parameter RAW = 8                   // log2 read-data FIFO depth (>= 2); 8 holds two full 128-beat bursts
) (
    input  wire        clk2x,
    input  wire        clk_sys,

    // core side (clk2x)
    input  wire        ddr3_RD,
    input  wire        ddr3_WE,
    input  wire [27:0] ddr3_ADDR,       // byte address of a 64-bit qword; only [24:3] is used
    input  wire [63:0] ddr3_DIN,
    input  wire [7:0]  ddr3_BE,
    input  wire [7:0]  ddr3_BURSTCNT,   // reads 1..128; writes must be 1
    output wire        ddr3_BUSY,
    output wire [63:0] ddr3_DOUT,
    output wire        ddr3_DOUT_READY,

    // SDRAM controller request port (clk_sys)
    input  wire        init_done,
    output wire        req_valid,
    input  wire        req_ready,
    output wire        req_we,
    output wire [24:0] req_addr,
    output wire [63:0] req_wdata,
    output wire [7:0]  req_be,
    input  wire        rd_valid,
    input  wire [63:0] rd_data,

    output reg  [15:0] dbg_reads,       // accepted read / write requests (clk2x), wrapping
    output reg  [15:0] dbg_writes
);
    localparam CW = 1 + 22 + 8 + 64 + 8;    // {we, qword index, burstcnt, din, be}
    localparam [CAW:0] CDEPTH = 1 << CAW;
    localparam [RAW+1:0] RDEPTH = 1 << RAW;

    // ---------------- clk2x: accept and push ----------------
    reg  [1:0] init_s = 2'b00;
    reg        busy_r = 1'b1;
    wire       cfull;
    wire [CAW:0] clevel;
    wire       acc  = (ddr3_RD | ddr3_WE) & ~busy_r;
    wire       acc_w = acc & ddr3_WE;

    // busy_r is registered: it was computed one edge before a possible push, with a level that excludes the push of
    // that edge. Low means level <= DEPTH-3 then, so at most DEPTH-1 after both pushes: the FIFO never overflows.
    always @(posedge clk2x) begin
        init_s <= {init_s[0], init_done};
        busy_r <= ~init_s[1] | cfull | (clevel >= CDEPTH - 2);
        if (acc) begin
            if (acc_w) dbg_writes <= dbg_writes + 16'd1;
            else       dbg_reads  <= dbg_reads + 16'd1;
        end
    end
    initial begin dbg_reads = 16'd0; dbg_writes = 16'd0; end
    assign ddr3_BUSY = busy_r;

    // synthesis translate_off
    always @(posedge clk2x) if (acc) begin
        if (ddr3_WE && ddr3_BURSTCNT != 8'd1) $display("ERROR vram_adapter: write with BURSTCNT=%0d (only 1 supported)", ddr3_BURSTCNT);
        if (!ddr3_WE && (ddr3_BURSTCNT == 8'd0 || ddr3_BURSTCNT > 8'd128)) $display("ERROR vram_adapter: read with BURSTCNT=%0d", ddr3_BURSTCNT);
    end
    // synthesis translate_on

    wire [CW-1:0] cq;
    wire          cempty;
    wire          cpop;
    async_fifo #(.WIDTH(CW), .AW(CAW)) cmd_fifo (
        .wclk(clk2x), .wen(acc), .wdata({ddr3_WE, ddr3_ADDR[24:3], ddr3_BURSTCNT, ddr3_DIN, ddr3_BE}),
        .wfull(cfull), .wlevel(clevel),
        .rclk(clk_sys), .ren(cpop), .rdata(cq), .rempty(cempty)
    );

    // ---------------- clk_sys: sequencer ----------------
    reg         have = 1'b0;            // a command is being issued
    reg         c_we;
    reg  [21:0] c_q;
    reg  [7:0]  c_left;                 // read requests still to issue, including the one on the port
    reg  [63:0] c_wd;
    reg  [7:0]  c_be;
    reg  [RAW+1:0] inflight = 0;        // read requests issued whose data has not reached the FIFO
    wire [RAW:0]   rlevel;
    wire        rfull;

    // A read request is issued only if its beat is guaranteed room: FIFO level (stale, so high) + in flight < depth.
    // The level only falls and inflight only falls when a beat moves into the level, so once true it stays true
    // until we issue: req_valid never drops while pending. Beats are never lost: push happens only against reserved room.
    wire        credit = ({1'b0, rlevel} + inflight) < RDEPTH;
    assign req_valid = have & (c_we | credit);
    wire        sacc = req_valid & req_ready;
    assign cpop = ~have & ~cempty;

    always @(posedge clk_sys) begin
        if (cpop) begin
            {c_we, c_q, c_left, c_wd, c_be} <= cq;
            have <= 1'b1;
        end else if (sacc) begin
            if (c_we || c_left <= 8'd1) have <= 1'b0;
            else begin
                c_left <= c_left - 8'd1;
                c_q    <= c_q + 22'd1;
            end
        end
        inflight <= inflight + {{(RAW+1){1'b0}}, sacc & ~c_we} - {{(RAW+1){1'b0}}, rd_valid};
    end

    assign req_we    = c_we;
    assign req_addr  = {1'b0, c_q, 2'b00};
    assign req_wdata = c_wd;
    assign req_be    = c_be;

    // ---------------- read data back to clk2x ----------------
    wire rempty;
    async_fifo #(.WIDTH(64), .AW(RAW)) rd_fifo (
        .wclk(clk_sys), .wen(rd_valid), .wdata(rd_data), .wfull(rfull), .wlevel(rlevel),
        .rclk(clk2x), .ren(1'b1), .rdata(ddr3_DOUT), .rempty(rempty)
    );
    assign ddr3_DOUT_READY = ~rempty;
endmodule
