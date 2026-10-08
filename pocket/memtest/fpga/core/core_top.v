//
// User core top-level
//
// Instantiated by the real top-level: apf_top
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
// clocks: 74.25 MHz in; the system clock (101.6064 MHz, or 135.4752 MHz in the SDRAM_135 variant), the same clock
// shifted for the SDRAM pin and for SDRAM read capture, 6.3504 MHz pixel clock and its 90 degree copy
wire clk_sys, clk_sd, clk_cap, clk_vid, clk_vid_90;
wire pll_core_locked;
wire pll_core_locked_s;
synch_3 s01(pll_core_locked, pll_core_locked_s, clk_74a);

pll_mem pll (
    .refclk     ( clk_74a ),
    .rst        ( 1'b0 ),
    .clk_sys    ( clk_sys ),
    .clk_sd     ( clk_sd ),
    .clk_cap    ( clk_cap ),
    .clk_vid    ( clk_vid ),
    .clk_vid_90 ( clk_vid_90 ),
    .locked     ( pll_core_locked )
);

//
// host/target command handler
//
    wire            reset_n;                // driven by host commands, can be used as core-wide reset
    wire    [31:0]  cmd_bridge_rd_data;
    
// bridge host commands
// synchronous to clk_74a
    wire            status_boot_done = pll_core_locked_s; 
    wire            status_setup_done = pll_core_locked_s; // rising edge triggers a target command
    wire            status_running = reset_n; // we are running as soon as reset_n goes high

    wire            dataslot_requestread;
    wire    [15:0]  dataslot_requestread_id;
    wire            dataslot_requestread_ack = 1;
    wire            dataslot_requestread_ok = 1;

    wire            dataslot_requestwrite;
    wire    [15:0]  dataslot_requestwrite_id;
    wire    [31:0]  dataslot_requestwrite_size;
    wire            dataslot_requestwrite_ack = 1;
    wire            dataslot_requestwrite_ok = 1;

    wire            dataslot_update;
    wire    [15:0]  dataslot_update_id;
    wire    [31:0]  dataslot_update_size;
    
    wire            dataslot_allcomplete;

    wire     [31:0] rtc_epoch_seconds;
    wire     [31:0] rtc_date_bcd;
    wire     [31:0] rtc_time_bcd;
    wire            rtc_valid;

    wire            savestate_supported;
    wire    [31:0]  savestate_addr;
    wire    [31:0]  savestate_size;
    wire    [31:0]  savestate_maxloadsize;

    wire            savestate_start;
    wire            savestate_start_ack;
    wire            savestate_start_busy;
    wire            savestate_start_ok;
    wire            savestate_start_err;

    wire            savestate_load;
    wire            savestate_load_ack;
    wire            savestate_load_busy;
    wire            savestate_load_ok;
    wire            savestate_load_err;
    
    wire            osnotify_inmenu;

// bridge target commands
// synchronous to clk_74a

    reg             target_dataslot_read;       
    reg             target_dataslot_write;
    reg             target_dataslot_getfile;    // require additional param/resp structs to be mapped
    reg             target_dataslot_openfile;   // require additional param/resp structs to be mapped
    
    wire            target_dataslot_ack;        
    wire            target_dataslot_done;
    wire    [2:0]   target_dataslot_err;

    reg     [15:0]  target_dataslot_id;
    reg     [31:0]  target_dataslot_slotoffset;
    reg     [31:0]  target_dataslot_bridgeaddr;
    reg     [31:0]  target_dataslot_length;
    
    wire    [31:0]  target_buffer_param_struct; // to be mapped/implemented when using some Target commands
    wire    [31:0]  target_buffer_resp_struct;  // to be mapped/implemented when using some Target commands
    
// bridge data slot access
// synchronous to clk_74a

    wire    [9:0]   datatable_addr;
    wire            datatable_wren;
    wire    [31:0]  datatable_data;
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
    .dataslot_requestread_ack   ( dataslot_requestread_ack ),
    .dataslot_requestread_ok    ( dataslot_requestread_ok ),

    .dataslot_requestwrite      ( dataslot_requestwrite ),
    .dataslot_requestwrite_id   ( dataslot_requestwrite_id ),
    .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
    .dataslot_requestwrite_ack  ( dataslot_requestwrite_ack ),
    .dataslot_requestwrite_ok   ( dataslot_requestwrite_ok ),

    .dataslot_update            ( dataslot_update ),
    .dataslot_update_id         ( dataslot_update_id ),
    .dataslot_update_size       ( dataslot_update_size ),
    
    .dataslot_allcomplete   ( dataslot_allcomplete ),

    .rtc_epoch_seconds      ( rtc_epoch_seconds ),
    .rtc_date_bcd           ( rtc_date_bcd ),
    .rtc_time_bcd           ( rtc_time_bcd ),
    .rtc_valid              ( rtc_valid ),
    
    .savestate_supported    ( savestate_supported ),
    .savestate_addr         ( savestate_addr ),
    .savestate_size         ( savestate_size ),
    .savestate_maxloadsize  ( savestate_maxloadsize ),

    .savestate_start        ( savestate_start ),
    .savestate_start_ack    ( savestate_start_ack ),
    .savestate_start_busy   ( savestate_start_busy ),
    .savestate_start_ok     ( savestate_start_ok ),
    .savestate_start_err    ( savestate_start_err ),

    .savestate_load         ( savestate_load ),
    .savestate_load_ack     ( savestate_load_ack ),
    .savestate_load_busy    ( savestate_load_busy ),
    .savestate_load_ok      ( savestate_load_ok ),
    .savestate_load_err     ( savestate_load_err ),

    .osnotify_inmenu        ( osnotify_inmenu ),
    
    .target_dataslot_read       ( target_dataslot_read ),
    .target_dataslot_write      ( target_dataslot_write ),
    .target_dataslot_getfile    ( target_dataslot_getfile ),
    .target_dataslot_openfile   ( target_dataslot_openfile ),
    
    .target_dataslot_ack        ( target_dataslot_ack ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err ),

    .target_dataslot_id         ( target_dataslot_id ),
    .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
    .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
    .target_dataslot_length     ( target_dataslot_length ),

    .target_buffer_param_struct ( target_buffer_param_struct ),
    .target_buffer_resp_struct  ( target_buffer_resp_struct ),
    
    .datatable_addr         ( datatable_addr ),
    .datatable_wren         ( datatable_wren ),
    .datatable_data         ( datatable_data ),
    .datatable_q            ( datatable_q )

);



////////////////////////////////////////////////////////////////////////////////////////



///////////////////////////////////////////////////////////////////////////////
// settings written by the APF menu (interact.json), clk_74a domain
//   0x80000000 restart the tests      0x80000004 PSRAM synchronous burst tests (0 off, 1 on)
//   0x80000008 latency counter code   0x8000000C sync read sample phase
//   0x80000010 loop (0 off, 1 on)
// results are readable at 0x10000000 + 4 * index (value) and 0x10000200 + 4 * index (valid flag)
reg        restart_tog;
reg        cfg_sync_en;
reg [2:0]  cfg_lc = 3'd3;
reg [1:0]  cfg_phase = 2'd2;
reg        cfg_loop;
always @(posedge clk_74a) begin
    if (bridge_wr) begin
        case (bridge_addr)
            32'h80000000: restart_tog <= ~restart_tog;
            32'h80000004: cfg_sync_en <= bridge_wr_data[0];
            32'h80000008: cfg_lc      <= bridge_wr_data[2:0];
            32'h8000000C: cfg_phase   <= bridge_wr_data[1:0];
            32'h80000010: cfg_loop    <= bridge_wr_data[0];
            default: ;
        endcase
    end
end

wire [7:0] cfg_s;
synch_3 #(.WIDTH(8)) s_cfg ({cfg_loop, cfg_phase, cfg_lc, cfg_sync_en}, cfg_s, clk_sys);
wire restart_tog_s;
synch_3 s_rst (restart_tog, restart_tog_s, clk_sys);
wire reset_n_s;
synch_3 s_rn (reset_n & pll_core_locked_s, reset_n_s, clk_sys);

reg        restart_d;
reg [4:0]  rst_cnt = 5'd31;
always @(posedge clk_sys) begin
    restart_d <= restart_tog_s;
    if (restart_d != restart_tog_s || !reset_n_s) rst_cnt <= 5'd31;
    else if (rst_cnt != 0) rst_cnt <= rst_cnt - 1'b1;
end
reg rst_sys;
always @(posedge clk_sys) rst_sys <= (rst_cnt != 0);

reg [31:0] seed_ctr;
always @(posedge clk_sys) seed_ctr <= seed_ctr + 32'd1;

///////////////////////////////////////////////////////////////////////////////
// the memory test
wire [6:0]  res_ra;
wire [32:0] res_rq, res_rq_b;
wire [1:0]  run_state;
wire [21:16] cram_a;
wire        cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n, cram_oe_n, cram_we_n;
wire        cram0_ub, cram0_lb, cram1_ub, cram1_lb;

memtest_core mt (
    .clk        ( clk_sys ),
    .clk_cap    ( clk_cap ),
    .rst        ( rst_sys ),
    .seed_in    ( seed_ctr ),
    .cfg_sync_en( cfg_s[0] ),
    .cfg_lc     ( cfg_s[3:1] ),
    .cfg_phase  ( cfg_s[5:4] ),
    .cfg_loop   ( cfg_s[6] ),
    .res_ra     ( res_ra ),
    .res_rq     ( res_rq ),
    .res_clk_b  ( clk_74a ),
    .res_rb     ( bridge_addr[8:2] ),
    .res_rq_b   ( res_rq_b ),
    .run_state  ( run_state ),
    .dram_a     ( dram_a ),
    .dram_ba    ( dram_ba ),
    .dram_dq    ( dram_dq ),
    .dram_dqm   ( dram_dqm ),
    .dram_ras_n ( dram_ras_n ),
    .dram_cas_n ( dram_cas_n ),
    .dram_we_n  ( dram_we_n ),
    .cram_a     ( cram_a ),
    .cram0_dq   ( cram0_dq ),
    .cram1_dq   ( cram1_dq ),
    .cram_clk   ( cram_clk ),
    .cram_adv_n ( cram_adv_n ),
    .cram_cre   ( cram_cre ),
    .cram_ce0_n ( cram_ce0_n ),
    .cram_ce1_n ( cram_ce1_n ),
    .cram_oe_n  ( cram_oe_n ),
    .cram_we_n  ( cram_we_n ),
    .cram0_ub_n ( cram0_ub ),
    .cram0_lb_n ( cram0_lb ),
    .cram1_ub_n ( cram1_ub ),
    .cram1_lb_n ( cram1_lb ),
    .sram_a     ( sram_a ),
    .sram_dq    ( sram_dq ),
    .sram_oe_n  ( sram_oe_n ),
    .sram_we_n  ( sram_we_n ),
    .sram_ub_n  ( sram_ub_n ),
    .sram_lb_n  ( sram_lb_n )
);

// SDRAM clock leaves through a DDIO register so it has the same pin delay as the data
assign dram_cke = 1'b1;
sd_clk_out sdclk (.clk(clk_sd), .pin(dram_clk));

// both PSRAM chips get the same control signals
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

///////////////////////////////////////////////////////////////////////////////
// result screen
wire        tx_we;
wire [9:0]  tx_wa;
wire [8:0]  tx_wd;
report_fmt fmt (.clk(clk_sys), .res_ra(res_ra), .res_rq(res_rq), .tx_we(tx_we), .tx_wa(tx_wa), .tx_wd(tx_wd));

wire [23:0] vid_rgb;
wire        vid_de, vid_hs, vid_vs;
video_text vt (
    .clk_s(clk_sys), .tx_we(tx_we), .tx_wa(tx_wa), .tx_wd(tx_wd),
    .clk_v(clk_vid), .reset_n(reset_n),
    .rgb(vid_rgb), .de(vid_de), .hs(vid_hs), .vs(vid_vs)
);

assign video_rgb_clock    = clk_vid;
assign video_rgb_clock_90 = clk_vid_90;
assign video_rgb          = vid_rgb;
assign video_de           = vid_de;
assign video_skip         = 1'b0;
assign video_vs           = vid_vs;
assign video_hs           = vid_hs;

///////////////////////////////////////////////////////////////////////////////
// bridge reads: command handler and the result store
always @(*) begin
    casex (bridge_addr)
    32'h1xxxxxxx: bridge_rd_data <= bridge_addr[9] ? {31'd0, res_rq_b[32]} : res_rq_b[31:0];
    32'hF8xxxxxx: bridge_rd_data <= cmd_bridge_rd_data;
    default:      bridge_rd_data <= 0;
    endcase
end

//
// audio i2s silence generator
// see other examples for actual audio generation
//

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
    reg         audgen_lrck_1;
always @(posedge audgen_mclk) begin
    aud_mclk_divider <= aud_mclk_divider + 1'b1;
end

// shift out audio data as I2S 
// 32 total bits per channel, but only 16 active bits at the start and then 16 dummy bits
//
    reg     [4:0]   audgen_lrck_cnt;    
    reg             audgen_lrck;
    reg             audgen_dac;
always @(negedge audgen_sclk) begin
    audgen_dac <= 1'b0;
    // 48khz * 64
    audgen_lrck_cnt <= audgen_lrck_cnt + 1'b1;
    if(audgen_lrck_cnt == 31) begin
        // switch channels
        audgen_lrck <= ~audgen_lrck;
        
    end 
end


///////////////////////////////////////////////

endmodule
