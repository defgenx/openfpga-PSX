// SDRAM traffic generator and checker: 64-bit bursts over a VRAM-like region.
// Modes and counters are described in docs/pocket/MEMTEST.md.
// base must be aligned to the region size (2^(REG_BITS+2) words).
module sd_traffic #(
    parameter REG_BITS = 17            // log2 of the number of bursts in the region
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    input  wire [2:0]  mode,
    input  wire [31:0] n_ops,
    input  wire [31:0] seed,
    input  wire [24:0] base,
    input  wire        pat_rel,        // data pattern is indexed from the region start, not the absolute address
    output reg         busy,
    output reg         done,
    output reg  [31:0] cycles,
    output reg  [31:0] errors,

    output reg         req_valid,
    input  wire        req_ready,
    output reg         req_we,
    output reg  [24:0] req_addr,
    output reg  [63:0] req_wdata,
    input  wire        rvalid,
    input  wire [63:0] rdata
);
    `include "memtest_fn.vh"

    reg [31:0] issued, returned_target, returned;
    reg [31:0] rnd;
    reg [2:0]  m;
    reg [3:0]  drain;

    // addresses of reads in flight
    reg [24:0] fifo [0:15];
    reg [3:0]  fw, fr;
    wire       fifo_room = (fw - fr) < 4'd12;

    wire [REG_BITS-1:0] idx = (m == `SDM_SEQ_WR || m == `SDM_SEQ_RD) ? issued[REG_BITS-1:0] : rnd[REG_BITS-1:0];
    wire [24:0] nx_addr = base | {{(23-REG_BITS){1'b0}}, idx, 2'b00};
    wire [24:0] nx_pa   = pat_rel ? (nx_addr & ~base) : nx_addr;
    wire        nx_we   = (m == `SDM_SEQ_WR) ? 1'b1 : (m == `SDM_MIXED) ? rnd[20] : 1'b0;

    // checker pipeline
    reg        c_v;
    reg [63:0] c_data;
    reg [24:0] c_addr;
    wire [24:0] c_pa = pat_rel ? (c_addr & ~base) : c_addr;
`ifdef ALTERA_RESERVED_QIS
    wire c_x = 1'b0;
`else
    wire c_x = (^c_data) === 1'bx;   // unknown bits count as errors in simulation
`endif

    always @(posedge clk) begin
        done <= 1'b0;
        c_v  <= 1'b0;
        if (rst) begin
            busy <= 1'b0; req_valid <= 1'b0; cycles <= 32'd0; errors <= 32'd0;
            fw <= 4'd0; fr <= 4'd0; issued <= 32'd0; returned <= 32'd0; returned_target <= 32'd0;
        end else begin
            if (busy) cycles <= cycles + 1'b1;

            if (start && !busy) begin
                busy <= 1'b1; m <= mode; cycles <= 32'd0; errors <= 32'd0;
                issued <= 32'd0; returned <= 32'd0; returned_target <= 32'd0;
                fw <= 4'd0; fr <= 4'd0; rnd <= seed | 32'd1; drain <= 4'd0;
                req_valid <= 1'b0;
            end

            if (busy) begin
                if (req_valid && req_ready) begin
                    if (!req_we) begin
                        fifo[fw] <= req_addr; fw <= fw + 1'b1;
                        returned_target <= returned_target + 1'b1;
                    end
                    req_valid <= 1'b0;
                end
                if ((!req_valid || req_ready) && issued < n_ops && fifo_room) begin
                    req_valid <= 1'b1;
                    req_we    <= nx_we;
                    req_addr  <= nx_addr;
                    req_wdata <= pat64({7'd0, nx_pa}, seed);
                    rnd       <= xs32(rnd);
                    issued    <= issued + 1'b1;
                end

                if (rvalid) begin
                    fr <= fr + 1'b1;
                    returned <= returned + 1'b1;
                    c_v <= 1'b1; c_data <= rdata; c_addr <= fifo[fr];
                end
                if (c_v && (c_x || c_data != pat64({7'd0, c_pa}, seed))) errors <= errors + 1'b1;

                if (issued == n_ops && !req_valid && returned == returned_target && !c_v) begin
                    drain <= drain + 1'b1;
                    if (drain == 4'd10) begin busy <= 1'b0; done <= 1'b1; end
                end
            end
        end
    end
endmodule
