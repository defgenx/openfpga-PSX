library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.pGPU_pocket.all;

-- Queue of spans (type t_span: rtl/pGPU_pocket.vhd) for the in-order compare.
--   golden side: span_probe_gold / span_dut_golden.vhd build t_span from the frozen gpu_poly
--   pocket:      gpu_pocket's poly unit drives span_dbg, read by span_dut_pocket.vhd
package gpu_span_pkg is

   constant SPAN_NONE : t_span :=
      ('0', 0, (others => '0'), (others => '0'), (others => '0'), (others => '0'),
       (others => '0'), (others => '0'), (others => '0'), (others => '0'), (others => '0'));

   type t_span_item is record
      s    : t_span;
      prim : integer;
      op   : integer;
   end record;

   type t_spanqueue is protected
      procedure push(v : t_span_item);
      impure function empty return boolean;
      impure function peek return t_span_item;
      procedure pop;
      impure function count return integer;
   end protected;

end package;

package body gpu_span_pkg is

   type t_spanqueue is protected body
      constant CAP : integer := 65536;
      type t_arr is array (0 to CAP - 1) of t_span_item;
      variable buf  : t_arr;
      variable head : integer := 0;
      variable tail : integer := 0;
      variable n    : integer := 0;

      procedure push(v : t_span_item) is
      begin
         assert n < CAP report "span queue overflow" severity failure;
         buf(tail) := v;
         tail := (tail + 1) mod CAP;
         n    := n + 1;
      end procedure;

      impure function empty return boolean is
      begin
         return n = 0;
      end function;

      impure function peek return t_span_item is
      begin
         return buf(head);
      end function;

      procedure pop is
      begin
         head := (head + 1) mod CAP;
         n    := n - 1;
      end procedure;

      impure function count return integer is
      begin
         return n;
      end function;
   end protected body;

end package body;
