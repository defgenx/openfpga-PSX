library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pGPU_pocket.all;
use work.gpu_span_pkg.all;

-- DUT flavour "pocket": gpu_pocket's poly unit drives span_dbg (t_span) and issue_dbg (std_logic).
architecture rtl of span_probe_dut is
   alias a_span  is << signal .tb_diff.dut.gdut.igpu.igpu.igpu_poly.span_dbg  : t_span >>;
   alias a_issue is << signal .tb_diff.dut.gdut.igpu.igpu.igpu_poly.issue_dbg : std_logic >>;
   alias a_vrst  is << signal .tb_diff.dut.gdut.igpu.igpu.igpu_videoout.igpu_videoout_async.reset : std_logic >>;
begin

   -- see span_probe_gold.vhd
   process
   begin
      a_vrst <= force '1';
      wait;
   end process;

   span  <= a_span;
   issue <= a_issue;

end architecture;
