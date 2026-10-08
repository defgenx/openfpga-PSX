// Result screen formatter: walks the 90 fields (30 rows x 3), converts the stored results to
// decimal text and writes them to the text RAM that video_text.v displays.
// Row and result mapping, number formats and colours: docs/pocket/MEMTEST.md.
module report_fmt (
    input  wire        clk,

    // result store (read latency 1)
    output reg  [6:0]  res_ra,
    input  wire [32:0] res_rq,

    // text RAM write port: {attr[1:0], char[6:0]}
    output reg         tx_we,
    output reg  [9:0]  tx_wa,
    output reg  [8:0]  tx_wd
);
    `include "memtest_defs.vh"

    localparam K_NONE = 3'd0, K_INT = 3'd1, K_X10 = 3'd2, K_ERR = 3'd3, K_PASS = 3'd4, K_STATE = 3'd5;

    // field f = row * 3 + slot -> {kind, result index}
    function [9:0] field;
        input [6:0] f;
        begin
            case (f)
                7'd6:  field = {K_X10,   `R_SD_BE + 7'd0};
                7'd7:  field = {K_ERR,   `R_SD_BE + 7'd1};
                7'd8:  field = {K_INT,   `R_SD_BE + 7'd2};
                7'd3:  field = {K_STATE, `R_STATUS + 7'd0};
                7'd4:  field = {K_INT,   `R_STATUS + 7'd1};
                7'd5:  field = {K_INT,   `R_STATUS + 7'd2};
                7'd12: field = {K_X10,   `R_SD_SW + 7'd0};
                7'd14: field = {K_INT,   `R_SD_SW + 7'd2};
                7'd15: field = {K_X10,   `R_SD_SR + 7'd0};
                7'd16: field = {K_ERR,   `R_SD_SR + 7'd1};
                7'd17: field = {K_INT,   `R_SD_SR + 7'd2};
                7'd18: field = {K_X10,   `R_SD_RR + 7'd0};
                7'd19: field = {K_ERR,   `R_SD_RR + 7'd1};
                7'd20: field = {K_INT,   `R_SD_RR + 7'd2};
                7'd21: field = {K_X10,   `R_SD_MX + 7'd0};
                7'd22: field = {K_ERR,   `R_SD_MX + 7'd1};
                7'd23: field = {K_INT,   `R_SD_MX + 7'd2};
                7'd27: field = {K_ERR,   `R_SC_ALONE + 7'd0};
                7'd28: field = {K_X10,   `R_SC_ALONE + 7'd1};
                7'd29: field = {K_INT,   `R_SC_ALONE + 7'd2};
                7'd30: field = {K_ERR,   `R_SC_MIX + 7'd0};
                7'd31: field = {K_X10,   `R_SC_MIX + 7'd1};
                7'd32: field = {K_INT,   `R_SC_MIX + 7'd2};
                7'd33: field = {K_X10,   `R_SD_MXS + 7'd0};
                7'd34: field = {K_ERR,   `R_SD_MXS + 7'd1};
                7'd35: field = {K_INT,   `R_SD_MXS + 7'd2};
                7'd36: field = {K_ERR,   `R_SC_ERR + 7'd0};
                7'd37: field = {K_ERR,   `R_SC_ERR + 7'd1};
                7'd42: field = {K_X10,   `R_PS_WR + 7'd0};
                7'd44: field = {K_X10,   `R_PS_WR + 7'd2};
                7'd45: field = {K_X10,   `R_PS_RR + 7'd0};
                7'd46: field = {K_ERR,   `R_PS_RR + 7'd1};
                7'd47: field = {K_X10,   `R_PS_RR + 7'd2};
                7'd48: field = {K_X10,   `R_PS_RW + 7'd0};
                7'd50: field = {K_X10,   `R_PS_RW + 7'd2};
                7'd51: field = {K_X10,   `R_PS_SR + 7'd0};
                7'd52: field = {K_ERR,   `R_PS_SR + 7'd1};
                7'd53: field = {K_X10,   `R_PS_SR + 7'd2};
                7'd54: field = {K_INT,   `R_PS_SWEEP + 7'd0};
                7'd55: field = {K_INT,   `R_PS_SWEEP + 7'd1};
                7'd56: field = {K_INT,   `R_PS_SWEEP + 7'd2};
                7'd57: field = {K_X10,   `R_PS_SYR + 7'd0};
                7'd58: field = {K_ERR,   `R_PS_SYR + 7'd1};
                7'd59: field = {K_X10,   `R_PS_SYR + 7'd2};
                7'd60: field = {K_X10,   `R_PS_SYN + 7'd0};
                7'd61: field = {K_ERR,   `R_PS_SYN + 7'd1};
                7'd62: field = {K_X10,   `R_PS_SYN + 7'd2};
                7'd64: field = {K_ERR,   `R_PS_AW + 7'd1};
                7'd69: field = {K_X10,   `R_SR_WR + 7'd0};
                7'd71: field = {K_INT,   `R_SR_WR + 7'd2};
                7'd72: field = {K_X10,   `R_SR_RD + 7'd0};
                7'd73: field = {K_ERR,   `R_SR_RD + 7'd1};
                7'd74: field = {K_INT,   `R_SR_RD + 7'd2};
                7'd75: field = {K_INT,   `R_SR_SWEEP + 7'd0};
                7'd76: field = {K_INT,   `R_SR_SWEEP + 7'd1};
                7'd77: field = {K_INT,   `R_SR_SWEEP + 7'd2};
                7'd81: field = {K_X10,   `R_DMA_A + 7'd0};
                7'd82: field = {K_ERR,   `R_DMA_A + 7'd1};
                7'd83: field = {K_INT,   `R_DMA_A + 7'd2};
                7'd84: field = {K_X10,   `R_DMA_S + 7'd0};
                7'd85: field = {K_ERR,   `R_DMA_S + 7'd1};
                7'd86: field = {K_INT,   `R_DMA_S + 7'd2};
                7'd87: field = {K_PASS,  `R_GATE + 7'd0};
                7'd88: field = {K_PASS,  `R_GATE + 7'd1};
                7'd89: field = {K_PASS,  `R_GATE + 7'd2};
                default: field = {K_NONE, 7'd0};
            endcase
        end
    endfunction

    function [3:0] add3;
        input [3:0] d;
        add3 = (d >= 4'd5) ? d + 4'd3 : d;
    endfunction

    function [63:0] text8;
        input [2:0] id;
        case (id)
            3'd0: text8 = "   INIT ";
            3'd1: text8 = "    RUN ";
            3'd2: text8 = "   DONE ";
            3'd3: text8 = "   PASS ";
            3'd4: text8 = "   FAIL ";
            3'd5: text8 = "    --- ";
            default: text8 = "      - ";
        endcase
    endfunction

    localparam S_NEXT = 3'd0, S_RD1 = 3'd1, S_RD2 = 3'd2, S_CONV = 3'd3, S_DD = 3'd4, S_PUT = 3'd5;

    reg [2:0]  st;
    reg [6:0]  f;
    reg [2:0]  kind;
    reg        vld;
    reg [31:0] val;
    reg [23:0] bin;
    reg [27:0] bcd;
    reg [4:0]  it;
    reg [2:0]  tid;          // fixed text instead of digits
    reg        use_text;
    reg [1:0]  attr;
    reg [3:0]  ci;

    wire [9:0]  fi = field(f);
    wire [27:0] adj = {add3(bcd[27:24]), add3(bcd[23:20]), add3(bcd[19:16]), add3(bcd[15:12]),
                       add3(bcd[11:8]), add3(bcd[7:4]), add3(bcd[3:0])};
    wire [51:0] sh  = {adj, bin} << 1;

    wire [3:0] d0 = bcd[3:0],   d1 = bcd[7:4],   d2 = bcd[11:8],  d3 = bcd[15:12];
    wire [3:0] d4 = bcd[19:16], d5 = bcd[23:20], d6 = bcd[27:24];

    // highest nonzero digit (digit 0 is always shown; X10 shows digit 1 as well)
    reg [2:0] top;
    always @(*) begin
        top = 3'd0;
        if (d1 != 0) top = 3'd1;
        if (d2 != 0) top = 3'd2;
        if (d3 != 0) top = 3'd3;
        if (d4 != 0) top = 3'd4;
        if (d5 != 0) top = 3'd5;
        if (d6 != 0) top = 3'd6;
    end

    function [7:0] dch;
        input [3:0] d;
        input       show;
        dch = show ? {4'h3, d} : 8'h20;
    endfunction

    // character i (0 = leftmost) of the field
    reg [7:0] c;
    always @(*) begin
        c = 8'h20;
        if (use_text) c = text8(tid) >> ((7 - ci) * 8);
        else if (kind == K_X10) begin
            case (ci)
                4'd6: c = dch(d0, 1'b1);
                4'd5: c = 8'h2E;
                4'd4: c = dch(d1, 1'b1);
                4'd3: c = dch(d2, top >= 3'd2);
                4'd2: c = dch(d3, top >= 3'd3);
                4'd1: c = dch(d4, top >= 3'd4);
                4'd0: c = dch(d5, top >= 3'd5);
                default: c = 8'h20;
            endcase
        end else begin
            case (ci)
                4'd6: c = dch(d0, 1'b1);
                4'd5: c = dch(d1, top >= 3'd1);
                4'd4: c = dch(d2, top >= 3'd2);
                4'd3: c = dch(d3, top >= 3'd3);
                4'd2: c = dch(d4, top >= 3'd4);
                4'd1: c = dch(d5, top >= 3'd5);
                4'd0: c = dch(d6, top >= 3'd6);
                default: c = 8'h20;
            endcase
        end
    end

    always @(posedge clk) begin
        tx_we <= 1'b0;
        case (st)
            S_NEXT: begin
                kind <= fi[9:7];
                if (fi[9:7] == K_NONE) begin
                    f <= (f == 7'd89) ? 7'd0 : f + 1'b1;
                end else begin
                    res_ra <= fi[6:0]; st <= S_RD1;
                end
            end
            S_RD1: st <= S_RD2;
            S_RD2: st <= S_CONV;
            S_CONV: begin
                vld <= res_rq[32]; val <= res_rq[31:0];
                use_text <= 1'b0; attr <= 2'd0; ci <= 4'd0; bcd <= 28'd0; it <= 5'd0;
                if (!res_rq[32]) begin
                    use_text <= 1'b1; tid <= 3'd6; st <= S_PUT;
                end else begin
                    case (kind)
                        K_PASS: begin
                            use_text <= 1'b1; st <= S_PUT;
                            tid <= (res_rq[1:0] == 2'd1) ? 3'd3 : (res_rq[1:0] == 2'd2) ? 3'd4 : 3'd5;
                            attr <= (res_rq[1:0] == 2'd1) ? 2'd1 : (res_rq[1:0] == 2'd2) ? 2'd2 : 2'd0;
                        end
                        K_STATE: begin
                            use_text <= 1'b1; st <= S_PUT;
                            tid <= (res_rq[1:0] == 2'd0) ? 3'd0 : (res_rq[1:0] == 2'd1) ? 3'd1 : 3'd2;
                            attr <= (res_rq[1:0] == 2'd2) ? 2'd1 : 2'd3;
                        end
                        default: begin
                            bin <= (kind == K_X10) ? ((res_rq[31:0] > 32'd999999) ? 24'd999999 : res_rq[23:0])
                                                   : ((res_rq[31:0] > 32'd9999999) ? 24'd9999999 : res_rq[23:0]);
                            if (kind == K_ERR) attr <= (res_rq[31:0] != 0) ? 2'd2 : 2'd1;
                            st <= S_DD;
                        end
                    endcase
                end
            end
            S_DD: begin
                {bcd, bin} <= sh[51:0];
                it <= it + 1'b1;
                if (it == 5'd23) st <= S_PUT;
            end
            S_PUT: begin
                tx_we <= 1'b1; tx_wa <= {f, 3'd0} + ci; tx_wd <= {attr, c[6:0]};
                ci <= ci + 1'b1;
                if (ci == 4'd7) begin
                    st <= S_NEXT; f <= (f == 7'd89) ? 7'd0 : f + 1'b1;
                end
            end
            default: st <= S_NEXT;
        endcase
    end

    initial begin st = S_NEXT; f = 7'd0; end
endmodule
