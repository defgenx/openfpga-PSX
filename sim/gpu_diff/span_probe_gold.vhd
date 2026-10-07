library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pGPU_pocket.all;
use work.gpu_span_pkg.all;

-- Probe of the frozen gpu on the golden side.
architecture rtl of span_probe_gold is
   alias a_xs    is << signal .tb_diff.golden.ggolden.igpu.igpu_poly.xStart  : signed(44 downto 0) >>;
   alias a_xe    is << signal .tb_diff.golden.ggolden.igpu.igpu_poly.xEnd    : signed(44 downto 0) >>;
   alias a_y     is << signal .tb_diff.golden.ggolden.igpu.igpu_poly.yCoord  : integer range -2048 to 2047 >>;
   alias a_r     is << signal .tb_diff.golden.ggolden.igpu.igpu_poly.work_R  : unsigned(31 downto 0) >>;
   alias a_g     is << signal .tb_diff.golden.ggolden.igpu.igpu_poly.work_G  : unsigned(31 downto 0) >>;
   alias a_b     is << signal .tb_diff.golden.ggolden.igpu.igpu_poly.work_B  : unsigned(31 downto 0) >>;
   alias a_u     is << signal .tb_diff.golden.ggolden.igpu.igpu_poly.work_U  : unsigned(31 downto 0) >>;
   alias a_v     is << signal .tb_diff.golden.ggolden.igpu.igpu_poly.work_V  : unsigned(31 downto 0) >>;
   alias a_prep  is << signal .tb_diff.golden.ggolden.igpu.igpu_poly.dbg_prep  : std_logic >>;
   alias a_run   is << signal .tb_diff.golden.ggolden.igpu.igpu_poly.dbg_run   : std_logic >>;
   alias a_issue is << signal .tb_diff.golden.ggolden.igpu.igpu_poly.dbg_issue : std_logic >>;
   -- The async video-out copy is unused with syncVideoOut = '1' and raises range errors (negative line numbers) in nvc:
   -- hold it in reset. Remove this process if the tie-off block selects the async path.
   alias a_vrst  is << signal .tb_diff.golden.ggolden.igpu.igpu_videoout.igpu_videoout_async.reset : std_logic >>;
begin

   process
   begin
      a_vrst <= force '1';
      wait;
   end process;

   process (clk2x)
      variable prev_prep  : std_logic := '0';
      variable prev_issue : std_logic := '0';
   begin
      if rising_edge(clk2x) then
         span       <= SPAN_NONE;
         if prev_prep = '1' and a_run = '1' then
            span.valid   <= '1';
            span.y       <= a_y;
            span.xs_int  <= a_xs(43 downto 32);
            span.xe_int  <= a_xe(43 downto 32);
            span.xs_frac <= unsigned(a_xs(31 downto 0));
            span.xe_frac <= unsigned(a_xe(31 downto 0));
            span.r       <= a_r(19 downto 0);
            span.g       <= a_g(19 downto 0);
            span.b       <= a_b(19 downto 0);
            span.u       <= a_u(19 downto 0);
            span.v       <= a_v(19 downto 0);
         end if;
         issue      <= a_issue and not prev_issue;
         prev_prep  := a_prep;
         prev_issue := a_issue;
      end if;
   end process;

end architecture;
