library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- gpu_rect with the Pocket tie-offs applied and the clip/loop logic restated with limits instead of counters.
-- Same pixels as gpu_rect; design and the one exception (no 2^20-cycle watchdog): docs/pocket/GPU.md.
entity gpu_rect_pocket is
   port
   (
      clk2x                : in  std_logic;
      ce                   : in  std_logic;
      reset                : in  std_logic;

      DrawPixelsMask       : in  std_logic;
      interlacedDrawing    : in  std_logic;
      activeLineLSB        : in  std_logic;
      drawingOffsetX       : in  signed(10 downto 0);
      drawingOffsetY       : in  signed(10 downto 0);
      drawingAreaLeft      : in  unsigned(9 downto 0);
      drawingAreaRight     : in  unsigned(9 downto 0);
      drawingAreaTop       : in  unsigned(8 downto 0);
      drawingAreaBottom    : in  unsigned(8 downto 0);

      fifoOut_idle         : in  std_logic;
      pipeline_busy        : in  std_logic;
      pipeline_stall       : in  std_logic;
      pipeline_new         : out std_logic;
      pipeline_texture     : out std_logic;
      pipeline_transparent : out std_logic;
      pipeline_rawTexture  : out std_logic;
      pipeline_x           : out unsigned(9 downto 0);
      pipeline_y           : out unsigned(8 downto 0);
      pipeline_cr          : out unsigned(7 downto 0);
      pipeline_cg          : out unsigned(7 downto 0);
      pipeline_cb          : out unsigned(7 downto 0);
      pipeline_u           : out unsigned(7 downto 0);
      pipeline_v           : out unsigned(7 downto 0);

      proc_idle            : in  std_logic;
      fifo_Valid           : in  std_logic;
      fifo_data            : in  std_logic_vector(31 downto 0);
      requestFifo          : out std_logic := '0';
      done                 : out std_logic := '0';

      requestVRAMEnable    : out std_logic;
      requestVRAMXPos      : out unsigned(9 downto 0);
      requestVRAMYPos      : out unsigned(8 downto 0);
      requestVRAMSize      : out unsigned(10 downto 0);
      requestVRAMIdle      : in  std_logic;
      requestVRAMDone      : in  std_logic;

      textPalNew           : out std_logic := '0';
      textPalX             : out unsigned(9 downto 0) := (others => '0');
      textPalY             : out unsigned(8 downto 0) := (others => '0');

      vramLineEna          : out std_logic;
      vramLineAddr         : out unsigned(9 downto 0)
   );
end entity;

architecture arch of gpu_rect_pocket is

   type tState is
   (
      IDLE,
      REQUESTPOS,
      REQUESTTEXTURE,
      REQUESTSIZE,
      CHECKPOS,
      REQUESTFIRST,
      REQUESTLINE,
      READWAIT,
      PROCPIXELS
   );
   signal state : tState := IDLE;

   signal rec_texture         : std_logic := '0';
   signal rec_size            : std_logic_vector(1 downto 0) := "00";
   signal rec_transparency    : std_logic := '0';
   signal rec_rawTexture      : std_logic := '0';
   signal rec_color           : std_logic_vector(23 downto 0) := (others => '0');

   -- command position and size; after CHECKPOS posx/yPos hold the first drawn pixel
   signal posx                : signed(10 downto 0) := (others => '0');
   signal yPos                : signed(10 downto 0) := (others => '0');
   signal sizex               : unsigned(9 downto 0) := (others => '0');
   signal sizey               : unsigned(8 downto 0) := (others => '0');

   signal rec_u               : unsigned(7 downto 0) := (others => '0');
   signal uWork               : unsigned(7 downto 0) := (others => '0');
   signal vWork               : unsigned(7 downto 0) := (others => '0');

   -- clipped drawing window: last pixel of a row, last row, pixels per row
   signal xPos                : unsigned(9 downto 0) := (others => '0');
   signal xLim                : unsigned(9 downto 0) := (others => '0');
   signal yLim                : unsigned(8 downto 0) := (others => '0');
   signal rowLen              : unsigned(9 downto 0) := (others => '0');

   signal firstPixel          : std_logic;
   signal emit                : std_logic;

begin

   requestFifo <= '1' when (state = REQUESTPOS or state = REQUESTTEXTURE or state = REQUESTSIZE) else '0';

   requestVRAMEnable <= '1'                       when (state = REQUESTLINE and requestVRAMIdle = '1' and pipeline_stall = '0') else '0';
   requestVRAMXPos   <= xPos                      when (state = REQUESTLINE and requestVRAMIdle = '1' and pipeline_stall = '0') else (others => '0');
   requestVRAMYPos   <= unsigned(yPos(8 downto 0)) when (state = REQUESTLINE and requestVRAMIdle = '1' and pipeline_stall = '0') else (others => '0');
   requestVRAMSize   <= '0' & rowLen              when (state = REQUESTLINE and requestVRAMIdle = '1' and pipeline_stall = '0') else (others => '0');

   -- the pixel of this cycle, all zero when none: the pixel pipeline latches it
   emit <= '1' when (state = PROCPIXELS and pipeline_stall = '0' and (firstPixel = '0' or pipeline_busy = '0')) else '0';
   pipeline_new         <= emit;
   pipeline_texture     <= emit and rec_texture;
   pipeline_transparent <= emit and rec_transparency;
   pipeline_rawTexture  <= emit and rec_rawTexture;
   pipeline_x           <= xPos when emit = '1' else (others => '0');
   pipeline_y           <= unsigned(yPos(8 downto 0)) when emit = '1' else (others => '0');
   pipeline_cr          <= unsigned(rec_color( 7 downto  0)) when emit = '1' else (others => '0');
   pipeline_cg          <= unsigned(rec_color(15 downto  8)) when emit = '1' else (others => '0');
   pipeline_cb          <= unsigned(rec_color(23 downto 16)) when emit = '1' else (others => '0');
   pipeline_u           <= uWork when emit = '1' else (others => '0');
   pipeline_v           <= vWork when emit = '1' else (others => '0');

   vramLineEna  <= '1' when (state = PROCPIXELS) else '0';
   vramLineAddr <= xPos when (state = PROCPIXELS) else (others => '0');

   process (clk2x)
      variable xrec12 : signed(11 downto 0);
      variable yrec12 : signed(11 downto 0);
      variable xl, xr, xlast, xlim12, xlimC : signed(11 downto 0);
      variable yt, yb, ylast, ylim12, ylimC : signed(11 downto 0);
      variable x0, y0, y0p : signed(10 downto 0);
      variable par         : signed(10 downto 0);
      variable yAdd        : integer range 1 to 2;
      variable ynext       : signed(10 downto 0);
      variable noDraw      : boolean;
   begin
      if rising_edge(clk2x) then

         -- must be done here, so it also is effected when ce is off = paused
         if (state = READWAIT) then
            if (requestVRAMDone = '1') then
               state <= PROCPIXELS;
            end if;
         end if;

         if (reset = '1') then

            state <= IDLE;

         elsif (ce = '1') then

            done                 <= '0';

            textPalNew           <= '0';
            textPalX             <= (others => '0');
            textPalY             <= (others => '0');

            case (state) is

               when IDLE =>
                  firstPixel   <= '1';
                  if (proc_idle = '1' and fifo_Valid = '1' and fifo_data(31 downto 29) = "011") then
                     state             <= REQUESTPOS;
                     rec_texture       <= fifo_data(26);
                     rec_size          <= fifo_data(28 downto 27);
                     rec_transparency  <= fifo_data(25);
                     rec_rawTexture    <= fifo_data(24);
                     rec_color         <= fifo_data(23 downto 0);
                  end if;

               when REQUESTPOS =>
                  case (rec_size) is
                     when "01" =>
                        sizex <= to_unsigned(1, 10);
                        sizey <= to_unsigned(1, 9);

                     when "10" =>
                        sizex <= to_unsigned(8, 10);
                        sizey <= to_unsigned(8, 9);

                     when "11" =>
                        sizex <= to_unsigned(16, 10);
                        sizey <= to_unsigned(16, 9);

                     when others => null;
                  end case;

                  if (fifo_Valid = '1') then
                     xrec12     := resize(drawingOffsetX, 12) + signed('0' & fifo_data(10 downto  0));
                     yrec12     := resize(drawingOffsetY, 12) + signed('0' & fifo_data(26 downto 16));
                     posx       <= xrec12(10 downto 0);
                     yPos       <= yrec12(10 downto 0);

                     if (rec_texture = '1') then
                        state    <= REQUESTTEXTURE;
                     elsif (rec_size = "00") then
                        state    <= REQUESTSIZE;
                     else
                        state    <= CHECKPOS;
                     end if;
                  end if;

               when REQUESTTEXTURE =>
                  if (fifo_Valid = '1') then
                     uWork         <= unsigned(fifo_data( 7 downto  0));
                     vWork         <= unsigned(fifo_data(15 downto  8));
                     rec_u         <= unsigned(fifo_data( 7 downto  0));
                     textPalX      <= unsigned(fifo_data(21 downto 16)) & "0000";
                     textPalY      <= unsigned(fifo_data(30 downto 22));
                     textPalNew    <= '1';
                     if (rec_size = "00") then
                        state    <= REQUESTSIZE;
                     else
                        state    <= CHECKPOS;
                     end if;
                  end if;

               when REQUESTSIZE =>
                  if (fifo_Valid = '1') then
                     sizex       <= unsigned(fifo_data(9 downto  0));
                     sizey       <= unsigned(fifo_data(24 downto 16));
                     state       <= CHECKPOS;
                  end if;

               when CHECKPOS =>
                  -- first pixel and last pixel of the clipped rectangle; nothing is drawn when the first is past the last
                  xl     := signed("00" & drawingAreaLeft);
                  xr     := signed("00" & drawingAreaRight);
                  xlast  := resize(posx, 12) + signed("00" & sizex) - 1;
                  if (resize(posx, 12) < xl) then x0 := xl(10 downto 0); else x0 := posx; end if;
                  if (xlast > xr) then xlim12 := xr; else xlim12 := xlast; end if;

                  yt     := signed("000" & drawingAreaTop);
                  yb     := signed("000" & drawingAreaBottom);
                  ylast  := resize(yPos, 12) + signed("000" & sizey) - 1;
                  if (resize(yPos, 12) < yt) then y0 := yt(10 downto 0); else y0 := yPos; end if;
                  par    := (others => '0');
                  if (interlacedDrawing = '1' and activeLineLSB = y0(0)) then par(0) := '1'; end if;
                  y0p    := y0 + par;
                  if (ylast > yb) then ylim12 := yb; else ylim12 := ylast; end if;

                  noDraw := resize(x0, 12) > xlim12 or resize(y0p, 12) > ylim12 or
                            drawingAreaLeft > drawingAreaRight or drawingAreaTop > drawingAreaBottom;

                  xlimC  := xlim12 - resize(x0, 12) + 1;

                  posx   <= x0;
                  xPos   <= unsigned(x0(9 downto 0));
                  xLim   <= unsigned(xlim12(9 downto 0));
                  rowLen <= unsigned(xlimC(9 downto 0));
                  yPos   <= y0p;
                  yLim   <= unsigned(ylim12(8 downto 0));
                  uWork  <= rec_u + (unsigned(x0(7 downto 0)) - unsigned(posx(7 downto 0)));
                  rec_u  <= rec_u + (unsigned(x0(7 downto 0)) - unsigned(posx(7 downto 0)));
                  vWork  <= vWork + (unsigned(y0p(7 downto 0)) - unsigned(yPos(7 downto 0)));

                  if (noDraw) then
                     state <= IDLE;
                     done  <= '1';
                  elsif (rec_transparency = '1' or DrawPixelsMask = '1') then
                     state <= REQUESTFIRST;
                  else
                     state <= PROCPIXELS;
                  end if;

               when REQUESTFIRST =>
                  if (pipeline_busy = '0' and fifoOut_idle = '1') then
                     state <= REQUESTLINE;
                  end if;

               when REQUESTLINE =>
                  if (pipeline_stall = '0' and requestVRAMIdle = '1') then
                     state  <= READWAIT;
                  end if;

               when READWAIT => null; -- handled outside due to ce

               when PROCPIXELS =>
                  if (pipeline_stall = '0' and (firstPixel = '0' or pipeline_busy = '0')) then
                     firstPixel <= '0';

                     if (xPos /= xLim) then
                        xPos  <= xPos + 1;
                        uWork <= uWork + 1;
                     else
                        yAdd := 1;
                        if (interlacedDrawing = '1') then
                           yAdd := 2;
                        end if;
                        ynext := yPos + yAdd;
                        yPos  <= ynext;
                        vWork <= vWork + yAdd;
                        if (resize(ynext, 12) > signed("000" & yLim)) then
                           state <= IDLE;
                           done  <= '1';
                        else
                           xPos  <= unsigned(posx(9 downto 0));
                           uWork <= rec_u;
                           if (rec_transparency = '1' or DrawPixelsMask = '1') then
                              state <= REQUESTLINE;
                           end if;
                        end if;
                     end if;
                  end if;

            end case;

         end if;

      end if;
   end process;

end architecture;
