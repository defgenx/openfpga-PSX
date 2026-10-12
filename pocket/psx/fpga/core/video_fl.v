// The GPU's picture onto the APF video bus for first light: one fixed 320 x 240 scaler slot (slot 0), one sample per
// clk_vid (clk2x / 10, the 320-wide dot rate; other widths are resampled). clk_vid and clk2x are one timed clock group, so the
// GPU outputs are sampled with one register. Window, strobes and limits: docs/pocket/POCKET_TOP.md, "First light".
module video_fl (
    input  wire        clk,            // clk_vid
    input  wire [7:0]  r, g, b,        // clk2x, from the GPU's video out
    input  wire        hblank,         // low on the active pixels of an active line; stays high on vblank lines
    input  wire        vblank,         // changes at the GPU's line boundary
    input  wire        hsync,          // once per line, blank lines included, in the blanking after the active pixels
    output reg  [23:0] rgb,
    output reg         de,
    output reg         hs,
    output reg         vs
);
    localparam [8:0] WIDTH = 9'd320;
    localparam [7:0] LINES = 8'd240;

    reg [23:0] px;
    reg        hb, hb_d, vb, vb_d, hy, hy_d;
    always @(posedge clk) begin
        px <= {r, g, b}; hb <= hblank; vb <= vblank; hy <= hsync;
        hb_d <= hb; vb_d <= vb; hy_d <= hy;
    end
    wire h_start = ~hb & hb_d;         // active pixels start
    wire v_start = ~vb & vb_d;         // first active line: the line boundary after its hsync
    wire h_line  = hy & ~hy_d;         // a line ends

    reg       armed = 1'b0;            // VS sent: the next hsync starts the frame
    reg [8:0] since = 9'd0;            // cycles since HS
    reg [8:0] de_at = 9'd100;          // HS to active pixels on the last active line
    reg [8:0] x = WIDTH;
    reg [7:0] line = 8'd0;             // window lines left after this one
    reg       in_win = 1'b0;           // this line is inside the 240-line window
    reg       done_l = 1'b1;           // this line's DE window has started
    always @(posedge clk) begin
        hs <= 1'b0; vs <= 1'b0;
        if (since != 9'h1FF) since <= since + 1'b1;
        // The GPU starts a line's pixels just after the line boundary where vblank ends, too soon for a VS and an HS before
        // them: the frame starts on the next hsync, so the GPU's first active line is not shown
        if (v_start) begin vs <= 1'b1; armed <= 1'b1; end
        if (h_line) begin
            hs <= 1'b1; since <= 9'd0; done_l <= 1'b0;
            if (armed) begin armed <= 1'b0; in_win <= 1'b1; line <= LINES - 1'b1; end
            else if (line != 8'd0) line <= line - 1'b1;
            else in_win <= 1'b0;
        end
        // a 320-cycle window from the active pixels, or from where they were on the last active line (blank lines)
        if (h_start && !done_l) de_at <= since;
        if (in_win && !done_l && (h_start || since == de_at + 9'd2)) begin x <= 9'd0; done_l <= 1'b1; end
        else if (x != WIDTH) x <= x + 1'b1;
        de  <= (x != WIDTH);
        rgb <= (x != WIDTH && !hb && !vb) ? px : 24'h000000;   // 0 after the window: the end-of-line word selects slot 0
    end
    initial begin
        rgb = 24'd0; de = 1'b0; hs = 1'b0; vs = 1'b0; px = 24'd0;
        hb = 1'b1; hb_d = 1'b1; vb = 1'b1; vb_d = 1'b1; hy = 1'b0; hy_d = 1'b0;
    end
endmodule
