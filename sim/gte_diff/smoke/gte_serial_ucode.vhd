-- Smoke-test stub of the micro-code package: SQR, GPF and NCLIP only.
-- Words are assembled from the bit layout in gte_serial_pkg.vhd.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.gte_serial_pkg.all;

package gte_serial_ucode is

   constant UCODE_DEPTH : integer := 13;
   type t_ucode is array (0 to UCODE_DEPTH-1) of std_logic_vector(UW-1 downto 0);
   constant UCODE : t_ucode;

   function prog_start(cmd : unsigned(31 downto 0)) return integer;
   function prog_prefetch(cmd : unsigned(31 downto 0); p : integer) return std_logic_vector;

end package;

package body gte_serial_ucode is

   procedure setf(w : inout std_logic_vector(UW-1 downto 0); lsb : integer; n : integer; val : integer) is
   begin
      w(lsb + n - 1 downto lsb) := std_logic_vector(to_unsigned(val, n));
   end procedure;

   -- lane field at lsb
   procedure lane(w : inout std_logic_vector(UW-1 downto 0); lsb : integer;
                  m0 : integer; row : integer; a : integer; b : integer; add : integer; sub : integer; wb : integer) is
   begin
      w(lsb + L_V) := '1';
      if m0 = 1 then w(lsb + L_M0) := '1'; end if;
      setf(w, lsb + L_ROW,  2, row);
      setf(w, lsb + L_ASEL, 6, a);
      setf(w, lsb + L_BSEL, 6, b);
      setf(w, lsb + L_ADD,  3, add);
      if sub = 1 then w(lsb + L_SUB) := '1'; end if;
      setf(w, lsb + L_WB,   3, wb);
   end procedure;

   function mk_ucode return t_ucode is
      variable u : t_ucode := (others => (others => '0'));
   begin
      -- SQR at 0
      lane(u(0), LA_LSB, 0, 1, A_IR1, B_IR1, ADD_ZERO, 0, WB_STD);
      lane(u(0), LB_LSB, 0, 2, A_IR2, B_IR2, ADD_ZERO, 0, WB_STD);
      lane(u(1), LA_LSB, 0, 3, A_IR3, B_IR3, ADD_ZERO, 0, WB_STD);
      u(1)(W_HALT) := '1';
      -- GPF at 2
      lane(u(2), LA_LSB, 0, 1, A_IR1, B_IR0, ADD_ZERO, 0, WB_STD);
      lane(u(2), LB_LSB, 0, 2, A_IR2, B_IR0, ADD_ZERO, 0, WB_STD);
      lane(u(3), LA_LSB, 0, 3, A_IR3, B_IR0, ADD_ZERO, 0, WB_STD);
      u(6)(SE_RGB) := '1';
      u(6)(W_HALT) := '1';
      -- NCLIP at 7: MAC0 products on lane A
      lane(u(7),  LA_LSB, 1, 0, A_SX0,     B_SY0 + 1, ADD_ZERO, 0, 0);   -- SX0 * SY1
      lane(u(8),  LA_LSB, 1, 0, A_SX0 + 1, B_SY0 + 2, ADD_ACC,  0, 0);   -- SX1 * SY2
      lane(u(9),  LA_LSB, 1, 0, A_SX0 + 2, B_SY0 + 0, ADD_ACC,  0, 0);   -- SX2 * SY0
      lane(u(10), LA_LSB, 1, 0, A_SX0,     B_SY0 + 2, ADD_ACC,  1, 0);   -- SX0 * SY2
      lane(u(11), LA_LSB, 1, 0, A_SX0 + 1, B_SY0 + 0, ADD_ACC,  1, 0);   -- SX1 * SY0
      lane(u(12), LA_LSB, 1, 0, A_SX0 + 2, B_SY0 + 1, ADD_ACC,  1, 2);   -- SX2 * SY1, checkOvf
      u(12)(W_HALT) := '1';
      return u;
   end function;

   constant UCODE : t_ucode := mk_ucode;

   function prog_start(cmd : unsigned(31 downto 0)) return integer is
   begin
      case to_integer(cmd(5 downto 0)) is
         when 16#28# => return 0;
         when 16#3D# => return 2;
         when 16#06# => return 7;
         when others => return -1;
      end case;
   end function;

   function prog_prefetch(cmd : unsigned(31 downto 0); p : integer) return std_logic_vector is
   begin
      return std_logic_vector(to_unsigned(0, RD_W));
   end function;

end package body;
