library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
library STD;
use STD.textio.all;
use STD.env.all;

use work.gpu_diff_pkg.all;
use work.pGPU_pocket.all;
use work.gpu_span_pkg.all;

-- Differential testbench: frozen gpu vs gpu_dut, identical stimulus on identical clock edges.
--
-- Vector file (one op per line, '#' comment, words are 8 hex digits): canonical list in gen_vectors.py's docstring.
-- Stimulus is driven from the golden side's GPUSTAT; both sides see the same bus values on the same edges.
entity tb_diff is
   generic
   (
      G_VECFILE             : string  := "vec.txt";
      G_REPRODUCIBLEGPUTIMING : integer := 0;
      G_TIMING_STRICT       : boolean := true;    -- timing differences fail the run
      G_TRACEFILE           : string  := "";      -- golden VRAM access trace, see vram_model.vhd
      G_TRACEFILE_DUT       : string  := "";      -- the same for the DUT
      G_VRAM_BUSY           : integer := 1;
      G_VRAM_LAT            : integer := 8;
      G_STAT_TIMING_MASK    : integer := 16#1E000000#; -- GPUSTAT bits that follow command timing
      G_TIMEOUT             : integer := 4000000; -- clk2x cycles to wait for idle
      G_SETTLE              : integer := 4000;    -- clk2x cycles drained before the final compare
      G_MAX_FAIL            : integer := 100000;  -- stop early after this many differences
      G_MAX_REPORT          : integer := 20;      -- detail lines per class
      -- fault injection on the DUT side; -1 = off
      G_FAULT_WR_MON        : integer := -1;      -- K-th VRAM write: flip a bit in the observed write only
      G_FAULT_WR_MEM        : integer := -1;      -- K-th VRAM write: flip a bit in the stored data only
      G_FAULT_BIT           : integer := 0;
      G_FAULT_IDLE_PRIM     : integer := -1;      -- primitive K: DUT idle seen late by G_FAULT_IDLE_DELAY clk2x
      G_FAULT_IDLE_DELAY    : integer := 0;
      G_FAULT_RD_IDX        : integer := -1;      -- K-th compared bus read: flip bit 0 of the DUT value
      G_FAULT_SPAN_IDX      : integer := -1;      -- K-th DUT span: flip bit 0 of r
      G_FAULT_SETUP_TRI     : integer := -1;      -- triangle K: DUT setup inflated by G_FAULT_SETUP_ADD clk2x in the criterion
      G_FAULT_SETUP_ADD     : integer := 0
   );
end entity;

architecture arch of tb_diff is

   function to_sl(b : boolean) return std_logic is
   begin
      if b then return '1'; else return '0'; end if;
   end function;

   ---------------------------------------------------------------- TIE-OFF block
   -- Option inputs of the GPU, as in sizing/psx_min_wrap.vhd (the stripped Pocket configuration).
   constant OPTS : t_gpu_opts :=
   (
      ditherOff             => '0',
      interlaced480pHack    => '0',
      REPRODUCIBLEGPUTIMING => to_sl(G_REPRODUCIBLEGPUTIMING /= 0),
      videoout_on           => '1',
      isPal                 => '0',
      pal60                 => '0',
      fpscountOn            => '0',
      noTexture             => '0',
      textureFilter         => "00",
      textureFilterStrength => "00",
      textureFilter2DOff    => '0',
      dither24              => '0',
      render24              => '0',
      drawSlow              => '0',
      debugmodeOn           => to_sl(G_REPRODUCIBLEGPUTIMING /= 0),   -- psx_top: debugmodeOn follows REPRODUCIBLEGPUTIMING
      syncVideoOut          => '1',
      syncInterlace         => '0',
      rotate180             => '0',
      fixedVBlank           => '0',
      vCrop                 => "00",
      hCrop                 => '0',
      oldGPU                => '0',
      Gun1CrosshairOn       => '0',
      Gun2CrosshairOn       => '0',
      cdSlow                => '0',
      errorOn               => '0',
      errorEna              => '0',
      LBAOn                 => '0'
   );
   ---------------------------------------------------------------- end TIE-OFF block

   signal opts_s : t_gpu_opts := OPTS;   -- vector op "OPT name 0|1" changes the live options of the video suite

   constant HALF2X : time := 7382 ps;
   constant NOBUSY_WAIT : integer := 40;   -- idle wait for commands that never drop GPUSTAT bit 26

   signal clk1x         : std_logic := '1';
   signal clk2x         : std_logic := '1';
   signal clkvid        : std_logic := '1';
   signal clk1xToggle   : std_logic := '0';
   signal clk1xToggle2x : std_logic := '0';
   signal clk2xIndex    : std_logic := '0';
   signal reset         : std_logic := '1';
   signal ss_reset      : std_logic := '1';

   signal bus_addr      : unsigned(3 downto 0) := (others => '0');
   signal bus_dataWrite : std_logic_vector(31 downto 0) := (others => '0');
   signal bus_read      : std_logic := '0';
   signal bus_write     : std_logic := '0';

   signal g_dataRead    : std_logic_vector(31 downto 0);
   signal d_dataRead    : std_logic_vector(31 downto 0);
   signal g_stall       : std_logic;
   signal d_stall       : std_logic;
   signal g_gpus        : std_logic_vector(31 downto 0);
   signal d_gpus        : std_logic_vector(31 downto 0);
   signal g_errs        : std_logic_vector(5 downto 0);
   signal d_errs        : std_logic_vector(5 downto 0);
   signal g_irq         : std_logic;
   signal d_irq         : std_logic;
   signal g_vid, d_vid  : std_logic_vector(76 downto 0);
   signal vid_on        : std_logic := '0';          -- vector op "VC 1": compare the video outputs every clk2x
   signal vid_mm        : integer := 0;
   signal vid_cmp       : integer := 0;
   signal vid_px        : integer := 0;               -- compared pixels (ce, not blanked) with a non-zero colour

   signal g_mon_we, g_mon_re, d_mon_we, d_mon_re : std_logic;
   signal g_mon_addr, d_mon_addr   : std_logic_vector(27 downto 0);
   signal g_mon_din, d_mon_din     : std_logic_vector(63 downto 0);
   signal g_mon_be, d_mon_be       : std_logic_vector(7 downto 0);
   signal g_mon_burst, d_mon_burst : std_logic_vector(7 downto 0);

   signal dump_idx      : natural range 0 to 131071 := 0;
   signal g_dump_q      : std_logic_vector(63 downto 0);
   signal d_dump_q      : std_logic_vector(63 downto 0);

   signal cyc           : integer := 0;                -- clk2x edges since start
   signal cur_prim      : integer := 0;                -- index of the current P/Q op
   signal cur_op        : integer := 0;                -- its opcode

   signal n_wr_g, n_wr_d       : integer := 0;
   signal n_rd_g, n_rd_d       : integer := 0;
   signal n_rdbeat_g, n_rdbeat_d : integer := 0;
   signal mm_wr         : integer := 0;
   signal wr_compared   : integer := 0;
   signal err_g, err_d  : std_logic_vector(5 downto 0) := (others => '0');

   -- idle measurement handshake
   signal meas_arm      : integer := 0;
   signal meas_start    : integer := 0;
   signal meas_prim     : integer := 0;
   signal done_id_g     : integer := 0;
   signal done_id_d     : integer := 0;
   signal done_cyc_g    : integer := 0;
   signal done_cyc_d    : integer := 0;

   signal g_span, d_span     : t_span := SPAN_NONE;
   signal g_issue, d_issue   : std_logic := '0';
   signal mm_span            : integer := 0;
   signal n_span_g, n_span_d : integer := 0;
   type t_i4 is array (0 to 3) of integer;
   signal su_n_g, su_sum_g, su_max_g : t_i4 := (others => 0);
   signal su_n_d, su_sum_d, su_max_d : t_i4 := (others => 0);
   signal sc_checked, sc_viol, sc_excess, sc_pure_max : integer := 0;

   shared variable sg   : t_spanqueue;
   shared variable sd   : t_spanqueue;
   shared variable qg   : t_wqueue;
   shared variable qd   : t_wqueue;

   ---------------------------------------------------------------- opcode classes
   constant NCLASS : integer := 8;
   function class_of(op : integer) return integer is
   begin
      if    op >= 16#20# and op <= 16#3F# then return 0;
      elsif op >= 16#40# and op <= 16#5F# then return 1;
      elsif op >= 16#60# and op <= 16#7F# then return 2;
      elsif op = 16#02#                   then return 3;
      elsif op >= 16#80# and op <= 16#9F# then return 4;
      elsif op >= 16#A0# and op <= 16#BF# then return 5;
      elsif op >= 16#C0# and op <= 16#DF# then return 6;
      else return 7;
      end if;
   end function;

   function class_name(c : integer) return string is
   begin
      case c is
         when 0 => return "poly";
         when 1 => return "line";
         when 2 => return "rect";
         when 3 => return "fill";
         when 4 => return "copy";
         when 5 => return "upload";
         when 6 => return "download";
         when others => return "other";
      end case;
   end function;

   -- opcodes whose counters are always printed (and must be non-zero for full coverage)
   function required_op(op : integer) return boolean is
   begin
      if op >= 16#20# and op <= 16#3F# then return true; end if;
      if op >= 16#60# and op <= 16#7F# then return true; end if;
      case op is
         when 16#01# | 16#02# | 16#1F# | 16#40# | 16#42# | 16#48# | 16#4A# | 16#50# | 16#52# | 16#58# | 16#5A# |
              16#80# | 16#A0# | 16#C0# | 16#E1# | 16#E2# | 16#E3# | 16#E4# | 16#E5# | 16#E6# => return true;
         when others => return false;
      end case;
   end function;

   ---------------------------------------------------------------- text helpers
   function hexval(c : character) return integer is
   begin
      case c is
         when '0' to '9' => return character'pos(c) - character'pos('0');
         when 'a' to 'f' => return character'pos(c) - character'pos('a') + 10;
         when 'A' to 'F' => return character'pos(c) - character'pos('A') + 10;
         when others     => return -1;
      end case;
   end function;

   function parse_word(s : string) return std_logic_vector is
      variable r : unsigned(31 downto 0) := (others => '0');
      variable h : integer;
   begin
      for i in s'range loop
         h := hexval(s(i));
         if h < 0 then
            report "bad hex digit in vector file: " & s severity failure;
         end if;
         r := shift_left(r, 4) or to_unsigned(h, 32);
      end loop;
      return std_logic_vector(r);
   end function;

   function parse_int(s : string) return integer is
      variable r : integer := 0;
   begin
      for i in s'range loop
         if s(i) < '0' or s(i) > '9' then
            report "bad number in vector file: " & s severity failure;
         end if;
         r := r * 10 + (character'pos(s(i)) - character'pos('0'));
      end loop;
      return r;
   end function;

   function setup_name(c : integer) return string is
   begin
      case c is
         when 0 => return "flat";
         when 1 => return "gouraud";
         when 2 => return "textured";
         when others => return "gouraud_textured";
      end case;
   end function;

   function verdict(fail : boolean) return string is
   begin
      if fail then return "FAIL"; else return "PASS"; end if;
   end function;

   procedure say(s : string) is
      variable l : line;
   begin
      write(l, s);
      writeline(output, l);
   end procedure;

begin

   ---------------------------------------------------------------- clocks (33.8688 MHz, edge-aligned)
   clk1x  <= not clk1x  after 2 * HALF2X;
   clkvid <= not clkvid after 2 * HALF2X;
   clk2x  <= not clk2x  after HALF2X;

   -- same derivation as psx_top for clk2xIndex
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         clk1xToggle <= not clk1xToggle;
      end if;
   end process;

   process (clk2x)
   begin
      if rising_edge(clk2x) then
         clk1xToggle2x <= clk1xToggle;
         clk2xIndex    <= '0';
         if (clk1xToggle2x = clk1xToggle) then
            clk2xIndex <= '1';
         end if;
         cyc <= cyc + 1;
      end if;
   end process;

   ---------------------------------------------------------------- the two sides
   golden : entity work.gpu_side
   generic map
   (
      G_DUT       => false,
      G_TRACEFILE => G_TRACEFILE,
      G_VRAM_BUSY => G_VRAM_BUSY,
      G_VRAM_LAT  => G_VRAM_LAT
   )
   port map
   (
      clk1x => clk1x, clk2x => clk2x, clk2xIndex => clk2xIndex, clkvid => clkvid, reset => reset, ss_reset => ss_reset, opts => opts_s,
      bus_addr => bus_addr, bus_dataWrite => bus_dataWrite, bus_read => bus_read, bus_write => bus_write,
      bus_dataRead => g_dataRead, bus_stall => g_stall, gpus => g_gpus, errs => g_errs, irq_vblank => g_irq, vid => g_vid,
      mon_we => g_mon_we, mon_re => g_mon_re, mon_addr => g_mon_addr, mon_din => g_mon_din, mon_be => g_mon_be,
      mon_burst => g_mon_burst, dump_idx => dump_idx, dump_q => g_dump_q
   );

   dut : entity work.gpu_side
   generic map
   (
      G_DUT           => true,
      G_TRACEFILE     => G_TRACEFILE_DUT,
      G_VRAM_BUSY     => G_VRAM_BUSY,
      G_VRAM_LAT      => G_VRAM_LAT,
      G_FAULT_MON_IDX => G_FAULT_WR_MON,
      G_FAULT_MEM_IDX => G_FAULT_WR_MEM,
      G_FAULT_BIT     => G_FAULT_BIT
   )
   port map
   (
      clk1x => clk1x, clk2x => clk2x, clk2xIndex => clk2xIndex, clkvid => clkvid, reset => reset, ss_reset => ss_reset, opts => opts_s,
      bus_addr => bus_addr, bus_dataWrite => bus_dataWrite, bus_read => bus_read, bus_write => bus_write,
      bus_dataRead => d_dataRead, bus_stall => d_stall, gpus => d_gpus, errs => d_errs, irq_vblank => d_irq, vid => d_vid,
      mon_we => d_mon_we, mon_re => d_mon_re, mon_addr => d_mon_addr, mon_din => d_mon_din, mon_be => d_mon_be,
      mon_burst => d_mon_burst, dump_idx => dump_idx, dump_q => d_dump_q
   );

   ---------------------------------------------------------------- VRAM write capture
   process (clk2x)
   begin
      if rising_edge(clk2x) then
         if g_mon_we = '1' then
            n_wr_g <= n_wr_g + 1;
            for k in 0 to 3 loop
               if g_mon_be(2 * k) = '1' then
                  qg.push((addr => std_logic_vector(unsigned(g_mon_addr) + 2 * k), data => x"000000000000" & g_mon_din(16 * k + 15 downto 16 * k),
                           be => g_mon_be, burst => g_mon_burst, prim => cur_prim, op => cur_op, cyc => cyc));
               end if;
            end loop;
         end if;
         if g_mon_re = '1' then
            n_rd_g     <= n_rd_g + 1;
            n_rdbeat_g <= n_rdbeat_g + to_integer(unsigned(g_mon_burst));
         end if;
         if d_mon_we = '1' then
            n_wr_d <= n_wr_d + 1;
            for k in 0 to 3 loop
               if d_mon_be(2 * k) = '1' then
                  qd.push((addr => std_logic_vector(unsigned(d_mon_addr) + 2 * k), data => x"000000000000" & d_mon_din(16 * k + 15 downto 16 * k),
                           be => d_mon_be, burst => d_mon_burst, prim => cur_prim, op => cur_op, cyc => cyc));
               end if;
            end loop;
         end if;
         if d_mon_re = '1' then
            n_rd_d     <= n_rd_d + 1;
            n_rdbeat_d <= n_rdbeat_d + to_integer(unsigned(d_mon_burst));
         end if;
         err_g <= err_g or g_errs;
         err_d <= err_d or d_errs;
      end if;
   end process;

   ---------------------------------------------------------------- video outputs (video suite)
   -- Cycle-exact: with no drawing in flight the video path is a function of the display registers and VRAM alone.
   process (clk2x)
   begin
      if rising_edge(clk2x) then
         if vid_on = '1' then
            vid_cmp <= vid_cmp + 1;
            if g_vid(72) = '1' and g_vid(74) = '0' and g_vid(66 downto 43) /= x"000000" then vid_px <= vid_px + 1; end if;
            if g_vid /= d_vid or g_irq /= d_irq then
               vid_mm <= vid_mm + 1;
               if vid_mm < G_MAX_REPORT then
                  say("MISMATCH video cyc=" & integer'image(cyc) & " gold=" & to_hstring("000" & g_vid) & " dut=" & to_hstring("000" & d_vid));
               end if;
            end if;
         end if;
      end if;
   end process;

   ---------------------------------------------------------------- polygon span probes
   pgold : entity work.span_probe_gold port map (clk2x => clk2x, span => g_span, issue => g_issue);
   pdut  : entity work.span_probe_dut  port map (clk2x => clk2x, span => d_span, issue => d_issue);

   process (clk2x)
   begin
      if rising_edge(clk2x) then
         if g_span.valid = '1' then
            sg.push((s => g_span, prim => cur_prim, op => cur_op));
            n_span_g <= n_span_g + 1;
         end if;
         if d_span.valid = '1' then
            sd.push((s => d_span, prim => cur_prim, op => cur_op));
            n_span_d <= n_span_d + 1;
         end if;
      end if;
   end process;

   -- spans compared in order; the cycle they occur in is not compared
   process (clk2x)
      variable a, b : t_span_item;
      variable mm   : integer := 0;
      variable nc   : integer := 0;
      variable bad  : boolean;
   begin
      if rising_edge(clk2x) then
         while (not sg.empty) and (not sd.empty) loop
            a := sg.peek;
            b := sd.peek;
            sg.pop;
            sd.pop;
            if nc = G_FAULT_SPAN_IDX then b.s.r(0) := not b.s.r(0); end if;
            bad := a.s.y /= b.s.y or a.s.xs_int /= b.s.xs_int or a.s.xe_int /= b.s.xe_int or
                   a.s.xs_frac /= b.s.xs_frac or a.s.xe_frac /= b.s.xe_frac or
                   a.s.r /= b.s.r or a.s.g /= b.s.g or a.s.b /= b.s.b or a.s.u /= b.s.u or a.s.v /= b.s.v;
            if bad then
               mm := mm + 1;
               if mm <= G_MAX_REPORT then
                  say("MISMATCH span idx=" & integer'image(nc) & " prim=" & integer'image(a.prim) &
                      " opcode=" & to_hstring(to_unsigned(a.op, 8)) &
                      " y=" & integer'image(a.s.y) & "/" & integer'image(b.s.y) &
                      " xs=" & to_hstring(a.s.xs_int) & "." & to_hstring(a.s.xs_frac) & "/" & to_hstring(b.s.xs_int) & "." & to_hstring(b.s.xs_frac) &
                      " xe=" & to_hstring(a.s.xe_int) & "." & to_hstring(a.s.xe_frac) & "/" & to_hstring(b.s.xe_int) & "." & to_hstring(b.s.xe_frac) &
                      " rgb=" & to_hstring(a.s.r) & "," & to_hstring(a.s.g) & "," & to_hstring(a.s.b) & "/" &
                      to_hstring(b.s.r) & "," & to_hstring(b.s.g) & "," & to_hstring(b.s.b) &
                      " uv=" & to_hstring(a.s.u) & "," & to_hstring(a.s.v) & "/" & to_hstring(b.s.u) & "," & to_hstring(b.s.v) & " (gold/dut)");
               end if;
            end if;
            nc := nc + 1;
         end loop;
         mm_span <= mm;
      end if;
   end process;

   -- setup cycles: ISSUE to the first drawn span, per polygon shading/texture class (quads count both triangles)
   process (clk2x)
      variable pg, pd   : boolean := false;
      variable tg, td   : integer := 0;
      variable ci       : integer;
      variable ng, sumg, mg, nd, sumd, md : t_i4 := (others => 0);
   begin
      if rising_edge(clk2x) then
         ci := 0;
         if cur_op >= 16#20# and cur_op <= 16#3F# then
            if (cur_op / 16) mod 2 = 1 then ci := ci + 1; end if;
            if (cur_op / 4) mod 2 = 1 then ci := ci + 2; end if;
         end if;
         if g_issue = '1' then pg := true; tg := cyc; end if;
         if d_issue = '1' then pd := true; td := cyc; end if;
         if pg and g_span.valid = '1' then
            pg := false;
            ng(ci) := ng(ci) + 1; sumg(ci) := sumg(ci) + (cyc - tg);
            if cyc - tg > mg(ci) then mg(ci) := cyc - tg; end if;
            su_n_g <= ng; su_sum_g <= sumg; su_max_g <= mg;
         end if;
         if pd and d_span.valid = '1' then
            pd := false;
            nd(ci) := nd(ci) + 1; sumd(ci) := sumd(ci) + (cyc - td);
            if cyc - td > md(ci) then md(ci) := cyc - td; end if;
            su_n_d <= nd; su_sum_d <= sumd; su_max_d <= md;
         end if;
      end if;
   end process;

   -- setup criterion (docs/pocket/GPU.md "Timing"), per triangle: DUT setup <= max(golden setup, reference).
   -- Setup = ISSUE to first PREPARELINE; line handling is cycle-identical, so DUT setup = golden setup
   -- + (DUT first drawn span - golden first drawn span). Triangles with no drawn span are not checked.
   process (clk2x)
      alias g_prep is << signal .tb_diff.golden.ggolden.igpu.igpu_poly.dbg_prep : std_logic >>;
      type t_ring is array (0 to 63) of integer;
      variable kg, kd, ke      : integer := 0;          -- triangles issued per side, next to check
      variable t_iss_g, t_prep_g, t_span_g, t_iss_d, t_span_d, cls : t_ring := (others => -1);
      variable prev_prep, armed_prep : boolean := false;
      variable ref, gsu, dsu, chk, viol, exc, pmax : integer := 0;
      constant REF_TRI  : t_i4 := (46, 334, 226, 496);  -- DuckStation s_setup_time, triangle
      constant REF_QUAD : t_i4 := (41, 185, 131, 266);  -- quad command cost split over its two triangles
      variable ci, k : integer;
   begin
      if rising_edge(clk2x) then
         ci := 0;
         if cur_op >= 16#20# and cur_op <= 16#3F# then
            if (cur_op / 16) mod 2 = 1 then ci := ci + 1; end if;
            if (cur_op / 4) mod 2 = 1 then ci := ci + 2; end if;
            if (cur_op / 8) mod 2 = 1 then ci := ci + 4; end if;
         end if;
         if g_issue = '1' then
            k := kg mod 64; t_iss_g(k) := cyc; t_prep_g(k) := -1; t_span_g(k) := -1; cls(k) := ci; kg := kg + 1;
            armed_prep := true;
         end if;
         if armed_prep and g_prep = '1' and not prev_prep then
            t_prep_g((kg - 1) mod 64) := cyc; armed_prep := false;
         end if;
         prev_prep := g_prep = '1';
         if g_span.valid = '1' and kg > 0 and t_span_g((kg - 1) mod 64) < 0 then t_span_g((kg - 1) mod 64) := cyc; end if;
         if d_issue = '1' then
            k := kd mod 64; t_iss_d(k) := cyc; t_span_d(k) := -1; kd := kd + 1;
         end if;
         if d_span.valid = '1' and kd > 0 and t_span_d((kd - 1) mod 64) < 0 then t_span_d((kd - 1) mod 64) := cyc; end if;
         -- triangle ke is settled on a side once it has a span or that side has issued the next one
         while ke < kg and ke < kd loop
            k := ke mod 64;
            exit when not ((t_span_g(k) >= 0 or kg > ke + 1) and (t_span_d(k) >= 0 or kd > ke + 1));
            if t_span_g(k) >= 0 and t_span_d(k) >= 0 and t_prep_g(k) >= 0 then
               gsu  := t_prep_g(k) - t_iss_g(k);
               dsu := gsu + (t_span_d(k) - t_iss_d(k)) - (t_span_g(k) - t_iss_g(k));
               if ke = G_FAULT_SETUP_TRI then dsu := dsu + G_FAULT_SETUP_ADD; end if;
               if cls(k) >= 4 then ref := REF_QUAD(cls(k) - 4); else ref := REF_TRI(cls(k)); end if;
               if gsu > ref then ref := gsu; end if;
               chk := chk + 1;
               if dsu > pmax then pmax := dsu; end if;
               if dsu > ref then
                  viol := viol + 1;
                  if dsu - ref > exc then exc := dsu - ref; end if;
                  if viol <= G_MAX_REPORT then
                     say("SETUPVIOL tri=" & integer'image(ke) & " class=" & integer'image(cls(k)) &
                         " gold=" & integer'image(gsu) & " dut=" & integer'image(dsu) & " limit=" & integer'image(ref));
                  end if;
               end if;
            end if;
            ke := ke + 1;
         end loop;
         sc_checked <= chk; sc_viol <= viol; sc_excess <= exc; sc_pure_max <= pmax;
      end if;
   end process;

   ---------------------------------------------------------------- write stream compare
   process (clk2x)
      variable a, b   : t_vwrite;
      variable mm     : integer := 0;
      variable nc     : integer := 0;
   begin
      if rising_edge(clk2x) then
         while (not qg.empty) and (not qd.empty) loop
            a := qg.peek;
            b := qd.peek;
            qg.pop;
            qd.pop;
            if a.addr /= b.addr or a.data /= b.data then
               mm := mm + 1;
               if mm <= G_MAX_REPORT then
                  say("MISMATCH pixel idx=" & integer'image(nc) & " prim=" & integer'image(a.prim) &
                      " opcode=" & to_hstring(to_unsigned(a.op, 8)) &
                      " addr=" & to_hstring(a.addr) & "/" & to_hstring(b.addr) &
                      " data=" & to_hstring(a.data(15 downto 0)) & "/" & to_hstring(b.data(15 downto 0)) & " (gold/dut)");
               end if;
            end if;
            nc := nc + 1;
         end loop;
         mm_wr       <= mm;
         wr_compared <= nc;
      end if;
   end process;

   ---------------------------------------------------------------- idle timing
   -- A measurement completes when GPUSTAT bits 26 (ready for command) and 28 (FIFO empty) are both set and
   -- bit 26 was seen low since the arm; commands that never drop bit 26 complete after NOBUSY_WAIT cycles.
   process (clk2x)
      variable arm_g, arm_d   : integer := 0;
      variable low_g, low_d   : boolean := false;
      variable hold_d         : integer := 0;
      variable idle_g, idle_d : boolean;
   begin
      if rising_edge(clk2x) then
         idle_g := g_gpus(26) = '1' and g_gpus(28) = '1';
         idle_d := d_gpus(26) = '1' and d_gpus(28) = '1';

         if meas_arm /= done_id_g then
            if arm_g /= meas_arm then arm_g := meas_arm; low_g := false; end if;
            if g_gpus(26) = '0' then low_g := true; end if;
            if idle_g and (low_g or cyc >= meas_start + NOBUSY_WAIT) then
               done_cyc_g <= cyc;
               done_id_g  <= meas_arm;
            end if;
         end if;

         if meas_arm /= done_id_d then
            if arm_d /= meas_arm then arm_d := meas_arm; low_d := false; hold_d := 0; end if;
            if d_gpus(26) = '0' then low_d := true; end if;
            if idle_d and (low_d or cyc >= meas_start + NOBUSY_WAIT) then
               if meas_prim = G_FAULT_IDLE_PRIM and hold_d < G_FAULT_IDLE_DELAY then
                  hold_d := hold_d + 1;
               else
                  done_cyc_d <= cyc;
                  done_id_d  <= meas_arm;
               end if;
            end if;
         end if;
      end if;
   end process;

   ---------------------------------------------------------------- stimulus and checks
   stim : process
      file vf                   : text;
      variable fstat            : file_open_status;
      variable l                : line;
      variable pos              : integer;
      variable tok              : string(1 to 64);
      variable tl               : integer;
      variable w                : std_logic_vector(31 downto 0);
      variable opc              : integer;
      variable nwords           : integer;
      variable suite            : string(1 to 16) := "unknown         ";
      variable suite_len        : integer := 7;
      variable opt_name         : string(1 to 32);
      variable opt_len          : integer := 0;

      variable fifo_words       : integer := 0;
      variable arm_v            : integer := 0;
      variable prim_v           : integer := 0;
      variable n_cmds           : integer := 0;
      variable n_words          : integer := 0;
      variable n_prims_timed    : integer := 0;
      variable stim_err         : integer := 0;
      variable abort            : boolean := false;
      variable is_p, is_rds, is_rg : boolean;

      -- bus read compare
      variable mm_rd            : integer := 0;
      variable stat_diffs       : integer := 0;
      variable rd_idx           : integer := 0;
      variable vg, vd           : std_logic_vector(31 downto 0);

      -- timing
      type t_int8 is array (0 to NCLASS - 1) of integer;
      variable t_n, t_gold, t_dut, t_max, t_diffs : t_int8 := (others => 0);
      variable timing_diffs     : integer := 0;
      variable timing_maxdelta  : integer := 0;
      variable tg, td, dl       : integer;
      variable rep_t, rep_s, rep_r : integer := 0;

      -- coverage
      type t_cnt256 is array (0 to 255) of integer;
      variable cnt_op           : t_cnt256 := (others => 0);
      variable cls_wrote, cls_nowrite : t_int8 := (others => 0);
      type t_names is array (0 to 63) of string(1 to 32);
      type t_nlen  is array (0 to 63) of integer;
      type t_tcnt  is array (0 to 63) of integer;
      variable tag_name         : t_names;
      variable tag_len          : t_nlen := (others => 0);
      variable tag_cnt          : t_tcnt := (others => 0);
      variable n_tags           : integer := 0;
      variable prev_class       : integer := -1;
      variable prev_wr_mark     : integer := 0;
      variable last_op          : integer := 0;

      -- final VRAM compare
      variable vram_mm          : integer := 0;
      variable fail             : boolean;

      procedure gettok is
      begin
         tl := 0;
         while pos <= l'length and (l(pos) = ' ' or l(pos) = HT) loop pos := pos + 1; end loop;
         while pos <= l'length and l(pos) /= ' ' and l(pos) /= HT loop
            tl := tl + 1;
            tok(tl) := l(pos);
            pos := pos + 1;
         end loop;
      end procedure;

      procedure align is
      begin
         wait until rising_edge(clk1x);
      end procedure;

      procedure idle_clk1x(n : integer) is
      begin
         for i in 1 to n loop wait until rising_edge(clk1x); end loop;
      end procedure;

      procedure tag_add(s : string) is
         variable k : integer := -1;
      begin
         for i in 0 to n_tags - 1 loop
            if tag_len(i) = s'length and tag_name(i)(1 to s'length) = s then k := i; end if;
         end loop;
         if k < 0 and n_tags < 64 then
            k := n_tags;
            n_tags := n_tags + 1;
            tag_name(k)(1 to s'length) := s;
            tag_len(k) := s'length;
         end if;
         if k >= 0 then tag_cnt(k) := tag_cnt(k) + 1; end if;
      end procedure;

      -- credit the previous command's class with whether golden wrote any VRAM since it started
      procedure finish_prev is
      begin
         if prev_class >= 0 then
            if n_wr_g > prev_wr_mark then
               cls_wrote(prev_class) := cls_wrote(prev_class) + 1;
            else
               cls_nowrite(prev_class) := cls_nowrite(prev_class) + 1;
            end if;
         end if;
         prev_class   := -1;
         prev_wr_mark := n_wr_g;
      end procedure;

      -- wait until GPUSTAT bit b of the golden side equals v
      procedure wait_gpus_bit(b : integer; v : std_logic) is
         variable n : integer := 0;
      begin
         while g_gpus(b) /= v or d_gpus(b) /= v loop
            wait until rising_edge(clk1x);
            n := n + 1;
            if n > G_TIMEOUT / 2 then
               say("TIMEOUT waiting for GPUSTAT bit " & integer'image(b) & " prim=" & integer'image(prim_v) & " opcode=" & to_hstring(to_unsigned(last_op, 8)));
               stim_err := stim_err + 1;
               abort := true;
               return;
            end if;
         end loop;
      end procedure;

      procedure gp0_write(x : std_logic_vector(31 downto 0)) is
      begin
         if fifo_words >= 100 then
            idle_clk1x(4);
            wait_gpus_bit(28, '1');
            fifo_words := 0;
         end if;
         bus_addr      <= x"0";
         bus_dataWrite <= x;
         bus_write     <= '1';
         wait until rising_edge(clk1x);
         bus_write     <= '0';
         fifo_words    := fifo_words + 1;
         n_words       := n_words + 1;
      end procedure;

      procedure gp1_write(x : std_logic_vector(31 downto 0)) is
      begin
         bus_addr      <= x"4";
         bus_dataWrite <= x;
         bus_write     <= '1';
         wait until rising_edge(clk1x);
         bus_write     <= '0';
         idle_clk1x(3);
      end procedure;

      -- one bus read on both sides; each side's value is taken on the edge where its own stall is low
      procedure bus_rd(a : unsigned(3 downto 0); rg, rd : out std_logic_vector(31 downto 0)) is
         variable got_g, got_d : boolean := false;
         variable n : integer := 0;
      begin
         bus_addr <= a;
         bus_read <= '1';
         wait until rising_edge(clk1x);
         bus_read <= '0';
         while not (got_g and got_d) loop
            wait until rising_edge(clk1x);
            if (not got_g) and g_stall = '0' then rg := g_dataRead; got_g := true; end if;
            if (not got_d) and d_stall = '0' then rd := d_dataRead; got_d := true; end if;
            n := n + 1;
            if n > 100000 then
               say("TIMEOUT bus read stall");
               stim_err := stim_err + 1;
               abort := true;
               if not got_g then rg := (others => 'X'); end if;
               if not got_d then rd := (others => 'X'); end if;
               exit;
            end if;
         end loop;
      end procedure;

      procedure compare_read(is_stat : boolean; what : string) is
         variable diff : std_logic_vector(31 downto 0);
         variable msk  : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(G_STAT_TIMING_MASK, 32));
      begin
         if rd_idx = G_FAULT_RD_IDX then vd(0) := not vd(0); end if;
         rd_idx := rd_idx + 1;
         diff := vg xor vd;
         if is_stat then
            if (diff and not msk) /= x"00000000" then
               mm_rd := mm_rd + 1;
               if mm_rd <= G_MAX_REPORT then
                  say("MISMATCH read " & what & " idx=" & integer'image(rd_idx - 1) & " prim=" & integer'image(prim_v) &
                      " gold=" & to_hstring(vg) & " dut=" & to_hstring(vd));
               end if;
            elsif diff /= x"00000000" then
               stat_diffs := stat_diffs + 1;
               if rep_s < G_MAX_REPORT then
                  rep_s := rep_s + 1;
                  say("TIMING DIFF GPUSTAT idx=" & integer'image(rd_idx - 1) & " prim=" & integer'image(prim_v) &
                      " gold=" & to_hstring(vg) & " dut=" & to_hstring(vd));
               end if;
            end if;
         elsif diff /= x"00000000" then
            mm_rd := mm_rd + 1;
            if mm_rd <= G_MAX_REPORT then
               say("MISMATCH read " & what & " idx=" & integer'image(rd_idx - 1) & " prim=" & integer'image(prim_v) &
                   " opcode=" & to_hstring(to_unsigned(last_op, 8)) &
                   " gold=" & to_hstring(vg) & " dut=" & to_hstring(vd));
            end if;
         end if;
      end procedure;

      -- wait for both sides to be idle again; timed = record the cycle counts for class c
      procedure wait_idle(timed : boolean; c : integer) is
      begin
         meas_start <= cyc;
         meas_prim  <= prim_v;
         arm_v      := arm_v + 1;
         meas_arm   <= arm_v;
         wait until (done_id_g = arm_v and done_id_d = arm_v) for G_TIMEOUT * HALF2X * 2;
         if not (done_id_g = arm_v and done_id_d = arm_v) then
            say("TIMEOUT waiting for idle prim=" & integer'image(prim_v) & " opcode=" & to_hstring(to_unsigned(last_op, 8)) &
                " gold_done=" & boolean'image(done_id_g = arm_v) & " dut_done=" & boolean'image(done_id_d = arm_v));
            stim_err := stim_err + 1;
            abort := true;
            return;
         end if;
         if timed then
            tg := done_cyc_g - meas_start;
            td := done_cyc_d - meas_start;
            dl := td - tg;
            t_n(c)    := t_n(c) + 1;
            t_gold(c) := t_gold(c) + tg;
            t_dut(c)  := t_dut(c) + td;
            if abs(dl) > t_max(c) then t_max(c) := abs(dl); end if;
            if abs(dl) > timing_maxdelta then timing_maxdelta := abs(dl); end if;
            if dl /= 0 then
               t_diffs(c)    := t_diffs(c) + 1;
               timing_diffs  := timing_diffs + 1;
               if rep_t < G_MAX_REPORT then
                  rep_t := rep_t + 1;
                  say("TIMING DIFF prim=" & integer'image(prim_v) & " opcode=" & to_hstring(to_unsigned(last_op, 8)) &
                      " gold=" & integer'image(tg) & " dut=" & integer'image(td) & " delta=" & integer'image(dl) & " clk2x");
               end if;
            end if;
         end if;
         align;
      end procedure;

   begin
      -- reset
      reset <= '1';
      ss_reset <= '1';
      idle_clk1x(8);
      ss_reset <= '0';
      idle_clk1x(16);
      reset <= '0';
      idle_clk1x(24);

      file_open(fstat, vf, G_VECFILE, read_mode);
      if fstat /= open_ok then
         say("ERROR cannot open vector file " & G_VECFILE);
         stim_err := stim_err + 1;
         abort := true;
      end if;

      while (not abort) and (not endfile(vf)) loop
         readline(vf, l);
         if l = null then next; end if;
         pos := 1;
         gettok;
         if tl = 0 or tok(1) = '#' then next; end if;

         if tok(1 to tl) = "SUITE" then
            gettok;
            suite_len := tl;
            suite(1 to tl) := tok(1 to tl);

         elsif tok(1 to tl) = "T" then
            gettok;
            while tl > 0 loop
               tag_add(tok(1 to tl));
               gettok;
            end loop;

         elsif tok(1 to tl) = "G1" then
            gettok;
            finish_prev;
            gp1_write(parse_word(tok(1 to tl)));
            n_cmds := n_cmds + 1;

         elsif tok(1 to tl) = "P" or tok(1 to tl) = "Q" then
            is_p := tok(1) = 'P';
            gettok;
            w   := parse_word(tok(1 to tl));
            opc := to_integer(unsigned(w(31 downto 24)));
            finish_prev;
            last_op       := opc;
            cur_op        <= opc;
            cur_prim      <= prim_v;
            prev_class    := class_of(opc);
            prev_wr_mark  := n_wr_g;
            cnt_op(opc)   := cnt_op(opc) + 1;
            n_cmds        := n_cmds + 1;
            loop
               gp0_write(w);
               gettok;
               exit when tl = 0 or abort;
               w := parse_word(tok(1 to tl));
            end loop;
            if is_p and not abort then wait_idle(true, class_of(opc)); end if;
            prim_v := prim_v + 1;

         elsif tok(1 to tl) = "I" then
            finish_prev;
            wait_idle(false, 7);

         elsif tok(1 to tl) = "RS" then
            bus_rd(x"4", vg, vd);
            compare_read(true, "GPUSTAT");

         elsif tok(1 to tl) = "RD" or tok(1 to tl) = "RDS" or tok(1 to tl) = "RG" then
            -- RDS: wait for the command to start, then rely on bus_stall; RD: poll GPUSTAT bit 27 before each word
            is_rds := tl = 3;
            is_rg  := tl = 2 and tok(2) = 'G';
            gettok;
            nwords := parse_int(tok(1 to tl));
            if is_rds then wait_gpus_bit(26, '0'); end if;
            for i in 1 to nwords loop
               exit when abort;
               if not (is_rds or is_rg) then wait_gpus_bit(27, '1'); end if;
               bus_rd(x"0", vg, vd);
               compare_read(false, "GPUREAD");
            end loop;

         elsif tok(1 to tl) = "W" then
            gettok;
            idle_clk1x(parse_int(tok(1 to tl)));

         elsif tok(1 to tl) = "OPT" then
            gettok;
            opt_name := (others => ' ');
            opt_name(1 to tl) := tok(1 to tl);
            opt_len := tl;
            gettok;
            if opt_name(1 to opt_len) = "pal60" then opts_s.pal60 <= to_sl(tok(1) = '1');
            elsif opt_name(1 to opt_len) = "syncInterlace" then opts_s.syncInterlace <= to_sl(tok(1) = '1');
            elsif opt_name(1 to opt_len) = "fixedVBlank" then opts_s.fixedVBlank <= to_sl(tok(1) = '1');
            elsif opt_name(1 to opt_len) = "isPal" then opts_s.isPal <= to_sl(tok(1) = '1');
            elsif opt_name(1 to opt_len) = "videoout_on" then opts_s.videoout_on <= to_sl(tok(1) = '1');
            else
               say("ERROR unknown option " & opt_name(1 to opt_len));
               stim_err := stim_err + 1;
               abort := true;
            end if;

         elsif tok(1 to tl) = "VC" then
            gettok;
            if tok(1) = '1' then vid_on <= '1'; else vid_on <= '0'; end if;

         else
            say("ERROR unknown vector op " & tok(1 to tl));
            stim_err := stim_err + 1;
            abort := true;
         end if;

         if mm_wr + mm_rd + mm_span > G_MAX_FAIL then
            say("ERROR too many differences, stopping early");
            abort := true;
         end if;
      end loop;

      if fstat = open_ok then file_close(vf); end if;

      -- drain
      if not abort then
         wait_idle(false, 7);
         for i in 1 to G_SETTLE / 2 loop wait until rising_edge(clk1x); end loop;
      end if;
      finish_prev;

      -- unmatched writes
      if qg.count /= 0 or qd.count /= 0 then
         say("MISMATCH pixel count: gold has " & integer'image(qg.count) & " unmatched, dut has " & integer'image(qd.count));
      end if;

      -- final VRAM compare
      for i in 0 to 131071 loop
         dump_idx <= i;
         wait for 2 ns;
         if g_dump_q /= d_dump_q then
            vram_mm := vram_mm + 1;
            if vram_mm <= G_MAX_REPORT then
               say("MISMATCH vram addr=" & to_hstring(to_unsigned(i * 8, 20)) & " gold=" & to_hstring(g_dump_q) &
                   " dut=" & to_hstring(d_dump_q));
            end if;
         end if;
      end loop;

      ---------------------------------------------------------------- report
      say("STREAM beats_note=informational pixels_compared=" & integer'image(wr_compared) & " writes_gold=" & integer'image(n_wr_g) & " writes_dut=" & integer'image(n_wr_d) &
          " compared=" & integer'image(wr_compared) &
          " reads_gold=" & integer'image(n_rd_g) & " reads_dut=" & integer'image(n_rd_d) &
          " beats_gold=" & integer'image(n_rdbeat_g) & " beats_dut=" & integer'image(n_rdbeat_d));
      say("SPANS gold=" & integer'image(n_span_g) & " dut=" & integer'image(n_span_d) & " unmatched=" & integer'image(sg.count + sd.count));
      for c in 0 to 3 loop
         say("SETUP " & setup_name(c) & " gold_n=" & integer'image(su_n_g(c)) & " gold_sum=" & integer'image(su_sum_g(c)) &
             " gold_max=" & integer'image(su_max_g(c)) & " dut_n=" & integer'image(su_n_d(c)) & " dut_sum=" & integer'image(su_sum_d(c)) &
             " dut_max=" & integer'image(su_max_d(c)));
      end loop;
      say("SETUPCHK checked=" & integer'image(sc_checked) & " violations=" & integer'image(sc_viol) &
          " worst_excess=" & integer'image(sc_excess) & " dut_max=" & integer'image(sc_pure_max));
      say("ERRFLAGS gold=" & to_string(err_g) & " dut=" & to_string(err_d) & " (FIFO MASK GPU POLY RECT LINE)");
      for c in 0 to NCLASS - 1 loop
         say("TIMING " & class_name(c) & " n=" & integer'image(t_n(c)) & " gold=" & integer'image(t_gold(c)) &
             " dut=" & integer'image(t_dut(c)) & " maxdelta=" & integer'image(t_max(c)) & " diffs=" & integer'image(t_diffs(c)));
      end loop;
      for op in 0 to 255 loop
         if cnt_op(op) > 0 or required_op(op) then
            say("COV " & suite(1 to suite_len) & " op_" & to_hstring(to_unsigned(op, 8)) & " " & integer'image(cnt_op(op)));
         end if;
      end loop;
      for c in 0 to NCLASS - 1 loop
         say("COV " & suite(1 to suite_len) & " " & class_name(c) & "_wrote " & integer'image(cls_wrote(c)));
         say("COV " & suite(1 to suite_len) & " " & class_name(c) & "_nowrite " & integer'image(cls_nowrite(c)));
      end loop;
      for i in 0 to n_tags - 1 loop
         say("COV " & suite(1 to suite_len) & " tag_" & tag_name(i)(1 to tag_len(i)) & " " & integer'image(tag_cnt(i)));
      end loop;

      say("VIDEO compared=" & integer'image(vid_cmp) & " pixels=" & integer'image(vid_px) & " mismatches=" & integer'image(vid_mm));
      fail := (mm_wr + mm_span + vram_mm + mm_rd + stim_err + vid_mm > 0) or sg.count /= 0 or sd.count /= 0 or err_g(5) = '1' or
              (G_TIMING_STRICT and (timing_diffs + stat_diffs > 0)) or sc_viol > 0 or
              qg.count /= 0 or qd.count /= 0;
      say("RESULT commands=" & integer'image(n_cmds) & " prims=" & integer'image(prim_v) & " words=" & integer'image(n_words) &
          " wr_mismatches=" & integer'image(mm_wr + qg.count + qd.count) & " span_mismatches=" & integer'image(mm_span + sg.count + sd.count) & " vram_mismatches=" & integer'image(vram_mm) &
          " video_mismatches=" & integer'image(vid_mm) &
          " rd_mismatches=" & integer'image(mm_rd) & " stim_errors=" & integer'image(stim_err) &
          " timing_diffs=" & integer'image(timing_diffs) & " stat_diffs=" & integer'image(stat_diffs) &
          " timing_maxdelta=" & integer'image(timing_maxdelta) & " cycles=" & integer'image(cyc) & " " & verdict(fail));
      if fail then
         finish(1);
      else
         finish(0);
      end if;
      wait;
   end process;

end architecture;
