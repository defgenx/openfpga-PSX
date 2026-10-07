-- Divider request/response for gpu_pocket's two shared dividers. Design: docs/pocket/GPU.md.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

package pGPU_pocket is

   -- qbits: quotient bits to compute; the caller guarantees |dividend| div |divisor| < 2^qbits.
   type tdiv_req is record
      start     : std_logic;
      dividend  : signed(44 downto 0);
      divisor   : signed(24 downto 0);
      qbits     : integer range 1 to 45;
   end record;

   -- quotient as divider.vhd returns it; qmag_lsb is bit 0 of its magnitude, valid with done.
   type tdiv_rsp is record
      done      : std_logic;
      busy      : std_logic;
      quotient  : signed(44 downto 0);
      qmag_lsb  : std_logic;
   end record;

   constant DIV_REQ_IDLE : tdiv_req := ('0', (others => '0'), (others => '0'), 1);

   -- simulation-only view of one drawn polygon line, compared by sim/gpu_diff; unused in synthesis
   type t_span is record
      valid    : std_logic;
      y        : integer range -2048 to 2047;
      xs_int   : signed(11 downto 0);
      xe_int   : signed(11 downto 0);
      xs_frac  : unsigned(31 downto 0);
      xe_frac  : unsigned(31 downto 0);
      r, g, b  : unsigned(19 downto 0);
      u, v     : unsigned(19 downto 0);
   end record;

   -- requests are OR-combined between the mutually exclusive poly and line units
   function div_or(a, b : tdiv_req) return tdiv_req;

end package;

package body pGPU_pocket is

   function div_or(a, b : tdiv_req) return tdiv_req is
      variable r : tdiv_req;
   begin
      r.start    := a.start or b.start;
      r.dividend := a.dividend or b.dividend;
      r.divisor  := a.divisor or b.divisor;
      if (a.start = '1') then r.qbits := a.qbits; else r.qbits := b.qbits; end if;
      return r;
   end function;

end package body;
