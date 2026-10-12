-- Directed tests: spu_none register echo, SPUSTAT mirror, spu_tick period; cd_none status reads;
-- DMA channel 4 in both directions through the real dma.vhd against spu_none.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;

entity tb_none_units is
end entity;

architecture sim of tb_none_units is

   signal clk1x, clk3x : std_logic := '0';
   signal clk3xIndex   : std_logic := '0';
   signal reset        : std_logic := '1';
   signal ce           : std_logic := '1';

   -- spu_none
   signal spu_addr   : unsigned(9 downto 0) := (others => '0');
   signal spu_wdata  : std_logic_vector(15 downto 0) := (others => '0');
   signal spu_rd, spu_wr : std_logic := '0';
   signal spu_rdata  : std_logic_vector(15 downto 0);
   signal spu_tick   : std_logic;
   signal spu_dmaReq : std_logic;
   signal spu_dmaRd, spu_dmaWr : std_logic;
   signal spu_dmaRdData, spu_dmaWrData : std_logic_vector(15 downto 0);
   signal spu_wr_count : integer := 0;

   -- cd_none
   signal cd_addr  : unsigned(3 downto 0) := (others => '0');
   signal cd_wdata : std_logic_vector(7 downto 0) := (others => '0');
   signal cd_rd, cd_wr : std_logic := '0';
   signal cd_rdata : std_logic_vector(7 downto 0);
   signal cd_region_out : std_logic_vector(1 downto 0);

   -- dma
   signal dma_addr  : unsigned(6 downto 0) := (others => '0');
   signal dma_wdata : std_logic_vector(31 downto 0) := (others => '0');
   signal dma_rd, dma_wr_bus : std_logic := '0';
   signal dma_rdata : std_logic_vector(31 downto 0);
   signal dma_ram_adr : std_logic_vector(22 downto 0);
   signal dma_ram_cnt : std_logic_vector(1 downto 0);
   signal dma_ram_ena : std_logic;
   signal dma_ram_wr, dma_ram_proc : std_logic := '0';
   signal dma_ram_data : std_logic_vector(31 downto 0) := (others => '0');
   signal dmaOn, dmaRequest, dma_irq : std_logic;
   signal fifo_empty : std_logic;
   signal dma_spu_wr, dma_spu_rd : std_logic;
   signal dma_spu_wdata, dma_spu_rdata : std_logic_vector(15 downto 0);

   signal ram_pend : integer := 0;
   signal ram_beats : integer := 0;
   signal tick_count, last_tick_clk : integer := 0;
   signal clk_count : integer := 0;
   signal tick_period : integer := 0;
   signal dma_words_written : integer := 0;
   signal dma_words_read : integer := 0;

   signal stop : boolean := false;

   procedure check(cond : boolean; msg : string) is
   begin
      assert cond report "FAIL " & msg severity failure;
   end procedure;

begin

   clk1x <= not clk1x after 15 ns when not stop;
   clk3x <= not clk3x after 5 ns when not stop;

   process (clk3x)
      variable c : integer := 0;
   begin
      if rising_edge(clk3x) then
         if (c = 0) then clk3xIndex <= '1'; else clk3xIndex <= '0'; end if;
         c := (c + 1) mod 3;
      end if;
   end process;

   ispu : entity work.spu_none
   port map
   (
      clk1x => clk1x, clk2x => '0', clk2xIndex => '0', ce => ce, reset => reset,
      SPUon => '1', SPUIRQTrigger => '0', useSDRAM => '0', REPRODUCIBLESPUIRQ => '1', REPRODUCIBLESPUDMA => '0',
      REVERBOFF => '0', cpuPaused => '0', spu_tick => spu_tick, cd_left => (others => '0'), cd_right => (others => '0'),
      bus_addr => spu_addr, bus_dataWrite => spu_wdata, bus_read => spu_rd, bus_write => spu_wr, bus_dataRead => spu_rdata,
      spu_dmaRequest => spu_dmaReq, dma_read => dma_spu_rd, dma_readdata => dma_spu_rdata,
      dma_write => dma_spu_wr, dma_writedata => dma_spu_wdata,
      sdram_dataRead => (others => '0'), sdram_done => '0',
      mem_ack => '0', mem_DOUT => (others => '0'), mem_DOUT_READY => '0',
      SS_reset => '0', loading_savestate => '0', SS_DataWrite => (others => '0'), SS_Adr => (others => '0'),
      SS_wren => '0', SS_rden => '0',
      SS_RAM_dataWrite => (others => '0'), SS_RAM_Adr => (others => '0'), SS_RAM_request => '0', SS_RAM_rnw => '0'
   );

   icd : entity work.cd_none
   port map
   (
      clk1x => clk1x, ce => ce, reset => reset,
      INSTANTSEEK => '0', FORCECDSPEED => "000", LIMITREADSPEED => '0', hasCD => '1', LIDopen => '0', fastCD => '0',
      testSeek => '0', pauseOnCDSlow => '0', region => "10", region_out => cd_region_out,
      spu_tick => spu_tick, mdec_idle => '1',
      bus_addr => cd_addr, bus_dataWrite => cd_wdata, bus_read => cd_rd, bus_write => cd_wr, bus_dataRead => cd_rdata,
      dma_read => '0', cd_hps_ack => '0', cd_hps_write => '0', cd_hps_data => (others => '0'),
      trackinfo_data => (others => '0'), trackinfo_addr => (others => '0'), trackinfo_write => '0',
      SS_reset => '0', SS_DataWrite => (others => '0'), SS_Adr => (others => '0'), SS_wren => '0', SS_rden => '0'
   );

   idma : entity work.dma
   port map
   (
      clk1x => clk1x, clk3x => clk3x, clk3xIndex => clk3xIndex, ce => ce, reset => reset,
      TURBO => '0', TURBO_CACHE => '0', ram8mb => '0', ignoreCDTiming => '0',
      canDMA => '1', cpuPaused => '1', dmaRequest => dmaRequest, dmaOn => dmaOn, irqOut => dma_irq,
      ram_Adr => dma_ram_adr, ram_cnt => dma_ram_cnt, ram_ena => dma_ram_ena,
      dma_wr => dma_ram_wr, dma_reqprocessed => dma_ram_proc, dma_data => dma_ram_data,
      ram_dmafifo_read => not fifo_empty, ram_dmafifo_empty => fifo_empty,
      gpu_dmaRequest => '0', DMA_GPU_read => (others => '0'),
      mdec_dmaWriteRequest => '0', mdec_dmaReadRequest => '0', DMA_MDEC_read => (others => '0'),
      cd_memctrl => (others => '0'), com0_delay => (others => '0'), DMA_CD_read => (others => '0'),
      spu_timing_on => '0', spu_timing_value => (others => '0'),
      spu_dmaRequest => spu_dmaReq, DMA_SPU_writeEna => dma_spu_wr, DMA_SPU_readEna => dma_spu_rd,
      DMA_SPU_write => dma_spu_wdata, DMA_SPU_read => dma_spu_rdata,
      bus_addr => dma_addr, bus_dataWrite => dma_wdata, bus_read => dma_rd, bus_write => dma_wr_bus, bus_dataRead => dma_rdata,
      loading_savestate => '0', SS_reset => '0', SS_DataWrite => (others => '0'), SS_Adr => (others => '0'),
      SS_wren => '0', SS_rden => '0'
   );

   -- RAM model for DMA reads: each request is answered two cycles later with 1+ram_cnt words of data
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         dma_ram_wr   <= '0';
         dma_ram_proc <= '0';
         if (dma_ram_ena = '1') then
            ram_pend  <= 2;
            ram_beats <= 1 + to_integer(unsigned(dma_ram_cnt));
         elsif (ram_pend > 0) then
            ram_pend <= ram_pend - 1;
            if (ram_pend = 1) then dma_ram_proc <= '1'; end if;
         elsif (ram_beats > 0) then
            dma_ram_wr   <= '1';
            dma_ram_data <= x"1234ABCD";
            ram_beats    <= ram_beats - 1;
         end if;
         if (dma_spu_wr = '1') then dma_words_written <= dma_words_written + 1; end if;
         if (dma_spu_rd = '1') then dma_words_read    <= dma_words_read + 1; end if;

         clk_count <= clk_count + 1;
         if (spu_tick = '1') then
            tick_period   <= clk_count - last_tick_clk;
            last_tick_clk <= clk_count;
            tick_count    <= tick_count + 1;
         end if;
      end if;
   end process;

   process
      procedure tick(n : integer := 1) is
      begin
         for i in 1 to n loop wait until rising_edge(clk1x); end loop;
      end procedure;

      procedure spu_write(a : integer; d : std_logic_vector(15 downto 0)) is
      begin
         spu_addr <= to_unsigned(a, 10); spu_wdata <= d; spu_wr <= '1'; tick;
         spu_wr <= '0'; tick;
      end procedure;

      procedure spu_read(a : integer; d : out std_logic_vector(15 downto 0)) is
      begin
         spu_addr <= to_unsigned(a, 10); spu_rd <= '1'; tick;
         spu_rd <= '0'; tick;      -- data is valid the cycle after bus_read, as in spu.vhd
         d := spu_rdata;
      end procedure;

      procedure cd_write(a : integer; d : std_logic_vector(7 downto 0)) is
      begin
         cd_addr <= to_unsigned(a, 4); cd_wdata <= d; cd_wr <= '1'; tick;
         cd_wr <= '0'; tick;
      end procedure;

      procedure cd_read(a : integer; d : out std_logic_vector(7 downto 0)) is
      begin
         cd_addr <= to_unsigned(a, 4); cd_rd <= '1'; tick;
         cd_rd <= '0'; tick;
         d := cd_rdata;
      end procedure;

      procedure dma_write(a : integer; d : std_logic_vector(31 downto 0)) is
      begin
         dma_addr <= to_unsigned(a, 7); dma_wdata <= d; dma_wr_bus <= '1'; tick;
         dma_wr_bus <= '0'; tick;
      end procedure;

      procedure dma_read(a : integer; d : out std_logic_vector(31 downto 0)) is
      begin
         dma_addr <= to_unsigned(a, 7); dma_rd <= '1'; tick;
         dma_rd <= '0'; tick;
         d := dma_rdata;
      end procedure;

      variable v16 : std_logic_vector(15 downto 0);
      variable v8  : std_logic_vector(7 downto 0);
      variable v32 : std_logic_vector(31 downto 0);
      variable t   : integer;
   begin
      tick(5);
      reset <= '0';
      tick(5);

      -- SPU register echo, voice window, volume window, a reverb register
      spu_write(16#000#, x"1234");
      spu_write(16#1C0#, x"BEEF");
      spu_write(16#25E#, x"7001");
      spu_read(16#000#, v16); check(v16 = x"1234", "voice reg echo");
      spu_read(16#1C0#, v16); check(v16 = x"BEEF", "reverb reg echo");
      spu_read(16#25E#, v16); check(v16 = x"7001", "volume reg echo");
      spu_read(16#002#, v16); check(v16 = x"0000", "unwritten reg reads 0");
      spu_write(16#000#, x"0001");
      spu_read(16#000#, v16); check(v16 = x"0001", "re-write wins");

      -- SPUSTAT mirrors SPUCNT(5:0), nothing else
      spu_read(16#1AE#, v16); check(v16 = x"0000", "SPUSTAT after reset");
      spu_write(16#1AA#, x"C03F");
      spu_read(16#1AE#, v16); check(v16 = x"003F", "SPUSTAT mirrors SPUCNT(5:0), got " & integer'image(to_integer(unsigned(v16))));
      spu_read(16#1AA#, v16); check(v16 = x"C03F", "SPUCNT echo");
      spu_write(16#1AE#, x"FFFF");
      spu_read(16#1AE#, v16); check(v16 = x"003F", "SPUSTAT write has no effect");
      spu_write(16#1AA#, x"8000");
      spu_read(16#1AE#, v16); check(v16 = x"0000", "SPUSTAT follows SPUCNT clear");
      check(spu_dmaReq = '0', "no DMA request in stop mode");

      -- spu_tick period equals spu.vhd (768 clocks)
      tick(2000);
      check(tick_count >= 2, "spu_tick runs");
      check(tick_period = 768, "spu_tick period 768, got " & integer'image(tick_period));

      -- CD status
      cd_read(0, v8); check(v8 = x"18", "CD status power-on 0x18, got " & integer'image(to_integer(unsigned(v8))));
      cd_write(0, x"01");
      cd_read(0, v8); check(v8 = x"19", "CD status index 1");
      cd_read(1, v8); check(v8 = x"00", "CD response fifo empty");
      cd_read(2, v8); check(v8 = x"00", "CD data fifo empty");
      cd_read(3, v8); check(v8 = x"E0", "CD IRQ flag clear");
      check(cd_region_out = "10", "CD region_out passes region through");

      -- DMA4 memory -> SPU: DPCR enable ch4, SPU DMA write mode, 4 words in one block
      spu_write(16#1AA#, x"8020");
      check(spu_dmaReq = '1', "DMA request in write mode");
      dma_write(16#70#, x"00080000");        -- DPCR: channel 4 enable (bit 19)
      dma_write(16#40#, x"00001000");        -- MADR
      dma_write(16#44#, x"00010004");        -- BCR: 1 block x 4 words
      dma_write(16#48#, x"01000201");        -- CHCR: start, sync mode 1, from RAM
      t := 0;
      while t < 5000 loop
         tick; t := t + 1;
         exit when t > 50 and dmaOn = '0';
      end loop;
      dma_read(16#48#, v32);
      check(dmaOn = '0' and v32(24) = '0', "DMA4 write completes (CHCR=" & integer'image(to_integer(unsigned(v32(30 downto 0)))) & ")");
      check(dma_words_written >= 8, "DMA4 delivered the halfwords to the SPU, got " & integer'image(dma_words_written));
      report "DMA4 to SPU: " & integer'image(dma_words_written) & " halfwords in " & integer'image(t) & " cycles";

      -- DMA4 SPU -> memory: read mode
      spu_write(16#1AA#, x"8030");
      dma_write(16#40#, x"00002000");
      dma_write(16#44#, x"00010004");
      dma_write(16#48#, x"01000200");        -- CHCR: start, sync mode 1, to RAM
      t := 0;
      while t < 5000 loop
         tick; t := t + 1;
         exit when t > 50 and dmaOn = '0';
      end loop;
      dma_read(16#48#, v32);
      check(dmaOn = '0' and v32(24) = '0', "DMA4 read completes");
      check(dma_words_read >= 8, "DMA4 read pulled halfwords from the SPU, got " & integer'image(dma_words_read));
      report "DMA4 from SPU: " & integer'image(dma_words_read) & " halfwords in " & integer'image(t) & " cycles";

      report "PASS none_units";
      stop <= true;
      wait;
   end process;

end architecture;
