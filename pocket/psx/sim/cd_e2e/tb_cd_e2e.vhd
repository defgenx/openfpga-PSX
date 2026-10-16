-- End-to-end CD path: cd_pocket + cd_loader (as wired in core_top.v) against a model of the APF host: target_dataslot_read of slot 1
-- (image) and slot 2 (track table, deferload) answered by bridge writes, dataslot_allcomplete and dataslot_update events, the data
-- table. The CPU side drives the 0x1F801800-3 registers. Checks: no table (size 0, read error) leaves hasCD low; GetTN/GetTD against
-- the CUE; sector data (2,048-byte and whole-sector modes) against the .bin; a second table (dataslot_update) changes the disc.
-- docs/pocket/POCKET_TOP.md.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_cd_e2e is
   generic (BIN_FILE : string := "out/disc.bin"; TRK_FILE : string := "out/disc.trk"; EXP_FILE : string := "out/expect.txt";
            TRK2_FILE : string := "out/disc2.trk"; EXP2_FILE : string := "out/expect2.txt");
end entity;

architecture sim of tb_cd_e2e is
   type byte_arr is array (natural range <>) of natural range 0 to 255;
   type char_file is file of character;

   impure function file_len(name : string) return natural is
      file f : char_file;
      variable c : character;
      variable n : natural := 0;
   begin
      file_open(f, name, read_mode);
      while not endfile(f) loop read(f, c); n := n + 1; end loop;
      file_close(f);
      return n;
   end function;

   impure function load(name : string; len : natural) return byte_arr is
      file f : char_file;
      variable c : character;
      variable r : byte_arr(0 to len - 1);
   begin
      file_open(f, name, read_mode);
      for i in 0 to len - 1 loop read(f, c); r(i) := character'pos(c); end loop;
      file_close(f);
      return r;
   end function;

   constant BIN_LEN : natural := file_len(BIN_FILE);
   constant TRK_LEN : natural := file_len(TRK_FILE);
   constant BIN : byte_arr(0 to BIN_LEN - 1) := load(BIN_FILE, BIN_LEN);
   constant TRK : byte_arr(0 to TRK_LEN - 1) := load(TRK_FILE, TRK_LEN);
   constant TRK2_LEN : natural := file_len(TRK2_FILE);
   constant TRK2 : byte_arr(0 to TRK2_LEN - 1) := load(TRK2_FILE, TRK2_LEN);
   constant SEC : natural := 2352;

   signal clk1x, clk_a : std_logic := '0';
   signal rst : std_logic := '1';
   signal reset, reset_t, cd_rst_b : std_logic := '1';
   signal upd, allc : std_logic := '0';
   signal upd_id : std_logic_vector(15 downto 0) := (others => '0');
   signal upd_size, dt_q : std_logic_vector(31 downto 0) := (others => '0');
   signal dt_addr : std_logic_vector(9 downto 0);
   type dt_t is array (0 to 1023) of std_logic_vector(31 downto 0);
   signal dt : dt_t := (others => (others => '0'));       -- the APF data table: word 2k the id, 2k+1 the size of data.json's slot k
   signal trk_sel : natural := 0;                         -- which .trk file slot 2 holds
   signal fail_trk : boolean := false;                    -- the host answers a read of slot 2 with an error code
   signal slot2_reads : natural := 0;

   -- bridge and target interface (clk_a = clk_74a)
   signal bridge_wr : std_logic := '0';
   signal bridge_addr, bridge_wr_data : std_logic_vector(31 downto 0) := (others => '0');
   signal tgt_read, tgt_done : std_logic := '0';
   signal tgt_id : std_logic_vector(15 downto 0);
   signal tgt_off, tgt_baddr, tgt_len : std_logic_vector(31 downto 0);
   signal tgt_err : std_logic_vector(2 downto 0) := "000";

   -- core side
   signal cd_hps_req, cd_hps_ack, cd_hps_write, trk_done, ld_err : std_logic;
   signal cd_hps_lba : std_logic_vector(31 downto 0);
   signal cd_hps_data : std_logic_vector(15 downto 0);
   signal trackinfo_data : std_logic_vector(31 downto 0);
   signal trackinfo_addr : std_logic_vector(8 downto 0);
   signal trackinfo_write : std_logic;

   signal bus_addr : unsigned(3 downto 0) := (others => '0');
   signal bus_dataWrite, bus_dataRead : std_logic_vector(7 downto 0) := (others => '0');
   signal bus_read, bus_write : std_logic := '0';
   signal sectors_served : natural := 0;
   signal finished : boolean := false;

   signal core_run : std_logic;

   component cd_loader is
      port (
         rst, clk_74a, clk_sys : in std_logic;
         dataslot_update, dataslot_allcomplete, core_run : in std_logic;
         dataslot_update_id : in std_logic_vector(15 downto 0);
         dataslot_update_size, datatable_q : in std_logic_vector(31 downto 0);
         datatable_addr : out std_logic_vector(9 downto 0);
         bridge_wr : in std_logic;
         bridge_addr, bridge_wr_data : in std_logic_vector(31 downto 0);
         tgt_read : out std_logic;
         tgt_id : out std_logic_vector(15 downto 0);
         tgt_off, tgt_baddr, tgt_len : out std_logic_vector(31 downto 0);
         tgt_done : in std_logic;
         tgt_err : in std_logic_vector(2 downto 0);
         cd_hps_req : in std_logic;
         cd_hps_lba : in std_logic_vector(31 downto 0);
         cd_hps_ack, cd_hps_write : out std_logic;
         cd_hps_data : out std_logic_vector(15 downto 0);
         trackinfo_data : out std_logic_vector(31 downto 0);
         trackinfo_addr : out std_logic_vector(8 downto 0);
         trackinfo_write, trk_done, err : out std_logic);
   end component;
begin
   core_run <= not reset;
   clk1x <= not clk1x after 14763 ps when not finished else clk1x;       -- 33.8688 MHz
   clk_a <= not clk_a after 6734 ps when not finished else clk_a;        -- 74.25 MHz

   reset <= reset_t or cd_rst_b;
   dt_q <= dt(to_integer(unsigned(dt_addr))) when rising_edge(clk_a) else unaffected;

   -- core_top.v: a table whose word 3 has bit 18 set resets the core for 32 cycles once it is replayed
   rstgen : process (clk1x)
      variable pend : boolean := false;
      variable cnt : natural := 0;
   begin
      if rising_edge(clk1x) then
         if reset_t = '1' then pend := false; cnt := 0;
         elsif trackinfo_write = '1' and trackinfo_addr = "000000011" and trackinfo_data(18) = '1' then pend := true;
         elsif pend and trk_done = '1' then pend := false; cnt := 32;
         elsif cnt > 0 then cnt := cnt - 1;
         end if;
         if cnt > 0 then cd_rst_b <= '1'; else cd_rst_b <= '0'; end if;
      end if;
   end process;

   ldr : cd_loader port map (
      rst => rst, clk_74a => clk_a, clk_sys => clk1x,
      bridge_wr => bridge_wr, bridge_addr => bridge_addr, bridge_wr_data => bridge_wr_data,
      dataslot_update => upd, dataslot_update_id => upd_id, dataslot_update_size => upd_size, dataslot_allcomplete => allc,
      datatable_addr => dt_addr, datatable_q => dt_q, core_run => core_run,
      tgt_read => tgt_read, tgt_id => tgt_id, tgt_off => tgt_off, tgt_baddr => tgt_baddr, tgt_len => tgt_len,
      tgt_done => tgt_done, tgt_err => tgt_err,
      cd_hps_req => cd_hps_req, cd_hps_lba => cd_hps_lba, cd_hps_ack => cd_hps_ack, cd_hps_write => cd_hps_write,
      cd_hps_data => cd_hps_data, trackinfo_data => trackinfo_data, trackinfo_addr => trackinfo_addr,
      trackinfo_write => trackinfo_write, trk_done => trk_done, err => ld_err);

   -- hasCD follows trk_done, LIDopen 0, as core_top.v
   cd : entity work.cd_pocket port map (
      clk1x => clk1x, ce => '1', reset => reset,
      INSTANTSEEK => '1', FORCECDSPEED => "000", LIMITREADSPEED => '0', hasCD => trk_done, LIDopen => '0', fastCD => '0',
      testSeek => '0', pauseOnCDSlow => '0', region => "00", region_out => open,
      pauseCD => open, Pause_idle_cd => open, fullyIdle => open, cdSlow => open, error => open, LBAdisplay => open,
      irqOut => open, spu_tick => '0', cd_left => open, cd_right => open, mdec_idle => '1',
      bus_addr => bus_addr, bus_dataWrite => bus_dataWrite, bus_read => bus_read, bus_write => bus_write,
      bus_dataRead => bus_dataRead, dma_read => '0', dma_readdata => open,
      cd_hps_req => cd_hps_req, cd_hps_lba => cd_hps_lba, cd_hps_lba_sim => open, cd_hps_ack => cd_hps_ack,
      cd_hps_write => cd_hps_write, cd_hps_data => cd_hps_data,
      trackinfo_data => trackinfo_data, trackinfo_addr => trackinfo_addr, trackinfo_write => trackinfo_write,
      resetFromCD => open,
      SS_reset => '0', SS_DataWrite => (others => '0'), SS_Adr => (others => '0'), SS_wren => '0', SS_rden => '0',
      SS_DataRead => open, SS_idle => open);

   -- ------------------------------------------------------------------ APF host model, clk_74a
   -- A read lands as big-endian bridge writes at the bridge address after a latency, then done; done stays high until the next
   -- command (core_bridge_cmd), so the model raises it again only after the writes.
   host : process
      variable off, baddr, len, nw, slot : natural;
      type b4_t is array (0 to 3) of natural;
      variable b4 : b4_t;
      variable w : std_logic_vector(31 downto 0);
   begin
      wait until rising_edge(clk_a) and tgt_read = '1';
      off := to_integer(unsigned(tgt_off));
      baddr := to_integer(unsigned(tgt_baddr));
      len := to_integer(unsigned(tgt_len));
      slot := to_integer(unsigned(tgt_id));
      if slot = 1 then
         assert baddr = 16#50000000# and len = SEC and off mod SEC = 0
            report "image read: bridge address " & integer'image(baddr) & " length " & integer'image(len) & " offset " & integer'image(off)
            severity failure;
         sectors_served <= sectors_served + 1;
      else
         assert slot = 2 and baddr = 16#30000000# and off = 0 and len <= 2048
            report "target read of slot " & integer'image(slot) & " address " & integer'image(baddr) & " offset " & integer'image(off) & " length " & integer'image(len)
            severity failure;
         slot2_reads <= slot2_reads + 1;
      end if;
      for i in 1 to 3 loop wait until rising_edge(clk_a); end loop;
      tgt_done <= '0';
      for i in 1 to 3000 loop wait until rising_edge(clk_a); end loop;
      if (slot = 1 and off + SEC > BIN_LEN) or (slot = 2 and fail_trk) then
         tgt_err <= "001";                      -- no data
      else
         tgt_err <= "000";
         nw := len / 4;
         for i in 0 to nw - 1 loop
            for g in 1 to (i mod 3) loop wait until rising_edge(clk_a); end loop;
            for k in 0 to 3 loop
               if slot = 1 then b4(k) := BIN(off + 4 * i + k);
               elsif trk_sel = 0 then b4(k) := TRK(4 * i + k);
               else b4(k) := TRK2(4 * i + k);
               end if;
            end loop;
            w := std_logic_vector(to_unsigned(b4(0), 8)) & std_logic_vector(to_unsigned(b4(1), 8)) &
                 std_logic_vector(to_unsigned(b4(2), 8)) & std_logic_vector(to_unsigned(b4(3), 8));
            bridge_addr <= std_logic_vector(to_unsigned(baddr + 4 * i, 32));
            bridge_wr_data <= w;
            bridge_wr <= '1';
            wait until rising_edge(clk_a);
            bridge_wr <= '0';
         end loop;
      end if;
      wait until rising_edge(clk_a);
      tgt_done <= '1';
   end process;

   -- ------------------------------------------------------------------ the CPU side
   test : process
      variable fails : natural := 0;
      variable d : std_logic_vector(7 downto 0);
      variable flags : natural;
      type resp_t is array (0 to 15) of natural;
      variable resp : resp_t;
      variable nresp : natural;
      variable l : line;
      file ef : text;
      type exp_t is array (0 to 7) of natural;
      variable exp : exp_t;
      variable n : integer;
      variable iv : natural;

      procedure tick(k : natural) is begin for i in 1 to k loop wait until rising_edge(clk1x); end loop; end procedure;

      procedure bw(a : natural; v : natural) is
      begin
         bus_addr <= to_unsigned(a, 4); bus_dataWrite <= std_logic_vector(to_unsigned(v, 8)); bus_write <= '1';
         wait until rising_edge(clk1x);
         bus_write <= '0';
         wait until rising_edge(clk1x);
      end procedure;

      procedure br(a : natural; v : out std_logic_vector(7 downto 0)) is
      begin
         bus_addr <= to_unsigned(a, 4); bus_read <= '1';
         wait until rising_edge(clk1x);
         bus_read <= '0';
         wait until rising_edge(clk1x);
         v := bus_dataRead;
      end procedure;

      procedure idx(i : natural) is begin bw(0, i); end procedure;

      -- wait for an interrupt flag; returns its number
      procedure wait_int(v : out natural; limit : natural; step : natural := 20) is
         variable r : std_logic_vector(7 downto 0);
      begin
         idx(1);
         v := 0;
         for i in 1 to limit loop
            br(3, r);
            if r(4 downto 0) /= "00000" then v := to_integer(unsigned(r(4 downto 0))); return; end if;
            tick(step);
         end loop;
      end procedure;

      procedure ack_int is begin idx(1); bw(3, 16#1F#); end procedure;

      procedure read_resp is
         variable r : std_logic_vector(7 downto 0);
      begin
         nresp := 0;
         idx(0);
         br(0, r);
         while r(5) = '1' and nresp < 16 loop
            br(1, r);
            resp(nresp) := to_integer(unsigned(r)); nresp := nresp + 1;
            br(0, r);
         end loop;
      end procedure;

      -- command with up to 3 parameters; waits for its first interrupt (expect_int) and reads the response
      procedure cmd(c : natural; np : natural; p0, p1, p2 : natural; expect_int : natural; name : string) is
         variable v : natural;
      begin
         idx(0);
         if np > 0 then bw(2, p0); end if;
         if np > 1 then bw(2, p1); end if;
         if np > 2 then bw(2, p2); end if;
         bw(1, c);
         wait_int(v, 60000);
         read_resp;
         ack_int;
         report name & ": INT" & integer'image(v) & " response " & integer'image(nresp) & " bytes, first " & integer'image(resp(0));
         if v /= expect_int then
            report name & ": interrupt " & integer'image(v) & ", want " & integer'image(expect_int) severity failure;
         end if;
      end procedure;

      procedure expect(a, b : natural; name : string) is
      begin
         if a /= b then
            report name & ": got " & integer'image(a) & ", want " & integer'image(b) severity error;
            fails := fails + 1;
         end if;
      end procedure;

      -- one sector's data: request it, read nbytes, compare with the .bin from file offset foff
      procedure read_sector(fsec : natural; foff : natural; nbytes : natural; name : string) is
         variable r : std_logic_vector(7 downto 0);
         variable bad : natural := 0;
         variable v : natural;
      begin
         wait_int(v, 100000, 200);
         if v /= 1 then
            report name & ": interrupt " & integer'image(v) & ", want 1 (data ready)" severity error;
            fails := fails + 1;
            return;
         end if;
         read_resp;
         idx(0);
         bw(3, 16#80#);
         for i in 1 to 2000 loop             -- the sector buffer is copied into the data FIFO
            br(0, r);
            exit when r(6) = '1';
         end loop;
         if r(6) = '0' then
            report name & ": DRQSTS clear after the data request" severity error;
            fails := fails + 1;
         end if;
         for i in 0 to nbytes - 1 loop
            br(2, r);
            if to_integer(unsigned(r)) /= BIN(fsec * SEC + foff + i) then
               if bad < 3 then
                  report name & ": byte " & integer'image(i) & " = " & integer'image(to_integer(unsigned(r))) & ", want " &
                         integer'image(BIN(fsec * SEC + foff + i)) severity error;
               end if;
               bad := bad + 1;
            end if;
         end loop;
         br(0, r);
         if r(6) = '1' then
            report name & ": data FIFO not empty after " & integer'image(nbytes) & " bytes" severity error;
            fails := fails + 1;
         end if;
         bw(3, 16#00#);
         ack_int;
         if bad > 0 then
            report name & ": " & integer'image(bad) & " wrong bytes of " & integer'image(nbytes) severity error;
            fails := fails + 1;
         else
            report name & ": sector " & integer'image(fsec) & " ok (" & integer'image(nbytes) & " bytes)";
         end if;
      end procedure;

      -- Pause: a sector interrupt may still be pending before the command's own INT3 and INT2
      procedure pause_drive is
         variable v : natural;
         variable got3 : boolean := false;
      begin
         idx(0); bw(1, 16#09#);
         for i in 1 to 8 loop
            wait_int(v, 100000, 200);
            ack_int;
            if v = 3 then got3 := true; end if;
            if v = 2 then exit; end if;
         end loop;
         if not got3 or v /= 2 then
            report "Pause: no INT3 + INT2" severity error;
            fails := fails + 1;
         end if;
      end procedure;

      function bcdv(v : natural) return natural is begin return (v / 10) * 16 + (v mod 10); end function;

   begin
      file_open(ef, EXP_FILE, read_mode);
      for i in 0 to 3 loop
         readline(ef, l); read(l, n); exp(2 * i) := n; read(l, n); exp(2 * i + 1) := n;
      end loop;
      file_close(ef);

      rst <= '1'; reset_t <= '1';
      tick(20); rst <= '0';
      tick(20); reset_t <= '0';
      tick(50);

      -- no table: size 0 in the data table, then a failing read of slot 2 -> hasCD stays low, no hang
      wait until rising_edge(clk_a);
      allc <= '1'; wait until rising_edge(clk_a); allc <= '0';
      wait for 200 us;
      if trk_done /= '0' or slot2_reads /= 0 then
         report "an empty slot 2 gave a table or a read" severity error; fails := fails + 1;
      end if;
      dt(4) <= x"00000002"; dt(5) <= std_logic_vector(to_unsigned(TRK_LEN, 32));
      fail_trk <= true;
      wait until rising_edge(clk_a);
      upd <= '1'; upd_id <= x"0002"; upd_size <= std_logic_vector(to_unsigned(TRK_LEN, 32));
      wait until rising_edge(clk_a); upd <= '0';
      wait for 1 ms;
      if trk_done /= '0' or slot2_reads /= 1 or ld_err /= '1' then
         report "failed table read: trk_done " & std_logic'image(trk_done) & " reads " & integer'image(slot2_reads) & " err " & std_logic'image(ld_err) severity error;
         fails := fails + 1;
      end if;
      fail_trk <= false;
      rst <= '1'; tick(4); rst <= '0'; tick(20);          -- clears the loader's sticky error and start-up state

      -- start-up: allcomplete, the size from the data table; the table is fetched by target read and replayed into the core
      wait until rising_edge(clk_a);
      allc <= '1'; wait until rising_edge(clk_a); allc <= '0';
      wait until trk_done = '1' for 20 ms;
      if trk_done /= '1' then
         report "trk_done did not rise" severity failure;
      end if;
      report "track table in the core after " & time'image(now);
      tick(200);

      cmd(16#0A#, 0, 0, 0, 0, 3, "Init");
      wait_int(iv, 3000, 2000);
      expect(iv, 2, "Init second interrupt");
      ack_int;
      cmd(16#01#, 0, 0, 0, 0, 3, "GetStat");

      -- TOC
      cmd(16#13#, 0, 0, 0, 0, 3, "GetTN");
      expect(resp(1), exp(0), "GetTN first");
      expect(resp(2), exp(1), "GetTN last");
      report "GetTN: tracks " & integer'image(resp(1)) & ".." & integer'image(resp(2)) & " (BCD)";
      for t in 1 to 3 loop
         cmd(16#14#, 1, bcdv(t mod 3), 0, 0, 3, "GetTD");
         expect(resp(1), exp(2 * t), "GetTD " & integer'image(t mod 3) & " minute");
         expect(resp(2), exp(2 * t + 1), "GetTD " & integer'image(t mod 3) & " second");
         report "GetTD " & integer'image(t mod 3) & ": " & integer'image(resp(1)) & ":" & integer'image(resp(2)) & " (BCD min:sec)";
      end loop;

      -- 2,048-byte data, double speed: file sectors 0..3, then a jump to sector 40
      cmd(16#0E#, 1, 16#80#, 0, 0, 3, "Setmode");
      cmd(16#02#, 3, 16#00#, 16#02#, 16#00#, 3, "Setloc 00:02:00");
      cmd(16#06#, 0, 0, 0, 0, 3, "ReadN");
      for s in 0 to 3 loop read_sector(s, 24, 2048, "ReadN"); end loop;
      pause_drive;
      cmd(16#02#, 3, 16#00#, 16#02#, 16#40#, 3, "Setloc 00:02:40");
      cmd(16#06#, 0, 0, 0, 0, 3, "ReadN");
      for s in 40 to 41 loop read_sector(s, 24, 2048, "ReadN after seek"); end loop;
      pause_drive;

      -- whole sector (2,340 bytes after the sync), the last data sector of track 1
      cmd(16#0E#, 1, 16#A0#, 0, 0, 3, "Setmode whole sector");
      cmd(16#02#, 3, 16#00#, 16#03#, 16#24#, 3, "Setloc 00:03:24");
      cmd(16#06#, 0, 0, 0, 0, 3, "ReadN");
      read_sector(99, 12, 2340, "ReadN whole sector");
      pause_drive;

      -- a second table (dataslot_update of slot 2): the disc changes, the core restarts on it
      file_open(ef, EXP2_FILE, read_mode);
      for i in 0 to 3 loop
         readline(ef, l); read(l, n); exp(2 * i) := n; read(l, n); exp(2 * i + 1) := n;
      end loop;
      file_close(ef);
      trk_sel <= 1;
      wait until rising_edge(clk_a);
      upd <= '1'; upd_id <= x"0002"; upd_size <= std_logic_vector(to_unsigned(TRK2_LEN, 32));
      wait until rising_edge(clk_a); upd <= '0';
      wait until trk_done = '0' for 5 ms;
      wait until trk_done = '1' and reset = '0' for 20 ms;
      tick(400);
      cmd(16#01#, 0, 0, 0, 0, 3, "GetStat after the disc change");
      cmd(16#13#, 0, 0, 0, 0, 3, "GetTN");
      expect(resp(1), exp(0), "GetTN first (second disc)");
      expect(resp(2), exp(1), "GetTN last (second disc)");
      report "second disc, GetTN: tracks " & integer'image(resp(1)) & ".." & integer'image(resp(2)) & " (BCD)";
      cmd(16#14#, 1, 16#00#, 0, 0, 3, "GetTD");
      expect(resp(1), exp(6), "GetTD 0 minute (second disc)");
      expect(resp(2), exp(7), "GetTD 0 second (second disc)");

      report "sectors served by the host model: " & integer'image(sectors_served) & ", loader err " & std_logic'image(ld_err);
      if ld_err /= '0' then fails := fails + 1; end if;
      if fails = 0 then
         report "PASS";
      else
         report "FAIL: " & integer'image(fails) & " failures" severity error;
      end if;
      finished <= true;
      wait;
   end process;
end architecture;
