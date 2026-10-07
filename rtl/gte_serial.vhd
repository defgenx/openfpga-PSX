-- GTE with two MAC lanes driven by a micro-code ROM; drop-in for gte.vhd.
-- Owning doc: docs/pocket/GTE.md. Micro-word layout: gte_serial_pkg.vhd.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pGTE.all;
use work.gte_serial_pkg.all;
use work.gte_serial_ucode.all;

entity gte_serial is
   generic
   (
      G_L                  : integer := 1   -- 1: golden timing, 2: product registered (one more cycle per offset)
   );
   port
   (
      clk1x                : in  std_logic;
      clk2x                : in  std_logic;
      clk2xIndex           : in  std_logic;
      ce                   : in  std_logic;
      reset                : in  std_logic;

      WIDESCREEN           : in  std_logic_vector(1 downto 0);
      TURBO                : in  std_logic;

      gte_busy             : out std_logic;
      gte_readAddr         : in  unsigned(5 downto 0);
      gte_readData         : out unsigned(31 downto 0);
      gte_readEna          : in  std_logic;
      gte_writeAddr_in     : in  unsigned(5 downto 0);
      gte_writeData_in     : in  unsigned(31 downto 0);
      gte_writeEna_in      : in  std_logic;
      gte_cmdData          : in  unsigned(31 downto 0);
      gte_cmdEna           : in  std_logic;

      loading_savestate    : in  std_logic;
      SS_reset             : in  std_logic;
      SS_DataWrite         : in  std_logic_vector(31 downto 0);
      SS_Adr               : in  unsigned(5 downto 0);
      SS_wren              : in  std_logic;
      SS_rden              : in  std_logic;
      SS_DataRead          : out std_logic_vector(31 downto 0);
      SS_idle              : out std_logic;

      debug_firstGTE       : out std_logic
   );
end entity;

architecture arch of gte_serial is

   -- flip-flop registers
   signal REG_RGBC : unsigned(31 downto 0);
   signal REG_OTZ  : unsigned(15 downto 0);
   signal REG_IR0  : signed(15 downto 0);
   signal REG_IR1  : signed(15 downto 0);
   signal REG_IR2  : signed(15 downto 0);
   signal REG_IR3  : signed(15 downto 0);
   signal REG_SX0  : signed(15 downto 0);
   signal REG_SY0  : signed(15 downto 0);
   signal REG_SX1  : signed(15 downto 0);
   signal REG_SY1  : signed(15 downto 0);
   signal REG_SX2  : signed(15 downto 0);
   signal REG_SY2  : signed(15 downto 0);
   signal REG_SZ0  : unsigned(15 downto 0);
   signal REG_SZ1  : unsigned(15 downto 0);
   signal REG_SZ2  : unsigned(15 downto 0);
   signal REG_SZ3  : unsigned(15 downto 0);
   signal REG_RGB0 : unsigned(31 downto 0);
   signal REG_RGB1 : unsigned(31 downto 0);
   signal REG_RGB2 : unsigned(31 downto 0);
   signal REG_MAC0 : signed(31 downto 0);
   signal REG_MAC1 : signed(31 downto 0);
   signal REG_MAC2 : signed(31 downto 0);
   signal REG_MAC3 : signed(31 downto 0);
   signal REG_LZCS : signed(31 downto 0);
   signal REG_LZCR : unsigned(5 downto 0);
   signal REG_FLAG : std_logic_vector(31 downto 12);

   -- RAM registers: three identical copies (CPU read, engine ports 0 and 1)
   type t_ram is array (0 to 63) of std_logic_vector(31 downto 0);
   signal ram_cpu : t_ram := (others => (others => '0'));
   signal ram_p0  : t_ram := (others => (others => '0'));
   signal ram_p1  : t_ram := (others => (others => '0'));
   attribute ramstyle : string;
   attribute ramstyle of ram_cpu : signal is "M10K";
   attribute ramstyle of ram_p0  : signal is "M10K";
   attribute ramstyle of ram_p1  : signal is "M10K";

   signal valid     : std_logic_vector(0 to 63) := (others => '0');
   signal ram_we    : std_logic;
   signal ram_wdata : std_logic_vector(31 downto 0);

   -- CPU read path
   signal cpu_rd_en     : std_logic;
   signal rd_isram  : std_logic;
   signal rd_valid  : std_logic;
   signal q_cpu     : std_logic_vector(31 downto 0);
   signal rd_ff     : unsigned(31 downto 0);

   -- command, busy
   type t_state is (IDLE, BUSY);
   signal state     : t_state := IDLE;
   signal cnt       : integer range 0 to 127 := 0;
   signal ecount    : integer range 0 to 127 := 0;
   signal c_sf      : std_logic := '0';
   signal c_lm      : std_logic := '0';
   signal c_mx      : unsigned(1 downto 0) := "00";
   signal c_v       : unsigned(1 downto 0) := "00";
   signal c_cv      : unsigned(1 downto 0) := "00";
   signal acc_ok    : std_logic;
   signal acc_run   : std_logic;
   signal pstart        : integer;
   signal pf0       : std_logic_vector(RD_W-1 downto 0);
   signal pf1       : std_logic_vector(RD_W-1 downto 0);

   -- sequencer
   signal run       : std_logic := '0';
   signal rom_addr  : integer range 0 to UCODE_DEPTH-1 := 0;
   signal rom_next  : integer range 0 to UCODE_DEPTH-1;
   signal rom_q     : std_logic_vector(UW-1 downto 0) := (others => '0');
   -- a signal, not the constant, so Quartus infers an M10K ROM instead of folding it into logic
   signal ucode_rom : t_ucode := UCODE;
   attribute romstyle : string;
   attribute romstyle of ucode_rom : signal is "M10K";

   -- engine read ports and staging
   type t_stg is array (0 to NSTG-1) of signed(31 downto 0);
   signal stg       : t_stg := (others => (others => '0'));
   signal sel0      : std_logic;
   signal sel1      : std_logic;
   signal ra0       : integer range 0 to 63;
   signal ra1       : integer range 0 to 63;
   signal q0        : std_logic_vector(31 downto 0);
   signal q1        : std_logic_vector(31 downto 0);
   signal vq0       : std_logic := '0';
   signal vq1       : std_logic := '0';
   signal ld0       : std_logic := '0';
   signal ld1       : std_logic := '0';
   signal dst0      : integer range 0 to NSTG-1 := 0;
   signal dst1      : integer range 0 to NSTG-1 := 0;

   -- lanes
   type t_ctl is record
      v    : std_logic;
      m0   : std_logic;
      row  : integer range 0 to 3;
      xs   : std_logic;
      k    : integer range 0 to 3;
      add  : integer range 0 to 7;
      sub  : std_logic;
      swap : std_logic;
      wb   : integer range 0 to 7;
      -- execute decode: X = sval when xsv; addend sval / accumulator / macLast; res = (X^nx) + (a^na) + cin
      xsv  : std_logic;
      asv  : std_logic;
      aac  : std_logic;
      ala  : std_logic;
      nx   : std_logic;
      na   : std_logic;
   end record;
   constant CTL0 : t_ctl := ('0', '0', 0, '0', 0, 0, '0', '0', 0, '0', '0', '0', '0', '0', '0');
   type t_ctls  is array (0 to 1) of t_ctl;
   type t_opa   is array (0 to 1) of signed(17 downto 0);
   type t_opb   is array (0 to 1) of signed(18 downto 0);
   type t_ops   is array (0 to 1) of signed(44 downto 0);
   type t_prod  is array (0 to 1) of signed(36 downto 0);
   type t_res   is array (0 to 1) of signed(44 downto 0);
   type t_acc   is array (0 to 3) of signed(44 downto 0);

   signal iC    : t_ctls := (others => CTL0);
   signal opA   : t_opa  := (others => (others => '0'));
   signal opB   : t_opb  := (others => (others => '0'));
   signal opS   : t_ops  := (others => (others => '0'));
   signal pC    : t_ctls := (others => CTL0);
   signal pS    : t_ops  := (others => (others => '0'));
   signal pP    : t_prod := (others => (others => '0'));
   signal eC    : t_ctls;
   signal eS    : t_ops;
   signal eP    : t_prod;
   signal wC    : t_ctls := (others => CTL0);
   signal res_q : t_res  := (others => (others => '0'));
   signal res_c : t_res;

   signal acc      : t_acc := (others => (others => '0'));
   signal macLast  : t_acc := (others => (others => '0'));
   signal acc0     : signed(34 downto 0) := (others => '0');
   signal mac0Last : signed(34 downto 0) := (others => '0');

   type t_snap is array (0 to 1) of signed(15 downto 0);
   signal snap_ir1 : t_snap := (others => (others => '0'));
   signal snap_ir2 : t_snap := (others => (others => '0'));
   signal vsnap0   : signed(15 downto 0) := (others => '0');
   signal vsnap1   : signed(15 downto 0) := (others => '0');
   signal vsnap2   : signed(15 downto 0) := (others => '0');

   -- divide
   signal div_trigger : std_logic := '0';
   signal div_lhs     : unsigned(15 downto 0) := (others => '0');
   signal div_rhs     : unsigned(15 downto 0) := (others => '0');
   signal div_result  : unsigned(16 downto 0);
   signal div_Error   : std_logic;

   constant MINVAL45 : signed(44 downto 0) := '1' & x"80000000000";
   constant MAXVAL45 : signed(44 downto 0) := '0' & x"7FFFFFFFFFF";
   constant MINVAL35 : signed(34 downto 0) := "111" & x"80000000";
   constant MAXVAL35 : signed(34 downto 0) := "000" & x"7FFFFFFF";

   function cat16(hi : signed(15 downto 0); lo : signed(15 downto 0)) return unsigned is
   begin
      return unsigned(std_logic_vector(hi)) & unsigned(std_logic_vector(lo));
   end function;

   function is_ram(a : integer) return boolean is
   begin
      return (a <= 5) or (a = 23) or (a >= 32 and a <= 62);
   end function;

   -- registers the golden sign-extends on read
   function is_sext16(a : integer) return boolean is
   begin
      return a = 1 or a = 3 or a = 5 or a = 36 or a = 44 or a = 52 or a = 58 or a = 59 or a = 61 or a = 62;
   end function;

   function ram_a(base : integer; off : integer; mx : unsigned(1 downto 0); v : unsigned(1 downto 0); cv : unsigned(1 downto 0)) return integer is
      variable b : integer;
   begin
      b := 0;
      case base is
         when BASE_MAT => b := 32; if mx = "01" then b := 40; elsif mx = "10" then b := 48; end if;
         when BASE_VEC => b := 0;  if v  = "01" then b := 2;  elsif v  = "10" then b := 4;  end if;
         when BASE_TRV => b := 37; if cv = "01" then b := 45; elsif cv = "10" then b := 53; end if;
         when others   => b := 0;
      end case;
      return to_integer(to_unsigned(b, 6) + to_unsigned(off, 6));
   end function;

   function rd_addr(f : std_logic_vector(RD_W-1 downto 0); mx : unsigned(1 downto 0); v : unsigned(1 downto 0); cv : unsigned(1 downto 0)) return integer is
   begin
      return ram_a(to_integer(unsigned(f(RD_BASE+1 downto RD_BASE))), to_integer(unsigned(f(RD_OFF+5 downto RD_OFF))), mx, v, cv);
   end function;

   function lane_lsb(l : integer) return integer is
   begin
      if l = 0 then return LA_LSB; else return LB_LSB; end if;
   end function;

   function lane_ctl(w : std_logic_vector(UW-1 downto 0); lsb : integer; run : std_logic) return t_ctl is
      variable c : t_ctl;
   begin
      c.v    := run and w(lsb + L_V);
      c.m0   := w(lsb + L_M0);
      if lsb = LB_LSB then c.m0 := '0'; end if;  -- MAC0 ops are always on lane A (gte_ucode.py)
      c.row  := to_integer(unsigned(w(lsb + L_ROW + 1 downto lsb + L_ROW)));
      c.xs   := w(lsb + L_XS);
      c.k    := to_integer(unsigned(w(lsb + L_K + 1 downto lsb + L_K)));
      c.add  := to_integer(unsigned(w(lsb + L_ADD + 2 downto lsb + L_ADD)));
      c.sub  := w(lsb + L_SUB);
      c.swap := w(lsb + L_SWAP);
      c.wb   := to_integer(unsigned(w(lsb + L_WB + 2 downto lsb + L_WB)));
      c.xsv  := c.xs;
      c.asv  := '0'; c.aac := '0'; c.ala := '0';
      case c.add is
         when ADD_ACC              => c.aac := '1';
         when ADD_MACLAST          => c.ala := '1';
         when ADD_S | ADD_S_SH12   => c.asv := '1';
         when others               => null;
      end case;
      c.nx := c.sub and not c.swap;  -- a - X
      c.na := c.sub and c.swap;      -- X - a
      return c;
   end function;

   -- staging slot half for source codes 1..16
   impure function stg_half(code : integer) return signed is
      variable s : integer;
   begin
      s := (code - 1) / 2;
      if ((code - 1) mod 2) = 0 then
         return stg(s)(15 downto 0);
      else
         return stg(s)(31 downto 16);
      end if;
   end function;

   impure function a_sel(code : integer) return signed is
      variable r : signed(15 downto 0);
   begin
      case code is
         when 1 to 2*NSTG => return resize(stg_half(code), 18);
         when 17 => return resize(REG_IR1, 18);
         when 18 => return resize(REG_IR2, 18);
         when 19 => return resize(REG_IR3, 18);
         when 20 => return resize(REG_IR0, 18);
         when 21 => return resize(REG_SX0, 18);
         when 22 => return resize(REG_SX1, 18);
         when 23 => return resize(REG_SX2, 18);
         when 24 => return signed(resize(REG_SZ0, 18));
         when 25 => return signed(resize(REG_SZ1, 18));
         when 26 => return signed(resize(REG_SZ2, 18));
         when 27 => return signed(resize(REG_SZ3, 18));
         when 28 => return signed(resize(REG_RGBC( 7 downto  0), 18));
         when 29 => return signed(resize(REG_RGBC(15 downto  8), 18));
         when 30 => return signed(resize(REG_RGBC(23 downto 16), 18));
         when 31 => return signed(resize(REG_RGB0( 7 downto  0), 18));
         when 32 => return signed(resize(REG_RGB0(15 downto  8), 18));
         when 33 => return signed(resize(REG_RGB0(23 downto 16), 18));
         when 34 | 35 =>
            r := signed(resize(REG_RGBC(7 downto 0) & "0000", 16));
            if code = 35 then r := to_signed(0, 16) - r; end if;
            return resize(r, 18);
         when 36 => return resize(snap_ir1(0), 18);
         when 37 => return resize(snap_ir1(1), 18);
         when 38 => return resize(snap_ir2(0), 18);
         when 39 => return resize(snap_ir2(1), 18);
         when others => return to_signed(0, 18);
      end case;
   end function;

   impure function b_sel(code : integer) return signed is
   begin
      case code is
         when 1 to 2*NSTG => return resize(stg_half(code), 19);
         when 17 => return resize(REG_IR1, 19);
         when 18 => return resize(REG_IR2, 19);
         when 19 => return resize(REG_IR3, 19);
         when 20 => return resize(REG_IR0, 19);
         when 21 => return signed(resize(REG_RGBC( 7 downto  0), 19));
         when 22 => return signed(resize(REG_RGBC(15 downto  8), 19));
         when 23 => return signed(resize(REG_RGBC(23 downto 16), 19));
         when 24 => return resize(vsnap0, 19);
         when 25 => return resize(vsnap1, 19);
         when 26 => return resize(vsnap2, 19);
         when 27 => return signed(resize(div_result, 19));
         when 28 => return resize(REG_SY0, 19);
         when 29 => return resize(REG_SY1, 19);
         when 30 => return resize(REG_SY2, 19);
         when 31 => return to_signed(16#1000#, 19);
         when 32 => return to_signed(16#10000#, 19);
         when others => return to_signed(0, 19);
      end case;
   end function;

   impure function s_sel(code : integer) return signed;

   -- S operand at issue: shifted for X (xs), or as the S / S<<12 addend
   impure function s_val(w : std_logic_vector(UW-1 downto 0); lsb : integer) return signed is
      variable sv : signed(44 downto 0);
      variable sh : integer;
   begin
      sv := resize(s_sel(to_integer(unsigned(w(lsb + L_SSEL + 3 downto lsb + L_SSEL)))), 45);
      if w(lsb + L_XS) = '1' then
         case to_integer(unsigned(w(lsb + L_K + 1 downto lsb + L_K))) is
            when K_0    => sh := 0;
            when K_4    => sh := 4;
            when K_12   => sh := 12;
            when others => if (c_sf = '1') then sh := 12; else sh := 0; end if;
         end case;
         return shift_left(sv, sh);
      elsif to_integer(unsigned(w(lsb + L_ADD + 2 downto lsb + L_ADD))) = ADD_S_SH12 then
         return shift_left(sv, 12);
      end if;
      return sv;
   end function;

   impure function s_sel(code : integer) return signed is
   begin
      case code is
         when 1 to NSTG => return stg(code - 1);
         when 9       => return REG_MAC1;
         when 10      => return REG_MAC2;
         when 11      => return REG_MAC3;
         when others  => return to_signed(0, 32);
      end case;
   end function;

begin

   SS_DataRead    <= (others => '0');
   debug_firstGTE <= '0';

   ----------------------------------------------------------------
   -- command accept
   ----------------------------------------------------------------
   acc_ok  <= '1' when (state = IDLE and gte_cmdEna = '1' and clk2xIndex = '1' and ce = '1' and reset = '0') else '0';
   pstart      <= prog_start(gte_cmdData);
   pf0     <= prog_prefetch(gte_cmdData, 0);
   pf1     <= prog_prefetch(gte_cmdData, 1);
   acc_run <= '1' when (acc_ok = '1' and busy_edges(gte_cmdData(5 downto 0)) > 0 and pstart >= 0) else '0';

   ----------------------------------------------------------------
   -- CPU read: the golden's read mux split into RAM and FF halves
   ----------------------------------------------------------------
   cpu_rd_en <= ce and (not reset) and gte_readEna;

   gte_readData <= unsigned(q_cpu) when (rd_isram = '1' and rd_valid = '1') else
                   (others => '0') when (rd_isram = '1') else
                   rd_ff;

   process (clk2x)
      variable a : integer;
   begin
      if rising_edge(clk2x) then
         if (cpu_rd_en = '1') then
            a := to_integer(gte_readAddr);
            if is_ram(a) then rd_isram <= '1'; else rd_isram <= '0'; end if;
            rd_valid <= valid(a);
            case (a) is
               when 06 => rd_ff <= REG_RGBC;
               when 07 => rd_ff <= x"0000" & REG_OTZ;
               when 08 => rd_ff <= unsigned(resize(REG_IR0, 32));
               when 09 => rd_ff <= unsigned(resize(REG_IR1, 32));
               when 10 => rd_ff <= unsigned(resize(REG_IR2, 32));
               when 11 => rd_ff <= unsigned(resize(REG_IR3, 32));
               when 12 => rd_ff <= cat16(REG_SY0, REG_SX0);
               when 13 => rd_ff <= cat16(REG_SY1, REG_SX1);
               when 14 => rd_ff <= cat16(REG_SY2, REG_SX2);
               when 15 => rd_ff <= cat16(REG_SY2, REG_SX2);
               when 16 => rd_ff <= x"0000" & REG_SZ0;
               when 17 => rd_ff <= x"0000" & REG_SZ1;
               when 18 => rd_ff <= x"0000" & REG_SZ2;
               when 19 => rd_ff <= x"0000" & REG_SZ3;
               when 20 => rd_ff <= REG_RGB0;
               when 21 => rd_ff <= REG_RGB1;
               when 22 => rd_ff <= REG_RGB2;
               when 24 => rd_ff <= unsigned(REG_MAC0);
               when 25 => rd_ff <= unsigned(REG_MAC1);
               when 26 => rd_ff <= unsigned(REG_MAC2);
               when 27 => rd_ff <= unsigned(REG_MAC3);
               when 28 | 29 =>
                  rd_ff(31 downto 15) <= (others => '0');
                  if (REG_IR1 < 0) then rd_ff( 4 downto  0) <= "00000"; elsif (REG_IR1(15 downto 7) > 31) then rd_ff( 4 downto  0) <= "11111"; else rd_ff( 4 downto  0) <= unsigned(REG_IR1(11 downto 7)); end if;
                  if (REG_IR2 < 0) then rd_ff( 9 downto  5) <= "00000"; elsif (REG_IR2(15 downto 7) > 31) then rd_ff( 9 downto  5) <= "11111"; else rd_ff( 9 downto  5) <= unsigned(REG_IR2(11 downto 7)); end if;
                  if (REG_IR3 < 0) then rd_ff(14 downto 10) <= "00000"; elsif (REG_IR3(15 downto 7) > 31) then rd_ff(14 downto 10) <= "11111"; else rd_ff(14 downto 10) <= unsigned(REG_IR3(11 downto 7)); end if;
               when 30 => rd_ff <= unsigned(REG_LZCS);
               when 31 => rd_ff <= resize(REG_LZCR, 32);
               when 63 => rd_ff <= unsigned(REG_FLAG) & x"000";
               when others => null;
            end case;
         end if;
      end if;
   end process;

   ----------------------------------------------------------------
   -- RAM copies: CPU writes identically, one read port each
   ----------------------------------------------------------------
   ram_we <= ce and (not reset) and gte_writeEna_in and clk2xIndex when is_ram(to_integer(gte_writeAddr_in)) else '0';

   ram_wdata <= std_logic_vector(resize(signed(gte_writeData_in(15 downto 0)), 32)) when is_sext16(to_integer(gte_writeAddr_in))
                else std_logic_vector(gte_writeData_in);

   process (clk2x)
   begin
      if rising_edge(clk2x) then
         if (ram_we = '1') then
            ram_cpu(to_integer(gte_writeAddr_in)) <= ram_wdata;
         end if;
         if (cpu_rd_en = '1') then
            q_cpu <= ram_cpu(to_integer(gte_readAddr));
         end if;
      end if;
   end process;

   sel0 <= (acc_run and pf0(RD_EN)) or (run and rom_q(RD0_LSB + RD_EN));
   sel1 <= (acc_run and pf1(RD_EN)) or (run and rom_q(RD1_LSB + RD_EN));

   ra0 <= rd_addr(pf0, unsigned(gte_cmdData(18 downto 17)), unsigned(gte_cmdData(16 downto 15)), unsigned(gte_cmdData(14 downto 13))) when acc_run = '1' else
          rd_addr(rom_q(RD0_LSB + RD_W - 1 downto RD0_LSB), c_mx, c_v, c_cv);
   ra1 <= rd_addr(pf1, unsigned(gte_cmdData(18 downto 17)), unsigned(gte_cmdData(16 downto 15)), unsigned(gte_cmdData(14 downto 13))) when acc_run = '1' else
          rd_addr(rom_q(RD1_LSB + RD_W - 1 downto RD1_LSB), c_mx, c_v, c_cv);

   process (clk2x)
   begin
      if rising_edge(clk2x) then
         if (ram_we = '1') then
            ram_p0(to_integer(gte_writeAddr_in)) <= ram_wdata;
         end if;
         if (ce = '1' and sel0 = '1') then
            q0 <= ram_p0(ra0);
         end if;

         if (reset = '1') then
            ld0 <= '0';
         elsif (ce = '1') then
            ld0 <= sel0;
            if (sel0 = '1') then
               vq0 <= valid(ra0);
               if (acc_run = '1') then
                  dst0 <= to_integer(unsigned(pf0(RD_DST + 2 downto RD_DST)));
               else
                  dst0 <= to_integer(unsigned(rom_q(RD0_LSB + RD_DST + 1 downto RD0_LSB + RD_DST)));
               end if;
            end if;
         end if;
      end if;
   end process;

   process (clk2x)
   begin
      if rising_edge(clk2x) then
         if (ram_we = '1') then
            ram_p1(to_integer(gte_writeAddr_in)) <= ram_wdata;
         end if;
         if (ce = '1' and sel1 = '1') then
            q1 <= ram_p1(ra1);
         end if;

         if (reset = '1') then
            ld1 <= '0';
         elsif (ce = '1') then
            ld1 <= sel1;
            if (sel1 = '1') then
               vq1 <= valid(ra1);
               if (acc_run = '1') then
                  dst1 <= to_integer(unsigned(pf1(RD_DST + 2 downto RD_DST)));
               else
                  dst1 <= to_integer(unsigned(rom_q(RD1_LSB + RD_DST + 1 downto RD1_LSB + RD_DST)));
               end if;
            end if;
         end if;
      end if;
   end process;

   -- staging registers
   process (clk2x)
   begin
      if rising_edge(clk2x) then
         if (ce = '1') then
            if (ld0 = '1') then
               if (vq0 = '1') then stg(dst0) <= signed(q0); else stg(dst0) <= (others => '0'); end if;
            end if;
            if (ld1 = '1') then
               if (vq1 = '1') then stg(dst1) <= signed(q1); else stg(dst1) <= (others => '0'); end if;
            end if;
         end if;
      end if;
   end process;

   ----------------------------------------------------------------
   -- micro-code ROM
   ----------------------------------------------------------------
   rom_next <= pstart when acc_run = '1' else
               rom_addr + 1 when rom_addr < UCODE_DEPTH - 1 else
               0;

   process (clk2x)
   begin
      if rising_edge(clk2x) then
         if (ce = '1') then
            rom_addr <= rom_next;
            rom_q    <= ucode_rom(rom_next);
         end if;
      end if;
   end process;

   ----------------------------------------------------------------
   -- lanes: issue, execute (G_L = 2: product register in between)
   ----------------------------------------------------------------
   g_l1 : if G_L = 1 generate
      eC <= iC;
      eS <= opS;
      eP(0) <= opA(0) * opB(0);
      eP(1) <= opA(1) * opB(1);
   end generate;

   g_l2 : if G_L = 2 generate
      eC <= pC;
      eS <= pS;
      eP <= pP;
      process (clk2x)
      begin
         if rising_edge(clk2x) then
            if (reset = '1') then
               pC(0).v <= '0';
               pC(1).v <= '0';
            elsif (ce = '1') then
               for l in 0 to 1 loop
                  pC(l) <= iC(l);
                  pS(l) <= opS(l);
                  pP(l) <= opA(l) * opB(l);
               end loop;
            end if;
         end if;
      end process;
   end generate;

   -- execute stage, combinational: X, addend and combine
   exec_comb : process (eC, eP, eS, acc, macLast, acc0, mac0Last)
      variable x   : signed(44 downto 0);
      variable a   : signed(44 downto 0);
      variable r46 : signed(45 downto 0);
      variable ci  : std_logic;
      variable lc  : t_ctl;
   begin
      for l in 0 to 1 loop
         lc := eC(l);
         if (lc.xsv = '1') then x := eS(l); else x := resize(eP(l), 45); end if;
         a := (others => '0');
         if (lc.asv = '1') then
            a := eS(l);
         elsif (lc.aac = '1') then
            if (lc.m0 = '1') then a := resize(acc0, 45); else a := resize(acc(lc.row)(43 downto 0), 45); end if;
         elsif (lc.ala = '1') then
            if (lc.m0 = '1') then a := resize(mac0Last, 45); else a := macLast(lc.row); end if;
         end if;
         if (lc.nx = '1') then x := not x; end if;
         if (lc.na = '1') then a := not a; end if;
         -- one carry chain: the +1 of a negation enters as the carry of an extra low bit
         if (lc.nx = '1' or lc.na = '1') then ci := '1'; else ci := '0'; end if;
         r46 := (x & '1') + (a & ci);
         res_c(l) <= r46(45 downto 1);
      end loop;
   end process;

   lanes : process (clk2x)
      variable lc  : t_ctl;
      variable lsb : integer;
      variable sl  : integer;
   begin
      if rising_edge(clk2x) then
         if (reset = '1') then
            for l in 0 to 1 loop
               iC(l).v <= '0';
               wC(l).v <= '0';
            end loop;
         elsif (ce = '1') then

            -- issue
            for l in 0 to 1 loop
               lsb := lane_lsb(l);
               iC(l)  <= lane_ctl(rom_q, lsb, run);
               opA(l) <= a_sel(to_integer(unsigned(rom_q(lsb + L_ASEL + 5 downto lsb + L_ASEL))));
               opB(l) <= b_sel(to_integer(unsigned(rom_q(lsb + L_BSEL + 5 downto lsb + L_BSEL))));
               opS(l) <= s_val(rom_q, lsb);
            end loop;

            -- execute
            for l in 0 to 1 loop
               lc := eC(l);
               res_q(l) <= res_c(l);
               wC(l)    <= lc;

               if (lc.v = '1') then
                  if (lc.m0 = '1') then
                     mac0Last <= acc0;
                     acc0     <= res_c(l)(34 downto 0);
                  else
                     macLast(lc.row) <= acc(lc.row);
                     acc(lc.row)     <= res_c(l);
                  end if;
               end if;
            end loop;

            -- side-effect snapshots
            if (run = '1') then
               sl := to_integer(unsigned(rom_q(SE_SNAP + 1 downto SE_SNAP)));
               if (sl /= 0) then
                  snap_ir1(sl - 1) <= REG_IR1;
                  snap_ir2(sl - 1) <= REG_IR2;
               end if;
               if (rom_q(SE_VSNAP) = '1') then
                  vsnap0 <= REG_IR1;
                  vsnap1 <= REG_IR2;
                  vsnap2 <= REG_IR3;
               end if;
            end if;

            -- synthesis translate_off
            if (eC(0).v = '1' and eC(1).v = '1' and eC(0).m0 = eC(1).m0) then
               assert (eC(0).m0 = '0' and eC(0).row /= eC(1).row)
                  report "gte_serial: both lanes execute the same accumulator" severity error;
            end if;
            -- synthesis translate_on

         end if;
      end if;
   end process;

   ----------------------------------------------------------------
   -- main process: front end, side effects, writebacks, FLAG
   ----------------------------------------------------------------
   process (clk2x)
      variable wa   : integer;
      variable lzd  : unsigned(31 downto 0);
      variable edg  : integer;
      variable m3s  : signed(31 downto 0);
      variable rq   : signed(44 downto 0);
      variable r35  : signed(34 downto 0);
      variable irr  : signed(31 downto 0);
      variable irv  : signed(15 downto 0);
      variable mval : signed(31 downto 0);
      variable ss, ui, irs, irsf, sat, satf : std_logic;
      variable irfl : boolean;
      variable hv   : unsigned(15 downto 0);
   begin
      if rising_edge(clk2x) then

         if (reset = '1') then

            state    <= IDLE;
            gte_busy <= '0';
            run      <= '0';
            valid    <= (others => '0');

            REG_RGBC <= (others => '0');
            REG_OTZ  <= (others => '0');
            REG_IR0  <= (others => '0');
            REG_IR1  <= (others => '0');
            REG_IR2  <= (others => '0');
            REG_IR3  <= (others => '0');
            REG_SX0  <= (others => '0');
            REG_SY0  <= (others => '0');
            REG_SX1  <= (others => '0');
            REG_SY1  <= (others => '0');
            REG_SX2  <= (others => '0');
            REG_SY2  <= (others => '0');
            REG_SZ0  <= (others => '0');
            REG_SZ1  <= (others => '0');
            REG_SZ2  <= (others => '0');
            REG_SZ3  <= (others => '0');
            REG_RGB0 <= (others => '0');
            REG_RGB1 <= (others => '0');
            REG_RGB2 <= (others => '0');
            REG_MAC0 <= (others => '0');
            REG_MAC1 <= (others => '0');
            REG_MAC2 <= (others => '0');
            REG_MAC3 <= (others => '0');
            REG_LZCS <= (others => '0');
            REG_LZCR <= (others => '0');
            REG_FLAG <= (others => '0');

         elsif (ce = '1') then

            div_trigger <= '0';

            -- CPU write
            if (gte_writeEna_in = '1' and clk2xIndex = '1') then
               wa := to_integer(gte_writeAddr_in);
               if is_ram(wa) then
                  valid(wa) <= '1';
               end if;

               case (wa) is
                  when 06 => REG_RGBC <= gte_writeData_in;
                  when 07 => REG_OTZ  <= gte_writeData_in(15 downto 0);
                  when 08 => REG_IR0  <= signed(gte_writeData_in(15 downto 0));
                  when 09 => REG_IR1  <= signed(gte_writeData_in(15 downto 0));
                  when 10 => REG_IR2  <= signed(gte_writeData_in(15 downto 0));
                  when 11 => REG_IR3  <= signed(gte_writeData_in(15 downto 0));
                  when 12 => REG_SX0  <= signed(gte_writeData_in(15 downto 0)); REG_SY0 <= signed(gte_writeData_in(31 downto 16));
                  when 13 => REG_SX1  <= signed(gte_writeData_in(15 downto 0)); REG_SY1 <= signed(gte_writeData_in(31 downto 16));
                  when 14 => REG_SX2  <= signed(gte_writeData_in(15 downto 0)); REG_SY2 <= signed(gte_writeData_in(31 downto 16));
                  when 15 =>
                     REG_SX2  <= signed(gte_writeData_in(15 downto 0)); REG_SY2 <= signed(gte_writeData_in(31 downto 16));
                     REG_SX1  <= REG_SX2; REG_SY1 <= REG_SY2;
                     REG_SX0  <= REG_SX1; REG_SY0 <= REG_SY1;
                  when 16 => REG_SZ0  <= gte_writeData_in(15 downto 0);
                  when 17 => REG_SZ1  <= gte_writeData_in(15 downto 0);
                  when 18 => REG_SZ2  <= gte_writeData_in(15 downto 0);
                  when 19 => REG_SZ3  <= gte_writeData_in(15 downto 0);
                  when 20 => REG_RGB0 <= gte_writeData_in;
                  when 21 => REG_RGB1 <= gte_writeData_in;
                  when 22 => REG_RGB2 <= gte_writeData_in;
                  when 24 => REG_MAC0 <= signed(gte_writeData_in);
                  when 25 => REG_MAC1 <= signed(gte_writeData_in);
                  when 26 => REG_MAC2 <= signed(gte_writeData_in);
                  when 27 => REG_MAC3 <= signed(gte_writeData_in);
                  when 28 =>
                     REG_IR1  <= signed("0000" & gte_writeData_in( 4 downto  0) & "0000000");
                     REG_IR2  <= signed("0000" & gte_writeData_in( 9 downto  5) & "0000000");
                     REG_IR3  <= signed("0000" & gte_writeData_in(14 downto 10) & "0000000");
                  when 30 =>
                     REG_LZCS <= signed(gte_writeData_in);
                     lzd := gte_writeData_in;
                     if (gte_writeData_in(31) = '1') then
                        lzd := not gte_writeData_in;
                     end if;
                     REG_LZCR <= to_unsigned(32, 6);
                     for i in 0 to 31 loop
                        if (lzd(i) = '1') then
                           REG_LZCR <= to_unsigned(31 - i, 6);
                        end if;
                     end loop;
                  when 63 =>
                     REG_FLAG(30 downto 12) <= std_logic_vector(gte_writeData_in(30 downto 12));
                     REG_FLAG(31) <= '0';
                     if ((gte_writeData_in(30 downto 12) and to_unsigned(16#7F87E#, 19)) > 0) then  -- bit 30..23 and 18..13
                        REG_FLAG(31) <= '1';
                     end if;
                  when others => null;
               end case;
            end if;

            -- engine stops after the word with halt
            if (run = '1' and rom_q(W_HALT) = '1') then
               run <= '0';
            end if;

            -- command accept and busy
            case (state) is

               when IDLE =>
                  cnt <= 0;
                  if (gte_cmdEna = '1' and clk2xIndex = '1') then
                     REG_FLAG <= (others => '0');
                     c_sf     <= gte_cmdData(19);
                     c_lm     <= gte_cmdData(10);
                     c_mx     <= gte_cmdData(18 downto 17);
                     c_v      <= gte_cmdData(16 downto 15);
                     c_cv     <= gte_cmdData(14 downto 13);
                     edg := busy_edges(gte_cmdData(5 downto 0));
                     if (edg > 0) then
                        gte_busy <= '1';
                        state    <= BUSY;
                        ecount   <= edg;
                        if (pstart >= 0) then
                           run <= '1';
                        end if;
                     else
                        gte_busy <= '0';
                     end if;
                  elsif (clk2xIndex = '0') then
                     gte_busy <= '0';
                  end if;

               when BUSY =>
                  if (cnt = ecount - 1) then
                     state <= IDLE;
                  else
                     cnt <= cnt + 1;
                  end if;

            end case;

            -- side effects of the current word
            if (run = '1') then

               -- push RGB from MAC
               if (rom_q(SE_RGB) = '1') then
                  if (REG_MAC1 < 0) then
                     REG_FLAG(21) <= '1';
                     REG_RGB2(7 downto 0) <= (others => '0');
                  elsif (unsigned(REG_MAC1(31 downto 4)) > 255) then
                     REG_FLAG(21) <= '1';
                     REG_RGB2(7 downto 0) <= (others => '1');
                  else
                     REG_RGB2(7 downto 0) <= unsigned(REG_MAC1(11 downto 4));
                  end if;

                  if (REG_MAC2 < 0) then
                     REG_FLAG(20) <= '1';
                     REG_RGB2(15 downto 8) <= (others => '0');
                  elsif (unsigned(REG_MAC2(31 downto 4)) > 255) then
                     REG_FLAG(20) <= '1';
                     REG_RGB2(15 downto 8) <= (others => '1');
                  else
                     REG_RGB2(15 downto 8) <= unsigned(REG_MAC2(11 downto 4));
                  end if;

                  if (REG_MAC3 < 0) then
                     REG_FLAG(19) <= '1';
                     REG_RGB2(23 downto 16) <= (others => '0');
                  elsif (unsigned(REG_MAC3(31 downto 4)) > 255) then
                     REG_FLAG(19) <= '1';
                     REG_RGB2(23 downto 16) <= (others => '1');
                  else
                     REG_RGB2(23 downto 16) <= unsigned(REG_MAC3(11 downto 4));
                  end if;

                  REG_RGB2(31 downto 24) <= REG_RGBC(31 downto 24);
                  REG_RGB0 <= REG_RGB1; REG_RGB1 <= REG_RGB2;
               end if;

               -- set OTZ
               if (rom_q(SE_OTZ) = '1') then
                  if (acc0 < 0) then
                     REG_OTZ <= (others => '0');
                     REG_FLAG(18) <= '1'; REG_FLAG(31) <= '1';
                  elsif (acc0(34 downto 12) > 16#FFFF#) then
                     REG_OTZ <= (others => '1');
                     REG_FLAG(18) <= '1'; REG_FLAG(31) <= '1';
                  else
                     REG_OTZ <= unsigned(acc0(27 downto 12));
                  end if;
               end if;

               -- push sz and start divide
               if (rom_q(SE_SZ) = '1') then
                  m3s := acc(3)(43 downto 12);
                  hv  := unsigned(stg(to_integer(unsigned(rom_q(SE_HSLOT + 1 downto SE_HSLOT))))(15 downto 0));
                  div_trigger <= '1';
                  div_lhs     <= hv;
                  if (m3s < 0) then
                     REG_FLAG(18) <= '1'; REG_FLAG(31) <= '1';
                     REG_SZ3      <= x"0000";
                     div_rhs      <= x"0000";
                  elsif (m3s > 16#FFFF#) then
                     REG_FLAG(18) <= '1'; REG_FLAG(31) <= '1';
                     REG_SZ3      <= x"FFFF";
                     div_rhs      <= x"FFFF";
                  else
                     REG_SZ3      <= unsigned(m3s(15 downto 0));
                     div_rhs      <= unsigned(m3s(15 downto 0));
                  end if;
                  REG_SZ0 <= REG_SZ1; REG_SZ1 <= REG_SZ2; REG_SZ2 <= REG_SZ3;
               end if;

               -- push SXY
               if (rom_q(SE_SXY) = '1') then
                  if (mac0Last(34 downto 16) < -1024) then
                     REG_SX2 <= to_signed(-1024, 16);
                     REG_FLAG(14) <= '1'; REG_FLAG(31) <= '1';
                  elsif (mac0Last(34 downto 16) > 1023) then
                     REG_SX2 <= to_signed(1023, 16);
                     REG_FLAG(14) <= '1'; REG_FLAG(31) <= '1';
                  else
                     REG_SX2 <= mac0Last(31 downto 16);
                  end if;
                  if (acc0(34 downto 16) < -1024) then
                     REG_SY2 <= to_signed(-1024, 16);
                     REG_FLAG(13) <= '1'; REG_FLAG(31) <= '1';
                  elsif (acc0(34 downto 16) > 1023) then
                     REG_SY2 <= to_signed(1023, 16);
                     REG_FLAG(13) <= '1'; REG_FLAG(31) <= '1';
                  else
                     REG_SY2 <= acc0(31 downto 16);
                  end if;
                  REG_SX0 <= REG_SX1; REG_SX1 <= REG_SX2;
                  REG_SY0 <= REG_SY1; REG_SY1 <= REG_SY2;
               end if;

            end if;

            -- MAC registers are written at the execute edge
            for l in 0 to 1 loop
               if (eC(l).v = '1') then
                  if (eC(l).m0 = '1') then
                     REG_MAC0 <= res_c(l)(31 downto 0);
                  else
                     case (eC(l).wb) is
                        when WB_STD | WB_RTP3 | WB_FC => ss := c_sf;
                        when others                   => ss := '0';
                     end case;
                     if (ss = '1') then mval := res_c(l)(43 downto 12); else mval := res_c(l)(31 downto 0); end if;
                     case (eC(l).row) is
                        when 1      => REG_MAC1 <= mval;
                        when 2      => REG_MAC2 <= mval;
                        when others => REG_MAC3 <= mval;
                     end case;
                  end if;
               end if;
            end loop;

            -- lane writebacks
            for l in 0 to 1 loop
               if (wC(l).v = '1') then
                  rq := res_q(l);

                  if (wC(l).m0 = '1') then
                     r35 := rq(34 downto 0);

                     if (wC(l).wb / 2 mod 2 = 1) then
                        if (r35 < MINVAL35) then REG_FLAG(15) <= '1'; REG_FLAG(31) <= '1'; end if;
                        if (r35 > MAXVAL35) then REG_FLAG(16) <= '1'; REG_FLAG(31) <= '1'; end if;
                     end if;

                     if (wC(l).wb mod 2 = 1) then
                        irr := resize(r35(34 downto 12), 32);
                        if (irr < 0) then
                           REG_IR0 <= (others => '0');
                           REG_FLAG(12) <= '1';
                        elsif (irr > 16#1000#) then
                           REG_IR0 <= x"1000";
                           REG_FLAG(12) <= '1';
                        else
                           REG_IR0 <= irr(15 downto 0);
                        end if;
                     end if;

                  else
                     ss := '0'; ui := '0'; irs := '0'; irsf := '0'; sat := '0'; satf := '0';
                     case (wC(l).wb) is
                        when WB_STD   => ss := c_sf; ui := '1'; irs := c_sf; irsf := c_sf; sat := c_lm; satf := c_lm;
                        when WB_RTP3  => ss := c_sf; ui := '1'; irs := c_sf; irsf := '1';  sat := c_lm; satf := '0';
                        when WB_FC    => ss := c_sf; ui := '1'; irs := c_sf; irsf := c_sf; sat := '0';  satf := '0';
                        when WB_MVBUG => ss := '0';  ui := '1'; irs := c_sf; irsf := c_sf; sat := '0';  satf := '0';
                        when others   => null;
                     end case;

                     -- IR value
                     irr := rq(31 downto 0);
                     if (irs = '1') then irr := rq(43 downto 12); end if;
                     irv := irr(15 downto 0);
                     if (sat = '1' and irr < 0) then
                        irv := (others => '0');
                     elsif (sat = '0' and irr < -32768) then
                        irv := x"8000";
                     elsif (irr > 16#7FFF#) then
                        irv := x"7FFF";
                     end if;

                     -- IR flag
                     irr := rq(31 downto 0);
                     if (irsf = '1') then irr := rq(43 downto 12); end if;
                     irfl := false;
                     if (satf = '1' and irr < 0) then
                        irfl := true;
                     elsif (satf = '0' and irr < -32768) then
                        irfl := true;
                     elsif (irr > 16#7FFF#) then
                        irfl := true;
                     end if;

                     case (wC(l).row) is
                        when 1 =>
                           if (ui = '1') then REG_IR1 <= irv; if irfl then REG_FLAG(24) <= '1'; REG_FLAG(31) <= '1'; end if; end if;
                           if (rq < MINVAL45) then REG_FLAG(27) <= '1'; REG_FLAG(31) <= '1'; end if;
                           if (rq > MAXVAL45) then REG_FLAG(30) <= '1'; REG_FLAG(31) <= '1'; end if;
                        when 2 =>
                           if (ui = '1') then REG_IR2 <= irv; if irfl then REG_FLAG(23) <= '1'; REG_FLAG(31) <= '1'; end if; end if;
                           if (rq < MINVAL45) then REG_FLAG(26) <= '1'; REG_FLAG(31) <= '1'; end if;
                           if (rq > MAXVAL45) then REG_FLAG(29) <= '1'; REG_FLAG(31) <= '1'; end if;
                        when others =>
                           if (ui = '1') then REG_IR3 <= irv; if irfl then REG_FLAG(22) <= '1'; end if; end if;
                           if (rq < MINVAL45) then REG_FLAG(25) <= '1'; REG_FLAG(31) <= '1'; end if;
                           if (rq > MAXVAL45) then REG_FLAG(28) <= '1'; REG_FLAG(31) <= '1'; end if;
                     end case;
                  end if;
               end if;
            end loop;

            if (div_Error = '1') then REG_FLAG(17) <= '1'; REG_FLAG(31) <= '1'; end if;

         end if;

      end if;
   end process;

   igte_div : entity work.gte_serial_div
   port map
   (
      clk2x          => clk2x,
      ce             => ce,
      trigger        => div_trigger,
      lhs            => div_lhs,
      rhs            => div_rhs,
      result         => div_result,
      divError       => div_Error
   );

   process (clk1x)
   begin
      if (rising_edge(clk1x)) then
         SS_idle <= '0';
         if (gte_busy = '0' and gte_cmdEna = '0' and gte_readEna = '0' and gte_writeEna_in = '0') then
            SS_idle <= '1';
         end if;
      end if;
   end process;

end architecture;
