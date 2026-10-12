library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
library STD;
use STD.textio.all;
use STD.env.all;

-- divider_pocket against the golden divider at the clock where cpu_pocket samples the result (35 clocks after the start edge).
-- Operands: edge values, powers of two, small values and random values, signed and unsigned, with zero divisors and
-- 0x80000000 / -1 (their results are the PSX special values of cpu.vhd, not the golden divider's).
entity tb_div is
   generic
   (
      G_PAIRS : natural := 200000;
      G_SEED  : natural := 1;
      G_LATENCY : natural := 35;    -- clocks after the start edge at which the result is read (selftest: 34 must fail)
      G_FAULT : natural := 0        -- selftest: flip a bit of the golden quotient it is compared with
   );
end entity;

architecture arch of tb_div is

   signal clk       : std_logic := '1';
   signal start     : std_logic := '0';
   signal isSigned  : std_logic := '0';
   signal a, b      : unsigned(31 downto 0) := (others => '0');
   signal gdiv, gdis : signed(32 downto 0) := (others => '0');
   signal gq, gr    : signed(32 downto 0);
   signal pq, pr    : unsigned(31 downto 0);

begin

   clk <= not clk after 5 ns;

   igold : entity work.divider
   port map (clk => clk, start => start, done => open, busy => open, dividend => gdiv, divisor => gdis, quotient => gq, remainder => gr);

   ipocket : entity work.divider_pocket
   port map (clk => clk, start => start, isSigned => isSigned, dividend => a, divisor => b, quotient => pq, remainder => pr);

   process
      variable seed : unsigned(31 downto 0) := resize(to_unsigned(G_SEED + 1, 32) * unsigned'(x"9E3779B1"), 32) xor x"2545F491";
      variable n_ok, n_bad : natural := 0;
      variable l : line;
      type edge_t is array (natural range <>) of unsigned(31 downto 0);
      constant EDGE : edge_t := (x"00000000", x"00000001", x"00000002", x"00000003", x"7FFFFFFF", x"80000000", x"80000001", x"FFFFFFFF",
                                 x"FFFFFFFE", x"0000FFFF", x"00010000", x"FFFF0000", x"12345678", x"55555555", x"AAAAAAAA", x"00000100",
                                 x"7FFF0000", x"0000FFFE", x"FFFF8000", x"00008000");
      variable va, vb : unsigned(31 downto 0);
      variable vs : std_logic;
      variable r : natural;
      variable eq, er : unsigned(31 downto 0);
      variable q_exp, r_exp : unsigned(31 downto 0);
      variable shift : natural;

      procedure rnd is
         variable x : unsigned(31 downto 0) := seed;
      begin
         x := x xor shift_left(x, 13); x := x xor shift_right(x, 17); x := x xor shift_left(x, 5);
         seed := x;
      end procedure;
   begin
      for k in 0 to G_PAIRS - 1 loop
         rnd;
         vs := seed(0);
         rnd; r := to_integer(seed(7 downto 0));
         rnd; va := seed;
         rnd; vb := seed;
         case (r mod 8) is
            when 0 => va := EDGE(to_integer(seed(4 downto 0)) mod EDGE'length);
            when 1 => vb := EDGE(to_integer(seed(9 downto 5)) mod EDGE'length);
            when 2 => shift := to_integer(seed(14 downto 10)); vb := shift_left(to_unsigned(1, 32), shift);
            when 3 => shift := to_integer(seed(14 downto 10)); va := shift_left(to_unsigned(1, 32), shift) - to_unsigned(r mod 3, 32);
            when 4 => vb := resize(seed(15 downto 8), 32); if seed(31) = '1' then vb := not vb; end if;
            when 5 => vb := shift_right(vb, to_integer(seed(20 downto 16)));
            when 6 => va := shift_right(va, to_integer(seed(20 downto 16)));
            when others => null;
         end case;
         if (r mod 16) = 3 then vb := x"00000000"; end if;
         if (r mod 16) = 5 and vs = '1' then va := x"80000000"; vb := x"FFFFFFFF"; end if;
         a <= va; b <= vb; isSigned <= vs;
         if vs = '1' then
            gdiv <= resize(signed(va), 33); gdis <= resize(signed(vb), 33);
         else
            gdiv <= '0' & signed(va); gdis <= '0' & signed(vb);
         end if;
         wait until rising_edge(clk);    -- operands are applied before this edge: start together with them
         start <= '1';
         wait until rising_edge(clk);    -- the start edge e0
         start <= '0';
         for i in 1 to G_LATENCY loop
            wait until rising_edge(clk);   -- e1 .. e35
         end loop;
         wait until rising_edge(clk);    -- e36: values before this edge are what the CPU loads
         q_exp := unsigned(gq(31 downto 0));
         r_exp := unsigned(gr(31 downto 0));
         -- the special results of the PSX divide (golden cpu.vhd): zero divisor and 0x80000000 / -1
         if vb = x"00000000" then
            r_exp := va;
            if vs = '1' and va(31) = '1' then q_exp := x"00000001"; else q_exp := x"FFFFFFFF"; end if;
         elsif vs = '1' and va = x"80000000" and vb = x"FFFFFFFF" then
            q_exp := x"80000000"; r_exp := x"00000000";
         end if;
         if G_FAULT = 1 and k = 7 then q_exp(0) := not q_exp(0); end if;
         if pq /= q_exp or pr /= r_exp then
            n_bad := n_bad + 1;
            if n_bad <= 10 then
               write(l, string'("MISMATCH pair ") & integer'image(k) & string'(" signed=") & std_logic'image(vs) & string'(" a=") & to_hstring(va) & string'(" b=") &
                     to_hstring(vb) & string'(" gold q=") & to_hstring(q_exp) & string'(" r=") & to_hstring(r_exp) & string'(" pocket q=") & to_hstring(pq) &
                     string'(" r=") & to_hstring(pr));
               writeline(output, l);
            end if;
         else
            n_ok := n_ok + 1;
         end if;
      end loop;
      if n_bad = 0 then
         write(l, string'("RESULT pairs=") & integer'image(n_ok + n_bad) & string'(" mismatches=0 PASS"));
      else
         write(l, string'("RESULT pairs=") & integer'image(n_ok + n_bad) & string'(" mismatches=") & integer'image(n_bad) & string'(" FAIL"));
      end if;
      writeline(output, l);
      if n_bad = 0 then stop(0); else stop(1); end if;
   end process;

end architecture;
