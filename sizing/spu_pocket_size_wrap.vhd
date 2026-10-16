-- Sizing-only wrapper: spu_pocket with every port registered on clk1x, options tied as in the contract
-- (useSDRAM, REPRODUCIBLESPUIRQ, SPUon; REPRODUCIBLESPUDMA and SPUIRQTrigger off), savestate and DDR3 ports tied off.
-- G_NO_REVERB is the DUT generic; REVERBOFF is tied to it. Same ports and registering as spu_size_wrap.
-- Not a functional top level. Results: docs/pocket/SPU.md.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity spu_pocket_size_wrap is
   generic
   (
      G_NO_REVERB : boolean := true
      ;G_L1_CACHE : boolean := true
   );
   port
   (
      clk1x, clk2x     : in  std_logic;
      i_ce, i_reset    : in  std_logic;
      i_cpuPaused      : in  std_logic;
      o_spu_tick       : out std_logic;
      i_cd_left        : in  signed(15 downto 0);
      i_cd_right       : in  signed(15 downto 0);
      o_irqOut         : out std_logic;
      o_sound_timeout  : out std_logic;
      o_sound_left     : out std_logic_vector(15 downto 0);
      o_sound_right    : out std_logic_vector(15 downto 0);
      i_bus_addr       : in  unsigned(9 downto 0);
      i_bus_dataWrite  : in  std_logic_vector(15 downto 0);
      i_bus_read       : in  std_logic;
      i_bus_write      : in  std_logic;
      o_bus_dataRead   : out std_logic_vector(15 downto 0);
      o_spu_dmaRequest : out std_logic;
      i_dma_read       : in  std_logic;
      o_dma_readdata   : out std_logic_vector(15 downto 0);
      i_dma_write      : in  std_logic;
      i_dma_writedata  : in  std_logic_vector(15 downto 0);
      o_sdram_dataWrite : out std_logic_vector(31 downto 0);
      o_sdram_Adr      : out std_logic_vector(18 downto 0);
      o_sdram_be       : out std_logic_vector(3 downto 0);
      o_sdram_rnw      : out std_logic;
      o_sdram_ena      : out std_logic;
      i_sdram_dataRead : in  std_logic_vector(31 downto 0);
      i_sdram_done     : in  std_logic
   );
end entity;

architecture arch of spu_pocket_size_wrap is

   signal ce, reset, cpuPaused, bus_read, bus_write, dma_read, dma_write, sdram_done : std_logic := '0';
   signal cd_left, cd_right      : signed(15 downto 0) := (others => '0');
   signal bus_addr               : unsigned(9 downto 0) := (others => '0');
   signal bus_dataWrite, dma_writedata : std_logic_vector(15 downto 0) := (others => '0');
   signal sdram_dataRead         : std_logic_vector(31 downto 0) := (others => '0');

   signal spu_tick, irqOut, sound_timeout, spu_dmaRequest, sdram_rnw, sdram_ena : std_logic;
   signal sound_left, sound_right, bus_dataRead, dma_readdata : std_logic_vector(15 downto 0);
   signal sdram_dataWrite        : std_logic_vector(31 downto 0);
   signal sdram_Adr              : std_logic_vector(18 downto 0);
   signal sdram_be               : std_logic_vector(3 downto 0);

   signal clk1xToggle, clk1xToggle2x, clk2xIndex : std_logic := '0';

   function tob(b : boolean) return std_logic is
   begin
      if b then return '1'; else return '0'; end if;
   end function;

begin

   -- clk2xIndex as psx_top derives it
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
         ce <= i_ce; reset <= i_reset; cpuPaused <= i_cpuPaused;
         cd_left <= i_cd_left; cd_right <= i_cd_right;
         bus_addr <= i_bus_addr; bus_dataWrite <= i_bus_dataWrite; bus_read <= i_bus_read; bus_write <= i_bus_write;
         dma_read <= i_dma_read; dma_write <= i_dma_write; dma_writedata <= i_dma_writedata;
         sdram_dataRead <= i_sdram_dataRead; sdram_done <= i_sdram_done;

         o_spu_tick <= spu_tick; o_irqOut <= irqOut; o_sound_timeout <= sound_timeout;
         o_sound_left <= sound_left; o_sound_right <= sound_right;
         o_bus_dataRead <= bus_dataRead; o_spu_dmaRequest <= spu_dmaRequest; o_dma_readdata <= dma_readdata;
         o_sdram_dataWrite <= sdram_dataWrite; o_sdram_Adr <= sdram_Adr; o_sdram_be <= sdram_be;
         o_sdram_rnw <= sdram_rnw; o_sdram_ena <= sdram_ena;
      end if;
   end process;

   ispu : entity work.spu_pocket
   generic map (NO_REVERB => G_NO_REVERB, L1_CACHE => G_L1_CACHE)
   port map
   (
      clk1x => clk1x, clk2x => clk2x, clk2xIndex => clk2xIndex, ce => ce, reset => reset,
      SPUon => '1', SPUIRQTrigger => '0', useSDRAM => '1', REPRODUCIBLESPUIRQ => '1',
      REPRODUCIBLESPUDMA => '0', REVERBOFF => tob(G_NO_REVERB),
      cpuPaused => cpuPaused,
      spu_tick => spu_tick, cd_left => cd_left, cd_right => cd_right,
      irqOut => irqOut, sound_timeout => sound_timeout,
      sound_out_left => sound_left, sound_out_right => sound_right,
      bus_addr => bus_addr, bus_dataWrite => bus_dataWrite, bus_read => bus_read, bus_write => bus_write,
      bus_dataRead => bus_dataRead,
      spu_dmaRequest => spu_dmaRequest, dma_read => dma_read, dma_readdata => dma_readdata,
      dma_write => dma_write, dma_writedata => dma_writedata,
      sdram_dataWrite => sdram_dataWrite, sdram_Adr => sdram_Adr, sdram_be => sdram_be,
      sdram_rnw => sdram_rnw, sdram_ena => sdram_ena, sdram_dataRead => sdram_dataRead, sdram_done => sdram_done,
      mem_request => open, mem_BURSTCNT => open, mem_ADDR => open, mem_DIN => open, mem_BE => open,
      mem_WE => open, mem_RD => open, mem_ack => '0', mem_DOUT => (others => '0'), mem_DOUT_READY => '0',
      SS_reset => '0', loading_savestate => '0', SS_DataWrite => (others => '0'), SS_Adr => (others => '0'),
      SS_wren => '0', SS_rden => '0', SS_DataRead => open, SS_idle => open,
      SS_RAM_dataWrite => (others => '0'), SS_RAM_Adr => (others => '0'), SS_RAM_request => '0',
      SS_RAM_rnw => '0', SS_RAM_dataRead => open, SS_RAM_done => open
   );

end architecture;
