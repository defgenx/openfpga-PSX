`timescale 1ns/1ps
// Status screen: status_fmt with example values, then status_screen renders one frame to sim/out/status.ppm.
// Checks the fields that matter on a Pocket: decimal, YES/NO, OK, the BIOS name (OpenBIOS by its word sum), hex.
module tb_status;
    reg clk_s = 0, clk_v = 0;
    always #6.734 clk_s = ~clk_s;              // 74.25 MHz
    always #78.73 clk_v = ~clk_v;              // 6.3504 MHz
    reg reset_n = 0;

    // calibration words: init, cal done, ok, PLL locked, flags 0010; width 29, boot 15, centre 16; min 14, max 17; moves 3; windows 42
    wire [159:0] cal_st = {16'd0, 16'd42, 16'd0, 16'd3, 17'd0, 7'd17, 1'b0, 7'd14, 9'd0, 7'd16, 1'b0, 7'd15, 1'b0, 7'd29,
                           24'd0, 4'b0010, 1'b1, 1'b1, 1'b1, 1'b1};
    reg [31:0] bios_bytes = 32'd524288, bios_sum = 32'hABA9788F;

    wire tx_we; wire [9:0] tx_wa; wire [8:0] tx_wd;
    status_fmt fmt (.clk(clk_s), .cal_st(cal_st), .uptime_s(32'd1234), .bios_bytes(bios_bytes), .bios_sum(bios_sum),
        .trk_bytes(32'd0), .trk_sum(32'd0), .pad_keys(16'h0081), .pad_joy(32'h80807F80),
        .tx_we(tx_we), .tx_wa(tx_wa), .tx_wd(tx_wd));

    wire [23:0] rgb; wire de, hs, vs;
    reg  [23:0] box = 24'h00FF00;
    status_screen #(.FONT_FILE("fpga/core/font8x8.hex")) scr (
        .clk_s(clk_s), .tx_we(tx_we), .tx_wa(tx_wa), .tx_wd(tx_wd),
        .clk_v(clk_v), .reset_n(reset_n), .box_rgb(box), .rgb(rgb), .de(de), .hs(hs), .vs(vs));

    integer fails = 0;
    task check_field;
        input integer r;
        input integer slot;
        input [63:0] want;
        input [1:0]  want_at;
        integer k;
        reg [63:0] got;
        reg [1:0]  at;
        begin
            for (k = 0; k < 8; k = k + 1) got[(7-k)*8 +: 8] = {1'b0, scr.txram[(r*3 + slot) * 8 + k][6:0]};
            at = scr.txram[(r*3 + slot) * 8 + 7][8:7];
            if (got !== want || at !== want_at) begin
                fails = fails + 1;
                $display("FIELD row %0d slot %0d: got '%0s' attr %0d, want '%0s' attr %0d", r, slot, got, at, want, want_at);
            end
        end
    endtask

    reg [23:0] frame [0:320*240-1];
    integer fx = 0, fy = 0, in_frame = 0;
    always @(posedge clk_v) begin
        if (vs) begin in_frame = 1; fx = 0; fy = -1; end
        if (in_frame) begin
            if (hs) begin fy = fy + 1; fx = 0; end
            if (de && fy >= 10 && fy < 250 && fx < 320) begin frame[(fy-10)*320 + fx] = rgb; fx = fx + 1; end
        end
    end

    integer ppm, r, c, n_de;
    reg [7:0] ch;
    initial begin
        #200 reset_n = 1;
        #(200000);                              // several passes of the formatter
        check_field(0, 2, "   1234 ", 0);
        check_field(5, 0, "    YES ", 1);
        check_field(5, 2, "     OK ", 1);
        check_field(6, 0, "    YES ", 1);
        check_field(7, 0, "     29 ", 0);
        check_field(7, 2, "     16 ", 0);
        check_field(8, 2, "      3 ", 0);
        check_field(9, 0, "   0010 ", 0);
        check_field(9, 1, "     42 ", 0);
        check_field(12, 0, " 524288 ", 0);
        check_field(12, 1, "ABA9788F", 0);
        check_field(13, 0, "OPENBIOS", 1);
        check_field(14, 0, "      0 ", 0);
        check_field(17, 0, "   0081 ", 0);
        check_field(18, 0, "80807F80", 0);
        // another BIOS of the right size, then a short one
        bios_sum = 32'h12345678;
        #(200000);
        check_field(13, 0, "     OWN", 1);
        bios_bytes = 32'd1000;
        #(200000);
        check_field(13, 0, "   SIZE?", 2);
        // a frame: de must cover exactly 320 x 240 pixels, the box must be the box colour
        bios_bytes = 32'd524288; bios_sum = 32'hABA9788F;
        #(200000);
        @(posedge vs); @(negedge vs); @(negedge clk_v); n_de = 0;
        while (!vs) begin if (de) n_de = n_de + 1; @(negedge clk_v); end
        if (n_de != 320 * 240) begin fails = fails + 1; $display("DE: %0d active pixels, want %0d", n_de, 320 * 240); end
        @(posedge vs); @(posedge clk_v); while (!vs) @(posedge clk_v);
        if (frame[200 * 320 + 300] !== 24'h00FF00) begin fails = fails + 1; $display("BOX: pixel (300,200) = %h", frame[200 * 320 + 300]); end
        // the text screen as ASCII
        for (r = 0; r < 30; r = r + 1) begin
            $write("|");
            for (c = 0; c < 40; c = c + 1) begin
                ch = (c >= 16 && scr.txram[(r*3 + (c >> 3) - 2) * 8 + (c & 7)][6:0] != 0)
                     ? scr.txram[(r*3 + (c >> 3) - 2) * 8 + (c & 7)][6:0] : scr.lrom[r*40 + c] & 8'h7F;
                $write("%c", ch);
            end
            $write("|\n");
        end
        ppm = $fopen("sim/out/status.ppm", "wb");
        $fwrite(ppm, "P6\n320 240\n255\n");
        for (r = 0; r < 320 * 240; r = r + 1) $fwrite(ppm, "%c%c%c", frame[r][23:16], frame[r][15:8], frame[r][7:0]);
        $fclose(ppm);
        if (fails == 0) $display("PASS"); else $display("FAIL (%0d)", fails);
        $finish;
    end
endmodule
