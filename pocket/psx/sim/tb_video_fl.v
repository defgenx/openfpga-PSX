`timescale 1ns/1ps
// video_fl against the GPU's sync video timing on clk2x (gpu_videoout_sync.vhd): 4,346 clk2x per line, 263 lines, vblank on
// lines 0..22 changing at the line boundary, hblank low only on the active pixels of active lines, hsync every line in the
// blanking after the active pixels. clk_vid = clk2x / 10, edge-aligned as the PLL makes it. 320 mode (a pixel per 10 clk2x)
// then 256 mode (per 12). Checks per frame: one VS at least 3 cycles before the first HS, an HS on every line, 240 DE lines of
// 320 pixels, no DE before the first HS or across an HS (the GPU's first active line is not shown); in 320 mode every pixel sampled once, in order.
//   iverilog -g2012 -o sim/out/video_fl.vvp sim/tb_video_fl.v fpga/core/video_fl.v && vvp sim/out/video_fl.vvp
module tb_video_fl;
    reg clk2x = 0;
    always #7.3815 clk2x = ~clk2x;
    reg [3:0] dv = 0;
    reg clk_vid = 0;
    always @(posedge clk2x) begin dv <= (dv == 4'd9) ? 4'd0 : dv + 1'b1; if (dv == 4'd4 || dv == 4'd9) clk_vid <= ~clk_vid; end

    localparam HTOT = 4346, VTOT = 263, VBL = 23;
    integer div = 10, act = 3200;              // clk2x per pixel, clk2x of active pixels
    integer hc = 0, vc = 0, frame = 0;
    reg hblank = 1, vblank = 1, hsync = 0;
    reg [7:0] r = 0, g = 0, b = 0;
    integer px;
    always @(posedge clk2x) begin
        hc <= (hc == HTOT - 1) ? 0 : hc + 1;
        if (hc == HTOT - 1) begin
            vc <= (vc == VTOT - 1) ? 0 : vc + 1;
            if (vc == VTOT - 1) frame <= frame + 1;
        end
        // active pixels from clk2x 20 of an active line; hsync 250 to 570 clk2x after them; vblank changes at the line start
        hblank <= !(vc >= VBL && hc >= 20 && hc < 20 + act);
        hsync  <= (hc >= 20 + act + 250 && hc < 20 + act + 570);
        if (hc == 0) vblank <= (vc < VBL);
        px = (hc - 20) / div;
        r <= px[7:0]; g <= {7'd0, px[8]}; b <= vc[7:0];
    end

    wire [23:0] rgb; wire de, hs, vs;
    video_fl dut (.clk(clk_vid), .r(r), .g(g), .b(b), .hblank(hblank), .vblank(vblank), .hsync(hsync), .rgb(rgb), .de(de), .hs(hs), .vs(vs));

    integer fails = 0, vs_n = 0, hs_n = 0, de_lines = 0, de_px = 0, line_px = 0, last_px = -1, bad_order = 0, frames_seen = 0;
    integer since_vs = 99;
    reg de_d = 0;
    integer mode320 = 1;
    always @(posedge clk_vid) begin
        de_d <= de;
        if (vs) begin
            if (frames_seen > 0) begin
                if (de_lines != 240) begin fails = fails + 1; $display("FAIL frame %0d: %0d DE lines", frames_seen, de_lines); end
                if (hs_n != VTOT) begin fails = fails + 1; $display("FAIL frame %0d: %0d HS", frames_seen, hs_n); end
            end
            frames_seen = frames_seen + 1; vs_n = vs_n + 1; hs_n = 0; de_lines = 0; since_vs = 0;
        end else if (since_vs < 99) since_vs = since_vs + 1;
        if (hs) begin
            if (hs_n == 0 && since_vs < 3) begin fails = fails + 1; $display("FAIL HS %0d cycles after VS", since_vs); end
            hs_n = hs_n + 1; if (de) begin fails = fails + 1; $display("FAIL HS inside DE"); end
        end
        if (de && frames_seen > 0 && hs_n == 0) begin fails = fails + 1; $display("FAIL DE before the frame's first HS"); end
        if (de) begin
            line_px = line_px + 1;
            if (mode320 && rgb != 24'd0) begin
                if (last_px >= 0 && {rgb[8], rgb[23:16]} != last_px + 1) bad_order = bad_order + 1;
                last_px = {rgb[8], rgb[23:16]};
            end
        end
        if (de_d && !de) begin
            if (line_px != 320) begin fails = fails + 1; $display("FAIL line of %0d pixels", line_px); end
            de_lines = de_lines + 1; line_px = 0; last_px = -1;
        end
    end

    initial begin
        wait (frame == 3);
        $display("320 mode: %0d frames, out-of-order samples %0d", frames_seen, bad_order);
        if (bad_order != 0) fails = fails + 1;
        mode320 = 0; div = 12; act = 3072;
        wait (frame == 6);
        $display("256 mode: %0d frames total", frames_seen);
        if (frames_seen < 5) begin fails = fails + 1; $display("FAIL too few frames"); end
        if (fails == 0) $display("PASS"); else $display("FAIL (%0d)", fails);
        $finish;
    end
endmodule
