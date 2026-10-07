-- Sizing-only wrapper: gte (G_SERIAL = false) or gte_serial (true) with every port registered on
-- clk1x, as the CPU drives it, so I/O paths do not dominate. Not a functional top level.
-- Gate metric and results: docs/pocket/GTE.md ("Gate metric", "Measurements").
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gte_size_wrap is
   generic
   (
      G_SERIAL : boolean := true
   );
   port
   (
      clk1x, clk2x  : in  std_logic;
      i_ce, i_reset : in  std_logic;
      i_readAddr    : in  unsigned(5 downto 0);
      i_readEna     : in  std_logic;
      i_writeAddr   : in  unsigned(5 downto 0);
      i_writeData   : in  unsigned(31 downto 0);
      i_writeEna    : in  std_logic;
      i_cmdData     : in  unsigned(31 downto 0);
      i_cmdEna      : in  std_logic;
      o_busy        : out std_logic;
      o_readData    : out unsigned(31 downto 0);
      o_idle        : out std_logic
   );
end entity;

architecture arch of gte_size_wrap is

   signal ce, reset, readEna, writeEna, cmdEna : std_logic := '0';
   signal readAddr, writeAddr                  : unsigned(5 downto 0) := (others => '0');
   signal writeData, cmdData                   : unsigned(31 downto 0) := (others => '0');
   signal busy, idle                           : std_logic;
   signal readData                             : unsigned(31 downto 0);

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
         ce <= i_ce; reset <= i_reset; readEna <= i_readEna; writeEna <= i_writeEna; cmdEna <= i_cmdEna;
         readAddr <= i_readAddr; writeAddr <= i_writeAddr; writeData <= i_writeData; cmdData <= i_cmdData;
         o_busy <= busy; o_readData <= readData; o_idle <= idle;
      end if;
   end process;

   gserial : if G_SERIAL generate
      igte : entity work.gte_serial
      port map (
         clk1x => clk1x, clk2x => clk2x, clk2xIndex => clk2xIndex, ce => ce, reset => reset,
         WIDESCREEN => "00", TURBO => '0',
         gte_busy => busy, gte_readAddr => readAddr, gte_readData => readData, gte_readEna => readEna,
         gte_writeAddr_in => writeAddr, gte_writeData_in => writeData, gte_writeEna_in => writeEna,
         gte_cmdData => cmdData, gte_cmdEna => cmdEna,
         loading_savestate => '0', SS_reset => '0', SS_DataWrite => (others => '0'), SS_Adr => (others => '0'),
         SS_wren => '0', SS_rden => '0', SS_DataRead => open, SS_idle => idle, debug_firstGTE => open);
   end generate;

   ggolden : if not G_SERIAL generate
      igte : entity work.gte
      port map (
         clk1x => clk1x, clk2x => clk2x, clk2xIndex => clk2xIndex, ce => ce, reset => reset,
         WIDESCREEN => "00", TURBO => '0',
         gte_busy => busy, gte_readAddr => readAddr, gte_readData => readData, gte_readEna => readEna,
         gte_writeAddr_in => writeAddr, gte_writeData_in => writeData, gte_writeEna_in => writeEna,
         gte_cmdData => cmdData, gte_cmdEna => cmdEna,
         loading_savestate => '0', SS_reset => '0', SS_DataWrite => (others => '0'), SS_Adr => (others => '0'),
         SS_wren => '0', SS_rden => '0', SS_DataRead => open, SS_idle => idle, debug_firstGTE => open);
   end generate;

end architecture;
