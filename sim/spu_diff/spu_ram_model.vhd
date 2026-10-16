-- SPU RAM model on the sdram_* port of the SPU: 512 KB of 16-bit words, one outstanding request, the response (sdram_done and
-- sdram_dataRead) arrives G_LATMIN .. G_LATMAX clk1x cycles after the request cycle. A read returns {word(a+2), word(a)}
-- for byte address a; a write stores sdram_dataWrite(15 downto 0). sdram_dataRead carries a cycle-keyed pattern while no
-- response is due. The image is an ADPCM-like block pattern derived from G_IMAGE.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.spu_diff_pkg.all;

entity spu_ram_model is
   generic
   (
      G_IMAGE  : natural := 1;
      G_LATSEED: natural := 1;
      G_LATMIN : natural := 1;
      G_LATMAX : natural := 1
   );
   port
   (
      clk            : in  std_logic;
      ena            : in  std_logic;
      rnw            : in  std_logic;
      adr            : in  std_logic_vector(18 downto 0);
      dataWrite      : in  std_logic_vector(31 downto 0);
      be             : in  std_logic_vector(3 downto 0);
      done           : out std_logic := '0';
      dataRead       : out std_logic_vector(31 downto 0) := (others => '0');
      reqs           : out natural := 0;
      writes         : out natural := 0
   );
end entity;

architecture arch of spu_ram_model is
   type mem_t is array (0 to 262143) of std_logic_vector(15 downto 0);

   impure function init return mem_t is
      variable m : mem_t;
      variable h : unsigned(31 downto 0);
      variable blk, pos : natural;
      variable hdr : std_logic_vector(15 downto 0);
   begin
      for w in 0 to 262143 loop
         blk := w / 8; pos := w mod 8;
         h := hash32(w, G_IMAGE);
         if pos = 0 then
            -- shift 0..12 mostly (13..15 sometimes), filter 0..4 mostly (5..7 sometimes), flags: end, repeat, start
            hdr := (others => '0');
            if h(31 downto 29) = "111" then hdr(3 downto 0) := std_logic_vector(h(3 downto 0));
            else hdr(3 downto 0) := std_logic_vector(to_unsigned(to_integer(h(3 downto 0)) mod 13, 4)); end if;
            if h(28 downto 26) = "111" then hdr(6 downto 4) := std_logic_vector(h(6 downto 4));
            else hdr(6 downto 4) := std_logic_vector(to_unsigned(to_integer(h(6 downto 4)) mod 5, 3)); end if;
            hdr(8)  := h(12) and h(13) and h(14);                  -- end, 1/8
            hdr(9)  := h(15);                                      -- repeat
            hdr(10) := h(16) and h(17);                            -- start, 1/4
            hdr(15 downto 11) := (others => '0');
            m(w) := hdr;
         else
            m(w) := std_logic_vector(h(15 downto 0));
         end if;
      end loop;
      return m;
   end function;

begin

   process (clk)
      variable mem   : mem_t := init;
      variable rl    : rng_t;
      variable pend  : natural := 0;
      variable q_adr : natural := 0;
      variable q_rnw : std_logic := '1';
      variable q_dat : std_logic_vector(15 downto 0) := (others => '0');
      variable n_req : natural := 0;
      variable n_wr  : natural := 0;
      variable cyc   : natural := 0;
      variable seeded: boolean := false;
      variable g     : unsigned(31 downto 0);
      variable w1    : natural;
   begin
      if rising_edge(clk) then
         if not seeded then rl.seed(G_LATSEED); seeded := true; end if;
         cyc := cyc + 1;
         g := hash32(cyc, 77 + G_IMAGE);
         done     <= '0';
         dataRead <= std_logic_vector(g);
         if ena = '1' then
            assert pend = 0 report "spu_ram_model: request while one is outstanding" severity failure;
            q_adr := to_integer(unsigned(adr(18 downto 1)));
            q_rnw := rnw;
            q_dat := dataWrite(15 downto 0);
            pend  := rl.between(G_LATMIN, G_LATMAX);
            n_req := n_req + 1;
            reqs  <= n_req;
         end if;
         if pend > 0 then
            pend := pend - 1;
            if pend = 0 then
               done <= '1';
               if q_rnw = '1' then
                  w1 := (q_adr + 1) mod 262144;
                  dataRead <= mem(w1) & mem(q_adr);
               else
                  mem(q_adr) := q_dat;
                  n_wr := n_wr + 1;
                  writes <= n_wr;
               end if;
            end if;
         end if;
      end if;
   end process;

end architecture;
