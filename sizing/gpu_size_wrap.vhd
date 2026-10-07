-- Sizing-only wrapper: gpu with every port registered in its own clock domain (bus and DMA on
-- clk1x, VRAM on clk2x, video on clkvid) and options tied as in psx_min_wrap.vhd.
-- Not a functional top level. Gate metric and results: docs/pocket/GPU.md.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gpu_size_wrap is
   generic
   (
      G_POCKET : boolean := false -- true: gpu_pocket instead of gpu
   );
   port
   (
      clk1x, clk2x, clkvid : in  std_logic;
      i_ce, i_reset        : in  std_logic;
      i_isPal              : in  std_logic;
      i_bus_addr           : in  unsigned(3 downto 0);
      i_bus_dataWrite      : in  std_logic_vector(31 downto 0);
      i_bus_read           : in  std_logic;
      i_bus_write          : in  std_logic;
      o_bus_dataRead       : out std_logic_vector(31 downto 0);
      o_bus_stall          : out std_logic;
      i_dmaOn              : in  std_logic;
      o_dmaRequest         : out std_logic;
      i_DMA_waiting        : in  std_logic;
      i_DMA_writeEna       : in  std_logic;
      i_DMA_readEna        : in  std_logic;
      i_DMA_write          : in  std_logic_vector(31 downto 0);
      o_DMA_read           : out std_logic_vector(31 downto 0);
      o_irq_VBLANK         : out std_logic;
      o_irq_GPU            : out std_logic;
      i_vram_pause         : in  std_logic;
      o_vram_paused        : out std_logic;
      i_vram_BUSY          : in  std_logic;
      i_vram_DOUT          : in  std_logic_vector(63 downto 0);
      i_vram_DOUT_READY    : in  std_logic;
      o_vram_BURSTCNT      : out std_logic_vector(7 downto 0);
      o_vram_ADDR          : out std_logic_vector(27 downto 0);
      o_vram_DIN           : out std_logic_vector(63 downto 0);
      o_vram_BE            : out std_logic_vector(7 downto 0);
      o_vram_WE            : out std_logic;
      o_vram_RD            : out std_logic;
      o_hblank_tmr         : out std_logic;
      o_vblank_tmr         : out std_logic;
      o_dotclock           : out std_logic;
      o_video_hsync        : out std_logic;
      o_video_vsync        : out std_logic;
      o_video_hblank       : out std_logic;
      o_video_vblank       : out std_logic;
      o_video_ce           : out std_logic;
      o_video_interlace    : out std_logic;
      o_video_r            : out std_logic_vector(7 downto 0);
      o_video_g            : out std_logic_vector(7 downto 0);
      o_video_b            : out std_logic_vector(7 downto 0);
      o_video_misc         : out std_logic_vector(63 downto 0)
   );
end entity;

architecture arch of gpu_size_wrap is

   signal ce, reset, isPal, bus_read, bus_write, dmaOn, DMA_waiting, DMA_writeEna, DMA_readEna : std_logic := '0';
   signal bus_addr                         : unsigned(3 downto 0) := (others => '0');
   signal bus_dataWrite, DMA_write         : std_logic_vector(31 downto 0) := (others => '0');
   signal bus_dataRead, DMA_read           : std_logic_vector(31 downto 0);
   signal bus_stall, dmaRequest, irq_VBLANK, irq_GPU, hblank_tmr, vblank_tmr, dotclock : std_logic;
   signal vram_pause, vram_BUSY, vram_DOUT_READY : std_logic := '0';
   signal vram_DOUT                        : std_logic_vector(63 downto 0) := (others => '0');
   signal vram_paused, vram_WE, vram_RD    : std_logic;
   signal vram_BURSTCNT, vram_BE           : std_logic_vector(7 downto 0);
   signal vram_ADDR                        : std_logic_vector(27 downto 0);
   signal vram_DIN                         : std_logic_vector(63 downto 0);
   signal video_hsync, video_vsync, video_hblank, video_vblank, video_ce, video_interlace : std_logic;
   signal video_r, video_g, video_b        : std_logic_vector(7 downto 0);
   signal video_DisplayWidth               : unsigned(10 downto 0);
   signal video_DisplayHeight              : unsigned(9 downto 0);
   signal video_DisplayOffsetX             : unsigned(9 downto 0);
   signal video_DisplayOffsetY             : unsigned(8 downto 0);
   signal video_isPal, video_fbmode, video_fb24 : std_logic;
   signal video_hResMode                   : std_logic_vector(2 downto 0);
   signal video_frameindex                 : std_logic_vector(3 downto 0);

   -- declared here so the gpu_golden revision, which has no gpu_pocket files, still analyses
   component gpu_pocket
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
   end component;

   signal clk1xToggle, clk1xToggle2x, clk2xIndex : std_logic := '0';

begin

   -- clk2xIndex as psx_top derives it (psx_top.vhd:695-710)
   process (clk1x) begin
      if rising_edge(clk1x) then clk1xToggle <= not clk1xToggle; end if;
   end process;
   process (clk2x) begin
      if rising_edge(clk2x) then
         clk1xToggle2x <= clk1xToggle;
         clk2xIndex    <= '0';
         if (clk1xToggle2x = clk1xToggle) then clk2xIndex <= '1'; end if;
      end if;
   end process;

   process (clk1x) begin
      if rising_edge(clk1x) then
         ce <= i_ce; reset <= i_reset; isPal <= i_isPal;
         bus_addr <= i_bus_addr; bus_dataWrite <= i_bus_dataWrite; bus_read <= i_bus_read; bus_write <= i_bus_write;
         dmaOn <= i_dmaOn; DMA_waiting <= i_DMA_waiting; DMA_writeEna <= i_DMA_writeEna; DMA_readEna <= i_DMA_readEna;
         DMA_write <= i_DMA_write;
         o_bus_dataRead <= bus_dataRead; o_bus_stall <= bus_stall; o_dmaRequest <= dmaRequest; o_DMA_read <= DMA_read;
         o_irq_VBLANK <= irq_VBLANK; o_irq_GPU <= irq_GPU; o_hblank_tmr <= hblank_tmr; o_vblank_tmr <= vblank_tmr;
         o_dotclock <= dotclock;
      end if;
   end process;

   process (clk2x) begin
      if rising_edge(clk2x) then
         vram_pause <= i_vram_pause; vram_BUSY <= i_vram_BUSY; vram_DOUT <= i_vram_DOUT; vram_DOUT_READY <= i_vram_DOUT_READY;
         o_vram_paused <= vram_paused; o_vram_BURSTCNT <= vram_BURSTCNT; o_vram_ADDR <= vram_ADDR; o_vram_DIN <= vram_DIN;
         o_vram_BE <= vram_BE; o_vram_WE <= vram_WE; o_vram_RD <= vram_RD;
      end if;
   end process;

   process (clkvid) begin
      if rising_edge(clkvid) then
         o_video_hsync <= video_hsync; o_video_vsync <= video_vsync; o_video_hblank <= video_hblank;
         o_video_vblank <= video_vblank; o_video_ce <= video_ce; o_video_interlace <= video_interlace;
         o_video_r <= video_r; o_video_g <= video_g; o_video_b <= video_b;
         o_video_misc <= std_logic_vector(video_DisplayWidth) & std_logic_vector(video_DisplayHeight) &
                         std_logic_vector(video_DisplayOffsetX) & std_logic_vector(video_DisplayOffsetY) &
                         video_isPal & video_fbmode & video_fb24 & video_hResMode & video_frameindex &
                         "00000000000000";
      end if;
   end process;

   ggolden : if not G_POCKET generate
   begin

      igpu : entity work.gpu
      port map
      (
         clk1x => clk1x, clk2x => clk2x, clk2xIndex => clk2xIndex, clkvid => clkvid, ce => ce, reset => reset,
         allowunpause => open, savestate_busy => '0', system_paused => '0',
         -- options as tied in psx_min_wrap.vhd:97-131
         ditherOff => '0', interlaced480pHack => '0', REPRODUCIBLEGPUTIMING => '0', videoout_on => '1',
         isPal => isPal, pal60 => '0', fpscountOn => '0', noTexture => '0',
         textureFilter => "00", textureFilterStrength => "00", textureFilter2DOff => '0',
         dither24 => '0', render24 => '0', drawSlow => '0', debugmodeOn => '0', syncVideoOut => '1',
         syncInterlace => '0', rotate180 => '0', fixedVBlank => '0', vCrop => "00", hCrop => '0', oldGPU => '0',
         Gun1CrosshairOn => '0', Gun1X => (others => '0'), Gun1Y_scanlines => (others => '0'), Gun1offscreen => '0',
         Gun1IRQ10 => open,
         Gun2CrosshairOn => '0', Gun2X => (others => '0'), Gun2Y_scanlines => (others => '0'), Gun2offscreen => '0',
         Gun2IRQ10 => open,
         cdSlow => '0', errorOn => '0', errorEna => '0', errorCode => (others => '0'),
         LBAOn => '0', LBAdisplay => (others => '0'),
         errorLINE => open, errorRECT => open, errorPOLY => open, errorGPU => open, errorMASK => open, errorFIFO => open,
         bus_addr => bus_addr, bus_dataWrite => bus_dataWrite, bus_read => bus_read, bus_write => bus_write,
         bus_dataRead => bus_dataRead, bus_stall => bus_stall,
         dmaOn => dmaOn, gpu_dmaRequest => dmaRequest, DMA_GPU_waiting => DMA_waiting,
         DMA_GPU_writeEna => DMA_writeEna, DMA_GPU_readEna => DMA_readEna, DMA_GPU_write => DMA_write,
         DMA_GPU_read => DMA_read,
         irq_VBLANK => irq_VBLANK, irq_GPU => irq_GPU,
         vram_pause => vram_pause, vram_paused => vram_paused, vram_BUSY => vram_BUSY, vram_DOUT => vram_DOUT,
         vram_DOUT_READY => vram_DOUT_READY, vram_BURSTCNT => vram_BURSTCNT, vram_ADDR => vram_ADDR,
         vram_DIN => vram_DIN, vram_BE => vram_BE, vram_WE => vram_WE, vram_RD => vram_RD,
         hblank_tmr => hblank_tmr, vblank_tmr => vblank_tmr, dotclock => dotclock,
         video_hsync => video_hsync, video_vsync => video_vsync, video_hblank => video_hblank,
         video_vblank => video_vblank, video_DisplayWidth => video_DisplayWidth,
         video_DisplayHeight => video_DisplayHeight, video_DisplayOffsetX => video_DisplayOffsetX,
         video_DisplayOffsetY => video_DisplayOffsetY, video_ce => video_ce, video_interlace => video_interlace,
         video_r => video_r, video_g => video_g, video_b => video_b, video_isPal => video_isPal,
         video_fbmode => video_fbmode, video_fb24 => video_fb24, video_hResMode => video_hResMode,
         video_frameindex => video_frameindex,
         loading_savestate => '0', SS_reset => '0', SS_DataWrite => (others => '0'), SS_Adr => (others => '0'),
         SS_wren_GPU => '0', SS_wren_Timing => '0', SS_rden_GPU => '0', SS_rden_Timing => '0',
         SS_DataRead_GPU => open, SS_DataRead_Timing => open, SS_Idle => open
      );

   end generate;

   gpocket : if G_POCKET generate
   begin

      igpu : gpu_pocket
      port map
      (
         clk1x => clk1x, clk2x => clk2x, clk2xIndex => clk2xIndex, clkvid => clkvid, ce => ce, reset => reset,
         allowunpause => open, savestate_busy => '0', system_paused => '0',
         -- options as tied in psx_min_wrap.vhd:97-131
         ditherOff => '0', interlaced480pHack => '0', REPRODUCIBLEGPUTIMING => '0', videoout_on => '1',
         isPal => isPal, pal60 => '0', fpscountOn => '0', noTexture => '0',
         textureFilter => "00", textureFilterStrength => "00", textureFilter2DOff => '0',
         dither24 => '0', render24 => '0', drawSlow => '0', debugmodeOn => '0', syncVideoOut => '1',
         syncInterlace => '0', rotate180 => '0', fixedVBlank => '0', vCrop => "00", hCrop => '0', oldGPU => '0',
         Gun1CrosshairOn => '0', Gun1X => (others => '0'), Gun1Y_scanlines => (others => '0'), Gun1offscreen => '0',
         Gun1IRQ10 => open,
         Gun2CrosshairOn => '0', Gun2X => (others => '0'), Gun2Y_scanlines => (others => '0'), Gun2offscreen => '0',
         Gun2IRQ10 => open,
         cdSlow => '0', errorOn => '0', errorEna => '0', errorCode => (others => '0'),
         LBAOn => '0', LBAdisplay => (others => '0'),
         errorLINE => open, errorRECT => open, errorPOLY => open, errorGPU => open, errorMASK => open, errorFIFO => open,
         bus_addr => bus_addr, bus_dataWrite => bus_dataWrite, bus_read => bus_read, bus_write => bus_write,
         bus_dataRead => bus_dataRead, bus_stall => bus_stall,
         dmaOn => dmaOn, gpu_dmaRequest => dmaRequest, DMA_GPU_waiting => DMA_waiting,
         DMA_GPU_writeEna => DMA_writeEna, DMA_GPU_readEna => DMA_readEna, DMA_GPU_write => DMA_write,
         DMA_GPU_read => DMA_read,
         irq_VBLANK => irq_VBLANK, irq_GPU => irq_GPU,
         vram_pause => vram_pause, vram_paused => vram_paused, vram_BUSY => vram_BUSY, vram_DOUT => vram_DOUT,
         vram_DOUT_READY => vram_DOUT_READY, vram_BURSTCNT => vram_BURSTCNT, vram_ADDR => vram_ADDR,
         vram_DIN => vram_DIN, vram_BE => vram_BE, vram_WE => vram_WE, vram_RD => vram_RD,
         hblank_tmr => hblank_tmr, vblank_tmr => vblank_tmr, dotclock => dotclock,
         video_hsync => video_hsync, video_vsync => video_vsync, video_hblank => video_hblank,
         video_vblank => video_vblank, video_DisplayWidth => video_DisplayWidth,
         video_DisplayHeight => video_DisplayHeight, video_DisplayOffsetX => video_DisplayOffsetX,
         video_DisplayOffsetY => video_DisplayOffsetY, video_ce => video_ce, video_interlace => video_interlace,
         video_r => video_r, video_g => video_g, video_b => video_b, video_isPal => video_isPal,
         video_fbmode => video_fbmode, video_fb24 => video_fb24, video_hResMode => video_hResMode,
         video_frameindex => video_frameindex,
         loading_savestate => '0', SS_reset => '0', SS_DataWrite => (others => '0'), SS_Adr => (others => '0'),
         SS_wren_GPU => '0', SS_wren_Timing => '0', SS_rden_GPU => '0', SS_rden_Timing => '0',
         SS_DataRead_GPU => open, SS_DataRead_Timing => open, SS_Idle => open
      );

   end generate;

end architecture;
