library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library mem;

-- DMA controller for the Pocket: the ports and cycle-exact behaviour of dma.vhd, with the per-channel MADR, BCR
-- and CHCR words in MLAB. Contract, exceptions and design notes: docs/pocket/CORE.md, section DMA.

entity dma_pocket is
   port
   (
      clk1x                : in  std_logic;
      clk3x                : in  std_logic;
      clk3xIndex           : in  std_logic;
      ce                   : in  std_logic;
      reset                : in  std_logic;

      errorCHOP            : out std_logic;
      errorDMACPU          : out std_logic;
      errorDMAFIFO         : out std_logic;

      TURBO                : in  std_logic;
      TURBO_CACHE          : in  std_logic;
      ram8mb               : in  std_logic;
      ignoreCDTiming       : in  std_logic;

      canDMA               : in  std_logic;
      cpuPaused            : in  std_logic;
      dmaRequest           : out std_logic;
      dmaStallCPU          : out std_logic;
      dmaOn                : out std_logic;
      irqOut               : out std_logic := '0';

      ram_Adr              : out std_logic_vector(22 downto 0) := (others => '0');
      ram_cnt              : buffer std_logic_vector(1 downto 0) := (others => '0');
      ram_ena              : out std_logic := '0';

      dma_wr               : in  std_logic;
      dma_reqprocessed     : in  std_logic;
      dma_data             : in  std_logic_vector(31 downto 0);

      ram_dmafifo_adr      : out std_logic_vector(22 downto 0);
      ram_dmafifo_data     : out std_logic_vector(31 downto 0);
      ram_dmafifo_empty    : out std_logic;
      ram_dmafifo_read     : in  std_logic;

      dma_cache_Adr        : out std_logic_vector(20 downto 0);
      dma_cache_data       : out std_logic_vector(31 downto 0);
      dma_cache_write      : out std_logic;

      gpu_dmaRequest       : in  std_logic;
      DMA_GPU_waiting      : out std_logic := '0';
      DMA_GPU_writeEna     : out std_logic := '0';
      DMA_GPU_readEna      : out std_logic := '0';
      DMA_GPU_write        : out std_logic_vector(31 downto 0);
      DMA_GPU_read         : in  std_logic_vector(31 downto 0);

      mdec_dmaWriteRequest : in  std_logic;
      mdec_dmaReadRequest  : in  std_logic;
      DMA_MDEC_writeEna    : out std_logic := '0';
      DMA_MDEC_readEna     : out std_logic := '0';
      DMA_MDEC_write       : out std_logic_vector(31 downto 0);
      DMA_MDEC_read        : in  std_logic_vector(31 downto 0);

      cd_memctrl           : in  unsigned(13 downto 0);
      com0_delay           : in  unsigned(3 downto 0);
      DMA_CD_readEna       : out std_logic := '0';
      DMA_CD_read          : in  std_logic_vector(7 downto 0);

      spu_timing_on        : in  std_logic;
      spu_timing_value     : in  unsigned(3 downto 0);

      spu_dmaRequest       : in  std_logic;
      DMA_SPU_writeEna     : out std_logic := '0';
      DMA_SPU_readEna      : out std_logic := '0';
      DMA_SPU_write        : out std_logic_vector(15 downto 0);
      DMA_SPU_read         : in  std_logic_vector(15 downto 0);

      bus_addr             : in  unsigned(6 downto 0);
      bus_dataWrite        : in  std_logic_vector(31 downto 0);
      bus_read             : in  std_logic;
      bus_write            : in  std_logic;
      bus_dataRead         : out std_logic_vector(31 downto 0);

      loading_savestate    : in  std_logic;
      SS_reset             : in  std_logic;
      SS_DataWrite         : in  std_logic_vector(31 downto 0);
      SS_Adr               : in  unsigned(5 downto 0);
      SS_wren              : in  std_logic;
      SS_rden              : in  std_logic;
      SS_DataRead          : out std_logic_vector(31 downto 0);
      SS_idle              : out std_logic
   );
end entity;

architecture arch of dma_pocket is

   type tdmaState is
   (
      OFF,
      STARTING,
      READHEADER,
      SLOWDOWN,
      WORKING,
      STOPPING,
      PAUSING
   );
   signal dmaState : tdmaState := OFF;

   -- per-channel words in MLAB; of CHCR only the bus-writable bits 30:29, 22:20, 18:16, 10:8, 1:0 (bits 24 and 28
   -- are flip-flops, the other bits read as 0)
   type t_madr is array (0 to 7) of unsigned(23 downto 0);
   type t_bcr  is array (0 to 7) of unsigned(31 downto 0);
   type t_chcr is array (0 to 7) of std_logic_vector(12 downto 0);
   signal madr_mem : t_madr;
   signal bcr_mem  : t_bcr;
   signal chcr_mem : t_chcr;
   attribute ramstyle : string;
   attribute ramstyle of madr_mem : signal is "MLAB, no_rw_check";
   attribute ramstyle of bcr_mem  : signal is "MLAB, no_rw_check";
   attribute ramstyle of chcr_mem : signal is "MLAB, no_rw_check";

   signal sweep       : unsigned(2 downto 0) := (others => '0');       -- clears the arrays during reset

   signal rd_adr      : integer range 0 to 7;
   signal rd_madr     : unsigned(23 downto 0);
   signal rd_bcr      : unsigned(31 downto 0);
   signal rd_chcr     : std_logic_vector(12 downto 0);
   signal trig_new    : std_logic;
   signal trig_chan   : integer range 0 to 6;
   signal dma_data_q  : std_logic_vector(31 downto 0);

   signal wb_ena      : std_logic;
   signal wr_madr     : std_logic;
   signal wr_bcr      : std_logic;
   signal wr_chcr     : std_logic;
   signal wr_adr      : integer range 0 to 7;
   signal wr_madr_d   : unsigned(23 downto 0);
   signal wr_bcr_d    : unsigned(31 downto 0);
   signal wr_chcr_d   : std_logic_vector(12 downto 0);

   -- per-channel flags stay in flip-flops: the trigger logic reads all seven every cycle
   signal chOn        : std_logic_vector(0 to 6) := (others => '0');
   signal f24         : std_logic_vector(0 to 6) := (others => '0');
   signal f28         : std_logic_vector(0 to 6) := (others => '0');
   signal chopwaiting : std_logic_vector(0 to 6) := (others => '0');
   -- A chop wait of n cycles stores the expiry stamp (tick counter + n); it ends on the tick that makes the
   -- counter equal to the stamp. A tick is a clock-enabled cycle with cpuPaused low. 7 bits cover n <= 128.
   type t_chopstamp is array (0 to 6) of unsigned(6 downto 0);
   signal chop_e      : t_chopstamp;
   signal chop_u      : unsigned(6 downto 0) := (others => '0');
   signal chop_uinc   : unsigned(6 downto 0);
   signal chop_unext  : unsigned(6 downto 0);

   -- the active transfer's working copy (loaded from the arrays, written back at the end of a transfer or pause)
   signal s_madr      : unsigned(23 downto 0);
   signal s_bcr       : unsigned(31 downto 0);
   signal s_chcr      : unsigned(31 downto 0) := (others => '0');

   signal DPCR                : unsigned(31 downto 0);
   signal DICR                : unsigned(23 downto 0);
   signal DICR_readback       : unsigned(31 downto 0);
   signal DICR_IRQs           : unsigned(6 downto 0);

   signal triggerDMA          : std_logic_vector(6 downto 0);
   signal triggerchannel      : integer range 0 to 6;

   signal readStall           : std_logic;

   signal wordAccu            : integer range 0 to 3 := 0;
   -- CD / SPU read accumulator (transfers from a device) and the linked list's next pointer (transfers to a device)
   signal read_accu           : std_logic_vector(23 downto 0);
   signal slowcnt             : integer range 0 to 24;

   signal activeChannel       : integer range 0 to 6;
   signal wordcount           : unsigned(16 downto 0);
   signal toDevice            : std_logic;
   signal directionNeg        : std_logic;

   signal chopsize            : unsigned(7 downto 0);
   signal chopwaittime        : unsigned(7 downto 0);
   signal chopdiff            : unsigned(16 downto 0);

   signal autoread            : std_logic := '0';
   signal useDataDirect       : std_logic := '0';

   signal requestedDwords     : integer range 0 to 131071;
   signal requiredDwords      : integer range 0 to 131071;

   signal fifoIn_reset        : std_logic := '0';
   signal fifoIn_Din          : std_logic_vector(31 downto 0);
   signal fifoIn_Wr           : std_logic;
   signal fifoIn_Full         : std_logic;
   signal fifoIn_Dout         : std_logic_vector(31 downto 0);
   signal fifoIn_Rd           : std_logic;
   signal fifoIn_Empty        : std_logic;
   signal fifoIn_Valid        : std_logic;
   signal fifoIn_Valid_1      : std_logic;

   signal fifoOut_reset       : std_logic := '0';
   signal fifoOut_Din         : std_logic_vector(52 downto 0);
   signal fifoOut_Wr          : std_logic;
   signal fifoOut_Wr_3x       : std_logic;
   signal fifoOut_Full        : std_logic;
   signal fifoOut_NearFull_3x : std_logic;
   signal fifoOut_NearFull    : std_logic;
   signal fifoOut_Dout        : std_logic_vector(52 downto 0);
   signal fifoOut_Empty       : std_logic;
   signal fifoOut_NearEmpty_3x: std_logic;
   signal fifoOut_NearEmpty   : std_logic;

   signal REP_counter         : integer range 0 to 1048575;
   signal REP_target          : integer range 0 to 1048575;
   signal REP_refresh         : unsigned(6 downto 0);
   signal REP_required        : std_logic;

   function chcr32(m : std_logic_vector(12 downto 0); b24, b28 : std_logic) return unsigned is
      variable r : unsigned(31 downto 0) := (others => '0');
   begin
      r(30 downto 29) := unsigned(m(12 downto 11));
      r(28)           := b28;
      r(24)           := b24;
      r(22 downto 20) := unsigned(m(10 downto 8));
      r(18 downto 16) := unsigned(m(7 downto 5));
      r(10 downto 8)  := unsigned(m(4 downto 2));
      r(1 downto 0)   := unsigned(m(1 downto 0));
      return r;
   end function;

   function chcr13(d : std_logic_vector(31 downto 0)) return std_logic_vector is
   begin
      return d(30 downto 29) & d(22 downto 20) & d(18 downto 16) & d(10 downto 8) & d(1 downto 0);
   end function;

begin

   toDevice <= s_chcr(0);

   ram_cnt <= "00" when (directionNeg = '1' and ram_adr(9 downto 2) = x"01") else
              "01" when (directionNeg = '1' and ram_adr(9 downto 2) = x"02") else
              "10" when (directionNeg = '1' and ram_adr(9 downto 2) = x"03") else
              "00" when (directionNeg = '0' and ram_adr(9 downto 2) = x"FF") else
              "01" when (directionNeg = '0' and ram_adr(9 downto 2) = x"FE") else
              "10" when (directionNeg = '0' and ram_adr(9 downto 2) = x"FD") else
              "11";

   dmaOn <= '0' when ((dmaState = STOPPING or dmaState = PAUSING) and fifoOut_NearEmpty = '1' and (TURBO = '1' or REP_counter >= REP_target)) else
            '1' when (dmaState /= OFF) else
            '0';

   DICR_readback( 5 downto  0) <= DICR( 5 downto 0);
   DICR_readback(14 downto  6) <= "000000000";
   DICR_readback(23 downto 15) <= DICR(23 downto 15);
   DICR_readback(30 downto 24) <= DICR_IRQs;
   DICR_readback(31)           <= '1' when (DICR(15) = '1') else
                                  '1' when (DICR(23) = '1' and (DICR(22 downto 16) and DICR_IRQs) /= "0000000") else
                                  '0';

   DMA_MDEC_readEna  <= '1' when (dmaState = WORKING and fifoOut_NearFull = '0' and activeChannel = 1 and toDevice = '0') else '0';

   DMA_GPU_waiting   <= '1' when (dmaOn = '1' and activeChannel = 2) else
                        '1' when (DPCR((2 * 4) + 3) = '1' and f24(2) = '1') else
                        '0';

   DMA_GPU_readEna   <= '1' when (dmaState = WORKING and fifoOut_NearFull = '0' and activeChannel = 2 and toDevice = '0') else '0';

   DMA_CD_readEna    <= '1' when (dmaState = WORKING and fifoOut_NearFull = '0' and activeChannel = 3 and toDevice = '0') else '0';

   DMA_SPU_readEna   <= '1' when (dmaState = WORKING and fifoOut_NearFull = '0' and activeChannel = 4 and toDevice = '0') else '0';

   readStall <= '1' when (activeChannel = 2 and toDevice = '0' and gpu_dmaRequest = '0') else '0';

   chopsize     <= to_unsigned(1, 8) sll to_integer(s_chcr(18 downto 16));
   chopdiff     <= ('0' & s_bcr(15 downto 0)) - resize(chopsize, 17);
   chopwaittime <= to_unsigned(1, 8) sll to_integer(s_chcr(22 downto 20));
   chop_uinc    <= chop_u + 1;
   chop_unext   <= chop_u when cpuPaused = '1' else chop_uinc;

   SS_DataRead <= (others => '0');

   -- the GPU and MDEC consumers read their write data only while the matching enable is high
   DMA_GPU_write  <= dma_data_q;
   DMA_MDEC_write <= dma_data_q;

--##############################################################
--############################### channel words (MLAB)
--##############################################################

   -- One read port: the bus read, else the channel the trigger logic selects this cycle. That channel's words are
   -- preloaded into the working copy while the controller is off; the start cycle uses them unchanged.
   rd_adr  <= to_integer(bus_addr(6 downto 4)) when bus_read = '1' else trig_chan;
   rd_madr <= madr_mem(rd_adr);
   rd_bcr  <= bcr_mem(rd_adr);
   rd_chcr <= chcr_mem(rd_adr);

   -- trigger arbitration: lowest DPCR priority value wins, the higher channel number on a tie
   process (all)
      variable nw   : std_logic;
      variable ch   : integer range 0 to 6;
      variable prio : unsigned(2 downto 0);
   begin
      nw   := '0';
      ch   := 0;
      prio := "111";
      if (dmaState = OFF and bus_write = '0' and bus_read = '0') then
         for i in 0 to 6 loop
            if (triggerDMA(i) = '1' and chopwaiting(i) = '0') then
               if ((DPCR((i * 4) + 3) = '1' and f24(i) = '1') or chOn(i) = '1') then
                  if (nw = '0' or (unsigned(DPCR((i * 4) + 2 downto (i * 4))) <= prio)) then
                     nw   := '1';
                     ch   := i;
                     prio := unsigned(DPCR((i * 4) + 2 downto (i * 4)));
                  end if;
               end if;
            end if;
         end loop;
      end if;
      trig_new  <= nw;
      trig_chan <= ch;
   end process;

   -- write-back at the end of a transfer or a pause (same condition as the golden's STOPPING / PAUSING exit)
   wb_ena <= '1' when ((dmaState = STOPPING or dmaState = PAUSING) and fifoOut_NearEmpty = '1' and
                       (TURBO = '1' or REP_required = '0' or REP_counter >= REP_target)) else '0';

   process (all)
   begin
      wr_madr   <= '0';
      wr_bcr    <= '0';
      wr_chcr   <= '0';
      wr_adr    <= to_integer(sweep);
      wr_madr_d <= (others => '0');
      wr_bcr_d  <= (others => '0');
      wr_chcr_d <= (others => '0');
      if (reset = '1') then
         wr_madr <= '1';
         wr_bcr  <= '1';
         wr_chcr <= '1';
      elsif (ce = '1') then
         if (wb_ena = '1') then
            wr_adr    <= activeChannel;
            wr_madr   <= '1';
            wr_bcr    <= '1';
            wr_madr_d <= s_madr;
            wr_bcr_d  <= s_bcr;
         elsif (bus_write = '1' and bus_addr(6 downto 4) /= "111") then
            wr_adr    <= to_integer(bus_addr(6 downto 4));
            wr_madr_d <= unsigned(bus_dataWrite(23 downto 0));
            wr_bcr_d  <= unsigned(bus_dataWrite);
            wr_chcr_d <= chcr13(bus_dataWrite);
            case (bus_addr(3 downto 2)) is
               when "00"   => wr_madr <= '1';
               when "01"   => wr_bcr  <= '1';
               when "10"   => wr_chcr <= '1';
               when others => null;
            end case;
         end if;
      end if;
   end process;

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (reset = '1') then
            sweep <= sweep + 1;
         end if;
         if (wr_madr = '1') then madr_mem(wr_adr) <= wr_madr_d; end if;
         if (wr_bcr  = '1') then bcr_mem(wr_adr)  <= wr_bcr_d;  end if;
         if (wr_chcr = '1') then chcr_mem(wr_adr) <= wr_chcr_d; end if;
      end if;
   end process;

--##############################################################
--############################### control
--##############################################################

   process (clk1x)
      variable channel         : integer range 0 to 7;
      variable checkIRQ        : std_logic;
      variable addtime         : integer range 0 to 511;
      variable chop_ld         : std_logic;               -- state machine starts a chop wait for activeChannel
      variable chop_v          : unsigned(6 downto 0);    -- its length
      variable chop_w2         : std_logic;               -- GPU CHCR write with linked-list sync starts a wait
   begin
      if rising_edge(clk1x) then

         fifoIn_reset  <= '0';
         fifoOut_reset <= '0';

         fifoOut_Wr    <= '0';

         fifoIn_Valid   <= fifoIn_Rd;
         fifoIn_Valid_1 <= fifoIn_Valid;

         if (cpuPaused = '1') then
            REP_counter <= REP_counter + 1;
         else
            REP_counter <= 0;
         end if;

         errorCHOP      <= '0';
         errorDMACPU    <= '0';
         errorDMAFIFO   <= '0';

         fifoOut_NearFull  <= fifoOut_NearFull_3x;
         fifoOut_NearEmpty <= fifoOut_NearEmpty_3x;

         if (reset = '1') then

            f24            <= (others => '0');
            f28            <= (others => '0');
            chOn           <= (others => '0');

            DPCR           <= x"07654321";
            DICR           <= (others => '0');
            DICR_IRQs      <= (others => '0');

            activeChannel  <= 0;

            -- dmaRequest survives a reset (as in the golden) and may start a transfer on the cleared arrays
            s_madr         <= (others => '0');
            s_bcr          <= (others => '0');
            s_chcr         <= (others => '0');

            dmaState       <= OFF;
            autoread       <= '0';
            fifoIn_reset   <= '1';
            fifoOut_reset  <= '1';
            irqOut         <= '0';
            triggerDMA     <= (others => '0');

            chopwaiting    <= (others => '0');

         elsif (ce = '1') then

            irqOut               <= '0';
            ram_ena              <= '0';

            DMA_MDEC_writeEna    <= '0';
            DMA_GPU_writeEna     <= '0';
            DMA_SPU_writeEna     <= '0';
            if (fifoIn_Valid_1 = '1' and DMA_SPU_writeEna = '1') then
               DMA_SPU_writeEna <= '1';
               DMA_SPU_write    <= fifoIn_Dout(31 downto 16);
            end if;

            bus_dataRead         <= (others => '0');
            dma_data_q           <= dma_data;

            channel := to_integer(unsigned(bus_addr(6 downto 4)));
            chop_ld := '0';
            chop_v  := (others => '0');
            chop_w2 := '0';

            -- triggers from modules
            triggerDMA <= (others => '0');
            if (f28(0) = '1' or mdec_dmaWriteRequest = '1')  then triggerDMA(0) <= '1'; end if;
            if (f28(1) = '1' or mdec_dmaReadRequest = '1')   then triggerDMA(1) <= '1'; end if;
            if (f28(2) = '1' or gpu_dmaRequest = '1')        then triggerDMA(2) <= '1'; end if;
            if (f28(3) = '1')                                then triggerDMA(3) <= '1'; end if;
            if (f28(4) = '1' or spu_dmaRequest = '1')        then triggerDMA(4) <= '1'; end if;
            if (f28(6) = '1')                                then triggerDMA(6) <= '1'; end if;

            -- bus read
            if (bus_read = '1') then
               if (channel < 7) then
                  case (bus_addr(3 downto 2)) is
                     when "00" => bus_dataRead <= x"00" & std_logic_vector(rd_madr);
                     when "01" => bus_dataRead <= std_logic_vector(rd_bcr);
                     when "10" => bus_dataRead <= std_logic_vector(chcr32(rd_chcr, f24(channel), f28(channel)));
                     when others => bus_dataRead <= (others => '1');
                  end case;
               else
                  case (bus_addr(3 downto 2)) is
                     when "00" => bus_dataRead <= std_logic_vector(DPCR);
                     when "01" => bus_dataRead <= std_logic_vector(DICR_readback);
                     when others => bus_dataRead <= (others => '1');
                  end case;
               end if;
            end if;

            -- bus write
            if (bus_write = '1') then
               if (channel < 7) then
                  case (bus_addr(3 downto 2)) is
                     when "10" =>
                        f24(channel) <= bus_dataWrite(24);
                        f28(channel) <= bus_dataWrite(28);
                        if (bus_dataWrite(24) = '0') then
                           chOn(channel) <= '0';
                        end if;
                        triggerDMA(channel) <= '0';

                        if (channel = 2 and bus_dataWrite(10 downto 9) = "10") then
                           chop_w2 := '1';
                        end if;

                     when others => null;
                  end case;
               else
                  case (bus_addr(3 downto 2)) is
                     when "00" =>
                        DPCR       <= unsigned(bus_dataWrite);
                     when "01" =>
                        DICR( 5 downto  0) <= unsigned(bus_dataWrite(5 downto 0));
                        DICR(14 downto  6) <= (14 downto 6 => '0');
                        DICR(          15) <= bus_dataWrite(15);
                        DICR(23 downto 16) <= unsigned(bus_dataWrite(23 downto 16));
                        DICR_IRQs          <= DICR_IRQs and (not unsigned(bus_dataWrite(30 downto 24)));
                        if (bus_dataWrite(15) = '1') then
                           irqOut <= '1';
                        end if;
                     when others => null;
                  end case;
               end if;
            end if;

            -- trigger
            dmaRequest    <= trig_new;
            triggerchannel <= trig_chan;

            -- accu
            if (DMA_CD_readEna = '1') then
               case (wordAccu) is
                  when 0 => wordAccu <= 3;
                  when 1 => wordAccu <= 0; read_accu(23 downto 16) <= DMA_CD_read;
                  when 2 => wordAccu <= 1; read_accu(15 downto  8) <= DMA_CD_read;
                  when 3 => wordAccu <= 2; read_accu( 7 downto  0) <= DMA_CD_read;
                  when others => null;
               end case;
            end if;

            if (DMA_SPU_readEna = '1') then
               case (wordAccu) is
                  when 0 => wordAccu <= 1;
                  when 1 => wordAccu <= 0; read_accu(15 downto 0) <= DMA_SPU_read;
                  when others => null;
               end case;
            end if;

            if (dmaState /= OFF and (bus_write = '1' or bus_read = '1')) then
               errorDMACPU <= '1';
            end if;

            if (fifoIn_Full = '1' or fifoOut_Full = '1') then
               errorDMAFIFO <= '1';
            end if;


            if (dmaState = WORKING and TURBO_CACHE = '1' and toDevice = '0') then
               dmaStallCPU <= '1';
            elsif (fifoOut_Empty = '1') then
               dmaStallCPU <= '0';
            end if;

            case (dmaState) is

               when OFF =>
                  fifoIn_reset    <= '1';
                  requestedDwords <= 0;

                  if (dmaRequest = '1' and canDMA = '1') then
                     f28(triggerchannel)  <= '0';
                     chOn(triggerchannel) <= '1';

                     dmaState      <= STARTING;
                     activeChannel <= triggerchannel;

                     REP_refresh   <= (others => '0');

                     if (s_chcr(0) = '1') then
                        ram_ena  <= '1';
                        ram_Adr  <= std_logic_vector(s_madr(22 downto 2)) & "00";
                     end if;

                     directionNeg <= '0';
                     if (s_chcr(10) = '0' and s_chcr(1) = '1') then
                        directionNeg <= '1';
                     end if;

                  else
                     s_chcr <= chcr32(rd_chcr, '0', '0');
                     s_madr <= rd_madr;
                     s_bcr  <= rd_bcr;
                  end if;

               when STARTING =>

                  wordAccu     <= 0;
                  if (activeChannel = 3) then
                     wordAccu <= 3;
                  end if;
                  if (activeChannel = 4) then
                     wordAccu <= 1;
                  end if;

                  useDataDirect <= '0';
                  if (activeChannel = 0 or activeChannel = 2) then
                     useDataDirect <= '1';
                  end if;

                  REP_required <= '1';
                  if (toDevice = '0') then
                     REP_target    <= 3;
                     if (activeChannel = 3) then
                        REP_target <= 2;
                     end if;
                     if (activeChannel = 4) then
                        REP_target <= 2;
                     end if;
                  else
                     REP_target    <= 3;
                     if (activeChannel = 4) then
                        REP_target <= 5;
                     end if;
                  end if;

                  if (s_chcr(8) = '1' and activeChannel /= 3 and activeChannel /= 6) then
                     errorCHOP <= '1';
                  end if;

                  case (s_chcr(10 downto 9)) is
                     when "00" => -- manual
                        if (s_chcr(8) = '1') then -- chopping
                           wordcount      <= resize(chopsize, 17);
                           requiredDwords <= to_integer(chopsize);
                           -- one subtraction serves all three cases; bit 16 is the borrow
                           if (s_bcr(15 downto 0) = 0) then
                              s_bcr(16 downto 0) <= '0' & chopdiff(15 downto 0);        -- 65536 - chopsize
                           elsif (chopdiff(16) = '0' and chopdiff(15 downto 0) /= 0) then
                              s_bcr(15 downto 0) <= chopdiff(15 downto 0);
                           else
                              wordcount                                  <= '0' & s_bcr(15 downto 0);
                              requiredDwords                             <= to_integer(s_bcr(15 downto 0));
                              s_bcr(15 downto 0)                         <= (others => '0');
                           end if;
                        else
                           if (s_bcr(15 downto 0) = 0) then
                              wordcount <= '1' & x"0000";
                              requiredDwords <= 16#10000#;
                           else
                              wordcount      <= '0' & s_bcr(15 downto 0);
                              requiredDwords <= to_integer(s_bcr(15 downto 0));
                           end if;
                        end if;

                     when "01" => -- request
                        wordcount      <= '0' & s_bcr(15 downto 0);
                        requiredDwords <= to_integer(s_bcr(15 downto 0));

                     when others => null;
                  end case;

                  if (toDevice = '0') then -- from device -> can start immidiatly
                     case (s_chcr(10 downto 9)) is
                        when "00" => -- manual
                           dmaState    <= WORKING;

                        when "01" => -- request
                           dmaState    <= WORKING;

                        when "10" => -- linked list -> forbidden
                           dmaState <= OFF;

                        when others =>
                           dmaState <= OFF;
                     end case;
                  else
                     case (s_chcr(10 downto 9)) is
                        when "00" => -- manual
                           dmaState    <= WORKING;
                           autoread    <= '1';

                        when "01" => -- request
                           dmaState    <= WORKING;
                           autoread    <= '1';

                        when "10" => -- linked list
                           dmaState    <= READHEADER;

                        when others =>
                           dmaState <= OFF;
                     end case;
                  end if;

               when READHEADER =>
                  if (dma_wr = '1') then
                     read_accu <= dma_data(23 downto 0);
                     if (unsigned(dma_data(31 downto 24)) > 0) then
                        s_madr             <= s_madr + 4;
                        dmaState           <= WORKING;
                        REP_target         <= 8;
                        wordcount          <= "0" & x"00" & unsigned(dma_data(31 downto 24));
                        requiredDwords     <= to_integer(unsigned(dma_data(31 downto 24))) + 1;
                        if (requestedDwords < (to_integer(unsigned(dma_data(31 downto 24))) + 1)) then
                           autoread        <= '1';
                           ram_ena         <= '1';
                        end if;
                     elsif (dma_data(23) = '1' or toDevice = '0') then
                        dmaState <= STOPPING;
                        if (DICR(16 + activeChannel) = '1') then
                           DICR_IRQs(activeChannel) <= '1';
                           if (DICR(23) = '1') then
                              irqOut <= '1';
                           end if;
                        end if;
                     else
                        s_madr      <= unsigned(dma_data(23 downto 0));
                        dmaState    <= PAUSING;
                        chop_ld := '1';
                        chop_v  := to_unsigned(3, 7);
                     end if;
                  end if;

               when SLOWDOWN =>
                  if (slowcnt > 0) then
                     slowcnt <= slowcnt - 1;
                  else
                     dmaState <= WORKING;
                  end if;

               when WORKING =>
                  if (fifoIn_Valid = '1' or (useDataDirect = '1' and dma_wr = '1') or (toDevice = '0' and fifoOut_NearFull = '0' and wordAccu = 0 and readStall = '0')) then
                     REP_target  <= REP_target + 1;
                     case (activeChannel) is

                        when 0 =>
                           if (toDevice = '1') then
                              DMA_MDEC_writeEna <= '1';
                           else
                              report "read from MDEC in not possible" severity failure;
                           end if;

                        when 1 =>
                           if (toDevice = '0') then
                              fifoOut_Wr                <= not s_madr(23);
                              fifoOut_Din(52 downto 32) <= std_logic_vector(s_madr(22 downto 2));
                              fifoOut_Din(31 downto 0)  <= DMA_MDEC_read;
                           else
                              report "write to MDEC out not possible" severity failure;
                           end if;

                        when 2 =>
                           if (toDevice = '1') then
                              DMA_GPU_writeEna  <= '1';
                           else
                              fifoOut_Wr                <= not s_madr(23);
                              fifoOut_Din(52 downto 32) <= std_logic_vector(s_madr(22 downto 2));
                              fifoOut_Din(31 downto 0)  <= DMA_GPU_read;
                           end if;

                        when 3 =>
                           if (toDevice = '0') then
                              fifoOut_Wr                <= not s_madr(23);
                              fifoOut_Din(52 downto 32) <= std_logic_vector(s_madr(22 downto 2));
                              fifoOut_Din(31 downto 0)  <= DMA_CD_read & read_accu;
                           end if;

                        when 4 =>
                           REP_required <= '1';
                           REP_target   <= REP_target + 4;
                           if (toDevice = '1') then
                              DMA_SPU_writeEna  <= '1';
                              DMA_SPU_write     <= fifoIn_Dout(15 downto 0);
                           else
                              fifoOut_Wr                <= not s_madr(23);
                              fifoOut_Din(52 downto 32) <= std_logic_vector(s_madr(22 downto 2));
                              fifoOut_Din(31 downto 0)  <= DMA_SPU_read & read_accu(15 downto 0);
                           end if;

                        when 6 =>
                           if (toDevice = '0') then
                              fifoOut_Wr                <= not s_madr(23);
                              fifoOut_Din(52 downto 32) <= std_logic_vector(s_madr(22 downto 2));
                              if (wordcount = 1) then
                                 fifoOut_Din(31 downto 0) <= x"00FFFFFF";
                              else
                                 fifoOut_Din(31 downto 0) <= x"00" & std_logic_vector(s_madr(23 downto 2) - 1) & "00";
                              end if;
                           end if;

                        when others => report "DMA channel not implemented" severity failure;
                     end case;

                     if (ram8mb = '0') then
                        fifoOut_Din(52 downto 51) <= "00";
                     end if;

                     if (directionNeg = '1')  then
                        s_madr <= s_madr - 4;
                     else
                        s_madr <= s_madr + 4;
                     end if;

                     -- timing when hitting new bank
                     if (wordcount > 1) then
                        if (directionNeg = '1')  then
                           if (s_madr(9 downto 2) = x"00") then
                              if (toDevice = '1') then
                                 REP_target   <= REP_target + 5;
                              else
                                 REP_target   <= REP_target + 6;
                              end if;
                              REP_required <= '1';
                           end if;
                        else
                           if (s_madr(9 downto 2) = x"FF") then
                              if (toDevice = '1') then
                                 REP_target   <= REP_target + 5;
                              else
                                 REP_target   <= REP_target + 6;
                              end if;
                              REP_required <= '1';
                           end if;
                        end if;
                     end if;

                     -- timing for sdram refresh
                     REP_refresh <= REP_refresh + 1;
                     if (REP_refresh >= 100) then
                        REP_refresh  <= (others => '0');
                        REP_target   <= REP_target + 6;
                        REP_required <= '1';
                     end if;

                     -- special timings
                     if (activeChannel = 4 and spu_timing_on = '1' and spu_timing_value > 0) then
                        REP_target   <= REP_target + 4 + (to_integer(spu_timing_value) * 2);
                        REP_required <= '1';
                     end if;

                     if (ignoreCDTiming = '0' and activeChannel = 3) then
                        REP_required <= '1';
                        addtime := 24;
                        if (cd_memctrl(8) = '1') then
                           if (wordcount > 1 and com0_delay > 0) then
                              addtime := addtime + to_integer(com0_delay) - 1;
                           end if;
                        end if;
                        if (REP_refresh >= 100) then
                           addtime := addtime + 6;
                        end if;
                        REP_target <= REP_target + addtime;
                     end if;

                     checkIRQ := '0';
                     wordcount <= wordcount - 1;
                     if (wordcount <= 1) then
                        case (s_chcr(10 downto 9)) is
                           when "00" => -- manual
                              if (s_chcr(8) = '1' and s_bcr(15 downto 0) > 0) then
                                 dmaState <= PAUSING;
                                 chop_ld := '1';
                                 chop_v  := chopwaittime(6 downto 0);
                                 f28(activeChannel)         <= '1';
                              else
                                 checkIRQ := '1';
                                 dmaState <= STOPPING;
                              end if;

                           when "01" => -- request
                              s_bcr(31 downto 16) <= s_bcr(31 downto 16) - 1;      -- blocks left - 1 = BCR(31:16) - 1
                              if (s_bcr(31 downto 16) = 1) then
                                 dmaState <= STOPPING;
                                 checkIRQ := '1';
                              else
                                 dmaState <= PAUSING;
                                 chop_ld := '1';
                                 chop_v  := to_unsigned(2, 7);
                              end if;

                           when "10" => -- linked list
                              s_madr <= unsigned(read_accu);
                              if (read_accu(23) = '1') then
                                 checkIRQ := '1';
                                 dmaState <= STOPPING;
                              else
                                 dmaState <= PAUSING;
                                 chop_ld := '1';
                                 chop_v  := to_unsigned(2, 7);
                              end if;

                           when others => null;
                        end case;
                     else
                        if (activeChannel = 4 and toDevice = '1') then -- SPU access is 4 cycles per 32bit
                           slowcnt  <= 1;
                           dmaState <= SLOWDOWN;
                        end if;
                        if (activeChannel = 3 and toDevice = '0') then -- CD access
                           slowcnt  <= 24;
                           dmaState <= SLOWDOWN;
                        end if;
                     end if;

                     if (checkIRQ = '1') then
                        if (DICR(16 + activeChannel) = '1') then
                           DICR_IRQs(activeChannel) <= '1';
                           if (DICR(23) = '1') then
                              irqOut <= '1';
                           end if;
                        end if;
                     end if;

                  else
                     REP_refresh <= REP_refresh + 1;

                     if (REP_counter >= REP_target) then
                        REP_required <= '0';
                     end if;

                     if (ignoreCDTiming = '0' and activeChannel = 3 and cd_memctrl(8) = '1' and com0_delay > 0) then
                        REP_target <= REP_target + to_integer(com0_delay) - 1;
                     end if;

                  end if;

               when STOPPING =>
                  autoread <= '0';
                  if (fifoOut_NearEmpty = '1') then
                     if (TURBO = '1' or REP_required = '0' or REP_counter >= REP_target) then
                        dmaState   <= OFF;
                        f24(activeChannel) <= '0';
                        chOn(activeChannel) <= '0';
                     end if;
                  end if;

               when PAUSING =>
                  autoread <= '0';
                  if (fifoOut_NearEmpty = '1') then
                     if (TURBO = '1' or REP_required = '0' or REP_counter >= REP_target) then
                        dmaState   <= OFF;
                     end if;
                  end if;

            end case;

--##############################################################
--############################### ram read handling
--##############################################################

            if (dma_reqprocessed = '1') then
               if (autoread = '1') then
                  ram_ena         <= '1';
               end if;
               if (directionNeg = '1') then
                  ram_Adr <= std_logic_vector(unsigned(ram_Adr) - ((1 + to_integer(unsigned(ram_cnt))) * 4));
               else
                  ram_Adr <= std_logic_vector(unsigned(ram_Adr) + ((1 + to_integer(unsigned(ram_cnt))) * 4));
               end if;
            end if;

            if ((dmaState = WORKING or dmaState = SLOWDOWN) and requestedDwords >= requiredDwords) then
               autoread <= '0';
               ram_ena  <= '0';
            end if;

            if (ram_ena = '1') then
               requestedDwords <= requestedDwords + (1 + to_integer(unsigned(ram_cnt)));
            end if;

            -- chopping wait: the state machine's start overrides the GPU CHCR write's, which a running wait that ticks
            -- in the same cycle suppresses
            if (cpuPaused = '0') then
               chop_u <= chop_uinc;
            end if;
            for i in 0 to 6 loop
               if (chopwaiting(i) = '1' and cpuPaused = '0' and chop_e(i) = chop_uinc) then
                  chopwaiting(i) <= '0';
               end if;
            end loop;
            if (chop_ld = '1') then
               chopwaiting(activeChannel) <= '1';
               chop_e(activeChannel)      <= chop_unext + chop_v;
            elsif (chop_w2 = '1' and not (chopwaiting(2) = '1' and cpuPaused = '0')) then
               chopwaiting(2) <= '1';
               chop_e(2)      <= chop_unext + 10;
            end if;

         end if; -- ce

      end if;
   end process;

   fifoIn_Wr  <= ce when (toDevice = '1' and dma_wr = '1' and useDataDirect = '0') else '0';
   fifoIn_Din <= dma_data(31 downto 0);


   fifoIn_Rd <= '1' when (fifoIn_Empty = '0' and toDevice = '1' and dmaState = working and (activeChannel /= 4 or fifoIn_Valid = '0')) else '0';

   iDMAfifoIn: entity mem.Syncfifo
   generic map
   (
      SIZE             => 64,
      DATAWIDTH        => 32,
      NEARFULLDISTANCE => 32
   )
   port map
   (
      clk      => clk1x,
      reset    => fifoIn_reset,
      Din      => fifoIn_Din,
      Wr       => fifoIn_Wr,
      Full     => fifoIn_Full,
      NearFull => open,
      Dout     => fifoIn_Dout,
      Rd       => fifoIn_Rd,
      Empty    => fifoIn_Empty
   );

   DMAfifoOut: entity mem.SyncFifoFallThrough
   generic map
   (
      SIZE              => 64,
      DATAWIDTH         => 53,
      NEARFULLDISTANCE  => 56,
      NEAREMPTYDISTANCE => 2
   )
   port map
   (
      clk       => clk3x,
      reset     => fifoOut_reset,
      Din       => fifoOut_Din,
      Wr        => fifoOut_Wr_3x,
      Full      => fifoOut_Full,
      NearFull  => fifoOut_NearFull_3x,
      Dout      => fifoOut_Dout,
      Rd        => ram_dmafifo_read,
      Empty     => fifoOut_Empty,
      NearEmpty => fifoOut_NearEmpty_3x
   );

   fifoOut_Wr_3x <= clk3xIndex and fifoOut_Wr;

   ram_dmafifo_adr   <= fifoOut_Dout(52 downto 32) & "00";
   ram_dmafifo_data  <= fifoOut_Dout(31 downto 0);
   ram_dmafifo_empty <= fifoOut_Empty;

   dma_cache_Adr   <= fifoOut_Din(50 downto 32) & "00";
   dma_cache_data  <= fifoOut_Din(31 downto 0);
   dma_cache_write <= fifoOut_Wr;

   process (clk1x)
   begin
      if (rising_edge(clk1x)) then
         SS_idle <= '0';
         if (dmaOn = '0' and dmaRequest = '0') then
            SS_idle <= '1';
         end if;
      end if;
   end process;

end architecture;
