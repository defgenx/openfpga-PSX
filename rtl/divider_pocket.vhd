library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Restoring divider, one quotient bit per clock, signed or unsigned, for cpu_pocket.
-- The result is valid 35 clocks after the start edge and holds until the next start:
--   clock 1: |dividend|, clock 2: |divisor|, clocks 3..34: 32 quotient steps, clock 35: quotient sign.
-- One 33-bit subtractor serves the quotient steps and the three negations; the remainder sign is applied at the output.
-- A zero divisor gives quotient 0xFFFFFFFF (1 for a negative signed dividend) and the dividend as remainder, and
-- 0x80000000 / -1 gives 0x80000000 and 0: the PSX results, without special cases.
entity divider_pocket is
   port
   (
      clk       : in  std_logic;
      start     : in  std_logic;
      isSigned  : in  std_logic;
      dividend  : in  unsigned(31 downto 0);
      divisor   : in  unsigned(31 downto 0);
      quotient  : out unsigned(31 downto 0);
      remainder : out unsigned(31 downto 0)
   );
end entity;

architecture arch of divider_pocket is

   signal cnt     : unsigned(5 downto 0) := to_unsigned(63, 6);
   signal Q       : unsigned(31 downto 0) := (others => '0');
   signal R       : unsigned(31 downto 0) := (others => '0');
   signal D       : unsigned(31 downto 0) := (others => '0');
   signal signA   : std_logic := '0';
   signal signB   : std_logic := '0';

   signal subX    : unsigned(32 downto 0);
   signal subY    : unsigned(32 downto 0);
   signal subT    : unsigned(33 downto 0);
   signal stepRun : std_logic;
   signal negQ    : std_logic;
   signal negD    : std_logic;

begin

   -- cnt: 0 abs(dividend), 1 abs(divisor), 2..33 steps, 34 quotient sign, 35.. idle (63 after start/idle)
   stepRun <= '1' when (cnt >= 2 and cnt <= 33) else '0';
   negQ    <= '1' when ((cnt = 0 and signA = '1') or (cnt = 34 and (signA xor signB) = '1')) else '0';
   negD    <= '1' when (cnt = 1 and signB = '1') else '0';

   subX    <= R(31 downto 0) & Q(31) when (stepRun = '1') else (others => '0');
   subY    <= '0' & Q when (cnt = 0 or cnt = 34) else '0' & D;
   subT    <= ('0' & subX) - ('0' & subY);

   quotient  <= Q;
   remainder <= (0 - R) when (signA = '1') else R;

   process (clk)
   begin
      if (rising_edge(clk)) then

         if (start = '1') then

            cnt   <= (others => '0');
            Q     <= dividend;
            D     <= divisor;
            R     <= (others => '0');
            signA <= isSigned and dividend(31);
            signB <= isSigned and divisor(31);

         else

            if (cnt /= 63) then
               if (cnt = 35) then
                  cnt <= to_unsigned(63, 6);
               else
                  cnt <= cnt + 1;
               end if;
            end if;

            if (negQ = '1') then
               Q <= subT(31 downto 0);
            end if;

            if (negD = '1') then
               D <= subT(31 downto 0);
            end if;

            if (stepRun = '1') then
               if (subT(33) = '0') then
                  R <= subT(31 downto 0);
                  Q <= Q(30 downto 0) & '1';
               else
                  R <= subX(31 downto 0);
                  Q <= Q(30 downto 0) & '0';
               end if;
            end if;

         end if;

      end if;
   end process;

end architecture;
