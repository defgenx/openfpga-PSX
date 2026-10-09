-- Per-cycle compare of named output signals, golden vs DUT, for block harnesses.
--   shared variable cmp : trace_cmp_t;
--   cmp.configure(max_log => 20);                          -- optional; first N mismatches are logged
--   cmp.compare("bus_dataRead", cycle, gold, dut, mask);   -- std_logic_vector/unsigned/signed (mask optional)
--   cmp.compare("irqOut", cycle, gold_bit, dut_bit);       -- std_logic
--   cmp.report_result(cycles);                             -- RESULT line, then ends the run (status 1 on FAIL)
-- Log lines (parsed by sim/common/summarize.py):
--   MISMATCH <name> cycle=<n> gold=<hex> dut=<hex> mask=<hex>
--   RESULT cycles=<n> compares=<n> mismatches=<n> PASS|FAIL
-- Only bits set in the mask are compared; metavalues are compared as-is (U /= 0).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

package trace_cmp_pkg is
   type trace_cmp_t is protected
      procedure configure(max_log : natural);
      procedure compare(name : string; cycle : natural; gold, dut, mask : std_logic_vector);
      procedure compare(name : string; cycle : natural; gold, dut : std_logic_vector);
      procedure compare(name : string; cycle : natural; gold, dut, mask : unsigned);
      procedure compare(name : string; cycle : natural; gold, dut : unsigned);
      procedure compare(name : string; cycle : natural; gold, dut, mask : signed);
      procedure compare(name : string; cycle : natural; gold, dut : signed);
      procedure compare(name : string; cycle : natural; gold, dut : std_logic);
      impure function mismatches return natural;
      impure function compares return natural;
      -- prints the RESULT line, then ends the run: exit status 1 on any mismatch or when nothing was compared
      procedure report_result(cycles : natural);
   end protected;
end package;

package body trace_cmp_pkg is
   type trace_cmp_t is protected body
      variable max_log_v : natural := 20;
      variable n_cmp     : natural := 0;
      variable n_bad     : natural := 0;

      procedure say(s : string) is
         variable l : line;
      begin
         write(l, s);
         writeline(output, l);
      end procedure;

      procedure configure(max_log : natural) is
      begin
         max_log_v := max_log;
      end procedure;

      function verdict(fail : boolean) return string is
      begin
         if fail then return " FAIL"; else return " PASS"; end if;
      end function;

      procedure compare(name : string; cycle : natural; gold, dut, mask : std_logic_vector) is
         variable g : std_logic_vector(gold'length-1 downto 0) := gold;
         variable d : std_logic_vector(gold'length-1 downto 0) := dut;
         variable m : std_logic_vector(gold'length-1 downto 0) := mask;
      begin
         assert gold'length = dut'length and gold'length = mask'length
            report "trace_cmp: width mismatch on " & name severity failure;
         n_cmp := n_cmp + 1;
         if (g and m) /= (d and m) then
            n_bad := n_bad + 1;
            if n_bad <= max_log_v then
               say("MISMATCH " & name & " cycle=" & integer'image(cycle) & " gold=" & to_hstring(g) &
                      " dut=" & to_hstring(d) & " mask=" & to_hstring(m));
            end if;
         end if;
      end procedure;

      procedure compare(name : string; cycle : natural; gold, dut : std_logic_vector) is
      begin
         compare(name, cycle, gold, dut, (gold'length-1 downto 0 => '1'));
      end procedure;

      procedure compare(name : string; cycle : natural; gold, dut, mask : unsigned) is
      begin
         compare(name, cycle, std_logic_vector(gold), std_logic_vector(dut), std_logic_vector(mask));
      end procedure;

      procedure compare(name : string; cycle : natural; gold, dut : unsigned) is
      begin
         compare(name, cycle, std_logic_vector(gold), std_logic_vector(dut));
      end procedure;

      procedure compare(name : string; cycle : natural; gold, dut, mask : signed) is
      begin
         compare(name, cycle, std_logic_vector(gold), std_logic_vector(dut), std_logic_vector(mask));
      end procedure;

      procedure compare(name : string; cycle : natural; gold, dut : signed) is
      begin
         compare(name, cycle, std_logic_vector(gold), std_logic_vector(dut));
      end procedure;

      procedure compare(name : string; cycle : natural; gold, dut : std_logic) is
      begin
         compare(name, cycle, std_logic_vector'(0 => gold), std_logic_vector'(0 => dut));
      end procedure;

      impure function mismatches return natural is
      begin
         return n_bad;
      end function;

      impure function compares return natural is
      begin
         return n_cmp;
      end function;

      procedure report_result(cycles : natural) is
         constant fail : boolean := n_bad /= 0 or n_cmp = 0;
      begin
         say("RESULT cycles=" & integer'image(cycles) & " compares=" & integer'image(n_cmp) &
             " mismatches=" & integer'image(n_bad) & verdict(fail));
         if fail then stop(1); else stop(0); end if;
      end procedure;
   end protected body;
end package body;
