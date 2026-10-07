library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use IEEE.std_logic_textio.all;
library STD;
use STD.textio.all;
use STD.env.all;

use work.pGTE.all;

-- Differential testbench: golden gte vs gte_dut, identical stimulus.
--
-- Vector file format (line types 01-19): canonical list in gen_vectors.py's docstring.
entity tb_diff is
   generic
   (
      G_VECFILE          : string  := "vec.txt";
      G_REQUIRE_COVERAGE : boolean := false;
      G_MAX_FAIL         : integer := 100000;  -- stop early after this many differences
      G_MAX_REPORT       : integer := 20;      -- detailed difference lines per source
      -- fault injection (golden side, comparison path only); -1 = off
      G_FAULT_XOR_CMD    : integer := -1;      -- command index K
      G_FAULT_XOR_REG    : integer := 0;       -- register whose read data is flipped
      G_FAULT_XOR_BIT    : integer := 0;
      G_FAULT_BUSY_CMD   : integer := -1;      -- golden busy delayed by 1 clk1x from command K
      G_FAULT_MUL        : integer := -1;      -- Nth multiply trigger gets a bad operand
      G_FAULT_DIVSHIFT   : integer := -1;      -- Nth divider trigger gets a bad shift
      G_FAULT_DIVRANGE   : integer := -1       -- Nth divider trigger gets an out-of-range value
   );
end entity;

architecture arch of tb_diff is

   constant TIMEOUT_EDGES : integer := 2000;

   -- clocks: 33.8688 MHz, edge-aligned
   signal clk1x         : std_logic := '1';
   signal clk2x         : std_logic := '1';

   signal clk1xToggle   : std_logic := '0';
   signal clk1xToggle2x : std_logic := '0';
   signal clk2xIndex    : std_logic := '0';

   signal ce            : std_logic := '1';
   signal reset         : std_logic := '1';

   -- stimulus bus
   signal gte_readAddr  : unsigned(5 downto 0) := (others => '0');
   signal gte_readEna   : std_logic := '0';
   signal gte_writeAddr : unsigned(5 downto 0) := (others => '0');
   signal gte_writeData : unsigned(31 downto 0) := (others => '0');
   signal gte_writeEna  : std_logic := '0';
   signal gte_cmdData   : unsigned(31 downto 0) := (others => '0');
   signal gte_cmdEna    : std_logic := '0';

   -- golden / dut outputs
   signal g_busy        : std_logic;
   signal g_readData    : unsigned(31 downto 0);
   signal g_idle        : std_logic;
   signal d_busy        : std_logic;
   signal d_readData    : unsigned(31 downto 0);
   signal d_idle        : std_logic;

   -- pause machinery: pending = (arm_cnt /= done_cnt)
   signal pause_arm_cnt  : integer := 0;
   signal pause_done_cnt : integer := 0;
   signal pause_len      : integer := 1;

   -- bookkeeping shared between processes
   signal cmp_en        : boolean := false;
   signal mode_cpu      : boolean := false;
   signal in_dump       : boolean := false;
   signal cmd_idx       : integer := 0;                      -- commands issued
   signal last_cmd      : unsigned(31 downto 0) := (others => '0');
   signal cur_suite     : integer := 0;
   signal bc_g          : integer := 0;                      -- clk1x edges with busy = 1
   signal bc_d          : integer := 0;
   signal mm_dump       : integer := 0;
   signal mm_edge       : integer := 0;
   signal bd_edge       : integer := 0;
   signal bd_seq        : integer := 0;
   signal as_mul        : integer := 0;
   signal as_shift      : integer := 0;
   signal as_range      : integer := 0;
   signal n_pause       : integer := 0;                      -- pauses fired / fired while busy
   signal n_pause_busy  : integer := 0;
   signal chk_mul       : integer := 0;                      -- triggers checked
   signal chk_div       : integer := 0;
   signal idx_err       : integer := 0;
   signal tb_err        : integer := 0;
   signal stim_done     : boolean := false;

   ---------------------------------------------------------------- coverage
   constant NSUITE : integer := 8;
   constant K_OP   : integer := 0;     -- 0..63 per opcode
   constant K_IR   : integer := 64;    -- +0..2 clamped (FLAG 24,23,22), +3..5 not clamped
   constant K_SXY  : integer := 70;    -- +0..1 clamped (14,13), +2..3 not clamped
   constant K_SZ3  : integer := 74;    -- +0 clamped (18), +1 not
   constant K_OTZ  : integer := 76;    -- +0 clamped (18), +1 not
   constant K_RGB  : integer := 78;    -- +0..2 clamped (21,20,19), +3..5 not clamped
   constant K_DIV  : integer := 84;    -- +0 divide error (17), +1 none
   constant NKIND  : integer := 86;
   type cov_t is array (0 to NSUITE - 1, 0 to NKIND - 1) of integer;

   type t_regs is array (0 to 63) of std_logic_vector(31 downto 0);

   function SUITE_NAME(s : integer) return string is
   begin
      case s is
         when 0 => return "directed";
         when 1 => return "edge";
         when 2 => return "reset";
         when 3 => return "cpu";
         when 4 => return "uniform";
         when 5 => return "game";
         when 6 => return "smoke";
         when others => return "other";
      end case;
   end function;

   function VALID_OPC(o : integer) return boolean is
   begin
      case o is
         when 16#01# | 16#06# | 16#0C# | 16#10# | 16#11# | 16#12# | 16#13# | 16#14# | 16#16# | 16#1B# | 16#1C# |
              16#1E# | 16#20# | 16#28# | 16#29# | 16#2A# | 16#2D# | 16#2E# | 16#30# | 16#3D# | 16#3E# | 16#3F# => return true;
         when others => return false;
      end case;
   end function;

   function WRITES_IR(o : integer) return boolean is
   begin
      return VALID_OPC(o) and o /= 16#06# and o /= 16#2D# and o /= 16#2E#;
   end function;

   function PUSHES_RGB(o : integer) return boolean is
   begin
      case o is
         when 16#10# | 16#11# | 16#13# | 16#14# | 16#16# | 16#1B# | 16#1C# | 16#1E# | 16#20# | 16#29# | 16#2A# |
              16#3D# | 16#3E# | 16#3F# => return true;
         when others => return false;
      end case;
   end function;

   function KIND_NAME(k : integer) return string is
   begin
      if k < K_IR then return "op_" & to_hstring(to_unsigned(k, 8)); end if;
      case k is
         when K_IR + 0 => return "ir1_clamped(f24)";
         when K_IR + 1 => return "ir2_clamped(f23)";
         when K_IR + 2 => return "ir3_clamped(f22)";
         when K_IR + 3 => return "ir1_notclamped";
         when K_IR + 4 => return "ir2_notclamped";
         when K_IR + 5 => return "ir3_notclamped";
         when K_SXY + 0 => return "sx_clamped(f14)";
         when K_SXY + 1 => return "sy_clamped(f13)";
         when K_SXY + 2 => return "sx_notclamped";
         when K_SXY + 3 => return "sy_notclamped";
         when K_SZ3 + 0 => return "sz3_clamped(f18)";
         when K_SZ3 + 1 => return "sz3_notclamped";
         when K_OTZ + 0 => return "otz_clamped(f18)";
         when K_OTZ + 1 => return "otz_notclamped";
         when K_RGB + 0 => return "r_clamped(f21)";
         when K_RGB + 1 => return "g_clamped(f20)";
         when K_RGB + 2 => return "b_clamped(f19)";
         when K_RGB + 3 => return "r_notclamped";
         when K_RGB + 4 => return "g_notclamped";
         when K_RGB + 5 => return "b_notclamped";
         when K_DIV + 0 => return "div_error(f17)";
         when K_DIV + 1 => return "div_noerror";
         when others => return "k" & integer'image(k);
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

   ---------------------------------------------------------------- clocks
   clk1x <= not clk1x after 14764 ps;
   clk2x <= not clk2x after 7382 ps;

   -- same derivation as psx_top / sim/gte tb for clk2xIndex
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
      end if;
   end process;

   ---------------------------------------------------------------- instances
   golden : entity work.gte
   port map
   (
      clk1x                => clk1x,
      clk2x                => clk2x,
      clk2xIndex           => clk2xIndex,
      ce                   => ce,
      reset                => reset,
      WIDESCREEN           => "00",
      TURBO                => '0',
      gte_busy             => g_busy,
      gte_readAddr         => gte_readAddr,
      gte_readData         => g_readData,
      gte_readEna          => gte_readEna,
      gte_writeAddr_in     => gte_writeAddr,
      gte_writeData_in     => gte_writeData,
      gte_writeEna_in      => gte_writeEna,
      gte_cmdData          => gte_cmdData,
      gte_cmdEna           => gte_cmdEna,
      loading_savestate    => '0',
      SS_reset             => '0',
      SS_DataWrite         => x"00000000",
      SS_Adr               => "000000",
      SS_wren              => '0',
      SS_rden              => '0',
      SS_DataRead          => open,
      SS_idle              => g_idle,
      debug_firstGTE       => open
   );

   dut : entity work.gte_dut
   port map
   (
      clk1x                => clk1x,
      clk2x                => clk2x,
      clk2xIndex           => clk2xIndex,
      ce                   => ce,
      reset                => reset,
      WIDESCREEN           => "00",
      TURBO                => '0',
      gte_busy             => d_busy,
      gte_readAddr         => gte_readAddr,
      gte_readData         => d_readData,
      gte_readEna          => gte_readEna,
      gte_writeAddr_in     => gte_writeAddr,
      gte_writeData_in     => gte_writeData,
      gte_writeEna_in      => gte_writeEna,
      gte_cmdData          => gte_cmdData,
      gte_cmdEna           => gte_cmdEna,
      loading_savestate    => '0',
      SS_reset             => '0',
      SS_DataWrite         => x"00000000",
      SS_Adr               => "000000",
      SS_wren              => '0',
      SS_rden              => '0',
      SS_DataRead          => open,
      SS_idle              => d_idle,
      debug_firstGTE       => open
   );

   ---------------------------------------------------------------- ce (psx_top pause rule)
   -- A pending pause fires one clk1x after the golden's SS_idle = '1' and holds ce low for N clk1x.
   process (clk1x)
      variable left : integer := 0;
   begin
      if rising_edge(clk1x) then
         if left > 0 then
            left := left - 1;
            ce <= '0';
         else
            ce <= '1';
            if pause_arm_cnt /= pause_done_cnt and g_idle = '1' then
               ce             <= '0';
               left           := pause_len - 1;
               pause_done_cnt <= pause_arm_cnt;
               n_pause        <= n_pause + 1;
               if g_busy = '1' then n_pause_busy <= n_pause_busy + 1; end if;
            end if;
         end if;
      end if;
   end process;

   ---------------------------------------------------------------- busy cycle counters
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if g_busy = '1' then bc_g <= bc_g + 1; end if;
         if d_busy = '1' then bc_d <= bc_d + 1; end if;
      end if;
   end process;

   ---------------------------------------------------------------- per-edge comparison
   process (clk1x)
      variable busy_d1    : std_logic := '0';
      variable gb         : std_logic;
      variable gr         : std_logic_vector(31 downto 0);
      variable xor_done   : boolean := false;
      variable rd_valid   : boolean := false;
      variable n_rep_b    : integer := 0;
      variable n_rep_m    : integer := 0;
   begin
      if rising_edge(clk1x) then
         gb := g_busy;
         if G_FAULT_BUSY_CMD >= 0 and cmd_idx > G_FAULT_BUSY_CMD then
            gb := busy_d1;
         end if;
         busy_d1 := g_busy;

         if not is_x(std_logic_vector(g_readData)) then rd_valid := true; end if;

         if cmp_en then
            if gb /= d_busy then
               bd_edge <= bd_edge + 1;
               if n_rep_b < G_MAX_REPORT then
                  n_rep_b := n_rep_b + 1;
                  say("BUSY DIFF t=" & to_string(now, ns) & " cmd#=" & integer'image(cmd_idx - 1) & " opcode=" & to_hstring(last_cmd(5 downto 0)) &
                      " signal=gte_busy gold=" & std_logic'image(gb) & " dut=" & std_logic'image(d_busy));
               end if;
            end if;
            if g_idle /= d_idle then
               mm_edge <= mm_edge + 1;
               if n_rep_m < G_MAX_REPORT then
                  n_rep_m := n_rep_m + 1;
                  say("MISMATCH t=" & to_string(now, ns) & " cmd#=" & integer'image(cmd_idx - 1) & " opcode=" & to_hstring(last_cmd(5 downto 0)) &
                      " signal=SS_idle gold=" & std_logic'image(g_idle) & " dut=" & std_logic'image(d_idle));
               end if;
            end if;
            if mode_cpu and rd_valid and not in_dump then
               gr := std_logic_vector(g_readData);
               if (not xor_done) and G_FAULT_XOR_CMD >= 0 and cmd_idx > G_FAULT_XOR_CMD and to_integer(gte_readAddr) = G_FAULT_XOR_REG then
                  gr(G_FAULT_XOR_BIT) := not gr(G_FAULT_XOR_BIT);
                  xor_done := true;
               end if;
               if gr /= std_logic_vector(d_readData) then
                  mm_edge <= mm_edge + 1;
                  if n_rep_m < G_MAX_REPORT then
                     n_rep_m := n_rep_m + 1;
                     say("MISMATCH t=" & to_string(now, ns) & " cmd#=" & integer'image(cmd_idx - 1) & " opcode=" & to_hstring(last_cmd(5 downto 0)) &
                         " reg=" & integer'image(to_integer(gte_readAddr)) & " signal=gte_readData gold=" & to_hstring(gr) & " dut=" & to_hstring(d_readData));
                  end if;
               end if;
            end if;
         end if;
      end if;
   end process;

   ---------------------------------------------------------------- golden-side assertions
   -- Sampled on clk2x through external names; the golden sources are not modified.
   process (clk2x)
      variable n_mul   : integer := 0;
      variable n_div   : integer := 0;
      variable r       : tMAC123req;
      variable m1, m2  : signed(31 downto 0);

      function fits16(v : signed(31 downto 0)) return boolean is
      begin
         return v = resize(v(15 downto 0), 32);
      end function;

      function pow2ok(v : signed(31 downto 0)) return boolean is
      begin
         return v = to_signed(1, 32) or v = to_signed(16#10#, 32) or v = to_signed(16#1000#, 32) or v = to_signed(16#10000#, 32);
      end function;

      procedure check_mul(req : tMAC123req; which : integer) is
         variable a, b : signed(31 downto 0);
      begin
         a := req.mul1;
         b := req.mul2;
         if G_FAULT_MUL >= 0 and n_mul = G_FAULT_MUL then
            a := x"12345678";
            b := x"00789ABC";
         end if;
         n_mul := n_mul + 1;
         chk_mul <= n_mul;
         if is_x(std_logic_vector(a)) or is_x(std_logic_vector(b)) then
            as_mul <= as_mul + 1;
            say("ASSERT mul: metavalue operand MAC" & integer'image(which) & " t=" & to_string(now, ns) & " cmd#=" & integer'image(cmd_idx - 1));
         elsif not ((fits16(a) and fits16(b)) or pow2ok(a) or pow2ok(b)) then
            as_mul <= as_mul + 1;
            say("ASSERT mul: MAC" & integer'image(which) & " mul1=" & to_hstring(a) & " mul2=" & to_hstring(b) & " t=" & to_string(now, ns) &
                " cmd#=" & integer'image(cmd_idx - 1) & " opcode=" & to_hstring(last_cmd(5 downto 0)));
         end if;
      end procedure;

      variable lhs    : unsigned(15 downto 0);
      variable sc     : integer;
      variable dval   : signed(19 downto 0);
      variable shifted, wide : unsigned(63 downto 0);
   begin
      if rising_edge(clk2x) then
         r := << signal .tb_diff.golden.MAC1req : tMAC123req >>;
         if r.trigger = '1' then check_mul(r, 1); end if;
         r := << signal .tb_diff.golden.MAC2req : tMAC123req >>;
         if r.trigger = '1' then check_mul(r, 2); end if;
         r := << signal .tb_diff.golden.MAC3req : tMAC123req >>;
         if r.trigger = '1' then check_mul(r, 3); end if;

         if << signal .tb_diff.golden.igte_UNRDivide.trigger_5 : std_logic >> = '1' then
            lhs  := << signal .tb_diff.golden.igte_UNRDivide.lhs_5 : unsigned(15 downto 0) >>;
            sc   := << signal .tb_diff.golden.igte_UNRDivide.shiftcount_5 : integer range 0 to 15 >>;
            dval := << signal .tb_diff.golden.igte_UNRDivide.calc_val_d : signed(19 downto 0) >>;
            if G_FAULT_DIVSHIFT >= 0 and n_div = G_FAULT_DIVSHIFT then
               lhs := x"FFFF";
               sc  := 20;
            end if;
            if G_FAULT_DIVRANGE >= 0 and n_div = G_FAULT_DIVRANGE then
               dval := to_signed(200000, 20);
            end if;
            n_div := n_div + 1;
            chk_div <= n_div;

            -- shift must lose no bits: (lhs sll sc) in 32 bits equals lhs * 2**sc
            shifted := resize(resize(lhs, 32) sll sc, 64);
            wide    := resize(lhs, 64) sll sc;
            if shifted /= wide then
               as_shift <= as_shift + 1;
               say("ASSERT divshift: lhs=" & to_hstring(lhs) & " shiftcount=" & integer'image(sc) & " t=" & to_string(now, ns) & " cmd#=" & integer'image(cmd_idx - 1));
            end if;

            -- reciprocal refinement value must fit 18-bit signed
            if dval < to_signed(-131072, 20) or dval > to_signed(131071, 20) then
               as_range <= as_range + 1;
               say("ASSERT divrange: calc_val_d=" & integer'image(to_integer(dval)) & " t=" & to_string(now, ns) & " cmd#=" & integer'image(cmd_idx - 1));
            end if;
         end if;
      end if;
   end process;

   ---------------------------------------------------------------- stimulus
   stim : process
      file     infile       : text;
      variable f_status     : file_open_status;
      variable inLine       : line;
      variable p_type       : std_logic_vector(7 downto 0);
      variable p_addr       : std_logic_vector(7 downto 0);
      variable p_data       : std_logic_vector(31 downto 0);
      variable space        : character;
      variable lineno       : integer := 0;

      variable v_cpu        : boolean := false;
      variable v_autodump   : boolean := false;
      variable race_armed   : boolean := false;
      variable race_len     : integer := 1;
      variable arm_var      : integer := 0;
      variable cmd_var      : integer := 0;
      variable suite        : integer := 0;
      variable gold         : t_regs;
      variable cov          : cov_t := (others => (others => 0));
      variable suite_cmds   : integer_vector(0 to NSUITE - 1) := (others => 0);
      variable n_rep_d      : integer := 0;
      variable n_rep_t      : integer := 0;
      variable xor_done     : boolean := false;
      variable timeouts     : integer := 0;
      variable bcs_g, bcs_d : integer;
      variable total_diff   : integer;
      variable zero_cnt     : integer := 0;
      variable res_fail     : boolean;

      procedure tick is
      begin
         wait until rising_edge(clk1x);
         if ce = '1' then
            gte_cmdEna   <= '0';
            gte_writeEna <= '0';
            gte_readEna  <= '0';
         end if;
      end procedure;

      procedure note_timeout(what : string) is
      begin
         timeouts := timeouts + 1;
         if n_rep_t < G_MAX_REPORT then
            n_rep_t := n_rep_t + 1;
            say("TIMEOUT " & what & " t=" & to_string(now, ns) & " cmd#=" & integer'image(cmd_var - 1) & " line=" & integer'image(lineno));
         end if;
      end procedure;

      impure function strobes_low return boolean is
      begin
         return gte_cmdEna = '0' and gte_writeEna = '0' and gte_readEna = '0';
      end function;

      impure function is_idle return boolean is
      begin
         return g_busy = '0' and d_busy = '0' and strobes_low and ce = '1';
      end function;

      procedure wait_idle is
         variable n : integer := 0;
      begin
         while not is_idle loop
            tick;
            n := n + 1;
            if n > TIMEOUT_EDGES then note_timeout("idle"); exit; end if;
         end loop;
      end procedure;

      -- cpu.vhd stall rules, evaluated on pre-edge values
      procedure wait_legal(kind : integer) is
         variable n  : integer := 0;
         variable ok : boolean;
      begin
         loop
            case kind is
               when 0      => ok := ce = '1' and g_busy = '0' and gte_cmdEna = '0';                                -- command
               when 1      => ok := ce = '1' and g_busy = '0' and gte_cmdEna = '0';                                -- write
               when others => ok := ce = '1' and g_busy = '0' and gte_cmdEna = '0' and gte_writeEna = '0';         -- read
            end case;
            exit when ok;
            tick;
            n := n + 1;
            if n > TIMEOUT_EDGES then note_timeout("legal"); exit; end if;
         end loop;
      end procedure;

      procedure arm_pause(len : integer) is
      begin
         pause_len     <= len;
         arm_var       := arm_var + 1;
         pause_arm_cnt <= arm_var;
      end procedure;

      procedure on_issue is
      begin
         if race_armed then
            arm_pause(race_len);
            race_armed := false;
         end if;
      end procedure;

      procedure report_reg(r : integer; g : std_logic_vector(31 downto 0); d : unsigned(31 downto 0)) is
      begin
         mm_dump <= mm_dump + 1;
         if n_rep_d < G_MAX_REPORT then
            n_rep_d := n_rep_d + 1;
            say("MISMATCH t=" & to_string(now, ns) & " cmd#=" & integer'image(cmd_var - 1) & " opcode=" & to_hstring(last_cmd(5 downto 0)) &
                " reg=" & integer'image(r) & " gold=" & to_hstring(g) & " dut=" & to_hstring(d));
         end if;
      end procedure;

      procedure do_dump is
         variable n  : integer;
         variable gv : std_logic_vector(31 downto 0);
      begin
         wait_idle;
         in_dump <= true;
         for k in 0 to 63 loop
            n := 0;
            loop
               gte_readAddr <= to_unsigned(k, 6);
               gte_readEna  <= '1';
               tick;
               exit when ce = '1';
               n := n + 1;
               if n > TIMEOUT_EDGES then note_timeout("dump"); exit; end if;
            end loop;
            gold(k) := std_logic_vector(g_readData);
            gv      := gold(k);
            if (not xor_done) and G_FAULT_XOR_CMD >= 0 and cmd_var - 1 = G_FAULT_XOR_CMD and k = G_FAULT_XOR_REG then
               gv(G_FAULT_XOR_BIT) := not gv(G_FAULT_XOR_BIT);
               xor_done := true;
            end if;
            if gv /= std_logic_vector(d_readData) then
               report_reg(k, gv, d_readData);
            end if;
         end loop;
         gte_readEna <= '0';
         in_dump     <= false;
      end procedure;

      procedure count_cov(opc_word : std_logic_vector(31 downto 0)) is
         variable o  : integer := to_integer(unsigned(opc_word(5 downto 0)));
         variable fl : std_logic_vector(31 downto 0) := gold(63);
         variable s  : integer := suite;

         procedure bump(k : integer) is
         begin
            cov(s, k) := cov(s, k) + 1;
         end procedure;

         procedure yn(bit_i : integer; k_yes : integer; k_no : integer) is
         begin
            if fl(bit_i) = '1' then bump(k_yes); else bump(k_no); end if;
         end procedure;
      begin
         if s >= NSUITE then s := NSUITE - 1; end if;
         bump(K_OP + o);
         suite_cmds(s) := suite_cmds(s) + 1;
         if WRITES_IR(o) then
            yn(24, K_IR + 0, K_IR + 3);
            yn(23, K_IR + 1, K_IR + 4);
            yn(22, K_IR + 2, K_IR + 5);
         end if;
         if o = 16#01# or o = 16#30# then
            yn(14, K_SXY + 0, K_SXY + 2);
            yn(13, K_SXY + 1, K_SXY + 3);
            yn(18, K_SZ3, K_SZ3 + 1);
            yn(17, K_DIV, K_DIV + 1);
         end if;
         if o = 16#2D# or o = 16#2E# then
            yn(18, K_OTZ, K_OTZ + 1);
         end if;
         if PUSHES_RGB(o) then
            yn(21, K_RGB + 0, K_RGB + 3);
            yn(20, K_RGB + 1, K_RGB + 4);
            yn(19, K_RGB + 2, K_RGB + 5);
         end if;
      end procedure;

      procedure do_cmd(w : std_logic_vector(31 downto 0)) is
      begin
         wait_legal(0);
         gte_cmdData <= unsigned(w);
         gte_cmdEna  <= '1';
         last_cmd    <= unsigned(w);
         cmd_var     := cmd_var + 1;
         cmd_idx     <= cmd_var;
         bcs_g       := bc_g;
         bcs_d       := bc_d;
         on_issue;
         tick;
         if not v_cpu then
            wait_idle;
            if bc_g - bcs_g /= bc_d - bcs_d then
               bd_seq <= bd_seq + 1;
               if bd_seq < G_MAX_REPORT then
                  say("BUSY DIFF t=" & to_string(now, ns) & " cmd#=" & integer'image(cmd_var - 1) & " opcode=" & to_hstring(w(5 downto 0)) &
                      " signal=busy_cycles gold=" & integer'image(bc_g - bcs_g) & " dut=" & integer'image(bc_d - bcs_d));
               end if;
            end if;
            if v_autodump then
               do_dump;
               count_cov(w);
            end if;
         end if;
      end procedure;

      procedure do_write(a : std_logic_vector(7 downto 0); d : std_logic_vector(31 downto 0)) is
      begin
         wait_legal(1);
         gte_writeAddr <= unsigned(a(5 downto 0));
         gte_writeData <= unsigned(d);
         gte_writeEna  <= '1';
         on_issue;
         tick;
         if not v_cpu then wait_idle; end if;
      end procedure;

      procedure do_read(a : std_logic_vector(7 downto 0)) is
         variable gv : std_logic_vector(31 downto 0);
      begin
         wait_legal(2);
         gte_readAddr <= unsigned(a(5 downto 0));
         gte_readEna  <= '1';
         on_issue;
         tick;
         if not v_cpu then
            wait_idle;
            gv := std_logic_vector(g_readData);
            if gv /= std_logic_vector(d_readData) then
               report_reg(to_integer(unsigned(a(5 downto 0))), gv, d_readData);
            end if;
         end if;
      end procedure;

      -- write and read strobes on the same clk1x edge (a stalled MFC2 re-issues on busy/cmdEna only, cpu.vhd:1163)
      procedure do_wr_rd(a : std_logic_vector(7 downto 0); d : std_logic_vector(31 downto 0); ra : unsigned(5 downto 0)) is
      begin
         wait_legal(1);
         gte_writeAddr <= unsigned(a(5 downto 0));
         gte_writeData <= unsigned(d);
         gte_writeEna  <= '1';
         gte_readAddr  <= ra;
         gte_readEna   <= '1';
         tick;
      end procedure;

      -- reset pulse while ce is low (reset has priority over ce in both GTEs)
      procedure do_pause_reset(len : integer) is
         variable n : integer := 0;
      begin
         wait_idle;
         arm_pause(len);
         tick;
         while pause_done_cnt /= arm_var loop
            tick;
            n := n + 1;
            if n > TIMEOUT_EDGES then note_timeout("pause"); exit; end if;
         end loop;
         if ce = '0' then
            reset <= '1';
            tick;
            reset <= '0';
         end if;
         while ce = '0' loop
            tick;
         end loop;
         tick;
      end procedure;

      procedure do_reset is
      begin
         -- Reset is applied only while idle: the golden leaves partially applied
         -- results when reset lands mid-command, which is outside the contract.
         wait_idle;
         reset <= '1';
         tick;
         reset <= '0';
         tick;
      end procedure;

      procedure do_pause_blocking(len : integer) is
         variable n : integer := 0;
      begin
         arm_pause(len);
         tick;
         while pause_done_cnt /= arm_var loop
            tick;
            n := n + 1;
            if n > TIMEOUT_EDGES then note_timeout("pause"); exit; end if;
         end loop;
         tick;
         while ce = '0' loop
            tick;
            n := n + 1;
            if n > TIMEOUT_EDGES then note_timeout("pause end"); exit; end if;
         end loop;
      end procedure;

      procedure print_coverage is
      begin
         for s in 0 to NSUITE - 1 loop
            if suite_cmds(s) > 0 then
               say("COVERAGE suite=" & SUITE_NAME(s) & " commands=" & integer'image(suite_cmds(s)));
               for k in 0 to NKIND - 1 loop
                  if k >= K_IR or VALID_OPC(k) then
                     say("COV " & SUITE_NAME(s) & " " & KIND_NAME(k) & " " & integer'image(cov(s, k)));
                     if cov(s, k) = 0 then
                        zero_cnt := zero_cnt + 1;
                        say("COVZERO suite=" & SUITE_NAME(s) & " counter=" & KIND_NAME(k));
                     end if;
                  end if;
               end loop;
               for k in 0 to 63 loop
                  if not VALID_OPC(k) and cov(s, K_OP + k) > 0 then
                     say("COV " & SUITE_NAME(s) & " " & KIND_NAME(k) & " " & integer'image(cov(s, k)));
                  end if;
               end loop;
            end if;
         end loop;
      end procedure;

   begin
      -- reset release
      reset <= '1';
      for i in 1 to 8 loop tick; end loop;
      reset <= '0';
      for i in 1 to 4 loop tick; end loop;
      cmp_en <= true;
      for i in 1 to 2 loop tick; end loop;

      file_open(f_status, infile, G_VECFILE, read_mode);
      if f_status /= open_ok then
         say("ERROR cannot open vector file " & G_VECFILE);
         tb_err <= tb_err + 1;
      else
         while not endfile(infile) loop
            readline(infile, inLine);
            lineno := lineno + 1;
            if inLine'length > 0 and inLine.all(inLine.all'left) /= '#' then
               hread(inLine, p_type);
               read(inLine, space);
               hread(inLine, p_addr);
               read(inLine, space);
               hread(inLine, p_data);

               case to_integer(unsigned(p_type)) is
                  when 16#01# => do_cmd(p_data);
                  when 16#04# => do_write(p_addr, p_data);
                  when 16#05# => do_read(p_addr);
                  when 16#02# =>
                     v_cpu      := p_data(0) = '1';
                     v_autodump := p_data(1) = '1';
                     mode_cpu   <= v_cpu;
                  when 16#10# =>
                     for i in 1 to to_integer(unsigned(p_data(30 downto 0))) loop tick; end loop;
                  when 16#11# => do_dump;
                  when 16#12# => do_reset;
                  when 16#13# => do_pause_blocking(maximum(1, to_integer(unsigned(p_data(30 downto 0)))));
                  when 16#14# =>
                     race_armed := true;
                     race_len   := maximum(1, to_integer(unsigned(p_data(30 downto 0))));
                  when 16#15# =>
                     suite     := to_integer(unsigned(p_data(7 downto 0)));
                     cur_suite <= suite;
                  when 16#16# =>
                     arm_pause(maximum(1, to_integer(unsigned(p_data(30 downto 0)))));
                     tick;
                  when 16#17# => do_wr_rd(p_addr, p_data, unsigned(p_addr(5 downto 0)));
                  when 16#18# => do_wr_rd(p_addr, p_data, unsigned(p_addr(5 downto 0)) + 1);
                  when 16#19# => do_pause_reset(maximum(2, to_integer(unsigned(p_data(30 downto 0)))));
                  when others =>
                     say("ERROR unknown vector type at line " & integer'image(lineno));
                     tb_err <= tb_err + 1;
               end case;

               total_diff := mm_dump + mm_edge + bd_edge + bd_seq + as_mul + as_shift + as_range + idx_err;
               exit when total_diff > G_MAX_FAIL or timeouts > 20;
            end if;
         end loop;
         file_close(infile);
      end if;

      -- drain
      v_cpu := false;
      for i in 1 to 16 loop tick; end loop;
      wait_idle;
      for i in 1 to 16 loop tick; end loop;
      stim_done <= true;
      wait for 1 ns;

      print_coverage;
      say("COVSUMMARY zero_counters=" & integer'image(zero_cnt));

      res_fail := mm_dump + mm_edge + bd_edge + bd_seq + as_mul + as_shift + as_range + idx_err + tb_err + timeouts > 0
                  or (G_REQUIRE_COVERAGE and zero_cnt > 0);
      say("RESULT mismatches=" & integer'image(mm_dump + mm_edge + tb_err + timeouts + idx_err) &
          " busy_diffs=" & integer'image(bd_edge + bd_seq) &
          " assert_fails=" & integer'image(as_mul + as_shift + as_range) &
          " commands=" & integer'image(cmd_var) & " " & verdict(res_fail));
      say("PAUSES fired=" & integer'image(n_pause) & " while_busy=" & integer'image(n_pause_busy));
      say("ASSERTS mul=" & integer'image(as_mul) & " divshift=" & integer'image(as_shift) & " divrange=" & integer'image(as_range) &
          " checked_mul=" & integer'image(chk_mul) & " checked_div=" & integer'image(chk_div));
      if res_fail then stop(1); else stop(0); end if;
      wait;
   end process;

end architecture;
