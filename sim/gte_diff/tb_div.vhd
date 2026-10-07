-- Exhaustive bit-exact comparison of gte_serial_div against gte_UNRDivide,
-- plus range checks on the golden's internal values (via external names).
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

entity tb_div is
   generic (selftest : boolean := false);
end entity;

architecture sim of tb_div is

   signal clk2x     : std_logic := '0';
   signal trigger   : std_logic := '0';
   signal lhs       : unsigned(15 downto 0) := (others => '0');
   signal rhs       : unsigned(15 downto 0) := (others => '0');
   signal g_result  : unsigned(16 downto 0);
   signal g_error   : std_logic;
   signal d_result  : unsigned(16 downto 0);
   signal d_error   : std_logic;
   signal done      : boolean := false;

begin

   golden : entity work.gte_UNRDivide
   port map (clk2x => clk2x, trigger => trigger, lhs => lhs, rhs => rhs,
             result => g_result, divError => g_error);

   dut : entity work.gte_serial_div
   port map (clk2x => clk2x, ce => '1', trigger => trigger, lhs => lhs, rhs => rhs,
             result => d_result, divError => d_error);

   clk2x <= not clk2x after 5 ns when not done else clk2x;

   ------------------------------------------------------------------
   -- stimulus: sweep every rhs; pass 0 = trigger every cycle, pass 1 = random gaps
   ------------------------------------------------------------------
   stim : process
      variable seed : unsigned(31 downto 0) := x"1234ABCD";
      type tlist is array(0 to 31) of natural;
      variable l : tlist;
      variable n : natural;

      impure function rnd16 return unsigned is
      begin
         seed := resize(seed * x"0019660D", 32) + x"3C6EF35F";
         return seed(31 downto 16);
      end function;

      procedure add(v : integer) is
      begin
         if v >= 0 and v <= 16#FFFF# then
            l(n) := v; n := n + 1;
         end if;
      end procedure;

      procedure drive(lv, rv : natural; gaps : boolean) is
         variable r : unsigned(15 downto 0);
      begin
         if gaps then
            -- idle cycles with garbage on the data inputs
            r := rnd16;
            for k in 1 to to_integer(r(1 downto 0)) loop
               trigger <= '0';
               lhs <= rnd16;
               rhs <= rnd16;
               wait until rising_edge(clk2x);
            end loop;
         end if;
         trigger <= '1';
         lhs <= to_unsigned(lv, 16);
         rhs <= to_unsigned(rv, 16);
         wait until rising_edge(clk2x);
      end procedure;
   begin
      wait until rising_edge(clk2x);
      for pass in 0 to 1 loop
         for rv in 0 to 65535 loop
            n := 0;
            add(0); add(16#FFFF#);
            add(2*rv - 1); add(2*rv); add(2*rv + 1);
            -- quotient just under / over the 0x1FFFF clamp
            add((2*rv - (rv + 16#8000#) / 16#10000#) - 1);
            add((2*rv - (rv + 16#8000#) / 16#10000#));
            add((2*rv - (rv + 16#8000#) / 16#10000#) + 1);
            add(2*rv - 2);
            for k in 1 to 4 loop
               add(to_integer(rnd16));
            end loop;
            for k in 0 to n - 1 loop
               drive(l(k), rv, pass = 1);
            end loop;
         end loop;
      end loop;
      trigger <= '0';
      for k in 1 to 12 loop
         wait until rising_edge(clk2x);
      end loop;
      done <= true;
      wait;
   end process;

   ------------------------------------------------------------------
   -- checker
   ------------------------------------------------------------------
   check : process
      alias g_trig5 is << signal .tb_div.golden.trigger_5 : std_logic >>;
      alias g_trig6 is << signal .tb_div.golden.trigger_6 : std_logic >>;
      alias g_d     is << signal .tb_div.golden.calc_val_d : signed(19 downto 0) >>;
      alias g_r     is << signal .tb_div.golden.calc_val_r : unsigned(19 downto 0) >>;
      alias g_lhs5  is << signal .tb_div.golden.lhs_5 : unsigned(15 downto 0) >>;
      alias g_sc5   is << signal .tb_div.golden.shiftcount_5 : integer range 0 to 15 >>;

      variable started    : boolean := false;
      variable divides    : natural := 0;
      variable mismatches : natural := 0;
      variable range_fails: natural := 0;
      variable forced     : boolean := false;
      variable min_d      : integer := integer'high;
      variable max_d      : integer := integer'low;
      variable max_r      : integer := 0;
      variable max_sh     : integer := 0;
      variable dv, sh     : integer;
      variable ok         : boolean;
   begin
      loop
         wait until rising_edge(clk2x) or done;
         exit when done;

         if started then
            if g_result /= d_result or g_error /= d_error then
               mismatches := mismatches + 1;
               if mismatches <= 10 then
                  report "mismatch: golden=" & to_hstring(g_result) & "/" & std_logic'image(g_error) &
                         " dut=" & to_hstring(d_result) & "/" & std_logic'image(d_error) severity error;
               end if;
            end if;
         end if;

         if trigger = '1' then divides := divides + 1; end if;
         if g_trig6 = '1' then
            started := true;
            if to_integer(g_r) > max_r then max_r := to_integer(g_r); end if;
         end if;

         if g_trig5 = '1' then
            dv := to_integer(g_d);
            if selftest and not forced then
               dv := 200000; forced := true;
            end if;
            if dv < min_d then min_d := dv; end if;
            if dv > max_d then max_d := dv; end if;
            if dv < -131072 or dv > 131071 then
               range_fails := range_fails + 1;
            end if;
            sh := to_integer(g_lhs5) * 2**g_sc5;
            if sh > max_sh then max_sh := sh; end if;
         end if;
      end loop;

      report "DIVTEST divides=" & integer'image(divides) &
             " mismatches=" & integer'image(mismatches) &
             " range_fails=" & integer'image(range_fails) &
             " min_d=" & integer'image(min_d) & " max_d=" & integer'image(max_d) &
             " max_r=" & integer'image(max_r) & " max_shifted_lhs=" & integer'image(max_sh) &
             " sub_2^31=" & boolean'image(max_sh / 65536 < 32768) &
             " r_fits_18u=" & boolean'image(max_r < 2**18);
      if selftest then
         ok := range_fails = 1 and mismatches = 0;
         report "DIVTEST-SELFTEST " & boolean'image(ok);
         if not ok then report "DIVTEST FAIL" severity failure; end if;
         report "DIVTEST-SELFTEST PASS";
      else
         ok := mismatches = 0 and range_fails = 0 and divides > 0;
         if ok then
            report "DIVTEST PASS";
         else
            report "DIVTEST FAIL" severity failure;
         end if;
      end if;
      finish;
   end process;

end architecture;
