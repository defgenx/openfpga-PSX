`timescale 1ns/1ps
// Report formatter and video renderer: loads a set of results, prints the text screen as ASCII
// and writes one rendered frame as sim/out/screen.ppm.
module tb_screen;
    `include "memtest_defs.vh"
    reg clk_s = 0, clk_v = 0;
    always #4.921 clk_s = ~clk_s;
    always #78.73 clk_v = ~clk_v;
    reg reset_n = 0;

    reg         we = 0;
    reg  [6:0]  wa = 0;
    reg  [32:0] wd = 0;
    wire [6:0]  ra;
    wire [32:0] rq, rq_b;
    res_ram rr (.clk(clk_s), .we(we), .wa(wa), .wd(wd), .ra(ra), .rq(rq), .clk_b(clk_s), .rb(7'd0), .rq_b(rq_b));

    wire        tx_we;
    wire [9:0]  tx_wa;
    wire [8:0]  tx_wd;
    report_fmt fmt (.clk(clk_s), .res_ra(ra), .res_rq(rq), .tx_we(tx_we), .tx_wa(tx_wa), .tx_wd(tx_wd));

    wire [23:0] rgb; wire de, hs, vs;
    video_text #(.FONT_FILE("fpga/core/font8x8.hex")) vt (
        .clk_s(clk_s), .tx_we(tx_we), .tx_wa(tx_wa), .tx_wd(tx_wd),
        .clk_v(clk_v), .reset_n(reset_n), .rgb(rgb), .de(de), .hs(hs), .vs(vs));

    task put;
        input integer idx;
        input integer v;
        begin
            @(posedge clk_s); we <= 1; wa <= idx; wd <= {1'b1, v[31:0]};
            @(posedge clk_s); we <= 0;
        end
    endtask

    integer fails = 0;
    task check_field;
        input integer r;
        input integer slot;
        input [63:0] want;
        integer k;
        reg [63:0] got;
        reg [7:0] ch;
        begin
            for (k = 0; k < 8; k = k + 1) begin
                ch = vt.txram[(r*3 + slot) * 8 + k][6:0];
                got[(7-k)*8 +: 8] = ch;
            end
            if (got !== want) begin
                fails = fails + 1;
                $display("FIELD row %0d slot %0d: got '%0s' want '%0s'", r, slot, got, want);
            end
        end
    endtask

    integer r, c;
    reg [7:0] ch;
    reg [7:0] line [0:39];
    reg [23:0] frame [0:320*240-1];
    integer fx = 0, fy = 0, in_frame = 0, frames = 0;

    always @(posedge clk_v) begin
        if (vs) begin in_frame = 1; fx = 0; fy = -1; end
        if (in_frame) begin
            if (hs) begin fy = fy + 1; fx = 0; end
            if (de && fy >= 10 && fy < 250 && fx < 320) begin frame[(fy-10)*320 + fx] = rgb; fx = fx + 1; end
        end
    end

    integer ppm;
    initial begin
        #200;
        reset_n = 1;
        // status: done, step 23, run 1
        put(`R_STATUS + 0, 2); put(`R_STATUS + 1, 23); put(`R_STATUS + 2, 1);
        put(`R_SD_SW + 0, 1980);  put(`R_SD_SW + 2, 8407);
        put(`R_SD_SR + 0, 1978);  put(`R_SD_SR + 1, 0);   put(`R_SD_SR + 2, 8415);
        put(`R_SD_RR + 0, 1270);  put(`R_SD_RR + 1, 0);   put(`R_SD_RR + 2, 6550);
        put(`R_SD_MX + 0, 1115);  put(`R_SD_MX + 1, 3);   put(`R_SD_MX + 2, 7460);
        put(`R_SC_ALONE + 0, 0);  put(`R_SC_ALONE + 1, 65); put(`R_SC_ALONE + 2, 96);
        put(`R_SC_MIX + 0, 0);    put(`R_SC_MIX + 1, 190);  put(`R_SC_MIX + 2, 142);
        put(`R_SD_MXS + 0, 1007); put(`R_SD_MXS + 1, 0);   put(`R_SD_MXS + 2, 8261);
        put(`R_SC_ERR + 0, 0);    put(`R_SC_ERR + 1, 0);
        put(`R_PS_WR + 0, 1082);  put(`R_PS_WR + 2, 369);
        put(`R_PS_RR + 0, 1180);  put(`R_PS_RR + 1, 0);   put(`R_PS_RR + 2, 338);
        put(`R_PS_RW + 0, 1378);  put(`R_PS_RW + 2, 290);
        put(`R_PS_AW + 1, 0);
        put(`R_PS_SR + 0, 996);   put(`R_PS_SR + 1, 0);   put(`R_PS_SR + 2, 401);
        put(`R_PS_SWEEP + 0, 8);  put(`R_PS_SWEEP + 1, 192); put(`R_PS_SWEEP + 2, 9);
        put(`R_SR_WR + 0, 688);   put(`R_SR_WR + 2, 4097);
        put(`R_SR_RD + 0, 590);   put(`R_SR_RD + 1, 0);   put(`R_SR_RD + 2, 3585);
        put(`R_SR_SWEEP + 0, 3);  put(`R_SR_SWEEP + 1, 2); put(`R_SR_SWEEP + 2, 384);
        put(`R_DMA_A + 0, 394);   put(`R_DMA_A + 1, 0);   put(`R_DMA_A + 2, 2636);
        put(`R_GATE + 0, 1);      put(`R_GATE + 1, 2);    put(`R_GATE + 2, 1);
        put(`R_PS_SYR + 0, 9999999); put(`R_PS_SYR + 1, 12345678);
        #300000;   // several formatter sweeps

        $display("---------------- text screen ----------------");
        for (r = 0; r < 30; r = r + 1) begin
            for (c = 0; c < 40; c = c + 1) begin
                ch = vt.lrom[r*40+c] & 8'h7F;
                if (c >= 16 && vt.txram[((r*3 + (c-16)/8) * 8) + (c % 8)][6:0] != 0)
                    ch = vt.txram[((r*3 + (c-16)/8) * 8) + (c % 8)][6:0];
                line[c] = ch;
            end
            $write("|");
            for (c = 0; c < 40; c = c + 1) $write("%c", line[c]);
            $write("|\n");
        end

        // number formats
        check_field(5, 0, "  197.8 ");  check_field(5, 1, "      0 ");  check_field(5, 2, "   8415 ");
        check_field(7, 1, "      3 ");
        check_field(9, 1, "    6.5 ");
        check_field(15, 0, "  118.0 "); check_field(15, 2, "   33.8 ");
        check_field(16, 0, "  137.8 "); check_field(16, 2, "   29.0 ");
        check_field(21, 1, "      0 ");
        check_field(18, 0, "      8 "); check_field(18, 2, "      9 ");
        check_field(29, 0, "   PASS "); check_field(29, 1, "   FAIL "); check_field(29, 2, "   PASS ");
        check_field(1, 0, "   DONE ");  check_field(1, 1, "     23 ");
        check_field(19, 0, "99999.9 "); check_field(19, 1, "9999999 ");
        check_field(19, 2, "      - ");
        check_field(20, 0, "      - ");

        // wait for the next frame and dump it
        @(posedge vs); @(posedge vs); #1000;
        wait (fy == 249 && fx == 320); #500;
        ppm = $fopen("sim/out/screen.ppm", "w");
        $fwrite(ppm, "P3\n320 240\n255\n");
        for (r = 0; r < 320*240; r = r + 1) $fwrite(ppm, "%0d %0d %0d\n", frame[r][23:16], frame[r][15:8], frame[r][7:0]);
        $fclose(ppm);
        if (fails == 0) $display("PASS"); else $display("FAIL (%0d)", fails);
        $finish;
    end
endmodule
