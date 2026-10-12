library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library mem;

-- One engine for the four transfer commands: fill (02), CPU to VRAM (A0), VRAM to VRAM (80), VRAM to CPU (C0).
-- Replaces gpu_fillVram, gpu_cpu2vram, gpu_vram2vram and gpu_vram2cpu with the same writes, reads and bus data.
-- Design: docs/pocket/GPU.md.
entity gpu_copy_pocket is
   port
   (
      clk2x                : in  std_logic;
      ce                   : in  std_logic;
      reset                : in  std_logic;
      drawer_reset         : in  std_logic;

      interlacedDrawing    : in  std_logic;
      activeLineLSB        : in  std_logic;
      DrawPixelsMask       : in  std_logic;
      SetMask              : in  std_logic;

      proc_idle            : in  std_logic;
      fifo_Valid           : in  std_logic;
      fifo_data            : in  std_logic_vector(31 downto 0);
      requestFifo          : out std_logic := '0';
      done                 : out std_logic := '0';
      doneWr               : out std_logic := '0';  -- done of a command that writes VRAM

      pipeline_busy        : in  std_logic;
      fifoOut_idle         : in  std_logic;
      pixelEmpty           : in  std_logic;
      pixelStall           : in  std_logic;
      pixelColor           : out std_logic_vector(15 downto 0) := (others => '0');
      pixelAddr            : out unsigned(19 downto 0) := (others => '0');
      pixelWrite           : out std_logic := '0';
      fillWrite            : out std_logic := '0';  -- pixelAddr and pixelColor are a fill of four pixels

      requestVRAMEnable    : out std_logic;
      requestVRAMXPos      : out unsigned(9 downto 0);
      requestVRAMYPos      : out unsigned(8 downto 0);
      requestVRAMSize      : out unsigned(10 downto 0);
      requestVRAMIdle      : in  std_logic;
      requestVRAMDone      : in  std_logic;

      vramLineAddr         : out unsigned(9 downto 0);
      vramLineData         : in  std_logic_vector(15 downto 0);

      Fifo_Dout            : out std_logic_vector(31 downto 0);
      Fifo_Rd              : in  std_logic;
      Fifo_Empty           : out std_logic;
      Fifo_ready           : out std_logic
   );
end entity;

architecture arch of gpu_copy_pocket is

   function to_sl(b : boolean) return std_logic is
   begin
      if b then return '1'; else return '0'; end if;
   end function;

   type tState is
   (
      IDLE,
      REQUESTWORD2,
      REQUESTWORD3,
      REQUESTWORD4,
      REQUESTFIRST,
      READVRAM,
      WAITREAD,
      READFIRST,
      WRITING,
      FINISH,
      WAITLAST1,
      WAITLAST2
   );
   signal state : tState := IDLE;

   type tOp is (OP_FILL, OP_CPU2VRAM, OP_VRAM2VRAM, OP_VRAM2CPU);
   signal op : tOp := OP_FILL;

   -- source and destination of the command, advanced one row at a time
   signal srcX          : unsigned(9 downto 0) := (others => '0');
   signal srcY          : unsigned(8 downto 0) := (others => '0');
   signal dstX          : unsigned(9 downto 0) := (others => '0');
   signal dstY          : unsigned(8 downto 0) := (others => '0');
   signal wm1           : unsigned(9 downto 0) := (others => '0');  -- width - 1 (a fill: rounded up to 16 pixels, then - 1)
   signal hRem          : unsigned(9 downto 0) := (others => '0');  -- rows left, this one included

   -- position inside the row
   signal xSrc          : unsigned(9 downto 0) := (others => '0');
   signal xDst          : unsigned(9 downto 0) := (others => '0');
   signal xCnt          : unsigned(9 downto 0) := (others => '0');

   signal dir           : std_logic := '0';

   -- fill: colour; CPU to VRAM: second halfword of the last word; VRAM to CPU: low halfword of the word being built
   signal half          : std_logic_vector(15 downto 0) := (others => '0');
   signal half_Valid    : std_logic := '0';

   signal Fifo_Din_hi   : std_logic_vector(15 downto 0) := (others => '0');
   signal Fifo_Wr       : std_logic := '0';
   signal Fifo_NearFull : std_logic;
   signal Fifo_Reset    : std_logic := '0';
   signal Fifo_wordhalf : std_logic := '0';
   signal Fifo_Empty_s  : std_logic;

   signal isFill        : std_logic;
   signal back          : std_logic;
   signal sumS, sumD    : unsigned(9 downto 0);
   signal xCntNext      : unsigned(9 downto 0);
   signal xSrcNext      : unsigned(9 downto 0);
   signal xDstNext      : unsigned(9 downto 0);
   signal rowEnd        : std_logic;
   signal lastRow       : std_logic;
   signal sizeOut       : unsigned(10 downto 0);

begin

   isFill <= '1' when (op = OP_FILL) else '0';
   back   <= '1' when (op = OP_VRAM2VRAM and dir = '1') else '0';

   sumS <= srcX + wm1;
   sumD <= dstX + wm1;

   -- fills step four pixels, the others one; a copy that overlaps its source from the right runs backwards
   xCntNext <= xCnt + 4 when (op = OP_FILL) else xCnt + 1;
   xSrcNext <= xSrc - 1 when (back = '1') else xSrc + 1;
   xDstNext <= xDst + 4 when (op = OP_FILL) else xDst - 1 when (back = '1') else xDst + 1;

   rowEnd  <= '1' when (xCnt(9 downto 2) = wm1(9 downto 2) and (isFill = '1' or xCnt(1 downto 0) = wm1(1 downto 0))) else '0';
   lastRow <= '1' when (hRem = 1) else '0';

   -- pixels to read: the width, one more when VRAM to CPU has an odd width (the read is in whole 64 bit words)
   sizeOut <= ('0' & wm1) + 2 when (op = OP_VRAM2CPU and wm1(0) = '0') else ('0' & wm1) + 1;

   requestFifo <= '1' when (state = REQUESTWORD2 or state = REQUESTWORD3 or state = REQUESTWORD4) else
                  '1' when (op = OP_CPU2VRAM and state = WRITING and pixelStall = '0' and fifo_Valid = '0' and
                            (rowEnd = '0' or lastRow = '0' or half_Valid = '0')) else
                  '0';

   requestVRAMEnable <= '1' when (state = READVRAM and requestVRAMIdle = '1' and (op /= OP_VRAM2CPU or Fifo_NearFull = '0')) else '0';
   requestVRAMXPos   <= srcX      when (state = READVRAM and requestVRAMIdle = '1') else (others => '0');
   requestVRAMYPos   <= srcY      when (state = READVRAM and requestVRAMIdle = '1') else (others => '0');
   requestVRAMSize   <= sizeOut   when (state = READVRAM and requestVRAMIdle = '1') else (others => '0');

   vramLineAddr <= xSrc when ((op = OP_VRAM2VRAM and (state = WRITING or state = READFIRST)) or
                              (op = OP_VRAM2CPU  and (state = WRITING or state = WAITREAD))) else (others => '0');

   Fifo_ready <= '1' when (Fifo_Empty_s = '0' or state = IDLE) else '0';
   Fifo_Empty <= Fifo_Empty_s;

   -- two full lines; filling can start whenever at least a full line fits in
   ififo: entity mem.SyncFifoFallThrough
   generic map
   (
      SIZE              => 1024,
      DATAWIDTH         => 32,
      NEARFULLDISTANCE  => 500,
      NEAREMPTYDISTANCE => 16
   )
   port map
   (
      clk         => clk2x,
      reset       => Fifo_Reset,

      Din         => Fifo_Din_hi & half,
      Wr          => Fifo_Wr,
      Full        => open,
      NearFull    => Fifo_NearFull,

      Dout        => Fifo_Dout,
      Rd          => Fifo_Rd,
      Empty       => Fifo_Empty_s,
      NearEmpty   => open
   );

   process (clk2x)
      variable lineEnd : std_logic;
      variable skip    : std_logic;
   begin
      if rising_edge(clk2x) then

         Fifo_Wr    <= '0';
         Fifo_Reset <= '0';

         -- must be done here, so it also is effected when ce is off = paused
         if (state = WAITREAD) then
            if (requestVRAMDone = '1') then
               if (op = OP_VRAM2CPU) then
                  state <= WRITING;
                  xSrc  <= xSrcNext;
               else
                  state <= READFIRST;
               end if;
            end if;
         end if;

         if (reset = '1') then

            state      <= IDLE;
            Fifo_Reset <= '1';

         elsif (ce = '1') then

            pixelColor <= (others => '0');
            pixelAddr  <= (others => '0');
            pixelWrite <= '0';
            fillWrite  <= '0';

            done       <= '0';
            doneWr     <= '0';
            half_Valid <= '0';

            case (state) is

               when IDLE =>
                  Fifo_wordhalf <= '0';
                  if (proc_idle = '1' and fifo_Valid = '1') then
                     if (fifo_data(31 downto 24) = x"02") then
                        state <= REQUESTWORD2;
                        op    <= OP_FILL;
                        half(4 downto  0)  <= fifo_data( 7 downto  3);
                        half(9 downto  5)  <= fifo_data(15 downto 11);
                        half(14 downto 10) <= fifo_data(23 downto 19);
                        half(15)           <= '0';
                     elsif (fifo_data(31 downto 29) = "101") then
                        state <= REQUESTWORD2;
                        op    <= OP_CPU2VRAM;
                     elsif (fifo_data(31 downto 29) = "100") then
                        state <= REQUESTWORD2;
                        op    <= OP_VRAM2VRAM;
                     elsif (fifo_data(31 downto 29) = "110") then
                        state <= REQUESTWORD2;
                        op    <= OP_VRAM2CPU;
                     end if;
                  end if;

               when REQUESTWORD2 =>
                  if (op = OP_VRAM2CPU) then
                     Fifo_Reset <= '1';
                  end if;
                  if (fifo_Valid = '1') then
                     state <= REQUESTWORD3;
                     srcX  <= unsigned(fifo_data( 9 downto  0));
                     srcY  <= unsigned(fifo_data(24 downto 16));
                     dstX  <= unsigned(fifo_data( 9 downto  0));
                     dstY  <= unsigned(fifo_data(24 downto 16));
                     if (op = OP_FILL) then
                        dstX(3 downto 0) <= "0000";
                     end if;
                  end if;

               when REQUESTWORD3 =>
                  if (fifo_Valid = '1') then
                     xCnt <= (others => '0');
                     xDst <= dstX;
                     -- width - 1: a size of 0 is 1024; a fill covers whole blocks of 16 pixels
                     wm1  <= unsigned(fifo_data(9 downto 0)) - 1;
                     if (op = OP_FILL) then
                        wm1(3 downto 0) <= "1111";
                     end if;
                     hRem <= '0' & unsigned(fifo_data(24 downto 16));
                     if (unsigned(fifo_data(24 downto 16)) = 0) then hRem <= to_unsigned(16#200#, 10); end if;
                     case (op) is
                        when OP_VRAM2VRAM =>
                           state <= REQUESTWORD4;
                           dstX  <= unsigned(fifo_data( 9 downto  0));
                           dstY  <= unsigned(fifo_data(24 downto 16));
                        when OP_VRAM2CPU =>
                           state <= REQUESTFIRST;
                        when OP_CPU2VRAM =>
                           state <= WRITING;
                        when OP_FILL =>
                           state <= WRITING;
                           if (unsigned(fifo_data(9 downto 0)) = 0 or unsigned(fifo_data(24 downto 16)) = 0) then
                              state  <= IDLE;
                              done   <= '1';
                              doneWr <= '1';
                           end if;
                     end case;
                  end if;

               when REQUESTWORD4 =>
                  if (fifo_Valid = '1') then
                     state <= REQUESTFIRST;
                     wm1   <= unsigned(fifo_data(9 downto 0)) - 1;
                     hRem  <= '0' & unsigned(fifo_data(24 downto 16));
                     if (unsigned(fifo_data(24 downto 16)) = 0) then hRem <= to_unsigned(16#200#, 10); end if;
                  end if;

               when REQUESTFIRST =>
                  -- copy direction: backwards when the destination overlaps the source from the right
                  dir <= '0';
                  if (srcX < dstX or sumS < sumD) then
                     dir <= '1';
                  end if;
                  if (pipeline_busy = '0' and fifoOut_idle = '1') then
                     state <= READVRAM;
                  end if;

               when READVRAM =>
                  if (back = '1') then
                     xSrc <= sumS;
                     xDst <= sumD;
                  else
                     xSrc <= srcX;
                     xDst <= dstX;
                  end if;
                  if (requestVRAMIdle = '1' and (op /= OP_VRAM2CPU or Fifo_NearFull = '0')) then
                     state <= WAITREAD;
                  end if;

               when WAITREAD => null; -- handled outside due to ce

               when READFIRST =>
                  if (pixelEmpty = '1') then
                     state <= WRITING;
                     xSrc  <= xSrcNext;
                  end if;

               when WRITING =>
                  lineEnd := '0';

                  case (op) is

                     when OP_FILL =>
                        if (pixelStall = '0') then
                           skip := interlacedDrawing and not (activeLineLSB xor dstY(0));
                           if (skip = '0') then
                              fillWrite  <= '1';
                              pixelAddr  <= dstY & xDst & '0';
                              pixelColor <= half;
                              if (rowEnd = '0') then
                                 xDst <= xDstNext;
                                 xCnt <= xCntNext;
                              else
                                 lineEnd := '1';
                              end if;
                           else
                              lineEnd := '1';
                           end if;
                        end if;

                     when OP_CPU2VRAM =>
                        if (fifo_Valid = '1') then
                           half_Valid <= '1';
                           half       <= fifo_data(31 downto 16);
                        end if;
                        if (fifo_Valid = '1' or half_Valid = '1') then
                           pixelWrite <= '1';
                           pixelAddr  <= dstY & xDst & '0';
                           if (fifo_Valid = '1') then
                              pixelColor <= fifo_data(15 downto 0);
                           else
                              pixelColor <= half;
                           end if;
                           if (SetMask = '1') then pixelColor(15) <= '1'; end if;
                           if (rowEnd = '0') then
                              xDst <= xDstNext;
                              xCnt <= xCntNext;
                           else
                              lineEnd := '1';
                           end if;
                        end if;

                     when OP_VRAM2VRAM =>
                        if (DrawPixelsMask = '0' or vramLineData(15) = '0') then
                           pixelWrite <= '1';
                        end if;
                        pixelAddr  <= dstY & xDst & '0';
                        pixelColor <= vramLineData;
                        if (SetMask = '1') then
                           pixelColor(15) <= '1';
                        end if;
                        xSrc <= xSrcNext;
                        xDst <= xDstNext;
                        xCnt <= xCntNext;
                        lineEnd := rowEnd;

                     when OP_VRAM2CPU =>
                        if (Fifo_wordhalf = '0') then
                           half          <= vramLineData;
                           Fifo_wordhalf <= '1';
                        else
                           Fifo_Din_hi   <= vramLineData;
                           Fifo_wordhalf <= '0';
                           Fifo_Wr       <= '1';
                        end if;
                        xSrc <= xSrcNext;
                        xCnt <= xCntNext;
                        lineEnd := rowEnd;

                  end case;

                  if (lineEnd = '1') then
                     xCnt <= (others => '0');
                     srcY <= srcY + 1;
                     dstY <= dstY + 1;
                     hRem <= hRem - 1;
                     if (op = OP_CPU2VRAM or op = OP_FILL) then
                        xDst <= dstX;
                     end if;
                     if (lastRow = '1') then
                        if (op = OP_VRAM2CPU) then
                           state <= FINISH;
                        else
                           state  <= IDLE;
                           done   <= '1';
                           doneWr <= '1';
                        end if;
                     elsif (op = OP_VRAM2VRAM or op = OP_VRAM2CPU) then
                        state <= READVRAM;
                     end if;
                  end if;

               when FINISH =>
                  if (Fifo_wordhalf = '1') then
                     Fifo_Din_hi   <= vramLineData;
                     Fifo_wordhalf <= '0';
                     Fifo_Wr       <= '1';
                  end if;
                  state <= WAITLAST1;

               when WAITLAST1 =>
                  state <= WAITLAST2;

               when WAITLAST2 =>
                  state <= IDLE;
                  done  <= '1';

            end case;

            if (drawer_reset = '1' and (op = OP_CPU2VRAM or op = OP_VRAM2CPU)) then
               state <= IDLE;
               if (state /= IDLE) then
                  done   <= '1';
                  doneWr <= to_sl(op = OP_CPU2VRAM);
               end if;
            end if;

         end if;

      end if;
   end process;

end architecture;
