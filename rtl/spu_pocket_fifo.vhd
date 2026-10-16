-- Fall-through FIFO of spu_pocket with the behaviour of mem.SyncFifoFallThrough (Full, NearFull, Empty, Dout), without
-- the separate fill counter: the level is wrcnt - rdcnt. SIZE = 2 ** SIZEBITS, Full at SIZE - 1 entries.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity spu_pocket_fifo is
   generic
   (
      SIZEBITS    : integer;
      DATAWIDTH   : integer;
      NEARFULL_AT : integer
   );
   port
   (
      clk      : in  std_logic;
      reset    : in  std_logic;
      Din      : in  std_logic_vector(DATAWIDTH - 1 downto 0);
      Wr       : in  std_logic;
      Full     : out std_logic := '0';
      NearFull : out std_logic := '0';
      Dout     : out std_logic_vector(DATAWIDTH - 1 downto 0) := (others => '0');
      Rd       : in  std_logic;
      Empty    : out std_logic := '1'
   );
end entity;

architecture arch of spu_pocket_fifo is

   type t_memory is array(0 to 2 ** SIZEBITS - 1) of std_logic_vector(DATAWIDTH - 1 downto 0);
   signal memory : t_memory := (others => (others => '0'));

   signal wrcnt      : unsigned(SIZEBITS - 1 downto 0) := (others => '0');
   signal rdcnt      : unsigned(SIZEBITS - 1 downto 0) := (others => '0');
   signal wr_inc     : unsigned(SIZEBITS - 1 downto 0);
   signal rd_inc     : unsigned(SIZEBITS - 1 downto 0);
   signal level      : unsigned(SIZEBITS - 1 downto 0);
   signal full_wire  : std_logic;
   signal empty_wire : std_logic;
   signal empty_r    : std_logic := '1';
   signal full_r     : std_logic := '0';

begin

   wr_inc     <= wrcnt + 1;
   rd_inc     <= rdcnt + 1;
   level      <= wrcnt - rdcnt;
   full_wire  <= '1' when wr_inc = rdcnt else '0';
   empty_wire <= '1' when wrcnt = rdcnt  else '0';

   Empty <= empty_r;
   Full  <= full_r;

   process (clk)
   begin
      if (rising_edge(clk)) then
         if (reset = '1') then
            wrcnt   <= (others => '0');
            rdcnt   <= (others => '0');
            empty_r <= '1';
            full_r  <= '0';
         else
            if (level >= NEARFULL_AT) then NearFull <= '1'; else NearFull <= '0'; end if;

            if (Wr = '1' and full_wire = '0') then
               memory(to_integer(wrcnt)) <= Din;
               wrcnt <= wr_inc;
            end if;

            if (Rd = '1' and empty_wire = '0') then
               rdcnt <= rd_inc;
               Dout  <= memory(to_integer(rd_inc));
            else
               Dout  <= memory(to_integer(rdcnt));
            end if;

            -- empty now, or one entry that is being read
            if (empty_wire = '1' or (wrcnt = rd_inc and Rd = '1')) then
               empty_r <= '1';
            else
               empty_r <= '0';
            end if;

            -- full now, or the level reaches SIZE - 1 in this clock
            if (full_wire = '1' or (wr_inc + 1 = rdcnt and Wr = '1' and Rd = '0')) then
               full_r <= '1';
            else
               full_r <= '0';
            end if;
         end if;
      end if;
   end process;

end architecture;
