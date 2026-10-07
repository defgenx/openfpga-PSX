-- Synthetic GTE lane slice for timing sizing: operand mux -> 18x19 multiplier
-- -> shift/accumulate -> overflow flags and IR saturation, plus the divider
-- last stage. Inputs are serial-loaded; all outputs are XOR-folded to 2 pins.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity gte_slice is
   generic
   (
      G_L        : integer range 1 to 3 := 2; -- 1: mul+acc same cycle, 2: product reg, 3: input reg + product reg
      G_DIV_REG  : integer range 0 to 2 := 0; -- 1: register after the divider multiply, 2: also after shift/round
      G_ACC_PRE  : integer range 0 to 1 := 0  -- 1: X select/negate and control decode registered before the accumulate
   );
   port
   (
      clk      : in  std_logic; -- lane clock
      clkdiv   : in  std_logic; -- divider clock
      sin      : in  std_logic; -- serial data in
      sen      : in  std_logic; -- shift enable, data chains
      cen      : in  std_logic; -- shift enable, control chain
      cstb     : in  std_logic; -- latch control chain
      dout     : out std_logic; -- folded lane results
      dout_div : out std_logic  -- folded divider result
   );
end entity;

architecture arch of gte_slice is

   attribute preserve : boolean;
   attribute ramstyle : string;

   type ctl_t is record
      selA, selB, selS : std_logic_vector(3 downto 0);
      k                : std_logic_vector(1 downto 0);
      useShift         : std_logic;
      addsel           : std_logic_vector(1 downto 0);
      sub, swap        : std_logic;
      row              : std_logic_vector(1 downto 0);
      irShift          : std_logic;
      irShiftFlag      : std_logic;
      satIR            : std_logic;
      satIRFlag        : std_logic;
      trig             : std_logic;
      raddr, waddr     : std_logic_vector(5 downto 0);
      we               : std_logic;
   end record;

   function unpack(v : std_logic_vector(38 downto 0)) return ctl_t is
      variable c : ctl_t;
   begin
      c.selA        := v(3 downto 0);
      c.selB        := v(7 downto 4);
      c.selS        := v(11 downto 8);
      c.k           := v(13 downto 12);
      c.useShift    := v(14);
      c.addsel      := v(16 downto 15);
      c.sub         := v(17);
      c.swap        := v(18);
      c.row         := v(20 downto 19);
      c.irShift     := v(21);
      c.irShiftFlag := v(22);
      c.satIR       := v(23);
      c.satIRFlag   := v(24);
      c.trig        := v(25);
      c.raddr       := v(31 downto 26);
      c.waddr       := v(37 downto 32);
      c.we          := v(38);
      return c;
   end function;

   -- parity of each group of n consecutive bits
   function fold(v : std_logic_vector; n : positive) return std_logic_vector is
      constant groups : natural := (v'length + n - 1) / n;
      variable r : std_logic_vector(groups - 1 downto 0) := (others => '0');
   begin
      for i in 0 to v'length - 1 loop
         r(i / n) := r(i / n) xor v(v'low + i);
      end loop;
      return r;
   end function;

   function parity(v : std_logic_vector) return std_logic is
      variable r : std_logic := '0';
   begin
      for i in v'range loop
         r := r xor v(i);
      end loop;
      return r;
   end function;

   constant MINVAL : signed(44 downto 0) := '1' & x"80000000000";
   constant MAXVAL : signed(44 downto 0) := '0' & x"7FFFFFFFFFF";

   -- input registers
   signal sin_r, sen_r, cen_r, cstb_r : std_logic := '0';

   -- operand sources
   type src_t  is array (0 to 15) of std_logic_vector(31 downto 0);
   type bank_t is array (0 to 13) of std_logic_vector(31 downto 0);
   signal bank   : bank_t := (others => (others => '0'));
   signal srcs   : src_t;
   signal cchain : std_logic_vector(38 downto 0) := (others => '0');

   -- RAM
   type ram_t is array (0 to 63) of std_logic_vector(31 downto 0);
   signal ram      : ram_t;
   attribute ramstyle of ram : signal is "M10K, no_rw_check";
   signal raddr_r  : unsigned(5 downto 0) := (others => '0');
   signal ram_q    : std_logic_vector(31 downto 0);

   -- control pipeline
   signal c0, c1, c2, ac, ci : ctl_t := unpack((others => '0'));

   -- datapath
   signal a0, a1     : signed(17 downto 0) := (others => '0');
   signal b0, b1     : signed(18 downto 0) := (others => '0');
   signal s0, s1, sval : signed(31 downto 0) := (others => '0');
   signal prod       : signed(36 downto 0);
   signal xsel       : signed(44 downto 0);
   type acc_t is array (0 to 2) of signed(44 downto 0);
   signal acc, macLast : acc_t := (others => (others => '0'));
   signal res_r      : signed(44 downto 0) := (others => '0');

   -- flags and IR
   signal unf, ovf, ir_flag : std_logic := '0';
   signal ir_val           : std_logic_vector(15 downto 0) := (others => '0');
   signal unf_c, ovf_c, irf_c : std_logic;
   signal ir_c             : std_logic_vector(15 downto 0);

   -- output folding, lane
   signal allv   : std_logic_vector(3 * 45 * 2 + 2 + 17 - 1 downto 0);
   signal foldA  : std_logic_vector(((3 * 45 * 2 + 2 + 17) + 5) / 6 - 1 downto 0) := (others => '0');
   signal foldB  : std_logic_vector((foldA'length + 5) / 6 - 1 downto 0) := (others => '0');
   attribute preserve of foldA, foldB : signal is true;

   -- divider
   signal sin_d, sen_d : std_logic := '0';
   signal dch      : std_logic_vector(39 downto 0) := (others => '0');
   signal d_pr     : unsigned(35 downto 0) := (others => '0');
   signal d_p      : unsigned(35 downto 0);
   signal d_r32    : unsigned(31 downto 0) := (others => '0');
   signal d_res    : std_logic_vector(16 downto 0) := (others => '0');
   signal dfoldA   : std_logic_vector(3 downto 0) := (others => '0');
   attribute preserve of dfoldA : signal is true;

begin

   ---------------------------------------------------------------- inputs, banks, control
   process (clk)
   begin
      if rising_edge(clk) then
         sin_r  <= sin;
         sen_r  <= sen;
         cen_r  <= cen;
         cstb_r <= cstb;

         if (sen_r = '1') then
            bank(0) <= bank(0)(30 downto 0) & sin_r;
            for i in 1 to 13 loop
               bank(i) <= bank(i)(30 downto 0) & bank(i - 1)(31);
            end loop;
         end if;

         if (cen_r = '1') then
            cchain <= cchain(37 downto 0) & sin_r;
         end if;
         if (cstb_r = '1') then
            c0 <= unpack(cchain);
         end if;

         c1 <= c0;
         c2 <= c1;
      end if;
   end process;

   ac <= c0 when G_L = 1 else c1 when G_L = 2 else c2;

   ---------------------------------------------------------------- RAM, 64x32
   process (clk)
   begin
      if rising_edge(clk) then
         if (c0.we = '1') then
            ram(to_integer(unsigned(c0.waddr))) <= bank(0);
         end if;
         raddr_r <= unsigned(c0.raddr);
      end if;
   end process;
   ram_q <= ram(to_integer(raddr_r));

   ---------------------------------------------------------------- operand mux
   gsrc : for i in 0 to 13 generate
      srcs(i) <= bank(i);
   end generate;
   srcs(14) <= ram_q;
   srcs(15) <= std_logic_vector(res_r(31 downto 0));

   process (all)
      variable ia, ib, isl : integer range 0 to 15;
   begin
      ia  := to_integer(unsigned(c0.selA));
      ib  := to_integer(unsigned(c0.selB));
      isl := to_integer(unsigned(c0.selS));
      if (ia mod 2 = 0) then
         a0 <= resize(signed(srcs(ia)(15 downto 0)), 18);
      else
         a0 <= signed(srcs(ia)(31 downto 14));
      end if;
      if (ib mod 2 = 0) then
         b0 <= resize(signed(srcs(ib)(15 downto 0)), 19);
      else
         b0 <= signed(srcs(ib)(31 downto 13));
      end if;
      s0 <= signed(srcs(isl));
   end process;

   ---------------------------------------------------------------- multiplier pipeline
   gl1 : if G_L = 1 generate
      prod <= resize(a0 * b0, 37);
      sval <= s0;
   end generate;

   gl2 : if G_L = 2 generate
      process (clk)
      begin
         if rising_edge(clk) then
            prod <= resize(a0 * b0, 37);
            sval <= s0;
         end if;
      end process;
   end generate;

   gl3 : if G_L = 3 generate
      process (clk)
      begin
         if rising_edge(clk) then
            a1   <= a0;
            b1   <= b0;
            s1   <= s0;
            prod <= resize(a1 * b1, 37);
            sval <= s1;
         end if;
      end process;
   end generate;

   ---------------------------------------------------------------- shift, accumulate
   -- X select and shift, shared by both accumulate forms
   process (all)
      variable sh : signed(44 downto 0);
   begin
      case ac.k is
         when "00"   => sh := shift_left(resize(sval, 45), 0);
         when "01"   => sh := shift_left(resize(sval, 45), 4);
         when "10"   => sh := shift_left(resize(sval, 45), 12);
         when others => sh := shift_left(resize(sval, 45), 16);
      end case;
      if (ac.useShift = '1') then
         xsel <= sh;
      else
         xsel <= resize(prod, 45);
      end if;
   end process;

   -- Single stage: addend select, add/sub and accumulate in one cycle.
   gacc0 : if G_ACC_PRE = 0 generate
      process (clk)
         variable ri      : integer range 0 to 2;
         variable a, r    : signed(44 downto 0);
      begin
         if rising_edge(clk) then
            ri := to_integer(unsigned(ac.row));
            if (ac.row = "11") then ri := 2; end if;

            case ac.addsel is
               when "00"   => a := (others => '0');
               when "01"   => a := resize(acc(ri)(43 downto 0), 45);
               when others => a := macLast(ri);
            end case;

            if (ac.sub = '0') then
               r := a + xsel;
            elsif (ac.swap = '0') then
               r := a - xsel;
            else
               r := xsel - a;
            end if;

            if (ac.trig = '1') then
               acc(ri)     <= r;
               macLast(ri) <= acc(ri);
               res_r       <= r;
            end if;
            ci <= ac;
         end if;
      end process;
   end generate;

   -- Two stages: X select/negate and control decode are registered first,
   -- so the accumulate loop is AND-OR of the addend, XOR, and one adder.
   gacc1 : if G_ACC_PRE = 1 generate
      signal xr                  : signed(44 downto 0) := (others => '0');
      signal ap                  : ctl_t := unpack((others => '0'));
      signal mAcc, mLast, negA, cin : std_logic := '0';
   begin
      process (clk)
         variable ri      : integer range 0 to 2;
         variable a, r    : signed(44 downto 0);
         variable cinv    : unsigned(0 downto 0);
      begin
         if rising_edge(clk) then
            if (ac.sub = '1' and ac.swap = '0') then
               xr <= not xsel;
            else
               xr <= xsel;
            end if;
            ap    <= ac;
            mAcc  <= (not ac.addsel(1)) and ac.addsel(0);
            mLast <= ac.addsel(1);
            negA  <= ac.sub and ac.swap;
            cin   <= ac.sub;

            ri := to_integer(unsigned(ap.row));
            if (ap.row = "11") then ri := 2; end if;

            a := (others => '0');
            if (mAcc = '1') then a := resize(acc(ri)(43 downto 0), 45); end if;
            if (mLast = '1') then a := macLast(ri); end if;
            if (negA = '1') then a := not a; end if;
            cinv(0) := cin;
            r := a + xr + signed(resize(cinv, 45));

            if (ap.trig = '1') then
               acc(ri)     <= r;
               macLast(ri) <= acc(ri);
               res_r       <= r;
            end if;
            ci <= ap;
         end if;
      end process;
   end generate;

   ---------------------------------------------------------------- overflow flags, IR saturation
   -- Source is res_r with its matching control.
      process (res_r, ci)
         variable irr : signed(31 downto 0);
         variable irf : signed(31 downto 0);
         variable v   : std_logic_vector(15 downto 0);
         variable f   : std_logic;
      begin
         unf_c <= '0';
         ovf_c <= '0';
         if (res_r < MINVAL) then unf_c <= '1'; end if;
         if (res_r > MAXVAL) then ovf_c <= '1'; end if;

         irr := res_r(31 downto 0);
         if (ci.irShift = '1') then irr := res_r(43 downto 12); end if;
         v := std_logic_vector(irr(15 downto 0));
         if (ci.satIR = '1' and irr < 0) then
            v := (others => '0');
         elsif (ci.satIR = '0' and irr < -32768) then
            v := x"8000";
         elsif (irr > 16#7FFF#) then
            v := x"7FFF";
         end if;
         ir_c <= v;

         irf := res_r(31 downto 0);
         if (ci.irShiftFlag = '1') then irf := res_r(43 downto 12); end if;
         f := '0';
         if (ci.satIRFlag = '1' and irf < 0) then
            f := '1';
         elsif (ci.satIRFlag = '0' and irf < -32768) then
            f := '1';
         elsif (irf > 16#7FFF#) then
            f := '1';
         end if;
         irf_c <= f;
      end process;

   process (clk)
   begin
      if rising_edge(clk) then
         unf     <= unf_c;
         ovf     <= ovf_c;
         ir_val  <= ir_c;
         ir_flag <= irf_c;
      end if;
   end process;

   ---------------------------------------------------------------- output folding, lane
   gv : for i in 0 to 2 generate
      allv(45 * i + 44 downto 45 * i)             <= std_logic_vector(acc(i));
      allv(135 + 45 * i + 44 downto 135 + 45 * i) <= std_logic_vector(macLast(i));
   end generate;
   allv(271 downto 270) <= unf & ovf;
   allv(288 downto 272) <= ir_flag & ir_val;

   process (clk)
   begin
      if rising_edge(clk) then
         foldA <= fold(allv, 6);
         foldB <= fold(foldA, 6);
         dout  <= parity(foldB);
      end if;
   end process;

   ---------------------------------------------------------------- divider last stage
   -- lhs = dch(15..0), r = dch(35..16), s = dch(39..36)
   d_p <= unsigned(dch(15 downto 0)) * unsigned(dch(35 downto 16));

   process (clkdiv)
      variable pv  : unsigned(35 downto 0);
      variable sh  : unsigned(51 downto 0);
      variable t   : unsigned(51 downto 0);
      variable r32 : unsigned(31 downto 0);
   begin
      if rising_edge(clkdiv) then
         sin_d <= sin;
         sen_d <= sen;
         if (sen_d = '1') then
            dch <= dch(38 downto 0) & sin_d;
         end if;

         d_pr <= d_p;
         if (G_DIV_REG >= 1) then
            pv := d_pr;
         else
            pv := d_p;
         end if;

         sh  := shift_left(resize(pv, 52), to_integer(unsigned(dch(39 downto 36))));
         t   := sh + 16#8000#;
         d_r32 <= t(47 downto 16);
         if (G_DIV_REG = 2) then
            r32 := d_r32;
         else
            r32 := t(47 downto 16);
         end if;
         if (r32 > 16#1FFFF#) then
            d_res <= (others => '1');
         else
            d_res <= std_logic_vector(r32(16 downto 0));
         end if;

         dfoldA <= fold(d_res, 5);
         dout_div <= parity(dfoldA);
      end if;
   end process;

end architecture;
