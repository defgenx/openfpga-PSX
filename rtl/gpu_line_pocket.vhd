library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library mem;
use work.pGPU_pocket.all;

-- gpu_line with the six concurrent divides issued to two shared dividers. Design: docs/pocket/GPU.md.
entity gpu_line_pocket is
   port
   (
      clk2x                : in  std_logic;
      clk2xIndex           : in  std_logic;
      ce                   : in  std_logic;
      reset                : in  std_logic;

      REPRODUCIBLEGPUTIMING: in  std_logic; -- ignored, tied off in gpu_pocket

      error                : out std_logic;

      DrawPixelsMask       : in  std_logic;
      interlacedDrawing    : in  std_logic;
      activeLineLSB        : in  std_logic;
      drawingOffsetX       : in  signed(10 downto 0);
      drawingOffsetY       : in  signed(10 downto 0);
      drawingAreaLeft      : in  unsigned(9 downto 0);
      drawingAreaRight     : in  unsigned(9 downto 0);
      drawingAreaTop       : in  unsigned(8 downto 0);
      drawingAreaBottom    : in  unsigned(8 downto 0);

      divE_req             : out tdiv_req := DIV_REQ_IDLE;
      divE_rsp             : in  tdiv_rsp;
      divG_req             : out tdiv_req := DIV_REQ_IDLE;
      divG_rsp             : in  tdiv_rsp;
      slot0_upd            : out std_logic := '0';
      slot0_val            : out std_logic := '0';

      fifoOut_idle         : in  std_logic;
      pipeline_busy        : in  std_logic;
      pipeline_stall       : in  std_logic;
      pipeline_new         : out std_logic;
      pipeline_transparent : out std_logic;
      pipeline_x           : out unsigned(9 downto 0);
      pipeline_y           : out unsigned(8 downto 0);
      pipeline_cr          : out unsigned(7 downto 0);
      pipeline_cg          : out unsigned(7 downto 0);
      pipeline_cb          : out unsigned(7 downto 0);

      proc_idle            : in  std_logic;
      fifo_Valid           : in  std_logic;
      fifo_data            : in  std_logic_vector(31 downto 0);
      requestFifo          : out std_logic := '0';
      done                 : out std_logic := '0';
      CmdDone              : out std_logic := '0';

      requestVRAMEnable    : out std_logic;
      requestVRAMXPos      : out unsigned(9 downto 0);
      requestVRAMYPos      : out unsigned(8 downto 0);
      requestVRAMSize      : out unsigned(10 downto 0);
      requestVRAMIdle      : in  std_logic;
      requestVRAMDone      : in  std_logic;

      vramLineEna          : out std_logic;
      vramLineAddr         : out unsigned(9 downto 0)
   );
end entity;

architecture arch of gpu_line_pocket is

   -- receive
   type trecState is
   (
      REQUESTIDLE,
      REQUESTPOS1,
      REQUESTCOLOR2,
      REQUESTPOS2,
      REQUESTWAITDONE
   );
   signal recstate : trecState := REQUESTIDLE;

   signal rec_polyline        : std_logic := '0';
   signal rec_shading         : std_logic := '0';
   signal rec_transparency    : std_logic := '0';

   signal rec_color1          : std_logic_vector(23 downto 0) := (others => '0');
   signal rec_color2          : std_logic_vector(23 downto 0) := (others => '0');

   signal rec_pos1x           : signed(11 downto 0) := (others => '0');
   signal rec_pos1y           : signed(11 downto 0) := (others => '0');
   signal rec_pos2x           : signed(11 downto 0) := (others => '0');
   signal rec_pos2y           : signed(11 downto 0) := (others => '0');

   signal swap12              : std_logic := '0';
   signal checkEnd            : std_logic := '0';

   -- fifo
   signal fifoLine_Din        : std_logic_vector(97 downto 0);
   signal fifoLine_Wr         : std_logic := '0';
   signal fifoLine_Full       : std_logic;
   signal fifoLine_Dout       : std_logic_vector(97 downto 0);
   signal fifoLine_Rd         : std_logic;
   signal fifoLine_Empty      : std_logic;
   signal fifoLine_Valid      : std_logic;

   -- base line handling
   type tprocState is
   (
      PROCIDLE,
      PROCRECEIVE,
      PROCCALC1,
      PROCCALC2,
      PROCCALC3,
      PROCREQUESTFIRST,
      PROCREADLINE,
      PROCREADWAIT,
      PROCPIXELS
   );
   signal procstate : tprocState := PROCIDLE;

   signal proc_shading        : std_logic := '0';
   signal proc_transparency   : std_logic := '0';

   signal proc_color1         : std_logic_vector(23 downto 0) := (others => '0');
   signal proc_color2         : std_logic_vector(23 downto 0) := (others => '0');

   signal proc_pos1x          : signed(11 downto 0) := (others => '0');
   signal proc_pos1y          : signed(11 downto 0) := (others => '0');
   signal proc_pos2x          : signed(11 downto 0) := (others => '0');
   signal proc_pos2y          : signed(11 downto 0) := (others => '0');

   signal points              : unsigned(9 downto 0) := (others => '0');
   signal singlePixelLines    : std_logic := '0';

   signal stepDx              : signed(43 downto 0) := (others => '0');
   signal stepDy              : signed(43 downto 0) := (others => '0');
   signal stepDyNeg           : std_logic := '0';
   signal stepDr              : signed(19 downto 0) := (others => '0');
   signal stepDg              : signed(19 downto 0) := (others => '0');
   signal stepDb              : signed(19 downto 0) := (others => '0');

   -- divide schedule: edge divider dx, dy, red; gradient divider pixels per row, green, blue
   signal edgeStep            : integer range 0 to 3 := 3;
   signal gradStep            : integer range 0 to 3 := 3;
   signal dxIssue             : std_logic := '0';
   signal slot0Wait           : std_logic := '0';

   signal workx               : signed(44 downto 0) := (others => '0');
   signal worky               : signed(44 downto 0) := (others => '0');
   signal workr               : signed(20 downto 0) := (others => '0');
   signal workg               : signed(20 downto 0) := (others => '0');
   signal workb               : signed(20 downto 0) := (others => '0');

   signal yPerLine            : unsigned(10 downto 0) := (others => '0');

   signal firstPixel          : std_logic;
   signal emit                : std_logic;
   signal drawx               : signed(10 downto 0);
   signal drawy               : signed(10 downto 0);

   -- 20-bit LFSR timeout: 2^20-1 steps from x"00001" reach x"00001" again, so saturation is a flag
   signal timeout             : unsigned(19 downto 0) := x"00001";
   signal timeoutSat          : std_logic := '0';

   -- (c2 - c1) * 2^12, the golden's colour dividend (the difference needs 9 bits)
   function colorDividend(c2, c1 : std_logic_vector(7 downto 0)) return signed is
   begin
      return resize(signed('0' & c2) - signed('0' & c1), 33) & x"000";
   end function;

   -- d * 2^32 + (d < 0 ? -pm1 : pm1), the golden's dx/dy dividend with pm1 = points - 1
   function edgeDividend(d : signed(11 downto 0); pm1 : unsigned(9 downto 0)) return signed is
      variable hi  : signed(12 downto 0);
      variable lo  : unsigned(9 downto 0);
      variable ext : std_logic_vector(21 downto 0);
   begin
      hi  := resize(d, 13);
      lo  := pm1;
      ext := (others => '0');
      if (d(11) = '1') then
         lo := (not pm1) + 1;
         if (pm1 /= 0) then
            hi  := hi - 1;
            ext := (others => '1');
         end if;
      end if;
      return hi & signed(ext) & signed(lo);
   end function;

begin

   requestFifo <= '1' when (recstate = REQUESTPOS1 or recstate = REQUESTCOLOR2 or recstate = REQUESTPOS2) else '0';

   requestVRAMEnable <= '1'                           when (procstate = PROCREADLINE and requestVRAMIdle = '1' and pipeline_stall = '0') else '0';
   requestVRAMXPos   <= unsigned(workx(41 downto 32)) when (procstate = PROCREADLINE and requestVRAMIdle = '1' and pipeline_stall = '0') else (others => '0');
   requestVRAMYPos   <= unsigned(worky(40 downto 32)) when (procstate = PROCREADLINE and requestVRAMIdle = '1' and pipeline_stall = '0') else (others => '0');
   requestVRAMSize   <= yPerLine                      when (procstate = PROCREADLINE and requestVRAMIdle = '1' and pipeline_stall = '0') else (others => '0');

   -- the pixel of this cycle, all zero when none: the pixel pipeline latches it
   drawx <= signed(workx(42 downto 32));
   drawy <= signed(worky(42 downto 32));
   emit  <= '1' when (procstate = PROCPIXELS and pipeline_stall = '0' and (firstPixel = '0' or pipeline_busy = '0') and
                      (interlacedDrawing = '0' or activeLineLSB /= drawy(0)) and
                      drawx >= to_integer(drawingAreaLeft) and drawx <= to_integer(drawingAreaRight) and
                      drawy >= to_integer(drawingAreaTop) and drawy <= to_integer(drawingAreaBottom)) else '0';
   pipeline_new         <= emit;
   pipeline_transparent <= emit and proc_transparency;
   pipeline_x           <= unsigned(drawx(9 downto 0)) when emit = '1' else (others => '0');
   pipeline_y           <= unsigned(drawy(8 downto 0)) when emit = '1' else (others => '0');
   pipeline_cr          <= (others => '0') when emit = '0' else
                           unsigned(proc_color1( 7 downto  0)) when proc_shading = '0' else unsigned(workr(19 downto 12));
   pipeline_cg          <= (others => '0') when emit = '0' else
                           unsigned(proc_color1(15 downto  8)) when proc_shading = '0' else unsigned(workg(19 downto 12));
   pipeline_cb          <= (others => '0') when emit = '0' else
                           unsigned(proc_color1(23 downto 16)) when proc_shading = '0' else unsigned(workb(19 downto 12));

   vramLineEna  <= '1' when (procstate = PROCPIXELS) else '0';
   vramLineAddr <= unsigned(workx(41 downto 32)) when (procstate = PROCPIXELS) else (others => '0');

   -- receive details
   process (clk2x)
      variable posX : signed(11 downto 0);
      variable posY : signed(11 downto 0);
   begin
      if rising_edge(clk2x) then

         posX := resize(signed(fifo_data(10 downto  0)),12) + resize(drawingOffsetX, 12);
         posY := resize(signed(fifo_data(26 downto 16)),12) + resize(drawingOffsetY, 12);

         if (reset = '1') then

            recstate <= REQUESTIDLE;
            checkEnd <= '0';

         elsif (ce = '1') then

            done         <= '0';
            CmdDone      <= '0';
            fifoLine_Wr  <= '0';
            swap12       <= '0';

            if (swap12 = '1') then
               rec_pos1x  <= rec_pos2x;
               rec_pos1y  <= rec_pos2y;
               if (rec_shading = '1') then
                  rec_color1 <= rec_color2;
               end if;
            end if;

            error <= '0';
            if (recstate = REQUESTIDLE) then
               timeout    <= x"00001";
               timeoutSat <= '0';
            elsif (timeoutSat = '0') then
               timeout    <= timeout(18 downto 0) & (timeout(19) xor timeout(16));
               if (timeout = x"80000") then timeoutSat <= '1'; end if;
            else
               error    <= '1';
               recstate <= REQUESTIDLE;
               done     <= '1';
            end if;

            if (fifoLine_Full = '1') then
               error <= '1';
            end if;

            case (recstate) is

               when REQUESTIDLE =>
                  if (proc_idle = '1' and fifo_Valid = '1' and fifo_data(31 downto 29) = "010") then
                     recstate          <= REQUESTPOS1;
                     rec_polyline      <= fifo_data(27);
                     rec_shading       <= fifo_data(28);
                     rec_transparency  <= fifo_data(25);
                     rec_color1        <= fifo_data(23 downto 0);
                     checkEnd          <= '0';
                  end if;

               when REQUESTPOS1 =>
                  if (fifo_Valid = '1') then
                     rec_pos1x   <= posX;
                     rec_pos1y   <= posY;
                     if (rec_shading = '0') then
                        recstate    <= REQUESTPOS2;
                     else
                        recstate    <= REQUESTCOLOR2;
                     end if;
                  end if;

               when REQUESTCOLOR2 =>
                  if (fifo_Valid = '1') then
                     rec_color2     <= fifo_data(23 downto 0);
                     recstate       <= REQUESTPOS2;
                     if (checkEnd = '1' and rec_shading = '1' and fifo_data(31 downto 28) = x"5" and fifo_data(15 downto 12) = x"5") then
                        recstate  <= REQUESTWAITDONE;
                        CmdDone   <= '1';
                     end if;
                  end if;

               when REQUESTPOS2 =>
                  if (fifo_Valid = '1') then
                     rec_pos2x   <= posX;
                     rec_pos2y   <= posY;
                     swap12      <= '1';
                     if (rec_polyline = '1') then
                        checkEnd    <= '1';
                        if (checkEnd = '1' and rec_shading = '0' and fifo_data(31 downto 28) = x"5" and fifo_data(15 downto 12) = x"5") then
                           recstate  <= REQUESTWAITDONE;
                           CmdDone   <= '1';
                        else
                           fifoLine_Wr  <= '1';
                           if (rec_shading = '0') then
                              recstate    <= REQUESTPOS2;
                           else
                              recstate    <= REQUESTCOLOR2;
                           end if;
                        end if;
                     else
                        fifoLine_Wr <= '1';
                        recstate    <= REQUESTWAITDONE;
                        CmdDone     <= '1';
                     end if;
                  end if;

               when REQUESTWAITDONE =>
                  if (procstate = PROCIDLE and fifoLine_Empty = '1' and fifoLine_Wr = '0') then
                     recstate    <= REQUESTIDLE;
                     done        <= '1';
                  end if;

            end case;

         end if;

      end if;
   end process;

   -- fifowidth          1                 1            24                          12                           12              24                          12                            12
   fifoLine_Din <= rec_shading & rec_transparency & rec_color2 & std_logic_vector(rec_pos2y) & std_logic_vector(rec_pos2x) & rec_color1 & std_logic_vector(rec_pos1y) & std_logic_vector(rec_pos1x);

   iFifoLines: entity mem.SyncFifo
   generic map
   (
      SIZE             => 64,
      DATAWIDTH        => 98,  -- 2 bit status + 2 * (2bit color + 2 * 12bit position)
      NEARFULLDISTANCE => 60
   )
   port map
   (
      clk      => clk2x,
      reset    => reset,
      Din      => fifoLine_Din,
      Wr       => fifoLine_Wr,
      Full     => fifoLine_Full,
      NearFull => open,
      Dout     => fifoLine_Dout,
      Rd       => fifoLine_Rd,
      Empty    => fifoLine_Empty
   );

   fifoLine_Rd <= '1' when (fifoLine_Empty = '0' and procstate = PROCIDLE) else '0';

   -- bit 0 of the dx quotient magnitude feeds the polygon unit's stale-bit register (docs/pocket/GPU.md)
   -- the golden dx divide always runs to completion, so this is not gated by reset or ce
   process (clk2x)
   begin
      if rising_edge(clk2x) then
         slot0_upd <= '0';
         if (slot0Wait = '1' and divE_rsp.done = '1') then
            slot0_upd <= '1';
            slot0_val <= divE_rsp.qmag_lsb;
            slot0Wait <= '0';
         end if;
         if (dxIssue = '1') then
            slot0Wait <= '1';
         end if;
      end if;
   end process;

   -- process lines
   process (clk2x)
      variable dx    : signed(11 downto 0);
      variable dy    : signed(11 downto 0);
      variable nexty : signed(44 downto 0);
      variable edgeDvd : signed(44 downto 0);
      variable edgeLast   : boolean;
      variable gradLast   : boolean;
   begin
      if rising_edge(clk2x) then

         dxIssue <= '0';

         -- must be done here, so it also is effected when ce is off = paused
         if (procstate = PROCREADWAIT) then
            if (requestVRAMDone = '1') then
               procstate <= PROCPIXELS;
            end if;
         end if;

         if (reset = '1') then

            procstate <= PROCIDLE;

         elsif (ce = '1') then

            divE_req             <= DIV_REQ_IDLE;
            divG_req             <= DIV_REQ_IDLE;

            -- dx dividend in PROCCALC2, dy dividend in PROCCALC3, as the golden computes them
            dx := proc_pos2x - proc_pos1x;
            dy := proc_pos2y - proc_pos1y;
            if (procstate = PROCCALC2) then edgeDvd := edgeDividend(dx, points - 1);
            else                            edgeDvd := edgeDividend(dy, points - 1); end if;

            case (procstate) is

               when PROCIDLE =>
                  firstPixel   <= '1';
                  if (fifoLine_Empty = '0') then
                     procstate <= PROCRECEIVE;
                  end if;

               when PROCRECEIVE =>
                  procstate            <= PROCCALC1;
                  proc_pos1x           <= signed(fifoLine_Dout(11 downto  0));
                  proc_pos1y           <= signed(fifoLine_Dout(23 downto 12));
                  proc_color1          <= fifoLine_Dout(47 downto 24);
                  proc_pos2x           <= signed(fifoLine_Dout(59 downto 48));
                  proc_pos2y           <= signed(fifoLine_Dout(71 downto 60));
                  proc_color2          <= fifoLine_Dout(95 downto 72);
                  proc_transparency    <= fifoLine_Dout(96);
                  proc_shading          <= fifoLine_Dout(97);

               when PROCCALC1 =>
                  procstate   <= PROCCALC2;
                  workx       <= resize(proc_pos1x & x"80000000", 45) - 1024;
                  worky       <= resize(proc_pos1y & x"80000000", 45);
                  workr       <= '0' & signed(proc_color1( 7 downto  0)) & x"800";
                  workg       <= '0' & signed(proc_color1(15 downto  8)) & x"800";
                  workb       <= '0' & signed(proc_color1(23 downto 16)) & x"800";
                  dx          := abs(dx);
                  dy          := abs(dy);
                  if (dx > dy) then
                     points            <= unsigned(dx(9 downto 0));
                     singlePixelLines  <= '0';
                  else
                     if (dy(9 downto 0) = 0) then
                        if (proc_transparency = '1' or DrawPixelsMask = '1') then
                           procstate <= PROCREQUESTFIRST;
                        else
                           procstate <= PROCPIXELS;
                        end if;
                     end if;
                     points            <= unsigned(dy(9 downto 0));
                     singlePixelLines  <= '1';
                     yPerLine          <= to_unsigned(1, 11);
                  end if;

                  if (dx >= 16#400# or dy >= 16#200#)                                                            then procstate <= PROCIDLE; end if;
                  if (proc_pos1x < to_integer(drawingAreaLeft)   and proc_pos2x < to_integer(drawingAreaLeft))   then procstate <= PROCIDLE; end if;
                  if (proc_pos1x > to_integer(drawingAreaRight)  and proc_pos2x > to_integer(drawingAreaRight))  then procstate <= PROCIDLE; end if;
                  if (proc_pos1y < to_integer(drawingAreaTop)    and proc_pos2y < to_integer(drawingAreaTop))    then procstate <= PROCIDLE; end if;
                  if (proc_pos1y > to_integer(drawingAreaBottom) and proc_pos2y > to_integer(drawingAreaBottom)) then procstate <= PROCIDLE; end if;

                  if (proc_pos1x >= proc_pos2x) then
                     proc_pos1x  <= proc_pos2x;
                     proc_pos1y  <= proc_pos2y;
                     proc_pos2x  <= proc_pos1x;
                     proc_pos2y  <= proc_pos1y;
                     if (proc_shading = '1') then
                        proc_color1 <= proc_color2;
                        proc_color2 <= proc_color1;
                     end if;
                  end if;

               when PROCCALC2 =>
                  procstate   <= PROCCALC3;
                  edgeStep    <= 0;
                  gradStep    <= 0;
                  dxIssue     <= '1';

                  -- dx on the edge divider (quotient up to 2^43 for the wrapped dx = -2048, points = 1)
                  divE_req    <= ('1', edgeDvd, "000" & x"000" & signed(points), 44);

                  -- pixels per row on the gradient divider, for transparency readback
                  if (dy = 0) then divG_req <= ('1', "000" & x"00000000" & signed(points), to_signed(1, 25), 10);
                  else             divG_req <= ('1', "000" & x"00000000" & signed(points), "0" & x"000" & (abs(dy)), 10); end if;

               when PROCCALC3 =>
                  -- each divide's final quotient is latched when its done is seen
                  edgeLast := (edgeStep = 3);
                  gradLast := (gradStep = 3);

                  if (edgeStep < 3 and divE_rsp.done = '1') then
                     case (edgeStep) is
                        when 0 =>
                           stepDx    <= divE_rsp.quotient(43 downto 0);
                           divE_req  <= ('1', edgeDvd, "000" & x"000" & signed(points), 44);
                        when 1 =>
                           stepDy    <= divE_rsp.quotient(43 downto 0);
                           stepDyNeg <= divE_rsp.quotient(44);
                           divE_req  <= ('1', colorDividend(proc_color2(7 downto 0), proc_color1(7 downto 0)), "000" & x"000" & signed(points), 20);
                        when others =>
                           stepDr    <= divE_rsp.quotient(19 downto 0);
                           edgeLast  := true;
                     end case;
                     edgeStep <= edgeStep + 1;
                  end if;

                  if (gradStep < 3 and divG_rsp.done = '1') then
                     case (gradStep) is
                        when 0 =>
                           if (singlePixelLines = '0') then
                              yPerLine <= resize(unsigned(divG_rsp.quotient(9 downto 0)),11) + 1;
                           end if;
                           divG_req  <= ('1', colorDividend(proc_color2(15 downto 8), proc_color1(15 downto 8)), "000" & x"000" & signed(points), 20);
                        when 1 =>
                           stepDg    <= divG_rsp.quotient(19 downto 0);
                           divG_req  <= ('1', colorDividend(proc_color2(23 downto 16), proc_color1(23 downto 16)), "000" & x"000" & signed(points), 20);
                        when others =>
                           stepDb    <= divG_rsp.quotient(19 downto 0);
                           gradLast  := true;
                     end case;
                     gradStep <= gradStep + 1;
                  end if;

                  if (edgeLast and gradLast) then
                     workx <= resize(proc_pos1x & x"80000000", 45) - 1024;
                     if (stepDyNeg = '1') then
                        worky <= resize(proc_pos1y & x"80000000", 45) - 1024;
                     else
                        worky <= resize(proc_pos1y & x"80000000", 45);
                     end if;
                     workr <= '0' & signed(proc_color1( 7 downto  0)) & x"800";
                     workg <= '0' & signed(proc_color1(15 downto  8)) & x"800";
                     workb <= '0' & signed(proc_color1(23 downto 16)) & x"800";
                     if (proc_transparency = '1' or DrawPixelsMask = '1') then
                        procstate <= PROCREQUESTFIRST;
                     else
                        procstate <= PROCPIXELS;
                     end if;
                  end if;

               when PROCREQUESTFIRST =>
                  if (pipeline_busy = '0' and fifoOut_idle = '1') then
                     procstate <= PROCREADLINE;
                  end if;

               when PROCREADLINE =>
                  if (pipeline_stall = '0' and requestVRAMIdle = '1') then
                     procstate         <= PROCREADWAIT;
                  end if;

               when PROCREADWAIT => null; -- handled outside due to ce
                  if (requestVRAMDone = '1') then
                     procstate <= PROCPIXELS;
                  end if;

               when PROCPIXELS =>
                  if (pipeline_stall = '0' and (firstPixel = '0' or pipeline_busy = '0')) then
                     firstPixel <= '0';

                     points <= points - 1;

                     nexty := worky + stepDy;
                     if (points = 0) then
                        procstate <= PROCIDLE;
                     elsif ((proc_transparency = '1' or DrawPixelsMask = '1') and nexty(40 downto 32) /= worky(40 downto 32)) then
                        procstate <= PROCREADLINE;
                     end if;

                     workx <= workx + stepDx;
                     worky <= nexty;
                     workr <= workr + stepDr;
                     workg <= workg + stepDg;
                     workb <= workb + stepDb;
                  end if;

            end case;

         end if;

      end if;
   end process;


end architecture;
