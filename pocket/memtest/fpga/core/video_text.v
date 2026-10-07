// 320 x 240 text screen (40 x 30 characters of 8 x 8) for the APF scaler, 6.3504 MHz pixel clock.
// Static labels come from screen_text.vh, numbers from the text RAM written by report_fmt.v.
// Timing and screen layout: docs/pocket/MEMTEST.md.
module video_text #(
    parameter FONT_FILE = "core/font8x8.hex"
) (
    input  wire        clk_s,          // text RAM write clock (system clock)
    input  wire        tx_we,
    input  wire [9:0]  tx_wa,
    input  wire [8:0]  tx_wd,

    input  wire        clk_v,          // pixel clock
    input  wire        reset_n,
    output reg  [23:0] rgb,
    output reg         de,
    output reg         hs,
    output reg         vs
);
    `include "screen_text.vh"

    localparam H_TOTAL = 400, H_ACTIVE = 320, H_BP = 10;
    localparam V_TOTAL = 264, V_ACTIVE = 240, V_BP = 10;

    // ---- memories
    reg [8:0] txram [0:1023];
    reg [7:0] lrom  [0:1199];
    reg [7:0] font  [0:1023];
    integer i;
    initial begin
        for (i = 0; i < 1024; i = i + 1) txram[i] = 9'd0;
        for (i = 0; i < 1200; i = i + 1) lrom[i] = SCREEN_TEXT[(1199 - i) * 8 +: 8];
        $readmemh(FONT_FILE, font);
    end
    always @(posedge clk_s) if (tx_we) txram[tx_wa] <= tx_wd;

    // ---- counters
    reg [9:0] x, y;
    always @(posedge clk_v or negedge reset_n) begin
        if (!reset_n) begin x <= 10'd0; y <= 10'd0; end
        else begin
            x <= x + 1'b1;
            if (x == H_TOTAL - 1) begin
                x <= 10'd0;
                y <= (y == V_TOTAL - 1) ? 10'd0 : y + 1'b1;
            end
        end
    end

    // ---- stage 1: addresses
    wire [9:0] vx = x - H_BP;
    wire [9:0] vy = y - V_BP;
    wire       act0 = (x >= H_BP) && (x < H_BP + H_ACTIVE) && (y >= V_BP) && (y < V_BP + V_ACTIVE);
    wire [5:0] col = vx[8:3];
    wire [4:0] row = vy[7:3];
    wire [6:0] row3 = {2'b00, row} + {1'b0, row, 1'b0};
    wire [10:0] lbl_a0 = ({6'd0, row} << 5) + ({6'd0, row} << 3) + {5'd0, col};
    wire [6:0] fidx = row3 + {4'd0, col[5:3]} - 7'd2;

    reg        act1, ge16_1, hs1, vs1;
    reg [10:0] lbl_a;
    reg [9:0]  fld_a;
    reg [2:0]  sx1, sy1;
    always @(posedge clk_v) begin
        act1 <= act0; ge16_1 <= (col >= 6'd16);
        hs1 <= (x == 10'd3); vs1 <= (x == 10'd0) && (y == 10'd0);
        lbl_a <= lbl_a0[10:0];
        fld_a <= {fidx, col[2:0]};
        sx1 <= vx[2:0]; sy1 <= vy[2:0];
    end

    // ---- stage 2: memory reads
    reg        act2, ge16_2, hs2, vs2;
    reg [7:0]  lbl_q;
    reg [8:0]  fld_q;
    reg [2:0]  sx2, sy2;
    always @(posedge clk_v) begin
        act2 <= act1; ge16_2 <= ge16_1; hs2 <= hs1; vs2 <= vs1; sx2 <= sx1; sy2 <= sy1;
        lbl_q <= lrom[lbl_a];
        fld_q <= txram[fld_a];
    end

    // ---- stage 3: character and font row
    wire       use_fld = ge16_2 && (fld_q[6:0] != 7'd0);
    wire [6:0] ch      = use_fld ? fld_q[6:0] : lbl_q[6:0];
    wire [2:0] attr    = use_fld ? {1'b0, fld_q[8:7]} : (lbl_q[7] ? 3'd4 : 3'd0);
    reg        act3, hs3, vs3;
    reg [7:0]  font_q;
    reg [2:0]  sx3, attr3;
    always @(posedge clk_v) begin
        act3 <= act2; hs3 <= hs2; vs3 <= vs2; sx3 <= sx2; attr3 <= attr;
        font_q <= font[{ch, sy2}];
    end

    // ---- stage 4: pixel
    reg [23:0] fg;
    always @(*) begin
        case (attr3)
            3'd1: fg = 24'h60F060;
            3'd2: fg = 24'hFF5858;
            3'd3: fg = 24'hFFE070;
            3'd4: fg = 24'h70D8FF;
            default: fg = 24'hE8E8E8;
        endcase
    end
    always @(posedge clk_v) begin
        de <= act3; hs <= hs3; vs <= vs3;
        rgb <= act3 ? (font_q[sx3] ? fg : 24'h101830) : 24'h000000;
    end
endmodule
