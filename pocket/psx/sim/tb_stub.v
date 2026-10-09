`timescale 1ns/1ps
// The stub's outputs must move in every clock domain and never be X once its inputs are driven.
module tb_stub;
    reg clk1x = 0, clk2x = 0, clk3x = 0, clkvid = 0;
    always #14.76 clk1x = ~clk1x;
    always #7.38  clk2x = ~clk2x;
    always #4.92  clk3x = ~clk3x;
    always #78.7  clkvid = ~clkvid;

    wire        isPaused, ram_ena, ddr3_WE, spuram_ena, cd_hps_req, hsync;
    wire [0:0] o_ram_refresh;
    wire [31:0] o_ram_dataWrite;
    wire [1:0] o_ram_cntDMA;
    wire [3:0] o_ram_be;
    wire [0:0] o_ram_rnw;
    wire [0:0] o_ram_dma;
    wire [0:0] o_ram_cache;
    wire [22:0] o_ram_dmafifo_adr;
    wire [31:0] o_ram_dmafifo_data;
    wire [0:0] o_ram_dmafifo_empty;
    wire [7:0] o_ddr3_BURSTCNT;
    wire [63:0] o_ddr3_DIN;
    wire [7:0] o_ddr3_BE;
    wire [0:0] o_ddr3_RD;
    wire [1:0] o_region_out;
    wire [0:0] o_resetFromCD;
    wire [31:0] o_cd_hps_lba;
    wire [31:0] o_cd_hps_lba_sim;
    wire [31:0] o_spuram_dataWrite;
    wire [18:0] o_spuram_Adr;
    wire [3:0] o_spuram_be;
    wire [0:0] o_spuram_rnw;
    wire [0:0] o_memcard_changed;
    wire [0:0] o_saving_memcard;
    wire [0:0] o_memcard1_rd;
    wire [0:0] o_memcard1_wr;
    wire [6:0] o_memcard1_lba;
    wire [15:0] o_memcard1_dataOut;
    wire [0:0] o_memcard2_rd;
    wire [0:0] o_memcard2_wr;
    wire [6:0] o_memcard2_lba;
    wire [15:0] o_memcard2_dataOut;
    wire [0:0] o_vsync;
    wire [0:0] o_hblank;
    wire [0:0] o_vblank;
    wire [10:0] o_DisplayWidth;
    wire [9:0] o_DisplayHeight;
    wire [9:0] o_DisplayOffsetX;
    wire [8:0] o_DisplayOffsetY;
    wire [0:0] o_video_ce;
    wire [0:0] o_video_interlace;
    wire [7:0] o_video_r;
    wire [7:0] o_video_b;
    wire [0:0] o_video_isPal;
    wire [0:0] o_video_fbmode;
    wire [0:0] o_video_fb24;
    wire [2:0] o_video_hResMode;
    wire [3:0] o_video_frameindex;
    wire [15:0] o_joypad1_rumble;
    wire [15:0] o_joypad2_rumble;
    wire [15:0] o_joypad3_rumble;
    wire [15:0] o_joypad4_rumble;
    wire [1:0] o_padMode;
    wire [7:0] o_transmitValueSnac;
    wire [0:0] o_selectedPort1Snac;
    wire [0:0] o_selectedPort2Snac;
    wire [0:0] o_clk9Snac;
    wire [0:0] o_beginTransferSnac;
    wire [15:0] o_sound_out_right;
    wire [0:0] o_state_loaded;
    wire [3:0] o_validSStates;
    wire [0:0] o_cheats_active;
    wire [20:0] o_Cheats_BusAddr;
    wire [0:0] o_Cheats_BusRnW;
    wire [3:0] o_Cheats_BusByteEnable;
    wire [31:0] o_Cheats_BusWriteData;
    wire [0:0] o_Cheats_Bus_ena;
    wire [24:0] ram_Adr;
    wire [27:0] ddr3_ADDR;
    wire [15:0] sound_out_left;
    wire [7:0]  video_g;

    psx_top_pocket_flat dut (
        .clk1x(clk1x),
        .clk2x(clk2x),
        .clk3x(clk3x),
        .clkvid(clkvid),
        .reset(1'd0),
        .isPaused(isPaused),
        .pause(1'd0),
        .hps_busy(1'd0),
        .loadExe(1'd0),
        .exe_initial_pc(32'd0),
        .exe_initial_gp(32'd0),
        .exe_load_address(32'd0),
        .exe_file_size(32'd0),
        .exe_stackpointer(32'd0),
        .fastboot(1'd0),
        .ram8mb(1'd0),
        .TURBO_MEM(1'd0),
        .TURBO_COMP(1'd0),
        .TURBO_CACHE(1'd0),
        .TURBO_CACHE50(1'd0),
        .REPRODUCIBLEGPUTIMING(1'd0),
        .INSTANTSEEK(1'd0),
        .FORCECDSPEED(3'd0),
        .LIMITREADSPEED(1'd0),
        .IGNORECDDMATIMING(1'd0),
        .ditherOff(1'd0),
        .interlaced480pHack(1'd0),
        .showGunCrosshairs(1'd0),
        .enableNeGconRumble(1'd0),
        .fpscountOn(1'd0),
        .cdslowOn(1'd0),
        .testSeek(1'd0),
        .pauseOnCDSlow(1'd0),
        .errorOn(1'd0),
        .LBAOn(1'd0),
        .PATCHSERIAL(1'd0),
        .noTexture(1'd0),
        .textureFilter(2'd0),
        .textureFilterStrength(2'd0),
        .textureFilter2DOff(1'd0),
        .dither24(1'd0),
        .render24(1'd0),
        .drawSlow(1'd0),
        .syncVideoOut(1'd0),
        .syncInterlace(1'd0),
        .rotate180(1'd0),
        .fixedVBlank(1'd0),
        .vCrop(2'd0),
        .hCrop(1'd0),
        .SPUon(1'd0),
        .SPUIRQTrigger(1'd0),
        .SPUSDRAM(1'd0),
        .REVERBOFF(1'd0),
        .REPRODUCIBLESPUDMA(1'd0),
        .WIDESCREEN(2'd0),
        .oldGPU(1'd0),
        .biosregion(2'd0),
        .ram_refresh(o_ram_refresh),
        .ram_dataWrite(o_ram_dataWrite),
        .ram_dataRead32(32'd0),
        .ram_Adr(ram_Adr),
        .ram_cntDMA(o_ram_cntDMA),
        .ram_be(o_ram_be),
        .ram_rnw(o_ram_rnw),
        .ram_ena(ram_ena),
        .ram_dma(o_ram_dma),
        .ram_cache(o_ram_cache),
        .ram_done(1'd0),
        .ram_dmafifo_adr(o_ram_dmafifo_adr),
        .ram_dmafifo_data(o_ram_dmafifo_data),
        .ram_dmafifo_empty(o_ram_dmafifo_empty),
        .ram_dmafifo_read(1'd0),
        .cache_wr(4'd0),
        .cache_data(32'd0),
        .cache_addr(8'd0),
        .dma_wr(1'd0),
        .dma_reqprocessed(1'd0),
        .dma_data(32'd0),
        .ddr3_BUSY(1'd0),
        .ddr3_DOUT(64'd0),
        .ddr3_DOUT_READY(1'd0),
        .ddr3_BURSTCNT(o_ddr3_BURSTCNT),
        .ddr3_ADDR(ddr3_ADDR),
        .ddr3_DIN(o_ddr3_DIN),
        .ddr3_BE(o_ddr3_BE),
        .ddr3_WE(ddr3_WE),
        .ddr3_RD(o_ddr3_RD),
        .region(2'd0),
        .region_out(o_region_out),
        .hasCD(1'd0),
        .fastCD(1'd0),
        .LIDopen(1'd0),
        .trackinfo_data(32'd0),
        .trackinfo_addr(9'd0),
        .trackinfo_write(1'd0),
        .resetFromCD(o_resetFromCD),
        .cd_hps_req(cd_hps_req),
        .cd_hps_lba(o_cd_hps_lba),
        .cd_hps_lba_sim(o_cd_hps_lba_sim),
        .cd_hps_ack(1'd0),
        .cd_hps_write(1'd0),
        .cd_hps_data(16'd0),
        .spuram_dataWrite(o_spuram_dataWrite),
        .spuram_Adr(o_spuram_Adr),
        .spuram_be(o_spuram_be),
        .spuram_rnw(o_spuram_rnw),
        .spuram_ena(spuram_ena),
        .spuram_dataRead(32'd0),
        .spuram_done(1'd0),
        .memcard_changed(o_memcard_changed),
        .saving_memcard(o_saving_memcard),
        .memcard1_load(1'd0),
        .memcard2_load(1'd0),
        .memcard_save(1'd0),
        .memcard1_mounted(1'd0),
        .memcard1_available(1'd0),
        .memcard1_rd(o_memcard1_rd),
        .memcard1_wr(o_memcard1_wr),
        .memcard1_lba(o_memcard1_lba),
        .memcard1_ack(1'd0),
        .memcard1_write(1'd0),
        .memcard1_addr(9'd0),
        .memcard1_dataIn(16'd0),
        .memcard1_dataOut(o_memcard1_dataOut),
        .memcard2_mounted(1'd0),
        .memcard2_available(1'd0),
        .memcard2_rd(o_memcard2_rd),
        .memcard2_wr(o_memcard2_wr),
        .memcard2_lba(o_memcard2_lba),
        .memcard2_ack(1'd0),
        .memcard2_write(1'd0),
        .memcard2_addr(9'd0),
        .memcard2_dataIn(16'd0),
        .memcard2_dataOut(o_memcard2_dataOut),
        .videoout_on(1'd0),
        .isPal(1'd0),
        .pal60(1'd0),
        .hsync(hsync),
        .vsync(o_vsync),
        .hblank(o_hblank),
        .vblank(o_vblank),
        .DisplayWidth(o_DisplayWidth),
        .DisplayHeight(o_DisplayHeight),
        .DisplayOffsetX(o_DisplayOffsetX),
        .DisplayOffsetY(o_DisplayOffsetY),
        .video_ce(o_video_ce),
        .video_interlace(o_video_interlace),
        .video_r(o_video_r),
        .video_g(video_g),
        .video_b(o_video_b),
        .video_isPal(o_video_isPal),
        .video_fbmode(o_video_fbmode),
        .video_fb24(o_video_fb24),
        .video_hResMode(o_video_hResMode),
        .video_frameindex(o_video_frameindex),
        .DSAltSwitchMode(1'd0),
        .joypad1(60'd0),
        .joypad2(60'd0),
        .joypad3(60'd0),
        .joypad4(60'd0),
        .multitap(1'd0),
        .multitapDigital(1'd0),
        .multitapAnalog(1'd0),
        .neGconRumble(1'd0),
        .joypad1_rumble(o_joypad1_rumble),
        .joypad2_rumble(o_joypad2_rumble),
        .joypad3_rumble(o_joypad3_rumble),
        .joypad4_rumble(o_joypad4_rumble),
        .padMode(o_padMode),
        .MouseEvent(1'd0),
        .MouseLeft(1'd0),
        .MouseRight(1'd0),
        .MouseX(9'd0),
        .MouseY(9'd0),
        .snacPort1(1'd0),
        .snacPort2(1'd0),
        .irq10Snac(1'd0),
        .actionNextSnac(1'd0),
        .receiveValidSnac(1'd0),
        .ackSnac(1'd0),
        .snacMC(1'd0),
        .receiveBufferSnac(8'd0),
        .transmitValueSnac(o_transmitValueSnac),
        .selectedPort1Snac(o_selectedPort1Snac),
        .selectedPort2Snac(o_selectedPort2Snac),
        .clk9Snac(o_clk9Snac),
        .beginTransferSnac(o_beginTransferSnac),
        .sound_out_left(sound_out_left),
        .sound_out_right(o_sound_out_right),
        .increaseSSHeaderCount(1'd0),
        .save_state(1'd0),
        .load_state(1'd0),
        .savestate_number(2'd0),
        .state_loaded(o_state_loaded),
        .validSStates(o_validSStates),
        .rewind_on(1'd0),
        .rewind_active(1'd0),
        .cheat_clear(1'd0),
        .cheats_enabled(1'd0),
        .cheat_on(1'd0),
        .cheat_in(128'd0),
        .cheats_active(o_cheats_active),
        .Cheats_BusAddr(o_Cheats_BusAddr),
        .Cheats_BusRnW(o_Cheats_BusRnW),
        .Cheats_BusByteEnable(o_Cheats_BusByteEnable),
        .Cheats_BusWriteData(o_Cheats_BusWriteData),
        .Cheats_Bus_ena(o_Cheats_Bus_ena),
        .Cheats_BusReadData(32'd0),
        .Cheats_BusDone(1'd0)
    );

    integer tog_ram = 0, tog_ddr = 0, tog_snd = 0, tog_vid = 0, tog_cd = 0;
    reg ram_q, ddr_q, cd_q, hs_q;
    reg [15:0] snd_q;
    always @(posedge clk3x) begin ram_q <= ram_ena; ddr_q <= ddr3_WE; if (ram_q !== ram_ena) tog_ram = tog_ram + 1; if (ddr_q !== ddr3_WE) tog_ddr = tog_ddr + 1; end
    always @(posedge clk2x) begin snd_q <= sound_out_left; if (snd_q !== sound_out_left) tog_snd = tog_snd + 1; end
    always @(posedge clkvid) begin hs_q <= hsync; if (hs_q !== hsync) tog_vid = tog_vid + 1; end
    always @(posedge clk1x) begin cd_q <= cd_hps_req; if (cd_q !== cd_hps_req) tog_cd = tog_cd + 1; end

    initial begin
        #100000;
        $display("toggles: ram_ena %0d ddr3_WE %0d sound %0d hsync %0d cd_req %0d", tog_ram, tog_ddr, tog_snd, tog_vid, tog_cd);
        if (tog_ram > 100 && tog_ddr > 100 && tog_snd > 100 && tog_vid > 10 && tog_cd > 10 && ^{ram_ena, ddr3_WE, hsync, sound_out_left} !== 1'bx)
            $display("PASS");
        else
            $display("FAIL");
        $finish;
    end
endmodule
