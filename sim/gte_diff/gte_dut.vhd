library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Port list of gte; the Makefile analyses one of two architectures (golden, serial).
entity gte_dut is
   port
   (
      clk1x                : in  std_logic;
      clk2x                : in  std_logic;
      clk2xIndex           : in  std_logic;
      ce                   : in  std_logic;
      reset                : in  std_logic;

      WIDESCREEN           : in  std_logic_vector(1 downto 0);
      TURBO                : in  std_logic;

      gte_busy             : out std_logic;
      gte_readAddr         : in  unsigned(5 downto 0);
      gte_readData         : out unsigned(31 downto 0);
      gte_readEna          : in  std_logic;
      gte_writeAddr_in     : in  unsigned(5 downto 0);
      gte_writeData_in     : in  unsigned(31 downto 0);
      gte_writeEna_in      : in  std_logic;
      gte_cmdData          : in  unsigned(31 downto 0);
      gte_cmdEna           : in  std_logic;

      loading_savestate    : in  std_logic;
      SS_reset             : in  std_logic;
      SS_DataWrite         : in  std_logic_vector(31 downto 0);
      SS_Adr               : in  unsigned(5 downto 0);
      SS_wren              : in  std_logic;
      SS_rden              : in  std_logic;
      SS_DataRead          : out std_logic_vector(31 downto 0);
      SS_idle              : out std_logic;

      debug_firstGTE       : out std_logic
   );
end entity;
