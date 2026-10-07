-- gpu_pocket_div (edge and gradient configurations) against the golden divider.vhd.
-- One run covers one operand class and one shard of it; see Makefile.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

use work.pGPU_pocket.all;

entity tb_divtest is
   generic
   (
      CLASS_NAME : string   := "edge";  -- edge | line | col | ppr | grad | rand
      SHARD      : natural  := 0;
      NSHARDS    : positive := 1;
      EDGE_DW    : positive := 45;      -- G_DIVIDEND_BITS of the edge configuration
      GRAD_DW    : positive := 45;      -- G_DIVIDEND_BITS of the gradient configuration
      MAXCASES   : natural  := 0        -- 0: whole class
   );
end entity;

architecture sim of tb_divtest is

   signal clk : std_logic := '0';

   signal g_start, g_done, g_busy : std_logic := '0';
   signal g_dividend : signed(44 downto 0) := (others => '0');
   signal g_divisor  : signed(24 downto 0) := (others => '0');
   signal g_quot     : signed(44 downto 0);
   signal g_rem      : signed(24 downto 0);

   signal req_e, req_g : tdiv_req := DIV_REQ_IDLE;
   signal rsp_e, rsp_g : tdiv_rsp;

   type tcase is record
      dividend : signed(44 downto 0);
      divisor  : signed(24 downto 0);
      qbits    : integer range 1 to 45;
   end record;

   function mix(x : unsigned(63 downto 0)) return unsigned is
      variable z : unsigned(63 downto 0) := x;
   begin
      z := resize((z + x"9E3779B97F4A7C15") * x"BF58476D1CE4E5B9", 64);
      z := z xor shift_right(z, 29);
      z := resize(z * x"94D049BB133111EB", 64);
      z := z xor shift_right(z, 32);
      return z;
   end function;

   function rnd(i : natural; salt : natural) return unsigned is
   begin
      return mix(to_unsigned(i, 32) & to_unsigned(salt, 32));
   end function;

   -- value in 0..n-1
   function rnd_below(i : natural; salt : natural; n : positive) return natural is
      variable r : unsigned(63 downto 0) := rnd(i, salt);
   begin
      return to_integer(r(30 downto 0)) mod n;
   end function;

   -- value below 2^k with k uniform in 1..maxbits
   function rnd_log(i : natural; salt : natural; maxbits : positive) return natural is
      variable k : natural := 1 + rnd_below(i, salt + 1000, maxbits);
      variable r : unsigned(63 downto 0) := rnd(i, salt);
   begin
      return to_integer(shift_right(r(30 downto 0), 31 - k));
   end function;

   constant GRAD_PMAX : natural := 521730;
   constant GRAD_DMAX : natural := 1046529;
   constant N_GFIX_A  : natural := 40;
   constant N_GFIX_B  : natural := 81;

   type tintvec is array (natural range <>) of integer;
   constant GFIX_A : tintvec(0 to N_GFIX_A - 1) := (
      0, 1, -1, 2, -2, 3, 255, 256, -256, 257, 4095, -4096, 4096, 4097, 65535, 65536, -65536, 131072,
      262143, 262144, -262144, 262145, 521729, 521730, -521730, -521729, 521728, 1000, -1000, 12345, -12345,
      16, 32, 64, 128, 512, 1024, 2048, 8192, -8192);
   constant GFIX_B : tintvec(0 to N_GFIX_B - 1) := (
      1, -1, 2, -2, 3, -3, 4, 5, 7, 8, -8, 15, 16, 17, 255, 256, -256, 257, 1023, 1024, -1024, 1025,
      4095, 4096, -4096, 4097, 8192, 12288, 16384, 65535, 65536, -65536, 65537, 131072, 262144, 524288,
      -524288, 1046527, 1046529, -1046529, 1046528, -1046528, 1046526, 1000000, 999999, 786432,
      524287, 524289, 4096 * 255, 4096 * 256, -4096 * 255, 4096 * 100, 4096 * 7, 4096 * 3, 8192 * 5,
      2 ** 19, 2 ** 18, 2 ** 17, 2 ** 16, 2 ** 15, 2 ** 14, 2 ** 13, 2 ** 12, 2 ** 11, 2 ** 10, 2 ** 9,
      2 ** 8, 2 ** 7, 2 ** 6, 2 ** 5, 100, 1000, 10000, 100000, -100, -1000, -10000, -100000, 0, 0, 6);

   function ncases(cls : string) return natural is
   begin
      if    cls = "edge" then return 2047 * 512;
      elsif cls = "line" then return 2047 * 1024;
      elsif cls = "col"  then return 511 * 1024;
      elsif cls = "ppr"  then return 1024 * 1023;
      elsif cls = "grad" then return N_GFIX_A * N_GFIX_B + 1200000;
      elsif cls = "rand" then return 1000000;
      else report "unknown class " & cls severity failure; return 0; end if;
   end function;

   function gen(cls : string; idx : natural; d0_bits : natural) return tcase is
      variable c    : tcase;
      variable dxi  : integer;
      variable dy   : integer;
      variable p    : integer;
      variable p1   : integer;
      variable dx1  : signed(44 downto 0);
      variable diff : integer;
      variable den  : integer;
      variable kind : natural;
      variable r    : natural;
      variable j    : natural;
   begin
      c.qbits := 43;
      if cls = "edge" then
         -- gpu_poly.vhd CALCBOUNDARY1
         dxi := idx / 512 - 1023;
         dy  := idx mod 512;
         dx1 := shift_left(to_signed(dxi, 45), 32);
         if    dx1 < 0 then dx1 := dx1 - (dy - 1);
         elsif dx1 > 0 then dx1 := dx1 + (dy - 1); end if;
         c.dividend := dx1;
         c.divisor  := to_signed(dy, 25);
      elsif cls = "line" then
         -- gpu_line.vhd PROCCALC2 (dx and dy share the form); points - 1 wraps in 10 bits
         dxi := idx / 1024 - 1023;
         p   := idx mod 1024;
         p1  := (p + 1023) mod 1024;
         dx1 := shift_left(to_signed(dxi, 45), 32);
         if dxi < 0 then dx1 := dx1 - p1; else dx1 := dx1 + p1; end if;
         c.dividend := dx1;
         c.divisor  := to_signed(p, 25);
      elsif cls = "col" then
         diff := idx / 1024 - 255;
         p    := idx mod 1024;
         c.dividend := shift_left(to_signed(diff, 45), 12);
         c.divisor  := to_signed(p, 25);
         c.qbits    := 21;
      elsif cls = "ppr" then
         p  := idx / 1023;
         dy := 1 + idx mod 1023;
         c.dividend := to_signed(p, 45);
         c.divisor  := to_signed(dy, 25);
         c.qbits    := 11;
      elsif cls = "rand" then
         -- any qbits 1..31 with a < 2^qbits and a divisor below 2^10; one case in 16 divides by zero
         c.qbits := 1 + rnd_below(idx, 20, 31);
         p   := rnd_log(idx, 21, c.qbits);
         den := rnd_log(idx, 22, 10);
         if rnd_below(idx, 23, 2) = 1 then p := -p; end if;
         if rnd_below(idx, 24, 2) = 1 then den := -den; end if;
         c.dividend := to_signed(p, 45);
         if idx mod 16 = 0 then
            c.dividend := signed(resize(rnd(idx, 25) srl (64 - d0_bits), 45));
            if rnd_below(idx, 26, 2) = 1 then c.dividend := -c.dividend; end if;
            den := 0;
         end if;
         c.divisor := to_signed(den, 25);
      else
         c.qbits := 31;
         if idx < N_GFIX_A * N_GFIX_B then
            diff := GFIX_A(idx / N_GFIX_B);
            den  := GFIX_B(idx mod N_GFIX_B);
         else
            j    := idx - N_GFIX_A * N_GFIX_B;
            kind := j mod 5;
            case kind is
               when 0 =>   -- uniform
                  diff := rnd_below(j, 1, 2 * GRAD_PMAX + 1) - GRAD_PMAX;
                  den  := rnd_below(j, 2, 2 * GRAD_DMAX + 1) - GRAD_DMAX;
               when 1 =>   -- random magnitudes
                  diff := rnd_log(j, 3, 19);
                  den  := rnd_log(j, 4, 20);
                  if rnd_below(j, 5, 2) = 1 then diff := -diff; end if;
                  if rnd_below(j, 6, 2) = 1 then den  := -den;  end if;
               when 2 =>   -- small denominators: large quotients
                  diff := rnd_below(j, 7, 2 * GRAD_PMAX + 1) - GRAD_PMAX;
                  den  := rnd_below(j, 8, 600) - 300;
               when 3 =>   -- near-exact: denominator close to diff * 4096 / k
                  diff := rnd_below(j, 9, 2 * GRAD_PMAX + 1) - GRAD_PMAX;
                  r    := 1 + rnd_below(j, 10, 4096);
                  den  := (diff * 4096) / r + rnd_below(j, 11, 3) - 1;
                  if den > GRAD_DMAX then den := GRAD_DMAX; elsif den < -GRAD_DMAX then den := -GRAD_DMAX; end if;
               when others =>   -- multiples of 4096 and powers of two
                  diff := rnd_below(j, 12, 2 * GRAD_PMAX + 1) - GRAD_PMAX;
                  if rnd_below(j, 13, 2) = 0 then
                     den := 4096 * (rnd_below(j, 14, 511) - 255);
                  else
                     den := 2 ** rnd_below(j, 15, 20);
                     if rnd_below(j, 16, 2) = 1 then den := -den; end if;
                  end if;
            end case;
         end if;
         c.dividend := shift_left(to_signed(diff, 45), 12);
         c.divisor  := to_signed(den, 25);
      end if;
      return c;
   end function;

   function use_edge(cls : string) return boolean is
   begin return cls /= "grad"; end function;
   function use_grad(cls : string) return boolean is
   begin return cls = "grad" or cls = "col" or cls = "ppr" or cls = "rand"; end function;

begin

   clk <= not clk after 5 ns;

   golden : entity work.divider
      port map (clk => clk, start => g_start, done => g_done, busy => g_busy,
                dividend => g_dividend, divisor => g_divisor, quotient => g_quot, remainder => g_rem);

   dut_edge : entity work.gpu_pocket_div
      generic map (G_BITS_PER_CYCLE => 4, G_DIVISOR_BITS => 10, G_DIVIDEND_BITS => EDGE_DW)
      port map (clk => clk, req => req_e, rsp => rsp_e);

   dut_grad : entity work.gpu_pocket_div
      generic map (G_BITS_PER_CYCLE => 2, G_DIVISOR_BITS => 21, G_DIVIDEND_BITS => GRAD_DW)
      port map (clk => clk, req => req_g, rsp => rsp_g);

   stim : process
      alias g_qu is <<signal .tb_divtest.golden.quotient_u : unsigned(45 downto 0)>>;

      type tlat is array (0 to 45) of integer;
      variable lat_e_min, lat_e_max, lat_g_min, lat_g_max : tlat;
      variable c         : tcase;
      variable n         : natural;
      variable total     : natural := ncases(CLASS_NAME);
      variable idx       : natural;
      variable mism      : natural := 0;
      variable ran       : natural := 0;
      variable cyc       : natural;
      variable seen_g, seen_e, seen_d : boolean;
      variable lat_g, lat_e, lat_d    : integer;
      variable q_g, q_e, q_d          : signed(44 downto 0);
      variable l_g, l_e, l_d          : std_logic;
      variable ue, ug    : boolean;
      variable golden_lat_min, golden_lat_max : integer := 1000000;

      procedure fail(msg : string) is
      begin
         mism := mism + 1;
         if mism <= 20 then
            report "MISMATCH " & CLASS_NAME & " " & msg & " dividend=" & to_hstring(c.dividend) &
                   " divisor=" & to_hstring(c.divisor) & " qbits=" & integer'image(c.qbits) severity warning;
         end if;
      end procedure;
   begin
      for i in 0 to 45 loop
         lat_e_min(i) := 1000000; lat_e_max(i) := -1;
         lat_g_min(i) := 1000000; lat_g_max(i) := -1;
      end loop;
      ue := use_edge(CLASS_NAME);
      ug := use_grad(CLASS_NAME);
      if MAXCASES /= 0 and MAXCASES < total then total := MAXCASES; end if;
      golden_lat_max := 0;

      n := 0;
      while n * NSHARDS + SHARD < total loop
         idx := n * NSHARDS + SHARD;
         n   := n + 1;
         c   := gen(CLASS_NAME, idx, minimum(EDGE_DW, GRAD_DW));

         wait until rising_edge(clk);
         g_start <= '1'; g_dividend <= c.dividend; g_divisor <= c.divisor;
         if ue then req_e <= ('1', c.dividend, c.divisor, c.qbits); end if;
         if ug then req_g <= ('1', c.dividend, c.divisor, c.qbits); end if;

         wait until rising_edge(clk);            -- the edge that samples start
         g_start <= '0'; g_dividend <= (others => '0'); g_divisor <= (others => '0');
         req_e <= DIV_REQ_IDLE; req_g <= DIV_REQ_IDLE;

         seen_g := false; seen_e := not ue; seen_d := not ug;
         lat_g := 0; lat_e := 0; lat_d := 0;
         cyc := 0;
         while not (seen_g and seen_e and seen_d) loop
            wait until rising_edge(clk);
            wait for 1 ns;
            cyc := cyc + 1;
            if g_done = '1' then
               if seen_g then fail("golden done twice"); end if;
               seen_g := true; lat_g := cyc; q_g := g_quot; l_g := g_qu(0);
            end if;
            if ue and rsp_e.done = '1' then
               if seen_e then fail("edge done twice"); end if;
               seen_e := true; lat_e := cyc; q_e := rsp_e.quotient; l_e := rsp_e.qmag_lsb;
            end if;
            if ug and rsp_g.done = '1' then
               if seen_d then fail("gradient done twice"); end if;
               seen_d := true; lat_d := cyc; q_d := rsp_g.quotient; l_d := rsp_g.qmag_lsb;
            end if;
            if ue and not seen_e and rsp_e.busy /= '1' then fail("edge busy low before done"); end if;
            if ug and not seen_d and rsp_g.busy /= '1' then fail("gradient busy low before done"); end if;
            if cyc > 200 then fail("timeout"); exit; end if;
         end loop;
         if ue and rsp_e.busy = '1' then fail("edge busy after done"); end if;
         if ug and rsp_g.busy = '1' then fail("gradient busy after done"); end if;

         if ue then
            if q_e /= q_g then fail("edge quotient got " & to_hstring(q_e) & " golden " & to_hstring(q_g)); end if;
            if l_e /= l_g then fail("edge qmag_lsb got " & std_logic'image(l_e) & " golden " & std_logic'image(l_g)); end if;
            lat_e_min(c.qbits) := minimum(lat_e_min(c.qbits), lat_e);
            lat_e_max(c.qbits) := maximum(lat_e_max(c.qbits), lat_e);
         end if;
         if ug then
            if q_d /= q_g then fail("gradient quotient got " & to_hstring(q_d) & " golden " & to_hstring(q_g)); end if;
            if l_d /= l_g then fail("gradient qmag_lsb got " & std_logic'image(l_d) & " golden " & std_logic'image(l_g)); end if;
            lat_g_min(c.qbits) := minimum(lat_g_min(c.qbits), lat_d);
            lat_g_max(c.qbits) := maximum(lat_g_max(c.qbits), lat_d);
         end if;
         golden_lat_min := minimum(golden_lat_min, lat_g);
         golden_lat_max := maximum(golden_lat_max, lat_g);
         ran := ran + 1;
      end loop;

      for i in 0 to 45 loop
         if lat_e_max(i) >= 0 then
            report "LATENCY edge qbits=" & integer'image(i) & " min=" & integer'image(lat_e_min(i)) & " max=" & integer'image(lat_e_max(i));
            if lat_e_min(i) /= lat_e_max(i) then mism := mism + 1; end if;
         end if;
         if lat_g_max(i) >= 0 then
            report "LATENCY gradient qbits=" & integer'image(i) & " min=" & integer'image(lat_g_min(i)) & " max=" & integer'image(lat_g_max(i));
            if lat_g_min(i) /= lat_g_max(i) then mism := mism + 1; end if;
         end if;
      end loop;
      report "LATENCY golden min=" & integer'image(golden_lat_min) & " max=" & integer'image(golden_lat_max);
      report "RESULT " & CLASS_NAME & " shard " & integer'image(SHARD) & "/" & integer'image(NSHARDS) &
             " cases=" & integer'image(ran) & " mismatches=" & integer'image(mism);
      stop(0);
      wait;
   end process;

end architecture;
