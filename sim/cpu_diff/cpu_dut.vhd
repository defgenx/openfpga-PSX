-- Device under test: the golden cpu port list. Architectures: dut_golden.vhd (the frozen cpu, harness
-- smoke test) and dut_pocket.vhd (cpu_pocket).
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.pexport.all;

entity cpu_dut is
   generic
   (
      G_NO_COP0_DEBUG : boolean := false
   );
   port
   (
      clk1x                 : in  std_logic;
      clk2x                 : in  std_logic;
      clk3x                 : in  std_logic;
      ce                    : in  std_logic;
      reset                 : in  std_logic;
      TURBO                 : in  std_logic;
      TURBO_CACHE           : in  std_logic;
      TURBO_CACHE50         : in  std_logic;
      irqRequest            : in  std_logic;
      dmaStallCPU           : in  std_logic;
      cpuPaused             : in  std_logic;
      error                 : out std_logic;
      error2                : out std_logic;
      mem_request           : out std_logic;
      mem_rnw               : out std_logic;
      mem_isData            : out std_logic;
      mem_isCache           : out std_logic;
      mem_oldtagvalids      : out std_logic_vector(3 downto 0);
      mem_addressInstr      : out unsigned(31 downto 0);
      mem_addressData       : out unsigned(31 downto 0);
      mem_reqsize           : out unsigned(1 downto 0);
      mem_writeMask         : out std_logic_vector(3 downto 0);
      mem_dataWrite         : out std_logic_vector(31 downto 0);
      mem_dataRead          : in  std_logic_vector(31 downto 0);
      mem_done              : in  std_logic;
      mem_fifofull          : in  std_logic;
      mem_tagvalids         : in  std_logic_vector(3 downto 0);
      cache_wr              : in  std_logic_vector(3 downto 0);
      cache_data            : in  std_logic_vector(31 downto 0);
      cache_addr            : in  std_logic_vector(7 downto 0);
      stallNext             : out std_logic;
      dma_cache_Adr         : in  std_logic_vector(20 downto 0);
      dma_cache_data        : in  std_logic_vector(31 downto 0);
      dma_cache_write       : in  std_logic;
      ram_done              : in  std_logic;
      ram_rnw               : in  std_logic;
      ram_dataRead          : in  std_logic_vector(31 downto 0);
      gte_busy              : in  std_logic;
      gte_readEna           : out std_logic;
      gte_readAddr          : out unsigned(5 downto 0);
      gte_readData          : in  unsigned(31 downto 0);
      gte_writeAddr         : out unsigned(5 downto 0);
      gte_writeData         : out unsigned(31 downto 0);
      gte_writeEna          : out std_logic;
      gte_cmdData           : out unsigned(31 downto 0);
      gte_cmdEna            : out std_logic;
      SS_reset              : in  std_logic;
      SS_idle               : out std_logic;
      cpu_done              : out std_logic;
      cpu_export            : out cpu_export_type
   );
end entity;
