// Black-box stand-in for rtl/psx_top_pocket.vhd: the ports of psx_top_pocket_flat.vhd, driven by registered pseudo-random sources.
// Every input is XOR-folded into the source of its clock domain, so nothing behind the ports can be pruned.
// Replaced by psx_top_pocket_flat.vhd and the rtl files through the qsf. Mapping and the joypad packing: docs/pocket/POCKET_TOP.md.
// Domains: clk3x ram_* ddr3_* cache_* dma_* Cheats_Bus*; clk2x spuram_* sound_out_*; clkvid video outputs; clk1x the rest.
// joypadN is the joypad_t record flattened, first field in the MSB: PadPort{Enable,Digital,Analog,Mouse,GunCon,NeGcon,
// Justif,DS,Stick,Popn}, WheelMap, ToggleDS, Key{Triangle,Circle,Cross,Square,Select,Start,Right,Left,Up,Down,R1,R2,R3,L1,L2,L3},
// Analog1X, Analog1Y, Analog2X, Analog2Y (signed 8 bit each, [31:0]).
`default_nettype none

module psx_top_pocket_flat #(
    parameter [0:0] is_simu        = 1'b0,
    parameter       NO_MDEC        = 0,
    parameter       G_GPU_IMPL     = "pocket",
    parameter       G_CPU_IMPL     = "golden",
    parameter       G_SPU_IMPL     = "golden",
    parameter       G_CD_IMPL      = "golden",
    parameter       G_DMA_IMPL     = "golden",
    parameter       G_BUS_IMPL     = "golden",
    parameter       G_JOYPAD_IMPL  = "golden",
    parameter       G_MEMCARD_IMPL = "golden",
    parameter       G_MDEC_IMPL    = "golden",
    parameter       G_CD_NO_LIBCRYPT    = 0,
    parameter       G_CD_FIXED_TIMING   = 0,
    parameter       G_CD_NO_PEAK        = 0,
    parameter       G_CPU_NO_COP0_DEBUG = 0
) (
    input wire clk1x,
    input wire clk2x,
    input wire clk3x,
    input wire clkvid,
    input wire reset,
    output wire isPaused,
    input wire pause,
    input wire hps_busy,
    input wire loadExe,
    input wire [31:0] exe_initial_pc,
    input wire [31:0] exe_initial_gp,
    input wire [31:0] exe_load_address,
    input wire [31:0] exe_file_size,
    input wire [31:0] exe_stackpointer,
    input wire fastboot,
    input wire ram8mb,
    input wire TURBO_MEM,
    input wire TURBO_COMP,
    input wire TURBO_CACHE,
    input wire TURBO_CACHE50,
    input wire REPRODUCIBLEGPUTIMING,
    input wire INSTANTSEEK,
    input wire [2:0] FORCECDSPEED,
    input wire LIMITREADSPEED,
    input wire IGNORECDDMATIMING,
    input wire ditherOff,
    input wire interlaced480pHack,
    input wire showGunCrosshairs,
    input wire enableNeGconRumble,
    input wire fpscountOn,
    input wire cdslowOn,
    input wire testSeek,
    input wire pauseOnCDSlow,
    input wire errorOn,
    input wire LBAOn,
    input wire PATCHSERIAL,
    input wire noTexture,
    input wire [1:0] textureFilter,
    input wire [1:0] textureFilterStrength,
    input wire textureFilter2DOff,
    input wire dither24,
    input wire render24,
    input wire drawSlow,
    input wire syncVideoOut,
    input wire syncInterlace,
    input wire rotate180,
    input wire fixedVBlank,
    input wire [1:0] vCrop,
    input wire hCrop,
    input wire SPUon,
    input wire SPUIRQTrigger,
    input wire SPUSDRAM,
    input wire REVERBOFF,
    input wire REPRODUCIBLESPUDMA,
    input wire [1:0] WIDESCREEN,
    input wire oldGPU,
    input wire [1:0] biosregion,
    output wire ram_refresh,
    output wire [31:0] ram_dataWrite,
    input wire [31:0] ram_dataRead32,
    output wire [24:0] ram_Adr,
    output wire [1:0] ram_cntDMA,
    output wire [3:0] ram_be,
    output wire ram_rnw,
    output wire ram_ena,
    output wire ram_dma,
    output wire ram_cache,
    input wire ram_done,
    output wire [22:0] ram_dmafifo_adr,
    output wire [31:0] ram_dmafifo_data,
    output wire ram_dmafifo_empty,
    input wire ram_dmafifo_read,
    input wire [3:0] cache_wr,
    input wire [31:0] cache_data,
    input wire [7:0] cache_addr,
    input wire dma_wr,
    input wire dma_reqprocessed,
    input wire [31:0] dma_data,
    input wire ddr3_BUSY,
    input wire [63:0] ddr3_DOUT,
    input wire ddr3_DOUT_READY,
    output wire [7:0] ddr3_BURSTCNT,
    output wire [27:0] ddr3_ADDR,
    output wire [63:0] ddr3_DIN,
    output wire [7:0] ddr3_BE,
    output wire ddr3_WE,
    output wire ddr3_RD,
    input wire [1:0] region,
    output wire [1:0] region_out,
    input wire hasCD,
    input wire fastCD,
    input wire LIDopen,
    input wire [31:0] trackinfo_data,
    input wire [8:0] trackinfo_addr,
    input wire trackinfo_write,
    output wire resetFromCD,
    output wire cd_hps_req,
    output wire [31:0] cd_hps_lba,
    output wire [31:0] cd_hps_lba_sim,
    input wire cd_hps_ack,
    input wire cd_hps_write,
    input wire [15:0] cd_hps_data,
    output wire [31:0] spuram_dataWrite,
    output wire [18:0] spuram_Adr,
    output wire [3:0] spuram_be,
    output wire spuram_rnw,
    output wire spuram_ena,
    input wire [31:0] spuram_dataRead,
    input wire spuram_done,
    output wire memcard_changed,
    output wire saving_memcard,
    input wire memcard1_load,
    input wire memcard2_load,
    input wire memcard_save,
    input wire memcard1_mounted,
    input wire memcard1_available,
    output wire memcard1_rd,
    output wire memcard1_wr,
    output wire [6:0] memcard1_lba,
    input wire memcard1_ack,
    input wire memcard1_write,
    input wire [8:0] memcard1_addr,
    input wire [15:0] memcard1_dataIn,
    output wire [15:0] memcard1_dataOut,
    input wire memcard2_mounted,
    input wire memcard2_available,
    output wire memcard2_rd,
    output wire memcard2_wr,
    output wire [6:0] memcard2_lba,
    input wire memcard2_ack,
    input wire memcard2_write,
    input wire [8:0] memcard2_addr,
    input wire [15:0] memcard2_dataIn,
    output wire [15:0] memcard2_dataOut,
    input wire videoout_on,
    input wire isPal,
    input wire pal60,
    output wire hsync,
    output wire vsync,
    output wire hblank,
    output wire vblank,
    output wire [10:0] DisplayWidth,
    output wire [9:0] DisplayHeight,
    output wire [9:0] DisplayOffsetX,
    output wire [8:0] DisplayOffsetY,
    output wire video_ce,
    output wire video_interlace,
    output wire [7:0] video_r,
    output wire [7:0] video_g,
    output wire [7:0] video_b,
    output wire video_isPal,
    output wire video_fbmode,
    output wire video_fb24,
    output wire [2:0] video_hResMode,
    output wire [3:0] video_frameindex,
    input wire DSAltSwitchMode,
    input wire [59:0] joypad1,
    input wire [59:0] joypad2,
    input wire [59:0] joypad3,
    input wire [59:0] joypad4,
    input wire multitap,
    input wire multitapDigital,
    input wire multitapAnalog,
    input wire neGconRumble,
    output wire [15:0] joypad1_rumble,
    output wire [15:0] joypad2_rumble,
    output wire [15:0] joypad3_rumble,
    output wire [15:0] joypad4_rumble,
    output wire [1:0] padMode,
    input wire MouseEvent,
    input wire MouseLeft,
    input wire MouseRight,
    input wire [8:0] MouseX,
    input wire [8:0] MouseY,
    input wire snacPort1,
    input wire snacPort2,
    input wire irq10Snac,
    input wire actionNextSnac,
    input wire receiveValidSnac,
    input wire ackSnac,
    input wire snacMC,
    input wire [7:0] receiveBufferSnac,
    output wire [7:0] transmitValueSnac,
    output wire selectedPort1Snac,
    output wire selectedPort2Snac,
    output wire clk9Snac,
    output wire beginTransferSnac,
    output wire [15:0] sound_out_left,
    output wire [15:0] sound_out_right,
    input wire increaseSSHeaderCount,
    input wire save_state,
    input wire load_state,
    input wire [1:0] savestate_number,
    output wire state_loaded,
    output wire [3:0] validSStates,
    input wire rewind_on,
    input wire rewind_active,
    input wire cheat_clear,
    input wire cheats_enabled,
    input wire cheat_on,
    input wire [127:0] cheat_in,
    output wire cheats_active,
    output wire [20:0] Cheats_BusAddr,
    output wire Cheats_BusRnW,
    output wire [3:0] Cheats_BusByteEnable,
    output wire [31:0] Cheats_BusWriteData,
    output wire Cheats_Bus_ena,
    input wire [31:0] Cheats_BusReadData,
    input wire Cheats_BusDone
);

// ---- clk1x domain
reg [204:0] s_1x = 205'd0;
reg        f_1x = 1'b0;
always @(posedge clk1x) f_1x <= ^{reset, pause, hps_busy, loadExe, exe_initial_pc, exe_initial_gp, exe_load_address, exe_file_size, exe_stackpointer, fastboot, ram8mb, TURBO_MEM, TURBO_COMP, TURBO_CACHE, TURBO_CACHE50, REPRODUCIBLEGPUTIMING, INSTANTSEEK, FORCECDSPEED, LIMITREADSPEED, IGNORECDDMATIMING, ditherOff, interlaced480pHack, showGunCrosshairs, enableNeGconRumble, fpscountOn, cdslowOn, testSeek, pauseOnCDSlow, errorOn, LBAOn, PATCHSERIAL, noTexture, textureFilter, textureFilterStrength, textureFilter2DOff, dither24, render24, drawSlow, syncVideoOut, syncInterlace, rotate180, fixedVBlank, vCrop, hCrop, SPUon, SPUIRQTrigger, SPUSDRAM, REVERBOFF, REPRODUCIBLESPUDMA, WIDESCREEN, oldGPU, biosregion, region, hasCD, fastCD, LIDopen, trackinfo_data, trackinfo_addr, trackinfo_write, cd_hps_ack, cd_hps_write, cd_hps_data, memcard1_load, memcard2_load, memcard_save, memcard1_mounted, memcard1_available, memcard1_ack, memcard1_write, memcard1_addr, memcard1_dataIn, memcard2_mounted, memcard2_available, memcard2_ack, memcard2_write, memcard2_addr, memcard2_dataIn, videoout_on, isPal, pal60, DSAltSwitchMode, joypad1, joypad2, joypad3, joypad4, multitap, multitapDigital, multitapAnalog, neGconRumble, MouseEvent, MouseLeft, MouseRight, MouseX, MouseY, snacPort1, snacPort2, irq10Snac, actionNextSnac, receiveValidSnac, ackSnac, snacMC, receiveBufferSnac, increaseSSHeaderCount, save_state, load_state, savestate_number, rewind_on, rewind_active, cheat_clear, cheats_enabled, cheat_on, cheat_in};
always @(posedge clk1x) s_1x <= {s_1x[203:0], s_1x[204]} ^ {s_1x[67:0], s_1x[204:68]} ^ {{204{1'b0}}, f_1x ^ ~s_1x[204]};
assign isPaused = s_1x[0 +: 1];
assign region_out = s_1x[1 +: 2];
assign resetFromCD = s_1x[3 +: 1];
assign cd_hps_req = s_1x[4 +: 1];
assign cd_hps_lba = s_1x[5 +: 32];
assign cd_hps_lba_sim = s_1x[37 +: 32];
assign memcard_changed = s_1x[69 +: 1];
assign saving_memcard = s_1x[70 +: 1];
assign memcard1_rd = s_1x[71 +: 1];
assign memcard1_wr = s_1x[72 +: 1];
assign memcard1_lba = s_1x[73 +: 7];
assign memcard1_dataOut = s_1x[80 +: 16];
assign memcard2_rd = s_1x[96 +: 1];
assign memcard2_wr = s_1x[97 +: 1];
assign memcard2_lba = s_1x[98 +: 7];
assign memcard2_dataOut = s_1x[105 +: 16];
assign joypad1_rumble = s_1x[121 +: 16];
assign joypad2_rumble = s_1x[137 +: 16];
assign joypad3_rumble = s_1x[153 +: 16];
assign joypad4_rumble = s_1x[169 +: 16];
assign padMode = s_1x[185 +: 2];
assign transmitValueSnac = s_1x[187 +: 8];
assign selectedPort1Snac = s_1x[195 +: 1];
assign selectedPort2Snac = s_1x[196 +: 1];
assign clk9Snac = s_1x[197 +: 1];
assign beginTransferSnac = s_1x[198 +: 1];
assign state_loaded = s_1x[199 +: 1];
assign validSStates = s_1x[200 +: 4];
assign cheats_active = s_1x[204 +: 1];

// ---- clk2x domain
reg [88:0] s_2x = 89'd0;
reg        f_2x = 1'b0;
always @(posedge clk2x) f_2x <= ^{spuram_dataRead, spuram_done};
always @(posedge clk2x) s_2x <= {s_2x[87:0], s_2x[88]} ^ {s_2x[28:0], s_2x[88:29]} ^ {{88{1'b0}}, f_2x ^ ~s_2x[88]};
assign spuram_dataWrite = s_2x[0 +: 32];
assign spuram_Adr = s_2x[32 +: 19];
assign spuram_be = s_2x[51 +: 4];
assign spuram_rnw = s_2x[55 +: 1];
assign spuram_ena = s_2x[56 +: 1];
assign sound_out_left = s_2x[57 +: 16];
assign sound_out_right = s_2x[73 +: 16];

// ---- clk3x domain
reg [292:0] s_3x = 293'd0;
reg        f_3x = 1'b0;
always @(posedge clk3x) f_3x <= ^{ram_dataRead32, ram_done, ram_dmafifo_read, cache_wr, cache_data, cache_addr, dma_wr, dma_reqprocessed, dma_data, ddr3_BUSY, ddr3_DOUT, ddr3_DOUT_READY, Cheats_BusReadData, Cheats_BusDone};
always @(posedge clk3x) s_3x <= {s_3x[291:0], s_3x[292]} ^ {s_3x[96:0], s_3x[292:97]} ^ {{292{1'b0}}, f_3x ^ ~s_3x[292]};
assign ram_refresh = s_3x[0 +: 1];
assign ram_dataWrite = s_3x[1 +: 32];
assign ram_Adr = s_3x[33 +: 25];
assign ram_cntDMA = s_3x[58 +: 2];
assign ram_be = s_3x[60 +: 4];
assign ram_rnw = s_3x[64 +: 1];
assign ram_ena = s_3x[65 +: 1];
assign ram_dma = s_3x[66 +: 1];
assign ram_cache = s_3x[67 +: 1];
assign ram_dmafifo_adr = s_3x[68 +: 23];
assign ram_dmafifo_data = s_3x[91 +: 32];
assign ram_dmafifo_empty = s_3x[123 +: 1];
assign ddr3_BURSTCNT = s_3x[124 +: 8];
assign ddr3_ADDR = s_3x[132 +: 28];
assign ddr3_DIN = s_3x[160 +: 64];
assign ddr3_BE = s_3x[224 +: 8];
assign ddr3_WE = s_3x[232 +: 1];
assign ddr3_RD = s_3x[233 +: 1];
assign Cheats_BusAddr = s_3x[234 +: 21];
assign Cheats_BusRnW = s_3x[255 +: 1];
assign Cheats_BusByteEnable = s_3x[256 +: 4];
assign Cheats_BusWriteData = s_3x[260 +: 32];
assign Cheats_Bus_ena = s_3x[292 +: 1];

// ---- clkvid domain
reg [79:0] s_vid = 80'd0;
reg        f_vid = 1'b0;
always @(posedge clkvid) f_vid <= 1'b0;
always @(posedge clkvid) s_vid <= {s_vid[78:0], s_vid[79]} ^ {s_vid[25:0], s_vid[79:26]} ^ {{79{1'b0}}, f_vid ^ ~s_vid[79]};
assign hsync = s_vid[0 +: 1];
assign vsync = s_vid[1 +: 1];
assign hblank = s_vid[2 +: 1];
assign vblank = s_vid[3 +: 1];
assign DisplayWidth = s_vid[4 +: 11];
assign DisplayHeight = s_vid[15 +: 10];
assign DisplayOffsetX = s_vid[25 +: 10];
assign DisplayOffsetY = s_vid[35 +: 9];
assign video_ce = s_vid[44 +: 1];
assign video_interlace = s_vid[45 +: 1];
assign video_r = s_vid[46 +: 8];
assign video_g = s_vid[54 +: 8];
assign video_b = s_vid[62 +: 8];
assign video_isPal = s_vid[70 +: 1];
assign video_fbmode = s_vid[71 +: 1];
assign video_fb24 = s_vid[72 +: 1];
assign video_hResMode = s_vid[73 +: 3];
assign video_frameindex = s_vid[76 +: 4];

endmodule
