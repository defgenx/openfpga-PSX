-- Smoke test: gte against gte_serial on random register states for SQR, GPF and NCLIP.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use STD.env.all;

entity tb_smoke is
   generic
   (
      ITER : integer := 300;  -- random states per opcode
      G_L  : integer := 1     -- gte_serial lane timing (G_L = 2 needs other programs)
   );
end entity;

architecture sim of tb_smoke is

   signal clk1x       : std_logic := '0';
   signal clk2x       : std_logic := '0';
   signal clk2xIndex  : std_logic := '0';
   signal ce          : std_logic := '1';
   signal reset       : std_logic := '1';

   signal readAddr    : unsigned(5 downto 0) := (others => '0');
   signal readEna     : std_logic := '0';
   signal writeAddr   : unsigned(5 downto 0) := (others => '0');
   signal writeData   : unsigned(31 downto 0) := (others => '0');
   signal writeEna    : std_logic := '0';
   signal cmdData     : unsigned(31 downto 0) := (others => '0');
   signal cmdEna      : std_logic := '0';

   signal busy_g, busy_s         : std_logic;
   signal rdata_g, rdata_s       : unsigned(31 downto 0);
   signal idle_g, idle_s         : std_logic;
   signal ssd_g, ssd_s           : std_logic_vector(31 downto 0);
   signal dbg_g, dbg_s           : std_logic;

begin

   clk2x <= not clk2x after 5 ns;
   clk1x <= not clk1x after 10 ns;

   process (clk2x)
   begin
      if rising_edge(clk2x) then
         clk2xIndex <= not clk2xIndex;
      end if;
   end process;

   igolden : entity work.gte
   port map
   (
      clk1x => clk1x, clk2x => clk2x, clk2xIndex => clk2xIndex, ce => ce, reset => reset,
      WIDESCREEN => "00", TURBO => '0',
      gte_busy => busy_g,
      gte_readAddr => readAddr, gte_readData => rdata_g, gte_readEna => readEna,
      gte_writeAddr_in => writeAddr, gte_writeData_in => writeData, gte_writeEna_in => writeEna,
      gte_cmdData => cmdData, gte_cmdEna => cmdEna,
      loading_savestate => '0', SS_reset => '0', SS_DataWrite => (others => '0'), SS_Adr => (others => '0'),
      SS_wren => '0', SS_rden => '0', SS_DataRead => ssd_g, SS_idle => idle_g,
      debug_firstGTE => dbg_g
   );

   iserial : entity work.gte_serial
   generic map (G_L => G_L)
   port map
   (
      clk1x => clk1x, clk2x => clk2x, clk2xIndex => clk2xIndex, ce => ce, reset => reset,
      WIDESCREEN => "00", TURBO => '0',
      gte_busy => busy_s,
      gte_readAddr => readAddr, gte_readData => rdata_s, gte_readEna => readEna,
      gte_writeAddr_in => writeAddr, gte_writeData_in => writeData, gte_writeEna_in => writeEna,
      gte_cmdData => cmdData, gte_cmdEna => cmdEna,
      loading_savestate => '0', SS_reset => '0', SS_DataWrite => (others => '0'), SS_Adr => (others => '0'),
      SS_wren => '0', SS_rden => '0', SS_DataRead => ssd_s, SS_idle => idle_s,
      debug_firstGTE => dbg_s
   );

   process
      type t_cnt is array (0 to 3) of integer;
      variable mism     : t_cnt := (others => 0);   -- reset, SQR, GPF, NCLIP register mismatches
      variable busymis  : integer := 0;
      variable printed  : integer := 0;
      variable grp    : integer;
      variable op       : integer;
      variable cg, cs   : integer;
      variable seen     : boolean;
      variable cmd      : unsigned(31 downto 0);
      variable v        : unsigned(31 downto 0);

      variable seed : unsigned(31 downto 0) := x"1234ABCD";

      impure function rnd return unsigned is
      begin
         seed := seed xor (seed sll 13);
         seed := seed xor (seed srl 17);
         seed := seed xor (seed sll 5);
         return seed;
      end function;

      impure function rval return unsigned is
         variable v : unsigned(31 downto 0);
         variable s : unsigned(31 downto 0);
      begin
         v := rnd;
         s := rnd;
         case to_integer(s(1 downto 0)) is
            when 1 => return unsigned(resize(signed(v(7 downto 0)), 32));
            when 2 => return unsigned(resize(signed(v(15 downto 0)), 32));
            when 3 =>
               case to_integer(s(4 downto 2)) is
                  when 0 => return x"00007FFF";
                  when 1 => return x"FFFF8000";
                  when 2 => return x"00008000";
                  when 3 => return x"7FFFFFFF";
                  when 4 => return x"80000000";
                  when 5 => return x"00001000";
                  when 6 => return x"FFFFFFFF";
                  when others => return x"00000000";
               end case;
            when others => return v;
         end case;
      end function;

      procedure tick is
      begin
         wait until rising_edge(clk2x);
         wait for 1 ns;
      end procedure;

      procedure cpu_write(a : integer; d : unsigned(31 downto 0)) is
      begin
         writeAddr <= to_unsigned(a, 6);
         writeData <= d;
         writeEna  <= '1';
         tick; tick;
         writeEna  <= '0';
      end procedure;

      procedure read_all(g : integer) is
      begin
         for a in 0 to 63 loop
            readAddr <= to_unsigned(a, 6);
            readEna  <= '1';
            tick;
            readEna  <= '0';
            if rdata_g /= rdata_s then
               mism(g) := mism(g) + 1;
               if printed < 20 then
                  printed := printed + 1;
                  report "grp " & integer'image(g) & " reg " & integer'image(a) &
                         " golden " & to_hstring(rdata_g) & " serial " & to_hstring(rdata_s) severity warning;
               end if;
            end if;
         end loop;
      end procedure;

   begin
      reset <= '1';
      tick; tick; tick; tick;
      reset <= '0';
      tick; tick;

      -- every register reads 0 after reset
      read_all(0);

      for i in 0 to 3*ITER-1 loop
         grp := 1 + (i mod 3);
         case grp is
            when 1 => op := 16#28#;
            when 2 => op := 16#3D#;
            when others => op := 16#06#;
         end case;

         for a in 0 to 62 loop
            if a /= 15 and a /= 23 + 6 and a /= 28 and a /= 29 and a /= 31 then
               cpu_write(a, rval);
            end if;
         end loop;
         cpu_write(23, rval);

         v   := rnd;
         cmd := (others => '0');
         cmd(5 downto 0)   := to_unsigned(op, 6);
         cmd(19)           := v(0);
         cmd(10)           := v(1);
         cmd(18 downto 13) := v(7 downto 2);

         cmdData <= cmd;
         cmdEna  <= '1';
         cg := 0; cs := 0; seen := false;
         for t in 1 to 300 loop
            tick;
            if t = 2 then cmdEna <= '0'; end if;
            if busy_g /= busy_s then busymis := busymis + 1; end if;
            if busy_g = '1' then seen := true; cg := cg + 1; end if;
            if busy_s = '1' then cs := cs + 1; end if;
            exit when seen and busy_g = '0' and busy_s = '0';
         end loop;
         if cg /= cs or not seen then
            busymis := busymis + 1;
            report "busy cycles golden " & integer'image(cg) & " serial " & integer'image(cs) severity warning;
         end if;

         read_all(grp);
      end loop;

      report "SMOKE: iterations=" & integer'image(3*ITER) &
             " mismatches reset=" & integer'image(mism(0)) &
             " SQR=" & integer'image(mism(1)) &
             " GPF=" & integer'image(mism(2)) &
             " NCLIP=" & integer'image(mism(3)) &
             " busy=" & integer'image(busymis);
      if mism(0) + mism(1) + mism(2) + mism(3) + busymis = 0 then
         report "SMOKE PASS";
         finish;
      else
         report "SMOKE FAIL" severity failure;
      end if;
      wait;
   end process;

end architecture;
