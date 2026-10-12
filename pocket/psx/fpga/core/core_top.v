//
// User core top-level: APF bridge, clocks, shared memory controllers and the PSX core stub.
// Instantiated by the real top-level: apf_top. Layout and placeholders: docs/pocket/POCKET_TOP.md, "Shell skeleton".
//

`default_nettype none

module core_top (

//
// physical connections
//

///////////////////////////////////////////////////
// clock inputs 74.25mhz. not phase aligned, so treat these domains as asynchronous

input   wire            clk_74a, // mainclk1
input   wire            clk_74b, // mainclk1 

///////////////////////////////////////////////////
// cartridge interface
// switches between 3.3v and 5v mechanically
// output enable for multibit translators controlled by pic32

// GBA AD[15:8]
inout   wire    [7:0]   cart_tran_bank2,
output  wire            cart_tran_bank2_dir,

// GBA AD[7:0]
inout   wire    [7:0]   cart_tran_bank3,
output  wire            cart_tran_bank3_dir,

// GBA A[23:16]
inout   wire    [7:0]   cart_tran_bank1,
output  wire            cart_tran_bank1_dir,

// GBA [7] PHI#
// GBA [6] WR#
// GBA [5] RD#
// GBA [4] CS1#/CS#
//     [3:0] unwired
inout   wire    [7:4]   cart_tran_bank0,
output  wire            cart_tran_bank0_dir,

// GBA CS2#/RES#
inout   wire            cart_tran_pin30,
output  wire            cart_tran_pin30_dir,
// when GBC cart is inserted, this signal when low or weak will pull GBC /RES low with a special circuit
// the goal is that when unconfigured, the FPGA weak pullups won't interfere.
// thus, if GBC cart is inserted, FPGA must drive this high in order to let the level translators
// and general IO drive this pin.
output  wire            cart_pin30_pwroff_reset,

// GBA IRQ/DRQ
inout   wire            cart_tran_pin31,
output  wire            cart_tran_pin31_dir,

// infrared
input   wire            port_ir_rx,
output  wire            port_ir_tx,
output  wire            port_ir_rx_disable, 

// GBA link port
inout   wire            port_tran_si,
output  wire            port_tran_si_dir,
inout   wire            port_tran_so,
output  wire            port_tran_so_dir,
inout   wire            port_tran_sck,
output  wire            port_tran_sck_dir,
inout   wire            port_tran_sd,
output  wire            port_tran_sd_dir,
 
///////////////////////////////////////////////////
// cellular psram 0 and 1, two chips (64mbit x2 dual die per chip)

output  wire    [21:16] cram0_a,
inout   wire    [15:0]  cram0_dq,
input   wire            cram0_wait,
output  wire            cram0_clk,
output  wire            cram0_adv_n,
output  wire            cram0_cre,
output  wire            cram0_ce0_n,
output  wire            cram0_ce1_n,
output  wire            cram0_oe_n,
output  wire            cram0_we_n,
output  wire            cram0_ub_n,
output  wire            cram0_lb_n,

output  wire    [21:16] cram1_a,
inout   wire    [15:0]  cram1_dq,
input   wire            cram1_wait,
output  wire            cram1_clk,
output  wire            cram1_adv_n,
output  wire            cram1_cre,
output  wire            cram1_ce0_n,
output  wire            cram1_ce1_n,
output  wire            cram1_oe_n,
output  wire            cram1_we_n,
output  wire            cram1_ub_n,
output  wire            cram1_lb_n,

///////////////////////////////////////////////////
// sdram, 512mbit 16bit

output  wire    [12:0]  dram_a,
output  wire    [1:0]   dram_ba,
inout   wire    [15:0]  dram_dq,
output  wire    [1:0]   dram_dqm,
output  wire            dram_clk,
output  wire            dram_cke,
output  wire            dram_ras_n,
output  wire            dram_cas_n,
output  wire            dram_we_n,

///////////////////////////////////////////////////
// sram, 1mbit 16bit

output  wire    [16:0]  sram_a,
inout   wire    [15:0]  sram_dq,
output  wire            sram_oe_n,
output  wire            sram_we_n,
output  wire            sram_ub_n,
output  wire            sram_lb_n,

///////////////////////////////////////////////////
// vblank driven by dock for sync in a certain mode

input   wire            vblank,

///////////////////////////////////////////////////
// i/o to 6515D breakout usb uart

output  wire            dbg_tx,
input   wire            dbg_rx,

///////////////////////////////////////////////////
// i/o pads near jtag connector user can solder to

output  wire            user1,
input   wire            user2,

///////////////////////////////////////////////////
// RFU internal i2c bus 

inout   wire            aux_sda,
output  wire            aux_scl,

///////////////////////////////////////////////////
// RFU, do not use
output  wire            vpll_feed,


//
// logical connections
//

///////////////////////////////////////////////////
// video, audio output to scaler
output  wire    [23:0]  video_rgb,
output  wire            video_rgb_clock,
output  wire            video_rgb_clock_90,
output  wire            video_de,
output  wire            video_skip,
output  wire            video_vs,
output  wire            video_hs,
    
output  wire            audio_mclk,
input   wire            audio_adc,
output  wire            audio_dac,
output  wire            audio_lrck,

///////////////////////////////////////////////////
// bridge bus connection
// synchronous to clk_74a
output  wire            bridge_endian_little,
input   wire    [31:0]  bridge_addr,
input   wire            bridge_rd,
output  reg     [31:0]  bridge_rd_data,
input   wire            bridge_wr,
input   wire    [31:0]  bridge_wr_data,

///////////////////////////////////////////////////
// controller data
// 
// key bitmap:
//   [0]    dpad_up
//   [1]    dpad_down
//   [2]    dpad_left
//   [3]    dpad_right
//   [4]    face_a
//   [5]    face_b
//   [6]    face_x
//   [7]    face_y
//   [8]    trig_l1
//   [9]    trig_r1
//   [10]   trig_l2
//   [11]   trig_r2
//   [12]   trig_l3
//   [13]   trig_r3
//   [14]   face_select
//   [15]   face_start
//   [31:28] type
// joy values - unsigned
//   [ 7: 0] lstick_x
//   [15: 8] lstick_y
//   [23:16] rstick_x
//   [31:24] rstick_y
// trigger values - unsigned
//   [ 7: 0] ltrig
//   [15: 8] rtrig
//
input   wire    [31:0]  cont1_key,
input   wire    [31:0]  cont2_key,
input   wire    [31:0]  cont3_key,
input   wire    [31:0]  cont4_key,
input   wire    [31:0]  cont1_joy,
input   wire    [31:0]  cont2_joy,
input   wire    [31:0]  cont3_joy,
input   wire    [31:0]  cont4_joy,
input   wire    [15:0]  cont1_trig,
input   wire    [15:0]  cont2_trig,
input   wire    [15:0]  cont3_trig,
input   wire    [15:0]  cont4_trig
    
);
// not using the IR port, so turn off both the LED, and
// disable the receive circuit to save power
assign port_ir_tx = 0;
assign port_ir_rx_disable = 1;

// bridge endianness
assign bridge_endian_little = 0;

// cart is unused, so set all level translators accordingly
// directions are 0:IN, 1:OUT
assign cart_tran_bank3 = 8'hzz;
assign cart_tran_bank3_dir = 1'b0;
assign cart_tran_bank2 = 8'hzz;
assign cart_tran_bank2_dir = 1'b0;
assign cart_tran_bank1 = 8'hzz;
assign cart_tran_bank1_dir = 1'b0;
assign cart_tran_bank0 = 4'hf;
assign cart_tran_bank0_dir = 1'b1;
assign cart_tran_pin30 = 1'b0;      // reset or cs2, we let the hw control it by itself
assign cart_tran_pin30_dir = 1'bz;
assign cart_pin30_pwroff_reset = 1'b0;  // hardware can control this
assign cart_tran_pin31 = 1'bz;      // input
assign cart_tran_pin31_dir = 1'b0;  // input

// link port is unused, set to input only to be safe
// each bit may be bidirectional in some applications
assign port_tran_so = 1'bz;
assign port_tran_so_dir = 1'b0;     // SO is output only
assign port_tran_si = 1'bz;
assign port_tran_si_dir = 1'b0;     // SI is input only
assign port_tran_sck = 1'bz;
assign port_tran_sck_dir = 1'b0;    // clock direction can change
assign port_tran_sd = 1'bz;
assign port_tran_sd_dir = 1'b0;     // SD is input and not used

assign dbg_tx = 1'bZ;
assign user1 = 1'bZ;
assign aux_scl = 1'bZ;
assign vpll_feed = 1'bZ;


///////////////////////////////////////////////////////////////////////////////
// clocks: 74.25 MHz in; clk1x/clk2x/clk3x 33.8688/67.7376/101.6064 MHz, clk_sys 135.4752 MHz with the SDRAM
// pin clock clk_sd and the read capture clock clk_cap (moved by the calibration, scan clock clk1x), and the
// placeholder pixel clock pair
wire clk1x, clk2x, clk3x, clk_sys, clk_sd, clk_cap, clk_vid, clk_vid_90;
wire ps_en, ps_up, ps_done;
wire pll_core_locked;
wire pll_core_locked_s;
synch_3 s01(pll_core_locked, pll_core_locked_s, clk_74a);

pll_psx pll (
    .refclk     ( clk_74a ),
    .rst        ( 1'b0 ),
    .clk1x      ( clk1x ),
    .clk2x      ( clk2x ),
    .clk3x      ( clk3x ),
    .clk_sys    ( clk_sys ),
    .clk_sd     ( clk_sd ),
    .clk_cap    ( clk_cap ),
    .clk_vid    ( clk_vid ),
    .clk_vid_90 ( clk_vid_90 ),
    .locked     ( pll_core_locked ),
    .phase_en   ( ps_en ),
    .updn       ( ps_up ),
    .phase_done ( ps_done )
);

///////////////////////////////////////////////////////////////////////////////
// host/target command handler (clk_74a)
wire            reset_n;
wire    [31:0]  cmd_bridge_rd_data;

wire            status_boot_done  = pll_core_locked_s;
wire            status_setup_done = pll_core_locked_s;
wire            status_running    = reset_n;

wire            dataslot_requestread;
wire    [15:0]  dataslot_requestread_id;
wire            dataslot_requestwrite;
wire    [15:0]  dataslot_requestwrite_id;
wire    [31:0]  dataslot_requestwrite_size;
wire            dataslot_update;
wire    [15:0]  dataslot_update_id;
wire    [31:0]  dataslot_update_size;
wire            dataslot_allcomplete;
wire    [31:0]  rtc_epoch_seconds, rtc_date_bcd, rtc_time_bcd;
wire            rtc_valid;
wire            osnotify_inmenu;

wire            target_dataslot_read;
wire            target_dataslot_ack, target_dataslot_done;
wire    [2:0]   target_dataslot_err;
wire    [15:0]  target_dataslot_id;
wire    [31:0]  target_dataslot_slotoffset, target_dataslot_bridgeaddr, target_dataslot_length;

wire    [9:0]   datatable_addr;
wire    [31:0]  datatable_q;

core_bridge_cmd icb (
    .clk                ( clk_74a ),
    .reset_n            ( reset_n ),

    .bridge_endian_little   ( bridge_endian_little ),
    .bridge_addr            ( bridge_addr ),
    .bridge_rd              ( bridge_rd ),
    .bridge_rd_data         ( cmd_bridge_rd_data ),
    .bridge_wr              ( bridge_wr ),
    .bridge_wr_data         ( bridge_wr_data ),

    .status_boot_done       ( status_boot_done ),
    .status_setup_done      ( status_setup_done ),
    .status_running         ( status_running ),

    .dataslot_requestread       ( dataslot_requestread ),
    .dataslot_requestread_id    ( dataslot_requestread_id ),
    .dataslot_requestread_ack   ( 1'b1 ),
    .dataslot_requestread_ok    ( 1'b1 ),

    .dataslot_requestwrite      ( dataslot_requestwrite ),
    .dataslot_requestwrite_id   ( dataslot_requestwrite_id ),
    .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
    .dataslot_requestwrite_ack  ( 1'b1 ),
    .dataslot_requestwrite_ok   ( 1'b1 ),

    .dataslot_update            ( dataslot_update ),
    .dataslot_update_id         ( dataslot_update_id ),
    .dataslot_update_size       ( dataslot_update_size ),
    .dataslot_allcomplete       ( dataslot_allcomplete ),

    .rtc_epoch_seconds      ( rtc_epoch_seconds ),
    .rtc_date_bcd           ( rtc_date_bcd ),
    .rtc_time_bcd           ( rtc_time_bcd ),
    .rtc_valid              ( rtc_valid ),

    .osnotify_inmenu        ( osnotify_inmenu ),

    .target_dataslot_read       ( target_dataslot_read ),
    .target_dataslot_write      ( 1'b0 ),
    .target_dataslot_ack        ( target_dataslot_ack ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err ),
    .target_dataslot_id         ( target_dataslot_id ),
    .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
    .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
    .target_dataslot_length     ( target_dataslot_length ),

    .datatable_addr         ( datatable_addr ),
    .datatable_wren         ( 1'b0 ),
    .datatable_data         ( 32'd0 ),
    .datatable_q            ( datatable_q )
);

///////////////////////////////////////////////////////////////////////////////
// bridge windows (clk_74a), the slots of dist/Cores/*/data.json:
//   0x80000000 core settings, 0x80000004 memory-controller settings, 0x80000008 screen (bit 0: debug screen)
//   0x20000000 BIOS, 0x30000000 track table, 0x40000000 memory card (not declared until its store exists),
//   0x50000000 CD sector sink (target read)
reg [31:0] cfg;
reg [31:0] cfg_mem;
reg [31:0] cfg_screen = 32'd0;
always @(posedge clk_74a) begin
    if (bridge_wr) begin
        case (bridge_addr)
            32'h80000000: cfg     <= bridge_wr_data;
            32'h80000004: cfg_mem <= bridge_wr_data;
            32'h80000008: cfg_screen <= bridge_wr_data;
            default: ;
        endcase
    end
end

// status screen: bytes and word sum received by the BIOS window; a write at offset 0 starts a new load
reg [31:0] bios_bytes = 32'd0, bios_sum = 32'd0;
always @(posedge clk_74a) begin
    if (bridge_wr && bridge_addr[31:28] == 4'h2) begin
        bios_bytes <= (bridge_addr[27:0] == 28'd0) ? 32'd4 : bios_bytes + 32'd4;
        bios_sum   <= (bridge_addr[27:0] == 28'd0) ? bridge_wr_data : bios_sum + bridge_wr_data;
    end
end
reg [26:0] up_cnt = 27'd0;
reg [31:0] uptime_s = 32'd0;
always @(posedge clk_74a) begin
    up_cnt <= (up_cnt == 27'd74_249_999) ? 27'd0 : up_cnt + 1'b1;
    if (up_cnt == 27'd74_249_999) uptime_s <= uptime_s + 1'b1;
end

wire [31:0]  cfg_sys;
wire [191:0] pad_1x;
synch_3 #(.WIDTH(32))  s_cfgm (cfg_mem, cfg_sys, clk_sys);

// controllers: buttons [15:0] and sticks [31:0] of the four pads
synch_3 #(.WIDTH(192)) s_pad (
    {cont4_joy, cont4_key[15:0], cont3_joy, cont3_key[15:0], cont2_joy, cont2_key[15:0], cont1_joy, cont1_key[15:0]},
    pad_1x, clk1x);

// reset: held while the host holds the core in reset or the PLL is unlocked
wire run_n = reset_n & pll_core_locked_s;
wire run_1x, run_sys;
synch_3 s_run1 (run_n, run_1x, clk1x);
synch_3 s_runs (run_n, run_sys, clk_sys);
wire rst_1x = ~run_1x;
reg [4:0] rst_cnt = 5'd31;
always @(posedge clk_sys) begin
    if (!run_sys) rst_cnt <= 5'd31;
    else if (rst_cnt != 0) rst_cnt <= rst_cnt - 1'b1;
end
reg rst_sys;
always @(posedge clk_sys) rst_sys <= (rst_cnt != 0);
wire pll_locked_sys;
synch_3 s_pl (pll_core_locked, pll_locked_sys, clk_sys);

// SDRAM capture tracking window: one pulse per 16 frames at 59.94 Hz. The core's vertical blank replaces it.
localparam [25:0] CAL_PERIOD = 26'd36_162_880;
reg [25:0] cal_cnt = 26'd0;
reg        cal_tick;
always @(posedge clk_sys) begin
    cal_tick <= (cal_cnt == 26'd0);
    cal_cnt  <= (rst_sys || cal_cnt == 26'd0) ? CAL_PERIOD - 26'd1 : cal_cnt - 26'd1;
end

///////////////////////////////////////////////////////////////////////////////
// the PSX core, first-light configuration: no SPU, no CD, no MDEC

wire psx_reset;
wire psx_isPaused;
wire psx_pause;
wire psx_hps_busy;
wire psx_loadExe;
wire [31:0] psx_exe_initial_pc;
wire [31:0] psx_exe_initial_gp;
wire [31:0] psx_exe_load_address;
wire [31:0] psx_exe_file_size;
wire [31:0] psx_exe_stackpointer;
wire psx_fastboot;
wire psx_ram8mb;
wire psx_TURBO_MEM;
wire psx_TURBO_COMP;
wire psx_TURBO_CACHE;
wire psx_TURBO_CACHE50;
wire psx_REPRODUCIBLEGPUTIMING;
wire psx_INSTANTSEEK;
wire [2:0] psx_FORCECDSPEED;
wire psx_LIMITREADSPEED;
wire psx_IGNORECDDMATIMING;
wire psx_ditherOff;
wire psx_interlaced480pHack;
wire psx_showGunCrosshairs;
wire psx_enableNeGconRumble;
wire psx_fpscountOn;
wire psx_cdslowOn;
wire psx_testSeek;
wire psx_pauseOnCDSlow;
wire psx_errorOn;
wire psx_LBAOn;
wire psx_PATCHSERIAL;
wire psx_noTexture;
wire [1:0] psx_textureFilter;
wire [1:0] psx_textureFilterStrength;
wire psx_textureFilter2DOff;
wire psx_dither24;
wire psx_render24;
wire psx_drawSlow;
wire psx_syncVideoOut;
wire psx_syncInterlace;
wire psx_rotate180;
wire psx_fixedVBlank;
wire [1:0] psx_vCrop;
wire psx_hCrop;
wire psx_SPUon;
wire psx_SPUIRQTrigger;
wire psx_SPUSDRAM;
wire psx_REVERBOFF;
wire psx_REPRODUCIBLESPUDMA;
wire [1:0] psx_WIDESCREEN;
wire psx_oldGPU;
wire [1:0] psx_biosregion;
wire psx_ram_refresh;
wire [31:0] psx_ram_dataWrite;
wire [31:0] psx_ram_dataRead32;
wire [24:0] psx_ram_Adr;
wire [1:0] psx_ram_cntDMA;
wire [3:0] psx_ram_be;
wire psx_ram_rnw;
wire psx_ram_ena;
wire psx_ram_dma;
wire psx_ram_cache;
wire psx_ram_done;
wire [22:0] psx_ram_dmafifo_adr;
wire [31:0] psx_ram_dmafifo_data;
wire psx_ram_dmafifo_empty;
wire psx_ram_dmafifo_read;
wire [3:0] psx_cache_wr;
wire [31:0] psx_cache_data;
wire [7:0] psx_cache_addr;
wire psx_dma_wr;
wire psx_dma_reqprocessed;
wire [31:0] psx_dma_data;
wire psx_ddr3_BUSY;
wire [63:0] psx_ddr3_DOUT;
wire psx_ddr3_DOUT_READY;
wire [7:0] psx_ddr3_BURSTCNT;
wire [27:0] psx_ddr3_ADDR;
wire [63:0] psx_ddr3_DIN;
wire [7:0] psx_ddr3_BE;
wire psx_ddr3_WE;
wire psx_ddr3_RD;
wire [1:0] psx_region;
wire [1:0] psx_region_out;
wire psx_hasCD;
wire psx_fastCD;
wire psx_LIDopen;
wire [31:0] psx_trackinfo_data;
wire [8:0] psx_trackinfo_addr;
wire psx_trackinfo_write;
wire psx_resetFromCD;
wire psx_cd_hps_req;
wire [31:0] psx_cd_hps_lba;
wire [31:0] psx_cd_hps_lba_sim;
wire psx_cd_hps_ack;
wire psx_cd_hps_write;
wire [15:0] psx_cd_hps_data;
wire [31:0] psx_spuram_dataWrite;
wire [18:0] psx_spuram_Adr;
wire [3:0] psx_spuram_be;
wire psx_spuram_rnw;
wire psx_spuram_ena;
wire [31:0] psx_spuram_dataRead;
wire psx_spuram_done;
wire psx_memcard_changed;
wire psx_saving_memcard;
wire psx_memcard1_load;
wire psx_memcard2_load;
wire psx_memcard_save;
wire psx_memcard1_mounted;
wire psx_memcard1_available;
wire psx_memcard1_rd;
wire psx_memcard1_wr;
wire [6:0] psx_memcard1_lba;
wire psx_memcard1_ack;
wire psx_memcard1_write;
wire [8:0] psx_memcard1_addr;
wire [15:0] psx_memcard1_dataIn;
wire [15:0] psx_memcard1_dataOut;
wire psx_memcard2_mounted;
wire psx_memcard2_available;
wire psx_memcard2_rd;
wire psx_memcard2_wr;
wire [6:0] psx_memcard2_lba;
wire psx_memcard2_ack;
wire psx_memcard2_write;
wire [8:0] psx_memcard2_addr;
wire [15:0] psx_memcard2_dataIn;
wire [15:0] psx_memcard2_dataOut;
wire psx_videoout_on;
wire psx_isPal;
wire psx_pal60;
wire psx_hsync;
wire psx_vsync;
wire psx_hblank;
wire psx_vblank;
wire [10:0] psx_DisplayWidth;
wire [9:0] psx_DisplayHeight;
wire [9:0] psx_DisplayOffsetX;
wire [8:0] psx_DisplayOffsetY;
wire psx_video_ce;
wire psx_video_interlace;
wire [7:0] psx_video_r;
wire [7:0] psx_video_g;
wire [7:0] psx_video_b;
wire psx_video_isPal;
wire psx_video_fbmode;
wire psx_video_fb24;
wire [2:0] psx_video_hResMode;
wire [3:0] psx_video_frameindex;
wire psx_DSAltSwitchMode;
wire [59:0] psx_joypad1;
wire [59:0] psx_joypad2;
wire [59:0] psx_joypad3;
wire [59:0] psx_joypad4;
wire psx_multitap;
wire psx_multitapDigital;
wire psx_multitapAnalog;
wire psx_neGconRumble;
wire [15:0] psx_joypad1_rumble;
wire [15:0] psx_joypad2_rumble;
wire [15:0] psx_joypad3_rumble;
wire [15:0] psx_joypad4_rumble;
wire [1:0] psx_padMode;
wire psx_MouseEvent;
wire psx_MouseLeft;
wire psx_MouseRight;
wire [8:0] psx_MouseX;
wire [8:0] psx_MouseY;
wire psx_snacPort1;
wire psx_snacPort2;
wire psx_irq10Snac;
wire psx_actionNextSnac;
wire psx_receiveValidSnac;
wire psx_ackSnac;
wire psx_snacMC;
wire [7:0] psx_receiveBufferSnac;
wire [7:0] psx_transmitValueSnac;
wire psx_selectedPort1Snac;
wire psx_selectedPort2Snac;
wire psx_clk9Snac;
wire psx_beginTransferSnac;
wire [15:0] psx_sound_out_left;
wire [15:0] psx_sound_out_right;
wire psx_increaseSSHeaderCount;
wire psx_save_state;
wire psx_load_state;
wire [1:0] psx_savestate_number;
wire psx_state_loaded;
wire [3:0] psx_validSStates;
wire psx_rewind_on;
wire psx_rewind_active;
wire psx_cheat_clear;
wire psx_cheats_enabled;
wire psx_cheat_on;
wire [127:0] psx_cheat_in;
wire psx_cheats_active;
wire [20:0] psx_Cheats_BusAddr;
wire psx_Cheats_BusRnW;
wire [3:0] psx_Cheats_BusByteEnable;
wire [31:0] psx_Cheats_BusWriteData;
wire psx_Cheats_Bus_ena;
wire [31:0] psx_Cheats_BusReadData;
wire psx_Cheats_BusDone;

// pad 1 as a digital pad, Pocket A/B/X/Y on Circle/Cross/Triangle/Square (joypad_t order: psx_top_pocket_flat.vhd)
wire [15:0] pk = pad_1x[15:0];
wire [59:0] pad1_1x = {1'b1, 1'b1, 10'd0, pk[6], pk[4], pk[5], pk[7], pk[14], pk[15], pk[3], pk[2], pk[0], pk[1],
                       pk[9], pk[11], pk[13], pk[8], pk[10], pk[12], 32'd0};
wire core_go_1x;

// first light: the core's inputs (docs/pocket/POCKET_TOP.md, "First light"). Main RAM, VRAM and the pad come from the
// adapters below; everything without a Pocket source yet is held at its MiSTer default.
assign psx_reset = rst_1x | ~core_go_1x;
assign psx_pause = 1'b0;
assign psx_hps_busy = 1'b0;
assign psx_loadExe = 1'b0;
assign psx_exe_initial_pc = 32'd0;
assign psx_exe_initial_gp = 32'd0;
assign psx_exe_load_address = 32'd0;
assign psx_exe_file_size = 32'd0;
assign psx_exe_stackpointer = 32'd0;
assign psx_fastboot = 1'b0;
assign psx_ram8mb = 1'b0;
assign psx_TURBO_MEM = 1'b0;
assign psx_TURBO_COMP = 1'b0;
assign psx_TURBO_CACHE = 1'b0;
assign psx_TURBO_CACHE50 = 1'b0;
assign psx_REPRODUCIBLEGPUTIMING = 1'b0;
assign psx_INSTANTSEEK = 1'b0;
assign psx_FORCECDSPEED = 3'd0;
assign psx_LIMITREADSPEED = 1'b0;
assign psx_IGNORECDDMATIMING = 1'b0;
assign psx_ditherOff = 1'b0;
assign psx_interlaced480pHack = 1'b0;
assign psx_showGunCrosshairs = 1'b0;
assign psx_enableNeGconRumble = 1'b0;
assign psx_fpscountOn = 1'b0;
assign psx_cdslowOn = 1'b0;
assign psx_testSeek = 1'b0;
assign psx_pauseOnCDSlow = 1'b0;
assign psx_errorOn = 1'b0;
assign psx_LBAOn = 1'b0;
assign psx_PATCHSERIAL = 1'b0;
assign psx_noTexture = 1'b0;
assign psx_textureFilter = 2'd0;
assign psx_textureFilterStrength = 2'd0;
assign psx_textureFilter2DOff = 1'b0;
assign psx_dither24 = 1'b0;
assign psx_render24 = 1'b0;
assign psx_drawSlow = 1'b0;
assign psx_syncVideoOut = 1'b1;
assign psx_syncInterlace = 1'b0;
assign psx_rotate180 = 1'b0;
assign psx_fixedVBlank = 1'b0;
assign psx_vCrop = 2'd0;
assign psx_hCrop = 1'b0;
assign psx_SPUon = 1'b0;
assign psx_SPUIRQTrigger = 1'b0;
assign psx_SPUSDRAM = 1'b1;
assign psx_REVERBOFF = 1'b1;
assign psx_REPRODUCIBLESPUDMA = 1'b0;
assign psx_WIDESCREEN = 2'd0;
assign psx_oldGPU = 1'b0;
assign psx_biosregion = 2'd0;
assign psx_region = 2'd0;
assign psx_hasCD = 1'b0;
assign psx_fastCD = 1'b0;
assign psx_LIDopen = 1'b1;
assign psx_trackinfo_data = 32'd0;
assign psx_trackinfo_addr = 9'd0;
assign psx_trackinfo_write = 1'b0;
assign psx_cd_hps_ack = 1'b0;
assign psx_cd_hps_write = 1'b0;
assign psx_cd_hps_data = 16'd0;
assign psx_spuram_dataRead = 32'd0;
assign psx_spuram_done = 1'b0;
assign psx_memcard1_load = 1'b0;
assign psx_memcard2_load = 1'b0;
assign psx_memcard_save = 1'b0;
assign psx_memcard1_mounted = 1'b0;
assign psx_memcard1_available = 1'b0;
assign psx_memcard1_ack = 1'b0;
assign psx_memcard1_write = 1'b0;
assign psx_memcard1_addr = 9'd0;
assign psx_memcard1_dataIn = 16'd0;
assign psx_memcard2_mounted = 1'b0;
assign psx_memcard2_available = 1'b0;
assign psx_memcard2_ack = 1'b0;
assign psx_memcard2_write = 1'b0;
assign psx_memcard2_addr = 9'd0;
assign psx_memcard2_dataIn = 16'd0;
assign psx_videoout_on = 1'b1;
assign psx_isPal = 1'b0;
assign psx_pal60 = 1'b0;
assign psx_DSAltSwitchMode = 1'b0;
assign psx_joypad1 = pad1_1x;
assign psx_joypad2 = 60'd0;
assign psx_joypad3 = 60'd0;
assign psx_joypad4 = 60'd0;
assign psx_multitap = 1'b0;
assign psx_multitapDigital = 1'b0;
assign psx_multitapAnalog = 1'b0;
assign psx_neGconRumble = 1'b0;
assign psx_MouseEvent = 1'b0;
assign psx_MouseLeft = 1'b0;
assign psx_MouseRight = 1'b0;
assign psx_MouseX = 9'd0;
assign psx_MouseY = 9'd0;
assign psx_snacPort1 = 1'b0;
assign psx_snacPort2 = 1'b0;
assign psx_irq10Snac = 1'b0;
assign psx_actionNextSnac = 1'b0;
assign psx_receiveValidSnac = 1'b0;
assign psx_ackSnac = 1'b0;
assign psx_snacMC = 1'b0;
assign psx_receiveBufferSnac = 8'd0;
assign psx_increaseSSHeaderCount = 1'b0;
assign psx_save_state = 1'b0;
assign psx_load_state = 1'b0;
assign psx_savestate_number = 2'd0;
assign psx_rewind_on = 1'b0;
assign psx_rewind_active = 1'b0;
assign psx_cheat_clear = 1'b0;
assign psx_cheats_enabled = 1'b0;
assign psx_cheat_on = 1'b0;
assign psx_cheat_in = 128'd0;
assign psx_Cheats_BusReadData = 32'd0;
assign psx_Cheats_BusDone = 1'b0;


psx_top_pocket_flat #(.G_SPU_IMPL("none"), .G_CD_IMPL("none"), .NO_MDEC(1)) psx (
    .clk1x( clk1x ),
    .clk2x( clk2x ),
    .clk3x( clk3x ),
    .clkvid( clk2x ),                   // gpu_videoout reads its line RAM on clk2x in sync mode
    .reset( psx_reset ),
    .isPaused( psx_isPaused ),
    .pause( psx_pause ),
    .hps_busy( psx_hps_busy ),
    .loadExe( psx_loadExe ),
    .exe_initial_pc( psx_exe_initial_pc ),
    .exe_initial_gp( psx_exe_initial_gp ),
    .exe_load_address( psx_exe_load_address ),
    .exe_file_size( psx_exe_file_size ),
    .exe_stackpointer( psx_exe_stackpointer ),
    .fastboot( psx_fastboot ),
    .ram8mb( psx_ram8mb ),
    .TURBO_MEM( psx_TURBO_MEM ),
    .TURBO_COMP( psx_TURBO_COMP ),
    .TURBO_CACHE( psx_TURBO_CACHE ),
    .TURBO_CACHE50( psx_TURBO_CACHE50 ),
    .REPRODUCIBLEGPUTIMING( psx_REPRODUCIBLEGPUTIMING ),
    .INSTANTSEEK( psx_INSTANTSEEK ),
    .FORCECDSPEED( psx_FORCECDSPEED ),
    .LIMITREADSPEED( psx_LIMITREADSPEED ),
    .IGNORECDDMATIMING( psx_IGNORECDDMATIMING ),
    .ditherOff( psx_ditherOff ),
    .interlaced480pHack( psx_interlaced480pHack ),
    .showGunCrosshairs( psx_showGunCrosshairs ),
    .enableNeGconRumble( psx_enableNeGconRumble ),
    .fpscountOn( psx_fpscountOn ),
    .cdslowOn( psx_cdslowOn ),
    .testSeek( psx_testSeek ),
    .pauseOnCDSlow( psx_pauseOnCDSlow ),
    .errorOn( psx_errorOn ),
    .LBAOn( psx_LBAOn ),
    .PATCHSERIAL( psx_PATCHSERIAL ),
    .noTexture( psx_noTexture ),
    .textureFilter( psx_textureFilter ),
    .textureFilterStrength( psx_textureFilterStrength ),
    .textureFilter2DOff( psx_textureFilter2DOff ),
    .dither24( psx_dither24 ),
    .render24( psx_render24 ),
    .drawSlow( psx_drawSlow ),
    .syncVideoOut( psx_syncVideoOut ),
    .syncInterlace( psx_syncInterlace ),
    .rotate180( psx_rotate180 ),
    .fixedVBlank( psx_fixedVBlank ),
    .vCrop( psx_vCrop ),
    .hCrop( psx_hCrop ),
    .SPUon( psx_SPUon ),
    .SPUIRQTrigger( psx_SPUIRQTrigger ),
    .SPUSDRAM( psx_SPUSDRAM ),
    .REVERBOFF( psx_REVERBOFF ),
    .REPRODUCIBLESPUDMA( psx_REPRODUCIBLESPUDMA ),
    .WIDESCREEN( psx_WIDESCREEN ),
    .oldGPU( psx_oldGPU ),
    .biosregion( psx_biosregion ),
    .ram_refresh( psx_ram_refresh ),
    .ram_dataWrite( psx_ram_dataWrite ),
    .ram_dataRead32( psx_ram_dataRead32 ),
    .ram_Adr( psx_ram_Adr ),
    .ram_cntDMA( psx_ram_cntDMA ),
    .ram_be( psx_ram_be ),
    .ram_rnw( psx_ram_rnw ),
    .ram_ena( psx_ram_ena ),
    .ram_dma( psx_ram_dma ),
    .ram_cache( psx_ram_cache ),
    .ram_done( psx_ram_done ),
    .ram_dmafifo_adr( psx_ram_dmafifo_adr ),
    .ram_dmafifo_data( psx_ram_dmafifo_data ),
    .ram_dmafifo_empty( psx_ram_dmafifo_empty ),
    .ram_dmafifo_read( psx_ram_dmafifo_read ),
    .cache_wr( psx_cache_wr ),
    .cache_data( psx_cache_data ),
    .cache_addr( psx_cache_addr ),
    .dma_wr( psx_dma_wr ),
    .dma_reqprocessed( psx_dma_reqprocessed ),
    .dma_data( psx_dma_data ),
    .ddr3_BUSY( psx_ddr3_BUSY ),
    .ddr3_DOUT( psx_ddr3_DOUT ),
    .ddr3_DOUT_READY( psx_ddr3_DOUT_READY ),
    .ddr3_BURSTCNT( psx_ddr3_BURSTCNT ),
    .ddr3_ADDR( psx_ddr3_ADDR ),
    .ddr3_DIN( psx_ddr3_DIN ),
    .ddr3_BE( psx_ddr3_BE ),
    .ddr3_WE( psx_ddr3_WE ),
    .ddr3_RD( psx_ddr3_RD ),
    .region( psx_region ),
    .region_out( psx_region_out ),
    .hasCD( psx_hasCD ),
    .fastCD( psx_fastCD ),
    .LIDopen( psx_LIDopen ),
    .trackinfo_data( psx_trackinfo_data ),
    .trackinfo_addr( psx_trackinfo_addr ),
    .trackinfo_write( psx_trackinfo_write ),
    .resetFromCD( psx_resetFromCD ),
    .cd_hps_req( psx_cd_hps_req ),
    .cd_hps_lba( psx_cd_hps_lba ),
    .cd_hps_lba_sim( psx_cd_hps_lba_sim ),
    .cd_hps_ack( psx_cd_hps_ack ),
    .cd_hps_write( psx_cd_hps_write ),
    .cd_hps_data( psx_cd_hps_data ),
    .spuram_dataWrite( psx_spuram_dataWrite ),
    .spuram_Adr( psx_spuram_Adr ),
    .spuram_be( psx_spuram_be ),
    .spuram_rnw( psx_spuram_rnw ),
    .spuram_ena( psx_spuram_ena ),
    .spuram_dataRead( psx_spuram_dataRead ),
    .spuram_done( psx_spuram_done ),
    .memcard_changed( psx_memcard_changed ),
    .saving_memcard( psx_saving_memcard ),
    .memcard1_load( psx_memcard1_load ),
    .memcard2_load( psx_memcard2_load ),
    .memcard_save( psx_memcard_save ),
    .memcard1_mounted( psx_memcard1_mounted ),
    .memcard1_available( psx_memcard1_available ),
    .memcard1_rd( psx_memcard1_rd ),
    .memcard1_wr( psx_memcard1_wr ),
    .memcard1_lba( psx_memcard1_lba ),
    .memcard1_ack( psx_memcard1_ack ),
    .memcard1_write( psx_memcard1_write ),
    .memcard1_addr( psx_memcard1_addr ),
    .memcard1_dataIn( psx_memcard1_dataIn ),
    .memcard1_dataOut( psx_memcard1_dataOut ),
    .memcard2_mounted( psx_memcard2_mounted ),
    .memcard2_available( psx_memcard2_available ),
    .memcard2_rd( psx_memcard2_rd ),
    .memcard2_wr( psx_memcard2_wr ),
    .memcard2_lba( psx_memcard2_lba ),
    .memcard2_ack( psx_memcard2_ack ),
    .memcard2_write( psx_memcard2_write ),
    .memcard2_addr( psx_memcard2_addr ),
    .memcard2_dataIn( psx_memcard2_dataIn ),
    .memcard2_dataOut( psx_memcard2_dataOut ),
    .videoout_on( psx_videoout_on ),
    .isPal( psx_isPal ),
    .pal60( psx_pal60 ),
    .hsync( psx_hsync ),
    .vsync( psx_vsync ),
    .hblank( psx_hblank ),
    .vblank( psx_vblank ),
    .DisplayWidth( psx_DisplayWidth ),
    .DisplayHeight( psx_DisplayHeight ),
    .DisplayOffsetX( psx_DisplayOffsetX ),
    .DisplayOffsetY( psx_DisplayOffsetY ),
    .video_ce( psx_video_ce ),
    .video_interlace( psx_video_interlace ),
    .video_r( psx_video_r ),
    .video_g( psx_video_g ),
    .video_b( psx_video_b ),
    .video_isPal( psx_video_isPal ),
    .video_fbmode( psx_video_fbmode ),
    .video_fb24( psx_video_fb24 ),
    .video_hResMode( psx_video_hResMode ),
    .video_frameindex( psx_video_frameindex ),
    .DSAltSwitchMode( psx_DSAltSwitchMode ),
    .joypad1( psx_joypad1 ),
    .joypad2( psx_joypad2 ),
    .joypad3( psx_joypad3 ),
    .joypad4( psx_joypad4 ),
    .multitap( psx_multitap ),
    .multitapDigital( psx_multitapDigital ),
    .multitapAnalog( psx_multitapAnalog ),
    .neGconRumble( psx_neGconRumble ),
    .joypad1_rumble( psx_joypad1_rumble ),
    .joypad2_rumble( psx_joypad2_rumble ),
    .joypad3_rumble( psx_joypad3_rumble ),
    .joypad4_rumble( psx_joypad4_rumble ),
    .padMode( psx_padMode ),
    .MouseEvent( psx_MouseEvent ),
    .MouseLeft( psx_MouseLeft ),
    .MouseRight( psx_MouseRight ),
    .MouseX( psx_MouseX ),
    .MouseY( psx_MouseY ),
    .snacPort1( psx_snacPort1 ),
    .snacPort2( psx_snacPort2 ),
    .irq10Snac( psx_irq10Snac ),
    .actionNextSnac( psx_actionNextSnac ),
    .receiveValidSnac( psx_receiveValidSnac ),
    .ackSnac( psx_ackSnac ),
    .snacMC( psx_snacMC ),
    .receiveBufferSnac( psx_receiveBufferSnac ),
    .transmitValueSnac( psx_transmitValueSnac ),
    .selectedPort1Snac( psx_selectedPort1Snac ),
    .selectedPort2Snac( psx_selectedPort2Snac ),
    .clk9Snac( psx_clk9Snac ),
    .beginTransferSnac( psx_beginTransferSnac ),
    .sound_out_left( psx_sound_out_left ),
    .sound_out_right( psx_sound_out_right ),
    .increaseSSHeaderCount( psx_increaseSSHeaderCount ),
    .save_state( psx_save_state ),
    .load_state( psx_load_state ),
    .savestate_number( psx_savestate_number ),
    .state_loaded( psx_state_loaded ),
    .validSStates( psx_validSStates ),
    .rewind_on( psx_rewind_on ),
    .rewind_active( psx_rewind_active ),
    .cheat_clear( psx_cheat_clear ),
    .cheats_enabled( psx_cheats_enabled ),
    .cheat_on( psx_cheat_on ),
    .cheat_in( psx_cheat_in ),
    .cheats_active( psx_cheats_active ),
    .Cheats_BusAddr( psx_Cheats_BusAddr ),
    .Cheats_BusRnW( psx_Cheats_BusRnW ),
    .Cheats_BusByteEnable( psx_Cheats_BusByteEnable ),
    .Cheats_BusWriteData( psx_Cheats_BusWriteData ),
    .Cheats_Bus_ena( psx_Cheats_Bus_ena ),
    .Cheats_BusReadData( psx_Cheats_BusReadData ),
    .Cheats_BusDone( psx_Cheats_BusDone )
);

///////////////////////////////////////////////////////////////////////////////
// CD: not in the first-light build (G_CD_IMPL "none")
assign target_dataslot_read        = 1'b0;
assign target_dataslot_id          = 16'd0;
assign target_dataslot_slotoffset  = 32'd0;
assign target_dataslot_bridgeaddr  = 32'd0;
assign target_dataslot_length      = 32'd0;
assign datatable_addr              = 10'd0;

///////////////////////////////////////////////////////////////////////////////
// memory: VRAM on the SDRAM, main RAM and the BIOS on the PSRAM, SRAM unused (docs/pocket/POCKET_TOP.md, "First light")
wire         sd_init_done;
wire         cal_done, cal_ok;
wire [6:0]   cal_width, cal_boot, cal_centre, cal_min, cal_max;
wire [15:0]  cal_moves;
wire [3:0]   cal_flags;
wire         c_valid, c_ready, c_we, c_tag, c_rvalid, c_rtag;
wire [24:0]  c_addr;
wire [63:0]  c_wdata, c_rdata;
wire [7:0]   c_be;
wire [15:0]  vram_rd_2x, vram_wr_2x;

vram_adapter vad (
    .clk2x(clk2x), .clk_sys(clk_sys), .init_done(sd_init_done),
    .ddr3_RD(psx_ddr3_RD), .ddr3_WE(psx_ddr3_WE), .ddr3_ADDR(psx_ddr3_ADDR), .ddr3_DIN(psx_ddr3_DIN), .ddr3_BE(psx_ddr3_BE),
    .ddr3_BURSTCNT(psx_ddr3_BURSTCNT), .ddr3_BUSY(psx_ddr3_BUSY), .ddr3_DOUT(psx_ddr3_DOUT), .ddr3_DOUT_READY(psx_ddr3_DOUT_READY),
    .req_valid(c_valid), .req_ready(c_ready), .req_we(c_we), .req_addr(c_addr), .req_wdata(c_wdata), .req_be(c_be),
    .rd_valid(c_rvalid), .rd_data(c_rdata),
    .dbg_reads(vram_rd_2x), .dbg_writes(vram_wr_2x)
);

assign c_tag = 1'b0;

sdram_ctl sdc (
    .clk(clk_sys), .clk_cap(clk_cap), .rst(rst_sys), .init_done(sd_init_done),
    .pll_locked(pll_locked_sys), .cal_tick(cal_tick), .clk_scan(clk1x), .ps_en(ps_en), .ps_up(ps_up), .ps_done(ps_done),
    .cal_done(cal_done), .cal_ok(cal_ok), .cal_width(cal_width), .cal_boot(cal_boot), .cal_centre(cal_centre),
    .cal_min(cal_min), .cal_max(cal_max), .cal_moves(cal_moves), .cal_flags(cal_flags),
    .req_valid(c_valid), .req_ready(c_ready), .req_we(c_we), .req_addr(c_addr),
    .req_wdata(c_wdata), .req_be(c_be), .req_tag(c_tag),
    .rd_valid(c_rvalid), .rd_data(c_rdata), .rd_tag(c_rtag),
    .dram_a(dram_a), .dram_ba(dram_ba), .dram_dq(dram_dq), .dram_dqm(dram_dqm),
    .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_we_n(dram_we_n)
);

assign dram_cke = 1'b1;
sd_clk_out sdclk (.clk(clk_sd), .pin(dram_clk));

// BIOS slot (bridge window 0x20000000) into PSRAM; the core is released once the SDRAM is calibrated and the BIOS is in.
// The loader and the RAM adapter reset on PLL lock only: the host may load the slot while it holds reset_n low.
reg [7:0] mrst_cnt = 8'hFF;
reg       rst_mem = 1'b1;
always @(posedge clk_sys) begin
    if (!pll_locked_sys) mrst_cnt <= 8'hFF; else if (mrst_cnt != 8'd0) mrst_cnt <= mrst_cnt - 1'b1;
    rst_mem <= (mrst_cnt != 8'd0);
end
wire         ld_valid, ld_ready;
wire [22:0]  ld_addr;
wire [31:0]  ld_data;
wire [17:0]  bios_words;
wire         bios_err;
bios_loader bld (
    .clk_74a(clk_74a), .bridge_wr(bridge_wr), .bridge_addr(bridge_addr), .bridge_wr_data(bridge_wr_data),
    .clk_sys(clk_sys), .rst(rst_mem),
    .ld_valid(ld_valid), .ld_ready(ld_ready), .ld_addr(ld_addr), .ld_data(ld_data),
    .words(bios_words), .err(bios_err)
);
reg core_go_sys = 1'b0;
always @(posedge clk_sys) core_go_sys <= sd_init_done & (bios_words == 18'd131072);
synch_3 s_go (core_go_sys, core_go_1x, clk1x);

wire         pc_valid, pc_ready, pc_we, pr_valid, pr_done;
wire [22:0]  pc_addr;
wire [4:0]   pc_len;
wire [31:0]  pc_wdata, pr_data;
wire [3:0]   pc_be;
wire [15:0]  ram_req_1x, ram_fill_1x, ram_dmaw_1x;
ram_adapter rad (
    .clk1x(clk1x), .clk3x(clk3x), .clk_sys(clk_sys), .rst(rst_mem),
    .ram_ena(psx_ram_ena), .ram_rnw(psx_ram_rnw), .ram_Adr(psx_ram_Adr), .ram_dataWrite(psx_ram_dataWrite), .ram_be(psx_ram_be),
    .ram_dma(psx_ram_dma), .ram_cache(psx_ram_cache), .ram_cntDMA(psx_ram_cntDMA),
    .ram_done(psx_ram_done), .ram_dataRead32(psx_ram_dataRead32),
    .dma_wr(psx_dma_wr), .dma_data(psx_dma_data), .dma_reqprocessed(psx_dma_reqprocessed),
    .cache_wr(psx_cache_wr), .cache_data(psx_cache_data), .cache_addr(psx_cache_addr),
    .ram_dmafifo_empty(psx_ram_dmafifo_empty), .ram_dmafifo_adr(psx_ram_dmafifo_adr), .ram_dmafifo_data(psx_ram_dmafifo_data),
    .ram_dmafifo_read(psx_ram_dmafifo_read),
    .ld_valid(ld_valid), .ld_ready(ld_ready), .ld_addr(ld_addr), .ld_data(ld_data),
    .cmd_valid(pc_valid), .cmd_ready(pc_ready), .cmd_we(pc_we), .cmd_addr(pc_addr), .cmd_len(pc_len),
    .cmd_wdata(pc_wdata), .cmd_be(pc_be), .rd_valid(pr_valid), .rd_data(pr_data), .done(pr_done),
    .dbg_req(ram_req_1x), .dbg_fill(ram_fill_1x), .dbg_dmaw(ram_dmaw_1x)
);

// PSRAM: both chips ganged as one 32-bit memory, shared control; asynchronous reads with the memtest's 88.5 ns wait unless
// the memory-controller settings word (0x80000004) sets one
wire [21:16] cram_a;
wire         cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n, cram_oe_n, cram_we_n;
wire         cram0_ub, cram0_lb, cram1_ub, cram1_lb;
wire [4:0]   ps_wait = (cfg_sys[5:1] == 5'd0) ? 5'd12 : cfg_sys[5:1];

psram32 ps (
    .clk(clk_sys), .rst(rst_sys),
    .cmd_valid(pc_valid), .cmd_ready(pc_ready), .cmd_we(pc_we), .cmd_cfg(1'b0), .cmd_addr(pc_addr),
    .cmd_len(pc_len), .cmd_wdata(pc_wdata), .cmd_be(pc_be),
    .sync_mode(1'b0), .rd_wait(ps_wait), .sync_lc(3'd3), .sync_phase(2'd2),
    .rd_valid(pr_valid), .rd_data(pr_data), .done(pr_done),
    .cram_a(cram_a), .cram0_dq(cram0_dq), .cram1_dq(cram1_dq), .cram_clk(cram_clk),
    .cram_adv_n(cram_adv_n), .cram_cre(cram_cre), .cram_ce0_n(cram_ce0_n), .cram_ce1_n(cram_ce1_n),
    .cram_oe_n(cram_oe_n), .cram_we_n(cram_we_n),
    .cram0_ub_n(cram0_ub), .cram0_lb_n(cram0_lb), .cram1_ub_n(cram1_ub), .cram1_lb_n(cram1_lb)
);
assign cram0_a = cram_a;      assign cram1_a = cram_a;
assign cram0_clk = cram_clk;  assign cram1_clk = cram_clk;
assign cram0_adv_n = cram_adv_n; assign cram1_adv_n = cram_adv_n;
assign cram0_cre = cram_cre;  assign cram1_cre = cram_cre;
assign cram0_ce0_n = cram_ce0_n; assign cram1_ce0_n = cram_ce0_n;
assign cram0_ce1_n = cram_ce1_n; assign cram1_ce1_n = cram_ce1_n;
assign cram0_oe_n = cram_oe_n; assign cram1_oe_n = cram_oe_n;
assign cram0_we_n = cram_we_n; assign cram1_we_n = cram_we_n;
assign cram0_ub_n = cram0_ub; assign cram0_lb_n = cram0_lb;
assign cram1_ub_n = cram1_ub; assign cram1_lb_n = cram1_lb;

// SRAM: idle until the memory-card store uses it
assign sram_a    = 17'd0;
assign sram_dq   = 16'hZZZZ;
assign sram_oe_n = 1'b1;
assign sram_we_n = 1'b1;
assign sram_ub_n = 1'b1;
assign sram_lb_n = 1'b1;

///////////////////////////////////////////////////////////////////////////////
// bridge reads: command handler and the SDRAM calibration status
// SDRAM calibration status, read-only words at 0x80000100 + 4*i (quasi-static, crossed without a handshake):
//   0: [0] init_done [1] cal_done [2] cal_ok [3] PLL locked [7:4] cal_flags
//   1: [6:0] cal_width [14:8] cal_boot [22:16] cal_centre    2: [6:0] cal_min [14:8] cal_max
//   3: [15:0] cal_moves                                       4: [15:0] tracking windows started
reg [15:0] cal_ticks;
always @(posedge clk_sys) if (cal_tick && !rst_sys) cal_ticks <= cal_ticks + 16'd1; else if (rst_sys) cal_ticks <= 16'd0;
wire [159:0] cal_st_sys = {16'd0, cal_ticks, 16'd0, cal_moves, 17'd0, cal_max, 1'b0, cal_min, 9'd0, cal_centre, 1'b0, cal_boot, 1'b0, cal_width,
                           24'd0, cal_flags, pll_locked_sys, cal_ok, cal_done, sd_init_done};
wire [159:0] cal_st;
synch_3 #(.WIDTH(160)) s_cal (cal_st_sys, cal_st, clk_74a);

always @(*) begin
    casex (bridge_addr)
    32'h800001xx: bridge_rd_data <= (bridge_addr[7:2] < 6'd5) ? cal_st[{bridge_addr[4:2], 5'd0} +: 32] : 32'd0;
    32'hF8xxxxxx: bridge_rd_data <= cmd_bridge_rd_data;
    default:      bridge_rd_data <= 0;
    endcase
end

///////////////////////////////////////////////////////////////////////////////
// video (clk_vid): the GPU's picture, or the debug screen (setting 0x80000008 bit 0)
wire [23:0] fl_rgb;
wire        fl_de, fl_hs, fl_vs;
video_fl vfl (
    .clk(clk_vid), .r(psx_video_r), .g(psx_video_g), .b(psx_video_b), .hblank(psx_hblank), .vblank(psx_vblank), .hsync(psx_hsync),
    .rgb(fl_rgb), .de(fl_de), .hs(fl_hs), .vs(fl_vs)
);
reg [15:0] frames_vid = 16'd0;
always @(posedge clk_vid) if (fl_vs) frames_vid <= frames_vid + 1'b1;

// debug counters to clk_74a (they move: a value may be read mid-change, the screen rewrites it continuously)
wire [15:0] ram_req_74, ram_fill_74, ram_dmaw_74, vram_rd_74, vram_wr_74, frames_74;
wire        core_run_74;
synch_3 #(.WIDTH(48)) s_dbg1 ({ram_req_1x, ram_fill_1x, ram_dmaw_1x}, {ram_req_74, ram_fill_74, ram_dmaw_74}, clk_74a);
synch_3 #(.WIDTH(32)) s_dbg2 ({vram_rd_2x, vram_wr_2x}, {vram_rd_74, vram_wr_74}, clk_74a);
synch_3 #(.WIDTH(16)) s_dbg3 (frames_vid, frames_74, clk_74a);
synch_3               s_dbg4 (core_go_1x & ~rst_1x, core_run_74, clk_74a);

wire        tx_we;
wire [9:0]  tx_wa;
wire [8:0]  tx_wd;
status_fmt sfmt (
    .clk(clk_74a), .cal_st(cal_st), .uptime_s(uptime_s), .bios_bytes(bios_bytes), .bios_sum(bios_sum),
    .pad_keys(cont1_key[15:0]), .pad_joy(cont1_joy), .core_run(core_run_74),
    .ram_req(ram_req_74), .ram_fill(ram_fill_74), .ram_dmaw(ram_dmaw_74),
    .vram_rd(vram_rd_74), .vram_wr(vram_wr_74), .frames(frames_74),
    .tx_we(tx_we), .tx_wa(tx_wa), .tx_wd(tx_wd)
);

wire [23:0] st_rgb;
wire        st_de, st_hs, st_vs;
status_screen sscr (
    .clk_s(clk_74a), .tx_we(tx_we), .tx_wa(tx_wa), .tx_wd(tx_wd),
    .clk_v(clk_vid), .reset_n(reset_n), .box_rgb(fl_rgb),
    .rgb(st_rgb), .de(st_de), .hs(st_hs), .vs(st_vs)
);

wire debug_vid;
synch_3 s_dbgv (cfg_screen[0], debug_vid, clk_vid);
wire [23:0] vid_rgb = debug_vid ? st_rgb : fl_rgb;
wire        vid_de  = debug_vid ? st_de  : fl_de;
wire        vid_hs  = debug_vid ? st_hs  : fl_hs;
wire        vid_vs  = debug_vid ? st_vs  : fl_vs;

assign video_rgb_clock    = clk_vid;
assign video_rgb_clock_90 = clk_vid_90;
assign video_rgb          = vid_rgb;
assign video_de           = vid_de;
assign video_skip         = 1'b0;
assign video_vs           = vid_vs;
assign video_hs           = vid_hs;

//
// audio i2s: the stub's samples are crossed to clk_74a and shifted out; mclk and lrck as in the silence generator
//
wire [31:0] snd_74;
synch_3 #(.WIDTH(32)) s_snd ({psx_sound_out_left, psx_sound_out_right}, snd_74, clk_74a);

assign audio_mclk = audgen_mclk;
assign audio_dac = audgen_dac;
assign audio_lrck = audgen_lrck;

// generate MCLK = 12.288mhz with fractional accumulator
    reg         [21:0]  audgen_accum;
    reg                 audgen_mclk;
    parameter   [20:0]  CYCLE_48KHZ = 21'd122880 * 2;
always @(posedge clk_74a) begin
    audgen_accum <= audgen_accum + CYCLE_48KHZ;
    if(audgen_accum >= 21'd742500) begin
        audgen_mclk <= ~audgen_mclk;
        audgen_accum <= audgen_accum - 21'd742500 + CYCLE_48KHZ;
    end
end

// generate SCLK = 3.072mhz by dividing MCLK by 4
    reg [1:0]   aud_mclk_divider;
    wire        audgen_sclk = aud_mclk_divider[1] /* synthesis keep*/;
always @(posedge audgen_mclk) begin
    aud_mclk_divider <= aud_mclk_divider + 1'b1;
end

// shift out audio data as I2S, 32 bits per channel
    reg     [4:0]   audgen_lrck_cnt;
    reg             audgen_lrck;
    reg             audgen_dac;
always @(negedge audgen_sclk) begin
    audgen_dac <= snd_74[~audgen_lrck_cnt];
    audgen_lrck_cnt <= audgen_lrck_cnt + 1'b1;
    if(audgen_lrck_cnt == 31) begin
        audgen_lrck <= ~audgen_lrck;
    end
end

endmodule
