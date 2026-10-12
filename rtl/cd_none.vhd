library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- CD-ROM stand-in for builds without a disc drive (G_CD_IMPL = "none"). Port list equals entity cd_top.
-- Status (0x1F801800) reads 0x18 | index: PRMEMPT and PRMWRDY set; BUSYSTS, DRQSTS, RSLRRDY, ADPBUSY
-- clear (power-on value of cd_top.vhd:3243, bits 7..2 as at :591-596). The index is the last value
-- written to 0x1800 bits 1:0. 0x1803 reads 0xE0 (empty IRQ flag, as cd_top.vhd:695-698); 0x1801 and
-- 0x1802 read 0. No command ever completes and no IRQ is raised.
-- Documented in docs/pocket/POCKET_TOP.md, "Per-block implementation generics".

entity cd_none is
   port
   (
      clk1x                : in  std_logic;
      ce                   : in  std_logic;
      reset                : in  std_logic;

      INSTANTSEEK          : in  std_logic;
      FORCECDSPEED         : in  std_logic_vector(2 downto 0);
      LIMITREADSPEED       : in  std_logic;
      hasCD                : in  std_logic;
      LIDopen              : in  std_logic;
      fastCD               : in  std_logic;
      testSeek             : in  std_logic;
      pauseOnCDSlow        : in  std_logic;
      region               : in  std_logic_vector(1 downto 0);
      region_out           : out std_logic_vector(1 downto 0);

      pauseCD              : out std_logic := '0';
      Pause_idle_cd        : out std_logic := '0';
      fullyIdle            : out std_logic;
      cdSlow               : out std_logic := '0';
      error                : out std_logic := '0';
      LBAdisplay           : out unsigned(19 downto 0);

      irqOut               : out std_logic := '0';

      spu_tick             : in  std_logic;
      cd_left              : out signed(15 downto 0) := (others => '0');
      cd_right             : out signed(15 downto 0) := (others => '0');

      mdec_idle            : in  std_logic;

      bus_addr             : in  unsigned(3 downto 0);
      bus_dataWrite        : in  std_logic_vector(7 downto 0);
      bus_read             : in  std_logic;
      bus_write            : in  std_logic;
      bus_dataRead         : out std_logic_vector(7 downto 0) := (others => '0');

      dma_read             : in  std_logic;
      dma_readdata         : out std_logic_vector(7 downto 0);

      cd_hps_req           : out std_logic := '0';
      cd_hps_lba           : out std_logic_vector(31 downto 0);
      cd_hps_lba_sim       : out std_logic_vector(31 downto 0) := (others => '0');
      cd_hps_ack           : in  std_logic;
      cd_hps_write         : in  std_logic;
      cd_hps_data          : in  std_logic_vector(15 downto 0);

      trackinfo_data       : in  std_logic_vector(31 downto 0);
      trackinfo_addr       : in  std_logic_vector(8 downto 0);
      trackinfo_write      : in  std_logic;
      resetFromCD          : out std_logic := '0';

      SS_reset             : in  std_logic;
      SS_DataWrite         : in  std_logic_vector(31 downto 0);
      SS_Adr               : in  unsigned(13 downto 0);
      SS_wren              : in  std_logic;
      SS_rden              : in  std_logic;
      SS_DataRead          : out std_logic_vector(31 downto 0);
      SS_idle              : out std_logic
   );
end entity;

architecture arch of cd_none is

   signal index : std_logic_vector(1 downto 0) := "00";

begin

   process (clk1x)
   begin
      if rising_edge(clk1x) then

         if (reset = '1') then
            index <= "00";
         elsif (bus_write = '1' and bus_addr = x"0") then
            index <= bus_dataWrite(1 downto 0);
         end if;

         bus_dataRead <= (others => '0');
         if (bus_read = '1') then
            case (bus_addr) is
               when x"0"   => bus_dataRead <= "00011" & "0" & index;
               when x"3"   => bus_dataRead <= x"E0";
               when others => null;
            end case;
         end if;

      end if;
   end process;

   region_out     <= region;
   pauseCD        <= '0';
   Pause_idle_cd  <= '1';
   fullyIdle      <= '1';
   cdSlow         <= '0';
   error          <= '0';
   LBAdisplay     <= (others => '0');
   irqOut         <= '0';
   cd_left        <= (others => '0');
   cd_right       <= (others => '0');
   dma_readdata   <= (others => '0');
   cd_hps_req     <= '0';
   cd_hps_lba     <= (others => '0');
   cd_hps_lba_sim <= (others => '0');
   resetFromCD    <= '0';
   SS_DataRead    <= (others => '0');
   SS_idle        <= '1';

end architecture;
