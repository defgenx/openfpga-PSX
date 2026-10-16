-- Behavioural stand-ins for the system simulation: the request ports of psram32 and sdram_ctl, and a frame grabber.
-- The real controllers are proven against chip models in their own benches (pocket/memtest/sim, tb_ram.v); here only the
-- protocols and the data matter. docs/pocket/POCKET_TOP.md, "First light".
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

-- psram32's command port: one command at a time, cmd_ready = idle, reads of cmd_len words with one rd_valid each, done at
-- the end of every command. Main RAM (words 0 .. 0x7FFFF) and the BIOS region (0x200000 .. 0x21FFFF); the BIOS file is
-- preloaded little-endian at 0x200000, as bios_loader leaves it.
entity psram_beh is
   generic (BIOS_FILE : string := ""; LAT : natural := 14);
   port (
      clk       : in  std_logic;
      cmd_valid : in  std_logic;
      cmd_ready : out std_logic;
      cmd_we    : in  std_logic;
      cmd_addr  : in  std_logic_vector(22 downto 0);
      cmd_len   : in  std_logic_vector(4 downto 0);
      cmd_wdata : in  std_logic_vector(31 downto 0);
      cmd_be    : in  std_logic_vector(3 downto 0);
      rd_valid  : out std_logic;
      rd_data   : out std_logic_vector(31 downto 0);
      done      : out std_logic
   );
end entity;

architecture beh of psram_beh is
   type mem_t is array (0 to 16#A0000# - 1) of std_logic_vector(31 downto 0);

   function idx(w : unsigned(22 downto 0)) return integer is
   begin
      if w < 16#80000# then return to_integer(w);
      elsif w >= 16#200000# and w < 16#220000# then return 16#80000# + to_integer(w) - 16#200000#;
      else return -1; end if;
   end function;
begin
   process
      variable mem : mem_t;
      type cfile is file of character;
      file f : cfile;
      variable c : character;
      variable st : file_open_status;
      variable wd : std_logic_vector(31 downto 0);
      variable a  : unsigned(22 downto 0);
      variable n, i, k, wait_c : integer;
      variable we : std_logic;
      variable din : std_logic_vector(31 downto 0);
      variable be  : std_logic_vector(3 downto 0);
   begin
      for j in mem'range loop mem(j) := (others => '0'); end loop;
      if BIOS_FILE /= "" then
         file_open(st, f, BIOS_FILE, read_mode);
         assert st = open_ok report "psram_beh: cannot open " & BIOS_FILE severity failure;
         for j in 0 to 16#20000# - 1 loop
            for b in 0 to 3 loop
               read(f, c);
               wd(8 * b + 7 downto 8 * b) := std_logic_vector(to_unsigned(character'pos(c), 8));
            end loop;
            mem(16#80000# + j) := wd;
         end loop;
         file_close(f);
         report "psram_beh: BIOS preloaded";
      end if;
      cmd_ready <= '1'; rd_valid <= '0'; done <= '0'; rd_data <= (others => '0');
      loop
         wait until rising_edge(clk);
         rd_valid <= '0'; done <= '0';
         if cmd_valid = '1' then
            cmd_ready <= '0';
            a := unsigned(cmd_addr); we := cmd_we; din := cmd_wdata; be := cmd_be; n := to_integer(unsigned(cmd_len));
            for w in 1 to LAT loop wait until rising_edge(clk); end loop;
            if we = '1' then
               k := idx(a);
               if k >= 0 then
                  for b in 0 to 3 loop
                     if be(b) = '1' then mem(k)(8 * b + 7 downto 8 * b) := din(8 * b + 7 downto 8 * b); end if;
                  end loop;
               end if;
            else
               if n = 0 then n := 1; end if;
               for w in 0 to n - 1 loop
                  if w > 0 then for d in 1 to 12 loop wait until rising_edge(clk); end loop; end if;
                  k := idx(a + to_unsigned(w, 23));
                  if k >= 0 then rd_data <= mem(k); else rd_data <= (others => '0'); end if;
                  rd_valid <= '1';
                  wait until rising_edge(clk);
                  rd_valid <= '0';
               end loop;
            end if;
            done <= '1'; cmd_ready <= '1';
         end if;
      end loop;
   end process;
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- sdram_ctl's request port: req_ready with occasional refresh stalls, every request one 64-bit burst, reads returned in
-- order after a fixed latency. VRAM: word addresses 0 .. 0x7FFFF (1 MB); SPU RAM: bit 23 set, 0x800000 + 0 .. 0x3FFFF (512 KB).
entity sdram_beh is
   generic (LAT : natural := 14);
   port (
      clk       : in  std_logic;
      init_done : out std_logic;
      req_valid : in  std_logic;
      req_ready : out std_logic;
      req_we    : in  std_logic;
      req_addr  : in  std_logic_vector(24 downto 0);
      req_wdata : in  std_logic_vector(63 downto 0);
      req_be    : in  std_logic_vector(7 downto 0);
      req_tag   : in  std_logic;
      rd_valid  : out std_logic;
      rd_data   : out std_logic_vector(63 downto 0);
      rd_tag    : out std_logic
   );
end entity;

architecture beh of sdram_beh is
   type mem_t is array (0 to 16#20000# - 1) of std_logic_vector(63 downto 0);
   type smem_t is array (0 to 16#10000# - 1) of std_logic_vector(63 downto 0);
   signal pipe_t : std_logic_vector(LAT - 1 downto 0) := (others => '0');
   signal pipe_v : std_logic_vector(LAT - 1 downto 0) := (others => '0');
   type pd_t is array (0 to LAT - 1) of std_logic_vector(63 downto 0);
   signal pipe_d : pd_t;
   signal cnt    : unsigned(9 downto 0) := (others => '0');
   signal ready  : std_logic;
   signal boot   : integer := 0;
begin
   ready     <= '1' when cnt < 920 and boot > 200 else '0';      -- a refresh-like stall of 14 cycles every 934
   req_ready <= ready;
   init_done <= '1' when boot > 200 else '0';
   rd_valid  <= pipe_v(LAT - 1);
   rd_data   <= pipe_d(LAT - 1);
   rd_tag    <= pipe_t(LAT - 1);
   process (clk)
      variable mem : mem_t;
      variable smem : smem_t;
      variable k   : integer;
      variable q   : std_logic_vector(63 downto 0);
   begin
      if rising_edge(clk) then
         if boot <= 200 then boot <= boot + 1; end if;
         cnt <= (cnt + 1) mod 934;
         pipe_v <= pipe_v(LAT - 2 downto 0) & '0';
         pipe_t <= pipe_t(LAT - 2 downto 0) & '0';
         pipe_d(1 to LAT - 1) <= pipe_d(0 to LAT - 2);
         if req_valid = '1' and ready = '1' then
            k := to_integer(unsigned(req_addr(24 downto 2)));
            if req_addr(23) = '1' then                                  -- SPU RAM
               k := to_integer(unsigned(req_addr(17 downto 2)));
               if req_we = '1' then
                  for b in 0 to 7 loop
                     if req_be(b) = '1' then smem(k)(8 * b + 7 downto 8 * b) := req_wdata(8 * b + 7 downto 8 * b); end if;
                  end loop;
               else
                  pipe_v(0) <= '1'; pipe_t(0) <= req_tag; pipe_d(0) <= smem(k);
               end if;
            elsif req_we = '1' then
               if k < mem'length then
                  for b in 0 to 7 loop
                     if req_be(b) = '1' then mem(k)(8 * b + 7 downto 8 * b) := req_wdata(8 * b + 7 downto 8 * b); end if;
                  end loop;
               end if;
            else
               if k < mem'length then q := mem(k); else q := (others => '0'); end if;
               pipe_v(0) <= '1'; pipe_d(0) <= q;
            end if;
         end if;
      end if;
   end process;
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

-- Writes every EVERY-th APF frame (VS to VS: DE pixels in order) as a plain PPM, out/frame_<n>.ppm, and reports its size.
entity frame_grab is
   generic (PREFIX : string := "frame_"; EVERY : natural := 1);
   port (
      clk : in std_logic;
      rgb : in std_logic_vector(23 downto 0);
      de  : in std_logic;
      hs  : in std_logic := '0';
      vs  : in std_logic;
      frames : out natural
   );
end entity;

architecture beh of frame_grab is
   type img_t is array (0 to 320 * 240 - 1) of std_logic_vector(23 downto 0);
begin
   process (clk)
      variable img  : img_t;
      variable n, px, lines, nonblack, hsn, de_first, de_last : integer := 0;
      variable de_d : std_logic := '0';
      file f : text;
      variable l : line;
   begin
      if rising_edge(clk) then
         if vs = '1' then
            if n > 0 and (n mod EVERY) = 0 then
               file_open(f, PREFIX & integer'image(n) & ".ppm", write_mode);
               write(l, string'("P3")); writeline(f, l);
               write(l, string'("320 240 255")); writeline(f, l);
               for i in 0 to 320 * 240 - 1 loop
                  write(l, to_integer(unsigned(img(i)(23 downto 16)))); write(l, ' ');
                  write(l, to_integer(unsigned(img(i)(15 downto 8))));  write(l, ' ');
                  write(l, to_integer(unsigned(img(i)(7 downto 0))));
                  writeline(f, l);
               end loop;
               file_close(f);
            end if;
            if n > 0 then
               report "frame " & integer'image(n) & ": " & integer'image(lines) & " DE lines, " & integer'image(px) &
                      " pixels, " & integer'image(nonblack) & " not black; " & integer'image(hsn) & " HS, DE on HS lines " &
                      integer'image(de_first) & " .. " & integer'image(de_last);
            end if;
            n := n + 1; px := 0; lines := 0; nonblack := 0; hsn := 0; de_first := -1; de_last := -1;
            for i in img'range loop img(i) := (others => '0'); end loop;
         end if;
         if hs = '1' then hsn := hsn + 1; end if;
         if de = '1' then
            if de_first < 0 then de_first := hsn; end if;
            de_last := hsn;
            if px < img'length then img(px) := rgb; end if;
            if rgb /= x"000000" then nonblack := nonblack + 1; end if;
            px := px + 1;
         end if;
         if de_d = '1' and de = '0' then lines := lines + 1; end if;
         de_d := de;
         frames <= n;
      end if;
   end process;
end architecture;
