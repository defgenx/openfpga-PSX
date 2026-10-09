// SRAM byte-store test engine; the access controller is common/mem/sram_ctl.v.
// Cycle counts and the wait sweep are described in docs/pocket/MEMTEST.md.

`include "memtest_defs.vh"

// Random byte write / read-verify and the wait sweeps.
module sram_test #(
    parameter [3:0] SAFE_W = `MT_CYC(787)    // known-good wait: 78.7 ns, 8 cycles at 101.6 MHz
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [1:0]  mode,           // 0 write, 1 read+verify, 2 sweep read wait, 3 sweep write wait
    input  wire [31:0] n_ops,
    input  wire [31:0] seed,
    input  wire [3:0]  run_wait,
    input  wire [3:0]  w_lo,
    input  wire [3:0]  w_hi,
    output reg         busy,
    output reg         done,
    output reg  [31:0] cycles,
    output reg  [31:0] bcyc,           // cycles spent inside accesses
    output reg  [31:0] errors,
    output reg  [3:0]  min_ok,

    output reg         c_start,
    output reg         c_we,
    output reg  [17:0] c_addr,
    output reg  [7:0]  c_wdata,
    output reg  [3:0]  c_wait,
    input  wire        c_done,
    input  wire [7:0]  c_rdata
);
    `include "memtest_fn.vh"

    localparam S_IDLE = 3'd0, S_NEXT = 3'd1, S_WAIT = 3'd2;

    reg [2:0]  st;
    reg [1:0]  m;
    reg [31:0] total, ops, rnd;
    reg [3:0]  w, last_bad;
    reg [31:0] w_err;
    reg        pre_done;     // sweep: pass 0 of this wait value done
    reg        p_we;         // direction of the running pass
    reg        p_verify;

    wire [17:0] a = rnd[17:0];
    wire [31:0] dp = pat32({14'd0, a}, seed);
    // sweep-write alternates the data polarity per wait value, starting inverted at w_lo, so stale data never matches
    wire [7:0]  d = dp[7:0] ^ ((m == 2'd3) ? {8{~(w[0] ^ w_lo[0])}} : 8'h00);
    wire [3:0]  p_w = (m == 2'd2) ? (p_we ? SAFE_W : w) :
                      (m == 2'd3) ? (p_we ? w : SAFE_W) : run_wait;
`ifdef ALTERA_RESERVED_QIS
    wire x_bad = 1'b0;
`else
    wire x_bad = (^c_rdata) === 1'bx;
`endif

    always @(posedge clk) begin
        done <= 1'b0; c_start <= 1'b0;
        if (rst) begin
            st <= S_IDLE; busy <= 1'b0; cycles <= 32'd0; bcyc <= 32'd0; errors <= 32'd0; min_ok <= 4'd0;
        end else begin
            if (busy) cycles <= cycles + 1'b1;
            if (st == S_WAIT) bcyc <= bcyc + 1'b1;
            case (st)
                S_IDLE: if (start) begin
                    busy <= 1'b1; m <= mode; cycles <= 32'd0; bcyc <= 32'd0; errors <= 32'd0;
                    total <= n_ops; ops <= 32'd0; rnd <= seed | 32'd1;
                    w <= w_lo; w_err <= 32'd0; last_bad <= 4'd0; min_ok <= w_lo; pre_done <= 1'b0;
                    // pass 0: sweep-read prefills, sweep-write writes at w, plain modes run directly
                    p_we <= (mode == 2'd0) || (mode == 2'd2) || (mode == 2'd3);
                    p_verify <= (mode == 2'd1);
                    st <= S_NEXT;
                end

                S_NEXT: begin
                    if (ops >= total) begin
                        if (m[1] == 1'b0) begin
                            busy <= 1'b0; done <= 1'b1; st <= S_IDLE;
                        end else begin
                            // sweep: end of a pass
                            ops <= 32'd0; rnd <= seed | 32'd1;
                            if (m == 2'd2 && !pre_done) begin
                                pre_done <= 1'b1; p_we <= 1'b0; p_verify <= 1'b1;      // read pass at w
                            end else if (m == 2'd3 && p_we) begin
                                p_we <= 1'b0; p_verify <= 1'b1;                      // read-back at the safe wait
                            end else begin
                                // wait value finished
                                if (w_err != 0) last_bad <= w;
                                errors <= errors + w_err; w_err <= 32'd0;
                                if (w == w_hi) begin
                                    min_ok <= (w_err != 0) ? w + 1'b1 : (last_bad == 0 ? w_lo : last_bad + 1'b1);
                                    busy <= 1'b0; done <= 1'b1; st <= S_IDLE;
                                end else begin
                                    w <= w + 1'b1;
                                    if (m == 2'd3) begin p_we <= 1'b1; p_verify <= 1'b0; end
                                end
                            end
                        end
                    end else begin
                        c_start <= 1'b1; c_we <= p_we; c_addr <= a; c_wdata <= d; c_wait <= p_w;
                        st <= S_WAIT;
                    end
                end

                S_WAIT: if (c_done) begin
                    if (p_verify && (x_bad || c_rdata != c_wdata)) begin     // c_wdata holds d of this access
                        if (m[1]) w_err <= w_err + 1'b1; else errors <= errors + 1'b1;
                    end
                    ops <= ops + 1'b1; rnd <= xs32(rnd);
                    st <= S_NEXT;
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
