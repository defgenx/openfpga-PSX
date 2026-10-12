library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library mem;
use work.pGPU.all;
use work.pGPU_pocket.all;

entity gpu_pocket is
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

-- gpu with the Pocket tie-offs applied and the polygon/line dividers shared. Design: docs/pocket/GPU.md.
architecture arch of gpu_pocket is

   signal softReset                 : std_logic := '0';
   signal drawer_reset              : std_logic := '0';

   signal videoout_settings         : tvideoout_settings;
   signal videoout_reports          : tvideoout_reports;
   signal videoout_out              : tvideoout_out;

   signal GPUREAD                   : std_logic_vector(31 downto 0) := (others => '0');
   signal GPUSTAT                   : std_logic_vector(31 downto 0) := (others => '0');
   signal GPUSTAT_TextPageX         : std_logic_vector(3 downto 0);
   signal GPUSTAT_TextPageY         : std_logic;
   signal GPUSTAT_Transparency      : std_logic_vector(1 downto 0);
   signal GPUSTAT_TextPageColors    : std_logic_vector(1 downto 0);
   signal GPUSTAT_Dither            : std_logic;
   signal GPUSTAT_DrawToDisplay     : std_logic;
   signal GPUSTAT_SetMask           : std_logic;
   signal GPUSTAT_DrawPixelsMask    : std_logic;
   signal GPUSTAT_ReverseFlag       : std_logic;
   signal GPUSTAT_TextureDisable    : std_logic;
   signal GPUSTAT_HorRes2           : std_logic := '0';
   signal GPUSTAT_HorRes1           : std_logic_vector(1 downto 0) := "00";
   signal GPUSTAT_VerRes            : std_logic := '0';
   signal GPUSTAT_PalVideoMode      : std_logic := '0';
   signal GPUSTAT_ColorDepth24      : std_logic := '0';
   signal GPUSTAT_VertInterlace     : std_logic := '0';
   signal GPUSTAT_DisplayDisable    : std_logic := '1';
   signal GPUSTAT_IRQRequest        : std_logic;
   signal GPUSTAT_DMADataRequest    : std_logic;
   signal GPUSTAT_ReadyRecCmd       : std_logic;
   signal GPUSTAT_ReadySendVRAM     : std_logic;
   signal GPUSTAT_ReadyRecDMA       : std_logic;
   signal GPUSTAT_DMADirection      : std_logic_vector(1 downto 0);

   signal vramRange                 : unsigned(18 downto 0) := (others => '0');
   signal hDisplayRange             : unsigned(23 downto 0) := x"C60260";
   signal vDisplayRange             : unsigned(19 downto 0) := x"3FC10";

   signal drawMode                  : unsigned(13 downto 0) := (others => '0');

   signal textureWindow             : unsigned(19 downto 0) := (others => '0');
   signal textureWindow_AND_X       : unsigned(7 downto 0) := (others => '0');
   signal textureWindow_AND_Y       : unsigned(7 downto 0) := (others => '0');
   signal textureWindow_OR_X        : unsigned(7 downto 0) := (others => '0');
   signal textureWindow_OR_Y        : unsigned(7 downto 0) := (others => '0');

   signal drawingAreaLeft           : unsigned(9 downto 0) := (others => '0');
   signal drawingAreaRight          : unsigned(9 downto 0) := (others => '0');
   signal drawingAreaTop            : unsigned(8 downto 0) := (others => '0');
   signal drawingAreaBottom         : unsigned(8 downto 0) := (others => '0');
   signal drawingOffsetX            : signed(10 downto 0) := (others => '0');
   signal drawingOffsetY            : signed(10 downto 0) := (others => '0');
   signal interlacedDrawing         : std_logic;

   -- FIFO IN
   signal fifoIn_reset              : std_logic;
   signal fifoIn_Din                : std_logic_vector(31 downto 0);
   signal fifoIn_Wr                 : std_logic;
   signal fifoIn_Dout               : std_logic_vector(31 downto 0);
   signal fifoIn_Rd                 : std_logic;
   signal fifoIn_Empty              : std_logic;
   signal fifoIn_Valid              : std_logic;

   -- Processing
   signal proc_idle                 : std_logic;
   signal proc_done                 : std_logic;
   signal proc_requestFifo          : std_logic;

   signal pixelStall                : std_logic;
   signal pixelColor                : std_logic_vector(15 downto 0);
   signal pixelAddr                 : unsigned(19 downto 0);
   signal pixelWrite                : std_logic;

   signal pixel64data               : std_logic_vector(63 downto 0) := (others => '0');
   signal pixel64wordEna            : std_logic_vector(3 downto 0) := (others => '0');
   signal pixel64addr               : std_logic_vector(16 downto 0) := (others => '0');
   signal pixel64filled             : std_logic := '0';
   signal pixel64timeout            : integer range 0 to 15;

   -- shared dividers: edge (4 bits/clk, 10-bit divisor) and gradient (2 bits/clk, 21-bit divisor)
   signal divE_poly_req             : tdiv_req;
   signal divE_line_req             : tdiv_req;
   signal divE_req                  : tdiv_req;
   signal divE_rsp                  : tdiv_rsp;
   signal divG_poly_req             : tdiv_req;
   signal divG_line_req             : tdiv_req;
   signal divG_req                  : tdiv_req;
   signal divG_rsp                  : tdiv_rsp;

   signal slot0_lsb                 : std_logic := '0';
   signal poly_slot0_upd            : std_logic;
   signal poly_slot0_val            : std_logic;
   signal line_slot0_upd            : std_logic;
   signal line_slot0_val            : std_logic;

   -- transfer engine: fill, CPU to VRAM, VRAM to VRAM, VRAM to CPU
   signal copy_requestFifo          : std_logic;
   signal copy_done                 : std_logic;
   signal copy_doneWr               : std_logic;
   signal copy_pixelColor           : std_logic_vector(15 downto 0);
   signal copy_pixelAddr            : unsigned(19 downto 0);
   signal copy_pixelWrite           : std_logic;
   signal copy_fillWrite            : std_logic;
   signal copy_reqVRAMEnable        : std_logic;
   signal copy_reqVRAMXPos          : unsigned(9 downto 0);
   signal copy_reqVRAMYPos          : unsigned(8 downto 0);
   signal copy_reqVRAMSize          : unsigned(10 downto 0);
   signal copy_vramLineAddr         : unsigned(9 downto 0);
   signal copy_Fifo_Dout            : std_logic_vector(31 downto 0);
   signal copy_Fifo_Rd              : std_logic;
   signal copy_Fifo_Empty           : std_logic;
   signal copy_Fifo_ready           : std_logic;

   signal line_requestFifo          : std_logic;
   signal line_done                 : std_logic;
   signal line_pipeline_new         : std_logic;
   signal line_pipeline_transparent : std_logic;
   signal line_pipeline_x           : unsigned(9 downto 0);
   signal line_pipeline_y           : unsigned(8 downto 0);
   signal line_pipeline_cr          : unsigned(7 downto 0);
   signal line_pipeline_cg          : unsigned(7 downto 0);
   signal line_pipeline_cb          : unsigned(7 downto 0);
   signal line_reqVRAMEnable        : std_logic;
   signal line_reqVRAMXPos          : unsigned(9 downto 0);
   signal line_reqVRAMYPos          : unsigned(8 downto 0);
   signal line_reqVRAMSize          : unsigned(10 downto 0);
   signal line_vramLineEna          : std_logic;
   signal line_vramLineAddr         : unsigned(9 downto 0);

   signal rect_requestFifo          : std_logic;
   signal rect_done                 : std_logic;
   signal rect_pipeline_new         : std_logic;
   signal rect_pipeline_texture     : std_logic;
   signal rect_pipeline_transparent : std_logic;
   signal rect_pipeline_rawTexture  : std_logic;
   signal rect_pipeline_x           : unsigned(9 downto 0);
   signal rect_pipeline_y           : unsigned(8 downto 0);
   signal rect_pipeline_cr          : unsigned(7 downto 0);
   signal rect_pipeline_cg          : unsigned(7 downto 0);
   signal rect_pipeline_cb          : unsigned(7 downto 0);
   signal rect_pipeline_u           : unsigned(7 downto 0);
   signal rect_pipeline_v           : unsigned(7 downto 0);
   signal rect_reqVRAMEnable        : std_logic;
   signal rect_reqVRAMXPos          : unsigned(9 downto 0);
   signal rect_reqVRAMYPos          : unsigned(8 downto 0);
   signal rect_reqVRAMSize          : unsigned(10 downto 0);
   signal rect_vramLineEna          : std_logic;
   signal rect_vramLineAddr         : unsigned(9 downto 0);
   signal rect_textPalNew           : std_logic;
   signal rect_textPalX             : unsigned(9 downto 0);
   signal rect_textPalY             : unsigned(8 downto 0);

   signal poly_requestFifo          : std_logic;
   signal poly_done                 : std_logic;
   signal poly_pipeline_new         : std_logic;
   signal poly_pipeline_texture     : std_logic;
   signal poly_pipeline_transparent : std_logic;
   signal poly_pipeline_rawTexture  : std_logic;
   signal poly_pipeline_dithering   : std_logic;
   signal poly_pipeline_x           : unsigned(9 downto 0);
   signal poly_pipeline_y           : unsigned(8 downto 0);
   signal poly_pipeline_cr          : unsigned(7 downto 0);
   signal poly_pipeline_cg          : unsigned(7 downto 0);
   signal poly_pipeline_cb          : unsigned(7 downto 0);
   signal poly_pipeline_u           : unsigned(7 downto 0);
   signal poly_pipeline_v           : unsigned(7 downto 0);
   signal poly_reqVRAMEnable        : std_logic;
   signal poly_reqVRAMXPos          : unsigned(9 downto 0);
   signal poly_reqVRAMYPos          : unsigned(8 downto 0);
   signal poly_reqVRAMSize          : unsigned(10 downto 0);
   signal poly_vramLineEna          : std_logic;
   signal poly_vramLineAddr         : unsigned(9 downto 0);
   signal poly_drawModeRec          : unsigned(11 downto 0);
   signal poly_drawModeNew          : std_logic;
   signal poly_textPalNew           : std_logic;
   signal poly_textPalX             : unsigned(9 downto 0);
   signal poly_textPalY             : unsigned(8 downto 0);

   signal pipeline_pixelColor       : std_logic_vector(15 downto 0);
   signal pipeline_pixelAddr        : unsigned(19 downto 0);
   signal pipeline_pixelWrite       : std_logic;
   signal pipeline_reqVRAMEnable    : std_logic;
   signal pipeline_reqVRAMXPos      : unsigned(9 downto 0);
   signal pipeline_reqVRAMYPos      : unsigned(8 downto 0);
   signal pipeline_reqVRAMSize      : unsigned(10 downto 0);

   signal pipeline_busy             : std_logic;
   signal pipeline_stall            : std_logic;
   signal pipeline_new              : std_logic;
   signal pipeline_texture          : std_logic;
   signal pipeline_transparent      : std_logic;
   signal pipeline_rawTexture       : std_logic;
   signal pipeline_dithering        : std_logic;
   signal pipeline_x                : unsigned(9 downto 0);
   signal pipeline_y                : unsigned(8 downto 0);
   signal pipeline_cr               : unsigned(7 downto 0);
   signal pipeline_cg               : unsigned(7 downto 0);
   signal pipeline_cb               : unsigned(7 downto 0);
   signal pipeline_u                : unsigned(7 downto 0);
   signal pipeline_v                : unsigned(7 downto 0);

   signal pipeline_clearCacheTexture: std_logic := '0';
   signal pipeline_clearCachePalette: std_logic := '0';

   signal pipeline_textPalNew       : std_logic;
   signal pipeline_textPalX         : unsigned(9 downto 0);
   signal pipeline_textPalY         : unsigned(8 downto 0);

   -- FIFO OUT
   signal fifoOut_reset             : std_logic;
   signal fifoOut_Din               : std_logic_vector(84 downto 0);
   signal fifoOut_Wr                : std_logic;
   signal fifoOut_Wr_1              : std_logic;
   signal fifoOut_NearFull          : std_logic;
   signal fifoOut_Dout              : std_logic_vector(84 downto 0);
   signal fifoOut_Rd                : std_logic;
   signal fifoOut_Empty             : std_logic;
   signal fifoOut_idle              : std_logic;

   -- vram access
   type tvramState is
   (
      IDLE,
      READVRAM
   );
   signal vramState : tvramState := IDLE;

   signal VRAMIdle                  : std_logic;
   signal reqVRAMIdle               : std_logic;
   signal reqVRAMDone               : std_logic;
   signal vram_pauseCnt             : integer range 0 to 3;

   signal reqVRAMEnable             : std_logic;
   signal reqVRAMXPos               : unsigned(9 downto 0);
   signal reqVRAMYPos               : unsigned(8 downto 0);
   signal reqVRAMSize               : unsigned(10 downto 0);
   signal reqVRAMremain             : unsigned(7 downto 0);
   signal reqVRAMwait               : unsigned(7 downto 0);
   signal reqVRAMwrap               : unsigned(7 downto 0);
   signal reqVRAMnext               : unsigned(7 downto 0);
   signal reqVRAMaddr               : unsigned(7 downto 0) := (others => '0');
   signal reqVRAMStore              : std_logic := '0';

   signal vramLineAddr              : unsigned(9 downto 0);

   signal vramLineData              : std_logic_vector(15 downto 0);

   -- videoout
   signal videoout_reqVRAMEnable    : std_logic;
   signal videoout_reqVRAMXPos      : unsigned(9 downto 0);
   signal videoout_reqVRAMYPos      : unsigned(8 downto 0);
   signal videoout_reqVRAMSize      : unsigned(10 downto 0);

   signal videoout_ss_out           : tvideoout_ss;

   -- Read size rounded up to whole 4x16-bit words, one word more when an unaligned start spills into it,
   -- clamped to 1024. The spill test is x(1:0) + size > 4.
   function sizeRounded(x : unsigned(1 downto 0); size : unsigned(10 downto 0)) return unsigned is
      variable big, a, b : std_logic;
      variable r         : unsigned(10 downto 0);
   begin
      big := '0';
      if (size(10 downto 2) /= 0) then big := '1'; end if;
      a := size(1) or size(0);
      b := '0';
      case x is
         when "01"   => b := big;
         when "10"   => b := big or (size(1) and size(0));
         when "11"   => b := big or size(1);
         when others => null;
      end case;
      r := size;
      r(10 downto 2) := size(10 downto 2) + ((a and b) & (a xor b));
      if (r > 1024) then r := to_unsigned(1024, 11); end if;
      return r;
   end function;

begin

-- synthesis translate_off
   export_gtm  <= unsigned(videoout_ss_out.nextHCount);
   export_line <= "000" & unsigned(videoout_ss_out.vpos);
   export_gpus <= unsigned(GPUSTAT);
-- synthesis translate_on

   -- removed options and outputs are constants
   Gun1IRQ10   <= '0';
   Gun2IRQ10   <= '0';
   errorLINE   <= '0';
   errorRECT   <= '0';
   errorPOLY   <= '0';
   errorGPU    <= '0';
   errorMASK   <= '0';
   errorFIFO   <= '0';

   SS_DataRead_GPU    <= (others => '0');
   SS_DataRead_Timing <= (others => '0');

   video_fbmode     <= '0';
   video_fb24       <= '0';
   video_frameindex <= x"0";

   gpu_dmaRequest <= GPUSTAT_DMADataRequest;

   GPUSTAT(3 downto 0)     <= GPUSTAT_TextPageX;
   GPUSTAT(4)              <= GPUSTAT_TextPageY;
   GPUSTAT(6 downto 5)     <= GPUSTAT_Transparency;
   GPUSTAT(8 downto 7)     <= GPUSTAT_TextPageColors;
   GPUSTAT(9)              <= GPUSTAT_Dither;
   GPUSTAT(10)             <= GPUSTAT_DrawToDisplay;
   GPUSTAT(11)             <= GPUSTAT_SetMask;
   GPUSTAT(12)             <= GPUSTAT_DrawPixelsMask;
   GPUSTAT(13)             <= not videoout_reports.GPUSTAT_InterlaceField;
   GPUSTAT(14)             <= GPUSTAT_ReverseFlag;
   GPUSTAT(15)             <= GPUSTAT_TextureDisable;
   GPUSTAT(16)             <= GPUSTAT_HorRes2;
   GPUSTAT(18 downto 17)   <= GPUSTAT_HorRes1;
   GPUSTAT(19)             <= GPUSTAT_VerRes;
   GPUSTAT(20)             <= GPUSTAT_PalVideoMode;
   GPUSTAT(21)             <= GPUSTAT_ColorDepth24;
   GPUSTAT(22)             <= GPUSTAT_VertInterlace;
   GPUSTAT(23)             <= GPUSTAT_DisplayDisable;
   GPUSTAT(24)             <= GPUSTAT_IRQRequest;
   GPUSTAT(25)             <= GPUSTAT_DMADataRequest;
   GPUSTAT(26)             <= GPUSTAT_ReadyRecCmd and ((not gpu_dmaRequest) or (not DMA_GPU_waiting));
   GPUSTAT(27)             <= GPUSTAT_ReadySendVRAM;
   GPUSTAT(28)             <= GPUSTAT_ReadyRecDMA;
   GPUSTAT(30 downto 29)   <= GPUSTAT_DMADirection;
   GPUSTAT(31)             <= videoout_reports.GPUSTAT_DrawingOddline;

   GPUSTAT_DMADataRequest <= '0' when (GPUSTAT_DMADirection = "00") else
                             GPUSTAT_ReadyRecDMA when (GPUSTAT_DMADirection = "01") else
                             GPUSTAT_ReadyRecDMA when (GPUSTAT_DMADirection = "10") else
                             not copy_Fifo_Empty; -- GPUSTAT_ReadySendVRAM cannot be used, because data is read earlier

   -- video out
   irq_VBLANK             <= videoout_reports.irq_VBLANK;
   hblank_tmr             <= videoout_reports.hblank_tmr;

   process (clk1x)
      variable cmdNew           : unsigned(7 downto 0);
   begin
      if rising_edge(clk1x) then

         fifoIn_reset  <= '0';
         fifoOut_reset <= '0';

         drawer_reset  <= '0';

         vblank_tmr <= videoout_reports.inVsync;

         if (reset = '1') then

            softReset               <= '1';
            bus_stall               <= '0';

            fifoIn_reset            <= '1';
            fifoOut_reset           <= '1';

            -- power-up defaults of the golden's savestate registers (SS_reset)
            vramRange               <= (others => '0');
            hDisplayRange           <= x"C60260";
            vDisplayRange           <= x"3FC10";

            GPUSTAT_ReverseFlag     <= '0';
            GPUSTAT_HorRes2         <= '0';
            GPUSTAT_HorRes1         <= "00";
            GPUSTAT_VerRes          <= '0';
            GPUSTAT_PalVideoMode    <= '0';
            GPUSTAT_ColorDepth24    <= '0';
            GPUSTAT_VertInterlace   <= '0';
            GPUSTAT_DisplayDisable  <= '0';
            GPUSTAT_IRQRequest      <= '0';
            GPUSTAT_DMADirection    <= "00";
            GPUREAD                 <= (others => '0');

         elsif (ce = '1') then

            bus_dataRead <= (others => '0');
            softReset    <= '0';

            -- bus read
            if (bus_read = '1') then
               if (bus_addr(3 downto 2) = "00") then

                  if (copy_Fifo_Empty = '0') then
                     bus_dataRead <= copy_Fifo_Dout;
                     GPUREAD      <= copy_Fifo_Dout;
                  else
                     bus_dataRead <= GPUREAD;
                  end if;

                  if (copy_Fifo_ready = '0') then
                     bus_stall <= '1';
                  end if;

               elsif (bus_addr(3 downto 2) = "01") then
                  bus_dataRead <= GPUSTAT;
               else
                  bus_dataRead <= x"FFFFFFFF";
               end if;
            end if;

            if (bus_stall = '1' and copy_Fifo_ready = '1') then
               bus_dataRead <= copy_Fifo_Dout;
               GPUREAD      <= copy_Fifo_Dout;
               bus_stall    <= '0';
            end if;

            -- bus write
            if (bus_write = '1') then

               if (bus_addr = 4) then

                  case (to_integer(unsigned(bus_dataWrite(29 downto 24)))) is
                     when 16#00# => -- reset
                        softReset    <= '1';
                        fifoIn_reset <= '1';

                     when 16#01# => -- clear fifo
                        fifoIn_reset <= '1';
                        drawer_reset <= '1';
                        -- todo: must reset drawing units to idle? -> ridge racer triggers that in the middle of a rectangle command clearing the screen
                        -- reset CLUT cache?

                     when 16#02# => -- ack irq
                        GPUSTAT_IRQRequest <= '0';

                     when 16#03# => -- display on/off
                        GPUSTAT_DisplayDisable <= bus_dataWrite(0);

                     when 16#04# => -- DMA direction
                        GPUSTAT_DMADirection <= bus_dataWrite(1 downto 0);

                     when 16#05# => -- Start of Display area (in VRAM)
                        vramRange <= unsigned(bus_dataWrite(18 downto 1)) & '0';

                     when 16#06# => -- horizontal diplay range
                        hDisplayRange <= unsigned(bus_dataWrite(23 downto 0));

                     when 16#07# => -- vertical diplay range
                        vDisplayRange <= unsigned(bus_dataWrite(19 downto 0));

                     when 16#08# => -- Set display mode
                        GPUSTAT_HorRes1       <= bus_dataWrite(1 downto 0);
                        GPUSTAT_VerRes        <= bus_dataWrite(2);
                        GPUSTAT_PalVideoMode  <= bus_dataWrite(3);
                        GPUSTAT_ColorDepth24  <= bus_dataWrite(4);
                        GPUSTAT_VertInterlace <= bus_dataWrite(5);
                        GPUSTAT_HorRes2       <= bus_dataWrite(6);
                        GPUSTAT_ReverseFlag   <= bus_dataWrite(7);

                     when 16#09# => -- Allow texture disable
                        -- todo

                     when 16#10# | 16#11# | 16#12# | 16#13# | 16#14# | 16#15# | 16#16# | 16#17# | 16#18# | 16#19# | 16#1A# | 16#1B# | 16#1C# | 16#1D# | 16#1E# | 16#1F# => -- GPUInfo
                        case (to_integer(unsigned(bus_dataWrite(2 downto 0)))) is
                           when 2 => --Get Texture Window
                              GPUREAD <= x"000" & std_logic_vector(textureWindow);

                           when 3 => --Get Draw Area Top Left
                              GPUREAD <= x"000" & '0' & std_logic_vector(drawingAreaTop) & std_logic_vector(drawingAreaLeft);

                           when 4 => --Get Draw Area Bottom Right
                              GPUREAD <= x"000" & '0' & std_logic_vector(drawingAreaBottom) & std_logic_vector(drawingAreaRight);

                           when 5 => --Get Drawing Offset
                              GPUREAD <= x"00" & "00" & std_logic_vector(drawingOffsetY) & std_logic_vector(drawingOffsetX);

                           when others => null;
                        end case;

                     when others => report "GP1 Command not implemented" severity failure;
                  end case;

               end if;

            end if;

            if (irq_GPU = '1') then
               GPUSTAT_IRQRequest <= '1';
            end if;

            -- softreset
            if (softReset = '1') then
               vramRange              <= (others => '0');
               hDisplayRange          <= x"C60260";
               vDisplayRange          <= x"3FC10";

               GPUSTAT_ReverseFlag    <= '0';
               GPUSTAT_HorRes2        <= '0';
               GPUSTAT_HorRes1        <= "00";
               GPUSTAT_VerRes         <= '0';
               GPUSTAT_PalVideoMode   <= isPal;
               GPUSTAT_ColorDepth24   <= '0';
               GPUSTAT_VertInterlace  <= '0';
               GPUSTAT_DisplayDisable <= '1';
               GPUSTAT_IRQRequest     <= '0';
               GPUSTAT_DMADirection   <= "00";

            end if;

         end if;
      end if;
   end process;

   iSyncFifo_IN: entity mem.SyncFifo
   generic map
   (
      SIZE             => 256, -- as the golden: larger than the real 16 entries for broken homebrew
      DATAWIDTH        => 32,
      NEARFULLDISTANCE => 16
   )
   port map
   (
      clk      => clk2x,
      reset    => fifoIn_reset,
      Din      => fifoIn_Din,
      Wr       => fifoIn_Wr,
      Full     => open,
      NearFull => open,
      Dout     => fifoIn_Dout,
      Rd       => fifoIn_Rd,
      Empty    => fifoIn_Empty
   );

   fifoIn_Rd <= '1' when (ce = '1' and (proc_idle = '1' or proc_requestFifo = '1') and pipeline_busy = '0' and fifoIn_Empty = '0' and fifoIn_Valid = '0') else '0';

   process (clk2x)
   begin
      if rising_edge(clk2x) then

         if (reset = '1') then

         elsif (ce = '1') then

            fifoIn_Wr  <= '0';

            if (clk2xIndex = '1' and bus_write = '1' and bus_addr = 0) then
               fifoIn_Wr  <= '1';
               fifoIn_Din <= bus_dataWrite;
            end if;

            if (clk2xIndex = '1' and DMA_GPU_writeEna = '1') then
               fifoIn_Wr  <= '1';
               fifoIn_Din <= DMA_GPU_write;
            end if;

         end if;

      end if;
   end process;

   process (clk2x)
      variable cmdNew : unsigned(7 downto 0);
   begin
      if rising_edge(clk2x) then

         textureWindow_AND_X     <= not (textureWindow(4 downto 0) & "000");
         textureWindow_AND_Y     <= not (textureWindow(9 downto 5) & "000");
         textureWindow_OR_X      <= (textureWindow(4 downto 0) and textureWindow(14 downto 10)) & "000";
         textureWindow_OR_Y      <= (textureWindow(9 downto 5) and textureWindow(19 downto 15)) & "000";

         if (reset = '1') then

            proc_idle <= '1';

            -- values of the never-written savestate registers
            textureWindow           <= (others => '0');

            drawingAreaLeft         <= (others => '0');
            drawingAreaRight        <= (others => '0');
            drawingAreaTop          <= (others => '0');
            drawingAreaBottom       <= (others => '0');
            drawingOffsetX          <= (others => '0');
            drawingOffsetY          <= (others => '0');

            drawMode                <= (others => '0');

            GPUSTAT_TextPageX       <= (others => '0');
            GPUSTAT_TextPageY       <= '0';
            GPUSTAT_Transparency    <= (others => '0');
            GPUSTAT_TextPageColors  <= (others => '0');
            GPUSTAT_Dither          <= '0';
            GPUSTAT_DrawToDisplay   <= '0';
            GPUSTAT_SetMask         <= '0';
            GPUSTAT_DrawPixelsMask  <= '0';
            GPUSTAT_TextureDisable  <= '0';
            GPUSTAT_ReadyRecCmd     <= '1';
            GPUSTAT_ReadyRecDMA     <= '1';

            fifoIn_Valid            <= '0';

         elsif (ce = '1') then

            fifoIn_Valid <= fifoIn_Rd and not fifoIn_reset;

            pipeline_clearCacheTexture <= '0';
            pipeline_clearCachePalette <= '0';

            if (poly_drawModeNew = '1') then
               drawMode(8 downto 0) <= poly_drawModeRec(8 downto 0);
               drawMode(11)         <= poly_drawModeRec(11);
            end if;

            if (clk2xIndex = '1') then
               irq_GPU <= '0';
            end if;

            if (fifoIn_Valid = '1' and proc_idle = '1') then

               cmdNew := unsigned(fifoIn_Dout(31 downto 24));

               if ((cmdNew >= 16#20# and cmdNew <=16#DF#) or cmdNew = 16#02#) then

                  proc_idle           <= '0';
                  GPUSTAT_ReadyRecCmd <= '0';

               elsif (cmdNew = 16#01#) then -- clear cache
                  pipeline_clearCacheTexture <= '1';
                  pipeline_clearCachePalette <= '1';

               elsif (cmdNew = 16#1F#) then -- irq request
                  if (GPUSTAT_IRQRequest = '0') then
                     irq_GPU <= '1';
                  end if;

               elsif (cmdNew = 16#E1#) then -- Draw Mode setting
                  GPUSTAT_TextPageX      <= fifoIn_Dout(3 downto 0);
                  GPUSTAT_TextPageY      <= fifoIn_Dout(4);
                  GPUSTAT_Transparency   <= fifoIn_Dout(6 downto 5);
                  GPUSTAT_TextPageColors <= fifoIn_Dout(8 downto 7);
                  GPUSTAT_Dither         <= fifoIn_Dout(9);
                  GPUSTAT_DrawToDisplay  <= fifoIn_Dout(10);
                  GPUSTAT_TextureDisable <= fifoIn_Dout(11);
                  drawMode               <= unsigned(fifoIn_Dout(13 downto 0));

               elsif (cmdNew = 16#E2#) then -- Set Texture window
                  textureWindow <= unsigned(fifoIn_Dout(19 downto 0));

               elsif (cmdNew = 16#E3#) then -- Set Drawing Area top left (X1,Y1)
                  drawingAreaLeft <= unsigned(fifoIn_Dout(9 downto 0));
                  drawingAreaTop  <= unsigned(fifoIn_Dout(18 downto 10));

               elsif (cmdNew = 16#E4#) then -- Set Drawing Area bottom right (X2,Y2)
                  drawingAreaRight  <= unsigned(fifoIn_Dout(9 downto 0));
                  drawingAreaBottom <= unsigned(fifoIn_Dout(18 downto 10));

               elsif (cmdNew = 16#E5#) then -- Set Drawing Offset (X,Y)
                  drawingOffsetX <= signed(fifoIn_Dout(10 downto 0));
                  drawingOffsetY <= signed(fifoIn_Dout(21 downto 11));

               elsif (cmdNew = 16#E6#) then -- Mask Bit Setting
                  GPUSTAT_SetMask        <= fifoIn_Dout(0);
                  GPUSTAT_DrawPixelsMask <= fifoIn_Dout(1);

               end if;

            end if;

            if (proc_idle = '1') then
               interlacedDrawing <= GPUSTAT_VertInterlace and GPUSTAT_VerRes and not GPUSTAT_DrawToDisplay;
            end if;

            GPUSTAT_ReadyRecDMA <= fifoIn_Empty;

            if (proc_done = '1') then
-- synthesis translate_off
               export_gobj          <= export_gobj + 1;
-- synthesis translate_on
               proc_idle            <= '1';
               GPUSTAT_ReadyRecCmd  <= '1';
            end if;

            if (copy_doneWr = '1') then
               pipeline_clearCacheTexture <= '1';
            end if;

            if (softReset = '1') then
               proc_idle              <= '1';
               drawMode               <= (others => '0');
               GPUSTAT_TextPageX      <= "0000";
               GPUSTAT_TextPageY      <= '0';
               GPUSTAT_Transparency   <= "00";
               GPUSTAT_TextPageColors <= "00";
               GPUSTAT_Dither         <= '0';
               GPUSTAT_DrawToDisplay  <= '0';
               GPUSTAT_SetMask        <= '0';
               GPUSTAT_DrawPixelsMask <= '0';
               GPUSTAT_TextureDisable <= '0';
               GPUSTAT_ReadyRecCmd    <= '1';
               GPUSTAT_ReadyRecDMA    <= '1';
               drawingAreaLeft        <= (others => '0');
               drawingAreaTop         <= (others => '0');
               drawingAreaRight       <= (others => '0');
               drawingAreaBottom      <= (others => '0');
               drawingOffsetX         <= (others => '0');
               drawingOffsetY         <= (others => '0');
            end if;

         end if;

      end if;
   end process;

   proc_done        <= copy_done        or line_done        or rect_done        or poly_done       ;
   proc_requestFifo <= copy_requestFifo or line_requestFifo or rect_requestFifo or poly_requestFifo;

   pixelStall <= fifoOut_NearFull;

   -- workers
   copy_Fifo_Rd <= '1' when (copy_Fifo_Empty = '0' and clk2xIndex = '0' and DMA_GPU_readEna = '1') else
                   '1' when (copy_Fifo_Empty = '0' and clk2xIndex = '0' and bus_read = '1' and bus_addr(3 downto 2) = "00") else
                   '1' when (copy_Fifo_Empty = '0' and clk2xIndex = '0' and bus_stall = '1') else
                   '0';

   DMA_GPU_read <= copy_Fifo_Dout when (copy_Fifo_Empty = '0') else (others => '1');

   GPUSTAT_ReadySendVRAM <= not copy_Fifo_Empty;

   igpu_copy : entity work.gpu_copy_pocket
   port map
   (
      clk2x                => clk2x,
      ce                   => ce,
      reset                => softreset,
      drawer_reset         => drawer_reset,

      interlacedDrawing    => interlacedDrawing,
      activeLineLSB        => videoout_reports.activeLineLSB,
      DrawPixelsMask       => GPUSTAT_DrawPixelsMask,
      SetMask              => GPUSTAT_SetMask,

      proc_idle            => proc_idle,
      fifo_Valid           => fifoIn_Valid,
      fifo_data            => fifoIn_Dout,
      requestFifo          => copy_requestFifo,
      done                 => copy_done,
      doneWr               => copy_doneWr,

      pipeline_busy        => pipeline_busy,
      fifoOut_idle         => fifoOut_idle,
      pixelEmpty           => fifoOut_Empty,
      pixelStall           => pixelStall,
      pixelColor           => copy_pixelColor,
      pixelAddr            => copy_pixelAddr,
      pixelWrite           => copy_pixelWrite,
      fillWrite            => copy_fillWrite,

      requestVRAMEnable    => copy_reqVRAMEnable,
      requestVRAMXPos      => copy_reqVRAMXPos,
      requestVRAMYPos      => copy_reqVRAMYPos,
      requestVRAMSize      => copy_reqVRAMSize,
      requestVRAMIdle      => reqVRAMIdle,
      requestVRAMDone      => reqVRAMDone,

      vramLineAddr         => copy_vramLineAddr,
      vramLineData         => vramLineData,

      Fifo_Dout            => copy_Fifo_Dout,
      Fifo_Rd              => copy_Fifo_Rd,
      Fifo_Empty           => copy_Fifo_Empty,
      Fifo_ready           => copy_Fifo_ready
   );

   igpu_line : entity work.gpu_line_pocket
   port map
   (
      clk2x                => clk2x,
      clk2xIndex           => clk2xIndex,
      ce                   => ce,
      reset                => softreset,

      REPRODUCIBLEGPUTIMING=> '0',

      error                => open,

      DrawPixelsMask       => GPUSTAT_DrawPixelsMask,
      interlacedDrawing    => interlacedDrawing,
      activeLineLSB        => videoout_reports.activeLineLSB,
      drawingOffsetX       => drawingOffsetX,
      drawingOffsetY       => drawingOffsetY,
      drawingAreaLeft      => drawingAreaLeft,
      drawingAreaRight     => drawingAreaRight,
      drawingAreaTop       => drawingAreaTop,
      drawingAreaBottom    => drawingAreaBottom,

      divE_req             => divE_line_req,
      divE_rsp             => divE_rsp,
      divG_req             => divG_line_req,
      divG_rsp             => divG_rsp,
      slot0_upd            => line_slot0_upd,
      slot0_val            => line_slot0_val,

      fifoOut_idle         => fifoOut_idle,
      pipeline_busy        => pipeline_busy,
      pipeline_stall       => pipeline_stall,
      pipeline_new         => line_pipeline_new,
      pipeline_transparent => line_pipeline_transparent,
      pipeline_x           => line_pipeline_x,
      pipeline_y           => line_pipeline_y,
      pipeline_cr          => line_pipeline_cr,
      pipeline_cg          => line_pipeline_cg,
      pipeline_cb          => line_pipeline_cb,

      proc_idle            => proc_idle,
      fifo_Valid           => fifoIn_Valid,
      fifo_data            => fifoIn_Dout,
      requestFifo          => line_requestFifo,
      done                 => line_done,
      CmdDone              => open,

      requestVRAMEnable    => line_reqVRAMEnable,
      requestVRAMXPos      => line_reqVRAMXPos,
      requestVRAMYPos      => line_reqVRAMYPos,
      requestVRAMSize      => line_reqVRAMSize,
      requestVRAMIdle      => reqVRAMIdle,
      requestVRAMDone      => reqVRAMDone,

      vramLineEna          => line_vramLineEna,
      vramLineAddr         => line_vramLineAddr
   );

   igpu_rect : entity work.gpu_rect_pocket
   port map
   (
      clk2x                => clk2x,
      ce                   => ce,
      reset                => softreset,

      DrawPixelsMask       => GPUSTAT_DrawPixelsMask,
      interlacedDrawing    => interlacedDrawing,
      activeLineLSB        => videoout_reports.activeLineLSB,
      drawingOffsetX       => drawingOffsetX,
      drawingOffsetY       => drawingOffsetY,
      drawingAreaLeft      => drawingAreaLeft,
      drawingAreaRight     => drawingAreaRight,
      drawingAreaTop       => drawingAreaTop,
      drawingAreaBottom    => drawingAreaBottom,

      fifoOut_idle         => fifoOut_idle,
      pipeline_busy        => pipeline_busy,
      pipeline_stall       => pipeline_stall,
      pipeline_new         => rect_pipeline_new,
      pipeline_texture     => rect_pipeline_texture,
      pipeline_transparent => rect_pipeline_transparent,
      pipeline_rawTexture  => rect_pipeline_rawTexture,
      pipeline_x           => rect_pipeline_x,
      pipeline_y           => rect_pipeline_y,
      pipeline_cr          => rect_pipeline_cr,
      pipeline_cg          => rect_pipeline_cg,
      pipeline_cb          => rect_pipeline_cb,
      pipeline_u           => rect_pipeline_u,
      pipeline_v           => rect_pipeline_v,

      proc_idle            => proc_idle,
      fifo_Valid           => fifoIn_Valid,
      fifo_data            => fifoIn_Dout,
      requestFifo          => rect_requestFifo,
      done                 => rect_done,

      requestVRAMEnable    => rect_reqVRAMEnable,
      requestVRAMXPos      => rect_reqVRAMXPos,
      requestVRAMYPos      => rect_reqVRAMYPos,
      requestVRAMSize      => rect_reqVRAMSize,
      requestVRAMIdle      => reqVRAMIdle,
      requestVRAMDone      => reqVRAMDone,

      textPalNew           => rect_textPalNew,
      textPalX             => rect_textPalX,
      textPalY             => rect_textPalY,

      vramLineEna          => rect_vramLineEna,
      vramLineAddr         => rect_vramLineAddr
   );

   igpu_poly : entity work.gpu_poly_pocket
   port map
   (
      clk2x                => clk2x,
      clk2xIndex           => clk2xIndex,
      ce                   => ce,
      reset                => softreset,

      REPRODUCIBLEGPUTIMING=> '0',
      textureFilter        => "00",
      textureFilterStrength=> "00",
      textureFilter2DOff   => '0',

      error                => open,

      DrawPixelsMask       => GPUSTAT_DrawPixelsMask,
      interlacedDrawing    => interlacedDrawing,
      activeLineLSB        => videoout_reports.activeLineLSB,
      drawingOffsetX       => drawingOffsetX,
      drawingOffsetY       => drawingOffsetY,
      drawingAreaLeft      => drawingAreaLeft,
      drawingAreaRight     => drawingAreaRight,
      drawingAreaTop       => drawingAreaTop,
      drawingAreaBottom    => drawingAreaBottom,

      drawModeRec          => poly_drawModeRec,
      drawModeNew          => poly_drawModeNew,
      drawmode_dithering   => drawMode(9),

      divE_req             => divE_poly_req,
      divE_rsp             => divE_rsp,
      divG_req             => divG_poly_req,
      divG_rsp             => divG_rsp,
      slot0_prev           => slot0_lsb,
      slot0_upd            => poly_slot0_upd,
      slot0_val            => poly_slot0_val,

      fifoOut_idle         => fifoOut_idle,
      pipeline_busy        => pipeline_busy,
      pipeline_stall       => pipeline_stall,
      pipeline_new         => poly_pipeline_new,
      pipeline_texture     => poly_pipeline_texture,
      pipeline_transparent => poly_pipeline_transparent,
      pipeline_rawTexture  => poly_pipeline_rawTexture,
      pipeline_dithering   => poly_pipeline_dithering,
      pipeline_x           => poly_pipeline_x,
      pipeline_y           => poly_pipeline_y,
      pipeline_cr          => poly_pipeline_cr,
      pipeline_cg          => poly_pipeline_cg,
      pipeline_cb          => poly_pipeline_cb,
      pipeline_u           => poly_pipeline_u,
      pipeline_v           => poly_pipeline_v,
      pipeline_filter      => open,
      pipeline_u11         => open,
      pipeline_v11         => open,
      pipeline_uAcc        => open,
      pipeline_vAcc        => open,

      proc_idle            => proc_idle,
      fifo_Valid           => fifoIn_Valid,
      fifo_data            => fifoIn_Dout,
      requestFifo          => poly_requestFifo,
      done                 => poly_done,
      CmdDone              => open,

      requestVRAMEnable    => poly_reqVRAMEnable,
      requestVRAMXPos      => poly_reqVRAMXPos,
      requestVRAMYPos      => poly_reqVRAMYPos,
      requestVRAMSize      => poly_reqVRAMSize,
      requestVRAMIdle      => reqVRAMIdle,
      requestVRAMDone      => reqVRAMDone,

      textPalNew           => poly_textPalNew,
      textPalX             => poly_textPalX,
      textPalY             => poly_textPalY,

      vramLineEna          => poly_vramLineEna,
      vramLineAddr         => poly_vramLineAddr
   );

   pipeline_new         <= line_pipeline_new         or rect_pipeline_new         or poly_pipeline_new        ;
   pipeline_texture     <= '0'                       or rect_pipeline_texture     or poly_pipeline_texture    ;
   pipeline_transparent <= line_pipeline_transparent or rect_pipeline_transparent or poly_pipeline_transparent;
   pipeline_rawTexture  <= '0'                       or rect_pipeline_rawTexture  or poly_pipeline_rawTexture ;
   pipeline_dithering   <= (line_pipeline_new        or '0'                       or poly_pipeline_dithering  ) and drawMode(9) and (not ditherOff);
   pipeline_x           <= line_pipeline_x           or rect_pipeline_x           or poly_pipeline_x          ;
   pipeline_y           <= line_pipeline_y           or rect_pipeline_y           or poly_pipeline_y          ;
   pipeline_cr          <= line_pipeline_cr          or rect_pipeline_cr          or poly_pipeline_cr         ;
   pipeline_cg          <= line_pipeline_cg          or rect_pipeline_cg          or poly_pipeline_cg         ;
   pipeline_cb          <= line_pipeline_cb          or rect_pipeline_cb          or poly_pipeline_cb         ;

   pipeline_u           <= ((rect_pipeline_u or poly_pipeline_u) and textureWindow_AND_X) or textureWindow_OR_X;
   pipeline_v           <= ((rect_pipeline_v or poly_pipeline_v) and textureWindow_AND_Y) or textureWindow_OR_Y;

   pipeline_textPalNew  <= rect_textPalNew or poly_textPalNew;
   pipeline_textPalX    <= rect_textPalX   or poly_textPalX  ;
   pipeline_textPalY    <= rect_textPalY   or poly_textPalY  ;

   -- texture filter off: the pipeline's filter inputs are constants
   igpu_pixelpipeline : entity work.gpu_pixelpipeline
   port map
   (
      clk2x                => clk2x,
      clk2xIndex           => clk2xIndex,
      ce                   => ce,
      reset                => softreset,

      noTexture            => noTexture,
      render24             => '0',
      drawSlow             => '0',

      oldGPU               => '0',

      drawMode_in          => drawMode,
      DrawPixelsMask_in    => GPUSTAT_DrawPixelsMask,
      SetMask_in           => GPUSTAT_SetMask,

      clearCacheTexture    => pipeline_clearCacheTexture,
      clearCachePalette    => pipeline_clearCachePalette,

      fifoOut_idle         => fifoOut_idle,
      pipeline_busy        => pipeline_busy,
      pipeline_stall       => pipeline_stall,
      pipeline_new         => pipeline_new,
      pipeline_texture     => pipeline_texture,
      pipeline_transparent => pipeline_transparent,
      pipeline_rawTexture  => pipeline_rawTexture,
      pipeline_dithering   => pipeline_dithering,
      pipeline_x           => pipeline_x,
      pipeline_y           => pipeline_y,
      pipeline_cr          => pipeline_cr,
      pipeline_cg          => pipeline_cg,
      pipeline_cb          => pipeline_cb,
      pipeline_u           => pipeline_u,
      pipeline_v           => pipeline_v,
      pipeline_filter      => '0',
      pipeline_u11         => (others => '0'),
      pipeline_v11         => (others => '0'),
      pipeline_uAcc        => (others => '0'),
      pipeline_vAcc        => (others => '0'),

      requestVRAMEnable    => pipeline_reqVRAMEnable,
      requestVRAMXPos      => pipeline_reqVRAMXPos,
      requestVRAMYPos      => pipeline_reqVRAMYPos,
      requestVRAMSize      => pipeline_reqVRAMSize,
      requestVRAMIdle      => reqVRAMIdle,
      requestVRAMDone      => reqVRAMDone,
      vram_DOUT            => vram_DOUT,
      vram_DOUT_READY      => vram_DOUT_READY,

      vramLineData         => vramLineData,
      vramLineData2        => (others => '0'),

      textPalInNew         => pipeline_textPalNew,
      textPalInX           => pipeline_textPalX,
      textPalInY           => pipeline_textPalY,

      pixelStall           => pixelStall,
      pixelColor           => pipeline_pixelColor,
      pixelColor2          => open,
      pixelAddr            => pipeline_pixelAddr,
      pixelWrite           => pipeline_pixelWrite
   );

   -- polygon and line unit never divide at the same time: requests are OR-combined, idle requesters drive zeros
   divE_req <= div_or(divE_poly_req, divE_line_req);
   divG_req <= div_or(divG_poly_req, divG_line_req);

   idivE : entity work.gpu_pocket_div
   generic map
   (
      G_BITS_PER_CYCLE => 4,
      G_DIVISOR_BITS   => 10,
      G_DIVIDEND_BITS  => 43
   )
   port map
   (
      clk => clk2x,
      req => divE_req,
      rsp => divE_rsp
   );

   idivG : entity work.gpu_pocket_div
   generic map
   (
      G_BITS_PER_CYCLE => 2,
      G_DIVISOR_BITS   => 21,
      G_DIVIDEND_BITS  => 31
   )
   port map
   (
      clk => clk2x,
      req => divG_req,
      rsp => divG_rsp
   );

   -- bit 0 of the last quotient on the golden's divider slot 0; never reset (docs/pocket/GPU.md, "Stale quotient bit")
   process (clk2x)
   begin
      if rising_edge(clk2x) then
         if (poly_slot0_upd = '1') then
            slot0_lsb <= poly_slot0_val;
         end if;
         if (line_slot0_upd = '1') then
            slot0_lsb <= line_slot0_val;
         end if;
      end if;
   end process;

   pixelColor  <= copy_pixelColor or pipeline_pixelColor;
   pixelAddr   <= copy_pixelAddr  or pipeline_pixelAddr ;
   pixelWrite  <= copy_pixelWrite or pipeline_pixelWrite;

   -- pixel writing fifo: 64bit data + 17 bit address + 4bit word enable
   iSyncFifo_OUT: entity mem.SyncFifoFallThrough
   generic map
   (
      SIZE             => 256,
      DATAWIDTH        => 64 + 17 + 4,
      NEARFULLDISTANCE => 250
   )
   port map
   (
      clk      => clk2x,
      reset    => fifoOut_reset,
      Din      => fifoOut_Din,
      Wr       => fifoOut_Wr,
      Full     => open,
      NearFull => fifoOut_NearFull,
      Dout     => fifoOut_Dout,
      Rd       => fifoOut_Rd,
      Empty    => fifoOut_Empty
   );

   process (clk2x)
   begin
      if rising_edge(clk2x) then

         fifoOut_Wr_1 <= fifoOut_Wr;

         fifoOut_Wr   <= '0';
         fifoOut_Din  <= pixel64wordEna & pixel64Addr & pixel64data;

         if (reset = '1') then

            pixel64filled <= '0';

         elsif (ce = '1') then

            if (copy_fillWrite = '1') then

               fifoOut_Wr    <= '1';
               fifoOut_Din   <=  "1111" & std_logic_vector(copy_pixelAddr(19 downto 3)) & copy_pixelColor & copy_pixelColor & copy_pixelColor & copy_pixelColor;
               pixel64filled <= '0';

            elsif (pixelWrite = '1') then

               pixel64timeout <= 15;

               if (pixel64filled = '0' or pixelAddr(19 downto 3) /= unsigned(pixel64Addr)) then

                  fifoOut_Wr <= pixel64filled;

                  pixel64Addr <= std_logic_vector(pixelAddr(19 downto 3));
                  case (pixelAddr(2 downto 1)) is
                     when "00" => pixel64data(15 downto  0) <= pixelColor; pixel64wordEna <= "0001";
                     when "01" => pixel64data(31 downto 16) <= pixelColor; pixel64wordEna <= "0010";
                     when "10" => pixel64data(47 downto 32) <= pixelColor; pixel64wordEna <= "0100";
                     when "11" => pixel64data(63 downto 48) <= pixelColor; pixel64wordEna <= "1000";
                     when others => null;
                  end case;

                  pixel64filled <= '1';

               else

                  case (pixelAddr(2 downto 1)) is
                     when "00" => pixel64data(15 downto  0) <= pixelColor; pixel64wordEna(0) <= '1';
                     when "01" => pixel64data(31 downto 16) <= pixelColor; pixel64wordEna(1) <= '1';
                     when "10" => pixel64data(47 downto 32) <= pixelColor; pixel64wordEna(2) <= '1';
                     when "11" => pixel64data(63 downto 48) <= pixelColor; pixel64wordEna(3) <= '1';
                     when others => null;
                  end case;

               end if;

            elsif (pixel64timeout > 0) then

               pixel64timeout <= pixel64timeout - 1;
               if (pixel64timeout = 1 or pipeline_busy = '0') then
                  pixel64filled  <= '0';
                  fifoOut_Wr     <= '1';
                  pixel64timeout <= 0;
               end if;

            end if;

         end if;

      end if;
   end process;

   fifoOut_Rd <= '1' when (ce = '1' and vramState = IDLE and (vram_WE = '0' or vram_BUSY = '0') and fifoOut_Empty = '0' and reqVRAMEnable = '0' and vram_pause = '0') else '0';

   fifoOut_idle <= '1' when (fifoOut_Empty = '1' and fifoOut_Wr = '0' and fifoOut_Wr_1 = '0' and pixel64filled = '0') else '0';

   VRAMIdle    <= '1' when (vramState = IDLE and (vram_WE = '0' or vram_BUSY = '0')) else '0';
   reqVRAMIdle <= VRAMIdle and (not videoout_reqVRAMEnable) and (not vram_pause);

   reqVRAMEnable <= copy_reqVRAMEnable or line_reqVRAMEnable or rect_reqVRAMEnable or poly_reqVRAMEnable or pipeline_reqVRAMEnable or videoout_reqVRAMEnable;
   reqVRAMXPos   <= copy_reqVRAMXPos        or line_reqVRAMXPos   or rect_reqVRAMXPos   or poly_reqVRAMXPos   or pipeline_reqVRAMXPos   or videoout_reqVRAMXPos  ;
   reqVRAMYPos   <= copy_reqVRAMYPos        or line_reqVRAMYPos   or rect_reqVRAMYPos   or poly_reqVRAMYPos   or pipeline_reqVRAMYPos   or videoout_reqVRAMYPos  ;
   reqVRAMSize   <= copy_reqVRAMSize        or line_reqVRAMSize   or rect_reqVRAMSize   or poly_reqVRAMSize   or pipeline_reqVRAMSize   or videoout_reqVRAMSize  ;

   -- every unit drives zero while its enable is low, and at most one is enabled
   vramLineAddr  <= copy_vramLineAddr or line_vramLineAddr or rect_vramLineAddr or poly_vramLineAddr;

   -- vram access
   process (clk2x)
      variable reqVRAMSizeRounded : unsigned(10 downto 0);
      variable reqVRAMWrapSum     : unsigned(10 downto 0);
   begin
      if rising_edge(clk2x) then

         if (vram_BUSY = '0') then
            vram_WE <= '0';
            vram_RD <= '0';
         end if;

         vram_paused <= '0';
         if (VRAMIdle = '1' and vram_pause = '1' and vram_WE = '0') then
            if (vram_pauseCnt = 3) then
               vram_paused <= '1';
            else
               vram_pauseCnt <= vram_pauseCnt + 1;
            end if;
         else
            vram_pauseCnt <= 0;
         end if;

         if (reset = '1') then

            vramState   <= IDLE;
            reqVRAMDone <= '0';

         else

            reqVRAMDone <= '0';

            case (vramState) is
               when IDLE =>
                  if ((ce = '1' or videoout_reqVRAMEnable = '1') and (vram_WE = '0' or vram_BUSY = '0') and vram_pause = '0') then
                     if (reqVRAMEnable = '1') then
                        reqVRAMStore  <= (not pipeline_reqVRAMEnable) and (not videoout_reqVRAMEnable);
                        reqVRAMSizeRounded := sizeRounded(reqVRAMXPos(1 downto 0), reqVRAMSize);
                        vramState     <= READVRAM;
                        vram_ADDR     <= x"00" & std_logic_vector(reqVRAMYPos) & std_logic_vector(reqVRAMXPos(9 downto 2)) & "000";
                        vram_RD       <= '1';
                        reqVRAMaddr   <= reqVRAMXPos(9 downto 2);
                        if (reqVRAMSizeRounded > 512) then
                           vram_BURSTCNT  <= x"80";
                           reqVRAMremain  <= x"80" - 1;
                           reqVRAMnext    <= resize((reqVRAMSizeRounded - 512) / 4, 8);
                        else
                           vram_BURSTCNT  <= std_logic_vector(reqVRAMSizeRounded(9 downto 2));
                           reqVRAMremain  <= reqVRAMSizeRounded(9 downto 2) - 1;
                           reqVRAMnext    <= (others => '0');
                        end if;
                        reqVRAMwrap <= (others => '0');
                        if (copy_reqVRAMEnable = '1') then
                           -- sum <= 2047: sum > 1024 and sum(9:2) = (sum - 1024) / 4
                           reqVRAMWrapSum := resize(reqVRAMXPos, 11) + reqVRAMSizeRounded;
                           if (reqVRAMWrapSum(10) = '1' and reqVRAMWrapSum(9 downto 0) /= 0) then
                              reqVRAMwrap <= reqVRAMWrapSum(9 downto 2);
                           end if;
                        end if;
                     elsif (fifoOut_Empty = '0') then
                        vram_WE         <= '1';
                        vram_ADDR       <= x"00" & fifoOut_Dout(80 downto 64) & "000";
                        vram_BE         <= fifoOut_Dout(84) & fifoOut_Dout(84) & fifoOut_Dout(83) & fifoOut_Dout(83) & fifoOut_Dout(82) & fifoOut_Dout(82) & fifoOut_Dout(81) & fifoOut_Dout(81);
                        vram_DIN        <= fifoOut_Dout(63 downto 0);
                        vram_BURSTCNT   <= x"01";
                     end if;
                  end if;

               when READVRAM =>
                  if (vram_DOUT_READY = '1') then
                     reqVRAMaddr <= reqVRAMaddr + 1;
                     if (reqVRAMremain > 0) then
                        reqVRAMremain <= reqVRAMremain - 1;
                     else
                        if (reqVRAMnext > 0) then
                           vram_ADDR(10)  <= '1';
                           vram_RD        <= '1';
                           vram_BURSTCNT  <= std_logic_vector(reqVRAMnext);
                           reqVRAMnext    <= (others => '0');
                           reqVRAMremain  <= (reqVRAMnext - 1);
                        elsif (reqVRAMwrap > 0) then
                           vram_ADDR(10 downto 0) <= (others => '0');
                           vram_RD        <= '1';
                           vram_BURSTCNT  <= std_logic_vector(reqVRAMwrap);
                           reqVRAMwrap    <= (others => '0');
                           reqVRAMaddr    <= (others => '0');
                           reqVRAMremain  <= (reqVRAMwrap - 1);
                           if (reqVRAMwrap > 128) then
                              vram_BURSTCNT  <= x"80";
                              reqVRAMremain  <= x"80" - 1;
                              reqVRAMnext    <= reqVRAMwrap - 128;
                           end if;
                        else
                           vramState   <= IDLE;
                           reqVRAMDone <= '1';
                        end if;
                     end if;
                  end if;

            end case;

         end if;

      end if;
   end process;

   ilineram: entity mem.dpram_dif
   generic map
   (
      addr_width_a  => 8,
      data_width_a  => 64,
      addr_width_b  => 10,
      data_width_b  => 16
   )
   port map
   (
      clock_a     => clk2x,
      address_a   => std_logic_vector(reqVRAMaddr),
      data_a      => vram_DOUT,
      wren_a      => (vram_DOUT_READY and reqVRAMStore),

      clock_b     => clk2x,
      address_b   => std_logic_vector(vramLineAddr),
      data_b      => x"0000",
      wren_b      => '0',
      q_b         => vramLineData
   );

--##############################################################
--############################### video out
--##############################################################

   videoout_settings.GPUSTAT_VerRes          <= GPUSTAT_VerRes;
   videoout_settings.GPUSTAT_PalVideoMode    <= GPUSTAT_PalVideoMode;
   videoout_settings.GPUSTAT_VertInterlace   <= GPUSTAT_VertInterlace;
   videoout_settings.GPUSTAT_HorRes2         <= GPUSTAT_HorRes2;
   videoout_settings.GPUSTAT_HorRes1         <= GPUSTAT_HorRes1;
   videoout_settings.GPUSTAT_ColorDepth24    <= GPUSTAT_ColorDepth24;
   videoout_settings.GPUSTAT_DisplayDisable  <= GPUSTAT_DisplayDisable;
   videoout_settings.vramRange               <= vramRange;
   videoout_settings.hDisplayRange           <= hDisplayRange;
   videoout_settings.vDisplayRange           <= vDisplayRange;
   videoout_settings.pal60                   <= pal60;
   videoout_settings.syncInterlace           <= syncInterlace;
   videoout_settings.rotate180               <= '0';
   videoout_settings.fixedVBlank             <= fixedVBlank;
   videoout_settings.vCrop                   <= "00";
   videoout_settings.hCrop                   <= '0';
   videoout_settings.dither24                <= '0';
   videoout_settings.render24                <= '0';

   allowunpause <= '1';

   igpu_videoout : entity work.gpu_videoout_pocket
   port map
   (
      clk1x                      => clk1x,
      clk2x                      => clk2x,
      clkvid                     => clkvid,
      ce                         => ce,
      reset                      => reset,
      softReset                  => softReset,

      videoout_settings          => videoout_settings,
      videoout_reports           => videoout_reports,

      videoout_on                => videoout_on,

      requestVRAMEnable          => videoout_reqVRAMEnable,
      requestVRAMXPos            => videoout_reqVRAMXPos,
      requestVRAMYPos            => videoout_reqVRAMYPos,
      requestVRAMSize            => videoout_reqVRAMSize,
      requestVRAMIdle            => VRAMIdle and (not vram_pause),
      requestVRAMDone            => reqVRAMDone,

      vram_DOUT                  => vram_DOUT,
      vram_DOUT_READY            => vram_DOUT_READY,

      videoout_out               => videoout_out,

      videoout_ss_out            => videoout_ss_out
   );

   video_hsync          <= videoout_out.hsync;
   video_vsync          <= videoout_out.vsync;
   video_hblank         <= videoout_out.hblank;
   video_vblank         <= videoout_out.vblank;
   video_DisplayOffsetX <= videoout_out.DisplayOffsetX;
   video_DisplayOffsetY <= videoout_out.DisplayOffsetY;
   video_DisplayWidth   <= videoout_out.DisplayWidthReal;
   video_DisplayHeight  <= videoout_out.DisplayHeightReal;
   video_ce             <= videoout_out.ce;
   video_interlace      <= videoout_out.interlace;
   video_r              <= videoout_out.r;
   video_g              <= videoout_out.g;
   video_b              <= videoout_out.b;
   video_isPal          <= videoout_out.isPal;
   video_hResMode       <= videoout_out.hResMode;

   dotclock             <= videoout_reports.dotclock;

--##############################################################
--############################### savestate idle
--##############################################################

   -- psx_top waits for SS_Idle before it pauses ce
   process (clk1x)
   begin
      if (rising_edge(clk1x)) then
         SS_Idle <= '0';
         if (proc_idle = '1' and fifoIn_Empty = '1' and fifoOut_Empty = '1' and vramState = IDLE and pipeline_busy = '0' and fifoOut_Wr = '0' and pixelWrite = '0') then
            SS_Idle <= '1';
         end if;
      end if;
   end process;

end architecture;
