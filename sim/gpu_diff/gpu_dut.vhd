library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Port list of gpu; the Makefile analyses one of two architectures (golden, pocket).
entity gpu_dut is
   port
   (
      clk1x                : in  std_logic;
      clk2x                : in  std_logic;
      clk2xIndex           : in  std_logic;
      clkvid               : in  std_logic;
      ce                   : in  std_logic;
      reset                : in  std_logic;

      allowunpause         : out std_logic;
      savestate_busy       : in  std_logic;
      system_paused        : in  std_logic;

      ditherOff            : in  std_logic;
      interlaced480pHack   : in  std_logic;
      REPRODUCIBLEGPUTIMING: in  std_logic;
      videoout_on          : in  std_logic;
      isPal                : in  std_logic;
      pal60                : in  std_logic;
      fpscountOn           : in  std_logic;
      noTexture            : in  std_logic;
      textureFilter        : in  std_logic_vector(1 downto 0);
      textureFilterStrength: in  std_logic_vector(1 downto 0);
      textureFilter2DOff   : in  std_logic;
      dither24             : in  std_logic;
      render24             : in  std_logic;
      drawSlow             : in  std_logic;
      debugmodeOn          : in  std_logic;
      syncVideoOut         : in  std_logic;
      syncInterlace        : in  std_logic;
      rotate180            : in  std_logic;
      fixedVBlank          : in  std_logic;
      vCrop                : in  std_logic_vector(1 downto 0);
      hCrop                : in  std_logic;

     oldGPU               : in  std_logic;

      Gun1CrosshairOn      : in  std_logic;
      Gun1X                : in  unsigned(7 downto 0);
      Gun1Y_scanlines      : in  unsigned(8 downto 0);
      Gun1offscreen        : in  std_logic;
      Gun1IRQ10            : out std_logic;

      Gun2CrosshairOn      : in  std_logic;
      Gun2X                : in  unsigned(7 downto 0);
      Gun2Y_scanlines      : in  unsigned(8 downto 0);
      Gun2offscreen        : in  std_logic;
      Gun2IRQ10            : out std_logic;

      cdSlow               : in  std_logic;

      errorOn              : in  std_logic;
      errorEna             : in  std_logic;
      errorCode            : in  unsigned(3 downto 0);

      LBAOn                : in  std_logic;
      LBAdisplay           : in  unsigned(19 downto 0);

      errorLINE            : out std_logic;
      errorRECT            : out std_logic;
      errorPOLY            : out std_logic;
      errorGPU             : out std_logic;
      errorMASK            : out std_logic;
      errorFIFO            : out std_logic;

      bus_addr             : in  unsigned(3 downto 0);
      bus_dataWrite        : in  std_logic_vector(31 downto 0);
      bus_read             : in  std_logic;
      bus_write            : in  std_logic;
      bus_dataRead         : out std_logic_vector(31 downto 0);
      bus_stall            : out std_logic := '0';

      dmaOn                : in  std_logic;
      gpu_dmaRequest       : out std_logic;
      DMA_GPU_waiting      : in  std_logic;
      DMA_GPU_writeEna     : in  std_logic;
      DMA_GPU_readEna      : in  std_logic;
      DMA_GPU_write        : in  std_logic_vector(31 downto 0);
      DMA_GPU_read         : out std_logic_vector(31 downto 0);

      irq_VBLANK           : out std_logic := '0';
      irq_GPU              : out std_logic := '0';

      vram_pause           : in  std_logic;
      vram_paused          : out std_logic := '0';
      vram_BUSY            : in  std_logic;
      vram_DOUT            : in  std_logic_vector(63 downto 0);
      vram_DOUT_READY      : in  std_logic;
      vram_BURSTCNT        : out std_logic_vector(7 downto 0) := (others => '0');
      vram_ADDR            : out std_logic_vector(27 downto 0) := (others => '0');
      vram_DIN             : out std_logic_vector(63 downto 0) := (others => '0');
      vram_BE              : out std_logic_vector(7 downto 0) := (others => '0');
      vram_WE              : out std_logic := '0';
      vram_RD              : out std_logic := '0';

      hblank_tmr           : out std_logic := '0';
      vblank_tmr           : out std_logic := '0';
      dotclock             : out std_logic;

      video_hsync          : out std_logic := '0';
      video_vsync          : out std_logic := '0';
      video_hblank         : out std_logic := '0';
      video_vblank         : out std_logic := '0';
      video_DisplayWidth   : out unsigned(10 downto 0);
      video_DisplayHeight  : out unsigned( 9 downto 0);
      video_DisplayOffsetX : out unsigned( 9 downto 0) := (others => '0');
      video_DisplayOffsetY : out unsigned( 8 downto 0) := (others => '0');
      video_ce             : out std_logic;
      video_interlace      : out std_logic;
      video_r              : out std_logic_vector(7 downto 0);
      video_g              : out std_logic_vector(7 downto 0);
      video_b              : out std_logic_vector(7 downto 0);
      video_isPal          : out std_logic;
      video_fbmode         : out std_logic;
      video_fb24           : out std_logic;
      video_hResMode       : out std_logic_vector(2 downto 0);
      video_frameindex     : out std_logic_vector(3 downto 0);

-- synthesis translate_off
      export_gtm           : out unsigned(11 downto 0);
      export_line          : out unsigned(11 downto 0);
      export_gpus          : out unsigned(31 downto 0);
      export_gobj          : out unsigned(15 downto 0) := (others => '0');
-- synthesis translate_on

      loading_savestate    : in  std_logic;
      SS_reset             : in  std_logic;
      SS_DataWrite         : in  std_logic_vector(31 downto 0);
      SS_Adr               : in  unsigned(2 downto 0);
      SS_wren_GPU          : in  std_logic;
      SS_wren_Timing       : in  std_logic;
      SS_rden_GPU          : in  std_logic;
      SS_rden_Timing       : in  std_logic;
      SS_DataRead_GPU      : out std_logic_vector(31 downto 0);
      SS_DataRead_Timing   : out std_logic_vector(31 downto 0);
      SS_Idle              : out std_logic
   );
end entity;
