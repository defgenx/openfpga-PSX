// The GPU's picture onto the APF video bus for first light: one fixed 320 x 240 scaler slot (slot 0), one sample per
// clk_vid (clk2x / 10, the 320-wide dot rate; other widths are resampled). clk_vid and clk2x are one timed clock group, so the
// GPU outputs are sampled with one register. Window, strobes and limits: docs/pocket/POCKET_TOP.md, "First light video".
module video_fl (
    input  wire        clk,            // clk_vid
    input  wire [7:0]  r, g, b,        // clk2x, from the GPU's video out
    input  wire        hblank,
    input  wire        vblank,
    output reg  [23:0] rgb,
    output reg         de,
    output reg         hs,
    output reg         vs
);
    localparam [8:0] WIDTH = 9'd320;
    localparam [7:0] LINES = 8'd240;
    localparam [4:0] HS_AT = 5'd16;    // clk_vid cycles after hblank rises: after the window ends in every mode

    reg [23:0] px;
    reg        hb, hb_d, vb, vb_d;
    always @(posedge clk) begin
        px <= {r, g, b}; hb <= hblank; vb <= vblank;
        hb_d <= hb; vb_d <= vb;
    end
    wire h_end   = hb & ~hb_d;         // blanking starts
    wire h_start = ~hb & hb_d;         // active pixels start
    wire v_start = ~vb & vb_d;         // first active line

    reg [4:0] hs_cnt = 5'd31;
    reg [8:0] x = WIDTH;
    reg [7:0] line = LINES;            // lines of the window left in this frame
    reg       armed = 1'b0;            // vblank ended
    reg       go = 1'b0;               // VS sent: the next HS starts the frame
    reg       in_win = 1'b0;           // this line is inside the 240-line window
    always @(posedge clk) begin
        hs <= 1'b0; vs <= 1'b0;
        if (v_start) armed <= 1'b1;
        if (h_end) hs_cnt <= 5'd0;
        else if (hs_cnt != 5'd31) hs_cnt <= hs_cnt + 1'b1;
        // VS goes 4 cycles before the frame's first HS
        if (armed && hs_cnt == HS_AT - 5'd4) begin vs <= 1'b1; armed <= 1'b0; go <= 1'b1; end
        if (hs_cnt == HS_AT) begin
            hs <= 1'b1;
            if (go) begin go <= 1'b0; line <= LINES - 1'b1; in_win <= 1'b1; end
            else if (line != 8'd0) line <= line - 1'b1;
            else in_win <= 1'b0;
        end
        // a 320-cycle window from the start of the active pixels, black outside the GPU's active area
        if (h_start && in_win) x <= 9'd0;
        else if (x != WIDTH) x <= x + 1'b1;
        de  <= (x != WIDTH);
        rgb <= (x != WIDTH && !hb && !vb) ? px : 24'h000000;   // 0 after the window: the end-of-line word selects slot 0
    end
    initial begin rgb = 24'd0; de = 1'b0; hs = 1'b0; vs = 1'b0; px = 24'd0; hb = 1'b1; hb_d = 1'b1; vb = 1'b1; vb_d = 1'b1; end
endmodule
