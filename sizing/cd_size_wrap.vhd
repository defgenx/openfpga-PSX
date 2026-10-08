-- Sizing-only wrapper: cd_top with every port registered on clk1x, options tied as psx_min_wrap ties them
-- (disc present, MiSTer-default timing, no seek test), savestate ports tied off. Not a functional top level.
-- Gate metric and results: docs/pocket/CD.md.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cd_size_wrap is
   port
   (
      clk1x                : in  std_logic;
      i_ce, i_reset        : in  std_logic;
      i_region             : in  std_logic_vector(1 downto 0);
      o_region_out         : out std_logic_vector(1 downto 0);
      o_pauseCD, o_Pause_idle_cd, o_fullyIdle, o_cdSlow, o_error : out std_logic;
      o_LBAdisplay         : out unsigned(19 downto 0);
      o_irqOut             : out std_logic;
      i_spu_tick           : in  std_logic;
      o_cd_left, o_cd_right : out signed(15 downto 0);
      i_mdec_idle          : in  std_logic;
      i_bus_addr           : in  unsigned(3 downto 0);
      i_bus_dataWrite      : in  std_logic_vector(7 downto 0);
      i_bus_read, i_bus_write : in std_logic;
      o_bus_dataRead       : out std_logic_vector(7 downto 0);
      i_dma_read           : in  std_logic;
      o_dma_readdata       : out std_logic_vector(7 downto 0);
      o_cd_hps_req         : out std_logic;
      o_cd_hps_lba, o_cd_hps_lba_sim : out std_logic_vector(31 downto 0);
      i_cd_hps_ack, i_cd_hps_write : in std_logic;
      i_cd_hps_data        : in  std_logic_vector(15 downto 0);
      i_trackinfo_data     : in  std_logic_vector(31 downto 0);
      i_trackinfo_addr     : in  std_logic_vector(8 downto 0);
      i_trackinfo_write    : in  std_logic;
      o_resetFromCD        : out std_logic
   );
end entity;

architecture arch of cd_size_wrap is

   signal ce, reset, spu_tick, mdec_idle, bus_read, bus_write, dma_read : std_logic := '0';
   signal hps_ack, hps_write, trackinfo_write : std_logic := '0';
   signal region                 : std_logic_vector(1 downto 0) := (others => '0');
   signal bus_addr               : unsigned(3 downto 0) := (others => '0');
   signal bus_dataWrite          : std_logic_vector(7 downto 0) := (others => '0');
   signal hps_data               : std_logic_vector(15 downto 0) := (others => '0');
   signal trackinfo_data         : std_logic_vector(31 downto 0) := (others => '0');
   signal trackinfo_addr         : std_logic_vector(8 downto 0) := (others => '0');

   signal region_out             : std_logic_vector(1 downto 0);
   signal pauseCD, Pause_idle_cd, fullyIdle, cdSlow, error, irqOut, hps_req, resetFromCD : std_logic;
   signal LBAdisplay             : unsigned(19 downto 0);
   signal cd_left, cd_right      : signed(15 downto 0);
   signal bus_dataRead, dma_readdata : std_logic_vector(7 downto 0);
   signal hps_lba, hps_lba_sim   : std_logic_vector(31 downto 0);

begin

   process (clk1x) begin
      if rising_edge(clk1x) then
         ce <= i_ce; reset <= i_reset; region <= i_region; spu_tick <= i_spu_tick; mdec_idle <= i_mdec_idle;
         bus_addr <= i_bus_addr; bus_dataWrite <= i_bus_dataWrite; bus_read <= i_bus_read; bus_write <= i_bus_write;
         dma_read <= i_dma_read; hps_ack <= i_cd_hps_ack; hps_write <= i_cd_hps_write; hps_data <= i_cd_hps_data;
         trackinfo_data <= i_trackinfo_data; trackinfo_addr <= i_trackinfo_addr; trackinfo_write <= i_trackinfo_write;

         o_region_out <= region_out; o_pauseCD <= pauseCD; o_Pause_idle_cd <= Pause_idle_cd; o_fullyIdle <= fullyIdle;
         o_cdSlow <= cdSlow; o_error <= error; o_LBAdisplay <= LBAdisplay; o_irqOut <= irqOut;
         o_cd_left <= cd_left; o_cd_right <= cd_right; o_bus_dataRead <= bus_dataRead; o_dma_readdata <= dma_readdata;
         o_cd_hps_req <= hps_req; o_cd_hps_lba <= hps_lba; o_cd_hps_lba_sim <= hps_lba_sim; o_resetFromCD <= resetFromCD;
      end if;
   end process;

   icd_top : entity work.cd_top
   port map
   (
      clk1x => clk1x, ce => ce, reset => reset,
      INSTANTSEEK => '0', FORCECDSPEED => "000", LIMITREADSPEED => '0', hasCD => '1', LIDopen => '0',
      fastCD => '0', testSeek => '0', pauseOnCDSlow => '0',
      region => region, region_out => region_out,
      pauseCD => pauseCD, Pause_idle_cd => Pause_idle_cd, fullyIdle => fullyIdle, cdSlow => cdSlow,
      error => error, LBAdisplay => LBAdisplay, irqOut => irqOut,
      spu_tick => spu_tick, cd_left => cd_left, cd_right => cd_right, mdec_idle => mdec_idle,
      bus_addr => bus_addr, bus_dataWrite => bus_dataWrite, bus_read => bus_read, bus_write => bus_write,
      bus_dataRead => bus_dataRead, dma_read => dma_read, dma_readdata => dma_readdata,
      cd_hps_req => hps_req, cd_hps_lba => hps_lba, cd_hps_lba_sim => hps_lba_sim,
      cd_hps_ack => hps_ack, cd_hps_write => hps_write, cd_hps_data => hps_data,
      trackinfo_data => trackinfo_data, trackinfo_addr => trackinfo_addr, trackinfo_write => trackinfo_write,
      resetFromCD => resetFromCD,
      SS_reset => '0', SS_DataWrite => (others => '0'), SS_Adr => (others => '0'),
      SS_wren => '0', SS_rden => '0', SS_DataRead => open, SS_idle => open
   );

end architecture;
