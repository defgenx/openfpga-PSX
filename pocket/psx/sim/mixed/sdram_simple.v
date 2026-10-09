`timescale 1ns/1ps
// Untimed-checks SDRAM model for the mixed-language spike: ACT, READ, WRITE, mode register, 4 banks, BL4/CL from the mode
// register; read data is put on dq at the clk_dq edge that follows the (CL+1)-th clock edge, because nvc ignores
// intra-assignment delays. Plain Verilog-2001 that nvc accepts (no arrays of real).
module sdram_simple (
    input  wire        clk,
    input  wire        clk_dq,           // clk delayed by the data path (access time plus pad delay) less whole cycles
    input  wire [12:0] a,
    input  wire [1:0]  ba,
    inout  wire [15:0] dq,
    input  wire [1:0]  dqm,
    input  wire        ras_n, cas_n, we_n
);
    reg [15:0] mem [0:(1<<19)-1];
    reg [12:0] row0, row1, row2, row3;
    reg [2:0]  cl = 3'd3;
    reg [15:0] sv;                       // scheduled-beat valid, bit i leaves i cycles from now
    reg [15:0] sd0 [0:15];
    reg [15:0] dq_r;
    reg        dq_oe;
    reg        nx_oe;
    reg [15:0] nx_dq;
    reg [1:0]  wr_beat;
    reg        wr_on;
    reg [18:0] wr_addr;
    integer i;
    wire [12:0] row = (ba == 2'd0) ? row0 : (ba == 2'd1) ? row1 : (ba == 2'd2) ? row2 : row3;
    wire [18:0] caddr = {ba, row[8:0], a[7:0]};

    assign dq = dq_oe ? dq_r : 16'hzzzz;

    always @(posedge clk) begin
        // shift the read pipeline
        sv = {1'b0, sv[15:1]};
        for (i = 0; i < 15; i = i + 1) sd0[i] = sd0[i+1];
        if (wr_on) begin
            mem[wr_addr + wr_beat] <= dq;
            wr_beat <= wr_beat + 1'b1;
            if (wr_beat == 2'd3) wr_on <= 1'b0;
        end
        case ({ras_n, cas_n, we_n})
            3'b000: cl <= a[6:4];
            3'b011: case (ba)
                        2'd0: row0 <= a;
                        2'd1: row1 <= a;
                        2'd2: row2 <= a;
                        default: row3 <= a;
                    endcase
            3'b101: begin
                        for (i = 0; i < 4; i = i + 1) begin
                            sv[cl + 1 + i] = 1'b1;
                            sd0[cl + 1 + i] = mem[{caddr[18:2], 2'd0} + i];
                        end
                    end
            3'b100: begin
                        wr_on <= 1'b1; wr_beat <= 2'd1; wr_addr <= {caddr[18:2], 2'd0};
                        mem[{caddr[18:2], 2'd0}] <= dq;
                    end
            default: ;
        endcase
        nx_oe = sv[0];
        nx_dq = sd0[0];
    end

    always @(posedge clk_dq) begin
        dq_oe <= nx_oe;
        dq_r  <= nx_dq;
    end
endmodule
