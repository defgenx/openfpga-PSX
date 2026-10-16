// SPU samples (44.1 kHz, clk1x) to the Pocket's I2S (48 kHz, 12.288 MHz MCLK from clk_74a): linear interpolation between the
// last two input samples at the age of the newer one, then a 16-bit left-justified I2S word per 32-bit channel slot.
// Crossings: one toggle clk1x -> clk_74a (the sample registers are stable for 768 clk1x cycles around it); lrck back into
// clk_74a through 2 flip-flops. Audio path and tests: docs/pocket/POCKET_TOP.md, "Audio".
module psx_audio (
    input  wire        clk1x,
    input  wire        clk_74a,
    input  wire [15:0] snd_l,           // signed, clk1x; the SPU updates them once per sample
    input  wire [15:0] snd_r,
    output wire        audio_mclk,
    output wire        audio_dac,
    output wire        audio_lrck
);
    // ---------------- clk1x: one capture per 768 cycles (44,100 Hz) ----------------
    reg [9:0]  cc = 10'd0;
    reg [15:0] cap_l = 16'd0, cap_r = 16'd0;
    reg        cap_t = 1'b0;
    always @(posedge clk1x) begin
        cc <= (cc == 10'd767) ? 10'd0 : cc + 10'd1;
        if (cc == 10'd0) begin cap_l <= snd_l; cap_r <= snd_r; cap_t <= ~cap_t; end
    end

    // ---------------- clk_74a: last two samples and the age of the newer ----------------
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg t_s1 = 1'b0, lr_s1 = 1'b0;
    reg t_s2 = 1'b0, t_p = 1'b0, lr_s2 = 1'b0, lr_p = 1'b0;
    reg signed [15:0] s0l = 16'sd0, s0r = 16'sd0, s1l = 16'sd0, s1r = 16'sd0;
    reg [11:0] age = 12'd0;
    wire       audgen_lrck_w;
    always @(posedge clk_74a) begin
        t_s1 <= cap_t; t_s2 <= t_s1; t_p <= t_s2;
        lr_s1 <= audgen_lrck_w; lr_s2 <= lr_s1; lr_p <= lr_s2;
        if (t_s2 ^ t_p) begin
            s0l <= s1l; s0r <= s1r; s1l <= cap_l; s1r <= cap_r; age <= 12'd0;
        end else if (age != 12'd4095) age <= age + 12'd1;
    end

    // frac = age / 1683.67 (clk_74a cycles per input sample), 16 bits, saturating: age * 39 = 65536 / 1684
    wire [17:0] agex = {6'd0, age} * 18'd39;
    wire [15:0] frac = (agex > 18'd65535) ? 16'hFFFF : agex[15:0];

    // On the lrck edge falling (start of the left slot): the two pairs and frac are latched, L is computed, R one cycle later.
    // The results are held for the whole frame.
    reg [1:0]  ph = 2'd0;
    reg signed [15:0] ol = 16'sd0, or_ = 16'sd0;
    reg signed [15:0] a_l, b_l, a_r, b_r;
    reg [15:0] fr_l;
    reg        sel_r = 1'b0;
    wire signed [15:0] a_s = sel_r ? a_r : a_l;
    wire signed [15:0] b_s = sel_r ? b_r : b_l;
    wire signed [16:0] d = b_s - a_s;
    wire signed [17:0] fx = {2'b00, fr_l};
    wire signed [34:0] pr = d * fx;
    wire signed [16:0] res = a_s + pr[32:16];
    always @(posedge clk_74a) begin
        case (ph)
            2'd0: if (lr_p & ~lr_s2) begin
                a_l <= s0l; b_l <= s1l; a_r <= s0r; b_r <= s1r; fr_l <= frac; sel_r <= 1'b0; ph <= 2'd1;
            end
            2'd1: ph <= 2'd2;
            2'd2: begin ol <= res[15:0]; sel_r <= 1'b1; ph <= 2'd3; end
            default: begin or_ <= res[15:0]; ph <= 2'd0; end
        endcase
    end

    // ---------------- MCLK 12.288 MHz, SCLK 3.072 MHz, I2S ----------------
    reg [21:0] audgen_accum = 22'd0;
    reg        audgen_mclk = 1'b0;
    localparam [20:0] CYCLE_48KHZ = 21'd122880 * 2;
    always @(posedge clk_74a) begin
        audgen_accum <= audgen_accum + CYCLE_48KHZ;
        if (audgen_accum >= 21'd742500) begin
            audgen_mclk <= ~audgen_mclk;
            audgen_accum <= audgen_accum - 21'd742500 + CYCLE_48KHZ;
        end
    end
    reg [1:0] aud_mclk_divider = 2'd0;
    wire      audgen_sclk = aud_mclk_divider[1] /* synthesis keep*/;
    always @(posedge audgen_mclk) aud_mclk_divider <= aud_mclk_divider + 1'b1;

    // one 32-bit slot per channel, the sample in its top 16 bits; lrck low = left
    reg [4:0]  audgen_lrck_cnt = 5'd0;
    reg        audgen_lrck = 1'b0;
    reg        audgen_dac = 1'b0;
    wire [31:0] word = audgen_lrck ? {or_, 16'd0} : {ol, 16'd0};
    always @(negedge audgen_sclk) begin
        audgen_dac <= word[~audgen_lrck_cnt];
        audgen_lrck_cnt <= audgen_lrck_cnt + 1'b1;
        if (audgen_lrck_cnt == 5'd31) audgen_lrck <= ~audgen_lrck;
    end
    assign audgen_lrck_w = audgen_lrck;
    assign audio_mclk = audgen_mclk;
    assign audio_dac  = audgen_dac;
    assign audio_lrck = audgen_lrck;
endmodule
