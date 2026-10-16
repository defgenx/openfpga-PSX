-- SPU differential testbench: frozen golden spu (library gold) against spu_pocket (library dut), same stimulus, every listed
-- output compared on every clk1x. Documentation: docs/pocket/SPU.md, "Differential harness".
--
-- Stimulus: one CPU/DMA process (register writes and reads, KEYON/KEYOFF, ADPCM block transfers through the transfer FIFO,
-- DMA writes and reads), random ce/cpuPaused in the wild suite, CD audio per spu_tick, one SPU RAM model per side
-- (spu_ram_model: variable latency, same request stream gives the same latency stream).
-- G_SUITE: random | directed | wild | bw | reset | smoke
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std;
use std.textio.all;
use std.env.all;
library gold;
library dut;

use work.spu_diff_pkg.all;
use work.trace_cmp_pkg.all;

entity tb_diff is
   generic
   (
      G_SEED       : natural := 1;
      G_SUITE      : string  := "random";
      G_SCEN       : natural := 0;          -- directed: scenario
      G_COUNT      : natural := 200;        -- samples (768 clk1x each)
      G_NO_REVERB  : natural := 1;          -- DUT generic NO_REVERB; the golden is tied REVERBOFF = G_NO_REVERB
      G_L1         : natural := 0;          -- DUT generic L1_CACHE; 1: reads are not compared, fixed latency G_LATMIN
      G_SAMPLE_ONLY: natural := 0;          -- 1: only sound_out at spu_tick is compared (latencies may differ; no register traffic in the run)
      G_REVOFF     : natural := 0;          -- 1: REVERBOFF = 1 for both sides whatever NO_REVERB is
      G_LATMIN     : natural := 1;
      G_LATMAX     : natural := 4;
      G_MAX_FAIL   : natural := 50;
      G_FAULT_SIG  : integer := -1;
      G_FAULT_CYC  : natural := 100000
   );
end entity;

architecture arch of tb_diff is

   constant TCLK    : time := 30 ns;
   constant WINDOW  : natural := 33869;       -- 1 ms of clk1x

   signal clk1x, clk2x      : std_logic := '0';
   signal clk2xIndex        : std_logic := '0';
   signal clk1xToggle, clk1xToggle2x : std_logic := '0';

   signal ce, reset, cpuPaused : std_logic := '0';
   signal ss_rst            : std_logic := '0';
   signal cd_left, cd_right : signed(15 downto 0) := (others => '0');
   signal bus_addr          : unsigned(9 downto 0) := (others => '0');
   signal bus_dataWrite     : std_logic_vector(15 downto 0) := (others => '0');
   signal bus_read, bus_write : std_logic := '0';
   signal dma_read, dma_write : std_logic := '0';
   signal dma_writedata     : std_logic_vector(15 downto 0) := (others => '0');
   signal reverboff         : std_logic;

   -- golden (g_) and DUT (d_) outputs
   signal g_spu_tick, g_irqOut, g_sound_timeout, g_spu_dmaRequest : std_logic;
   signal g_sound_left, g_sound_right, g_bus_dataRead, g_dma_readdata : std_logic_vector(15 downto 0);
   signal g_sdram_dataWrite, g_sdram_dataRead : std_logic_vector(31 downto 0);
   signal g_sdram_Adr       : std_logic_vector(18 downto 0);
   signal g_sdram_be        : std_logic_vector(3 downto 0);
   signal g_sdram_rnw, g_sdram_ena, g_sdram_done : std_logic;
   signal g_mem_request, g_mem_WE, g_mem_RD : std_logic;
   signal g_mem_BURSTCNT    : std_logic_vector(7 downto 0);
   signal g_mem_ADDR        : std_logic_vector(19 downto 0);
   signal g_mem_DIN         : std_logic_vector(63 downto 0);
   signal g_mem_BE          : std_logic_vector(7 downto 0);
   signal g_SS_DataRead     : std_logic_vector(31 downto 0);
   signal g_SS_idle, g_SS_RAM_done : std_logic;
   signal g_SS_RAM_dataRead : std_logic_vector(15 downto 0);

   signal d_spu_tick, d_irqOut, d_sound_timeout, d_spu_dmaRequest : std_logic;
   signal d_sound_left, d_sound_right, d_bus_dataRead, d_dma_readdata : std_logic_vector(15 downto 0);
   signal d_sdram_dataWrite, d_sdram_dataRead : std_logic_vector(31 downto 0);
   signal d_sdram_Adr       : std_logic_vector(18 downto 0);
   signal d_sdram_be        : std_logic_vector(3 downto 0);
   signal d_sdram_rnw, d_sdram_ena, d_sdram_done : std_logic;
   signal d_mem_request, d_mem_WE, d_mem_RD : std_logic;
   signal d_mem_BURSTCNT    : std_logic_vector(7 downto 0);
   signal d_mem_ADDR        : std_logic_vector(19 downto 0);
   signal d_mem_DIN         : std_logic_vector(63 downto 0);
   signal d_mem_BE          : std_logic_vector(7 downto 0);
   signal d_SS_DataRead     : std_logic_vector(31 downto 0);
   signal d_SS_idle, d_SS_RAM_done : std_logic;
   signal d_SS_RAM_dataRead : std_logic_vector(15 downto 0);

   signal g_reqs, g_writes, d_reqs, d_writes : natural := 0;

   signal armed, bus_seen : boolean := false;
   signal g_eps, g_cps    : integer := 4;     -- golden output-stage and CD-stage step counters (4: idle)
   signal finished        : boolean := false;
   signal stim_cycle      : natural := 0;

   shared variable cmp  : trace_cmp_t;
   shared variable cov  : counters_t;    -- golden internals (cov_flags bit i: clocks the condition held)
   shared variable tcv  : counters_t;    -- stimulus and output counters

   constant TCV_NAMES : string :=
      "wr_voice wr_global rd_voice rd_vol rd_global rd_endx rd_stat rd_reverb keyon_w keyoff_w cnt_w dma_wr dma_rd fifo_wr " &
      "xfer_blocks hot_overlap irq_at_hot reset_pulse ce_low nz_out sat_out none21 pitch_hi reverb_w noise_w sweep_w pmon_w";

begin

   -------------------------------------------------------------- clocks
   p_clk : process
      variable t1 : std_logic := '0';
   begin
      loop
         clk2x <= '1'; t1 := not t1; clk1x <= t1;
         wait for TCLK / 4;
         clk2x <= '0';
         wait for TCLK / 4;
      end loop;
   end process;

   p_idx1 : process (clk1x) begin
      if rising_edge(clk1x) then clk1xToggle <= not clk1xToggle; end if;
   end process;
   p_idx2 : process (clk2x) begin
      if rising_edge(clk2x) then
         clk1xToggle2x <= clk1xToggle;
         clk2xIndex    <= '0';
         if (clk1xToggle2x = clk1xToggle) then clk2xIndex <= '1'; end if;
      end if;
   end process;

   reverboff <= '1' when (G_NO_REVERB /= 0 or G_REVOFF /= 0) else '0';

   -------------------------------------------------------------- units
   gold : entity gold.spu
   port map
   (
      clk1x => clk1x, clk2x => clk2x, clk2xIndex => clk2xIndex, ce => ce, reset => reset,
      SPUon => '1', SPUIRQTrigger => '0', useSDRAM => '1', REPRODUCIBLESPUIRQ => '1', REPRODUCIBLESPUDMA => '0',
      REVERBOFF => reverboff, cpuPaused => cpuPaused,
      spu_tick => g_spu_tick, cd_left => cd_left, cd_right => cd_right, irqOut => g_irqOut, sound_timeout => g_sound_timeout,
      sound_out_left => g_sound_left, sound_out_right => g_sound_right,
      bus_addr => bus_addr, bus_dataWrite => bus_dataWrite, bus_read => bus_read, bus_write => bus_write, bus_dataRead => g_bus_dataRead,
      spu_dmaRequest => g_spu_dmaRequest, dma_read => dma_read, dma_readdata => g_dma_readdata,
      dma_write => dma_write, dma_writedata => dma_writedata,
      sdram_dataWrite => g_sdram_dataWrite, sdram_Adr => g_sdram_Adr, sdram_be => g_sdram_be, sdram_rnw => g_sdram_rnw,
      sdram_ena => g_sdram_ena, sdram_dataRead => g_sdram_dataRead, sdram_done => g_sdram_done,
      mem_request => g_mem_request, mem_BURSTCNT => g_mem_BURSTCNT, mem_ADDR => g_mem_ADDR, mem_DIN => g_mem_DIN, mem_BE => g_mem_BE,
      mem_WE => g_mem_WE, mem_RD => g_mem_RD, mem_ack => '0', mem_DOUT => (others => '0'), mem_DOUT_READY => '0',
      SS_reset => ss_rst, loading_savestate => '0', SS_DataWrite => (others => '0'), SS_Adr => (others => '0'),
      SS_wren => '0', SS_rden => '0', SS_DataRead => g_SS_DataRead, SS_idle => g_SS_idle,
      SS_RAM_dataWrite => (others => '0'), SS_RAM_Adr => (others => '0'), SS_RAM_request => '0', SS_RAM_rnw => '0',
      SS_RAM_dataRead => g_SS_RAM_dataRead, SS_RAM_done => g_SS_RAM_done
   );

   dut : entity dut.spu_pocket
   generic map (NO_REVERB => G_NO_REVERB /= 0, L1_CACHE => G_L1 /= 0)
   port map
   (
      clk1x => clk1x, clk2x => clk2x, clk2xIndex => clk2xIndex, ce => ce, reset => reset,
      SPUon => '1', SPUIRQTrigger => '0', useSDRAM => '1', REPRODUCIBLESPUIRQ => '1', REPRODUCIBLESPUDMA => '0',
      REVERBOFF => reverboff, cpuPaused => cpuPaused,
      spu_tick => d_spu_tick, cd_left => cd_left, cd_right => cd_right, irqOut => d_irqOut, sound_timeout => d_sound_timeout,
      sound_out_left => d_sound_left, sound_out_right => d_sound_right,
      bus_addr => bus_addr, bus_dataWrite => bus_dataWrite, bus_read => bus_read, bus_write => bus_write, bus_dataRead => d_bus_dataRead,
      spu_dmaRequest => d_spu_dmaRequest, dma_read => dma_read, dma_readdata => d_dma_readdata,
      dma_write => dma_write, dma_writedata => dma_writedata,
      sdram_dataWrite => d_sdram_dataWrite, sdram_Adr => d_sdram_Adr, sdram_be => d_sdram_be, sdram_rnw => d_sdram_rnw,
      sdram_ena => d_sdram_ena, sdram_dataRead => d_sdram_dataRead, sdram_done => d_sdram_done,
      mem_request => d_mem_request, mem_BURSTCNT => d_mem_BURSTCNT, mem_ADDR => d_mem_ADDR, mem_DIN => d_mem_DIN, mem_BE => d_mem_BE,
      mem_WE => d_mem_WE, mem_RD => d_mem_RD, mem_ack => '0', mem_DOUT => (others => '0'), mem_DOUT_READY => '0',
      SS_reset => ss_rst, loading_savestate => '0', SS_DataWrite => (others => '0'), SS_Adr => (others => '0'),
      SS_wren => '0', SS_rden => '0', SS_DataRead => d_SS_DataRead, SS_idle => d_SS_idle,
      SS_RAM_dataWrite => (others => '0'), SS_RAM_Adr => (others => '0'), SS_RAM_request => '0', SS_RAM_rnw => '0',
      SS_RAM_dataRead => d_SS_RAM_dataRead, SS_RAM_done => d_SS_RAM_done
   );

   ram_g : entity work.spu_ram_model
   generic map (G_IMAGE => G_SEED, G_LATSEED => G_SEED, G_LATMIN => G_LATMIN, G_LATMAX => G_LATMAX)
   port map (clk => clk1x, ena => g_sdram_ena, rnw => g_sdram_rnw, adr => g_sdram_Adr, dataWrite => g_sdram_dataWrite,
             be => g_sdram_be, done => g_sdram_done, dataRead => g_sdram_dataRead, reqs => g_reqs, writes => g_writes);

   ram_d : entity work.spu_ram_model
   generic map (G_IMAGE => G_SEED, G_LATSEED => G_SEED, G_LATMIN => G_LATMIN, G_LATMAX => G_LATMAX)
   port map (clk => clk1x, ena => d_sdram_ena, rnw => d_sdram_rnw, adr => d_sdram_Adr, dataWrite => d_sdram_dataWrite,
             be => d_sdram_be, done => d_sdram_done, dataRead => d_sdram_dataRead, reqs => d_reqs, writes => d_writes);

   -------------------------------------------------------------- compare
   p_compare : process
      variable cyc      : natural := 0;
      variable n_samp   : natural := 0;
      variable fired    : boolean := false;
      variable v_left, v_right, v_bus, v_dma : std_logic_vector(15 downto 0);
      variable v_tick, v_irq, v_tmo, v_req, v_ena, v_rnw, v_memreq, v_idle : std_logic;
      variable v_adr    : std_logic_vector(18 downto 0);
      variable v_dw     : std_logic_vector(31 downto 0);
      variable v_be     : std_logic_vector(3 downto 0);
      variable g_wr, d_wr : std_logic;
      variable win_g, win_d, win_k, peak_g, peak_d, tot_g, tot_d : natural := 0;
      variable line_o   : line;
      variable f        : boolean;
      variable n_cmp    : natural := 0;

      procedure chk(name : string; g, d : std_logic_vector) is
      begin
         n_cmp := n_cmp + 1;
         if g /= d then cmp.compare(name, cyc, g, d); end if;
      end procedure;
      procedure chk1(name : string; g, d : std_logic) is
      begin
         n_cmp := n_cmp + 1;
         if g /= d then cmp.compare(name, cyc, g, d); end if;
      end procedure;
   begin
      loop
         wait until falling_edge(clk1x);
         cyc := cyc + 1;
         if armed then
            f := false;
            if G_FAULT_SIG >= 0 and not fired and cyc >= G_FAULT_CYC then
               case G_FAULT_SIG is
                  when 2      => f := bus_seen;
                  when 9 | 10 | 12 => f := g_sdram_ena = '1';
                  when 11     => f := g_sdram_ena = '1' and g_sdram_rnw = '0';
                  when others => f := true;
               end case;
            end if;
            if f then fired := true; end if;
            v_left := d_sound_left; v_right := d_sound_right; v_bus := d_bus_dataRead; v_dma := d_dma_readdata;
            v_tick := d_spu_tick; v_irq := d_irqOut; v_tmo := d_sound_timeout; v_req := d_spu_dmaRequest;
            v_ena := d_sdram_ena; v_rnw := d_sdram_rnw; v_adr := d_sdram_Adr; v_dw := d_sdram_dataWrite; v_be := d_sdram_be;
            v_memreq := d_mem_request; v_idle := d_SS_idle;
            if f then
               case G_FAULT_SIG is
                  when 0  => v_left(3) := not v_left(3);
                  when 1  => v_right(15) := not v_right(15);
                  when 2  => v_bus(7) := not v_bus(7);
                  when 3  => v_irq := not v_irq;
                  when 4  => v_tick := not v_tick;
                  when 5  => v_tmo := not v_tmo;
                  when 6  => v_req := not v_req;
                  when 7  => v_dma(0) := not v_dma(0);
                  when 8  => v_ena := not v_ena;
                  when 9  => v_adr(18) := not v_adr(18);
                  when 10 => v_rnw := not v_rnw;
                  when 11 => v_dw(9) := not v_dw(9);
                  when 12 => v_be(0) := not v_be(0);
                  when 13 => v_memreq := not v_memreq;
                  when others => v_idle := not v_idle;
               end case;
            end if;
            if G_SAMPLE_ONLY /= 0 then
               if g_spu_tick = '1' then
                  chk("sound_out_left", g_sound_left, v_left);
                  chk("sound_out_right", g_sound_right, v_right);
               end if;
            else
            chk("sound_out_left", g_sound_left, v_left);
            chk("sound_out_right", g_sound_right, v_right);
            if bus_seen then chk("bus_dataRead", g_bus_dataRead, v_bus); end if;
            chk1("irqOut", g_irqOut, v_irq);
            chk1("spu_tick", g_spu_tick, v_tick);
            chk1("sound_timeout", g_sound_timeout, v_tmo);
            chk1("spu_dmaRequest", g_spu_dmaRequest, v_req);
            chk("dma_readdata", g_dma_readdata, v_dma);
            chk1("SS_idle", g_SS_idle, v_idle);
            if G_L1 = 0 then
               chk1("sdram_ena", g_sdram_ena, v_ena);
               if g_sdram_ena = '1' then
                  chk("sdram_Adr", g_sdram_Adr, v_adr);
                  chk1("sdram_rnw", g_sdram_rnw, v_rnw);
                  chk("sdram_be", g_sdram_be, v_be);
                  if g_sdram_rnw = '0' then chk("sdram_dataWrite", g_sdram_dataWrite, v_dw); end if;
               end if;
            else
               g_wr := g_sdram_ena and not g_sdram_rnw;
               d_wr := v_ena and not v_rnw;
               chk1("sdram_write", g_wr, d_wr);
               if g_wr = '1' then
                  chk("sdram_Adr", g_sdram_Adr, v_adr);
                  chk("sdram_be", g_sdram_be, v_be);
                  chk("sdram_dataWrite", g_sdram_dataWrite, v_dw);
               end if;
            end if;
            chk1("mem_request", g_mem_request, v_memreq);
            chk("mem_BURSTCNT", g_mem_BURSTCNT, d_mem_BURSTCNT);
            chk("mem_ADDR", g_mem_ADDR, d_mem_ADDR);
            chk("mem_DIN", g_mem_DIN, d_mem_DIN);
            chk("mem_BE", g_mem_BE, d_mem_BE);
            chk1("mem_WE", g_mem_WE, d_mem_WE);
            chk1("mem_RD", g_mem_RD, d_mem_RD);
            end if;

            -- coverage of the golden's internals and outputs
            if g_spu_tick = '1' then
               n_samp := n_samp + 1;
               if g_sound_left /= x"0000" or g_sound_right /= x"0000" then tcv.inc(19); end if;
               if g_sound_left = x"7FFF" or g_sound_left = x"8000" or g_sound_right = x"7FFF" or g_sound_right = x"8000" then tcv.inc(20); end if;
            end if;
            if g_sdram_ena = '1' then win_g := win_g + 1; end if;
            if d_sdram_ena = '1' then win_d := win_d + 1; end if;
            if (cyc mod WINDOW) = 0 then
               write(line_o, string'("BW ") & integer'image(win_k) & " " & integer'image(win_g) & " " & integer'image(win_d));
               writeline(output, line_o);
               if win_g > peak_g then peak_g := win_g; end if;
               if win_d > peak_d then peak_d := win_d; end if;
               tot_g := tot_g + win_g; tot_d := tot_d + win_d;
               win_g := 0; win_d := 0; win_k := win_k + 1;
            end if;
         end if;
         if cmp.mismatches > G_MAX_FAIL or finished then exit; end if;
      end loop;
      write(line_o, string'("BWSUM windows=") & integer'image(win_k) & " gold_peak=" & integer'image(peak_g) & " dut_peak=" & integer'image(peak_d) &
            " gold_total=" & integer'image(tot_g + win_g) & " dut_total=" & integer'image(tot_d + win_d) & " gold_reads=" & integer'image(g_reqs - g_writes) &
            " dut_reads=" & integer'image(d_reqs - d_writes));
      writeline(output, line_o);
      write(line_o, string'("COV "));
      for i in 0 to 63 loop write(line_o, integer'image(cov.get(i)) & " "); end loop;
      writeline(output, line_o);
      write(line_o, string'("TCOVNAMES ") & TCV_NAMES);
      writeline(output, line_o);
      write(line_o, string'("TCOV "));
      for i in 0 to 63 loop write(line_o, integer'image(tcv.get(i)) & " "); end loop;
      writeline(output, line_o);
      write(line_o, string'("SAMPLES ") & integer'image(n_samp));
      writeline(output, line_o);
      -- RESULT line: cycles compares mismatches samples
      write(line_o, string'("RESULT cycles=") & integer'image(cyc) & " samples=" & integer'image(n_samp) & " nonzero=" & integer'image(tcv.get(19)) &
            " compares=" & integer'image(n_cmp) & " mismatches=" & integer'image(cmp.mismatches) & " ");
      if cmp.mismatches /= 0 or n_cmp = 0 then write(line_o, string'("FAIL")); else write(line_o, string'("PASS")); end if;
      writeline(output, line_o);
      if cmp.mismatches /= 0 or n_cmp = 0 then stop(1); else stop(0); end if;
      wait;
   end process;


   b_cov : block
      alias gcov is <<signal .tb_diff.gold.cov_flags : std_logic_vector(63 downto 0)>>;
      alias geps is <<signal .tb_diff.gold.endProcStep : integer>>;
      alias gcps is <<signal .tb_diff.gold.cdProcStep : integer>>;
   begin
      g_eps <= geps;
      g_cps <= gcps;
      process (clk1x)
      begin
         if falling_edge(clk1x) and armed then
            for i in 0 to 63 loop
               if gcov(i) = '1' then cov.inc(i); end if;
            end loop;
         end if;
      end process;
   end block;

   -------------------------------------------------------------- CD audio input, one new pair per sample
   p_cd : process
      variable rc : rng_t;
      variable l, r : integer := 0;
      variable k : natural;
   begin
      rc.seed(G_SEED * 31 + 5);
      loop
         wait until rising_edge(clk1x);
         if g_spu_tick = '1' then
            k := rc.rnd(100);
            if k < 35 then l := 0; r := 0;
            elsif k < 65 then l := rc.between(-32768, 32767); r := rc.between(-32768, 32767);
            elsif k < 80 then
               if rc.chance(50) then l := 32767; else l := -32768; end if;
               if rc.chance(50) then r := 32767; else r := -32768; end if;
            else l := l + rc.between(-2000, 2000); r := r + rc.between(-2000, 2000);
               if l > 32767 then l := 32767; end if; if l < -32768 then l := -32768; end if;
               if r > 32767 then r := 32767; end if; if r < -32768 then r := -32768; end if;
            end if;
            cd_left  <= to_signed(l, 16);
            cd_right <= to_signed(r, 16);
         end if;
      end loop;
   end process;

   -------------------------------------------------------------- ce and cpuPaused
   p_ce : process
      variable rc : rng_t;
      variable n  : natural;
   begin
      rc.seed(G_SEED * 17 + 3);
      ce <= '1'; cpuPaused <= '0';
      if G_SUITE /= "wild" then
         wait;
      end if;
      loop
         wait until rising_edge(clk1x);
         -- the top stops ce only while the SPU reports SS_idle
         if g_SS_idle = '1' and ce = '1' and rc.chance(8) then
            n := rc.between(1, 40);
            ce <= '0';
            tcv.add(18, n);
            for i in 1 to n loop wait until rising_edge(clk1x); end loop;
            ce <= '1';
         end if;
         cpuPaused <= '0';
         if rc.chance(30) then cpuPaused <= '1'; end if;
      end loop;
   end process;

   -------------------------------------------------------------- CPU / DMA stimulus
   p_stim : process
      variable rs : rng_t;
      variable cnt_sh : natural := 0;
      type hot_t is array (0 to 15) of natural;
      variable hot  : hot_t := (others => 16#400#);
      variable nhot : natural := 0;
      variable scen : natural := 0;
      variable wild : boolean := false;
      variable k    : natural;
      variable t_end: natural;
      variable v, r, a, d : natural;
      variable mask : unsigned(31 downto 0);

      procedure idle(n : natural) is
      begin
         for i in 1 to n loop wait until rising_edge(clk1x); end loop;
      end procedure;

      procedure wr(a : natural; d : natural) is
      begin
         wait until rising_edge(clk1x);
         bus_addr <= to_unsigned(a, 10);
         bus_dataWrite <= std_logic_vector(to_unsigned(d mod 65536, 16));
         bus_write <= '1';
         wait until rising_edge(clk1x);
         bus_write <= '0';
         if a < 16#180# then tcv.inc(0); else tcv.inc(1); end if;
      end procedure;

      -- a write immediately followed by a read of the same register
      procedure wr_rd(a : natural; d : natural) is
      begin
         wait until rising_edge(clk1x);
         bus_addr <= to_unsigned(a, 10);
         bus_dataWrite <= std_logic_vector(to_unsigned(d mod 65536, 16));
         bus_write <= '1';
         wait until rising_edge(clk1x);
         bus_write <= '0';
         bus_read  <= '1';
         wait until rising_edge(clk1x);
         bus_read  <= '0';
         bus_seen <= true;
         tcv.inc(1);
         tcv.inc(4);
      end procedure;

      procedure rd(a : natural) is
      begin
         wait until rising_edge(clk1x);
         bus_addr <= to_unsigned(a, 10);
         bus_read <= '1';
         wait until rising_edge(clk1x);
         bus_read <= '0';
         bus_seen <= true;
         if a < 16#180# then tcv.inc(2);
         elsif a >= 16#200# and a < 16#260# then tcv.inc(3);
         elsif a = 16#19C# or a = 16#19E# then tcv.inc(5);
         elsif a = 16#1AE# then tcv.inc(6);
         elsif a >= 16#1C0# or a = 16#184# or a = 16#186# or a = 16#1A2# then tcv.inc(7);
         else tcv.inc(4); end if;
      end procedure;

      impure function gap return natural is
         variable q : natural := rs.rnd(100);
      begin
         if wild then
            if q < 50 then return 0; elsif q < 80 then return rs.between(1, 3); else return rs.between(4, 30); end if;
         end if;
         if q < 22 then return 0;
         elsif q < 42 then return 1;
         elsif q < 57 then return rs.between(2, 4);
         elsif q < 72 then return rs.between(5, 20);
         elsif q < 88 then return rs.between(21, 100);
         else return rs.between(101, 700); end if;
      end function;

      impure function pick_addr return natural is
         variable q : natural := rs.rnd(100);
         variable x : natural;
      begin
         if scen = 3 and nhot > 0 and q < 92 then
            return hot(rs.rnd(nhot));
         elsif nhot > 0 and q < 45 then
            x := hot(rs.rnd(nhot));
            if rs.chance(30) then x := x + 2 * rs.rnd(3); end if;
            return x mod 65536;
         elsif q < 75 then return 2 * rs.between(16#100#, 16#6FFF#) + rs.rnd(2);
         elsif q < 88 then return 2 * rs.between(0, 16#FF#) + rs.rnd(2);
         else return 2 * rs.between(16#7000#, 16#7FFF#) + rs.rnd(2); end if;
      end function;

      procedure add_hot(a : natural) is
      begin
         if scen = 3 and nhot >= 3 then return; end if;
         hot(nhot mod 16) := a;
         if nhot < 16 then nhot := nhot + 1; else hot(rs.rnd(16)) := a; end if;
      end procedure;

      impure function rnd16 return natural is
      begin
         return to_integer(rs.u32(15 downto 0));
      end function;

      impure function vol_val return natural is
         variable q : natural := rs.rnd(100);
      begin
         if scen = 6 and q < 70 then
            tcv.inc(25);
            return 16#C000# + rs.between(30, 62);             -- exponential increase, rates around the thresholds
         elsif q < 25 then
            tcv.inc(25);
            return 16#8000# + rs.rnd(16#8000#);
         elsif q < 40 then return 16#3FFF#;
         elsif q < 55 then return 16#1FFF# + rs.rnd(16#2000#);
         else return rs.rnd(16#8000#); end if;
      end function;

      impure function pitch_val return natural is
         variable q : natural := rs.rnd(100);
      begin
         if q < 25 then return 16#1000#;
         elsif q < 55 then return rs.rnd(16#4000#);
         elsif q < 70 then tcv.inc(22); return 16#3FFF# + rs.rnd(16#C002#);
         else return rs.rnd(16#800#); end if;
      end function;

      procedure voice_write(v : natural; r : natural) is
         variable d : natural;
      begin
         case r is
            when 0 | 1 => d := vol_val;
            when 2     => d := pitch_val;
            when 3     => d := pick_addr; add_hot(d);
            when 4 =>
               -- attack mode/shift/step, decay shift, sustain level; favour quick attacks and exponential ones
               if scen = 6 and rs.chance(45) then d := rs.rnd(2) * 16#400# + rs.rnd(4) * 16#100# + rs.rnd(2) * 16#10# + 12 + rs.rnd(4);   -- fast attack and decay to a high sustain level
               elsif scen = 6 and rs.chance(60) then d := 16#8000# + rs.between(10, 11) * 16#400# + rs.rnd(16#400#);
               elsif rs.chance(40) then d := rs.rnd(16#10000#);
               elsif rs.chance(50) then d := 16#8000# + rs.between(10, 31) * 16#400# + rs.rnd(16#400#);
               else d := (rs.rnd(2) * 16#8000#) + (rs.rnd(8) * 16#400#) + rs.rnd(16#400#); end if;
            when 5 =>
               if scen = 6 and rs.chance(60) then d := 16#8000# + rs.between(10, 11) * 16#100# + rs.rnd(4) * 16#40# + rs.rnd(16#40#);   -- exponential increase in the sustain phase
               else d := rs.rnd(16#10000#); end if;
            when 6 => d := rs.rnd(16#8000#);
            when others => d := pick_addr;
         end case;
         wr(v * 16 + r * 2, d);
      end procedure;

      procedure keyon(m : unsigned(23 downto 0)) is
      begin
         if m(15 downto 0) /= x"0000" then wr(16#188#, to_integer(m(15 downto 0))); end if;
         if m(23 downto 16) /= x"00" then wr(16#18A#, to_integer(m(23 downto 16))); end if;
         tcv.inc(8);
      end procedure;

      impure function rnd_mask(nmax : natural) return unsigned is
         variable m : unsigned(23 downto 0) := (others => '0');
      begin
         if rs.chance(8) then return x"FFFFFF"; end if;
         for i in 1 to rs.between(1, nmax) loop
            m(rs.rnd(24)) := '1';
         end loop;
         return m;
      end function;

      procedure set_cnt(mode : natural) is
         variable d : natural;
      begin
         -- keep the shadow's noise, reverb enable, irq enable and cd/ext bits
         d := 16#C000# + ((cnt_sh / 256) mod 64) * 256 + ((cnt_sh / 128) mod 2) * 128 + ((cnt_sh / 64) mod 2) * 64 + mode * 16 + (cnt_sh mod 16);
         wr(16#1AA#, d);
         tcv.inc(10);
      end procedure;

      procedure new_cnt is
         variable d : natural;
      begin
         d := 0;
         if rs.chance(92) then d := d + 16#8000#; end if;
         if rs.chance(90) then d := d + 16#4000#; end if;
         d := d + rs.rnd(64) * 256 + rs.rnd(2) * 128 + rs.rnd(2) * 64 + rs.rnd(16);
         if scen = 3 then d := d - (d / 64 mod 2) * 64 + 64; end if;
         if scen = 4 then d := d - (d / 128 mod 2) * 128 + 128; end if;
         cnt_sh := d;
         wr(16#1AA#, d);
         tcv.inc(10);
      end procedure;

      procedure dma_blocks(nb : natural) is
         variable a   : natural := pick_addr;
         variable per : natural;
      begin
         add_hot(a);
         wr(16#1A6#, a);
         set_cnt(2);
         per := rs.rnd(3);
         for b in 1 to nb loop
            for w in 0 to 7 loop
               wait until rising_edge(clk1x);
               dma_write <= '1';
               if w = 0 then
                  dma_writedata <= std_logic_vector(to_unsigned(rs.rnd(13) + 16 * rs.rnd(5) + 256 * (rs.rnd(2) + 2 * rs.rnd(2) + 4 * rs.rnd(2)), 16));
               else
                  dma_writedata <= std_logic_vector(rs.u32(15 downto 0));
               end if;
               tcv.inc(11);
               if per > 0 then
                  wait until rising_edge(clk1x);
                  dma_write <= '0';
                  idle(rs.rnd(per * 8));
               end if;
            end loop;
         end loop;
         wait until rising_edge(clk1x);
         dma_write <= '0';
         tcv.inc(14);
         for k in 1 to nb * 2 loop
            idle(nb * 4 * 26 / (nb * 2) * 2 + rs.rnd(40));
            rd(16#1AE#);
         end loop;
         idle(rs.rnd(100));
         set_cnt(0);
      end procedure;

      procedure dma_burst(n : natural) is
         variable a : natural := pick_addr;
      begin
         wr(16#1A6#, a);
         set_cnt(2);
         for i in 1 to n loop
            wait until rising_edge(clk1x);
            dma_write <= '1';
            dma_writedata <= std_logic_vector(rs.u32(15 downto 0));
            tcv.inc(11);
         end loop;
         wait until rising_edge(clk1x);
         dma_write <= '0';
         idle(n * 26);
         set_cnt(0);
      end procedure;

      procedure dma_read_words(n : natural) is
         variable a : natural := pick_addr;
      begin
         wr(16#1A6#, a);
         set_cnt(3);
         idle(rs.between(200, 1500));
         for i in 1 to n loop
            wait until rising_edge(clk1x);
            dma_read <= '1';
            tcv.inc(12);
            if rs.chance(50) then
               wait until rising_edge(clk1x);
               dma_read <= '0';
               idle(rs.rnd(30));
            end if;
         end loop;
         wait until rising_edge(clk1x);
         dma_read <= '0';
         idle(rs.rnd(200));
         set_cnt(0);
      end procedure;

      procedure fifo_blocks(nw : natural) is
         variable a : natural := pick_addr;
      begin
         add_hot(a);
         wr(16#1A6#, a);
         set_cnt(1);
         for i in 1 to nw loop
            wr(16#1A8#, rnd16);
            tcv.inc(13);
            idle(gap);
         end loop;
         idle(rs.rnd(400));
         set_cnt(0);
      end procedure;

      procedure global_write is
         variable q : natural := rs.rnd(100);
         variable a : natural;
      begin
         if q < 14 then wr(16#180# + 2 * rs.rnd(2), vol_val);
         elsif q < 24 then new_cnt;
         elsif q < 34 then wr(16#190# + 2 * rs.rnd(4), rnd16); tcv.inc(26);
         elsif q < 44 then wr(16#194# + 2 * rs.rnd(2), rnd16); tcv.inc(24);
         elsif q < 54 then wr(16#198# + 2 * rs.rnd(2), rnd16);
         elsif q < 62 then wr(16#1B0# + 2 * rs.rnd(4), vol_val);
         elsif q < 68 then wr(16#1AC#, rnd16);
         elsif q < 72 then wr(16#1A6#, pick_addr);
         elsif q < 82 then
            a := 16#1C0# + 2 * rs.rnd(32);
            wr(a, rnd16); tcv.inc(23);
         elsif q < 90 then
            wr(16#184# + 2 * rs.rnd(2), rnd16); tcv.inc(23);
         elsif q < 95 then
            wr(16#1A2#, 2 * rs.between(16#7000#, 16#7FFF#)); tcv.inc(23);
         else
            wr(16#1A2#, pick_addr); tcv.inc(23);
         end if;
      end procedure;

      procedure random_read is
         variable q : natural := rs.rnd(100);
      begin
         if q < 25 then rd(rs.rnd(24) * 16 + rs.rnd(8) * 2);
         elsif q < 40 then rd(16#200# + 2 * rs.rnd(48));
         elsif q < 52 then rd(16#19C# + 2 * rs.rnd(2));
         elsif q < 64 then rd(16#1AE#);
         elsif q < 72 then rd(16#1B8# + 2 * rs.rnd(2));
         elsif q < 82 then rd(16#1C0# + 2 * rs.rnd(32));
         elsif q < 92 then rd(16#180# + 2 * rs.rnd(32));
         else rd(2 * rs.rnd(512)); end if;
      end procedure;

      -- the top's reset sequencer: reset, SS_reset for 2 clocks, reset for 61 clocks; the SPU clears its RAMs for 192 clocks after SS_reset
      procedure power_up is
      begin
         reset <= '1';
         idle(6);
         reset <= '0'; ss_rst <= '1';
         idle(2);
         ss_rst <= '0'; reset <= '1';
         idle(61);
         reset <= '0';
         idle(200);
      end procedure;

      procedure init_all is
      begin
         for vv in 0 to 23 loop
            for rr in 0 to 7 loop voice_write(vv, rr); end loop;
         end loop;
         wr(16#180#, 16#3FFF#); wr(16#182#, 16#3FFF#);
         wr(16#1B0#, 16#7FFF#); wr(16#1B2#, 16#7FFF#); wr(16#1B4#, 16#4000#); wr(16#1B6#, 16#4000#);
         for i in 0 to 31 loop wr(16#1C0# + 2 * i, rnd16); end loop;
         wr(16#184#, 16#3000#); wr(16#186#, 16#3000#);
         wr(16#1A2#, 2 * 16#7C00#);
         new_cnt;
         wr(16#1A4#, pick_addr);
      end procedure;

      procedure init_bw(fast : boolean) is
         variable p : natural;
      begin
         if fast then p := 16#4000#; else p := 16#1000#; end if;
         for vv in 0 to 23 loop
            wr(vv * 16 + 0, 16#2000#); wr(vv * 16 + 2, 16#2000#);
            wr(vv * 16 + 4, p);
            add_hot(2 * (16#200# + vv * 16#380# + rs.rnd(16#40#)));
            wr(vv * 16 + 6, hot((nhot - 1) mod 16));
            wr(vv * 16 + 8, 16#000F#); wr(vv * 16 + 10, 16#5FC0#);
         end loop;
         wr(16#180#, 16#3FFF#); wr(16#182#, 16#3FFF#);
         wr(16#1AA#, 16#C000#);
         keyon(x"FFFFFF");
      end procedure;

      procedure one_action is
         variable q : natural := rs.rnd(100);
         variable vv, rr : natural;
      begin
         if scen = 6 and rs.chance(12) then
            -- a fixed volume near 0x6000, one sample later an exponential increase from there
            vv := rs.rnd(24); rr := rs.rnd(2);
            wr(vv * 16 + rr * 2, 16#3000# + rs.rnd(16#500#));
            idle(rs.between(900, 1500));
            wr(vv * 16 + rr * 2, 16#C000# + rs.between(24, 62));
            return;
         end if;
         case scen is
            when 1 => if q < 60 then q := 30 + (q mod 10); end if;                    -- many key-ons
            when 2 => if q < 50 then q := 58 + (q mod 12); end if;                    -- transfers
            when 3 => if q < 40 then q := 70 + (q mod 3); end if;                     -- IRQ addresses
            when 5 => if q < 55 then q := 58 + (q mod 12); end if;                    -- writes into live blocks
            when 6 => if q < 60 then q := q mod 40; end if;                           -- voice writes and key-ons
            when others => null;
         end case;
         if q < 30 then voice_write(rs.rnd(24), rs.rnd(8));
         elsif q < 40 then keyon(rnd_mask(3));
         elsif q < 44 then
            mask := rs.u32; mask(31 downto 24) := x"00";
            if rs.chance(70) then mask := mask and rs.u32; end if;
            wr(16#18C#, to_integer(mask(15 downto 0))); wr(16#18E#, to_integer(mask(23 downto 16))); tcv.inc(9);
         elsif q < 48 then
            if rs.chance(40) then
               wr(16#190#, to_integer(rs.u32(15 downto 0)));
            else
               wr(16#194# + 2 * rs.rnd(2), to_integer(rs.u32(15 downto 0)) mod 65536);
            end if;
         elsif q < 58 then
            if rs.chance(12) then
               wr_rd(16#180# + 2 * rs.rnd(64), rnd16);
            elsif rs.chance(6) then
               wr_rd(rs.rnd(24) * 16 + rs.rnd(8) * 2, rnd16);
            else global_write; end if;
         elsif q < 62 then fifo_blocks(rs.between(1, 24));
         elsif q < 67 then
            if rs.chance(12) then dma_burst(rs.between(120, 170)); else dma_blocks(rs.between(1, 4)); end if;
         elsif q < 70 then dma_read_words(rs.between(1, 40));
         elsif q < 73 then
            if nhot > 0 and rs.chance(70) then wr(16#1A4#, hot(rs.rnd(nhot)) + rs.rnd(2 + 2 * rs.rnd(2))); tcv.inc(16);
            else wr(16#1A4#, pick_addr); end if;
            if rs.chance(40) then new_cnt; end if;
            if rs.chance(30) then   -- acknowledge, then usually re-arm
               wr(16#1AA#, (cnt_sh / 128) * 128);
               if rs.chance(70) then idle(rs.rnd(8)); wr(16#1AA#, cnt_sh + 64 - (cnt_sh / 64 mod 2) * 64); end if;
            end if;
         else random_read;
         end if;
      end procedure;

   begin
      rs.seed(G_SEED * 7919 + 13);
      scen := G_SCEN;
      wild := (G_SUITE = "wild");
      power_up;
      armed <= true;
      if G_SUITE = "bw" then
         init_bw(G_SCEN = 0);
      else
         init_all;
      end if;
      t_end := G_COUNT * 768;
      while stim_cycle < t_end loop
         if G_SUITE = "bw" then
            rd(16#19C#);       -- steady playback with a status read now and then
            idle(rs.between(200, 900));
         else
            one_action;
            idle(gap);
         end if;
         if G_SUITE = "reset" and rs.chance(3) then
            if rs.chance(50) then
               -- a reset inside the four-clock output stage or CD stage of the golden
               wait until (g_eps < 4 or g_cps < 4) for 60 us;
            end if;
            wait until rising_edge(clk1x);
            tcv.inc(17);
            power_up;
            if rs.chance(60) then init_all; end if;
         end if;
         if wild and rs.chance(20) then
            a := rs.rnd(512);
            if a / 2 = 16#1AA# / 2 and rs.chance(90) then a := a + 4; end if;
            wr(a, rnd16);
         end if;
      end loop;
      idle(2);
      finished <= true;
      wait;
   end process;

   p_stimclk : process (clk1x) begin
      if rising_edge(clk1x) then stim_cycle <= stim_cycle + 1; end if;
   end process;

end architecture;
