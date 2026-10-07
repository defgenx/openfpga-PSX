-- Narrow radix-2^G restoring divider for gpu_pocket. Design and latency: docs/pocket/GPU.md.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pGPU_pocket.all;

-- Same result as divider.vhd for |divisor| < 2^G_DIVISOR_BITS and |dividend| < 2^qbits
-- (which implies the quotient fits qbits). Divide by zero reproduces the golden bit for bit.
-- Latency: done is high ceil(min(qbits, G_DIVIDEND_BITS) / G_BITS_PER_CYCLE) + 2 clk edges after
-- the edge that samples start.
entity gpu_pocket_div is
   generic
   (
      G_BITS_PER_CYCLE : positive;
      G_DIVISOR_BITS   : positive;
      G_DIVIDEND_BITS  : positive range 2 to 45 := 45  -- dividend magnitude bits kept
   );
   port
   (
      clk : in  std_logic;
      req : in  tdiv_req;
      rsp : out tdiv_rsp
   );
end entity;

architecture arch of gpu_pocket_div is

   constant G  : positive := G_BITS_PER_CYCLE;
   constant GB : positive := G_DIVISOR_BITS;
   constant W  : positive := G_DIVIDEND_BITS;
   constant NG : positive := (W + G - 1) / G;

   type tphase is (IDLE, FETCH, RUN, FIN);
   signal phase : tphase := IDLE;

   signal mag     : unsigned(W - 1 downto 0)  := (others => '0');
   signal divis   : unsigned(GB - 1 downto 0) := (others => '0');
   signal sgn     : std_logic := '0';
   signal d0      : std_logic := '0';
   signal fp      : integer range 0 to NG - 1 := 0;
   signal lastg   : std_logic := '0';
   signal grp     : std_logic_vector(G - 1 downto 0) := (others => '0');
   signal racc    : unsigned(GB - 1 downto 0) := (others => '0');
   signal qacc    : unsigned(W - 1 downto 0)  := (others => '0');

   signal done_r  : std_logic := '0';
   signal busy_r  : std_logic := '0';
   signal quot_r  : signed(44 downto 0) := (others => '0');
   signal lsb_r   : std_logic := '0';

   function pick(m : unsigned(W - 1 downto 0); idx : integer) return std_logic_vector is
      variable r : std_logic_vector(G - 1 downto 0);
   begin
      for i in 0 to G - 1 loop
         if idx * G + i < W then r(i) := m(idx * G + i); else r(i) := '0'; end if;
      end loop;
      return r;
   end function;

begin

   rsp.done     <= done_r;
   rsp.busy     <= busy_r;
   rsp.quotient <= quot_r;
   rsp.qmag_lsb <= lsb_r;

   process (clk) is
      variable dvd_abs : unsigned(44 downto 0);
      variable dvs_abs : unsigned(24 downto 0);
      variable qlim    : integer range 1 to 45;
      variable ngr     : integer range 1 to NG;
      variable rv      : unsigned(GB - 1 downto 0);
      variable t       : unsigned(GB downto 0);
      variable df      : unsigned(GB + 1 downto 0);
      variable qb      : std_logic_vector(G - 1 downto 0);
      variable m       : unsigned(44 downto 0);
      -- synthesis translate_off
      variable a_big   : unsigned(99 downto 0);
      variable b_big   : unsigned(99 downto 0);
      -- synthesis translate_on
   begin
      if rising_edge(clk) then

         done_r <= '0';

         if req.start = '1' then

            if req.dividend(44) = '1' then dvd_abs := unsigned(not std_logic_vector(req.dividend)) + 1;
            else                           dvd_abs := unsigned(req.dividend); end if;
            if req.divisor(24) = '1' then  dvs_abs := unsigned(not std_logic_vector(req.divisor)) + 1;
            else                           dvs_abs := unsigned(req.divisor); end if;

            -- synthesis translate_off
            a_big := resize(dvd_abs, 100);
            b_big := resize(dvs_abs, 100);
            assert dvs_abs < 2 ** GB
               report "gpu_pocket_div: |divisor| = " & to_string(to_integer(dvs_abs)) & " needs more than G_DIVISOR_BITS = " & integer'image(GB)
               severity error;
            assert dvs_abs = 0 or a_big < shift_left(b_big, req.qbits)
               report "gpu_pocket_div: quotient does not fit qbits = " & integer'image(req.qbits)
               severity error;
            assert dvs_abs = 0 or a_big < shift_left(to_unsigned(1, 100), minimum(req.qbits, W))
               report "gpu_pocket_div: |dividend| >= 2^min(qbits, G_DIVIDEND_BITS), qbits = " & integer'image(req.qbits)
               severity error;
            -- synthesis translate_on

            mag   <= dvd_abs(W - 1 downto 0);
            divis <= dvs_abs(GB - 1 downto 0);
            sgn   <= req.dividend(44) xor req.divisor(24);
            if dvs_abs(GB - 1 downto 0) = 0 then d0 <= '1'; else d0 <= '0'; end if;
            if req.qbits < W then qlim := req.qbits; else qlim := W; end if;
            ngr := (qlim + G - 1) / G;
            fp    <= ngr - 1;
            racc  <= (others => '0');
            qacc  <= (others => '0');
            phase <= FETCH;
            busy_r <= '1';

         else
            case phase is

               when FETCH =>
                  grp <= pick(mag, fp);
                  if fp = 0 then lastg <= '1'; else lastg <= '0'; fp <= fp - 1; end if;
                  phase <= RUN;

               when RUN =>
                  rv := racc;
                  for i in G - 1 downto 0 loop
                     t  := rv & grp(i);
                     df := ('0' & t) - resize(divis, GB + 2);
                     if df(GB + 1) = '0' then
                        qb(i) := '1';
                        rv    := df(GB - 1 downto 0);
                     else
                        qb(i) := '0';
                        rv    := t(GB - 1 downto 0);
                     end if;
                  end loop;
                  racc <= rv;
                  qacc <= qacc(W - G - 1 downto 0) & unsigned(qb);

                  if lastg = '1' then
                     phase <= FIN;
                  else
                     grp <= pick(mag, fp);
                     if fp = 0 then lastg <= '1'; else lastg <= '0'; fp <= fp - 1; end if;
                  end if;

               when FIN =>
                  m := (others => '0');
                  m(W - 1 downto 0) := qacc;
                  if d0 = '1' then
                     -- golden with divisor 0: magnitude bits 44..20 are ones, bits 19..0 are
                     -- the complement of dividend magnitude bits 44..25
                     for i in 0 to 44 loop
                        if i >= 20 then
                           m(i) := '1';
                        else
                           if i + 25 < W then m(i) := not mag(i + 25); else m(i) := '1'; end if;
                        end if;
                     end loop;
                  end if;
                  if sgn = '1' then quot_r <= signed((not m) + 1);
                  else              quot_r <= signed(m); end if;
                  lsb_r  <= m(0);
                  done_r <= '1';
                  busy_r <= '0';
                  phase  <= IDLE;

               when others => null;
            end case;
         end if;

      end if;
   end process;

end architecture;
