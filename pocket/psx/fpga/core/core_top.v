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
//   0x80000000 core settings, 0x80000004 memory-controller settings
//   0x20000000 BIOS, 0x30000000 track table, 0x40000000 memory card (not declared until its store exists),
//   0x50000000 CD sector sink (target read)
// Every write to a slot window is held in one register and crossed to clk1x: placeholder for the slot stores.
reg [31:0] cfg;
reg [31:0] cfg_mem;
reg [31:0] win_data;
reg [25:0] win_addr;
reg        win_tog;
always @(posedge clk_74a) begin
    if (bridge_wr) begin
        case (bridge_addr)
            32'h80000000: cfg     <= bridge_wr_data;
            32'h80000004: cfg_mem <= bridge_wr_data;
            default: ;
        endcase
        if (bridge_addr[31:30] == 2'b00 && bridge_addr[29:28] != 2'b00) begin
            win_data <= bridge_wr_data;
            win_addr <= bridge_addr[27:2];
            win_tog  <= ~win_tog;
        end
    end
end

wire [31:0]  cfg_1x;
wire [31:0]  cfg_sys;
wire [31:0]  win_data_1x;
wire [25:0]  win_addr_1x;
wire         win_tog_1x;
wire [191:0] pad_1x;
synch_3 #(.WIDTH(32))  s_cfg  (cfg, cfg_1x, clk1x);
synch_3 #(.WIDTH(32))  s_cfgm (cfg_mem, cfg_sys, clk_sys);
synch_3 #(.WIDTH(32))  s_wd   (win_data, win_data_1x, clk1x);
synch_3 #(.WIDTH(26))  s_wa   (win_addr, win_addr_1x, clk1x);
synch_3                s_wt   (win_tog, win_tog_1x, clk1x);
reg win_tog_1x_d;
always @(posedge clk1x) win_tog_1x_d <= win_tog_1x;
wire win_wr_1x = win_tog_1x ^ win_tog_1x_d;

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
// the PSX core (stub until the VHDL entity replaces it)
wire         cd_ack_1x;
wire         g_ddr3_busy;
wire [63:0]  g_ddr3_dout;
wire         g_ddr3_dout_ready;
wire [31:0]  g_ram_data_read;
wire         g_ram_done;
wire [31:0]  g_spuram_data_read;
wire         g_spuram_done;
wire         g_memcard1_ack;
wire [15:0]  g_memcard1_data_in;

wire [281:0] pool_1x = {cfg_1x, win_data_1x, win_addr_1x, pad_1x};
wire [95:0]  pool_3x = {g_ddr3_dout, g_ram_data_read};

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

assign psx_reset = rst_1x;
assign psx_pause = pool_1x[0:0];
assign psx_hps_busy = pool_1x[1:1];
assign psx_loadExe = pool_1x[2:2];
assign psx_exe_initial_pc = pool_1x[34:3];
assign psx_exe_initial_gp = pool_1x[66:35];
assign psx_exe_load_address = pool_1x[98:67];
assign psx_exe_file_size = pool_1x[130:99];
assign psx_exe_stackpointer = pool_1x[162:131];
assign psx_fastboot = pool_1x[163:163];
assign psx_ram8mb = pool_1x[164:164];
assign psx_TURBO_MEM = pool_1x[165:165];
assign psx_TURBO_COMP = pool_1x[166:166];
assign psx_TURBO_CACHE = pool_1x[167:167];
assign psx_TURBO_CACHE50 = pool_1x[168:168];
assign psx_REPRODUCIBLEGPUTIMING = pool_1x[169:169];
assign psx_INSTANTSEEK = pool_1x[170:170];
assign psx_FORCECDSPEED = pool_1x[173:171];
assign psx_LIMITREADSPEED = pool_1x[174:174];
assign psx_IGNORECDDMATIMING = pool_1x[175:175];
assign psx_ditherOff = pool_1x[176:176];
assign psx_interlaced480pHack = pool_1x[177:177];
assign psx_showGunCrosshairs = pool_1x[178:178];
assign psx_enableNeGconRumble = pool_1x[179:179];
assign psx_fpscountOn = pool_1x[180:180];
assign psx_cdslowOn = pool_1x[181:181];
assign psx_testSeek = pool_1x[182:182];
assign psx_pauseOnCDSlow = pool_1x[183:183];
assign psx_errorOn = pool_1x[184:184];
assign psx_LBAOn = pool_1x[185:185];
assign psx_PATCHSERIAL = pool_1x[186:186];
assign psx_noTexture = pool_1x[187:187];
assign psx_textureFilter = pool_1x[189:188];
assign psx_textureFilterStrength = pool_1x[191:190];
assign psx_textureFilter2DOff = pool_1x[192:192];
assign psx_dither24 = pool_1x[193:193];
assign psx_render24 = pool_1x[194:194];
assign psx_drawSlow = pool_1x[195:195];
assign psx_syncVideoOut = pool_1x[196:196];
assign psx_syncInterlace = pool_1x[197:197];
assign psx_rotate180 = pool_1x[198:198];
assign psx_fixedVBlank = pool_1x[199:199];
assign psx_vCrop = pool_1x[201:200];
assign psx_hCrop = pool_1x[202:202];
assign psx_SPUon = pool_1x[203:203];
assign psx_SPUIRQTrigger = pool_1x[204:204];
assign psx_SPUSDRAM = pool_1x[205:205];
assign psx_REVERBOFF = pool_1x[206:206];
assign psx_REPRODUCIBLESPUDMA = pool_1x[207:207];
assign psx_WIDESCREEN = pool_1x[209:208];
assign psx_oldGPU = pool_1x[210:210];
assign psx_biosregion = pool_1x[212:211];
assign psx_ram_dataRead32 = g_ram_data_read;
assign psx_ram_done = g_ram_done;
assign psx_ram_dmafifo_read = pool_3x[0:0];
assign psx_cache_wr = pool_3x[4:1];
assign psx_cache_data = pool_3x[36:5];
assign psx_cache_addr = pool_3x[44:37];
assign psx_dma_wr = pool_3x[45:45];
assign psx_dma_reqprocessed = pool_3x[46:46];
assign psx_dma_data = pool_3x[78:47];
assign psx_ddr3_BUSY = g_ddr3_busy;
assign psx_ddr3_DOUT = g_ddr3_dout;
assign psx_ddr3_DOUT_READY = g_ddr3_dout_ready;
assign psx_region = pool_1x[214:213];
assign psx_hasCD = pool_1x[215:215];
assign psx_fastCD = pool_1x[216:216];
assign psx_LIDopen = pool_1x[217:217];
assign psx_trackinfo_data = win_data_1x;
assign psx_trackinfo_addr = win_addr_1x[8:0];
assign psx_trackinfo_write = win_wr_1x;
assign psx_cd_hps_ack = cd_ack_1x;
assign psx_cd_hps_write = win_wr_1x;
assign psx_cd_hps_data = win_data_1x[15:0];
assign psx_spuram_dataRead = g_spuram_data_read;
assign psx_spuram_done = g_spuram_done;
assign psx_memcard1_load = pool_1x[218:218];
assign psx_memcard2_load = pool_1x[219:219];
assign psx_memcard_save = pool_1x[220:220];
assign psx_memcard1_mounted = pool_1x[221:221];
assign psx_memcard1_available = pool_1x[222:222];
assign psx_memcard1_ack = g_memcard1_ack;
assign psx_memcard1_write = pool_1x[223:223];
assign psx_memcard1_addr = pool_1x[232:224];
assign psx_memcard1_dataIn = g_memcard1_data_in;
assign psx_memcard2_mounted = pool_1x[233:233];
assign psx_memcard2_available = pool_1x[234:234];
assign psx_memcard2_ack = pool_1x[235:235];
assign psx_memcard2_write = pool_1x[236:236];
assign psx_memcard2_addr = pool_1x[245:237];
assign psx_memcard2_dataIn = pool_1x[261:246];
assign psx_videoout_on = pool_1x[262:262];
assign psx_isPal = pool_1x[263:263];
assign psx_pal60 = pool_1x[264:264];
assign psx_DSAltSwitchMode = pool_1x[265:265];
assign psx_joypad1 = {cfg_1x[11:0], pad_1x[47:0]};
assign psx_joypad2 = {cfg_1x[23:12], pad_1x[95:48]};
assign psx_joypad3 = {cfg_1x[11:0] ^ cfg_1x[23:12], pad_1x[143:96]};
assign psx_joypad4 = {cfg_1x[31:20], pad_1x[191:144]};
assign psx_multitap = pool_1x[266:266];
assign psx_multitapDigital = pool_1x[267:267];
assign psx_multitapAnalog = pool_1x[268:268];
assign psx_neGconRumble = pool_1x[269:269];
assign psx_MouseEvent = pool_1x[270:270];
assign psx_MouseLeft = pool_1x[271:271];
assign psx_MouseRight = pool_1x[272:272];
assign psx_MouseX = pool_1x[281:273];
assign psx_MouseY = pool_1x[8:0];
assign psx_snacPort1 = pool_1x[9:9];
assign psx_snacPort2 = pool_1x[10:10];
assign psx_irq10Snac = pool_1x[11:11];
assign psx_actionNextSnac = pool_1x[12:12];
assign psx_receiveValidSnac = pool_1x[13:13];
assign psx_ackSnac = pool_1x[14:14];
assign psx_snacMC = pool_1x[15:15];
assign psx_receiveBufferSnac = pool_1x[23:16];
assign psx_increaseSSHeaderCount = pool_1x[24:24];
assign psx_save_state = pool_1x[25:25];
assign psx_load_state = pool_1x[26:26];
assign psx_savestate_number = pool_1x[28:27];
assign psx_rewind_on = pool_1x[29:29];
assign psx_rewind_active = pool_1x[30:30];
assign psx_cheat_clear = pool_1x[31:31];
assign psx_cheats_enabled = pool_1x[32:32];
assign psx_cheat_on = pool_1x[33:33];
assign psx_cheat_in = pool_1x[161:34];
assign psx_Cheats_BusReadData = {pool_3x[14:0], pool_3x[95:79]};
assign psx_Cheats_BusDone = pool_3x[15:15];

wire left_1x_i = ^{psx_isPaused, psx_region_out, psx_resetFromCD, psx_cd_hps_lba_sim, psx_memcard_changed, psx_saving_memcard, psx_memcard2_rd, psx_memcard2_wr, psx_memcard2_lba, psx_memcard2_dataOut, psx_joypad1_rumble, psx_joypad2_rumble, psx_joypad3_rumble, psx_joypad4_rumble, psx_padMode, psx_transmitValueSnac, psx_selectedPort1Snac, psx_selectedPort2Snac, psx_clk9Snac, psx_beginTransferSnac, psx_state_loaded, psx_validSStates, psx_cheats_active};
wire left_2x_i = ^{psx_spuram_dataWrite, psx_spuram_be, psx_spuram_rnw};
wire left_3x_i = ^{psx_ram_refresh, psx_ram_cntDMA, psx_ram_dma, psx_ram_cache, psx_ram_dmafifo_adr, psx_ram_dmafifo_data, psx_ram_dmafifo_empty, psx_ddr3_BURSTCNT, psx_Cheats_BusAddr, psx_Cheats_BusRnW, psx_Cheats_BusByteEnable, psx_Cheats_BusWriteData, psx_Cheats_Bus_ena};
wire left_vid_i = ^{psx_DisplayWidth, psx_DisplayHeight, psx_DisplayOffsetX, psx_DisplayOffsetY, psx_video_ce, psx_video_interlace, psx_video_isPal, psx_video_fbmode, psx_video_fb24, psx_video_hResMode, psx_video_frameindex};

psx_top_pocket_flat stub (
    .clk1x( clk1x ),
    .clk2x( clk2x ),
    .clk3x( clk3x ),
    .clkvid( clk_vid ),
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
// CD sector requests: the stub's cd_hps_req/lba become a target read of slot 1 into window 0x50000000
wire        cd_req_74;
wire [31:0] cd_lba_74;
synch_3                cd_s_req (psx_cd_hps_req, cd_req_74, clk_74a);
synch_3 #(.WIDTH(32))  cd_s_lba (psx_cd_hps_lba, cd_lba_74, clk_74a);
assign target_dataslot_read        = cd_req_74;
assign target_dataslot_id          = 16'd1;
assign target_dataslot_slotoffset  = {cd_lba_74[20:0], 11'd0};
assign target_dataslot_bridgeaddr  = 32'h50000000;
assign target_dataslot_length      = 32'd2048;
synch_3 cd_s_ack (target_dataslot_done | target_dataslot_ack, cd_ack_1x, clk1x);

assign datatable_addr = cd_lba_74[9:0];


///////////////////////////////////////////////////////////////////////////////
// shared controllers (clk_sys) behind the placeholder glue
reg left_1x, left_2x, left_3x, left_vid;
always @(posedge clk1x)  left_1x  <= left_1x_i;
always @(posedge clk2x)  left_2x  <= left_2x_i;
always @(posedge clk3x)  left_3x  <= left_3x_i;
always @(posedge clk_vid) left_vid <= left_vid_i;
wire [3:0] left_s;
synch_3 s_l1 (left_1x,  left_s[0], clk_sys);
synch_3 s_l2 (left_2x,  left_s[1], clk_sys);
synch_3 s_l3 (left_3x,  left_s[2], clk_sys);
synch_3 s_lv (left_vid, left_s[3], clk_sys);

wire         a_valid, a_ready, a_we, b_valid, b_ready, a_rvalid, b_rvalid;
wire [24:0]  a_addr, b_addr;
wire [63:0]  a_wdata, r_data;
wire [7:0]   a_be;
wire         pc_valid, pc_ready, pc_we, pc_cfg, pr_valid, pr_done;
wire [22:0]  pc_addr;
wire [31:0]  pc_wdata, pr_data;
wire [3:0]   pc_be;
wire         sr_start, sr_we, sr_busy, sr_done;
wire [17:0]  sr_addr;
wire [7:0]   sr_wdata, sr_rdata;
wire         sd_init_done;
wire         cal_done, cal_ok;
wire [6:0]   cal_width, cal_boot, cal_centre, cal_min, cal_max;
wire [15:0]  cal_moves;
wire [3:0]   cal_flags;

mem_glue_placeholder glue (
    .clk_sys ( clk_sys ), .clk3x ( clk3x ), .clk2x ( clk2x ), .clk1x ( clk1x ),
    .ram_ena ( psx_ram_ena ), .ram_rnw ( psx_ram_rnw ), .ram_Adr ( psx_ram_Adr ),
    .ram_dataWrite ( psx_ram_dataWrite ), .ram_be ( psx_ram_be ),
    .ddr3_WE ( psx_ddr3_WE ), .ddr3_RD ( psx_ddr3_RD ), .ddr3_ADDR ( psx_ddr3_ADDR ),
    .ddr3_DIN ( psx_ddr3_DIN ), .ddr3_BE ( psx_ddr3_BE ),
    .spuram_ena ( psx_spuram_ena ), .spuram_Adr ( psx_spuram_Adr ),
    .memcard1_rd ( psx_memcard1_rd ), .memcard1_wr ( psx_memcard1_wr ),
    .memcard1_lba ( psx_memcard1_lba ), .memcard1_dataOut ( psx_memcard1_dataOut ),
    .left_s ( left_s ),
    .g_ddr3_busy ( g_ddr3_busy ), .g_ddr3_dout ( g_ddr3_dout ), .g_ddr3_dout_ready ( g_ddr3_dout_ready ),
    .g_ram_data_read ( g_ram_data_read ), .g_ram_done ( g_ram_done ),
    .g_spuram_data_read ( g_spuram_data_read ), .g_spuram_done ( g_spuram_done ),
    .g_memcard1_ack ( g_memcard1_ack ), .g_memcard1_data_in ( g_memcard1_data_in ),
    .a_valid ( a_valid ), .a_ready ( a_ready ), .a_we ( a_we ), .a_addr ( a_addr ),
    .a_wdata ( a_wdata ), .a_be ( a_be ),
    .b_valid ( b_valid ), .b_ready ( b_ready ), .b_addr ( b_addr ),
    .a_rvalid ( a_rvalid ), .b_rvalid ( b_rvalid ), .r_data ( r_data ), .sd_init_done ( sd_init_done ),
    .pc_valid ( pc_valid ), .pc_ready ( pc_ready ), .pc_we ( pc_we ), .pc_cfg ( pc_cfg ),
    .pc_addr ( pc_addr ), .pc_wdata ( pc_wdata ), .pc_be ( pc_be ),
    .pr_valid ( pr_valid ), .pr_data ( pr_data ), .pr_done ( pr_done ),
    .sr_start ( sr_start ), .sr_we ( sr_we ), .sr_addr ( sr_addr ), .sr_wdata ( sr_wdata ),
    .sr_busy ( sr_busy ), .sr_done ( sr_done ), .sr_rdata ( sr_rdata )
);

// SDRAM: arbiter, controller, clock pin through a DDIO register
wire         c_valid, c_ready, c_we, c_tag, c_rvalid, c_rtag;
wire [24:0]  c_addr;
wire [63:0]  c_wdata, c_rdata;
wire [7:0]   c_be;

sdram_arb arb (
    .clk(clk_sys), .rst(rst_sys),
    .a_valid(a_valid), .a_ready(a_ready), .a_we(a_we), .a_addr(a_addr), .a_wdata(a_wdata), .a_be(a_be),
    .b_valid(b_valid), .b_ready(b_ready), .b_addr(b_addr),
    .a_rvalid(a_rvalid), .b_rvalid(b_rvalid), .r_data(r_data),
    .c_valid(c_valid), .c_ready(c_ready), .c_we(c_we), .c_addr(c_addr), .c_wdata(c_wdata), .c_be(c_be), .c_tag(c_tag),
    .c_rvalid(c_rvalid), .c_rdata(c_rdata), .c_rtag(c_rtag)
);

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

// PSRAM: both chips ganged as one 32-bit memory, shared control
wire [21:16] cram_a;
wire         cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n, cram_oe_n, cram_we_n;
wire         cram0_ub, cram0_lb, cram1_ub, cram1_lb;

psram32 ps (
    .clk(clk_sys), .rst(rst_sys),
    .cmd_valid(pc_valid), .cmd_ready(pc_ready), .cmd_we(pc_we), .cmd_cfg(pc_cfg), .cmd_addr(pc_addr),
    .cmd_len(5'd4), .cmd_wdata(pc_wdata), .cmd_be(pc_be),
    .sync_mode(cfg_sys[0]), .rd_wait(cfg_sys[5:1]), .sync_lc(cfg_sys[8:6]), .sync_phase(cfg_sys[10:9]),
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

// SRAM: byte store
sram_ctl sr (
    .clk(clk_sys), .rst(rst_sys), .start(sr_start), .we(sr_we), .addr(sr_addr), .wdata(sr_wdata),
    .wait_c(cfg_sys[14:11]), .busy(sr_busy), .done(sr_done), .rdata(sr_rdata),
    .sram_a(sram_a), .sram_dq(sram_dq), .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n),
    .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n)
);

///////////////////////////////////////////////////////////////////////////////
// video: fixed mode from the stub's video outputs (placeholder pixel clock, clk_vid domain)
reg [23:0] vid_rgb;
reg        vid_de, vid_hs, vid_vs;
always @(posedge clk_vid) begin
    vid_rgb <= {psx_video_r, psx_video_g, psx_video_b};
    vid_de  <= ~psx_hblank & ~psx_vblank;
    vid_hs  <= psx_hsync;
    vid_vs  <= psx_vsync;
end

assign video_rgb_clock    = clk_vid;
assign video_rgb_clock_90 = clk_vid_90;
assign video_rgb          = vid_rgb;
assign video_de           = vid_de;
assign video_skip         = 1'b0;
assign video_vs           = vid_vs;
assign video_hs           = vid_hs;

///////////////////////////////////////////////////////////////////////////////
// bridge reads: command handler, and the stub's memory-card stream for the slot windows
wire [31:0] rd_pool;
synch_3 #(.WIDTH(32)) s_rd ({psx_memcard1_dataOut, psx_memcard1_dataOut} ^ {psx_cd_hps_lba[15:0], psx_cd_hps_lba[31:16]}, rd_pool, clk_74a);

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
    32'h4xxxxxxx: bridge_rd_data <= rd_pool ^ datatable_q;
    32'h800001xx: bridge_rd_data <= (bridge_addr[7:2] < 6'd5) ? cal_st[{bridge_addr[4:2], 5'd0} +: 32] : 32'd0;
    32'hF8xxxxxx: bridge_rd_data <= cmd_bridge_rd_data;
    default:      bridge_rd_data <= 0;
    endcase
end

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
