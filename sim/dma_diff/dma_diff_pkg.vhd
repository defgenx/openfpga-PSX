-- Input and output records of one dma / dma_pocket instance (savestate ports are tied off inside dma_side).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package dma_diff_pkg is

   type dma_in_t is record
      clk1x, clk3x, clk3xIndex, ce, reset : std_logic;
      TURBO, TURBO_CACHE, ram8mb, ignoreCDTiming : std_logic;
      canDMA, cpuPaused : std_logic;
      dma_wr, dma_reqprocessed : std_logic;
      dma_data : std_logic_vector(31 downto 0);
      ram_dmafifo_read : std_logic;
      gpu_dmaRequest : std_logic;
      DMA_GPU_read : std_logic_vector(31 downto 0);
      mdec_dmaWriteRequest, mdec_dmaReadRequest : std_logic;
      DMA_MDEC_read : std_logic_vector(31 downto 0);
      cd_memctrl : unsigned(13 downto 0);
      com0_delay : unsigned(3 downto 0);
      DMA_CD_read : std_logic_vector(7 downto 0);
      spu_timing_on : std_logic;
      spu_timing_value : unsigned(3 downto 0);
      spu_dmaRequest : std_logic;
      DMA_SPU_read : std_logic_vector(15 downto 0);
      bus_addr : unsigned(6 downto 0);
      bus_dataWrite : std_logic_vector(31 downto 0);
      bus_read, bus_write : std_logic;
   end record;

   type dma_out_t is record
      errorCHOP, errorDMACPU, errorDMAFIFO : std_logic;
      dmaRequest, dmaStallCPU, dmaOn, irqOut : std_logic;
      ram_Adr : std_logic_vector(22 downto 0);
      ram_cnt : std_logic_vector(1 downto 0);
      ram_ena : std_logic;
      ram_dmafifo_adr : std_logic_vector(22 downto 0);
      ram_dmafifo_data : std_logic_vector(31 downto 0);
      ram_dmafifo_empty : std_logic;
      dma_cache_Adr : std_logic_vector(20 downto 0);
      dma_cache_data : std_logic_vector(31 downto 0);
      dma_cache_write : std_logic;
      DMA_GPU_waiting, DMA_GPU_writeEna, DMA_GPU_readEna : std_logic;
      DMA_GPU_write : std_logic_vector(31 downto 0);
      DMA_MDEC_writeEna, DMA_MDEC_readEna : std_logic;
      DMA_MDEC_write : std_logic_vector(31 downto 0);
      DMA_CD_readEna : std_logic;
      DMA_SPU_writeEna, DMA_SPU_readEna : std_logic;
      DMA_SPU_write : std_logic_vector(15 downto 0);
      bus_dataRead : std_logic_vector(31 downto 0);
      SS_idle : std_logic;
   end record;

end package;
