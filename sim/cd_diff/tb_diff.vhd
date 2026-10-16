-- CD differential testbench: frozen golden cd_top (library gold) against cd_pocket (library dut), same stimulus, every
-- listed output compared on every clock. Documentation: docs/pocket/CD.md, "Differential harness".
--
-- Stimulus: one CPU process (bus accesses, commands, parameter loads, data reads), an HPS model (cd_hps_*), a track
-- table loader, random ce stalls, spu_tick, option inputs. G_SUITE selects the CPU program.
-- Time compression (G_SKIP = 1): a process clamps the long delay counters of both sides at the same clock edge through
-- VHDL-2008 external names (force/release); the DUT must carry same-named counters of the same meaning
-- (cmd_delay, workDelay, driveDelay, slow_timeout, newCDCounter). The delay constants themselves run uncompressed in
-- the "realtime" suite.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std;
use std.textio.all;
use std.env.all;
library gold;
library dut;

use work.cd_diff_pkg.all;
use work.trace_cmp_pkg.all;

entity tb_diff is
   generic
   (
      G_SEED        : natural := 1;
      G_SUITE       : string  := "random";   -- directed | random | realtime | reset | smoke
      G_COUNT       : natural := 2000;       -- commands (random), episodes (directed per-block repeat)
      G_SCEN        : natural := 0;          -- realtime: scenario index
      G_SKIP        : natural := 1;          -- time compression
      G_KMAX        : natural := 1500;       -- upper bound of the compression clamp (clk1x cycles)
      G_MAXCYC      : natural := 2000000000; -- abort after this many clocks
      G_MAX_FAIL    : natural := 50;
      G_TRACE       : natural := 0;
      G_DBG_CYC     : natural := 0;
      G_DBG_PROC    : natural := 0;          -- print the sector header registers after every processDataSector
      G_DBG_IRQ     : natural := 0;          -- print the flags and response bytes of every serviced interrupt
      -- DUT amputation generics (cd_pocket); the golden is tied as the plan lists: NO_CD_PEAK forces the golden's peak registers
      -- to 0, NO_LIBCRYPT forces its libcrypt key to 0. NO_XA and FIXED_CD_TIMING are not tied (run with G_COMPARE = 0)
      G_DUT_NO_XA          : natural := 0;
      G_DUT_FIXED_CD_TIMING: natural := 0;
      G_DUT_NO_LIBCRYPT    : natural := 0;
      G_DUT_NO_CD_PEAK     : natural := 0;
      G_COMPARE     : natural := 1;          -- 0: differences are counted but do not fail the run (amputation smoke runs)          -- print internal state of both sides around this clock
      -- fault injection into one DUT output for exactly one clock; G_FAULT_SIG = -1: off
      G_FAULT_SIG   : integer := -1;
      G_FAULT_CYC   : natural := 20000
   );
end entity;

architecture arch of tb_diff is

   constant TCLK : time := 30 ns;

   signal clk : std_logic := '0';

   -- stimulus
   signal ce                : std_logic := '1';
   signal reset             : std_logic := '1';
   signal INSTANTSEEK       : std_logic := '0';
   signal FORCECDSPEED      : std_logic_vector(2 downto 0) := "000";
   signal LIMITREADSPEED    : std_logic := '0';
   signal hasCD             : std_logic := '1';
   signal LIDopen           : std_logic := '0';
   signal fastCD            : std_logic := '0';
   signal testSeek          : std_logic := '0';
   signal pauseOnCDSlow     : std_logic := '0';
   signal region            : std_logic_vector(1 downto 0) := "00";
   signal spu_tick          : std_logic := '0';
   signal mdec_idle         : std_logic := '1';
   signal bus_addr          : unsigned(3 downto 0) := (others => '0');
   signal bus_dataWrite     : std_logic_vector(7 downto 0) := (others => '0');
   signal bus_read          : std_logic := '0';
   signal bus_write         : std_logic := '0';
   signal dma_read          : std_logic := '0';
   signal cd_hps_ack        : std_logic := '0';
   signal cd_hps_write      : std_logic := '0';
   signal cd_hps_data       : std_logic_vector(15 downto 0) := (others => '0');
   signal trackinfo_data    : std_logic_vector(31 downto 0) := (others => '0');
   signal trackinfo_addr    : std_logic_vector(8 downto 0) := (others => '0');
   signal trackinfo_write   : std_logic := '0';
   signal SS_reset          : std_logic := '0';
   signal SS_DataWrite      : std_logic_vector(31 downto 0) := (others => '0');
   signal SS_Adr            : unsigned(13 downto 0) := (others => '0');
   signal SS_wren           : std_logic := '0';
   signal SS_rden           : std_logic := '0';

   -- outputs, golden (g_) and DUT (d_)
   signal g_region_out   : std_logic_vector(1 downto 0);
   signal g_pauseCD, g_Pause_idle_cd, g_fullyIdle, g_cdSlow, g_error, g_irqOut, g_cd_hps_req, g_resetFromCD, g_SS_idle : std_logic;
   signal g_LBAdisplay   : unsigned(19 downto 0);
   signal g_cd_left, g_cd_right : signed(15 downto 0);
   signal g_bus_dataRead, g_dma_readdata : std_logic_vector(7 downto 0);
   signal g_cd_hps_lba, g_cd_hps_lba_sim, g_SS_DataRead : std_logic_vector(31 downto 0);

   signal d_region_out   : std_logic_vector(1 downto 0);
   signal d_pauseCD, d_Pause_idle_cd, d_fullyIdle, d_cdSlow, d_error, d_irqOut, d_cd_hps_req, d_resetFromCD, d_SS_idle : std_logic;
   signal d_LBAdisplay   : unsigned(19 downto 0);
   signal d_cd_left, d_cd_right : signed(15 downto 0);
   signal d_bus_dataRead, d_dma_readdata : std_logic_vector(7 downto 0);
   signal d_cd_hps_lba, d_cd_hps_lba_sim, d_SS_DataRead : std_logic_vector(31 downto 0);

   -- bookkeeping
   signal armed        : boolean := false;
   signal cycle        : natural := 0;
   signal irq_count    : natural := 0;
   signal hps_busy     : std_logic := '0';
   signal hps_nodata   : std_logic := '0';   -- the HPS model answers requests with ack but never data (stall)
   signal skip_on      : boolean := false;
   signal k_cmd        : natural := 100;
   signal k_work       : natural := 100;
   signal k_drive      : natural := 100;
   signal k_slow       : natural := 100;
   signal k_newcd      : natural := 100;
   signal k_irq        : natural := 10000;   -- irqTimeout is advanced to 10000 - k_irq (10000: not at all)
   signal stall_on     : boolean := false;
   signal stall_pct    : natural := 0;
   signal stall_max    : natural := 20;
   signal cmds_done    : natural := 0;
   signal ev_cnt       : natural := 0;       -- sector events of the golden (readOnDisk), and lastReadSector at the event
   signal ev_lba       : natural := 0;
   signal flag_nz      : std_logic := '0';   -- the golden's interrupt flags are not zero
   signal quiet_cnt    : natural := 0;   -- consecutive clocks with nothing pending in the golden
   signal finished     : boolean := false;

   -- shared models
   shared variable disc : disc_t;
   shared variable rh   : rng_t;   -- hps / stall / misc
   shared variable cmp  : trace_cmp_t;

   shared variable cov : counters_t;
   constant COV_NAMES : string :=
      "cmd_beg cmd_pend err_cmd err_drive ack_pend ack_pend_sec getid proc_data proc_cdda xa_start xa_write cdda_write copy " &
      "ack_read ack_read_data drive_end ack_drive drive_ack new_cd seek_cmd seek_drive seek_play libcrypt cdda_report soft_reset " &
      "set_mode cmd_stop drive_stop irq1 irq2 irq3 irq4 irq5 pause_cd cd_slow reset_from_cd xa_eof dma_rd bus_rd bus_wr " &
      "start_reading start_playing calc_seek skip_cmd skip_work skip_drive skip_slow skip_newcd ce_stall skip_irq cd_out_nz cd_out_clamp";
   shared variable cmd_hist : counters_t;
   shared variable ep_stat  : counters_t;   -- per episode type: [2t] clocks, [2t+1] episodes

   function is_libcrypt_lba(l : natural; key : std_logic_vector(15 downto 0)) return boolean is
      type lt is array (0 to 15) of natural;
      constant a : lt := (14105, 14231, 14485, 14579, 14649, 14899, 15056, 15130, 15242, 15312, 15378, 15628, 15919, 16031, 16101, 16167);
      constant b : lt := (14110, 14236, 14490, 14584, 14654, 14904, 15061, 15135, 15247, 15317, 15383, 15633, 15924, 16036, 16106, 16172);
   begin
      for i in 0 to 15 loop
         if key(15 - i) = '1' and (l + 2 = a(i) or l + 2 = b(i)) then return true; end if;
      end loop;
      return false;
   end function;

begin

   clk <= not clk after TCLK / 2;

   gold : entity gold.cd_top
   port map
   (
      clk1x => clk, ce => ce, reset => reset,
      INSTANTSEEK => INSTANTSEEK, FORCECDSPEED => FORCECDSPEED, LIMITREADSPEED => LIMITREADSPEED, hasCD => hasCD,
      LIDopen => LIDopen, fastCD => fastCD, testSeek => testSeek, pauseOnCDSlow => pauseOnCDSlow,
      region => region, region_out => g_region_out,
      pauseCD => g_pauseCD, Pause_idle_cd => g_Pause_idle_cd, fullyIdle => g_fullyIdle, cdSlow => g_cdSlow,
      error => g_error, LBAdisplay => g_LBAdisplay, irqOut => g_irqOut,
      spu_tick => spu_tick, cd_left => g_cd_left, cd_right => g_cd_right, mdec_idle => mdec_idle,
      bus_addr => bus_addr, bus_dataWrite => bus_dataWrite, bus_read => bus_read, bus_write => bus_write,
      bus_dataRead => g_bus_dataRead, dma_read => dma_read, dma_readdata => g_dma_readdata,
      cd_hps_req => g_cd_hps_req, cd_hps_lba => g_cd_hps_lba, cd_hps_lba_sim => g_cd_hps_lba_sim,
      cd_hps_ack => cd_hps_ack, cd_hps_write => cd_hps_write, cd_hps_data => cd_hps_data,
      trackinfo_data => trackinfo_data, trackinfo_addr => trackinfo_addr, trackinfo_write => trackinfo_write,
      resetFromCD => g_resetFromCD,
      SS_reset => SS_reset, SS_DataWrite => SS_DataWrite, SS_Adr => SS_Adr, SS_wren => SS_wren, SS_rden => SS_rden,
      SS_DataRead => g_SS_DataRead, SS_idle => g_SS_idle
   );

   dut : entity dut.cd_pocket
   generic map (NO_XA => G_DUT_NO_XA /= 0, FIXED_CD_TIMING => G_DUT_FIXED_CD_TIMING /= 0, NO_LIBCRYPT => G_DUT_NO_LIBCRYPT /= 0, NO_CD_PEAK => G_DUT_NO_CD_PEAK /= 0)
   port map
   (
      clk1x => clk, ce => ce, reset => reset,
      INSTANTSEEK => INSTANTSEEK, FORCECDSPEED => FORCECDSPEED, LIMITREADSPEED => LIMITREADSPEED, hasCD => hasCD,
      LIDopen => LIDopen, fastCD => fastCD, testSeek => testSeek, pauseOnCDSlow => pauseOnCDSlow,
      region => region, region_out => d_region_out,
      pauseCD => d_pauseCD, Pause_idle_cd => d_Pause_idle_cd, fullyIdle => d_fullyIdle, cdSlow => d_cdSlow,
      error => d_error, LBAdisplay => d_LBAdisplay, irqOut => d_irqOut,
      spu_tick => spu_tick, cd_left => d_cd_left, cd_right => d_cd_right, mdec_idle => mdec_idle,
      bus_addr => bus_addr, bus_dataWrite => bus_dataWrite, bus_read => bus_read, bus_write => bus_write,
      bus_dataRead => d_bus_dataRead, dma_read => dma_read, dma_readdata => d_dma_readdata,
      cd_hps_req => d_cd_hps_req, cd_hps_lba => d_cd_hps_lba, cd_hps_lba_sim => d_cd_hps_lba_sim,
      cd_hps_ack => cd_hps_ack, cd_hps_write => cd_hps_write, cd_hps_data => cd_hps_data,
      trackinfo_data => trackinfo_data, trackinfo_addr => trackinfo_addr, trackinfo_write => trackinfo_write,
      resetFromCD => d_resetFromCD,
      SS_reset => SS_reset, SS_DataWrite => SS_DataWrite, SS_Adr => SS_Adr, SS_wren => SS_wren, SS_rden => SS_rden,
      SS_DataRead => d_SS_DataRead, SS_idle => d_SS_idle
   );

   ---------------------------------------------------------------- compare
   p_compare : process
      variable n_cmp    : natural := 0;
      variable n_meta   : natural := 0;
      variable n_idle_v : natural := 0;
      variable cyc      : natural := 0;
      -- DUT values after the optional single-clock fault
      variable v_bus    : std_logic_vector(7 downto 0);
      variable v_dma    : std_logic_vector(7 downto 0);
      variable v_irq, v_hreq, v_pause, v_pidle, v_full, v_slow, v_err, v_rfc : std_logic;
      variable v_lba    : std_logic_vector(31 downto 0);
      variable v_left, v_right : signed(15 downto 0);
      variable v_reg    : std_logic_vector(1 downto 0);
      variable v_ldisp  : unsigned(19 downto 0);
      variable f        : boolean;
      variable line_o   : line;

      procedure chk(name : string; g, d : std_logic_vector) is
      begin
         if g /= d then cmp.compare(name, cyc, g, d); end if;
      end procedure;
      procedure chk1(name : string; g, d : std_logic) is
      begin
         if g /= d then cmp.compare(name, cyc, g, d); end if;
      end procedure;
   begin
      loop
         wait until falling_edge(clk);
         cyc := cyc + 1;
         cycle <= cyc;
         if G_TRACE /= 0 and (cyc mod 4194304) = 0 then
            write(line_o, string'("PROGRESS cycles=") & integer'image(cyc) & " cmds=" & integer'image(cmds_done));
            writeline(output, line_o);
         end if;
         if armed then
            f := (G_FAULT_SIG >= 0 and cyc = G_FAULT_CYC);
            v_bus := d_bus_dataRead; v_dma := d_dma_readdata; v_irq := d_irqOut; v_hreq := d_cd_hps_req;
            v_pause := d_pauseCD; v_pidle := d_Pause_idle_cd; v_full := d_fullyIdle; v_slow := d_cdSlow; v_err := d_error;
            v_rfc := d_resetFromCD; v_lba := d_cd_hps_lba; v_left := d_cd_left; v_right := d_cd_right;
            v_reg := d_region_out; v_ldisp := d_LBAdisplay;
            if f then
               case G_FAULT_SIG is
                  when 0  => v_bus(0) := not v_bus(0);
                  when 1  => v_irq := not v_irq;
                  when 2  => v_dma(0) := not v_dma(0);
                  when 3  => v_left(0) := not v_left(0);
                  when 4  => v_right(15) := not v_right(15);
                  when 5  => v_hreq := not v_hreq;
                  when 6  => v_lba(31) := not v_lba(31);
                  when 7  => v_pause := not v_pause;
                  when 8  => v_pidle := not v_pidle;
                  when 9  => v_full := not v_full;
                  when 10 => v_slow := not v_slow;
                  when 11 => v_rfc := not v_rfc;
                  when 12 => v_reg(1) := not v_reg(1);
                  when 13 => v_ldisp(19) := not v_ldisp(19);
                  when others => v_err := not v_err;
               end case;
            end if;
            chk("bus_dataRead", g_bus_dataRead, v_bus);
            chk("dma_readdata", g_dma_readdata, v_dma);
            chk1("irqOut", g_irqOut, v_irq);
            chk("cd_left", std_logic_vector(g_cd_left), std_logic_vector(v_left));
            chk("cd_right", std_logic_vector(g_cd_right), std_logic_vector(v_right));
            chk1("cd_hps_req", g_cd_hps_req, v_hreq);
            chk("cd_hps_lba", g_cd_hps_lba, v_lba);
            chk1("pauseCD", g_pauseCD, v_pause);
            chk1("Pause_idle_cd", g_Pause_idle_cd, v_pidle);
            chk1("fullyIdle", g_fullyIdle, v_full);
            chk1("cdSlow", g_cdSlow, v_slow);
            chk1("resetFromCD", g_resetFromCD, v_rfc);
            chk("region_out", g_region_out, v_reg);
            chk("LBAdisplay", std_logic_vector(g_LBAdisplay), std_logic_vector(v_ldisp));
            chk1("error", g_error, v_err);
            n_cmp := n_cmp + 1;        -- clocks compared, 15 outputs each
            if (cyc mod 64) = 0 and (is_x(g_bus_dataRead) or is_x(g_dma_readdata) or is_x(g_irqOut) or is_x(std_logic_vector(g_cd_left)) or
               is_x(g_cd_hps_req) or is_x(g_cd_hps_lba) or is_x(g_pauseCD) or is_x(g_fullyIdle) or is_x(g_cdSlow) or
               is_x(g_resetFromCD) or is_x(g_region_out) or is_x(std_logic_vector(g_LBAdisplay))) then
               n_meta := n_meta + 1;
            end if;
            -- the DUT may call itself idle only when no HPS stream is in flight
            if d_SS_idle = '1' and d_cd_hps_req = '1' then n_idle_v := n_idle_v + 1; end if;
         end if;
         if (cmp.mismatches > G_MAX_FAIL and G_COMPARE /= 0) or cyc >= G_MAXCYC or finished then
            exit;
         end if;
      end loop;
      -- RESULT
      write(line_o, string'("RESULT cycles=") & integer'image(cyc) & " clocks=" & integer'image(n_cmp) &
            " mismatches=" & integer'image(cmp.mismatches) & " cmds=" & integer'image(cmds_done) &
            " gold_meta=" & integer'image(n_meta) & " idle_viol=" & integer'image(n_idle_v) & " ");
      if (cmp.mismatches /= 0 and G_COMPARE /= 0) or n_cmp = 0 or n_meta /= 0 or n_idle_v /= 0 or (cyc >= G_MAXCYC and not finished) then
         write(line_o, string'("FAIL"));
      else
         write(line_o, string'("PASS"));
      end if;
      writeline(output, line_o);
      write(line_o, string'("COVNAMES ") & COV_NAMES);
      writeline(output, line_o);
      write(line_o, string'("COV "));
      for i in 0 to 63 loop
         write(line_o, integer'image(cov.get(i)) & " ");
      end loop;
      writeline(output, line_o);
      write(line_o, string'("EPISODES "));
      for i in 0 to 21 loop
         write(line_o, integer'image(ep_stat.get(i)) & " ");
      end loop;
      writeline(output, line_o);
      write(line_o, string'("CMDS "));
      for i in 0 to 255 loop
         write(line_o, integer'image(cmd_hist.get(i)) & " ");
      end loop;
      writeline(output, line_o);
      if (cmp.mismatches /= 0 and G_COMPARE /= 0) or n_cmp = 0 or n_meta /= 0 or n_idle_v /= 0 or (cyc >= G_MAXCYC and not finished) then
         stop(1);
      else
         stop(0);
      end if;
      wait;
   end process;

   b_gold : block
   alias c_peakL is <<signal .tb_diff.gold.peakvolumeL : signed(15 downto 0)>>;
   alias c_peakR is <<signal .tb_diff.gold.peakvolumeR : signed(15 downto 0)>>;
   alias c_libkey_f is <<signal .tb_diff.gold.libcryptKey : std_logic_vector(15 downto 0)>>;
   alias g_cmd_delay    is <<signal .tb_diff.gold.cmd_delay : integer>>;
   alias g_workDelay    is <<signal .tb_diff.gold.workDelay : integer>>;
   alias g_driveDelay   is <<signal .tb_diff.gold.driveDelay : integer>>;
   alias g_slow_timeout is <<signal .tb_diff.gold.slow_timeout : integer>>;
   alias g_newCDCounter is <<signal .tb_diff.gold.newCDCounter : unsigned(25 downto 0)>>;
   alias g_irqTimeout   is <<signal .tb_diff.gold.irqTimeout : integer>>;
   alias d_irqTimeout   is <<signal .tb_diff.dut.irqTimeout : integer>>;
   alias d_cmd_delay    is <<signal .tb_diff.dut.cmd_delay : integer>>;
   alias d_workDelay    is <<signal .tb_diff.dut.workDelay : integer>>;
   alias d_driveDelay   is <<signal .tb_diff.dut.driveDelay : integer>>;
   alias d_slow_timeout is <<signal .tb_diff.dut.slow_timeout : integer>>;
   alias d_newCDCounter is <<signal .tb_diff.dut.newCDCounter : unsigned(25 downto 0)>>;

   alias c_beginCommand   is <<signal .tb_diff.gold.beginCommand : std_logic>>;
   alias c_newCmd         is <<signal .tb_diff.gold.newCmd : std_logic_vector(7 downto 0)>>;
   alias c_cmdPending     is <<signal .tb_diff.gold.cmdPending : std_logic>>;
   alias c_irqflag        is <<signal .tb_diff.gold.CDROM_IRQFLAG : std_logic_vector(4 downto 0)>>;
   alias c_errCmd         is <<signal .tb_diff.gold.errorResponseCmd_new : std_logic>>;
   alias c_errDrive       is <<signal .tb_diff.gold.errorResponseDrive_new : std_logic>>;
   alias c_ackPending     is <<signal .tb_diff.gold.ackPendingIRQ : std_logic>>;
   alias c_ackPendSector  is <<signal .tb_diff.gold.ackPendingSector : std_logic>>;
   alias c_getIDAck       is <<signal .tb_diff.gold.getIDAck : std_logic>>;
   alias c_procData       is <<signal .tb_diff.gold.processDataSector : std_logic>>;
   alias c_procCDDA       is <<signal .tb_diff.gold.processCDDASector : std_logic>>;
   alias c_xaStart        is <<signal .tb_diff.gold.XA_start : std_logic>>;
   alias c_xaWrite        is <<signal .tb_diff.gold.XA_write : std_logic>>;
   alias c_cddaWrite      is <<signal .tb_diff.gold.CDDA_write : std_logic>>;
   alias c_copyData       is <<signal .tb_diff.gold.copyData : std_logic>>;
   alias c_ackRead        is <<signal .tb_diff.gold.ackRead : std_logic>>;
   alias c_ackReadData    is <<signal .tb_diff.gold.ackRead_data : std_logic>>;
   alias c_ackDriveEnd    is <<signal .tb_diff.gold.ackDriveEnd : std_logic>>;
   alias c_ackDrive       is <<signal .tb_diff.gold.ackDrive : std_logic>>;
   alias c_driveAck       is <<signal .tb_diff.gold.driveAck : std_logic>>;
   alias c_newCD          is <<signal .tb_diff.gold.newCD : std_logic>>;
   alias c_seekCmd        is <<signal .tb_diff.gold.seekOnDiskCmd : std_logic>>;
   alias c_seekDrive      is <<signal .tb_diff.gold.seekOnDiskDrive : std_logic>>;
   alias c_seekPlay       is <<signal .tb_diff.gold.seekOnDiskPlay : std_logic>>;
   alias c_libkey         is <<signal .tb_diff.gold.libcryptKey : std_logic_vector(15 downto 0)>>;
   alias c_lastRead       is <<signal .tb_diff.gold.lastReadSector : integer>>;
   alias c_xaReset        is <<signal .tb_diff.gold.XA_reset : std_logic>>;
   alias c_xaEof          is <<signal .tb_diff.gold.XA_eof : std_logic>>;
   alias c_cddaOut        is <<signal .tb_diff.gold.CDDA_outcnt : integer>>;
   alias c_calcSeek       is <<signal .tb_diff.gold.calcSeekTime : std_logic>>;
   alias c_startReading   is <<signal .tb_diff.gold.startReading : std_logic>>;
   alias c_startPlaying   is <<signal .tb_diff.gold.startPlaying : std_logic>>;
   alias c_softReset      is <<signal .tb_diff.gold.softReset : std_logic>>;
   alias c_setMode        is <<signal .tb_diff.gold.setMode : std_logic>>;
   alias c_driveStopC     is <<signal .tb_diff.gold.cmdStop : std_logic>>;
   alias c_driveStop      is <<signal .tb_diff.gold.drive_stop : std_logic>>;
   alias c_readOnDisk     is <<signal .tb_diff.gold.readOnDisk : std_logic>>;
   alias c_pendIrq        is <<signal .tb_diff.gold.pendingDriveIRQ : std_logic_vector(4 downto 0)>>;
   alias c_errNext        is <<signal .tb_diff.gold.errorResponseNext_new : std_logic>>;
   alias c_ackPendNext    is <<signal .tb_diff.gold.ackPendingIRQNext : std_logic>>;

   begin
   p_ties : process
   begin
      if G_DUT_NO_CD_PEAK /= 0 then
         c_peakL <= force to_signed(0, 16);
         c_peakR <= force to_signed(0, 16);
      end if;
      if G_DUT_NO_LIBCRYPT /= 0 then
         c_libkey_f <= force x"0000";
      end if;
      wait;
   end process;
   ---------------------------------------------------------------- coverage and command bookkeeping (golden side)
   p_cov : process
      variable irq_n : natural := 0;
      variable last_hreq : std_logic := '0';
      variable last_newcd : std_logic := '0';
      variable last_slow : std_logic := '0';
   begin
      wait until rising_edge(clk);
      if armed then
         if c_beginCommand = '1' then
            cov.inc(0);
            cmd_hist.inc(to_integer(unsigned(c_newCmd)));
            cmds_done <= cmds_done + 1;
            if c_cmdPending = '1' then cov.inc(1); end if;
         end if;
         if c_errCmd = '1' then cov.inc(2); end if;
         if c_errDrive = '1' then cov.inc(3); end if;
         if c_ackPending = '1' then cov.inc(4); end if;
         if c_ackPendSector = '1' then cov.inc(5); end if;
         if c_getIDAck = '1' then cov.inc(6); end if;
         if c_procData = '1' then cov.inc(7); end if;
         if c_procCDDA = '1' then cov.inc(8); end if;
         if c_xaStart = '1' then cov.inc(9); end if;
         if c_xaWrite = '1' then cov.inc(10); end if;
         if c_cddaWrite = '1' then cov.inc(11); end if;
         if c_copyData = '1' then cov.inc(12); end if;
         if c_ackRead = '1' then cov.inc(13); end if;
         if c_ackReadData = '1' then cov.inc(14); end if;
         if c_ackDriveEnd = '1' then cov.inc(15); end if;
         if c_ackDrive = '1' then cov.inc(16); end if;
         if c_driveAck = '1' then cov.inc(17); end if;
         if c_newCD = '1' and last_newcd = '0' then cov.inc(18); end if;
         last_newcd := c_newCD;
         if c_seekCmd = '1' then cov.inc(19); end if;
         if c_seekDrive = '1' then cov.inc(20); end if;
         if c_seekPlay = '1' then cov.inc(21); end if;
         if g_cd_hps_req = '1' and last_hreq = '0' then
            if is_libcrypt_lba(c_lastRead, c_libkey) then cov.inc(22); end if;
         end if;
         last_hreq := g_cd_hps_req;
         if c_cddaOut = 8 then cov.inc(23); end if;
         if c_softReset = '1' then cov.inc(24); end if;
         if c_setMode = '1' then cov.inc(25); end if;
         if c_driveStopC = '1' then cov.inc(26); end if;
         if c_driveStop = '1' then cov.inc(27); end if;
         if g_irqOut = '1' then
            irq_count <= irq_count + 1;
            case to_integer(unsigned(c_irqflag)) is
               when 1 => cov.inc(28);
               when 2 => cov.inc(29);
               when 3 => cov.inc(30);
               when 4 => cov.inc(31);
               when 5 => cov.inc(32);
               when others => null;
            end case;
         end if;
         if g_pauseCD = '1' then cov.inc(33); end if;
         if g_cdSlow = '1' and last_slow = '0' then cov.inc(34); end if;
         last_slow := g_cdSlow;
         if g_resetFromCD = '1' then cov.inc(35); end if;
         if c_xaEof = '1' then cov.inc(36); end if;
         if dma_read = '1' then cov.inc(37); end if;
         if bus_read = '1' then cov.inc(38); end if;
         if bus_write = '1' then cov.inc(39); end if;
         if c_startReading = '1' then cov.inc(40); end if;
         if c_startPlaying = '1' then cov.inc(41); end if;
         if c_calcSeek = '1' then cov.inc(42); end if;
         if g_cd_left /= 0 or g_cd_right /= 0 then cov.inc(50); end if;
         if g_cd_left = x"7FFF" or g_cd_left = x"8000" or g_cd_right = x"7FFF" or g_cd_right = x"8000" then cov.inc(51); end if;
         if c_readOnDisk = '1' then ev_cnt <= ev_cnt + 1; ev_lba <= c_lastRead; end if;
         if c_irqflag /= "00000" then flag_nz <= '1'; else flag_nz <= '0'; end if;
         if g_fullyIdle = '1' and c_pendIrq = "00000" and c_cddaOut = 0 and c_errNext = '0' and c_ackPendNext = '0' and c_ackPending = '0' and
            g_irqOut = '0' and c_beginCommand = '0' then
            quiet_cnt <= quiet_cnt + 1;
         else
            quiet_cnt <= 0;
         end if;
      end if;
   end process;

   -- debug: internal state of both sides around G_DBG_CYC
   p_dbg : process
      alias gb is <<signal .tb_diff.gold.cmd_busy : std_logic>>;
      alias db is <<signal .tb_diff.dut.cmd_busy : std_logic>>;
      alias gw is <<signal .tb_diff.gold.working : std_logic>>;
      alias dw is <<signal .tb_diff.dut.working : std_logic>>;
      alias gdb is <<signal .tb_diff.gold.driveBusy : std_logic>>;
      alias ddb is <<signal .tb_diff.dut.driveBusy : std_logic>>;
      alias gdd is <<signal .tb_diff.gold.driveDelay : integer>>;
      alias ddd is <<signal .tb_diff.dut.driveDelay : integer>>;
      alias gcd is <<signal .tb_diff.gold.cmd_delay : integer>>;
      alias dcd is <<signal .tb_diff.dut.cmd_delay : integer>>;
      alias gsm is <<signal .tb_diff.gold.startMotor : std_logic>>;
      alias dsm is <<signal .tb_diff.dut.startMotor : std_logic>>;
      alias gcm is <<signal .tb_diff.gold.cmdStartMotor : std_logic>>;
      alias dcm is <<signal .tb_diff.dut.cmdStartMotor : std_logic>>;
      alias gnc is <<signal .tb_diff.gold.nextCmd : std_logic_vector(7 downto 0)>>;
      alias dnc is <<signal .tb_diff.dut.nextCmd : std_logic_vector(7 downto 0)>>;
      alias gro is <<signal .tb_diff.gold.readOnDisk_buffer : std_logic>>;
      alias dro is <<signal .tb_diff.dut.readOnDisk_buffer : std_logic>>;
      variable l : line;
   begin
      wait until falling_edge(clk);
      if G_DBG_CYC /= 0 and cycle + 12 >= G_DBG_CYC and cycle <= G_DBG_CYC + 6 then
         write(l, string'("DBG cyc=") & integer'image(cycle) & " cmd_busy g/d=" & std_logic'image(gb) & std_logic'image(db) &
               " working=" & std_logic'image(gw) & std_logic'image(dw) & " driveBusy=" & std_logic'image(gdb) & std_logic'image(ddb) &
               " roBuf=" & std_logic'image(gro) & std_logic'image(dro) &   " cmd_delay=" & integer'image(gcd) & "/" & integer'image(dcd) & " sm=" & std_logic'image(gsm) & std_logic'image(dsm) & " csm=" & std_logic'image(gcm) & std_logic'image(dcm) & " nc=" & to_hstring(gnc) & "/" & to_hstring(dnc) & " driveDelay=" & integer'image(gdd) & "/" & integer'image(ddd) & " fullyIdle=" & std_logic'image(g_fullyIdle) & std_logic'image(d_fullyIdle));
         writeline(output, l);
      end if;
   end process;
   b_dbg : block
   begin
   p_dbg2 : process
      alias gh  is <<signal .tb_diff.gold.header : std_logic_vector(31 downto 0)>>;
      alias gsh is <<signal .tb_diff.gold.subheader : std_logic_vector(31 downto 0)>>;
      alias gmr is <<signal .tb_diff.gold.modeReg : std_logic_vector(7 downto 0)>>;
      alias gpd is <<signal .tb_diff.gold.processDataSector : std_logic>>;
      alias gxw is <<signal .tb_diff.gold.XA_write : std_logic>>;
      alias gxs is <<signal .tb_diff.gold.XaFilterFile : std_logic_vector(7 downto 0)>>;
      alias gxc is <<signal .tb_diff.gold.XaFilterChannel : std_logic_vector(7 downto 0)>>;
      alias gxset is <<signal .tb_diff.gold.XaCurrentSet : std_logic>>;
      alias gbc is <<signal .tb_diff.gold.beginCommand : std_logic>>;
      alias gnc is <<signal .tb_diff.gold.newCmd : std_logic_vector(7 downto 0)>>;
      alias gpc is <<signal .tb_diff.gold.cmdPending : std_logic>>;
      alias gfc is <<signal .tb_diff.gold.fifoParamCount : integer>>;
      alias gsm is <<signal .tb_diff.gold.setMode : std_logic>>;
      variable l : line;
      variable n : natural := 0;
   begin
      wait until falling_edge(clk);
      if G_DBG_PROC = 2 and gbc = '1' then
         write(l, string'("CMD cyc=") & integer'image(cycle) & " cmd=" & to_hstring(gnc) & " pending=" & std_logic'image(gpc) & " params=" & integer'image(gfc));
         writeline(output, l);
      end if;
      if G_DBG_PROC = 2 and gsm = '1' then
         write(l, string'("SETMODE cyc=") & integer'image(cycle));
         writeline(output, l);
      end if;
      if G_DBG_PROC = 1 then
         if gpd = '1' then n := 12; end if;
         if n > 0 then
            n := n - 1;
            write(l, string'("PROC cyc=") & integer'image(cycle) & " pd=" & std_logic'image(gpd) & " mode=" & to_hstring(gmr) & " hdr=" & to_hstring(gh) & " sub=" & to_hstring(gsh) &
                  " xaw=" & std_logic'image(gxw) & " filt=" & to_hstring(gxs) & to_hstring(gxc) & " cur=" & std_logic'image(gxset));
            writeline(output, l);
         end if;
      end if;
   end process;

   end block;

   ---------------------------------------------------------------- time compression
   p_skip : process
      variable fc, fw, fd, fs, fn, fi : boolean;
   begin
      wait until falling_edge(clk);
      if skip_on and armed then
         fc := g_cmd_delay > k_cmd;
         fw := g_workDelay > k_work;
         fd := g_driveDelay > k_drive;
         fs := g_slow_timeout > k_slow;
         fn := to_integer(g_newCDCounter) > k_newcd;
         fi := k_irq < 10000 and g_irqTimeout < 10000 - k_irq;
         if fc or fw or fd or fs or fn or fi then
            if fc then g_cmd_delay <= force k_cmd; d_cmd_delay <= force k_cmd; cov.inc(43); end if;
            if fw then g_workDelay <= force k_work; d_workDelay <= force k_work; cov.inc(44); end if;
            if fd then g_driveDelay <= force k_drive; d_driveDelay <= force k_drive; cov.inc(45); end if;
            if fs then g_slow_timeout <= force k_slow; d_slow_timeout <= force k_slow; cov.inc(46); end if;
            if fn then
               g_newCDCounter <= force to_unsigned(k_newcd, 26); d_newCDCounter <= force to_unsigned(k_newcd, 26);
               cov.inc(47);
            end if;
            if fi then g_irqTimeout <= force 10000 - k_irq; d_irqTimeout <= force 10000 - k_irq; cov.inc(49); end if;
            wait until rising_edge(clk);
            wait for 1 ns;
            if fi then g_irqTimeout <= release; d_irqTimeout <= release; end if;
            if fc then g_cmd_delay <= release; d_cmd_delay <= release; end if;
            if fw then g_workDelay <= release; d_workDelay <= release; end if;
            if fd then g_driveDelay <= release; d_driveDelay <= release; end if;
            if fs then g_slow_timeout <= release; d_slow_timeout <= release; end if;
            if fn then g_newCDCounter <= release; d_newCDCounter <= release; end if;
         end if;
      end if;
   end process;

   end block;

   ---------------------------------------------------------------- spu tick, ce stalls
   p_tick : process
      variable n : natural := 0;
   begin
      wait until rising_edge(clk);
      n := n + 1;
      spu_tick <= '0';
      if n >= 768 then n := 0; spu_tick <= '1'; end if;
   end process;

   p_ce : process
      variable left : natural := 0;
   begin
      wait until rising_edge(clk);
      if left > 0 then
         left := left - 1;
         if left = 0 then ce <= '1'; end if;
      elsif stall_on and armed and rh.rnd(1000) < stall_pct then
         left := 1 + rh.rnd(stall_max);
         ce <= '0';
         cov.inc(48);
      end if;
   end process;

   ---------------------------------------------------------------- HPS model
   p_hps : process
      variable lba   : natural;
      variable idx   : natural;
      variable wait_n: natural;
      variable w     : std_logic_vector(31 downto 0);
      variable gap   : natural;
      variable mode  : natural;
   begin
      cd_hps_ack <= '0'; cd_hps_write <= '0'; hps_busy <= '0';
      loop
         wait until rising_edge(clk);
         if g_cd_hps_req = '1' then
            hps_busy <= '1';
            lba := to_integer(unsigned(g_cd_hps_lba(19 downto 0)));   -- 20 bits: the sector generator multiplies it by 1024
            mode := rh.rnd(10);
            -- request latency
            case rh.rnd(8) is
               when 0 => wait_n := rh.rnd(2000);
               when 1 | 2 => wait_n := rh.rnd(40);
               when others => wait_n := 3 + rh.rnd(6);
            end case;
            for i in 1 to wait_n loop
               wait until rising_edge(clk);
            end loop;
            if g_cd_hps_req = '1' then
               cd_hps_ack <= '1';
               for i in 1 to 3 loop wait until rising_edge(clk); end loop;
               while hps_nodata = '1' loop wait until rising_edge(clk); end loop;   -- a stalled HPS answers late
               if true then
                  idx := 0;
                  while idx < 588 loop
                     w := disc.sector_word(lba, idx);
                     -- low half, then high half, at a random gap
                     for h in 0 to 1 loop
                        cd_hps_write <= '1';
                        if h = 0 then cd_hps_data <= w(15 downto 0); else cd_hps_data <= w(31 downto 16); end if;
                        wait until rising_edge(clk);
                        cd_hps_write <= '0';
                        case mode is
                           when 0 => gap := rh.rnd(4);
                           when 1 | 2 | 3 | 4 => gap := 0;
                           when 5 => gap := rh.rnd(24);
                           when others => gap := h mod 2;
                        end case;
                        if mode = 5 and rh.rnd(400) = 0 then gap := 100 + rh.rnd(300); end if;
                        for i in 1 to gap loop wait until rising_edge(clk); end loop;
                     end loop;
                     idx := idx + 1;
                  end loop;
                  for i in 1 to 3 loop wait until rising_edge(clk); end loop;
               end if;
               cd_hps_ack <= '0';
            end if;
            hps_busy <= '0';
            wait until rising_edge(clk);
         end if;
      end loop;
   end process;

   ---------------------------------------------------------------- CPU program
   p_cpu : process
      variable r      : rng_t;
      type par_arr is array (0 to 15) of natural;
      variable pa     : par_arr := (others => 0);
      variable v      : natural;
      variable irq_seen : natural := 0;
      variable nparams  : natural := 0;       -- parameters in the FIFO as the CPU sees it

      procedure cyc(n : natural) is
      begin
         for i in 1 to n loop wait until falling_edge(clk); end loop;
      end procedure;

      procedure bus_wr(a, d : natural) is
      begin
         while ce /= '1' loop wait until falling_edge(clk); end loop;
         bus_addr <= to_unsigned(a, 4); bus_dataWrite <= std_logic_vector(to_unsigned(d, 8)); bus_write <= '1';
         wait until falling_edge(clk);
         bus_write <= '0';
      end procedure;

      procedure bus_rd(a : natural; variable d : out natural) is
      begin
         while ce /= '1' loop wait until falling_edge(clk); end loop;
         bus_addr <= to_unsigned(a, 4); bus_read <= '1';
         wait until falling_edge(clk);
         bus_read <= '0';
         wait until falling_edge(clk);
         d := to_integer(unsigned(g_bus_dataRead));
      end procedure;

      procedure set_index(i : natural) is begin bus_wr(0, i); end procedure;

      procedure wait_ce(n : natural) is   -- n clocks with ce high
         variable k : natural := 0;
      begin
         while k < n loop
            wait until falling_edge(clk);
            if ce = '1' then k := k + 1; end if;
         end loop;
      end procedure;

      -- a short random think time between CPU accesses
      procedure think is
      begin
         case r.rnd(12) is
            when 0 => cyc(r.rnd(30));
            when 1 => cyc(r.rnd(300));
            when others => null;
         end case;
      end procedure;

      procedure pick_k is
      begin
         case r.rnd(10) is
            when 0 => k_cmd <= 6 + r.rnd(40);
            when 1 | 2 | 3 => k_cmd <= 40 + r.rnd(200);
            when 4 | 5 | 6 => k_cmd <= 100 + r.rnd(400);
            when 7 | 8 => k_cmd <= 300 + r.rnd(1000);
            when others => k_cmd <= 8000 + r.rnd(400);
         end case;
         case r.rnd(8) is
            when 0 => k_work <= 3 + r.rnd(20);
            when 1 | 2 | 3 => k_work <= 12 + r.rnd(150);
            when 4 | 5 => k_work <= 100 + r.rnd(500);
            when others => k_work <= 200 + r.rnd(G_KMAX);
         end case;
         case r.rnd(8) is
            when 0 => k_drive <= 20 + r.rnd(100);
            when 1 | 2 => k_drive <= 100 + r.rnd(300);
            when 3 | 4 | 5 => k_drive <= 500 + r.rnd(2500);
            when 6 => k_drive <= 8100 + r.rnd(200);
            when others => k_drive <= 1000 + r.rnd(G_KMAX);
         end case;
         k_slow <= 50 + r.rnd(2000);
         case r.rnd(6) is
            when 0 => k_irq <= 10000;
            when 1 | 2 => k_irq <= 10 + r.rnd(60);
            when 3 => k_irq <= 100 + r.rnd(900);
            when others => k_irq <= 1000 + r.rnd(2500);
         end case;
         k_newcd <= 40 + r.rnd(300);
      end procedure;

      -- reset exactly as the top sequences it: reset_in high, SS_reset two clocks, reset_intern 61 clocks
      procedure do_reset is
      begin
         wait until falling_edge(clk);
         reset <= '1';
         cyc(2 + r.rnd(6));
         reset <= '0'; SS_reset <= '1';
         cyc(2);
         SS_reset <= '0'; reset <= '1';
         cyc(61);
         reset <= '0';
         nparams := 0;
         cyc(2);
         -- the BIOS enables the interrupts first; some episodes leave them off
         if r.rnd(8) /= 0 then set_index(1); bus_wr(2, 31); set_index(0); end if;
      end procedure;

      procedure load_disc(kind : natural; spaced : boolean) is
         variable n   : natural;
         variable key : natural;
         variable order : natural;
         variable wi  : natural;
         variable a   : natural;
      begin
         case r.rnd(6) is
            when 0 => key := 0;
            when 1 => key := 65535;
            when others => key := r.rnd(65536);
         end case;
         disc.randomize(kind, r.rnd(16777216), key, r.rnd(4), r.rnd(2));
         n := disc.words;
         order := r.rnd(4);
         for i in 0 to n - 1 loop
            if order = 1 then wi := (n - 1) - i;
            elsif order = 2 then wi := (i * 7) mod n;   -- n is never a multiple of 7 with gcd problems: checked below
            else wi := i;
            end if;
            a := disc.table_addr(wi);
            wait until falling_edge(clk);
            trackinfo_addr <= std_logic_vector(to_unsigned(a, 9));
            trackinfo_data <= disc.table_word(wi);
            trackinfo_write <= '1';
            wait until falling_edge(clk);
            trackinfo_write <= '0';
            if spaced then cyc(r.rnd(4)); end if;
         end loop;
         -- gcd(7, n) = 7 would skip words: fill the ones that order 2 missed
         if order = 2 and (n mod 7) = 0 then
            for i in 0 to n - 1 loop
               a := disc.table_addr(i);
               wait until falling_edge(clk);
               trackinfo_addr <= std_logic_vector(to_unsigned(a, 9));
               trackinfo_data <= disc.table_word(i);
               trackinfo_write <= '1';
               wait until falling_edge(clk);
               trackinfo_write <= '0';
            end loop;
         end if;
      end procedure;

      procedure push_param(b : natural) is
      begin
         set_index(0);
         bus_wr(2, b);
         nparams := nparams + 1;
      end procedure;

      procedure send_cmd(cmd : natural; np : natural) is
      begin
         if nparams > 16 - np then
            set_index(1); bus_wr(3, 64); set_index(0);   -- CLRPRM does nothing in the golden; the FIFO is cleared by the command
            nparams := 0;
         end if;
         for i in 0 to np - 1 loop
            push_param(pa(i));
         end loop;
         set_index(0);
         bus_wr(1, cmd);
         nparams := 0;
      end procedure;

      -- wait for the golden's next irqOut pulse; false after a timeout (clocks)
      procedure wait_irq(limit : natural; variable got : out boolean) is
         variable k : natural := 0;
      begin
         got := false;
         while k < limit loop
            if irq_count /= irq_seen or flag_nz = '1' then
               got := true;
               exit;
            end if;
            exit when quiet_cnt >= 24 and k >= 12;   -- nothing is pending (a command takes a few clocks to show): no interrupt will come
            wait until falling_edge(clk);
            k := k + 1;
         end loop;
      end procedure;

      -- read the IRQ flags, all response bytes, acknowledge
      procedure service_irq(ackmode : natural) is
         variable fl, st, b, n : natural;
         variable resp : line;
      begin
         irq_seen := irq_count;
         think;
         set_index(1);
         bus_rd(3, fl);
         set_index(r.rnd(4));
         n := 0;
         loop
            bus_rd(0, st);
            exit when (st / 32) mod 2 = 0 or n >= 18;
            bus_rd(1, b);
            if G_DBG_IRQ /= 0 then write(resp, " " & to_hstring(to_unsigned(b, 8))); end if;
            n := n + 1;
            if r.rnd(16) = 0 then think; end if;
            exit when r.rnd(40) = 0;
         end loop;
         if G_DBG_IRQ /= 0 then
            if resp = null then write(resp, string'(" -")); end if;
            report "IRQ int=" & integer'image(fl mod 8) & " resp" & resp.all severity note;
            deallocate(resp);
         end if;
         set_index(1);
         case ackmode is
            when 0 => bus_wr(3, 31);
            when 1 => bus_wr(3, fl);
            when 2 => bus_wr(3, 31 + 64);
            when 3 => bus_wr(3, r.rnd(32));
            when others => bus_wr(3, 31);
         end case;
         set_index(0);
      end procedure;

      -- INT1 handling: ask for the data and read it
      procedure data_xfer(mode : natural; n : natural) is
         variable d : natural;
      begin
         set_index(0);
         bus_wr(3, 128);
         if mode = 0 then
            for i in 1 to n loop
               bus_rd(2, d);
               if r.rnd(64) = 0 then think; end if;
            end loop;
         elsif mode = 1 then
            while ce /= '1' loop wait until falling_edge(clk); end loop;
            dma_read <= '1';
            cyc(n);
            dma_read <= '0';
            cyc(1);
         else
            for i in 1 to n loop
               if r.rnd(3) = 0 then
                  dma_read <= '1'; cyc(1 + r.rnd(4)); dma_read <= '0';
               else
                  bus_rd(2, d);
               end if;
            end loop;
         end if;
         if r.rnd(3) = 0 then set_index(0); bus_wr(3, 0); end if;
      end procedure;

      procedure serve(maxirq : natural; limit : natural; datamode : natural) is
         variable got : boolean;
         variable k   : natural := 0;
         variable fl, sel : natural;
      begin
         while k < maxirq loop
            wait_irq(limit, got);
            exit when not got;
            k := k + 1;
            -- the CPU may be slow to acknowledge
            if r.rnd(12) = 0 then cyc(r.rnd(1500)); end if;
            if r.rnd(250) = 0 then cyc(10000 + r.rnd(5000)); end if;
            irq_seen := irq_count;
            set_index(1);
            bus_rd(3, fl);
            if datamode /= 9 and (fl mod 32) = 1 then
               service_irq(0);
               case datamode is
                  when 0 => null;
                  when 1 => data_xfer(0, 1 + r.rnd(40));
                  when 2 => data_xfer(1, 2340 + r.rnd(2));
                  when 3 => data_xfer(0, 64 + r.rnd(300));
                  when 4 => data_xfer(2, 1 + r.rnd(2340));
                  when others => data_xfer(1 + r.rnd(2), 1 + r.rnd(3000));
               end case;
            else
               service_irq(r.rnd(6));
            end if;
         end loop;
      end procedure;

      procedure fix_k is
      begin
         if G_SKIP /= 0 then skip_on <= true; else skip_on <= false; end if;
      end procedure;

      -- parameter set-up helpers
      procedure set_msf(m, s, f : natural) is
      begin
         pa(0) := to_bcd(m); pa(1) := to_bcd(s); pa(2) := to_bcd(f);
      end procedure;

      procedure random_loc is
         variable l : natural;
         variable m : natural;
      begin
         case r.rnd(10) is
            when 0 => l := lba_of(3, 8, 3) + r.rnd(20);           -- libcrypt area
            when 1 => l := lba_of(3, 20, 0) + r.rnd(15);
            when 2 => l := r.rnd(400);
            when 3 | 4 => l := disc.track_start(1 + r.rnd(disc.track_count)) + r.rnd(300);
            when 5 => l := disc.track_end(1 + r.rnd(disc.track_count)) - r.rnd(8);
            when 6 => l := disc.total_lba - r.rnd(5);
            when 7 => l := disc.total_lba + r.rnd(10);
            when others => l := r.rnd(disc.total_lba + 1);
         end case;
         if r.rnd(40) = 0 then
            pa(0) := r.rnd(10) * 16 + r.rnd(16); pa(1) := r.rnd(10) * 16 + r.rnd(16); pa(2) := r.rnd(10) * 16 + r.rnd(16);   -- invalid BCD digits (high nibble <= 9 keeps the LBA inside 19 bits)
         else
            m := l / 4500;
            set_msf(m mod 100, (l / 75) mod 60, l mod 75);
         end if;
      end procedure;

      impure function rand_mode return natural is
      begin
         case r.rnd(8) is
            when 0 => return 16#20#;
            when 1 => return 16#A0#;
            when 2 => return 16#60# + r.rnd(2) * 128;
            when 3 => return 16#48# + r.rnd(2) * 128;
            when 4 => return r.rnd(256);
            when 5 => return 16#05# + r.rnd(2) * 128 + r.rnd(2) * 2;
            when 6 => return 16#01# + r.rnd(2) * 128;
            when others => return 16#00# + r.rnd(2) * 128 + r.rnd(2) * 32;
         end case;
      end function;

      -- command number and its natural parameter count
      function nat_params(c : natural) return natural is
      begin
         case c is
            when 16#02# => return 3;
            when 16#0D# => return 2;
            when 16#0E# | 16#12# | 16#14# | 16#19# => return 1;
            when 16#1D# => return 2;
            when 16#1F# => return 6;
            when others => return 0;
         end case;
      end function;

      procedure make_params(c : natural) is
      begin
         pa := (others => 0);
         case c is
            when 16#02# | 16#03# => random_loc;
            when 16#0D# => pa(0) := r.rnd(4); pa(1) := r.rnd(4); if r.rnd(10) = 0 then pa(1) := 255; end if;
            when 16#0E# => pa(0) := rand_mode;
            when 16#12# => pa(0) := 1 + r.rnd(2);
            when 16#14# => pa(0) := to_bcd(r.rnd(disc.track_count + 2));
            when 16#19# =>
               case r.rnd(7) is
                  when 0 => pa(0) := 16#04#;
                  when 1 => pa(0) := 16#05#;
                  when 2 | 3 => pa(0) := 16#20#;
                  when 4 | 5 => pa(0) := 16#22#;
                  when others => pa(0) := r.rnd(256);
               end case;
            when others =>
               for i in 0 to 15 loop pa(i) := r.rnd(256); end loop;
         end case;
      end procedure;

      impure function pick_cmd return natural is
         variable x : natural;
      begin
         x := r.rnd(100);
         if x < 5 then return 16#01#;
         elsif x < 12 then return 16#02#;
         elsif x < 15 then return 16#03#;
         elsif x < 17 then return 16#04# + r.rnd(2);
         elsif x < 24 then return 16#06# + r.rnd(2) * 21;    -- ReadN / ReadS
         elsif x < 26 then return 16#07#;
         elsif x < 29 then return 16#08#;
         elsif x < 34 then return 16#09#;
         elsif x < 36 then return 16#0A#;
         elsif x < 38 then return 16#0B# + r.rnd(2);
         elsif x < 41 then return 16#0D#;
         elsif x < 46 then return 16#0E#;
         elsif x < 48 then return 16#0F#;
         elsif x < 51 then return 16#10#;
         elsif x < 54 then return 16#11#;
         elsif x < 55 then return 16#12#;
         elsif x < 57 then return 16#13#;
         elsif x < 60 then return 16#14#;
         elsif x < 65 then return 16#15# + r.rnd(2);
         elsif x < 67 then return 16#17# + r.rnd(2);
         elsif x < 73 then return 16#19#;
         elsif x < 77 then return 16#1A#;
         elsif x < 78 then return 16#1C#;
         elsif x < 79 then return 16#1D#;
         elsif x < 81 then return 16#1E#;
         elsif x < 82 then return 16#1F#;
         elsif x < 84 then return 16#00#;
         elsif x < 90 then return 16#20# + r.rnd(224);
         else return r.rnd(32);
         end if;
      end function;

      procedure pick_options is
      begin
         if r.rnd(2) = 0 then
            INSTANTSEEK <= '0'; FORCECDSPEED <= "000"; LIMITREADSPEED <= '0'; fastCD <= '0'; testSeek <= '0'; pauseOnCDSlow <= '0';
         else
            INSTANTSEEK <= '1' when r.rnd(4) = 0 else '0';
            FORCECDSPEED <= std_logic_vector(to_unsigned(r.rnd(8), 3));
            LIMITREADSPEED <= '1' when r.rnd(4) = 0 else '0';
            fastCD <= '1' when r.rnd(5) = 0 else '0';
            testSeek <= '1' when r.rnd(4) = 0 else '0';
            pauseOnCDSlow <= '1' when r.rnd(3) = 0 else '0';
         end if;
         hasCD <= '0' when r.rnd(12) = 0 else '1';
         LIDopen <= '1' when r.rnd(30) = 0 else '0';
         mdec_idle <= '0' when r.rnd(5) = 0 else '1';
         region <= std_logic_vector(to_unsigned(r.rnd(4), 2));
      end procedure;

      -- one command with its parameters and the service of its interrupts
      procedure one_cmd(c : natural; np : natural; maxirq : natural; datamode : natural) is
      begin
         send_cmd(c, np);
         serve(maxirq, 6000 + 3 * k_cmd + 2 * k_work + k_drive, datamode);
      end procedure;

      procedure good_cmd(c : natural; maxirq : natural; datamode : natural) is
      begin
         make_params(c);
         one_cmd(c, nat_params(c), maxirq, datamode);
      end procedure;

      -- episodes ----------------------------------------------------------------------------------------------
      procedure ep_simple is
         variable c : natural;
      begin
         c := pick_cmd;
         make_params(c);
         case r.rnd(6) is
            when 0 => one_cmd(c, r.rnd(5), 2, 1);                -- any parameter count
            when 1 => one_cmd(c, 0, 2, 1);
            when 2 => one_cmd(c, nat_params(c) + 1, 2, 1);
            when others => one_cmd(c, nat_params(c), 1 + r.rnd(3), r.rnd(6));
         end case;
      end procedure;

      procedure ep_read is
         variable n, dm : natural;
         variable c : natural;
      begin
         if r.rnd(3) = 0 then good_cmd(16#0E#, 1, 9); end if;
         if r.rnd(4) /= 0 then good_cmd(16#02#, 1, 9); end if;
         if r.rnd(6) = 0 then good_cmd(16#0D#, 1, 9); end if;
         c := 16#06# + r.rnd(2) * 21;
         one_cmd(c, 0, 1, 9);
         n := 1 + r.rnd(4);
         dm := r.rnd(7);
         for i in 1 to n loop
            serve(1, 12000 + 2 * k_drive, dm);
            if r.rnd(10) = 0 then dm := r.rnd(7); end if;
            if r.rnd(25) = 0 then good_cmd(16#10#, 1, 9); end if;
            if r.rnd(25) = 0 then good_cmd(16#11#, 1, 9); end if;
            if r.rnd(40) = 0 then good_cmd(16#01#, 1, 9); end if;
            if r.rnd(60) = 0 then good_cmd(16#0E#, 1, 9); end if;
         end loop;
         case r.rnd(5) is
            when 0 => one_cmd(16#09#, 0, 2, 9);
            when 1 => one_cmd(16#08#, 0, 2, 9);
            when 2 => one_cmd(16#15# + r.rnd(2), 0, 2, 9);
            when others => null;
         end case;
      end procedure;

      procedure ep_play is
         variable n : natural;
      begin
         good_cmd(16#0E#, 1, 9);
         if r.rnd(3) = 0 then pa(0) := 16#05#; one_cmd(16#0E#, 1, 1, 9); end if;
         if r.rnd(2) = 0 then good_cmd(16#02#, 1, 9); end if;
         pa := (others => 0);
         if r.rnd(2) = 0 then pa(0) := to_bcd(1 + r.rnd(disc.track_count)); one_cmd(16#03#, 1, 2, 9); else one_cmd(16#03#, 0, 2, 9); end if;
         n := 1 + r.rnd(4);
         for i in 1 to n loop
            serve(1, 3500 + 2 * k_drive, 9);          -- no interrupt unless the report mode is on
            if r.rnd(6) = 0 then
               one_cmd(16#04# + r.rnd(2), 0, 1, 9);
            end if;
            if r.rnd(8) = 0 then good_cmd(16#11#, 1, 9); end if;
            -- some time of silence so that the CDDA FIFO and the volume stage run
            if r.rnd(4) = 0 then cyc(r.rnd(3000)); end if;
         end loop;
         if r.rnd(2) = 0 then one_cmd(16#09#, 0, 2, 9); end if;
      end procedure;

      procedure ep_chaos is
         variable n, a, d : natural;
         variable rv : natural;
      begin
         n := 5 + r.rnd(60);
         for i in 1 to n loop
            a := r.rnd(4); d := r.rnd(256);
            case r.rnd(8) is
               when 0 => set_index(r.rnd(4));
               when 1 | 2 => bus_wr(a, d);
               when 3 | 4 => bus_rd(a, rv);
               when 5 =>
                  dma_read <= '1'; cyc(1 + r.rnd(20)); dma_read <= '0';
               when 6 => cyc(r.rnd(2000));
               when others => bus_wr(a, r.rnd(4) * 32 + 31 * r.rnd(2));
            end case;
            if r.rnd(8) = 0 then cyc(r.rnd(100)); end if;
         end loop;
         nparams := 8;      -- unknown
         if r.rnd(2) = 0 then
            set_index(0); bus_wr(1, 16#01#);
            nparams := 0;
            serve(1, 8000, 9);
         end if;
         nparams := 0;
         irq_seen := irq_count;
      end procedure;

      procedure ep_regs is
         variable d : natural;
      begin
         -- volume and XA mute registers
         set_index(2); bus_wr(2, r.rnd(256)); bus_wr(3, r.rnd(256));
         set_index(3); bus_wr(1, r.rnd(256)); bus_wr(2, r.rnd(256)); bus_wr(3, r.rnd(2) * 32 + r.rnd(2));
         if r.rnd(2) = 0 then
            set_index(3); bus_wr(3, 32 + r.rnd(2));
         end if;
         set_index(1);
         if r.rnd(8) = 0 then bus_wr(2, r.rnd(32)); else bus_wr(2, 31); end if;
         set_index(0);
      end procedure;

      procedure ep_disc is
      begin
         load_disc(4, r.rnd(2) = 0);
         serve(2, 6000 + 3 * k_cmd + 2 * k_work + k_drive, 9);
         if r.rnd(2) = 0 then good_cmd(16#01#, 2, 9); end if;
         if r.rnd(2) = 0 then good_cmd(16#1A#, 2, 9); end if;
         if r.rnd(3) = 0 then good_cmd(16#13#, 1, 9); end if;
         if r.rnd(3) = 0 then good_cmd(16#14#, 1, 9); end if;
      end procedure;

      procedure ep_seek is
         variable c : natural;
      begin
         good_cmd(16#02#, 1, 9);
         c := 16#15# + r.rnd(2);
         one_cmd(c, 0, 2, 9);
         if r.rnd(2) = 0 then good_cmd(16#11#, 1, 9); end if;
         if r.rnd(3) = 0 then good_cmd(16#10#, 1, 9); end if;
         if r.rnd(3) = 0 then
            good_cmd(16#02#, 1, 9);
            one_cmd(16#06# + r.rnd(2) * 21, 0, 1, 9);
            if r.rnd(2) = 0 then good_cmd(16#09#, 1, 9); end if;
            serve(2, 12000 + 2 * k_drive, 9);
         end if;
      end procedure;

      procedure ep_life is
      begin
         case r.rnd(6) is
            when 0 => one_cmd(16#07#, 0, 2, 9);
            when 1 => one_cmd(16#08#, 0, 2, 9);
            when 2 => one_cmd(16#0A#, 0, 2, 9);
            when 3 => one_cmd(16#1A#, 0, 2, 9);
            when 4 => one_cmd(16#1E#, 0, 2, 9);
            when others => good_cmd(16#12#, 2, 9);
         end case;
         if r.rnd(2) = 0 then one_cmd(16#01#, 0, 1, 9); end if;
      end procedure;

      procedure ep_libcrypt is
         variable l : natural;
      begin
         load_disc(1 + r.rnd(2) * 3, false);
         serve(2, 6000 + 3 * k_cmd + 2 * k_work + k_drive, 9);
         good_cmd(16#0E#, 1, 9);
         l := lba_of(3, 8, 5) - 2 - r.rnd(2) + r.rnd(40) * (r.rnd(2));
         if r.rnd(2) = 0 then l := 14231 - 2 + r.rnd(12); end if;
         if r.rnd(3) = 0 then l := 16165 + r.rnd(10); end if;
         set_msf(l / 4500, (l / 75) mod 60, l mod 75);
         one_cmd(16#02#, 3, 1, 9);
         one_cmd(16#06#, 0, 1, 9);
         for i in 1 to 4 loop
            serve(1, 8000 + 2 * k_drive, r.rnd(3));
            if i = 3 then good_cmd(16#11#, 1, 9); end if;
         end loop;
         one_cmd(16#09#, 0, 2, 9);
      end procedure;

      procedure ep_reset is
      begin
         do_reset;
         if r.rnd(2) = 0 then load_disc(4, true); serve(2, 6000 + 3 * k_cmd + 2 * k_work + k_drive, 9); end if;
         irq_seen := irq_count;
      end procedure;

      procedure ep_options is
      begin
         pick_options;
         cyc(r.rnd(50));
      end procedure;

      procedure random_episode is
         variable t0 : natural;
         variable ty : natural;
      begin
         if r.rnd(8) = 0 then pick_k; end if;
         t0 := cycle;
         ty := r.rnd(44);
         case ty is
            when 0 to 19  => ep_simple;  ty := 0;
            when 20 to 24 => ep_read;    ty := 1;
            when 25 to 26 => ep_play;    ty := 2;
            when 27 to 29 => ep_chaos;   ty := 3;
            when 30 to 31 => ep_regs;    ty := 4;
            when 32       => ep_disc;    ty := 5;
            when 33 to 35 => ep_seek;    ty := 6;
            when 36 to 39 => ep_life;    ty := 7;
            when 40       => ep_libcrypt; ty := 8;
            when 41       => ep_reset;   ty := 9;
            when others   => ep_options; ty := 10;
         end case;
         ep_stat.add(2 * ty, cycle - t0);
         ep_stat.inc(2 * ty + 1);
      end procedure;

      -- directed ------------------------------------------------------------------------------------------------
      procedure state_prelude(s : natural) is
      begin
         case s is
            when 0 => null;                                          -- as after the reset
            when 1 => cyc(r.rnd(40000));                              -- motor spinning up
            when 2 => one_cmd(16#07#, 0, 2, 9);                      -- motor on
            when 3 => good_cmd(16#02#, 1, 9); one_cmd(16#15#, 0, 2, 9);
            when 4 => good_cmd(16#02#, 1, 9); one_cmd(16#06#, 0, 1, 9); serve(2, 12000 + 2 * k_drive, 9);
            when 5 => pa(0) := 16#01#; one_cmd(16#0E#, 1, 1, 9); one_cmd(16#03#, 0, 2, 9); serve(1, 12000 + 2 * k_drive, 9);
            when 6 => good_cmd(16#02#, 1, 9); one_cmd(16#06#, 0, 1, 9); serve(1, 12000 + 2 * k_drive, 9); one_cmd(16#09#, 0, 2, 9);
            when others => good_cmd(16#02#, 1, 9); one_cmd(16#16#, 0, 2, 9);
         end case;
      end procedure;

      procedure directed_cmds is
         variable c, st, hc, pv : natural;
      begin
         for c0 in 0 to 36 loop
            c := c0;
            if c0 = 33 then c := 16#40#; elsif c0 = 34 then c := 16#80#; elsif c0 = 35 then c := 16#FF#; elsif c0 = 36 then c := 16#55#; end if;
            for hc in 0 to 1 loop
               for st in 0 to 7 loop
                  for pv in 0 to 3 loop
                     if G_COUNT <= 1 and (pv > 1 or st > 3) then null;
                     else
                        pick_k;
                        hasCD <= '1' when hc = 0 else '0';
                        do_reset;
                        if hc = 0 then load_disc(4, true); serve(2, 6000 + 3 * k_cmd + 2 * k_work + k_drive, 9); end if;
                        state_prelude(st);
                        hasCD <= '1' when hc = 0 else '0';
                        make_params(c);
                        case pv is
                           when 0 => one_cmd(c, nat_params(c), 3, 1);
                           when 1 => one_cmd(c, 0, 2, 1);
                           when 2 => one_cmd(c, nat_params(c) + 2, 2, 1);
                           when others =>
                              one_cmd(c, nat_params(c), 1, 9);
                              one_cmd(r.rnd(32), 0, 1, 9);      -- a second command right behind the first
                        end case;
                        serve(2, 3000 + k_work + k_drive, 9);
                     end if;
                  end loop;
               end loop;
            end loop;
         end loop;
      end procedure;

      procedure directed_regs is
         variable d : natural;
         variable a, i : natural;
      begin
         do_reset;
         load_disc(0, true); serve(2, 6000 + 3 * k_cmd + 2 * k_work + k_drive, 9);
         for idx in 0 to 3 loop
            for ad in 0 to 3 loop
               for pat in 0 to 6 loop
                  set_index(idx);
                  case pat is
                     when 0 => d := 0;
                     when 1 => d := 1;
                     when 2 => d := 31;
                     when 3 => d := 127;
                     when 4 => d := 128;
                     when 5 => d := 255;
                     when others => d := r.rnd(256);
                  end case;
                  if ad /= 0 and not (ad = 1 and idx = 0) then bus_wr(ad, d); end if;
                  set_index(idx);
                  bus_rd(ad, v);
                  set_index(r.rnd(4));
                  dma_read <= '1'; cyc(2); dma_read <= '0';
               end loop;
            end loop;
         end loop;
         -- parameter FIFO: fill and drain through commands
         set_index(0);
         for i in 1 to 16 loop bus_wr(2, i); end loop;
         bus_rd(0, v);
         bus_wr(1, 16#01#);
         serve(2, 8000, 9);
         irq_seen := irq_count;
      end procedure;

      -- the sectors around the end of the pregap of track 1: data before position 0 reads as zeros
      procedure directed_pregap is
      begin
         for m in 0 to 3 loop
            pick_k;
            do_reset;
            load_disc(0, true); serve(2, 6000 + 3 * k_cmd + 2 * k_work + k_drive, 9);
            pa(0) := (m mod 2) * 32 + 16#00#; one_cmd(16#0E#, 1, 1, 9);
            set_msf(0, 1, 70 + (m / 2) * 2);
            one_cmd(16#02#, 3, 1, 9);
            one_cmd(16#06#, 0, 1, 9);
            for i in 1 to 6 loop serve(1, 12000 + 2 * k_drive, 3); end loop;
            one_cmd(16#09#, 0, 2, 9);
         end loop;
      end procedure;

      procedure directed_speed is
      begin
         for fs in 0 to 7 loop
            for inst in 0 to 1 loop
               for fast in 0 to 1 loop
                  pick_k;
                  FORCECDSPEED <= std_logic_vector(to_unsigned(fs, 3));
                  INSTANTSEEK <= '1' when inst = 1 else '0';
                  fastCD <= '1' when fast = 1 else '0';
                  LIMITREADSPEED <= '1' when (fs mod 2 = 1) else '0';
                  testSeek <= '1' when (inst = 1) else '0';
                  pauseOnCDSlow <= '1' when (fast = 1) else '0';
                  do_reset;
                  load_disc(0, true); serve(2, 6000 + 3 * k_cmd + 2 * k_work + k_drive, 9);
                  good_cmd(16#0E#, 1, 9);
                  good_cmd(16#02#, 1, 9);
                  one_cmd(16#06#, 0, 1, 9);
                  for i in 1 to 4 loop serve(1, 12000 + 2 * k_drive, 2); end loop;
                  one_cmd(16#09#, 0, 2, 9);
                  good_cmd(16#02#, 1, 9);
                  one_cmd(16#16#, 0, 2, 9);
                  one_cmd(16#08#, 0, 2, 9);
               end loop;
            end loop;
         end loop;
         INSTANTSEEK <= '0'; FORCECDSPEED <= "000"; fastCD <= '0'; LIMITREADSPEED <= '0'; testSeek <= '0'; pauseOnCDSlow <= '0';
      end procedure;

      procedure directed_xa is
      begin
         for flt in 0 to 7 loop
            pick_k;
            do_reset;
            load_disc(0, true); serve(2, 6000 + 3 * k_cmd + 2 * k_work + k_drive, 9);
            -- XA on, double or single speed; filter on for odd flt: the sectors carry file 1 or 2, channel 0..2 or FF
            pa(0) := 16#40# + (flt / 4) * 128 + (flt mod 2) * 8;
            one_cmd(16#0E#, 1, 1, 9);
            pa(0) := 1 + r.rnd(2); pa(1) := r.rnd(3);
            if flt = 3 then pa(1) := 255; end if;
            one_cmd(16#0D#, 2, 1, 9);
            set_msf(0, 2, r.rnd(70));
            one_cmd(16#02#, 3, 1, 9);
            one_cmd(16#06#, 0, 1, 9);
            for i in 1 to 14 loop serve(1, 12000 + 2 * k_drive, 2); cyc(r.rnd(1500)); end loop;
            ep_regs;
            for i in 1 to 6 loop serve(1, 12000 + 2 * k_drive, 9); cyc(r.rnd(3000)); end loop;
            one_cmd(16#09#, 0, 2, 9);
         end loop;
      end procedure;

      procedure directed_audio is
      begin
         for kind in 0 to 3 loop
            pick_k;
            do_reset;
            load_disc(1 + (kind mod 2), true); serve(2, 6000 + 3 * k_cmd + 2 * k_work + k_drive, 9);
            pa(0) := 16#05# + (kind / 2) * 2; one_cmd(16#0E#, 1, 1, 9);
            if kind mod 2 = 0 then
               ep_regs;
            else
               -- loud and asymmetric: gains of 2, 0.4, 0.6 and 1.75, so that the mixer clamps and every gain register matters
               set_index(2); bus_wr(2, 255); bus_wr(3, 16#30#);
               set_index(3); bus_wr(1, 16#E0#); bus_wr(2, 16#50#); bus_wr(3, 32);
               set_index(0);
            end if;
            pa(0) := to_bcd(1 + (kind mod 2)); one_cmd(16#03#, 1, 2, 9);
            for i in 1 to 10 loop serve(1, 12000 + 2 * k_drive, 9); cyc(r.rnd(4000)); end loop;
            one_cmd(16#04#, 0, 1, 9);
            for i in 1 to 4 loop serve(1, 12000 + 2 * k_drive, 9); end loop;
            one_cmd(16#05#, 0, 1, 9);
            for i in 1 to 4 loop serve(1, 12000 + 2 * k_drive, 9); end loop;
            one_cmd(16#09#, 0, 2, 9);
         end loop;
      end procedure;

      -- wait for the next sector event of the golden; the lba is lastReadSector at the event, the sector whose subchannel
      -- data the drive takes over at this event
      procedure wait_event(limit : natural; variable lba : out natural; variable got : out boolean) is
         variable k : natural := 0;
         variable n : natural := ev_cnt;
      begin
         got := false;
         lba := 0;
         while k < limit loop
            wait until falling_edge(clk);
            if ev_cnt /= n then lba := ev_lba; got := true; exit; end if;
            k := k + 1;
         end loop;
      end procedure;

      -- GetLocP right after sector events of a stream; hit = a sector for which GetLocP is always asked
      procedure probe_events(nev : natural; hit_lo, hit_hi : natural) is
         variable lba : natural;
         variable got : boolean;
      begin
         for i in 1 to nev loop
            wait_event(60000 + 2 * k_drive, lba, got);
            exit when not got;
            if (lba >= hit_lo and lba <= hit_hi) or r.rnd(5) = 0 then
               send_cmd(16#11#, 0);
               serve(1, 4000, 9);
            end if;
         end loop;
      end procedure;

      procedure directed_libcrypt is
         type lt is array (0 to 15) of natural;
         constant a : lt := (14105, 14231, 14485, 14579, 14649, 14899, 15056, 15130, 15242, 15312, 15378, 15628, 15919, 16031, 16101, 16167);
         variable t : natural;
      begin
         -- one pair per run, its key bit set; both sectors of the pair (sector + 2 = a and a + 5) are probed on an audio disc
         for j in 0 to 31 loop
            pick_k;
            k_cmd <= 12;
            do_reset;
            disc.randomize(2, 100 + j, 2 ** (15 - (j mod 16)), j mod 4, 0);
            for i in 0 to disc.words - 1 loop
               wait until falling_edge(clk);
               trackinfo_addr <= std_logic_vector(to_unsigned(disc.table_addr(i), 9));
               trackinfo_data <= disc.table_word(i);
               trackinfo_write <= '1';
               wait until falling_edge(clk);
               trackinfo_write <= '0';
            end loop;
            serve(2, 6000 + 3 * k_cmd + 2 * k_work + k_drive, 9);
            if j < 16 then t := a(j) - 2; else t := a(j - 16) + 3; end if;
            set_msf((t - 4) / 4500, ((t - 4) / 75) mod 60, (t - 4) mod 75);
            one_cmd(16#02#, 3, 1, 9);
            one_cmd(16#03#, 0, 2, 9);
            probe_events(10, t, t);
            one_cmd(16#09#, 0, 2, 9);
         end loop;
      end procedure;

      procedure directed_irq is
      begin
         -- commands issued behind pending interrupts and before the first is acknowledged
         for i in 0 to 39 loop
            pick_k;
            do_reset;
            load_disc(0, true); serve(2, 6000 + 3 * k_cmd + 2 * k_work + k_drive, 9);
            case i mod 5 is
               when 0 => good_cmd(16#02#, 1, 9);
               when 1 => pa(0) := 16#20#; one_cmd(16#0E#, 1, 1, 9);
               when others => null;
            end case;
            send_cmd(16#01#, 0);
            cyc(r.rnd(3000));
            send_cmd(16#06# + (i mod 2) * 21, 0);
            cyc(r.rnd(60000));
            send_cmd(16#0E#, 1);
            cyc(r.rnd(20000));
            send_cmd(16#09#, 0);
            cyc(20000 + r.rnd(40000));
            serve(4, 6000, 9);
            for j in 1 to 8 loop
               cyc(r.rnd(20000));
               serve(1, 5000, 9);
               if i mod 3 = 0 then send_cmd(16#01#, 0); end if;
            end loop;
            serve(3, 3000, 9);
         end loop;
      end procedure;

      -- real-time suite: one scenario per G_SCEN, no compression; wait limits in clocks
      procedure realtime_scen(s : natural) is
         variable wl : natural := 130000000;
         variable lbaT : natural;
         variable evgot : boolean;
      begin
         -- the set-up (reset, disc load, spin-up) is compressed except in scenario 0, which times the spin-up itself;
         -- the command under test then runs at the real delays
         if s = 0 then
            skip_on <= false;
         else
            skip_on <= true; k_cmd <= 50; k_work <= 50; k_drive <= 50; k_slow <= 50; k_newcd <= 50; k_irq <= 50;
         end if;
         do_reset;
         load_disc(0, false);
         cyc(3000);
         serve(3, 140000000, 9);
         cyc(3000);
         skip_on <= false;
         k_cmd <= 30000; k_work <= 40000000; k_drive <= 70000000;     -- only the wait limits of serve() use these now
         case s is
            when 0 => one_cmd(16#01#, 0, 2, 9);
            when 1 => one_cmd(16#1A#, 0, 2, 9); serve(2, wl, 9);
            when 2 => one_cmd(16#07#, 0, 2, 9);
            when 3 => one_cmd(16#08#, 0, 2, 9);
            when 4 => one_cmd(16#0A#, 0, 2, 9);
            when 5 => one_cmd(16#1E#, 0, 2, 9);
            when 6 => set_msf(0, 2, 10); one_cmd(16#02#, 3, 1, 9); one_cmd(16#15#, 0, 2, 9);
            when 7 => set_msf(0, 2, 10); one_cmd(16#02#, 3, 1, 9); one_cmd(16#16#, 0, 2, 9);
            when 8 =>
               set_msf(0, 2, 10); one_cmd(16#02#, 3, 1, 9); one_cmd(16#06#, 0, 1, 9);
               for i in 1 to 4 loop wait_event(60000000, lbaT, evgot); end loop;
               one_cmd(16#09#, 0, 2, 9);
            when 9 =>
               pa(0) := 16#80#; one_cmd(16#0E#, 1, 2, 9);
               set_msf(0, 2, 10); one_cmd(16#02#, 3, 1, 9);
               pauseOnCDSlow <= '1';
               one_cmd(16#06#, 0, 1, 9);
               for i in 1 to 3 loop wait_event(60000000, lbaT, evgot); end loop;
               hps_nodata <= '1';               -- the next sector arrives late: pauseCD, then cdSlow rises and times out
               cyc(1500000);
               hps_nodata <= '0';
               for i in 1 to 2 loop wait_event(60000000, lbaT, evgot); end loop;
               one_cmd(16#09#, 0, 2, 9);
               cyc(17000000);                    -- cdSlow falls 2^24 clocks after the last sector fetch
            when 10 =>
               pa(0) := 16#01#; one_cmd(16#0E#, 1, 1, 9);
               one_cmd(16#03#, 0, 2, 9);
               for i in 1 to 4 loop wait_event(60000000, lbaT, evgot); end loop;
               one_cmd(16#09#, 0, 2, 9);
            when 11 => pa(0) := 16#80#; one_cmd(16#0E#, 1, 2, 9); one_cmd(16#09#, 0, 2, 9);
            when 12 => pa(0) := 16#00#; one_cmd(16#0E#, 1, 2, 9); pa(0) := 16#80#; one_cmd(16#0E#, 1, 2, 9);
            when 13 => pa(0) := 2; one_cmd(16#12#, 1, 2, 9);
            when 14 => one_cmd(16#0A#, 0, 2, 9); one_cmd(16#01#, 0, 2, 9);
            when 15 => one_cmd(16#08#, 0, 2, 9); set_msf(0, 2, 10); one_cmd(16#02#, 3, 1, 9); one_cmd(16#15#, 0, 2, 9);
            when 16 => pa(0) := 16#80#; one_cmd(16#0E#, 1, 2, 9); one_cmd(16#08#, 0, 2, 9);
            when 17 => load_disc(1, false); serve(3, wl, 9); one_cmd(16#01#, 0, 2, 9);
            when 18 => set_msf(0, 2, 10); one_cmd(16#02#, 3, 1, 9); one_cmd(16#15#, 0, 2, 9); one_cmd(16#08#, 0, 2, 9);
            when 19 => one_cmd(16#07#, 0, 2, 9); one_cmd(16#09#, 0, 2, 9); one_cmd(16#1A#, 0, 2, 9); serve(2, wl, 9);
            when 21 =>
               -- seek times over the distance classes (the seek time table compresses to nothing otherwise)
               for d in 0 to 8 loop
                  case d is
                     when 0 => lbaT := 3;
                     when 1 => lbaT := 3 + 4;
                     when 2 => lbaT := 7 + 5;
                     when 3 => lbaT := 12 + 32;
                     when 4 => lbaT := 44 + 75;
                     when 5 => lbaT := 119 + 76;
                     when 6 => lbaT := 195 + 255;
                     when 7 => lbaT := 450 + 4499;
                     when others => lbaT := 4949 + 4500;
                  end case;
                  set_msf(lbaT / 4500, (lbaT / 75) mod 60, lbaT mod 75);
                  one_cmd(16#02#, 3, 1, 9);
                  one_cmd(16#15#, 0, 2, 9);
               end loop;
            when others =>
               for c in 0 to 31 loop
                  if c = 16#08# or c = 16#1E# then null;
                  else good_cmd(c, 2, 9); serve(1, 300000, 9);
                  end if;
               end loop;
         end case;
         serve(3, 20000000, 9);
      end procedure;

   begin
      r.seed(G_SEED);
      rh.seed(G_SEED * 7 + 3);
      pick_options;
      INSTANTSEEK <= '0'; FORCECDSPEED <= "000"; LIMITREADSPEED <= '0'; fastCD <= '0'; testSeek <= '0'; pauseOnCDSlow <= '0';
      hasCD <= '1'; LIDopen <= '0'; mdec_idle <= '1';
      reset <= '1';
      cyc(5);
      -- power-up: reset_in high, then the sequenced release
      reset <= '1'; SS_reset <= '0';
      cyc(8);
      reset <= '0'; SS_reset <= '1';
      cyc(2);
      SS_reset <= '0'; reset <= '1';
      cyc(61);
      reset <= '0';
      cyc(4);
      set_index(1); bus_wr(2, 31); set_index(0);
      load_disc(0, true);
      cyc(10);
      armed <= true;
      pick_k;
      fix_k;
      if G_SUITE = "realtime" then
         realtime_scen(G_SCEN);
      elsif G_SUITE = "smoke" then
         for i in 1 to 40 loop random_episode; end loop;
      elsif G_SUITE = "directed" then
         case G_SCEN is
            when 0 => directed_cmds;
            when 1 => directed_regs; directed_irq; directed_pregap;
            when 2 => directed_speed;
            when 3 => directed_xa; directed_audio;
            when 4 => directed_libcrypt;
            when others => directed_cmds; directed_regs; directed_irq; directed_pregap; directed_speed; directed_xa; directed_audio; directed_libcrypt;
         end case;
      elsif G_SUITE = "reset" then
         for i in 1 to G_COUNT loop
            ep_reset; random_episode; random_episode;
         end loop;
      else
         if r.rnd(2) = 0 then stall_on <= true; stall_pct <= 1 + r.rnd(20); stall_max <= 1 + r.rnd(60); end if;
         while cmds_done < G_COUNT loop
            random_episode;
            if r.rnd(300) = 0 then
               hps_nodata <= '1'; cyc(1000 + r.rnd(4000)); hps_nodata <= '0';
            end if;
         end loop;
      end if;
      -- drain
      cyc(6000);
      finished <= true;
      wait;
   end process;

end architecture;
