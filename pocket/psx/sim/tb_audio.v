// psx_audio: a 44.1 kHz sine from clk1x (changed once per sample, as the SPU does) through the resampler to the I2S bits.
// The bench deserialises the I2S (left slot first, lrck low = left, data one SCLK after the lrck edge, 16 bits MSB first) and checks
// the 48 kHz frame rate, the sine's frequency and amplitude on both channels (different frequencies), and that no input sample is
// dropped or repeated (the step between output samples stays within the sine's own slope).
//   cd pocket/psx && iverilog -g2012 -o sim/out/audio.vvp sim/tb_audio.v fpga/core/psx_audio.v && vvp sim/out/audio.vvp   (PASS on its own line)
`timescale 1ns/1ps
module tb_audio;
    reg clk1x = 0, clk_74a = 0;
    always #14.7625 clk1x = ~clk1x;          // 33.8688 MHz
    always #6.7340067 clk_74a = ~clk_74a;    // 74.25 MHz
    localparam real PI = 3.14159265358979;
    localparam real FL = 997.0, FR = 3001.0, AMP = 20000.0;

    // SPU model: a new sample every 768 clk1x cycles
    reg [15:0] snd_l = 0, snd_r = 0;
    integer n = 0, cyc = 0;
    always @(posedge clk1x) begin
        cyc = cyc + 1;
        if (cyc == 768) begin cyc = 0;           // phase of the SPU's update inside the 768-cycle frame
            snd_l <= $rtoi(AMP * $sin(2.0 * PI * FL * n / 44100.0));
            snd_r <= $rtoi(AMP * $sin(2.0 * PI * FR * n / 44100.0));
            n = n + 1;
        end
    end
    wire mclk, dac, lrck;
    psx_audio dut (.clk1x(clk1x), .clk_74a(clk_74a), .snd_l(snd_l), .snd_r(snd_r), .audio_mclk(mclk), .audio_dac(dac), .audio_lrck(lrck));

    // I2S receiver on SCLK = mclk/4 (the DUT's divider): sample dac on the rising edge of SCLK
    reg [1:0] dv = 0;
    always @(posedge mclk) dv <= dv + 1;
    wire sclk = dv[1];
    reg lrck_d = 0;
    integer bitn = 0;
    reg [31:0] sh = 0;
    integer lcount = 0, rcount = 0;
    integer lh [0:3999], rh [0:3999];
    integer nl = 0, nr = 0;
    reg ch;
    always @(posedge sclk) begin
        if (lrck !== lrck_d) begin bitn = 0; ch = lrck; end        // the first bit follows next SCLK
        lrck_d = lrck;
        if (bitn >= 1 && bitn <= 16) sh = {sh[30:0], dac};
        if (bitn == 16) begin
            if (!ch) begin if (nl < 4000) lh[nl] = $signed(sh[15:0]); nl = nl + 1; end
            else begin if (nr < 4000) rh[nr] = $signed(sh[15:0]); nr = nr + 1; end
        end
        bitn = bitn + 1;
    end

    integer errs = 0, i, zc_l, zc_r, first_l, last_l, first_r, last_r, maxl, maxr, dmax_l, dmax_r, d;
    real fl_meas, fr_meas;
    initial begin
        #70_000_000;                                    // 70 ms
        // skip the first 200 frames (start-up), then measure
        zc_l = 0; zc_r = 0; maxl = 0; maxr = 0; dmax_l = 0; dmax_r = 0; first_l = -1; first_r = -1;
        for (i = 201; i < nl && i < 3999; i = i + 1) begin
            if (lh[i-1] < 0 && lh[i] >= 0) begin zc_l = zc_l + 1; if (first_l < 0) first_l = i; last_l = i; end
            if (lh[i] > maxl) maxl = lh[i];
            if (-lh[i] > maxl) maxl = -lh[i];
            d = lh[i] - lh[i-1]; if (d < 0) d = -d; if (d > dmax_l) dmax_l = d;
        end
        for (i = 201; i < nr && i < 3999; i = i + 1) begin
            if (rh[i-1] < 0 && rh[i] >= 0) begin zc_r = zc_r + 1; if (first_r < 0) first_r = i; last_r = i; end
            if (rh[i] > maxr) maxr = rh[i];
            if (-rh[i] > maxr) maxr = -rh[i];
            d = rh[i] - rh[i-1]; if (d < 0) d = -d; if (d > dmax_r) dmax_r = d;
        end
        fl_meas = 48000.0 * (zc_l - 1) / (last_l - first_l);
        fr_meas = 48000.0 * (zc_r - 1) / (last_r - first_r);
        $display("frames: %0d left, %0d right in 70 ms (48 kHz: %0d)", nl, nr, 70 * 48);
        $display("left: %0.1f Hz (want %0.0f), peak %0d (want %0.0f), max step %0d (sine slope %0.0f)", fl_meas, FL, maxl, AMP, dmax_l, AMP * 2 * PI * FL / 48000.0);
        $display("right: %0.1f Hz (want %0.0f), peak %0d (want %0.0f), max step %0d (sine slope %0.0f)", fr_meas, FR, maxr, AMP, dmax_r, AMP * 2 * PI * FR / 48000.0);
        if (nl < 3300 || nl > 3400 || nr < 3300 || nr > 3400) begin errs = errs + 1; $display("ERR: frame count"); end
        if (fl_meas < FL * 0.995 || fl_meas > FL * 1.005) begin errs = errs + 1; $display("ERR: left frequency"); end
        if (fr_meas < FR * 0.995 || fr_meas > FR * 1.005) begin errs = errs + 1; $display("ERR: right frequency"); end
        if (maxl < AMP * 0.98 || maxl > AMP * 1.01 || maxr < AMP * 0.97 || maxr > AMP * 1.01) begin errs = errs + 1; $display("ERR: amplitude"); end
        if (dmax_l > AMP * 2 * PI * FL / 48000.0 * 1.15 || dmax_r > AMP * 2 * PI * FR / 48000.0 * 1.15) begin errs = errs + 1; $display("ERR: output step too large (dropped or repeated input sample)"); end
        if (errs == 0) $display("PASS"); else $display("FAIL (%0d)", errs);
        $finish;
    end
endmodule
