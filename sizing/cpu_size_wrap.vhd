-- Sizing-only wrapper: cpu with every port registered on clk1x, TURBO options off, savestate ports tied off.
-- clk2x/clk3x are the PLL clocks of the core; the cpu uses them for the scratchpad port and the cache RAM.
-- Not a functional top level. Gate metric and results: docs/pocket/CPU.md.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cpu_size_wrap is
   port
   (
      clk1x, clk2x, clk3x   : in  std_logic;
      i_ce, i_reset         : in  std_logic;
      i_irqRequest, i_dmaStallCPU, i_cpuPaused : in std_logic;
      o_error, o_error2     : out std_logic;
      o_mem_request, o_mem_rnw, o_mem_isData, o_mem_isCache : out std_logic;
      o_mem_oldtagvalids    : out std_logic_vector(3 downto 0);
      o_mem_addressInstr, o_mem_addressData : out unsigned(31 downto 0);
      o_mem_reqsize         : out unsigned(1 downto 0);
      o_mem_writeMask       : out std_logic_vector(3 downto 0);
      o_mem_dataWrite       : out std_logic_vector(31 downto 0);
      i_mem_dataRead        : in  std_logic_vector(31 downto 0);
      i_mem_done, i_mem_fifofull : in std_logic;
      i_mem_tagvalids       : in  std_logic_vector(3 downto 0);
      i_cache_wr            : in  std_logic_vector(3 downto 0);
      i_cache_data          : in  std_logic_vector(31 downto 0);
      i_cache_addr          : in  std_logic_vector(7 downto 0);
      o_stallNext           : out std_logic;
      i_dma_cache_Adr       : in  std_logic_vector(20 downto 0);
      i_dma_cache_data      : in  std_logic_vector(31 downto 0);
      i_dma_cache_write     : in  std_logic;
      i_ram_done, i_ram_rnw : in  std_logic;
      i_ram_dataRead        : in  std_logic_vector(31 downto 0);
      i_gte_busy            : in  std_logic;
      o_gte_readEna         : out std_logic;
      o_gte_readAddr        : out unsigned(5 downto 0);
      i_gte_readData        : in  unsigned(31 downto 0);
      o_gte_writeAddr       : out unsigned(5 downto 0);
      o_gte_writeData       : out unsigned(31 downto 0);
      o_gte_writeEna        : out std_logic;
      o_gte_cmdData         : out unsigned(31 downto 0);
      o_gte_cmdEna          : out std_logic
   );
end entity;

architecture arch of cpu_size_wrap is

   signal ce, reset, irqRequest, dmaStallCPU, cpuPaused, mem_done, mem_fifofull : std_logic := '0';
   signal dma_cache_write, ram_done, ram_rnw, gte_busy : std_logic := '0';
   signal mem_dataRead, cache_data, dma_cache_data, ram_dataRead : std_logic_vector(31 downto 0) := (others => '0');
   signal mem_tagvalids, cache_wr : std_logic_vector(3 downto 0) := (others => '0');
   signal cache_addr             : std_logic_vector(7 downto 0) := (others => '0');
   signal dma_cache_Adr          : std_logic_vector(20 downto 0) := (others => '0');
   signal gte_readData           : unsigned(31 downto 0) := (others => '0');

   signal error, error2, mem_request, mem_rnw, mem_isData, mem_isCache, stallNext : std_logic;
   signal mem_oldtagvalids, mem_writeMask : std_logic_vector(3 downto 0);
   signal mem_addressInstr, mem_addressData, gte_writeData, gte_cmdData : unsigned(31 downto 0);
   signal mem_reqsize            : unsigned(1 downto 0);
   signal mem_dataWrite          : std_logic_vector(31 downto 0);
   signal gte_readEna, gte_writeEna, gte_cmdEna : std_logic;
   signal gte_readAddr, gte_writeAddr : unsigned(5 downto 0);

begin

   process (clk1x) begin
      if rising_edge(clk1x) then
         ce <= i_ce; reset <= i_reset; irqRequest <= i_irqRequest; dmaStallCPU <= i_dmaStallCPU; cpuPaused <= i_cpuPaused;
         mem_dataRead <= i_mem_dataRead; mem_done <= i_mem_done; mem_fifofull <= i_mem_fifofull; mem_tagvalids <= i_mem_tagvalids;
         cache_wr <= i_cache_wr; cache_data <= i_cache_data; cache_addr <= i_cache_addr;
         dma_cache_Adr <= i_dma_cache_Adr; dma_cache_data <= i_dma_cache_data; dma_cache_write <= i_dma_cache_write;
         ram_done <= i_ram_done; ram_rnw <= i_ram_rnw; ram_dataRead <= i_ram_dataRead;
         gte_busy <= i_gte_busy; gte_readData <= i_gte_readData;

         o_error <= error; o_error2 <= error2; o_mem_request <= mem_request; o_mem_rnw <= mem_rnw;
         o_mem_isData <= mem_isData; o_mem_isCache <= mem_isCache; o_mem_oldtagvalids <= mem_oldtagvalids;
         o_mem_addressInstr <= mem_addressInstr; o_mem_addressData <= mem_addressData; o_mem_reqsize <= mem_reqsize;
         o_mem_writeMask <= mem_writeMask; o_mem_dataWrite <= mem_dataWrite; o_stallNext <= stallNext;
         o_gte_readEna <= gte_readEna; o_gte_readAddr <= gte_readAddr; o_gte_writeAddr <= gte_writeAddr;
         o_gte_writeData <= gte_writeData; o_gte_writeEna <= gte_writeEna; o_gte_cmdData <= gte_cmdData;
         o_gte_cmdEna <= gte_cmdEna;
      end if;
   end process;

   icpu : entity work.cpu
   port map
   (
      clk1x => clk1x, clk2x => clk2x, clk3x => clk3x, ce => ce, reset => reset,
      TURBO => '0', TURBO_CACHE => '0', TURBO_CACHE50 => '0',
      irqRequest => irqRequest, dmaStallCPU => dmaStallCPU, cpuPaused => cpuPaused,
      error => error, error2 => error2,
      mem_request => mem_request, mem_rnw => mem_rnw, mem_isData => mem_isData, mem_isCache => mem_isCache,
      mem_oldtagvalids => mem_oldtagvalids, mem_addressInstr => mem_addressInstr, mem_addressData => mem_addressData,
      mem_reqsize => mem_reqsize, mem_writeMask => mem_writeMask, mem_dataWrite => mem_dataWrite,
      mem_dataRead => mem_dataRead, mem_done => mem_done, mem_fifofull => mem_fifofull, mem_tagvalids => mem_tagvalids,
      cache_wr => cache_wr, cache_data => cache_data, cache_addr => cache_addr,
      stallNext => stallNext,
      dma_cache_Adr => dma_cache_Adr, dma_cache_data => dma_cache_data, dma_cache_write => dma_cache_write,
      ram_done => ram_done, ram_rnw => ram_rnw, ram_dataRead => ram_dataRead,
      gte_busy => gte_busy, gte_readEna => gte_readEna, gte_readAddr => gte_readAddr, gte_readData => gte_readData,
      gte_writeAddr => gte_writeAddr, gte_writeData => gte_writeData, gte_writeEna => gte_writeEna,
      gte_cmdData => gte_cmdData, gte_cmdEna => gte_cmdEna,
      SS_reset => '0', SS_DataWrite => (others => '0'), SS_Adr => (others => '0'),
      SS_wren_CPU => '0', SS_wren_SCP => '0', SS_rden_CPU => '0', SS_rden_SCP => '0',
      SS_DataRead_CPU => open, SS_DataRead_SCP => open, SS_idle => open,
      debug_firstGTE => '0'
   );

end architecture;
