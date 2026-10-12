-- psx_top_pocket with flat ports: the VHDL record joypad_t, the integer savestate_number and the signed/unsigned ports
-- become std_logic_vector, so a Verilog parent can instantiate it. Same port names and widths as the Verilog stub
-- psx_top_stub.v. joypadN packs the record, first field in the MSB: PadPort{Enable,Digital,Analog,Mouse,GunCon,NeGcon,
-- Justif,DS,Stick,Popn}, WheelMap, ToggleDS, Key{Triangle,Circle,Cross,Square,Select,Start,Right,Left,Up,Down,R1,R2,R3,L1,L2,L3},
-- Analog1X, Analog1Y, Analog2X, Analog2Y.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.pJoypad.all;

entity psx_top_pocket_flat is
   generic
   (
      is_simu               : std_logic := '0';
      NO_MDEC               : integer   := 0;          -- 0/1: a Verilog parent cannot set a boolean
      G_GPU_IMPL            : string    := "pocket";
      G_CPU_IMPL            : string    := "golden";
      G_SPU_IMPL            : string    := "golden";
      G_CD_IMPL             : string    := "golden";
      G_DMA_IMPL            : string    := "golden";
      G_BUS_IMPL            : string    := "golden";
      G_JOYPAD_IMPL         : string    := "golden";
      G_MEMCARD_IMPL        : string    := "golden";
      G_MDEC_IMPL           : string    := "golden"
   );
   port
   (
      clk1x                 : in  std_logic;
      clk2x                 : in  std_logic;
      clk3x                 : in  std_logic;
      clkvid                : in  std_logic;
      reset                 : in  std_logic;
      isPaused              : out std_logic;
      pause                 : in  std_logic;
      hps_busy              : in  std_logic;
      loadExe               : in  std_logic;
      exe_initial_pc        : in  std_logic_vector(31 downto 0);
      exe_initial_gp        : in  std_logic_vector(31 downto 0);
      exe_load_address      : in  std_logic_vector(31 downto 0);
      exe_file_size         : in  std_logic_vector(31 downto 0);
      exe_stackpointer      : in  std_logic_vector(31 downto 0);
      fastboot              : in  std_logic;
      ram8mb                : in  std_logic;
      TURBO_MEM             : in  std_logic;
      TURBO_COMP            : in  std_logic;
      TURBO_CACHE           : in  std_logic;
      TURBO_CACHE50         : in  std_logic;
      REPRODUCIBLEGPUTIMING : in  std_logic;
      INSTANTSEEK           : in  std_logic;
      FORCECDSPEED          : in  std_logic_vector(2 downto 0);
      LIMITREADSPEED        : in  std_logic;
      IGNORECDDMATIMING     : in  std_logic;
      ditherOff             : in  std_logic;
      interlaced480pHack    : in  std_logic;
      showGunCrosshairs     : in  std_logic;
      enableNeGconRumble    : in  std_logic;
      fpscountOn            : in  std_logic;
      cdslowOn              : in  std_logic;
      testSeek              : in  std_logic;
      pauseOnCDSlow         : in  std_logic;
      errorOn               : in  std_logic;
      LBAOn                 : in  std_logic;
      PATCHSERIAL           : in  std_logic;
      noTexture             : in  std_logic;
      textureFilter         : in  std_logic_vector(1 downto 0);
      textureFilterStrength : in  std_logic_vector(1 downto 0);
      textureFilter2DOff    : in  std_logic;
      dither24              : in  std_logic;
      render24              : in  std_logic;
      drawSlow              : in  std_logic;
      syncVideoOut          : in  std_logic;
      syncInterlace         : in  std_logic;
      rotate180             : in  std_logic;
      fixedVBlank           : in  std_logic;
      vCrop                 : in  std_logic_vector(1 downto 0);
      hCrop                 : in  std_logic;
      SPUon                 : in  std_logic;
      SPUIRQTrigger         : in  std_logic;
      SPUSDRAM              : in  std_logic;
      REVERBOFF             : in  std_logic;
      REPRODUCIBLESPUDMA    : in  std_logic;
      WIDESCREEN            : in  std_logic_vector(1 downto 0);
      oldGPU                : in  std_logic;
      biosregion            : in  std_logic_vector(1 downto 0);
      ram_refresh           : out std_logic;
      ram_dataWrite         : out std_logic_vector(31 downto 0);
      ram_dataRead32        : in  std_logic_vector(31 downto 0);
      ram_Adr               : out std_logic_vector(24 downto 0);
      ram_cntDMA            : out std_logic_vector(1 downto 0);
      ram_be                : out std_logic_vector(3 downto 0);
      ram_rnw               : out std_logic;
      ram_ena               : out std_logic;
      ram_dma               : out std_logic;
      ram_cache             : out std_logic;
      ram_done              : in  std_logic;
      ram_dmafifo_adr       : out std_logic_vector(22 downto 0);
      ram_dmafifo_data      : out std_logic_vector(31 downto 0);
      ram_dmafifo_empty     : out std_logic;
      ram_dmafifo_read      : in  std_logic;
      cache_wr              : in  std_logic_vector(3 downto 0);
      cache_data            : in  std_logic_vector(31 downto 0);
      cache_addr            : in  std_logic_vector(7 downto 0);
      dma_wr                : in  std_logic;
      dma_reqprocessed      : in  std_logic;
      dma_data              : in  std_logic_vector(31 downto 0);
      ddr3_BUSY             : in  std_logic;
      ddr3_DOUT             : in  std_logic_vector(63 downto 0);
      ddr3_DOUT_READY       : in  std_logic;
      ddr3_BURSTCNT         : out std_logic_vector(7 downto 0);
      ddr3_ADDR             : out std_logic_vector(27 downto 0);
      ddr3_DIN              : out std_logic_vector(63 downto 0);
      ddr3_BE               : out std_logic_vector(7 downto 0);
      ddr3_WE               : out std_logic;
      ddr3_RD               : out std_logic;
      region                : in  std_logic_vector(1 downto 0);
      region_out            : out std_logic_vector(1 downto 0);
      hasCD                 : in  std_logic;
      fastCD                : in  std_logic;
      LIDopen               : in  std_logic;
      trackinfo_data        : in  std_logic_vector(31 downto 0);
      trackinfo_addr        : in  std_logic_vector(8 downto 0);
      trackinfo_write       : in  std_logic;
      resetFromCD           : out std_logic;
      cd_hps_req            : out std_logic;
      cd_hps_lba            : out std_logic_vector(31 downto 0);
      cd_hps_lba_sim        : out std_logic_vector(31 downto 0);
      cd_hps_ack            : in  std_logic;
      cd_hps_write          : in  std_logic;
      cd_hps_data           : in  std_logic_vector(15 downto 0);
      spuram_dataWrite      : out std_logic_vector(31 downto 0);
      spuram_Adr            : out std_logic_vector(18 downto 0);
      spuram_be             : out std_logic_vector(3 downto 0);
      spuram_rnw            : out std_logic;
      spuram_ena            : out std_logic;
      spuram_dataRead       : in  std_logic_vector(31 downto 0);
      spuram_done           : in  std_logic;
      memcard_changed       : out std_logic;
      saving_memcard        : out std_logic;
      memcard1_load         : in  std_logic;
      memcard2_load         : in  std_logic;
      memcard_save          : in  std_logic;
      memcard1_mounted      : in  std_logic;
      memcard1_available    : in  std_logic;
      memcard1_rd           : out std_logic;
      memcard1_wr           : out std_logic;
      memcard1_lba          : out std_logic_vector(6 downto 0);
      memcard1_ack          : in  std_logic;
      memcard1_write        : in  std_logic;
      memcard1_addr         : in  std_logic_vector(8 downto 0);
      memcard1_dataIn       : in  std_logic_vector(15 downto 0);
      memcard1_dataOut      : out std_logic_vector(15 downto 0);
      memcard2_mounted      : in  std_logic;
      memcard2_available    : in  std_logic;
      memcard2_rd           : out std_logic;
      memcard2_wr           : out std_logic;
      memcard2_lba          : out std_logic_vector(6 downto 0);
      memcard2_ack          : in  std_logic;
      memcard2_write        : in  std_logic;
      memcard2_addr         : in  std_logic_vector(8 downto 0);
      memcard2_dataIn       : in  std_logic_vector(15 downto 0);
      memcard2_dataOut      : out std_logic_vector(15 downto 0);
      videoout_on           : in  std_logic;
      isPal                 : in  std_logic;
      pal60                 : in  std_logic;
      hsync                 : out std_logic;
      vsync                 : out std_logic;
      hblank                : out std_logic;
      vblank                : out std_logic;
      DisplayWidth          : out std_logic_vector(10 downto 0);
      DisplayHeight         : out std_logic_vector(9 downto 0);
      DisplayOffsetX        : out std_logic_vector(9 downto 0);
      DisplayOffsetY        : out std_logic_vector(8 downto 0);
      video_ce              : out std_logic;
      video_interlace       : out std_logic;
      video_r               : out std_logic_vector(7 downto 0);
      video_g               : out std_logic_vector(7 downto 0);
      video_b               : out std_logic_vector(7 downto 0);
      video_isPal           : out std_logic;
      video_fbmode          : out std_logic;
      video_fb24            : out std_logic;
      video_hResMode        : out std_logic_vector(2 downto 0);
      video_frameindex      : out std_logic_vector(3 downto 0);
      DSAltSwitchMode       : in  std_logic;
      joypad1               : in  std_logic_vector(59 downto 0);
      joypad2               : in  std_logic_vector(59 downto 0);
      joypad3               : in  std_logic_vector(59 downto 0);
      joypad4               : in  std_logic_vector(59 downto 0);
      multitap              : in  std_logic;
      multitapDigital       : in  std_logic;
      multitapAnalog        : in  std_logic;
      neGconRumble          : in  std_logic;
      joypad1_rumble        : out std_logic_vector(15 downto 0);
      joypad2_rumble        : out std_logic_vector(15 downto 0);
      joypad3_rumble        : out std_logic_vector(15 downto 0);
      joypad4_rumble        : out std_logic_vector(15 downto 0);
      padMode               : out std_logic_vector(1 downto 0);
      MouseEvent            : in  std_logic;
      MouseLeft             : in  std_logic;
      MouseRight            : in  std_logic;
      MouseX                : in  std_logic_vector(8 downto 0);
      MouseY                : in  std_logic_vector(8 downto 0);
      snacPort1             : in  std_logic;
      snacPort2             : in  std_logic;
      irq10Snac             : in  std_logic;
      actionNextSnac        : in  std_logic;
      receiveValidSnac      : in  std_logic;
      ackSnac               : in  std_logic;
      snacMC                : in  std_logic;
      receiveBufferSnac     : in  std_logic_vector(7 downto 0);
      transmitValueSnac     : out std_logic_vector(7 downto 0);
      selectedPort1Snac     : out std_logic;
      selectedPort2Snac     : out std_logic;
      clk9Snac              : out std_logic;
      beginTransferSnac     : out std_logic;
      sound_out_left        : out std_logic_vector(15 downto 0);
      sound_out_right       : out std_logic_vector(15 downto 0);
      increaseSSHeaderCount : in  std_logic;
      save_state            : in  std_logic;
      load_state            : in  std_logic;
      savestate_number      : in  std_logic_vector(1 downto 0);
      state_loaded          : out std_logic;
      validSStates          : out std_logic_vector(3 downto 0);
      rewind_on             : in  std_logic;
      rewind_active         : in  std_logic;
      cheat_clear           : in  std_logic;
      cheats_enabled        : in  std_logic;
      cheat_on              : in  std_logic;
      cheat_in              : in  std_logic_vector(127 downto 0);
      cheats_active         : out std_logic;
      Cheats_BusAddr        : out std_logic_vector(20 downto 0);
      Cheats_BusRnW         : out std_logic;
      Cheats_BusByteEnable  : out std_logic_vector(3 downto 0);
      Cheats_BusWriteData   : out std_logic_vector(31 downto 0);
      Cheats_Bus_ena        : out std_logic;
      Cheats_BusReadData    : in  std_logic_vector(31 downto 0);
      Cheats_BusDone        : in  std_logic
   );
end entity;

architecture arch of psx_top_pocket_flat is

   function to_joypad(v : std_logic_vector(59 downto 0)) return joypad_t is
      variable j : joypad_t;
   begin
      j.PadPortEnable := v(59);
      j.PadPortDigital := v(58);
      j.PadPortAnalog := v(57);
      j.PadPortMouse := v(56);
      j.PadPortGunCon := v(55);
      j.PadPortNeGcon := v(54);
      j.PadPortJustif := v(53);
      j.PadPortDS := v(52);
      j.PadPortStick := v(51);
      j.PadPortPopn := v(50);
      j.WheelMap := v(49);
      j.ToggleDS := v(48);
      j.KeyTriangle := v(47);
      j.KeyCircle := v(46);
      j.KeyCross := v(45);
      j.KeySquare := v(44);
      j.KeySelect := v(43);
      j.KeyStart := v(42);
      j.KeyRight := v(41);
      j.KeyLeft := v(40);
      j.KeyUp := v(39);
      j.KeyDown := v(38);
      j.KeyR1 := v(37);
      j.KeyR2 := v(36);
      j.KeyR3 := v(35);
      j.KeyL1 := v(34);
      j.KeyL2 := v(33);
      j.KeyL3 := v(32);
      j.Analog1X := signed(v(31 downto 24));
      j.Analog1Y := signed(v(23 downto 16));
      j.Analog2X := signed(v(15 downto 8));
      j.Analog2Y := signed(v(7 downto 0));
      return j;
   end function;

   signal core_Cheats_BusAddr : std_logic_vector(20 downto 0);
   signal core_DisplayWidth : unsigned(10 downto 0);
   signal core_DisplayHeight : unsigned(9 downto 0);
   signal core_DisplayOffsetX : unsigned(9 downto 0);
   signal core_DisplayOffsetY : unsigned(8 downto 0);
begin
   core : entity work.psx_top_pocket
      generic map (is_simu => is_simu, NO_MDEC => (NO_MDEC /= 0), G_GPU_IMPL => G_GPU_IMPL, G_CPU_IMPL => G_CPU_IMPL, G_SPU_IMPL => G_SPU_IMPL,
                   G_CD_IMPL => G_CD_IMPL, G_DMA_IMPL => G_DMA_IMPL, G_BUS_IMPL => G_BUS_IMPL, G_JOYPAD_IMPL => G_JOYPAD_IMPL,
                   G_MEMCARD_IMPL => G_MEMCARD_IMPL, G_MDEC_IMPL => G_MDEC_IMPL)
      port map (
         clk1x => clk1x,
         clk2x => clk2x,
         clk3x => clk3x,
         clkvid => clkvid,
         reset => reset,
         isPaused => isPaused,
         pause => pause,
         hps_busy => hps_busy,
         loadExe => loadExe,
         exe_initial_pc => unsigned(exe_initial_pc),
         exe_initial_gp => unsigned(exe_initial_gp),
         exe_load_address => unsigned(exe_load_address),
         exe_file_size => unsigned(exe_file_size),
         exe_stackpointer => unsigned(exe_stackpointer),
         fastboot => fastboot,
         ram8mb => ram8mb,
         TURBO_MEM => TURBO_MEM,
         TURBO_COMP => TURBO_COMP,
         TURBO_CACHE => TURBO_CACHE,
         TURBO_CACHE50 => TURBO_CACHE50,
         REPRODUCIBLEGPUTIMING => REPRODUCIBLEGPUTIMING,
         INSTANTSEEK => INSTANTSEEK,
         FORCECDSPEED => FORCECDSPEED,
         LIMITREADSPEED => LIMITREADSPEED,
         IGNORECDDMATIMING => IGNORECDDMATIMING,
         ditherOff => ditherOff,
         interlaced480pHack => interlaced480pHack,
         showGunCrosshairs => showGunCrosshairs,
         enableNeGconRumble => enableNeGconRumble,
         fpscountOn => fpscountOn,
         cdslowOn => cdslowOn,
         testSeek => testSeek,
         pauseOnCDSlow => pauseOnCDSlow,
         errorOn => errorOn,
         LBAOn => LBAOn,
         PATCHSERIAL => PATCHSERIAL,
         noTexture => noTexture,
         textureFilter => textureFilter,
         textureFilterStrength => textureFilterStrength,
         textureFilter2DOff => textureFilter2DOff,
         dither24 => dither24,
         render24 => render24,
         drawSlow => drawSlow,
         syncVideoOut => syncVideoOut,
         syncInterlace => syncInterlace,
         rotate180 => rotate180,
         fixedVBlank => fixedVBlank,
         vCrop => vCrop,
         hCrop => hCrop,
         SPUon => SPUon,
         SPUIRQTrigger => SPUIRQTrigger,
         SPUSDRAM => SPUSDRAM,
         REVERBOFF => REVERBOFF,
         REPRODUCIBLESPUDMA => REPRODUCIBLESPUDMA,
         WIDESCREEN => WIDESCREEN,
         oldGPU => oldGPU,
         biosregion => biosregion,
         ram_refresh => ram_refresh,
         ram_dataWrite => ram_dataWrite,
         ram_dataRead32 => ram_dataRead32,
         ram_Adr => ram_Adr,
         ram_cntDMA => ram_cntDMA,
         ram_be => ram_be,
         ram_rnw => ram_rnw,
         ram_ena => ram_ena,
         ram_dma => ram_dma,
         ram_cache => ram_cache,
         ram_done => ram_done,
         ram_dmafifo_adr => ram_dmafifo_adr,
         ram_dmafifo_data => ram_dmafifo_data,
         ram_dmafifo_empty => ram_dmafifo_empty,
         ram_dmafifo_read => ram_dmafifo_read,
         cache_wr => cache_wr,
         cache_data => cache_data,
         cache_addr => cache_addr,
         dma_wr => dma_wr,
         dma_reqprocessed => dma_reqprocessed,
         dma_data => dma_data,
         ddr3_BUSY => ddr3_BUSY,
         ddr3_DOUT => ddr3_DOUT,
         ddr3_DOUT_READY => ddr3_DOUT_READY,
         ddr3_BURSTCNT => ddr3_BURSTCNT,
         ddr3_ADDR => ddr3_ADDR,
         ddr3_DIN => ddr3_DIN,
         ddr3_BE => ddr3_BE,
         ddr3_WE => ddr3_WE,
         ddr3_RD => ddr3_RD,
         region => region,
         region_out => region_out,
         hasCD => hasCD,
         fastCD => fastCD,
         LIDopen => LIDopen,
         trackinfo_data => trackinfo_data,
         trackinfo_addr => trackinfo_addr,
         trackinfo_write => trackinfo_write,
         resetFromCD => resetFromCD,
         cd_hps_req => cd_hps_req,
         cd_hps_lba => cd_hps_lba,
         cd_hps_lba_sim => cd_hps_lba_sim,
         cd_hps_ack => cd_hps_ack,
         cd_hps_write => cd_hps_write,
         cd_hps_data => cd_hps_data,
         spuram_dataWrite => spuram_dataWrite,
         spuram_Adr => spuram_Adr,
         spuram_be => spuram_be,
         spuram_rnw => spuram_rnw,
         spuram_ena => spuram_ena,
         spuram_dataRead => spuram_dataRead,
         spuram_done => spuram_done,
         memcard_changed => memcard_changed,
         saving_memcard => saving_memcard,
         memcard1_load => memcard1_load,
         memcard2_load => memcard2_load,
         memcard_save => memcard_save,
         memcard1_mounted => memcard1_mounted,
         memcard1_available => memcard1_available,
         memcard1_rd => memcard1_rd,
         memcard1_wr => memcard1_wr,
         memcard1_lba => memcard1_lba,
         memcard1_ack => memcard1_ack,
         memcard1_write => memcard1_write,
         memcard1_addr => memcard1_addr,
         memcard1_dataIn => memcard1_dataIn,
         memcard1_dataOut => memcard1_dataOut,
         memcard2_mounted => memcard2_mounted,
         memcard2_available => memcard2_available,
         memcard2_rd => memcard2_rd,
         memcard2_wr => memcard2_wr,
         memcard2_lba => memcard2_lba,
         memcard2_ack => memcard2_ack,
         memcard2_write => memcard2_write,
         memcard2_addr => memcard2_addr,
         memcard2_dataIn => memcard2_dataIn,
         memcard2_dataOut => memcard2_dataOut,
         videoout_on => videoout_on,
         isPal => isPal,
         pal60 => pal60,
         hsync => hsync,
         vsync => vsync,
         hblank => hblank,
         vblank => vblank,
         DisplayWidth => core_DisplayWidth,
         DisplayHeight => core_DisplayHeight,
         DisplayOffsetX => core_DisplayOffsetX,
         DisplayOffsetY => core_DisplayOffsetY,
         video_ce => video_ce,
         video_interlace => video_interlace,
         video_r => video_r,
         video_g => video_g,
         video_b => video_b,
         video_isPal => video_isPal,
         video_fbmode => video_fbmode,
         video_fb24 => video_fb24,
         video_hResMode => video_hResMode,
         video_frameindex => video_frameindex,
         DSAltSwitchMode => DSAltSwitchMode,
         joypad1 => to_joypad(joypad1),
         joypad2 => to_joypad(joypad2),
         joypad3 => to_joypad(joypad3),
         joypad4 => to_joypad(joypad4),
         multitap => multitap,
         multitapDigital => multitapDigital,
         multitapAnalog => multitapAnalog,
         neGconRumble => neGconRumble,
         joypad1_rumble => joypad1_rumble,
         joypad2_rumble => joypad2_rumble,
         joypad3_rumble => joypad3_rumble,
         joypad4_rumble => joypad4_rumble,
         padMode => padMode,
         MouseEvent => MouseEvent,
         MouseLeft => MouseLeft,
         MouseRight => MouseRight,
         MouseX => signed(MouseX),
         MouseY => signed(MouseY),
         snacPort1 => snacPort1,
         snacPort2 => snacPort2,
         irq10Snac => irq10Snac,
         actionNextSnac => actionNextSnac,
         receiveValidSnac => receiveValidSnac,
         ackSnac => ackSnac,
         snacMC => snacMC,
         receiveBufferSnac => receiveBufferSnac,
         transmitValueSnac => transmitValueSnac,
         selectedPort1Snac => selectedPort1Snac,
         selectedPort2Snac => selectedPort2Snac,
         clk9Snac => clk9Snac,
         beginTransferSnac => beginTransferSnac,
         sound_out_left => sound_out_left,
         sound_out_right => sound_out_right,
         increaseSSHeaderCount => increaseSSHeaderCount,
         save_state => save_state,
         load_state => load_state,
         savestate_number => to_integer(unsigned(savestate_number)),
         state_loaded => state_loaded,
         validSStates => validSStates,
         rewind_on => rewind_on,
         rewind_active => rewind_active,
         cheat_clear => cheat_clear,
         cheats_enabled => cheats_enabled,
         cheat_on => cheat_on,
         cheat_in => cheat_in,
         cheats_active => cheats_active,
         Cheats_BusAddr => core_Cheats_BusAddr,
         Cheats_BusRnW => Cheats_BusRnW,
         Cheats_BusByteEnable => Cheats_BusByteEnable,
         Cheats_BusWriteData => Cheats_BusWriteData,
         Cheats_Bus_ena => Cheats_Bus_ena,
         Cheats_BusReadData => Cheats_BusReadData,
         Cheats_BusDone => Cheats_BusDone);
   Cheats_BusAddr <= core_Cheats_BusAddr;
   DisplayWidth <= std_logic_vector(core_DisplayWidth);
   DisplayHeight <= std_logic_vector(core_DisplayHeight);
   DisplayOffsetX <= std_logic_vector(core_DisplayOffsetX);
   DisplayOffsetY <= std_logic_vector(core_DisplayOffsetY);
end architecture;
