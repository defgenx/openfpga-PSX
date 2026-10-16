-- Helpers of the spu_diff testbench: PRNG, hash, counters.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package spu_diff_pkg is

   type rng_t is protected
      procedure seed(s : natural);
      impure function u32 return unsigned;
      impure function rnd(n : positive) return natural;              -- 0 .. n-1
      impure function between(lo, hi : integer) return integer;      -- lo .. hi
      impure function chance(pct : natural) return boolean;
   end protected;

   type counters_t is protected
      procedure inc(i : natural);
      procedure add(i : natural; n : natural);
      impure function get(i : natural) return natural;
   end protected;

   function hash32(a, b : natural) return unsigned;

end package;

package body spu_diff_pkg is

   type rng_t is protected body
      variable st : unsigned(31 downto 0) := x"2545F491";

      procedure seed(s : natural) is
      begin
         st := to_unsigned(s, 32) xor x"9E3779B9";
         if st = 0 then st := x"2545F491"; end if;
         for i in 1 to 8 loop
            st := st xor shift_left(st, 13);
            st := st xor shift_right(st, 17);
            st := st xor shift_left(st, 5);
         end loop;
      end procedure;

      impure function u32 return unsigned is
      begin
         st := st xor shift_left(st, 13);
         st := st xor shift_right(st, 17);
         st := st xor shift_left(st, 5);
         return st;
      end function;

      impure function rnd(n : positive) return natural is
         variable v : unsigned(31 downto 0);
      begin
         v := u32;
         return to_integer(v(30 downto 0) mod to_unsigned(n, 31));
      end function;

      impure function between(lo, hi : integer) return integer is
      begin
         return lo + rnd(hi - lo + 1);
      end function;

      impure function chance(pct : natural) return boolean is
      begin
         return rnd(100) < pct;
      end function;
   end protected body;

   type counters_t is protected body
      type arr_t is array (0 to 255) of natural;
      variable a : arr_t := (others => 0);
      procedure inc(i : natural) is begin a(i) := a(i) + 1; end procedure;
      procedure add(i : natural; n : natural) is begin a(i) := a(i) + n; end procedure;
      impure function get(i : natural) return natural is begin return a(i); end function;
   end protected body;

   function hash32(a, b : natural) return unsigned is
      variable x : unsigned(31 downto 0);
   begin
      x := to_unsigned(a, 32) xor (to_unsigned(b, 32) + x"7F4A7C15");
      x := x xor shift_right(x, 16);
      x := resize(x * x"7FEB352D", 32);
      x := x xor shift_right(x, 15);
      x := resize(x * x"846CA68B", 32);
      x := x xor shift_right(x, 16);
      return x;
   end function;

end package body;
