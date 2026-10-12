library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library mem;
use work.pGPU.all;

-- gpu_videoout with syncVideoOut = '1' and every overlay, crosshair, 480p and rotate option tied off:
-- gpu_videoout_sync and the line fetch of gpu_videoout in one entity, same outputs on every clock.
-- Design: docs/pocket/GPU.md.
entity gpu_videoout_pocket is
   port
   (
      clk1x                      : in  std_logic;
      clk2x                      : in  std_logic;
      clkvid                     : in  std_logic;
      ce                         : in  std_logic;
      reset                      : in  std_logic;
      softReset                  : in  std_logic;

      videoout_settings          : in  tvideoout_settings;
      videoout_reports           : out tvideoout_reports;

      videoout_on                : in  std_logic;

      requestVRAMEnable          : out std_logic := '0';
      requestVRAMXPos            : out unsigned(9 downto 0);
      requestVRAMYPos            : out unsigned(8 downto 0);
      requestVRAMSize            : out unsigned(10 downto 0);
      requestVRAMIdle            : in  std_logic;
      requestVRAMDone            : in  std_logic;

      vram_DOUT                  : in  std_logic_vector(63 downto 0);
      vram_DOUT_READY            : in  std_logic;

      videoout_out               : out tvideoout_out;

      videoout_ss_out            : out tvideoout_ss
   );
end entity;

architecture arch of gpu_videoout_pocket is

   signal rep                       : tvideoout_reports;
   signal vo                        : tvideoout_out;

   signal videoout_request          : tvideoout_request := ('0', (others => '0'), (others => '0'), 0, (others => '0'));
   signal videoout_readAddr         : unsigned(10 downto 0) := (others => '0');
   signal videoout_pixelRead        : std_logic_vector(15 downto 0);

   -- timing
   signal lineIn           : unsigned(8 downto 0) := (others => '0');
   signal nextHCount       : integer range 0 to 4095;
   signal vpos             : integer range 0 to 511;
   signal vsyncCount       : integer range 0 to 15;  -- saturates: only the first 12 lines of vsync are decoded

   signal htotal           : integer range 2169 to 2173; -- 3406 to 3413 in GPU clock domain
   signal vtotal           : integer range 263 to 314;
   signal vDisplayStart    : integer range 0 to 314;
   signal vDisplayEnd      : integer range 0 to 314;

   -- output
   signal pixelData_R      : std_logic_vector(7 downto 0) := (others => '0');
   signal pixelData_G      : std_logic_vector(7 downto 0) := (others => '0');
   signal pixelData_B      : std_logic_vector(7 downto 0) := (others => '0');

   signal clkDiv           : integer range 5 to 12 := 5;
   signal clkCnt           : integer range 0 to 12 := 0;
   signal xmax             : integer range 0 to 1023;

   signal hsync_start      : integer range 0 to 4095;
   signal hsync_end        : integer range 0 to 4095;

   type tReadState is
   (
      IDLE,
      READ16,
      READ24_0,
      READ24_8,
      READ24_16,
      READ24_24
   );
   signal readstate     : tReadState := IDLE;
   signal readstate24   : tReadState := READ24_0;

   -- line fetch
   signal DisplayOffsetY            : unsigned( 8 downto 0) := (others => '0');
   signal vDisplayStartRaw          : unsigned( 9 downto 0);

   type tState is
   (
      WAITNEWLINE,
      WAITREQUEST,
      REQUEST,
      WAITREAD
   );
   signal state : tState := WAITNEWLINE;

   signal waitcnt             : integer range 0 to 3;

   signal reqPosX             : unsigned(9 downto 0) := (others => '0');
   signal reqPosY             : unsigned(8 downto 0) := (others => '0');
   signal reqSize             : unsigned(10 downto 0) := (others => '0');
   signal lineAct             : unsigned(8 downto 0) := (others => '0');
   signal fillAddr            : unsigned(8 downto 0) := (others => '0');
   signal store               : std_logic := '0';

begin

   videoout_reports <= rep;
   videoout_out     <= vo;

   videoout_ss_out.interlacedDisplayField <= rep.interlacedDisplayField;
   videoout_ss_out.nextHCount             <= std_logic_vector(to_unsigned(nextHCount, 12));
   videoout_ss_out.vpos                   <= std_logic_vector(to_unsigned(vpos, 9));
   videoout_ss_out.vdisp                  <= std_logic_vector(to_unsigned(vpos, 9));
   videoout_ss_out.inVsync                <= rep.inVsync;
   videoout_ss_out.activeLineLSB          <= rep.activeLineLSB;
   videoout_ss_out.GPUSTAT_InterlaceField <= rep.GPUSTAT_InterlaceField;
   videoout_ss_out.GPUSTAT_DrawingOddline <= rep.GPUSTAT_DrawingOddline;

   videoout_request.fetchsize <= vo.DisplayWidth(9 downto 0);

   --##############################################################
   --############################### timing, clk1x
   --##############################################################

   process (clk1x)
      variable mode480i                  : std_logic;
      variable isVsync                   : std_logic;
      variable vposNew                   : integer range 0 to 511;
      variable rel                       : integer range -314 to 511; -- vposNew - vDisplayStart
      variable relNext                   : integer range -314 to 512; -- the same for the next line
      variable toEnd                     : integer range -511 to 314; -- vDisplayEnd - vposNew
      variable interlacedDisplayFieldNew : std_logic;
      variable lineLSB                   : std_logic;
   begin
      if rising_edge(clk1x) then

         if (nextHCount <   3) then rep.hblank_tmr <= '1'; else rep.hblank_tmr <= '0'; end if;

         rep.vsync    <= '0';
         rep.dotclock <= '0';
         if (videoout_settings.GPUSTAT_VerRes = '1') then
            if (vsyncCount >= 5 and vsyncCount < 8) then rep.vsync <= '1'; end if;
         else
            if (vsyncCount >= 10 and vsyncCount < 13) then rep.vsync <= '1'; end if;
         end if;

         if (reset = '1') then

            rep.irq_VBLANK              <= '0';

            rep.interlacedDisplayField  <= '0';
            nextHCount                  <= 0;
            vpos                        <= 0;
            rep.inVsync                 <= '0';
            rep.activeLineLSB           <= '0';
            rep.GPUSTAT_InterlaceField  <= '0';
            rep.GPUSTAT_DrawingOddline  <= '0';

         elsif (ce = '1') then

            rep.irq_VBLANK <= '0';

            --gpu timing calc
            if (videoout_settings.GPUSTAT_PalVideoMode = '1' and videoout_settings.pal60 = '0') then
               vtotal <= 314;
               vo.isPal <= '1';
            else
               vtotal <= 263;
               vo.isPal <= '0';
            end if;

            if (videoout_settings.GPUSTAT_HorRes2 = '1') then
               htotal  <= 2169; -- 368
            else
               case (videoout_settings.GPUSTAT_HorRes1) is
                  when "00" => htotal <= 2172; -- 256;
                  when "01" => htotal <= 2170; -- 320;
                  when "10" => htotal <= 2169;  -- 512;
                  when "11" => htotal <= 2170;  -- 640;
                  when others => null;
               end case;
            end if;

            if (videoout_settings.vDisplayRange( 9 downto  0) < 314) then vDisplayStart <= to_integer(videoout_settings.vDisplayRange( 9 downto  0)); else vDisplayStart <= 314; end if;
            if (videoout_settings.vDisplayRange(19 downto 10) < 314) then vDisplayEnd   <= to_integer(videoout_settings.vDisplayRange(19 downto 10)); else vDisplayEnd   <= 314; end if;

            -- gpu timing count
            if (nextHCount > 1) then
               nextHCount <= nextHCount - 1;
            else

               nextHCount <= htotal;

               vposNew := vpos + 1;
               if (vposNew >= vtotal) then
                  vposNew := 0;
                  if (videoout_settings.GPUSTAT_VertInterlace = '1') then
                     rep.GPUSTAT_InterlaceField <= not rep.GPUSTAT_InterlaceField;
                  else
                     rep.GPUSTAT_InterlaceField <= '0';
                  end if;
               end if;

               vpos <= vposNew;

               mode480i := videoout_settings.GPUSTAT_VerRes and videoout_settings.GPUSTAT_VertInterlace;

               -- line index inside the display window: of this line (rel) and of the next (relNext)
               rel     := vposNew - vDisplayStart;
               relNext := rel + 1;
               toEnd   := vDisplayEnd - vposNew;

               isVsync := '0';
               if (rel < 0 or toEnd <= 0) then
                  isVsync := '1';
               end if;
               if (isVsync = '1') then
                  if (vsyncCount < 15) then vsyncCount <= vsyncCount + 1; end if;
               else
                  vsyncCount <= 0;
                  if (videoout_settings.GPUSTAT_VerRes = '1') then
                     lineIn <= to_unsigned(rel * 2, 9) or ("00000000" & rep.interlacedDisplayField);
                  else
                     lineIn <= to_unsigned(rel, 9);
                  end if;
               end if;

               interlacedDisplayFieldNew := rep.interlacedDisplayField;
               if (isVsync /= rep.inVsync) then
                  if (isVsync = '1') then
                     videoout_request.fetch <= '0';
                     rep.irq_VBLANK         <= '1';
                     if (mode480i = '1') then
                        interlacedDisplayFieldNew := not rep.GPUSTAT_InterlaceField;
                     else
                        interlacedDisplayFieldNew := '0';
                     end if;
                  end if;
                  rep.inVsync <= isVsync;
               end if;
               rep.interlacedDisplayField <= interlacedDisplayFieldNew;

               rep.GPUSTAT_DrawingOddline <= '0';
               rep.activeLineLSB          <= '0';
               if (mode480i = '1') then
                  if (videoout_settings.vramRange(10) = '0' and interlacedDisplayFieldNew = '1') then rep.activeLineLSB <= '1'; end if;
                  if (videoout_settings.vramRange(10) = '1' and interlacedDisplayFieldNew = '0') then rep.activeLineLSB <= '1'; end if;

                  if (videoout_settings.vramRange(10) = '0' and isVsync = '0' and interlacedDisplayFieldNew = '1') then rep.GPUSTAT_DrawingOddline <= '1'; end if;
                  if (videoout_settings.vramRange(10) = '1' and isVsync = '0' and interlacedDisplayFieldNew = '0') then rep.GPUSTAT_DrawingOddline <= '1'; end if;
               else
                  if (videoout_settings.vramRange(10) = '0' and (vposNew mod 2) = 1) then rep.GPUSTAT_DrawingOddline <= '1'; end if;
                  if (videoout_settings.vramRange(10) = '1' and (vposNew mod 2) = 0) then rep.GPUSTAT_DrawingOddline <= '1'; end if;
               end if;

               -- request of the next line (the old activeLineLSB selects the field)
               lineLSB := rep.activeLineLSB;
               if (vDisplayStart = 0 and vposNew + 1 = vtotal) then
                  if (videoout_settings.GPUSTAT_VerRes = '1' and rep.interlacedDisplayField = '1') then
                     videoout_request.lineInNext <= to_unsigned(1, 9);
                  else
                     videoout_request.lineInNext <= to_unsigned(0, 9);
                  end if;
                  videoout_request.fetch <= '1';
               elsif (relNext >= 0 and toEnd > 1) then
                  if (videoout_settings.GPUSTAT_VerRes = '1') then
                     videoout_request.lineInNext <= to_unsigned(relNext * 2, 9) or ("00000000" & lineLSB);
                  else
                     videoout_request.lineInNext <= to_unsigned(relNext, 9);
                  end if;
                  videoout_request.fetch <= '1';
               end if;

            end if;

            if (softReset = '1') then
               rep.GPUSTAT_InterlaceField <= '1';
               rep.GPUSTAT_DrawingOddline <= '0';
               rep.irq_VBLANK             <= '0';

               vpos                       <= 0;
               nextHCount                 <= htotal;
               rep.inVsync                <= '0';
            end if;

         end if;
      end if;
   end process;

   --##############################################################
   --############################### pixel clock, clk2x
   --##############################################################

   vo.vsync          <= rep.vsync;
   vo.vblank         <= rep.inVsync;
   vo.interlace      <= videoout_settings.GPUSTAT_VerRes and rep.interlacedDisplayField;

   vo.DisplayOffsetX <= videoout_settings.vramRange(9 downto 0);
   vo.DisplayOffsetY <= videoout_settings.vramRange(18 downto 10);

   vo.DisplayWidthReal  <= vo.DisplayWidth;
   vo.DisplayHeightReal <= vo.DisplayHeight;

   process (clk2x)
   begin
      if rising_edge(clk2x) then

         vo.ce <= '0';

         if (videoout_settings.GPUSTAT_HorRes2 = '1') then
            clkDiv  <= 9; vo.hResMode <= "010"; -- 368
         else
            case (videoout_settings.GPUSTAT_HorRes1) is
               when "00" => clkDiv <= 12; vo.hResMode <= "100"; -- 256;
               when "01" => clkDiv <= 10; vo.hResMode <= "011"; -- 320;
               when "10" => clkDiv <= 6;  vo.hResMode <= "001"; -- 512;
               when "11" => clkDiv <= 5;  vo.hResMode <= "000"; -- 640;
               when others => null;
            end case;
         end if;

         if (videoout_settings.GPUSTAT_HorRes2 = '1') then
            vo.DisplayWidth  <= to_unsigned(368, 11);
         else
            case (videoout_settings.GPUSTAT_HorRes1) is
               when "00" => vo.DisplayWidth <= to_unsigned(256, 11);
               when "01" => vo.DisplayWidth <= to_unsigned(320, 11);
               when "10" => vo.DisplayWidth <= to_unsigned(512, 11);
               when "11" => vo.DisplayWidth <= to_unsigned(640, 11);
               when others => null;
            end case;
         end if;

         if (videoout_settings.GPUSTAT_VerRes = '1') then
            vo.DisplayHeight  <= to_unsigned(480, 10);
         else
            vo.DisplayHeight  <= to_unsigned(240, 10);
         end if;

         if (reset = '1') then

            clkCnt                     <= 0;
            vo.hblank                  <= '1';
            videoout_request.lineDisp  <= (others => '0');
            readstate                  <= IDLE;

         elsif (ce = '1') then

            if (clkCnt < (clkDiv - 1)) then
               clkCnt <= clkCnt + 1;
            else
               clkCnt    <= 0;
               vo.ce  <= '1';
               if (videoout_request.xpos < 1023) then
                  videoout_request.xpos <= videoout_request.xpos + 1;
               end if;
               if (videoout_request.xpos > 0 and videoout_request.xpos <= xmax) then
                  vo.hblank <= '0';
                  if (videoout_settings.GPUSTAT_DisplayDisable = '1') then
                     vo.r      <= (others => '0');
                     vo.g      <= (others => '0');
                     vo.b      <= (others => '0');
                  else
                     vo.r      <= pixelData_R;
                     vo.g      <= pixelData_G;
                     vo.b      <= pixelData_B;
                  end if;
               else
                  vo.hblank <= '1';
                  if (vo.hblank = '0') then
                     hsync_start <= (nextHCount / 2) + (16 * clkDiv);
                     hsync_end   <= (nextHCount / 2);
                  end if;
               end if;
            end if;

            if (lineIn /= videoout_request.lineDisp) then
               videoout_request.lineDisp <= lineIn;
               -- must add lower 2 bits of display offset here as fetching from ddr3 vram is done in 64bits = 4 pixel steps
               -- so if image is shifted in steps below 4, it must be fetched with offset from linebuffer.
               videoout_readAddr         <= lineIn(0) & x"00" & vo.DisplayOffsetX(1 downto 0);
               if (videoout_settings.GPUSTAT_VerRes = '1') then -- interlaced mode
                  videoout_readAddr(10) <= lineIn(1);
               end if;
               videoout_request.xpos <= 0;
               xmax                  <= to_integer(vo.DisplayWidth);
            end if;

            if (nextHCount = hsync_start) then vo.hsync <= '1'; end if;
            if (nextHCount = hsync_end  ) then vo.hsync <= '0'; end if;

            case (readstate) is

               when IDLE =>
                  if (clkCnt >= (clkDiv - 1) and videoout_request.xpos < xmax) then
                     if (videoout_settings.GPUSTAT_ColorDepth24 = '1') then
                        videoout_readAddr  <= videoout_readAddr + 1;
                        if (videoout_request.xpos = 0 or readstate24 = READ24_0) then
                           readstate <= READ24_0;
                        else
                           readstate <= READ24_8;
                        end if;
                     else
                        readstate <= READ16;
                     end if;
                  end if;

               when READ16 =>
                  readstate                  <= IDLE;
                  videoout_readAddr  <= videoout_readAddr + 1;
                  pixelData_R                <= videoout_pixelRead( 4 downto  0) & videoout_pixelRead( 4 downto 2);
                  pixelData_G                <= videoout_pixelRead( 9 downto  5) & videoout_pixelRead( 9 downto 7);
                  pixelData_B                <= videoout_pixelRead(14 downto 10) & videoout_pixelRead(14 downto 12);

               when READ24_0 =>
                  readstate                  <= READ24_16;
                  pixelData_R                <= videoout_pixelRead( 7 downto  0);
                  pixelData_G                <= videoout_pixelRead(15 downto  8);

               when READ24_8 =>
                  readstate                  <= READ24_24;
                  pixelData_R                <= videoout_pixelRead(15 downto  8);

               when READ24_16 =>
                  readstate                  <= IDLE;
                  readstate24                <= READ24_8;
                  pixelData_B                <= videoout_pixelRead( 7 downto  0);

                when READ24_24 =>
                  readstate                  <= IDLE;
                  readstate24                <= READ24_0;
                  videoout_readAddr  <= videoout_readAddr + 1;
                  pixelData_G                <= videoout_pixelRead( 7 downto  0);
                  pixelData_B                <= videoout_pixelRead(15 downto  8);

            end case;

         end if;

      end if;
   end process;

   --##############################################################
   --############################### line fetch, clk2x
   --##############################################################

   requestVRAMEnable <= '1'                       when (state = REQUEST and requestVRAMIdle = '1') else '0';
   requestVRAMXPos   <= reqPosX                   when (state = REQUEST and requestVRAMIdle = '1') else (others => '0');
   requestVRAMYPos   <= reqPosY                   when (state = REQUEST and requestVRAMIdle = '1') else (others => '0');
   requestVRAMSize   <= reqSize                   when (state = REQUEST and requestVRAMIdle = '1') else (others => '0');

   vDisplayStartRaw <= videoout_settings.vDisplayRange(9 downto 0);

   process (clk2x)
      variable thr  : unsigned(4 downto 0);
      variable diff : unsigned(4 downto 0);
   begin
      if rising_edge(clk2x) then

         -- display offset is adjusted if display start is below typical line for CRTs
         if (videoout_settings.GPUSTAT_PalVideoMode = '1' and videoout_settings.pal60 = '0') then
            thr := to_unsigned(19, 5);
         else
            thr := to_unsigned(16, 5);
         end if;
         diff := thr - vDisplayStartRaw(4 downto 0);
         DisplayOffsetY <= videoout_settings.vramRange(18 downto 10);
         if (vDisplayStartRaw < thr) then
            if (videoout_settings.GPUSTAT_VerRes = '1' and videoout_settings.GPUSTAT_VertInterlace = '1') then
               DisplayOffsetY <= videoout_settings.vramRange(18 downto 10) + (diff & '0');
            else
               DisplayOffsetY <= videoout_settings.vramRange(18 downto 10) + diff;
            end if;
         end if;

         if (state = WAITREAD) then
            if (vram_DOUT_READY = '1') then
               fillAddr <= fillAddr + 1;
            end if;
            if (requestVRAMDone = '1') then
               store  <= '0';
               state  <= WAITNEWLINE;
            end if;
         end if;

         if (reset = '1') then

            state   <= WAITNEWLINE;
            lineAct <= (others => '0');

         else

            case (state) is

               when WAITNEWLINE =>
                  if (videoout_on = '1' and videoout_request.lineInNext /= lineAct and videoout_request.fetch = '1' and videoout_settings.GPUSTAT_DisplayDisable = '0') then
                     waitcnt <= 3;
                     state   <= WAITREQUEST;
                  end if;

               when WAITREQUEST =>
                  if (waitcnt > 0) then
                     waitcnt <= waitcnt - 1;
                  else
                     state     <= REQUEST;
                     lineAct   <= videoout_request.lineInNext;
                     reqPosX   <= vo.DisplayOffsetX;
                     reqPosY   <= videoout_request.lineInNext + DisplayOffsetY;
                     if (videoout_settings.GPUSTAT_ColorDepth24 = '1') then
                        reqSize <= resize(videoout_request.fetchsize, 11) + resize(videoout_request.fetchsize(9 downto 1), 11);
                     else
                        reqSize <= '0' & videoout_request.fetchsize;
                     end if;
                     fillAddr  <= videoout_request.lineInNext(0) & x"00";
                     if (videoout_settings.GPUSTAT_VerRes = '1') then
                        fillAddr(8)  <= videoout_request.lineInNext(1);
                     end if;
                  end if;

               when REQUEST =>
                  if (requestVRAMIdle = '1') then
                     state <= WAITREAD;
                     store <= '1';
                  end if;

               when WAITREAD  => null; -- handled outside

            end case;

         end if;

      end if;
   end process;

   ilineram: entity work.dpram_dif
   generic map
   (
      addr_width_a  => 9,
      data_width_a  => 64,
      addr_width_b  => 11,
      data_width_b  => 16
   )
   port map
   (
      clock_a     => clk2x,
      address_a   => std_logic_vector(fillAddr),
      data_a      => vram_DOUT,
      wren_a      => (vram_DOUT_READY and store),

      clock_b     => clkvid,
      address_b   => std_logic_vector(videoout_readAddr),
      data_b      => x"0000",
      wren_b      => '0',
      q_b         => videoout_pixelRead
   );

end architecture;
