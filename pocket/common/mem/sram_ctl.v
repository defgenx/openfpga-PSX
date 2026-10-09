// SRAM (256 KB, 16-bit) as a byte-wide store: access controller. Cycle counts: docs/pocket/MEMTEST.md.

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
