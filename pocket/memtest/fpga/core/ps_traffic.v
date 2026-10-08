// PSRAM traffic generator and checker for psram32.
// Modes are listed in memtest_defs.vh and described in docs/pocket/MEMTEST.md.
module ps_traffic #(
    parameter REG_BITS = 19            // log2 of the words tested per die (main RAM: 2 MiB per die)
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    input  wire [2:0]  mode,
    input  wire [31:0] n_ops,          // words (K per wait value for the sweep, unused by the walk)
    input  wire [31:0] seed,
    input  wire [4:0]  run_wait,       // read wait used outside the sweep
    input  wire [4:0]  w_lo,
    input  wire [4:0]  w_hi,
    output reg         busy,
    output reg         done,
    output reg  [31:0] cycles,         // wall clock from start to done
    output reg  [31:0] bcyc,           // cycles the controller spent on commands (accept to done)
    output reg  [31:0] errors,
    output reg  [4:0]  min_ok,         // sweep: smallest wait with no error above it (w_hi + 1: none)
    output reg         timeout,

    output reg         cmd_valid,
    input  wire        cmd_ready,
    output reg         cmd_we,
    output reg  [22:0] cmd_addr,
    output reg  [4:0]  cmd_len,
    output reg  [31:0] cmd_wdata,
    output wire [3:0]  cmd_be,
    output wire [4:0]  rd_wait,
    input  wire        rd_valid,
    input  wire [31:0] rd_data,
    input  wire        rd_done
);
    `include "memtest_fn.vh"

    localparam S_IDLE = 3'd0, S_NEXT = 3'd1, S_CMD = 3'd2, S_WAIT = 3'd3, S_WDOG = 3'd4;

    reg [2:0]  st, m;
    reg [31:0] total, ops, rnd;
    reg [4:0]  w;
    reg [4:0]  last_bad;
    reg [31:0] w_err;
    reg [31:0] widx;
    reg [22:0] a0;
    reg [15:0] wd;
    reg        in_cmd;

    assign cmd_be  = 4'hF;
    assign rd_wait = (m == `PSM_SWEEP) ? w : run_wait;

    wire [22:0] exp_addr = a0 + widx[22:0];
    wire [31:0] exp_data = pat32({9'd0, exp_addr}, seed);
`ifdef ALTERA_RESERVED_QIS
    wire x_bad = 1'b0;
`else
    wire x_bad = (^rd_data) === 1'bx;
`endif
    wire bad = x_bad || (rd_data != exp_data);

    // address-line walk: per die, word 0 and 2^0 .. 2^(WALK_BITS-1), written then read back
    localparam WALK_BITS = 19;
    localparam WALK_N    = WALK_BITS + 1;
    wire [6:0]  wk_o    = ops[6:0];
    wire        wk_wr   = wk_o < 7'd2 * WALK_N;
    wire [6:0]  wk_r    = wk_wr ? wk_o : wk_o - 7'd2 * WALK_N;
    wire        wk_die  = wk_r >= WALK_N;
    wire [6:0]  wk_k    = wk_die ? wk_r - WALK_N : wk_r;
    wire [22:0] wk_addr = {wk_die, 22'd0} | ((wk_k == 7'd0) ? 23'd0 : (23'd1 << (wk_k - 7'd1)));

    // next command
    reg        n_we;
    reg [22:0] n_addr;
    reg [4:0]  n_len;
    reg [31:0] n_wdata;
    always @(*) begin
        n_we = (m == `PSM_FILL) || (m == `PSM_WALK && wk_wr);
        n_len = (m == `PSM_SEQ_RD) ? 5'd16 : 5'd1;
        case (m)
            `PSM_FILL:   n_addr = {ops[REG_BITS], {(22-REG_BITS){1'b0}}, ops[REG_BITS-1:0]};
            `PSM_SEQ_RD: n_addr = {1'b0, ops[21:0]};
            `PSM_WALK:   n_addr = wk_addr;
            default:     n_addr = {rnd[REG_BITS], {(22-REG_BITS){1'b0}}, rnd[REG_BITS-1:0]};
        endcase
        n_wdata = pat32({9'd0, n_addr}, seed);
    end

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            st <= S_IDLE; busy <= 1'b0; cmd_valid <= 1'b0; cycles <= 32'd0; bcyc <= 32'd0; in_cmd <= 1'b0; errors <= 32'd0;
            timeout <= 1'b0; min_ok <= 5'd0;
        end else begin
            if (busy) cycles <= cycles + 1'b1;
            if (in_cmd) bcyc <= bcyc + 1'b1;
            case (st)
                S_IDLE: if (start) begin
                    busy <= 1'b1; m <= mode; cycles <= 32'd0; bcyc <= 32'd0; errors <= 32'd0; timeout <= 1'b0;
                    ops <= 32'd0; rnd <= seed | 32'd1; last_bad <= 5'd0; w <= w_lo; w_err <= 32'd0;
                    min_ok <= w_lo;
                    total <= (mode == `PSM_FILL) ? {n_ops[30:0], 1'b0} : (mode == `PSM_WALK) ? 32'd4 * WALK_N : n_ops;
                    st <= S_NEXT;
                end

                S_NEXT: begin
                    if (ops >= total) begin
                        if (m == `PSM_SWEEP) begin
                            // close the current wait value
                            if (w_err != 0) last_bad <= w;
                            errors <= errors + w_err;
                            w_err <= 32'd0;
                            if (w == w_hi) begin
                                busy <= 1'b0; done <= 1'b1; st <= S_IDLE;
                                min_ok <= (w_err != 0) ? w + 1'b1 : (last_bad == 0 ? w_lo : last_bad + 1'b1);
                            end else begin
                                w <= w + 1'b1; ops <= 32'd0;
                            end
                        end else begin
                            busy <= 1'b0; done <= 1'b1; st <= S_IDLE;
                        end
                    end else begin
                        cmd_valid <= 1'b1; cmd_we <= n_we; cmd_addr <= n_addr; cmd_len <= n_len;
                        cmd_wdata <= n_wdata;
                        a0 <= n_addr; widx <= 32'd0; wd <= 16'd0;
                        st <= S_CMD;
                    end
                end

                S_CMD: begin
                    wd <= wd + 1'b1;
                    if (cmd_valid && cmd_ready) begin
                        cmd_valid <= 1'b0; st <= S_WAIT; wd <= 16'd0; in_cmd <= 1'b1;
                    end else if (wd == 16'hFFFF) begin
                        cmd_valid <= 1'b0; timeout <= 1'b1; errors <= errors + 1'b1;
                        busy <= 1'b0; done <= 1'b1; st <= S_IDLE;
                    end
                end

                S_WAIT: begin
                    wd <= wd + 1'b1;
                    if (rd_valid) begin
                        widx <= widx + 1'b1;
                        if (bad) begin
                            if (m == `PSM_SWEEP) w_err <= w_err + 1'b1;
                            else errors <= errors + 1'b1;
                        end
                    end
                    if (rd_done) begin
                        in_cmd <= 1'b0;
                        ops <= ops + (cmd_we ? 32'd1 : {27'd0, cmd_len});
                        // a short read burst (device not answering) counts as errors
                        if (!cmd_we && widx[4:0] != cmd_len) begin
                            errors <= errors + 1'b1;
                        end
                        st <= S_NEXT;
                        rnd <= xs32(rnd);
                    end else if (wd == 16'hFFFF) begin
                        timeout <= 1'b1; errors <= errors + 1'b1;
                        busy <= 1'b0; done <= 1'b1; st <= S_IDLE;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
