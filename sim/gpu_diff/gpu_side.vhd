library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.gpu_diff_pkg.all;

-- One side of the comparison: a GPU (the frozen gpu, or gpu_dut) with its own VRAM model.
-- System-level inputs are fixed here; option inputs come from opts (the tb's TIE-OFF block).
entity gpu_side is
   generic
   (
      G_DUT            : boolean := false;
      G_TRACEFILE      : string  := "";
      G_VRAM_BUSY      : integer := 1;
      G_VRAM_LAT       : integer := 8;
      G_FAULT_MON_IDX  : integer := -1;
      G_FAULT_MEM_IDX  : integer := -1;
      G_FAULT_BIT      : integer := 0
   );
   port
   (
      clk1x            : in  std_logic;
      clk2x            : in  std_logic;
      clk2xIndex       : in  std_logic;
      clkvid           : in  std_logic;
      reset            : in  std_logic;
      ss_reset         : in  std_logic;   -- loads the savestate defaults (display range) like a power-up
      opts             : in  t_gpu_opts;

      bus_addr         : in  unsigned(3 downto 0);
      bus_dataWrite    : in  std_logic_vector(31 downto 0);
      bus_read         : in  std_logic;
      bus_write        : in  std_logic;
      bus_dataRead     : out std_logic_vector(31 downto 0);
      bus_stall        : out std_logic;

      gpus             : out std_logic_vector(31 downto 0);   -- live GPUSTAT
      errs             : out std_logic_vector(5 downto 0);    -- LINE, RECT, POLY, GPU, MASK, FIFO
      irq_vblank       : out std_logic;
      vid              : out std_logic_vector(76 downto 0);   -- video outputs, compared by the video suite

      mon_we           : out std_logic;
      mon_re           : out std_logic;
      mon_addr         : out std_logic_vector(27 downto 0);
      mon_din          : out std_logic_vector(63 downto 0);
      mon_be           : out std_logic_vector(7 downto 0);
      mon_burst        : out std_logic_vector(7 downto 0);

      dump_idx         : in  natural range 0 to 131071;
      dump_q           : out std_logic_vector(63 downto 0)
   );
end entity;

architecture arch of gpu_side is

   signal vram_BUSY       : std_logic;
   signal vram_DOUT       : std_logic_vector(63 downto 0);
   signal vram_DOUT_READY : std_logic;
   signal vram_BURSTCNT   : std_logic_vector(7 downto 0);
   signal vram_ADDR       : std_logic_vector(27 downto 0);
   signal vram_DIN        : std_logic_vector(63 downto 0);
   signal vram_BE         : std_logic_vector(7 downto 0);
   signal vram_WE         : std_logic;
   signal vram_RD         : std_logic;
   signal gpus_u          : unsigned(31 downto 0);
   signal v_hblank_tmr, v_vblank_tmr, v_dotclock, v_hsync, v_vsync, v_hblank, v_vblank, v_ce, v_interlace, v_isPal : std_logic;
   signal v_width         : unsigned(10 downto 0);
   signal v_height        : unsigned(9 downto 0);
   signal v_offx          : unsigned(9 downto 0);
   signal v_offy          : unsigned(8 downto 0);
   signal v_r, v_g, v_b   : std_logic_vector(7 downto 0);
   signal v_hres          : std_logic_vector(2 downto 0);

begin

   gpus <= std_logic_vector(gpus_u);

   vid <= v_hsync & v_vsync & v_hblank & v_vblank & v_ce & v_interlace & v_isPal & v_hres & v_r & v_g & v_b &
          std_logic_vector(v_width) & std_logic_vector(v_height) & std_logic_vector(v_offx) & std_logic_vector(v_offy) &
          v_hblank_tmr & v_vblank_tmr & v_dotclock;

   ivram : entity work.vram_model
   generic map
   (
      G_BUSY_MODE      => G_VRAM_BUSY,
      G_READ_LAT       => G_VRAM_LAT,
      G_TRACEFILE      => G_TRACEFILE,
      G_FAULT_MON_IDX  => G_FAULT_MON_IDX,
      G_FAULT_MEM_IDX  => G_FAULT_MEM_IDX,
      G_FAULT_BIT      => G_FAULT_BIT
   )
   port map
   (
      clk              => clk2x,
      vram_BUSY        => vram_BUSY,
      vram_DOUT        => vram_DOUT,
      vram_DOUT_READY  => vram_DOUT_READY,
      vram_BURSTCNT    => vram_BURSTCNT,
      vram_ADDR        => vram_ADDR,
      vram_DIN         => vram_DIN,
      vram_BE          => vram_BE,
      vram_WE          => vram_WE,
      vram_RD          => vram_RD,
      mon_we           => mon_we,
      mon_re           => mon_re,
      mon_addr         => mon_addr,
      mon_din          => mon_din,
      mon_be           => mon_be,
      mon_burst        => mon_burst,
      dump_idx         => dump_idx,
      dump_q           => dump_q
   );

   ggolden : if not G_DUT generate
      igpu : entity work.gpu
      port map
      (
            clk1x                 => clk1x,
            clk2x                 => clk2x,
            clk2xIndex            => clk2xIndex,
            clkvid                => clkvid,
            ce                    => '1',
            reset                 => reset,
            allowunpause          => open,
            savestate_busy        => '0',
            system_paused         => '0',
            ditherOff             => opts.ditherOff,
            interlaced480pHack    => opts.interlaced480pHack,
            REPRODUCIBLEGPUTIMING => opts.REPRODUCIBLEGPUTIMING,
            videoout_on           => opts.videoout_on,
            isPal                 => opts.isPal,
            pal60                 => opts.pal60,
            fpscountOn            => opts.fpscountOn,
            noTexture             => opts.noTexture,
            textureFilter         => opts.textureFilter,
            textureFilterStrength => opts.textureFilterStrength,
            textureFilter2DOff    => opts.textureFilter2DOff,
            dither24              => opts.dither24,
            render24              => opts.render24,
            drawSlow              => opts.drawSlow,
            debugmodeOn           => opts.debugmodeOn,
            syncVideoOut          => opts.syncVideoOut,
            syncInterlace         => opts.syncInterlace,
            rotate180             => opts.rotate180,
            fixedVBlank           => opts.fixedVBlank,
            vCrop                 => opts.vCrop,
            hCrop                 => opts.hCrop,
            oldGPU                => opts.oldGPU,
            Gun1CrosshairOn       => opts.Gun1CrosshairOn,
            Gun1X                 => (others => '0'),
            Gun1Y_scanlines       => (others => '0'),
            Gun1offscreen         => '0',
            Gun1IRQ10             => open,
            Gun2CrosshairOn       => opts.Gun2CrosshairOn,
            Gun2X                 => (others => '0'),
            Gun2Y_scanlines       => (others => '0'),
            Gun2offscreen         => '0',
            Gun2IRQ10             => open,
            cdSlow                => opts.cdSlow,
            errorOn               => opts.errorOn,
            errorEna              => opts.errorEna,
            errorCode             => (others => '0'),
            LBAOn                 => opts.LBAOn,
            LBAdisplay            => (others => '0'),
            errorLINE             => errs(0),
            errorRECT             => errs(1),
            errorPOLY             => errs(2),
            errorGPU              => errs(3),
            errorMASK             => errs(4),
            errorFIFO             => errs(5),
            bus_addr              => bus_addr,
            bus_dataWrite         => bus_dataWrite,
            bus_read              => bus_read,
            bus_write             => bus_write,
            bus_dataRead          => bus_dataRead,
            bus_stall             => bus_stall,
            dmaOn                 => '0',
            gpu_dmaRequest        => open,
            DMA_GPU_waiting       => '0',
            DMA_GPU_writeEna      => '0',
            DMA_GPU_readEna       => '0',
            DMA_GPU_write         => (others => '0'),
            DMA_GPU_read          => open,
            irq_VBLANK            => irq_vblank,
            irq_GPU               => open,
            vram_pause            => '0',
            vram_paused           => open,
            vram_BUSY             => vram_BUSY,
            vram_DOUT             => vram_DOUT,
            vram_DOUT_READY       => vram_DOUT_READY,
            vram_BURSTCNT         => vram_BURSTCNT,
            vram_ADDR             => vram_ADDR,
            vram_DIN              => vram_DIN,
            vram_BE               => vram_BE,
            vram_WE               => vram_WE,
            vram_RD               => vram_RD,
            hblank_tmr            => v_hblank_tmr,
            vblank_tmr            => v_vblank_tmr,
            dotclock              => v_dotclock,
            video_hsync           => v_hsync,
            video_vsync           => v_vsync,
            video_hblank          => v_hblank,
            video_vblank          => v_vblank,
            video_DisplayWidth    => v_width,
            video_DisplayHeight   => v_height,
            video_DisplayOffsetX  => v_offx,
            video_DisplayOffsetY  => v_offy,
            video_ce              => v_ce,
            video_interlace       => v_interlace,
            video_r               => v_r,
            video_g               => v_g,
            video_b               => v_b,
            video_isPal           => v_isPal,
            video_fbmode          => open,
            video_fb24            => open,
            video_hResMode        => v_hres,
            video_frameindex      => open,
            export_gtm            => open,
            export_line           => open,
            export_gpus           => gpus_u,
            export_gobj           => open,
            loading_savestate     => '0',
            SS_reset              => ss_reset,
            SS_DataWrite          => x"00020000",
            SS_Adr                => (others => '0'),
            SS_wren_GPU           => '0',
            SS_wren_Timing        => '0',
            SS_rden_GPU           => '0',
            SS_rden_Timing        => '0',
            SS_DataRead_GPU       => open,
            SS_DataRead_Timing    => open,
            SS_Idle               => open
      );
   end generate;

   gdut : if G_DUT generate
      igpu : entity work.gpu_dut
      port map
      (
            clk1x                 => clk1x,
            clk2x                 => clk2x,
            clk2xIndex            => clk2xIndex,
            clkvid                => clkvid,
            ce                    => '1',
            reset                 => reset,
            allowunpause          => open,
            savestate_busy        => '0',
            system_paused         => '0',
            ditherOff             => opts.ditherOff,
            interlaced480pHack    => opts.interlaced480pHack,
            REPRODUCIBLEGPUTIMING => opts.REPRODUCIBLEGPUTIMING,
            videoout_on           => opts.videoout_on,
            isPal                 => opts.isPal,
            pal60                 => opts.pal60,
            fpscountOn            => opts.fpscountOn,
            noTexture             => opts.noTexture,
            textureFilter         => opts.textureFilter,
            textureFilterStrength => opts.textureFilterStrength,
            textureFilter2DOff    => opts.textureFilter2DOff,
            dither24              => opts.dither24,
            render24              => opts.render24,
            drawSlow              => opts.drawSlow,
            debugmodeOn           => opts.debugmodeOn,
            syncVideoOut          => opts.syncVideoOut,
            syncInterlace         => opts.syncInterlace,
            rotate180             => opts.rotate180,
            fixedVBlank           => opts.fixedVBlank,
            vCrop                 => opts.vCrop,
            hCrop                 => opts.hCrop,
            oldGPU                => opts.oldGPU,
            Gun1CrosshairOn       => opts.Gun1CrosshairOn,
            Gun1X                 => (others => '0'),
            Gun1Y_scanlines       => (others => '0'),
            Gun1offscreen         => '0',
            Gun1IRQ10             => open,
            Gun2CrosshairOn       => opts.Gun2CrosshairOn,
            Gun2X                 => (others => '0'),
            Gun2Y_scanlines       => (others => '0'),
            Gun2offscreen         => '0',
            Gun2IRQ10             => open,
            cdSlow                => opts.cdSlow,
            errorOn               => opts.errorOn,
            errorEna              => opts.errorEna,
            errorCode             => (others => '0'),
            LBAOn                 => opts.LBAOn,
            LBAdisplay            => (others => '0'),
            errorLINE             => errs(0),
            errorRECT             => errs(1),
            errorPOLY             => errs(2),
            errorGPU              => errs(3),
            errorMASK             => errs(4),
            errorFIFO             => errs(5),
            bus_addr              => bus_addr,
            bus_dataWrite         => bus_dataWrite,
            bus_read              => bus_read,
            bus_write             => bus_write,
            bus_dataRead          => bus_dataRead,
            bus_stall             => bus_stall,
            dmaOn                 => '0',
            gpu_dmaRequest        => open,
            DMA_GPU_waiting       => '0',
            DMA_GPU_writeEna      => '0',
            DMA_GPU_readEna       => '0',
            DMA_GPU_write         => (others => '0'),
            DMA_GPU_read          => open,
            irq_VBLANK            => irq_vblank,
            irq_GPU               => open,
            vram_pause            => '0',
            vram_paused           => open,
            vram_BUSY             => vram_BUSY,
            vram_DOUT             => vram_DOUT,
            vram_DOUT_READY       => vram_DOUT_READY,
            vram_BURSTCNT         => vram_BURSTCNT,
            vram_ADDR             => vram_ADDR,
            vram_DIN              => vram_DIN,
            vram_BE               => vram_BE,
            vram_WE               => vram_WE,
            vram_RD               => vram_RD,
            hblank_tmr            => v_hblank_tmr,
            vblank_tmr            => v_vblank_tmr,
            dotclock              => v_dotclock,
            video_hsync           => v_hsync,
            video_vsync           => v_vsync,
            video_hblank          => v_hblank,
            video_vblank          => v_vblank,
            video_DisplayWidth    => v_width,
            video_DisplayHeight   => v_height,
            video_DisplayOffsetX  => v_offx,
            video_DisplayOffsetY  => v_offy,
            video_ce              => v_ce,
            video_interlace       => v_interlace,
            video_r               => v_r,
            video_g               => v_g,
            video_b               => v_b,
            video_isPal           => v_isPal,
            video_fbmode          => open,
            video_fb24            => open,
            video_hResMode        => v_hres,
            video_frameindex      => open,
            export_gtm            => open,
            export_line           => open,
            export_gpus           => gpus_u,
            export_gobj           => open,
            loading_savestate     => '0',
            SS_reset              => ss_reset,
            SS_DataWrite          => x"00020000",
            SS_Adr                => (others => '0'),
            SS_wren_GPU           => '0',
            SS_wren_Timing        => '0',
            SS_rden_GPU           => '0',
            SS_rden_Timing        => '0',
            SS_DataRead_GPU       => open,
            SS_DataRead_Timing    => open,
            SS_Idle               => open
      );
   end generate;

end architecture;
