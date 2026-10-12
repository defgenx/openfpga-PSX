// Status screen formatter: walks the 90 fields (30 rows x 3) without end and writes each value as 8 characters to the
// text RAM that status_screen.v displays. Rows and labels: tools/gen_screen.py; screen: docs/pocket/POCKET_TOP.md.
module status_fmt (
    input  wire         clk,
    input  wire [159:0] cal_st,        // the calibration status words of the bridge window 0x80000100
    input  wire [31:0]  uptime_s,
    input  wire [31:0]  bios_bytes,
    input  wire [31:0]  bios_sum,      // sum of the 32-bit words written to the BIOS window
    input  wire [15:0]  pad_keys,
    input  wire [31:0]  pad_joy,
    input  wire         core_run,      // the PSX core is out of reset
    input  wire [15:0]  ram_req,       // main RAM requests, icache fills, DMA words written
    input  wire [15:0]  ram_fill,
    input  wire [15:0]  ram_dmaw,
    input  wire [15:0]  vram_rd,       // GPU VRAM reads and writes accepted, frames sent to the APF
    input  wire [15:0]  vram_wr,
    input  wire [15:0]  frames,

    // text RAM write port: {attr[1:0], char[6:0]}; attr 0 white, 1 green, 2 red, 3 yellow
    output reg          tx_we,
    output reg  [9:0]   tx_wa,
    output reg  [8:0]   tx_wd
);
    localparam [3:0] K_NONE = 4'd0, K_DEC = 4'd1, K_HEX = 4'd2, K_HEX4 = 4'd3, K_BIN4 = 4'd4, K_YN = 4'd5,
                     K_OK = 4'd6, K_BIOS = 4'd7, K_RUN = 4'd8;
    localparam [31:0] BIOS_SIZE = 32'd524288;
    // word sums of pocket/psx/dist/Assets/psx/defgenx.PSX/psxbios.bin (OpenBIOS), words read big- and little-endian
    localparam [31:0] OPENBIOS_SUM_BE = 32'hABA9788F, OPENBIOS_SUM_LE = 32'h93B04320;

    // field f = row * 3 + slot -> {kind, value}
    reg [3:0]  k_f;
    reg [31:0] v_f;
    reg [6:0]  f = 7'd0;
    always @(*) begin
        k_f = K_NONE; v_f = 32'd0;
        case (f)
            7'd2:  begin k_f = K_DEC;  v_f = uptime_s; end
            7'd15: begin k_f = K_YN;   v_f = {31'd0, cal_st[0]}; end
            7'd16: begin k_f = K_YN;   v_f = {31'd0, cal_st[1]}; end
            7'd17: begin k_f = K_OK;   v_f = {30'd0, cal_st[1], cal_st[2]}; end
            7'd18: begin k_f = K_YN;   v_f = {31'd0, cal_st[3]}; end
            7'd21: begin k_f = K_DEC;  v_f = {25'd0, cal_st[38:32]}; end
            7'd22: begin k_f = K_DEC;  v_f = {25'd0, cal_st[46:40]}; end
            7'd23: begin k_f = K_DEC;  v_f = {25'd0, cal_st[54:48]}; end
            7'd24: begin k_f = K_DEC;  v_f = {25'd0, cal_st[70:64]}; end
            7'd25: begin k_f = K_DEC;  v_f = {25'd0, cal_st[78:72]}; end
            7'd26: begin k_f = K_DEC;  v_f = {16'd0, cal_st[111:96]}; end
            7'd27: begin k_f = K_BIN4; v_f = {28'd0, cal_st[7:4]}; end
            7'd28: begin k_f = K_DEC;  v_f = {16'd0, cal_st[143:128]}; end
            7'd36: begin k_f = K_DEC;  v_f = bios_bytes; end
            7'd37: begin k_f = K_HEX;  v_f = bios_sum; end
            7'd39: begin k_f = K_BIOS; v_f = bios_sum; end
            7'd42: begin k_f = K_RUN;  v_f = {31'd0, core_run}; end
            7'd60: begin k_f = K_DEC;  v_f = {16'd0, ram_req}; end
            7'd61: begin k_f = K_DEC;  v_f = {16'd0, ram_fill}; end
            7'd62: begin k_f = K_DEC;  v_f = {16'd0, ram_dmaw}; end
            7'd63: begin k_f = K_DEC;  v_f = {16'd0, vram_rd}; end
            7'd64: begin k_f = K_DEC;  v_f = {16'd0, vram_wr}; end
            7'd65: begin k_f = K_DEC;  v_f = {16'd0, frames}; end
            7'd51: begin k_f = K_HEX4; v_f = {16'd0, pad_keys}; end
            7'd54: begin k_f = K_HEX;  v_f = pad_joy; end
            default: ;
        endcase
    end

    // ---- decimal: double dabble, 32 shifts into 10 BCD digits (the last 8 are shown)
    reg [3:0]  kind;
    reg [31:0] val;
    reg [31:0] sh;
    reg [39:0] bcd;
    reg [5:0]  it;
    reg [2:0]  cp;
    reg        lead;                   // only leading zeros so far
    reg [1:0]  st = 2'd0;
    localparam [1:0] S_PICK = 2'd0, S_DAB = 2'd1, S_EMIT = 2'd2;

    reg [39:0] adj;
    integer n;
    always @(*) begin
        for (n = 0; n < 10; n = n + 1)
            adj[4*n +: 4] = (bcd[4*n +: 4] >= 4'd5) ? bcd[4*n +: 4] + 4'd3 : bcd[4*n +: 4];
    end

    // ---- one character of the field: position cp, 0 = leftmost
    function [6:0] hexc;
        input [3:0] h;
        hexc = (h < 4'd10) ? 7'h30 + {3'd0, h} : 7'h37 + {3'd0, h};
    endfunction
    function [6:0] strc;               // character cp of an 8-character string
        input [63:0] s;
        input [2:0]  p;
        strc = s[8 * (7 - p) +: 7];
    endfunction

    reg [6:0] ch;
    reg [1:0] at;
    reg [3:0] dig;
    reg [2:0] p7;                      // position in a 7-character value; the 8th character is a space
    reg       bios_open, bios_size;
    always @(*) begin
        ch = 7'h20; at = 2'd0;
        p7  = cp + 3'd1;
        dig = bcd[4 * (7 - p7) +: 4];
        bios_size = (bios_bytes == BIOS_SIZE);
        bios_open = (val == OPENBIOS_SUM_BE) || (val == OPENBIOS_SUM_LE);
        case (kind)
            K_DEC:  ch = (cp == 3'd7) ? 7'h20 : (lead && dig == 4'd0 && cp != 3'd6) ? 7'h20 : 7'h30 + {3'd0, dig};
            K_HEX:  ch = hexc(val[4 * (7 - cp) +: 4]);
            K_HEX4: ch = (cp < 3'd3 || cp == 3'd7) ? 7'h20 : hexc(val[4 * (7 - p7) +: 4]);
            K_BIN4: ch = (cp < 3'd3 || cp == 3'd7) ? 7'h20 : (val[7 - p7] ? 7'h31 : 7'h30);
            K_YN:   begin ch = val[0] ? strc("    YES ", cp) : strc("     NO ", cp); at = val[0] ? 2'd1 : 2'd2; end
            K_OK:   begin
                        if (!val[1]) ch = strc("      - ", cp);
                        else begin ch = val[0] ? strc("     OK ", cp) : strc("   FAIL ", cp); at = val[0] ? 2'd1 : 2'd2; end
                    end
            K_RUN:  begin ch = val[0] ? strc("RUNNING ", cp) : strc("   HELD ", cp); at = val[0] ? 2'd1 : 2'd3; end
            K_BIOS: begin
                        if (bios_bytes == 32'd0)  begin ch = strc("    NONE", cp); at = 2'd2; end
                        else if (!bios_size)      begin ch = strc("   SIZE?", cp); at = 2'd2; end
                        else if (bios_open)       begin ch = strc("OPENBIOS", cp); at = 2'd1; end
                        else                      begin ch = strc("     OWN", cp); at = 2'd1; end
                    end
            default: ;
        endcase
    end

    initial begin tx_we = 1'b0; tx_wa = 10'd0; tx_wd = 9'd0; end
    always @(posedge clk) begin
        tx_we <= 1'b0;
        case (st)
            S_PICK: begin
                kind <= k_f; val <= v_f; sh <= v_f; bcd <= 40'd0; it <= 6'd0; cp <= 3'd0; lead <= 1'b1;
                if (k_f == K_NONE) f <= (f == 7'd89) ? 7'd0 : f + 1'b1;
                else st <= (k_f == K_DEC) ? S_DAB : S_EMIT;
            end
            S_DAB: begin
                {bcd, sh} <= {adj[38:0], sh, 1'b0};
                it <= it + 1'b1;
                if (it == 6'd31) st <= S_EMIT;
            end
            default: begin
                tx_we <= 1'b1;
                tx_wa <= {f, cp};
                tx_wd <= {at, ch};
                if (kind == K_DEC && dig != 4'd0 && cp != 3'd7) lead <= 1'b0;
                cp <= cp + 1'b1;
                if (cp == 3'd7) begin st <= S_PICK; f <= (f == 7'd89) ? 7'd0 : f + 1'b1; end
            end
        endcase
    end
endmodule
