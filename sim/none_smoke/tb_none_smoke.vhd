-- Smoke test: psx_top_pocket (through psx_pocket_wrap) elaborates with the given generics and runs
-- CYCLES clk1x cycles with idle inputs, a zero-data RAM and no assertion failure.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.pJoypad.all;

entity tb_none_smoke is
   generic
   (
      G_SPU_IMPL : string  := "none";
      G_CD_IMPL  : string  := "none";
      G_NO_MDEC  : boolean := true;
      CYCLES     : integer := 20000
   );
end entity;

architecture sim of tb_none_smoke is

   constant NOPAD : joypad_t := (
      PadPortEnable => '0', PadPortDigital => '0', PadPortAnalog => '0', PadPortMouse => '0', PadPortGunCon => '0',
      PadPortNeGcon => '0', PadPortJustif => '0', PadPortDS => '0', PadPortStick => '0', PadPortPopn => '0',
      WheelMap => '0', ToggleDS => '0',
      KeyTriangle => '0', KeyCircle => '0', KeyCross => '0', KeySquare => '0', KeySelect => '0', KeyStart => '0',
      KeyRight => '0', KeyLeft => '0', KeyUp => '0', KeyDown => '0',
      KeyR1 => '0', KeyR2 => '0', KeyR3 => '0', KeyL1 => '0', KeyL2 => '0', KeyL3 => '0',
      -- psx_top_pocket.vhd:1038 aborts nvc for Analog1X/Y >= 0 (signed wrap in `+ 128`); 0x80 maps to 0
      Analog1X => x"80", Analog1Y => x"80", Analog2X => x"80", Analog2Y => x"80");

   signal clk1x, clk2x, clk3x, clkvid : std_logic := '0';
   signal reset : std_logic := '1';
   signal done  : boolean := false;

   signal isPaused, ram_refresh, ram_rnw, ram_ena, ram_dma, ram_cache : std_logic;
   signal ram_dataWrite, ram_dmafifo_data : std_logic_vector(31 downto 0);
   signal ram_Adr : std_logic_vector(24 downto 0);
   signal ram_cntDMA : std_logic_vector(1 downto 0);
   signal ram_be : std_logic_vector(3 downto 0);
   signal ram_dmafifo_adr : std_logic_vector(22 downto 0);
   signal ram_dmafifo_empty : std_logic;
   signal ram_done : std_logic := '0';
   signal ddr3_BURSTCNT : std_logic_vector(7 downto 0);
   signal ddr3_ADDR : std_logic_vector(27 downto 0);
   signal ddr3_DIN : std_logic_vector(63 downto 0);
   signal ddr3_BE : std_logic_vector(7 downto 0);
   signal ddr3_WE, ddr3_RD : std_logic;
   signal region_out : std_logic_vector(1 downto 0);
   signal resetFromCD, cd_hps_req : std_logic;
   signal cd_hps_lba, cd_hps_lba_sim : std_logic_vector(31 downto 0);
   signal spuram_dataWrite : std_logic_vector(31 downto 0);
   signal spuram_Adr : std_logic_vector(18 downto 0);
   signal spuram_be : std_logic_vector(3 downto 0);
   signal spuram_rnw, spuram_ena : std_logic;
   signal memcard_changed, saving_memcard, memcard1_rd, memcard1_wr : std_logic;
   signal memcard1_lba : std_logic_vector(6 downto 0);
   signal memcard1_dataOut : std_logic_vector(15 downto 0);
   signal hsync, vsync, hblank, vblank, video_ce, video_interlace : std_logic;
   signal DisplayWidth : unsigned(10 downto 0);
   signal DisplayHeight : unsigned(9 downto 0);
   signal DisplayOffsetX : unsigned(9 downto 0);
   signal DisplayOffsetY : unsigned(8 downto 0);
   signal video_r, video_g, video_b : std_logic_vector(7 downto 0);
   signal video_isPal, video_fbmode, video_fb24 : std_logic;
   signal video_hResMode : std_logic_vector(2 downto 0);
   signal video_frameindex : std_logic_vector(3 downto 0);
   signal padMode : std_logic_vector(1 downto 0);
   signal sound_out_left, sound_out_right : std_logic_vector(15 downto 0);

   signal ram_cnt : integer := 0;

begin

   clk1x <= not clk1x after 5 ns when not done;
   clk2x <= not clk2x after 2500 ps when not done;
   clk3x <= not clk3x after 1667 ps when not done;
   clkvid <= not clkvid after 5 ns when not done;

   dut : entity work.psx_pocket_wrap
   generic map (G_NO_MDEC => G_NO_MDEC, G_SPU_IMPL => G_SPU_IMPL, G_CD_IMPL => G_CD_IMPL)
   port map
   (
      clk1x => clk1x, clk2x => clk2x, clk3x => clk3x, clkvid => clkvid, reset => reset,
      isPaused => isPaused, ram_refresh => ram_refresh, ram_dataWrite => ram_dataWrite,
      ram_dataRead32 => (others => '0'), ram_Adr => ram_Adr, ram_cntDMA => ram_cntDMA, ram_be => ram_be,
      ram_rnw => ram_rnw, ram_ena => ram_ena, ram_dma => ram_dma, ram_cache => ram_cache, ram_done => ram_done,
      ram_dmafifo_adr => ram_dmafifo_adr, ram_dmafifo_data => ram_dmafifo_data,
      ram_dmafifo_empty => ram_dmafifo_empty, ram_dmafifo_read => '0',
      dma_wr => '0', dma_reqprocessed => '0', dma_data => (others => '0'),
      ddr3_BUSY => '0', ddr3_DOUT => (others => '0'), ddr3_DOUT_READY => '0',
      ddr3_BURSTCNT => ddr3_BURSTCNT, ddr3_ADDR => ddr3_ADDR, ddr3_DIN => ddr3_DIN, ddr3_BE => ddr3_BE,
      ddr3_WE => ddr3_WE, ddr3_RD => ddr3_RD,
      biosregion => "00", region => "00", region_out => region_out,
      trackinfo_data => (others => '0'), trackinfo_addr => (others => '0'), trackinfo_write => '0',
      resetFromCD => resetFromCD, cd_hps_req => cd_hps_req, cd_hps_lba => cd_hps_lba, cd_hps_lba_sim => cd_hps_lba_sim,
      cd_hps_ack => '0', cd_hps_write => '0', cd_hps_data => (others => '0'),
      spuram_dataWrite => spuram_dataWrite, spuram_Adr => spuram_Adr, spuram_be => spuram_be,
      spuram_rnw => spuram_rnw, spuram_ena => spuram_ena, spuram_dataRead => (others => '0'), spuram_done => '0',
      memcard_changed => memcard_changed, saving_memcard => saving_memcard,
      memcard1_load => '0', memcard_save => '0', memcard1_mounted => '0', memcard1_available => '0',
      memcard1_rd => memcard1_rd, memcard1_wr => memcard1_wr, memcard1_lba => memcard1_lba,
      memcard1_ack => '0', memcard1_write => '0', memcard1_addr => (others => '0'), memcard1_dataIn => (others => '0'),
      memcard1_dataOut => memcard1_dataOut, isPal => '0',
      hsync => hsync, vsync => vsync, hblank => hblank, vblank => vblank,
      DisplayWidth => DisplayWidth, DisplayHeight => DisplayHeight,
      DisplayOffsetX => DisplayOffsetX, DisplayOffsetY => DisplayOffsetY,
      video_ce => video_ce, video_interlace => video_interlace,
      video_r => video_r, video_g => video_g, video_b => video_b,
      video_isPal => video_isPal, video_fbmode => video_fbmode, video_fb24 => video_fb24,
      video_hResMode => video_hResMode, video_frameindex => video_frameindex,
      joypad1 => NOPAD, joypad2 => NOPAD, padMode => padMode,
      sound_out_left => sound_out_left, sound_out_right => sound_out_right
   );

   -- RAM answers every request with zeros two cycles later
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         ram_done <= '0';
         if (ram_ena = '1' or ram_refresh = '1') then
            ram_cnt <= 2;
         elsif (ram_cnt > 0) then
            ram_cnt <= ram_cnt - 1;
            if (ram_cnt = 1) then ram_done <= '1'; end if;
         end if;
      end if;
   end process;

   process
   begin
      wait for 100 ns;
      reset <= '0';
      for i in 1 to CYCLES loop
         wait until rising_edge(clk1x);
         assert resetFromCD = '0' or G_CD_IMPL /= "none" report "resetFromCD must stay 0" severity failure;
         assert cd_hps_req = '0' or G_CD_IMPL /= "none" report "cd_hps_req must stay 0" severity failure;
         assert spuram_ena = '0' or G_SPU_IMPL /= "none" report "spuram_ena must stay 0" severity failure;
         assert sound_out_left = x"0000" or G_SPU_IMPL /= "none" report "sound must stay 0" severity failure;
      end loop;
      report "PASS none_smoke spu=" & G_SPU_IMPL & " cd=" & G_CD_IMPL & " cycles=" & integer'image(CYCLES);
      done <= true;
      wait;
   end process;

end architecture;
