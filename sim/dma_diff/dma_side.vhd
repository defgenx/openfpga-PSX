-- One DMA instance behind records. G_IMPL "golden" = rtl/dma.vhd, "pocket" = rtl/dma_pocket.vhd (component in the
-- untaken branch, as in psx_top_pocket.vhd). Savestate ports are tied off as the Pocket top does.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library work;
use work.dma_diff_pkg.all;

entity dma_side is
   generic (G_IMPL : string := "golden");
   port (i : in dma_in_t; o : out dma_out_t);
end entity;

architecture arch of dma_side is
   signal ss_dr : std_logic_vector(31 downto 0);
begin

   gold : if G_IMPL = "golden" generate
   begin
      idma : entity work.dma
      port map
      (
         clk1x => i.clk1x, clk3x => i.clk3x, clk3xIndex => i.clk3xIndex, ce => i.ce, reset => i.reset,
         errorCHOP => o.errorCHOP, errorDMACPU => o.errorDMACPU, errorDMAFIFO => o.errorDMAFIFO,
         TURBO => i.TURBO, TURBO_CACHE => i.TURBO_CACHE, ram8mb => i.ram8mb, ignoreCDTiming => i.ignoreCDTiming,
         canDMA => i.canDMA, cpuPaused => i.cpuPaused, dmaRequest => o.dmaRequest, dmaStallCPU => o.dmaStallCPU,
         dmaOn => o.dmaOn, irqOut => o.irqOut,
         ram_Adr => o.ram_Adr, ram_cnt => o.ram_cnt, ram_ena => o.ram_ena,
         dma_wr => i.dma_wr, dma_reqprocessed => i.dma_reqprocessed, dma_data => i.dma_data,
         ram_dmafifo_adr => o.ram_dmafifo_adr, ram_dmafifo_data => o.ram_dmafifo_data,
         ram_dmafifo_empty => o.ram_dmafifo_empty, ram_dmafifo_read => i.ram_dmafifo_read,
         dma_cache_Adr => o.dma_cache_Adr, dma_cache_data => o.dma_cache_data, dma_cache_write => o.dma_cache_write,
         gpu_dmaRequest => i.gpu_dmaRequest, DMA_GPU_waiting => o.DMA_GPU_waiting, DMA_GPU_writeEna => o.DMA_GPU_writeEna,
         DMA_GPU_readEna => o.DMA_GPU_readEna, DMA_GPU_write => o.DMA_GPU_write, DMA_GPU_read => i.DMA_GPU_read,
         mdec_dmaWriteRequest => i.mdec_dmaWriteRequest, mdec_dmaReadRequest => i.mdec_dmaReadRequest,
         DMA_MDEC_writeEna => o.DMA_MDEC_writeEna, DMA_MDEC_readEna => o.DMA_MDEC_readEna,
         DMA_MDEC_write => o.DMA_MDEC_write, DMA_MDEC_read => i.DMA_MDEC_read,
         cd_memctrl => i.cd_memctrl, com0_delay => i.com0_delay, DMA_CD_readEna => o.DMA_CD_readEna, DMA_CD_read => i.DMA_CD_read,
         spu_timing_on => i.spu_timing_on, spu_timing_value => i.spu_timing_value, spu_dmaRequest => i.spu_dmaRequest,
         DMA_SPU_writeEna => o.DMA_SPU_writeEna, DMA_SPU_readEna => o.DMA_SPU_readEna, DMA_SPU_write => o.DMA_SPU_write,
         DMA_SPU_read => i.DMA_SPU_read,
         bus_addr => i.bus_addr, bus_dataWrite => i.bus_dataWrite, bus_read => i.bus_read, bus_write => i.bus_write,
         bus_dataRead => o.bus_dataRead,
         loading_savestate => '0', SS_reset => '0', SS_DataWrite => (others => '0'), SS_Adr => (others => '0'),
         SS_wren => '0', SS_rden => '0', SS_DataRead => ss_dr, SS_idle => o.SS_idle
      );
   end generate;

   pock : if G_IMPL = "pocket" generate
      component dma_pocket is
      port
      (
         clk1x : in std_logic; clk3x : in std_logic; clk3xIndex : in std_logic; ce : in std_logic; reset : in std_logic;
         errorCHOP : out std_logic; errorDMACPU : out std_logic; errorDMAFIFO : out std_logic;
         TURBO : in std_logic; TURBO_CACHE : in std_logic; ram8mb : in std_logic; ignoreCDTiming : in std_logic;
         canDMA : in std_logic; cpuPaused : in std_logic; dmaRequest : out std_logic; dmaStallCPU : out std_logic;
         dmaOn : out std_logic; irqOut : out std_logic;
         ram_Adr : out std_logic_vector(22 downto 0); ram_cnt : buffer std_logic_vector(1 downto 0); ram_ena : out std_logic;
         dma_wr : in std_logic; dma_reqprocessed : in std_logic; dma_data : in std_logic_vector(31 downto 0);
         ram_dmafifo_adr : out std_logic_vector(22 downto 0); ram_dmafifo_data : out std_logic_vector(31 downto 0);
         ram_dmafifo_empty : out std_logic; ram_dmafifo_read : in std_logic;
         dma_cache_Adr : out std_logic_vector(20 downto 0); dma_cache_data : out std_logic_vector(31 downto 0);
         dma_cache_write : out std_logic;
         gpu_dmaRequest : in std_logic; DMA_GPU_waiting : out std_logic; DMA_GPU_writeEna : out std_logic;
         DMA_GPU_readEna : out std_logic; DMA_GPU_write : out std_logic_vector(31 downto 0);
         DMA_GPU_read : in std_logic_vector(31 downto 0);
         mdec_dmaWriteRequest : in std_logic; mdec_dmaReadRequest : in std_logic;
         DMA_MDEC_writeEna : out std_logic; DMA_MDEC_readEna : out std_logic;
         DMA_MDEC_write : out std_logic_vector(31 downto 0); DMA_MDEC_read : in std_logic_vector(31 downto 0);
         cd_memctrl : in unsigned(13 downto 0); com0_delay : in unsigned(3 downto 0);
         DMA_CD_readEna : out std_logic; DMA_CD_read : in std_logic_vector(7 downto 0);
         spu_timing_on : in std_logic; spu_timing_value : in unsigned(3 downto 0);
         spu_dmaRequest : in std_logic; DMA_SPU_writeEna : out std_logic; DMA_SPU_readEna : out std_logic;
         DMA_SPU_write : out std_logic_vector(15 downto 0); DMA_SPU_read : in std_logic_vector(15 downto 0);
         bus_addr : in unsigned(6 downto 0); bus_dataWrite : in std_logic_vector(31 downto 0);
         bus_read : in std_logic; bus_write : in std_logic; bus_dataRead : out std_logic_vector(31 downto 0);
         loading_savestate : in std_logic; SS_reset : in std_logic; SS_DataWrite : in std_logic_vector(31 downto 0);
         SS_Adr : in unsigned(5 downto 0); SS_wren : in std_logic; SS_rden : in std_logic;
         SS_DataRead : out std_logic_vector(31 downto 0); SS_idle : out std_logic
      );
      end component;
   begin
      idma : dma_pocket
      port map
      (
         clk1x => i.clk1x, clk3x => i.clk3x, clk3xIndex => i.clk3xIndex, ce => i.ce, reset => i.reset,
         errorCHOP => o.errorCHOP, errorDMACPU => o.errorDMACPU, errorDMAFIFO => o.errorDMAFIFO,
         TURBO => i.TURBO, TURBO_CACHE => i.TURBO_CACHE, ram8mb => i.ram8mb, ignoreCDTiming => i.ignoreCDTiming,
         canDMA => i.canDMA, cpuPaused => i.cpuPaused, dmaRequest => o.dmaRequest, dmaStallCPU => o.dmaStallCPU,
         dmaOn => o.dmaOn, irqOut => o.irqOut,
         ram_Adr => o.ram_Adr, ram_cnt => o.ram_cnt, ram_ena => o.ram_ena,
         dma_wr => i.dma_wr, dma_reqprocessed => i.dma_reqprocessed, dma_data => i.dma_data,
         ram_dmafifo_adr => o.ram_dmafifo_adr, ram_dmafifo_data => o.ram_dmafifo_data,
         ram_dmafifo_empty => o.ram_dmafifo_empty, ram_dmafifo_read => i.ram_dmafifo_read,
         dma_cache_Adr => o.dma_cache_Adr, dma_cache_data => o.dma_cache_data, dma_cache_write => o.dma_cache_write,
         gpu_dmaRequest => i.gpu_dmaRequest, DMA_GPU_waiting => o.DMA_GPU_waiting, DMA_GPU_writeEna => o.DMA_GPU_writeEna,
         DMA_GPU_readEna => o.DMA_GPU_readEna, DMA_GPU_write => o.DMA_GPU_write, DMA_GPU_read => i.DMA_GPU_read,
         mdec_dmaWriteRequest => i.mdec_dmaWriteRequest, mdec_dmaReadRequest => i.mdec_dmaReadRequest,
         DMA_MDEC_writeEna => o.DMA_MDEC_writeEna, DMA_MDEC_readEna => o.DMA_MDEC_readEna,
         DMA_MDEC_write => o.DMA_MDEC_write, DMA_MDEC_read => i.DMA_MDEC_read,
         cd_memctrl => i.cd_memctrl, com0_delay => i.com0_delay, DMA_CD_readEna => o.DMA_CD_readEna, DMA_CD_read => i.DMA_CD_read,
         spu_timing_on => i.spu_timing_on, spu_timing_value => i.spu_timing_value, spu_dmaRequest => i.spu_dmaRequest,
         DMA_SPU_writeEna => o.DMA_SPU_writeEna, DMA_SPU_readEna => o.DMA_SPU_readEna, DMA_SPU_write => o.DMA_SPU_write,
         DMA_SPU_read => i.DMA_SPU_read,
         bus_addr => i.bus_addr, bus_dataWrite => i.bus_dataWrite, bus_read => i.bus_read, bus_write => i.bus_write,
         bus_dataRead => o.bus_dataRead,
         loading_savestate => '0', SS_reset => '0', SS_DataWrite => (others => '0'), SS_Adr => (others => '0'),
         SS_wren => '0', SS_rden => '0', SS_DataRead => ss_dr, SS_idle => o.SS_idle
      );
   end generate;

end architecture;
