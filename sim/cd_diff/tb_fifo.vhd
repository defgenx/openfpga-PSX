-- Equivalence of cd_pocket_fifo with the library FIFOs it replaces (mem.SyncFifoFallThrough, mem.SyncFifo): random write and read
-- phases, full and empty corners, random resets; Empty, NearFull and Dout compared on every clock.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std;
use std.textio.all;
use std.env.all;
library mem;
use work.cd_diff_pkg.all;

entity tb_fifo is
   generic
   (
      G_SIZEBITS   : natural := 12;
      G_WIDTH      : natural := 8;
      G_FALLTHROUGH: natural := 1;
      G_SEED       : natural := 1;
      G_CYCLES     : natural := 3000000
   );
end entity;

architecture arch of tb_fifo is
   signal clk   : std_logic := '0';
   signal reset : std_logic := '1';
   signal din   : std_logic_vector(G_WIDTH - 1 downto 0) := (others => '0');
   signal wr, rd : std_logic := '0';
   signal g_nf, d_nf, g_empty, d_empty : std_logic;
   signal g_dout, d_dout : std_logic_vector(G_WIDTH - 1 downto 0);
   shared variable r : rng_t;
begin
   clk <= not clk after 5 ns;

   gold_ft : if G_FALLTHROUGH /= 0 generate
      ig : entity mem.SyncFifoFallThrough
      generic map (SIZE => 2 ** G_SIZEBITS, DATAWIDTH => G_WIDTH, NEARFULLDISTANCE => 16)
      port map (clk => clk, reset => reset, Din => din, Wr => wr, Full => open, NearFull => g_nf, Dout => g_dout, Rd => rd, Empty => g_empty);
   end generate;
   gold_nft : if G_FALLTHROUGH = 0 generate
      ig : entity mem.SyncFifo
      generic map (SIZE => 2 ** G_SIZEBITS, DATAWIDTH => G_WIDTH, NEARFULLDISTANCE => 16)
      port map (clk => clk, reset => reset, Din => din, Wr => wr, Full => open, NearFull => g_nf, Dout => g_dout, Rd => rd, Empty => g_empty);
   end generate;

   idut : entity work.cd_pocket_fifo
   generic map (SIZEBITS => G_SIZEBITS, DATAWIDTH => G_WIDTH, FALLTHROUGH => G_FALLTHROUGH /= 0)
   port map (clk => clk, reset => reset, Din => din, Wr => wr, NearFull => d_nf, Dout => d_dout, Rd => rd, Empty => d_empty);

   process
      variable cyc, bad, nfull, nempty, nnear : natural := 0;
      variable pw, pr : natural := 50;
      variable l : line;
   begin
      r.seed(G_SEED);
      while cyc < G_CYCLES loop
         wait until falling_edge(clk);
         if cyc mod 5000 = 0 then
            pw := r.rnd(101); pr := r.rnd(101);
            if r.rnd(4) = 0 then pw := 100; pr := 0; end if;     -- fill
            if r.rnd(4) = 0 then pw := 0; pr := 100; end if;     -- drain
         end if;
         reset <= '1' when (cyc < 3 or r.rnd(20000) = 0) else '0';
         wr <= '1' when r.rnd(100) < pw else '0';
         rd <= '1' when r.rnd(100) < pr else '0';
         din <= std_logic_vector(r.u32(G_WIDTH - 1 downto 0)) when false else std_logic_vector(resize(r.u32, G_WIDTH));
         wait until rising_edge(clk);
         wait for 1 ns;
         -- the library FIFO has no initial Dout or NearFull: undefined values are not compared
         if g_empty /= d_empty or (not is_x(g_nf) and g_nf /= d_nf) or (not is_x(g_dout) and g_dout /= d_dout) then
            bad := bad + 1;
            if bad <= 10 then
               write(l, string'("MISMATCH cycle=") & integer'image(cyc) & " empty " & std_logic'image(g_empty) & std_logic'image(d_empty) &
                     " nearfull " & std_logic'image(g_nf) & std_logic'image(d_nf) & " dout " & to_hstring(g_dout) & " " & to_hstring(d_dout));
               writeline(output, l);
            end if;
         end if;
         if g_empty = '1' then nempty := nempty + 1; end if;
         if g_nf = '1' then nnear := nnear + 1; end if;
         cyc := cyc + 1;
      end loop;
      write(l, string'("RESULT cycles=") & integer'image(cyc) & " compares=" & integer'image(cyc * 3) & " mismatches=" & integer'image(bad) &
            " empty_cycles=" & integer'image(nempty) & " nearfull_cycles=" & integer'image(nnear) & " ");
      if bad = 0 and nempty > 0 and nnear > 0 then write(l, string'("PASS")); else write(l, string'("FAIL")); end if;
      writeline(output, l);
      if bad = 0 and nempty > 0 and nnear > 0 then stop(0); else stop(1); end if;
      wait;
   end process;
end architecture;
