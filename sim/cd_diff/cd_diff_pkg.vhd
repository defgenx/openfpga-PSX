-- Helpers of the cd_diff testbench: PRNG, hash, BCD, and the disc model (track table words and sector contents).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package cd_diff_pkg is

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
   function to_bcd(n : natural) return natural;                      -- 0..99 -> 0x00..0x99
   function lba_of(m, s, f : natural) return natural;

   constant MAXTRK : natural := 127;

   type disc_t is protected
      procedure clear;
      -- new random disc; kind: 0 one data track, 1 data + audio, 2 audio only, 3 many data tracks, 4 any
      procedure randomize(kind : natural; seed : natural; key : natural; region : natural; rcd : natural);
      impure function words return natural;                          -- number of table words
      impure function table_addr(i : natural) return natural;        -- address of the i-th table word
      impure function table_word(i : natural) return std_logic_vector;
      impure function sector_word(lba : natural; idx : natural) return std_logic_vector;
      impure function track_count return natural;
      impure function total_lba return natural;
      impure function track_start(i : natural) return natural;       -- i = 1..track_count
      impure function track_end(i : natural) return natural;
      impure function track_audio(i : natural) return boolean;
      impure function key return natural;
   end protected;

end package;

package body cd_diff_pkg is

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

   function to_bcd(n : natural) return natural is
   begin
      return ((n / 10) mod 10) * 16 + (n mod 10);
   end function;

   function lba_of(m, s, f : natural) return natural is
   begin
      return m * 4500 + s * 75 + f;
   end function;

   type disc_t is protected body
      type nat_arr is array (0 to MAXTRK) of natural;
      type bool_arr is array (0 to MAXTRK) of boolean;
      variable ntrk   : natural := 1;
      variable tstart : nat_arr := (others => 0);
      variable tend   : nat_arr := (others => 0);
      variable taud   : bool_arr := (others => false);
      variable total  : natural := 20000;
      variable lkey   : natural := 0;
      variable lreg   : natural := 0;
      variable lrcd   : natural := 0;
      variable salt   : natural := 1;

      procedure clear is
      begin
         ntrk := 0; total := 0; lkey := 0; lreg := 0; lrcd := 0;
         tstart := (others => 0); tend := (others => 0); taud := (others => false);
      end procedure;

      procedure randomize(kind : natural; seed : natural; key : natural; region : natural; rcd : natural) is
         variable r   : unsigned(31 downto 0);
         variable k   : natural;
         variable n   : natural;
         variable len : natural;
         variable pos : natural;
      begin
         salt := seed;
         lkey := key; lreg := region; lrcd := rcd;
         r := hash32(seed, 17);
         k := kind;
         if k >= 4 then k := to_integer(r(2 downto 0)) mod 4; end if;
         case k is
            when 0 => n := 1;
            when 1 => n := 2 + to_integer(r(5 downto 3)) mod 6;
            when 2 => n := 1 + to_integer(r(5 downto 3)) mod 5;
            when others => n := 2 + to_integer(r(7 downto 3)) mod 30;
         end case;
         case to_integer(r(10 downto 8)) mod 4 is
            when 0 => total := 3000 + to_integer(r(23 downto 12)) mod 3000;
            when 1 => total := 18000 + to_integer(r(23 downto 12)) mod 3000;
            when 2 => total := 150000 + to_integer(r(27 downto 12)) mod 100000;
            when others => total := 40000 + to_integer(r(27 downto 12)) mod 20000;
         end case;
         if total < n * 40 then total := n * 40; end if;
         ntrk := n;
         pos := 0;
         for i in 1 to n loop
            len := total / n;
            if i = n then len := total - pos; end if;
            tstart(i) := pos;
            tend(i)   := pos + len - 1;
            pos := pos + len;
            case k is
               when 0 => taud(i) := false;
               when 1 => taud(i) := (i > 1);
               when 2 => taud(i) := true;
               when others => taud(i) := (hash32(seed, i)(3) = '1') and (i > 1);
            end case;
         end loop;
         if k = 3 then taud(1) := (hash32(seed, 99)(0) = '1' and hash32(seed, 98)(0) = '1'); end if;
      end procedure;

      impure function words return natural is
      begin
         return 4 + 4 * ntrk;
      end function;

      impure function table_addr(i : natural) return natural is
      begin
         return i;
      end function;

      impure function table_word(i : natural) return std_logic_vector is
         variable w   : std_logic_vector(31 downto 0) := (others => '0');
         variable t   : natural;
         variable sec : natural;
         variable mn  : natural;
      begin
         if i = 0 then
            w(7 downto 0)  := std_logic_vector(to_unsigned(ntrk, 8));
            w(15 downto 8) := std_logic_vector(to_unsigned(to_bcd(ntrk), 8));
         elsif i = 1 then
            w(18 downto 0) := std_logic_vector(to_unsigned(total, 19));
         elsif i = 2 then
            sec := (total / 75) mod 60;
            mn  := (total / 4500);
            w(7 downto 0)  := std_logic_vector(to_unsigned(to_bcd(sec), 8));
            w(15 downto 8) := std_logic_vector(to_unsigned(to_bcd(mn), 8));
         elsif i = 3 then
            w(15 downto 0)  := std_logic_vector(to_unsigned(lkey, 16));
            w(17 downto 16) := std_logic_vector(to_unsigned(lreg, 2));
            w(18)           := '1' when lrcd /= 0 else '0';
         else
            t := i / 4;
            if t >= 1 and t <= ntrk then
               case i mod 4 is
                  when 0 => w(18 downto 0) := std_logic_vector(to_unsigned(tstart(t), 19));
                  when 1 => w(18 downto 0) := std_logic_vector(to_unsigned(tend(t), 19));
                  when 2 =>
                     sec := ((tstart(t) + 150) / 75) mod 60;
                     mn  := (tstart(t) + 150) / 4500;
                     w(7 downto 0)  := std_logic_vector(to_unsigned(to_bcd(sec), 8));
                     w(15 downto 8) := std_logic_vector(to_unsigned(to_bcd(mn), 8));
                     w(16) := '1' when taud(t) else '0';
                  when others => null;
               end case;
            end if;
         end if;
         return w;
      end function;

      impure function sector_word(lba : natural; idx : natural) return std_logic_vector is
         variable h    : unsigned(31 downto 0);
         variable k    : unsigned(31 downto 0);
         variable w    : std_logic_vector(31 downto 0);
         variable aud  : boolean := false;
         variable mode : natural;
         variable sub  : natural;
         variable m, s, f : natural;
         variable amp  : natural;
      begin
         for t in 1 to ntrk loop
            if lba >= tstart(t) and lba <= tend(t) and taud(t) then aud := true; end if;
         end loop;
         k := hash32(lba, salt + 5);
         h := hash32(lba * 1024 + idx, salt);
         if aud then
            amp := to_integer(k(2 downto 0));
            w := std_logic_vector(h);
            if amp = 0 then w := (others => '0');
            elsif amp = 1 then w := x"7FFF7FFF";
            elsif amp = 2 then w := x"80008000";
            elsif amp = 3 then w := "000000000000" & std_logic_vector(h(19 downto 0));
            elsif amp = 4 then w := std_logic_vector(h(31 downto 16)) & "0000" & std_logic_vector(h(11 downto 0)); w(31 downto 28) := (others => w(27));
            end if;
            return w;
         end if;
         -- data track
         m := lba / 4500; s := (lba / 75) mod 60; f := lba mod 75;
         case idx is
            when 0 => return x"FFFFFF00";
            when 1 => return x"FFFFFFFF";
            when 2 => return x"00FFFFFF";
            when 3 =>
               case to_integer(k(7 downto 5)) is
                  when 0 => mode := 1;
                  when 1 => mode := 0;
                  when others => mode := 2;
               end case;
               return std_logic_vector(to_unsigned(mode, 8)) & std_logic_vector(to_unsigned(to_bcd(f), 8)) &
                      std_logic_vector(to_unsigned(to_bcd(s), 8)) & std_logic_vector(to_unsigned(to_bcd(m), 8));
            when 4 | 5 =>
               case to_integer(k(10 downto 8)) is
                  when 0 | 1 | 2 =>                      -- XA audio, realtime
                     sub := 16#64#;
                     if k(11) = '1' and k(12) = '1' then sub := 16#E4#; end if;           -- EOF
                     w(7 downto 0)   := std_logic_vector(to_unsigned(1 + to_integer(k(14 downto 13)) mod 2, 8));
                     w(15 downto 8)  := std_logic_vector(to_unsigned(to_integer(k(17 downto 15)) mod 3, 8));
                     if k(20 downto 18) = "111" then w(15 downto 8) := x"FF"; end if;
                     w(23 downto 16) := std_logic_vector(to_unsigned(sub, 8));
                     w(31 downto 24) := std_logic_vector(k(31 downto 24)) and x"35";
                  when 3 =>                                -- realtime, not audio
                     w := x"00" & x"48" & x"00" & x"00";
                  when 4 =>                                -- audio, not realtime
                     w := x"00" & x"24" & x"01" & x"01";
                  when others =>                           -- form 1 data
                     w := x"00" & x"08" & x"00" & x"00";
               end case;
               return w;
            when others => return std_logic_vector(h);
         end case;
      end function;

      impure function track_count return natural is begin return ntrk; end function;
      impure function total_lba return natural is begin return total; end function;
      impure function track_start(i : natural) return natural is begin return tstart(i); end function;
      impure function track_end(i : natural) return natural is begin return tend(i); end function;
      impure function track_audio(i : natural) return boolean is begin return taud(i); end function;
      impure function key return natural is begin return lkey; end function;
   end protected body;

end package body;
