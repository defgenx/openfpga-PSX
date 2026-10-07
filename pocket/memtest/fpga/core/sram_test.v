// SRAM (256 KB, 16-bit) as a byte-wide store: access controller and test engine.
// Cycle counts and the wait sweep are described in docs/pocket/MEMTEST.md.

// One byte access. wait_c = cycles the address (read) or the write pulse (write) is held.
module sram_ctl (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire        we,
    input  wire [17:0] addr,          // byte address
    input  wire [7:0]  wdata,
    input  wire [3:0]  wait_c,
    output reg         busy,
    output reg         done,
    output reg  [7:0]  rdata,

    output reg  [16:0] sram_a,
    inout  wire [15:0] sram_dq,
    output reg         sram_oe_n,
    output reg         sram_we_n,
    output reg         sram_ub_n,
    output reg         sram_lb_n
);
    reg [4:0]  s;
    reg        c_we, c_hi;
    reg [3:0]  w;
    reg [15:0] dq_out;
    reg        dq_oe;
    assign sram_dq = dq_oe ? dq_out : 16'hzzzz;

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            busy <= 1'b0; sram_oe_n <= 1'b1; sram_we_n <= 1'b1; sram_ub_n <= 1'b1; sram_lb_n <= 1'b1;
            dq_oe <= 1'b0; s <= 5'd0;
        end else if (!busy) begin
            if (start) begin
                busy <= 1'b1; s <= 5'd0; c_we <= we; c_hi <= addr[0]; w <= wait_c;
                sram_a <= addr[17:1];
                sram_ub_n <= ~addr[0]; sram_lb_n <= addr[0];
                dq_out <= {wdata, wdata}; dq_oe <= we;
                sram_oe_n <= we; sram_we_n <= 1'b1;
            end
        end else begin
            s <= s + 1'b1;
            if (c_we) begin
                // address and data are set up one cycle before WE# falls
                if (s == 5'd0) sram_we_n <= 1'b0;
                if (s == {1'b0, w}) sram_we_n <= 1'b1;
                if (s == {1'b0, w} + 5'd1) begin
                    dq_oe <= 1'b0; sram_ub_n <= 1'b1; sram_lb_n <= 1'b1;
                    busy <= 1'b0; done <= 1'b1;
                end
            end else begin
                if (s == {1'b0, w} - 5'd1) begin
                    rdata <= c_hi ? sram_dq[15:8] : sram_dq[7:0];
                    sram_oe_n <= 1'b1; sram_ub_n <= 1'b1; sram_lb_n <= 1'b1;
                    busy <= 1'b0; done <= 1'b1;
                end
            end
        end
    end
endmodule

// Random byte write / read-verify and the wait sweeps.
module sram_test (
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
    localparam [3:0] SAFE_W = 4'd8;

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
    // sweep-write alternates the data polarity per wait value so stale data never matches
    wire [7:0]  d = dp[7:0] ^ ((m == 2'd3) ? {8{w[0]}} : 8'h00);
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
                    if (p_verify && (x_bad || c_rdata != d)) begin
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
