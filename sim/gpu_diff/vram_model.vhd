library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
library STD;
use STD.textio.all;

-- Behavioural 1 MB VRAM behind the GPU's 64-bit DDR-style port (clk2x).
--   command accepted on a clock edge where (vram_WE or vram_RD) = '1' and vram_BUSY = '0'
--   write: one beat (burst 1), data merged per byte enable
--   read : burst beats of vram_DOUT, one per clk2x, vram_DOUT_READY high, first beat G_READ_LAT edges after accept
--   vram_BUSY: high from a read's accept until its last beat; with G_BUSY_MODE = 1 also a fixed 1-in-4 pattern
-- Address bits 19..3 select the 64-bit word; bits 27..20 must be zero (second-buffer modes are off).
-- Initial contents are a fixed hash of the word index, identical on every instance.
--
-- G_TRACEFILE (empty = off): one line per accepted access
--   <clk2x edge count> <R|W> <addr, 7 hex digits (byte address)> <burst count, decimal> <byte enable, 2 hex digits>
--
-- Fault injection (G_FAULT_*, -1 = off): flip bit G_FAULT_BIT of the lowest enabled byte of the K-th write
--   only in the monitor strobe (_MON_) or only in the stored data (_MEM_).
entity vram_model is
   generic
   (
      G_BUSY_MODE      : integer := 1;
      G_READ_LAT       : integer := 8;
      G_TRACEFILE      : string  := "";
      G_FAULT_MON_IDX  : integer := -1;
      G_FAULT_MEM_IDX  : integer := -1;
      G_FAULT_BIT      : integer := 0
   );
   port
   (
      clk              : in  std_logic;
      vram_BUSY        : out std_logic := '0';
      vram_DOUT        : out std_logic_vector(63 downto 0) := (others => '0');
      vram_DOUT_READY  : out std_logic := '0';
      vram_BURSTCNT    : in  std_logic_vector(7 downto 0);
      vram_ADDR        : in  std_logic_vector(27 downto 0);
      vram_DIN         : in  std_logic_vector(63 downto 0);
      vram_BE          : in  std_logic_vector(7 downto 0);
      vram_WE          : in  std_logic;
      vram_RD          : in  std_logic;

      -- one-cycle strobes at the edge after an access is accepted
      mon_we           : out std_logic := '0';
      mon_re           : out std_logic := '0';
      mon_addr         : out std_logic_vector(27 downto 0) := (others => '0');
      mon_din          : out std_logic_vector(63 downto 0) := (others => '0');
      mon_be           : out std_logic_vector(7 downto 0) := (others => '0');
      mon_burst        : out std_logic_vector(7 downto 0) := (others => '0');

      -- asynchronous read-out of word dump_idx
      dump_idx         : in  natural range 0 to 131071;
      dump_q           : out std_logic_vector(63 downto 0)
   );
end entity;

architecture arch of vram_model is
begin

   process (clk, dump_idx)
      type t_mem is array (0 to 131071) of std_logic_vector(63 downto 0);
      variable mem      : t_mem;
      variable inited   : boolean := false;
      variable h        : unsigned(63 downto 0);
      variable cyc      : integer := 0;
      variable lfsr     : unsigned(15 downto 0) := x"ACE1";
      variable busy_v   : std_logic := '0';
      variable rd_act   : boolean := false;
      variable lat      : integer := 0;
      variable beats    : integer := 0;
      variable rd_ptr   : integer := 0;
      variable nwr      : integer := 0;
      variable idx      : integer;
      variable d        : std_logic_vector(63 downto 0);
      variable m        : std_logic_vector(63 downto 0);
      variable fb       : integer;
      variable accepted : boolean;
      file     tf       : text;
      variable tl       : line;
      variable tstat    : file_open_status;
      variable tracing  : boolean := false;

      procedure trace(rw : string; a : std_logic_vector(27 downto 0); bc : integer; be : std_logic_vector(7 downto 0)) is
      begin
         if tracing then
            write(tl, cyc);
            write(tl, string'(" ") & rw & string'(" "));
            write(tl, to_hstring(a));
            write(tl, string'(" ") & integer'image(bc) & string'(" ") & to_hstring(be));
            writeline(tf, tl);
         end if;
      end procedure;
   begin
      if not inited then
         inited := true;
         for i in 0 to 131071 loop
            h := resize(to_unsigned(i, 64) * unsigned'(x"9E3779B97F4A7C15"), 64) + unsigned'(x"0123456789ABCDEF");
            h := h xor (h srl 29);
            h := resize(h * unsigned'(x"BF58476D1CE4E5B9"), 64);
            h := h xor (h srl 32);
            mem(i) := std_logic_vector(h);
         end loop;
         if G_TRACEFILE'length > 0 then
            file_open(tstat, tf, G_TRACEFILE, write_mode);
            tracing := (tstat = open_ok);
         end if;
      end if;

      dump_q <= mem(dump_idx);

      if rising_edge(clk) then
         cyc      := cyc + 1;
         accepted := false;
         mon_we   <= '0';
         mon_re   <= '0';
         vram_DOUT_READY <= '0';

         -- read data return
         if rd_act then
            if lat > 0 then
               lat := lat - 1;
            else
               vram_DOUT       <= mem(rd_ptr);
               vram_DOUT_READY <= '1';
               rd_ptr          := (rd_ptr + 1) mod 131072;
               beats           := beats - 1;
               if beats = 0 then rd_act := false; end if;
            end if;
         end if;

         -- command accept (BUSY as sampled at this edge)
         if (vram_WE = '1' or vram_RD = '1') and busy_v = '0' then
            accepted := true;
            assert vram_ADDR(27 downto 20) = x"00" report "VRAM address above 1 MB" severity error;
            idx := to_integer(unsigned(vram_ADDR(19 downto 3)));
            if vram_WE = '1' then
               assert vram_BURSTCNT = x"01" report "VRAM write burst /= 1" severity error;
               m := (others => '0');
               for b in 0 to 7 loop
                  if vram_BE(b) = '1' then m(b * 8 + 7 downto b * 8) := (others => '1'); end if;
               end loop;
               d := vram_DIN;
               mon_we    <= '1';
               mon_addr  <= vram_ADDR;
               mon_din   <= vram_DIN and m;
               mon_be    <= vram_BE;
               mon_burst <= vram_BURSTCNT;
               fb := -1;
               for b in 7 downto 0 loop
                  if vram_BE(b) = '1' then fb := b; end if;
               end loop;
               if fb >= 0 then
                  if nwr = G_FAULT_MON_IDX then
                     mon_din(fb * 8 + G_FAULT_BIT) <= not (vram_DIN(fb * 8 + G_FAULT_BIT));
                  end if;
                  if nwr = G_FAULT_MEM_IDX then
                     d(fb * 8 + G_FAULT_BIT) := not d(fb * 8 + G_FAULT_BIT);
                  end if;
               end if;
               mem(idx) := (mem(idx) and not m) or (d and m);
               nwr := nwr + 1;
               trace("W", vram_ADDR, 1, vram_BE);
            else
               mon_re    <= '1';
               mon_addr  <= vram_ADDR;
               mon_burst <= vram_BURSTCNT;
               rd_act := true;
               lat    := G_READ_LAT - 1;
               beats  := to_integer(unsigned(vram_BURSTCNT));
               rd_ptr := idx;
               if beats = 0 then
                  rd_act := false;
                  report "VRAM read burst 0" severity error;
               end if;
               trace("R", vram_ADDR, beats, x"FF");
            end if;
         end if;

         -- BUSY for the next edge
         lfsr := lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
         busy_v := '0';
         if rd_act then busy_v := '1'; end if;
         if G_BUSY_MODE = 1 and lfsr(3 downto 2) = "11" then busy_v := '1'; end if;
         vram_BUSY <= busy_v;
      end if;
   end process;

end architecture;
