-- Self-check of trace_cmp_pkg: a masked difference is ignored, an unmasked one and a metavalue are counted,
-- only the first G_MAX_LOG are logged. Expected: compares=7 mismatches=3 (printed as SELFCHECK PASS).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;
use work.trace_cmp_pkg.all;

entity trace_cmp_tb is
   generic (G_MAX_LOG : natural := 2);
end entity;

architecture sim of trace_cmp_tb is
   subtype slv is std_logic_vector;
   shared variable cmp : trace_cmp_t;
begin
   process
      variable l : line;
      variable ok : boolean;
   begin
      cmp.configure(G_MAX_LOG);
      cmp.compare("eq", 0, slv'(x"1234"), slv'(x"1234"));
      cmp.compare("masked", 1, slv'(x"12F4"), slv'(x"1204"), slv'(x"FF0F"));                       -- differs only in masked bits
      cmp.compare("bit", 2, '1', '1');
      cmp.compare("bad_a", 3, slv'(x"1234"), slv'(x"1235"));                                  -- mismatch 1
      cmp.compare("bad_u", 4, unsigned'(x"0F"), unsigned'(x"1F"));                -- mismatch 2
      cmp.compare("bad_s", 5, signed'(x"80"), signed'(x"00"), signed'(x"01"));    -- masked: equal
      cmp.compare("bad_x", 6, slv'("0000"), slv'("00X0"));  -- mismatch 3 (not logged)
      ok := cmp.compares = 7 and cmp.mismatches = 3;
      if ok then
         write(l, string'("SELFCHECK PASS"));
         writeline(output, l);
         stop(0);
      else
         write(l, string'("SELFCHECK FAIL"));
         writeline(output, l);
         stop(1);
      end if;
   end process;
end architecture;
