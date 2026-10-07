-- Sizing-only wrapper: gpu_pocket_div with every port registered, on one clock.
-- Not a functional top level. Results: docs/pocket/GPU.md.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.pGPU_pocket.all;

entity gpu_div_wrap is
   generic
   (
      G_BITS_PER_CYCLE : positive := 4;
      G_DIVISOR_BITS   : positive := 10;
      G_DIVIDEND_BITS  : positive := 45
   );
   port
   (
      clk2x          : in  std_logic;
      i_start        : in  std_logic;
      i_dividend     : in  signed(44 downto 0);
      i_divisor      : in  signed(24 downto 0);
      i_qbits        : in  unsigned(5 downto 0);
      o_done         : out std_logic;
      o_busy         : out std_logic;
      o_quotient     : out signed(44 downto 0);
      o_qmag_lsb     : out std_logic
   );
end entity;

architecture arch of gpu_div_wrap is
   signal req : tdiv_req := DIV_REQ_IDLE;
   signal rsp : tdiv_rsp;
begin

   process (clk2x) is
   begin
      if rising_edge(clk2x) then
         req.start    <= i_start;
         req.dividend <= i_dividend;
         req.divisor  <= i_divisor;
         if i_qbits = 0 or i_qbits > 45 then req.qbits <= 1; else req.qbits <= to_integer(i_qbits); end if;
         o_done     <= rsp.done;
         o_busy     <= rsp.busy;
         o_quotient <= rsp.quotient;
         o_qmag_lsb <= rsp.qmag_lsb;
      end if;
   end process;

   div : entity work.gpu_pocket_div
      generic map (G_BITS_PER_CYCLE => G_BITS_PER_CYCLE, G_DIVISOR_BITS => G_DIVISOR_BITS, G_DIVIDEND_BITS => G_DIVIDEND_BITS)
      port map (clk => clk2x, req => req, rsp => rsp);

end architecture;
