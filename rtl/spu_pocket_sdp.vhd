-- Simple dual-port RAM of spu_pocket: one write port, one registered read port on the same clock. A read that coincides
-- with a write of the same address returns the old word. re = '0' holds q.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity spu_pocket_sdp is
   generic
   (
      ADDR_WIDTH : natural := 5;
      DATA_WIDTH : natural := 16
   );
   port
   (
      clk : in  std_logic;
      we  : in  std_logic;
      wa  : in  std_logic_vector(ADDR_WIDTH - 1 downto 0);
      d   : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
      re  : in  std_logic := '1';
      ra  : in  std_logic_vector(ADDR_WIDTH - 1 downto 0);
      q   : out std_logic_vector(DATA_WIDTH - 1 downto 0)
   );
end entity;

architecture rtl of spu_pocket_sdp is

   type mem_t is array (0 to 2 ** ADDR_WIDTH - 1) of std_logic_vector(DATA_WIDTH - 1 downto 0);
   signal ram : mem_t := (others => (others => '0'));

   attribute ramstyle : string;
   attribute ramstyle of ram : signal is "M10K";

begin

   process (clk)
   begin
      if (rising_edge(clk)) then
         if (we = '1') then
            ram(to_integer(unsigned(wa))) <= d;
         end if;
         if (re = '1') then
            q <= ram(to_integer(unsigned(ra)));
         end if;
      end if;
   end process;

end architecture;
