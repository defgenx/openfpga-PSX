// PSRAM -> SDRAM block copy, shaped like the PSX DMA to the GPU: 32-bit words are read from
// main RAM in 16-word bursts and written to SDRAM as 64-bit bursts. See docs/pocket/MEMTEST.md.
module dma_eng (
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    input  wire [31:0] n_words,        // multiple of 16
    input  wire [24:0] dst,            // SDRAM word address
    output reg         busy,
    output reg         done,
    output reg  [31:0] cycles,
    output reg         timeout,

    output reg         pcmd_valid,
    input  wire        pcmd_ready,
    output reg  [22:0] pcmd_addr,
    input  wire        prd_valid,
    input  wire [31:0] prd_data,
    input  wire        pdone,

    output reg         req_valid,
    input  wire        req_ready,
    output reg  [24:0] req_addr,
    output reg  [63:0] req_wdata
);
    localparam S_IDLE = 2'd0, S_ISSUE = 2'd1, S_CMD = 2'd2, S_WAIT = 2'd3;

    reg [1:0]  st;
    reg [31:0] words_left;
    reg [22:0] src;
    reg [24:0] paddr;
    reg [31:0] lo;
    reg        half;
    reg [15:0] wd;
    reg [3:0]  drain;

    // write FIFO: 16 entries of {address, data}
    reg [88:0] fifo [0:15];
    reg [4:0]  wp, rp;
    wire [4:0] fcnt = wp - rp;
    wire       pop  = busy && (fcnt != 0) && (!req_valid || req_ready);

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            st <= S_IDLE; busy <= 1'b0; pcmd_valid <= 1'b0; req_valid <= 1'b0; wp <= 5'd0; rp <= 5'd0;
            cycles <= 32'd0; timeout <= 1'b0; half <= 1'b0;
        end else begin
            if (busy) cycles <= cycles + 1'b1;

            // write side
            if (req_valid && req_ready) req_valid <= 1'b0;
            if (pop) begin
                req_valid <= 1'b1; {req_addr, req_wdata} <= fifo[rp[3:0]][88:0]; rp <= rp + 1'b1;
            end
            if (busy && prd_valid) begin
                if (!half) begin lo <= prd_data; half <= 1'b1; end
                else begin
                    fifo[wp[3:0]] <= {paddr, prd_data, lo}; wp <= wp + 1'b1; paddr <= paddr + 25'd4; half <= 1'b0;
                end
            end

            case (st)
                S_IDLE: if (start) begin
                    busy <= 1'b1; cycles <= 32'd0; timeout <= 1'b0; words_left <= n_words; src <= 23'd0;
                    paddr <= dst; half <= 1'b0; wp <= 5'd0; rp <= 5'd0; drain <= 4'd0; req_valid <= 1'b0;
                    st <= S_ISSUE;
                end
                S_ISSUE: begin
                    if (words_left == 0) begin
                        if (fcnt == 0 && !req_valid) begin
                            drain <= drain + 1'b1;
                            if (drain == 4'd10) begin busy <= 1'b0; done <= 1'b1; st <= S_IDLE; end
                        end
                    end else if (fcnt <= 5'd8) begin
                        pcmd_valid <= 1'b1; pcmd_addr <= src; wd <= 16'd0; st <= S_CMD;
                    end
                end
                S_CMD: begin
                    wd <= wd + 1'b1;
                    if (pcmd_valid && pcmd_ready) begin pcmd_valid <= 1'b0; st <= S_WAIT; wd <= 16'd0; end
                    else if (wd == 16'hFFFF) begin pcmd_valid <= 1'b0; timeout <= 1'b1; busy <= 1'b0; done <= 1'b1; st <= S_IDLE; end
                end
                S_WAIT: begin
                    wd <= wd + 1'b1;
                    if (pdone) begin
                        src <= src + 23'd16; words_left <= words_left - 32'd16; st <= S_ISSUE;
                    end else if (wd == 16'hFFFF) begin
                        timeout <= 1'b1; busy <= 1'b0; done <= 1'b1; st <= S_IDLE;
                    end
                end
            endcase
        end
    end
endmodule
