-- Sizing-only wrapper: psx_top_pocket with every option a minimal Pocket core would drop tied to a constant,
-- so synthesis prunes the dead logic. Not a functional top level.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.pJoypad.all;

entity psx_pocket_wrap is
   generic
   (
      G_NO_MDEC      : boolean := false;
      G_GPU_IMPL     : string  := "pocket";
      G_CPU_IMPL     : string  := "golden";
      G_SPU_IMPL     : string  := "golden";
      G_CD_IMPL      : string  := "golden";
      G_DMA_IMPL     : string  := "golden";
      G_BUS_IMPL     : string  := "golden";
      G_JOYPAD_IMPL  : string  := "golden";
      G_MEMCARD_IMPL : string  := "golden";
      G_MDEC_IMPL    : string  := "golden"
   );
   port
   (
      clk1x, clk2x, clk3x, clkvid, reset : in std_logic;
      isPaused              : out std_logic;
      ram_refresh           : out std_logic;
      ram_dataWrite         : out std_logic_vector(31 downto 0);
      ram_dataRead32        : in  std_logic_vector(31 downto 0);
      ram_Adr               : out std_logic_vector(24 downto 0);
      ram_cntDMA            : out std_logic_vector(1 downto 0);
      ram_be                : out std_logic_vector(3 downto 0);
      ram_rnw, ram_ena, ram_dma, ram_cache : out std_logic;
      ram_done              : in  std_logic;
      ram_dmafifo_adr       : out std_logic_vector(22 downto 0);
      ram_dmafifo_data      : out std_logic_vector(31 downto 0);
      ram_dmafifo_empty     : out std_logic;
      ram_dmafifo_read      : in  std_logic;
      dma_wr, dma_reqprocessed : in std_logic;
      dma_data              : in  std_logic_vector(31 downto 0);
      ddr3_BUSY             : in  std_logic;
      ddr3_DOUT             : in  std_logic_vector(63 downto 0);
      ddr3_DOUT_READY       : in  std_logic;
      ddr3_BURSTCNT         : out std_logic_vector(7 downto 0);
      ddr3_ADDR             : out std_logic_vector(27 downto 0);
      ddr3_DIN              : out std_logic_vector(63 downto 0);
      ddr3_BE               : out std_logic_vector(7 downto 0);
      ddr3_WE, ddr3_RD      : out std_logic;
      biosregion, region    : in  std_logic_vector(1 downto 0);
      region_out            : out std_logic_vector(1 downto 0);
      trackinfo_data        : in  std_logic_vector(31 downto 0);
      trackinfo_addr        : in  std_logic_vector(8 downto 0);
      trackinfo_write       : in  std_logic;
      resetFromCD           : out std_logic;
      cd_hps_req            : out std_logic;
      cd_hps_lba, cd_hps_lba_sim : out std_logic_vector(31 downto 0);
      cd_hps_ack, cd_hps_write : in std_logic;
      cd_hps_data           : in  std_logic_vector(15 downto 0);
      spuram_dataWrite      : out std_logic_vector(31 downto 0);
      spuram_Adr            : out std_logic_vector(18 downto 0);
      spuram_be             : out std_logic_vector(3 downto 0);
      spuram_rnw, spuram_ena : out std_logic;
      spuram_dataRead       : in  std_logic_vector(31 downto 0);
      spuram_done           : in  std_logic;
      memcard_changed, saving_memcard : out std_logic;
      memcard1_load, memcard_save, memcard1_mounted, memcard1_available : in std_logic;
      memcard1_rd, memcard1_wr : out std_logic;
      memcard1_lba          : out std_logic_vector(6 downto 0);
      memcard1_ack, memcard1_write : in std_logic;
      memcard1_addr         : in  std_logic_vector(8 downto 0);
      memcard1_dataIn       : in  std_logic_vector(15 downto 0);
      memcard1_dataOut      : out std_logic_vector(15 downto 0);
      isPal                 : in  std_logic;
      hsync, vsync, hblank, vblank : out std_logic;
      DisplayWidth          : out unsigned(10 downto 0);
      DisplayHeight         : out unsigned( 9 downto 0);
      DisplayOffsetX        : out unsigned( 9 downto 0);
      DisplayOffsetY        : out unsigned( 8 downto 0);
      video_ce, video_interlace : out std_logic;
      video_r, video_g, video_b : out std_logic_vector(7 downto 0);
      video_isPal, video_fbmode, video_fb24 : out std_logic;
      video_hResMode        : out std_logic_vector(2 downto 0);
      video_frameindex      : out std_logic_vector(3 downto 0);
      joypad1, joypad2      : in  joypad_t;
      padMode               : out std_logic_vector(1 downto 0);
      sound_out_left, sound_out_right : out std_logic_vector(15 downto 0)
   );
end entity;

architecture arch of psx_pocket_wrap is
   constant NOPAD : joypad_t := (
      PadPortEnable => '0', PadPortDigital => '0', PadPortAnalog => '0', PadPortMouse => '0', PadPortGunCon => '0',
      PadPortNeGcon => '0', PadPortJustif => '0', PadPortDS => '0', PadPortStick => '0', PadPortPopn => '0',
      WheelMap => '0', ToggleDS => '0',
      KeyTriangle => '0', KeyCircle => '0', KeyCross => '0', KeySquare => '0', KeySelect => '0', KeyStart => '0',
      KeyRight => '0', KeyLeft => '0', KeyUp => '0', KeyDown => '0',
      KeyR1 => '0', KeyR2 => '0', KeyR3 => '0', KeyL1 => '0', KeyL2 => '0', KeyL3 => '0',
      Analog1X => (others => '0'), Analog1Y => (others => '0'), Analog2X => (others => '0'), Analog2Y => (others => '0'));
begin
   ipsx_top : entity work.psx_top_pocket
   generic map
   (
      NO_MDEC => G_NO_MDEC, G_GPU_IMPL => G_GPU_IMPL, G_CPU_IMPL => G_CPU_IMPL, G_SPU_IMPL => G_SPU_IMPL,
      G_CD_IMPL => G_CD_IMPL, G_DMA_IMPL => G_DMA_IMPL, G_BUS_IMPL => G_BUS_IMPL, G_JOYPAD_IMPL => G_JOYPAD_IMPL,
      G_MEMCARD_IMPL => G_MEMCARD_IMPL, G_MDEC_IMPL => G_MDEC_IMPL
   )
   port map
   (
      clk1x => clk1x, clk2x => clk2x, clk3x => clk3x, clkvid => clkvid, reset => reset,
      isPaused => isPaused, pause => '0', hps_busy => '0',
      loadExe => '0', exe_initial_pc => (others => '0'), exe_initial_gp => (others => '0'),
      exe_load_address => (others => '0'), exe_file_size => (others => '0'), exe_stackpointer => (others => '0'),
      fastboot => '0', ram8mb => '0',
      TURBO_MEM => '0', TURBO_COMP => '0', TURBO_CACHE => '0', TURBO_CACHE50 => '0',
      REPRODUCIBLEGPUTIMING => '0', INSTANTSEEK => '0', FORCECDSPEED => "000", LIMITREADSPEED => '0',
      IGNORECDDMATIMING => '0', ditherOff => '0', interlaced480pHack => '0', showGunCrosshairs => '0',
      enableNeGconRumble => '0', fpscountOn => '0', cdslowOn => '0', testSeek => '0', pauseOnCDSlow => '0',
      errorOn => '0', LBAOn => '0', PATCHSERIAL => '0', noTexture => '0',
      textureFilter => "00", textureFilterStrength => "00", textureFilter2DOff => '0',
      dither24 => '0', render24 => '0', drawSlow => '0', syncVideoOut => '1', syncInterlace => '0',
      rotate180 => '0', fixedVBlank => '0', vCrop => "00", hCrop => '0',
      SPUon => '1', SPUIRQTrigger => '0', SPUSDRAM => '1', REVERBOFF => '0', REPRODUCIBLESPUDMA => '0',
      WIDESCREEN => "00", oldGPU => '0', biosregion => biosregion,
      ram_refresh => ram_refresh, ram_dataWrite => ram_dataWrite, ram_dataRead32 => ram_dataRead32,
      ram_Adr => ram_Adr, ram_cntDMA => ram_cntDMA, ram_be => ram_be, ram_rnw => ram_rnw, ram_ena => ram_ena,
      ram_dma => ram_dma, ram_cache => ram_cache, ram_done => ram_done,
      ram_dmafifo_adr => ram_dmafifo_adr, ram_dmafifo_data => ram_dmafifo_data,
      ram_dmafifo_empty => ram_dmafifo_empty, ram_dmafifo_read => ram_dmafifo_read,
      cache_wr => "0000", cache_data => (others => '0'), cache_addr => (others => '0'),
      dma_wr => dma_wr, dma_reqprocessed => dma_reqprocessed, dma_data => dma_data,
      ddr3_BUSY => ddr3_BUSY, ddr3_DOUT => ddr3_DOUT, ddr3_DOUT_READY => ddr3_DOUT_READY,
      ddr3_BURSTCNT => ddr3_BURSTCNT, ddr3_ADDR => ddr3_ADDR, ddr3_DIN => ddr3_DIN, ddr3_BE => ddr3_BE,
      ddr3_WE => ddr3_WE, ddr3_RD => ddr3_RD,
      region => region, region_out => region_out, hasCD => '1', fastCD => '0', LIDopen => '0',
      trackinfo_data => trackinfo_data, trackinfo_addr => trackinfo_addr, trackinfo_write => trackinfo_write,
      resetFromCD => resetFromCD, cd_hps_req => cd_hps_req, cd_hps_lba => cd_hps_lba, cd_hps_lba_sim => cd_hps_lba_sim,
      cd_hps_ack => cd_hps_ack, cd_hps_write => cd_hps_write, cd_hps_data => cd_hps_data,
      spuram_dataWrite => spuram_dataWrite, spuram_Adr => spuram_Adr, spuram_be => spuram_be,
      spuram_rnw => spuram_rnw, spuram_ena => spuram_ena, spuram_dataRead => spuram_dataRead, spuram_done => spuram_done,
      memcard_changed => memcard_changed, saving_memcard => saving_memcard,
      memcard1_load => memcard1_load, memcard2_load => '0', memcard_save => memcard_save,
      memcard1_mounted => memcard1_mounted, memcard1_available => memcard1_available,
      memcard1_rd => memcard1_rd, memcard1_wr => memcard1_wr, memcard1_lba => memcard1_lba,
      memcard1_ack => memcard1_ack, memcard1_write => memcard1_write, memcard1_addr => memcard1_addr,
      memcard1_dataIn => memcard1_dataIn, memcard1_dataOut => memcard1_dataOut,
      memcard2_mounted => '0', memcard2_available => '0', memcard2_rd => open, memcard2_wr => open,
      memcard2_lba => open, memcard2_ack => '0', memcard2_write => '0', memcard2_addr => (others => '0'),
      memcard2_dataIn => (others => '0'), memcard2_dataOut => open,
      videoout_on => '1', isPal => isPal, pal60 => '0',
      hsync => hsync, vsync => vsync, hblank => hblank, vblank => vblank,
      DisplayWidth => DisplayWidth, DisplayHeight => DisplayHeight,
      DisplayOffsetX => DisplayOffsetX, DisplayOffsetY => DisplayOffsetY,
      video_ce => video_ce, video_interlace => video_interlace,
      video_r => video_r, video_g => video_g, video_b => video_b,
      video_isPal => video_isPal, video_fbmode => video_fbmode, video_fb24 => video_fb24,
      video_hResMode => video_hResMode, video_frameindex => video_frameindex,
      DSAltSwitchMode => '0',
      joypad1 => joypad1, joypad2 => joypad2, joypad3 => NOPAD, joypad4 => NOPAD,
      multitap => '0', multitapDigital => '0', multitapAnalog => '0', neGconRumble => '0',
      joypad1_rumble => open, joypad2_rumble => open, joypad3_rumble => open, joypad4_rumble => open,
      padMode => padMode,
      MouseEvent => '0', MouseLeft => '0', MouseRight => '0', MouseX => (others => '0'), MouseY => (others => '0'),
      snacPort1 => '0', snacPort2 => '0', irq10Snac => '0', actionNextSnac => '0', receiveValidSnac => '0',
      ackSnac => '0', snacMC => '0', receiveBufferSnac => (others => '0'),
      transmitValueSnac => open, selectedPort1Snac => open, selectedPort2Snac => open, clk9Snac => open,
      beginTransferSnac => open,
      sound_out_left => sound_out_left, sound_out_right => sound_out_right,
      increaseSSHeaderCount => '0', save_state => '0', load_state => '0', savestate_number => 0,
      state_loaded => open, validSStates => open, rewind_on => '0', rewind_active => '0',
      cheat_clear => '0', cheats_enabled => '0', cheat_on => '0', cheat_in => (others => '0'),
      cheats_active => open, Cheats_BusRnW => open, Cheats_BusByteEnable => open, Cheats_BusWriteData => open,
      Cheats_Bus_ena => open, Cheats_BusReadData => (others => '0'), Cheats_BusDone => '0'
   );
end architecture;
