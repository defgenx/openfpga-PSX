// SPU RAM port of spu_pocket (spuram_*, clk1x, one request outstanding) onto the SDRAM request port (clk_sys, via psx_sdram_arb).
// One 16-bit access = one 4-word burst: a read takes the halfword out of the qword, a write masks the other bytes.
// Crossings: toggles through 2-FF synchronisers; the request and the answer are held until the other side has taken them.
// Contract, address map and latency budget: docs/pocket/POCKET_TOP.md, "SPU RAM".
module spu_adapter #(
    parameter [24:0] BASE = 25'h0800000     // SDRAM word address of SPU RAM byte 0 (16 MB), above every VRAM address
) (
    input  wire        clk1x,
    input  wire        clk_sys,

    // spu_pocket, clk1x
    input  wire        ena,                 // one-clock pulse; adr, rnw, dataWrite valid and held until done
    input  wire        rnw,
    input  wire [18:0] adr,                 // byte address
    input  wire [31:0] dataWrite,           // low 16 bits
    output reg  [31:0] dataRead = 32'd0,
    output reg         done = 1'b0,         // one-clock pulse

    // psx_sdram_arb client B, clk_sys
    output reg         req_valid = 1'b0,
    input  wire        req_ready,
    output wire        req_we,
    output wire [24:0] req_addr,
    output wire [63:0] req_wdata,
    output wire [7:0]  req_be,
    input  wire        rd_valid,
    input  wire [63:0] rd_data
);
    // ---------------- clk1x ----------------
    reg [18:0] a1;
    reg [15:0] w1;
    reg        r1;
    reg        rq_t = 1'b0;                 // clk1x -> clk_sys
    reg        dn_t = 1'b0;                 // clk_sys -> clk1x
    reg [15:0] res;                         // clk_sys -> clk1x, stable while dn_t is in flight
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg dn_s1 = 1'b0, rq_s1 = 1'b0;
    reg dn_s2 = 1'b0, dn_p = 1'b0;
    always @(posedge clk1x) begin
        done <= 1'b0;
        dn_s1 <= dn_t; dn_s2 <= dn_s1; dn_p <= dn_s2;
        if (ena) begin a1 <= adr; w1 <= dataWrite[15:0]; r1 <= rnw; rq_t <= ~rq_t; end
        if (dn_s2 ^ dn_p) begin done <= 1'b1; dataRead <= {16'd0, res}; end
    end

    // ---------------- clk_sys ----------------
    reg rq_s2 = 1'b0, rq_seen = 1'b0;
    reg [1:0] st = 2'd0;
    localparam [1:0] S_IDLE = 2'd0, S_REQ = 2'd1, S_RD = 2'd2;
    reg [1:0]  k;                           // halfword index in the qword
    reg        we_q;
    reg [15:0] wd_q;
    reg [24:0] ad_q;
    assign req_we    = we_q;
    assign req_addr  = ad_q;
    assign req_wdata = {4{wd_q}};
    assign req_be    = we_q ? (8'b00000011 << {k, 1'b0}) : 8'hFF;
    always @(posedge clk_sys) begin
        rq_s1 <= rq_t; rq_s2 <= rq_s1;
        case (st)
            S_IDLE: if (rq_s2 != rq_seen) begin
                rq_seen <= rq_s2;
                we_q <= ~r1; wd_q <= w1; k <= a1[2:1];
                ad_q <= BASE + {6'd0, a1[18:3], 2'b00};
                req_valid <= 1'b1; st <= S_REQ;
            end
            S_REQ: if (req_ready) begin
                req_valid <= 1'b0;
                if (we_q) begin dn_t <= ~dn_t; st <= S_IDLE; end
                else st <= S_RD;
            end
            S_RD: if (rd_valid) begin
                res <= rd_data[{k, 4'b0000} +: 16];
                dn_t <= ~dn_t; st <= S_IDLE;
            end
            default: st <= S_IDLE;
        endcase
    end
endmodule
