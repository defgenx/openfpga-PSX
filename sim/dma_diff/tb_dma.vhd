-- DMA differential testbench: rtl/dma.vhd (ref) against G_DUT ("pocket" = rtl/dma_pocket.vhd, "golden" for the
-- harness self-test), same inputs, every output compared at every clk3x falling edge (3 times per clk1x cycle).
-- Don't-care: DMA_GPU_write and DMA_MDEC_write while their enable is low (the consumers gate on the enable).
--
-- Environment (all inputs are shared; device models answer the reference's outputs):
--   - clk3x = 3 x clk1x, edges coincident; clk3xIndex high before the middle clk3x edge of each clk1x cycle
--   - RAM model with the ram_* / dma_* protocol of ram_adapter.v: per ram_ena a dma_reqprocessed pulse after
--     G_LAT1 cycles, then 1+ram_cnt consecutive dma_wr beats after G_LAT2 cycles; the DMA FIFO is drained on clk3x
--   - device request / data lines random; cpuPaused follows the top's switch (mode 0) or random stretches (mode 1)
--   - bus accesses from the vector file, 1-cycle strobes; writes only while the reference is not transferring
-- Vector file commands: see gen_vectors.py.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
library work;
use work.dma_diff_pkg.all;
use work.trace_cmp_pkg.all;

entity tb_dma is
   generic
   (
      G_VECFILE   : string  := "vec.txt";
      G_DUT       : string  := "pocket";
      G_MODE      : integer := 0;        -- 0 top-like cpuPaused/ce, 1 random cpuPaused/ce/canDMA
      G_SEED      : integer := 1;
      G_FAULT_AT  : integer := -1;       -- compare sample at which the DUT output G_FAULT_SIG is flipped (self-test)
      G_FAULT_SIG : integer := 0;
      G_ECHO      : integer := 0         -- 1: report every vector-file comment line with the cycle number
   );
end entity;

architecture sim of tb_dma is

   shared variable cmp : trace_cmp_t;

   -- 2 MB word RAM
   type ram_t is protected
      procedure init;
      impure function rd(a : natural) return std_logic_vector;
      procedure wr(a : natural; d : std_logic_vector(31 downto 0));
   end protected;

   type ram_t is protected body
      type mem_t is array (0 to 2**19 - 1) of std_logic_vector(31 downto 0);
      variable m : mem_t;
      procedure init is
         variable s : unsigned(31 downto 0);
      begin
         for a in 0 to 2**19 - 1 loop
            s := resize(to_unsigned(a, 32) * x"9E3779B1", 32) + x"5851F42D";
            s := s xor (s sll 13); s := s xor (s srl 17); s := s xor (s sll 5);
            m(a) := std_logic_vector(s);
         end loop;
      end procedure;
      impure function rd(a : natural) return std_logic_vector is
      begin
         return m(a mod 2**19);
      end function;
      procedure wr(a : natural; d : std_logic_vector(31 downto 0)) is
      begin
         m(a mod 2**19) := d;
      end procedure;
   end protected body;

   shared variable ram : ram_t;

   function xs(s : unsigned(31 downto 0)) return unsigned is
      variable r : unsigned(31 downto 0) := s;
   begin
      r := r xor (r sll 13);
      r := r xor (r srl 17);
      r := r xor (r sll 5);
      return r;
   end function;

   function pct(s : unsigned(31 downto 0); p : integer) return boolean is
   begin
      return (to_integer(s(23 downto 8)) mod 100) < p;
   end function;

   signal clk1x, clk3x, clk3xIndex : std_logic := '0';
   signal reset      : std_logic;
   signal rst_seq    : std_logic := '1';
   signal wd_rst     : std_logic := '0';   -- watchdog: a transfer longer than 40000 cycles (200000 for the OTC channel) is reset: REP_target would leave its 20 bits
   signal ce_seq     : std_logic := '1';
   signal ce_rnd     : std_logic := '1';
   signal ram_idle   : std_logic := '1';     -- RAM model has nothing in flight
   signal ce         : std_logic;
   signal TURBO, TURBO_CACHE, ram8mb, ignoreCDTiming : std_logic := '0';
   signal canDMA     : std_logic := '1';
   signal cpuPaused  : std_logic := '0';
   signal cp_top, cp_wild : std_logic := '0';

   signal dma_wr, dma_reqprocessed : std_logic := '0';
   signal dma_data   : std_logic_vector(31 downto 0) := (others => '0');
   signal ram_dmafifo_read : std_logic := '0';
   signal gpu_req, mdec_wreq, mdec_rreq, spu_req : std_logic := '0';
   signal req_set    : std_logic_vector(3 downto 0) := "0000";   -- REQ command: levels to force
   signal req_n      : natural := 0;
   signal gpu_rd, mdec_rd : std_logic_vector(31 downto 0) := (others => '0');
   signal cd_rd   : std_logic_vector(7 downto 0) := (others => '0');
   signal spu_rd  : std_logic_vector(15 downto 0) := (others => '0');
   signal cd_memctrl : unsigned(13 downto 0) := (others => '0');
   signal com0_delay : unsigned(3 downto 0) := (others => '0');
   signal spu_timing_on : std_logic := '0';
   signal spu_timing_value : unsigned(3 downto 0) := (others => '0');
   signal bus_addr   : unsigned(6 downto 0) := (others => '0');
   signal bus_data   : std_logic_vector(31 downto 0) := (others => '0');
   signal bus_read, bus_write : std_logic := '0';

   -- device model parameters (DEV command)
   signal dev_gpu_flip, dev_mdw_flip, dev_mdr_flip, dev_spu_flip : integer := 2;
   signal dev_fifo_p  : integer := 50;     -- percent per clk3x cycle that the FIFO drain starts a read
   signal dev_lat1_min, dev_lat1_max, dev_lat2_min, dev_lat2_max : integer := 2;
   signal dev_busy_p  : integer := 5;      -- percent per cycle that canDMA drops (top mode)

   signal gi : dma_in_t;
   signal go, do : dma_out_t;

   -- reference internals (isOn = dmaState /= OFF), published by the probe block below
   signal ref_isOn, ref_todev : std_logic := '0';
   signal ref_chan : integer range 0 to 6 := 0;
   signal ref_trig : integer range 0 to 6 := 0;

   signal cycle_n  : natural := 0;
   signal armed    : std_logic := '0';
   signal finished : boolean := false;

   -- coverage
   type cnt_t is array (natural range <>) of natural;
   shared variable cov_xfer : cnt_t(0 to 13) := (others => 0);
   shared variable cov_ev   : cnt_t(0 to 31) := (others => 0);
   constant EV_RAMRD : natural := 0;  -- dma_wr beats
   constant EV_RAMWR : natural := 1;  -- dma_cache_write
   constant EV_GPUW  : natural := 2;
   constant EV_MDECW : natural := 3;
   constant EV_SPUW  : natural := 4;
   constant EV_GPUR  : natural := 5;
   constant EV_MDECR : natural := 6;
   constant EV_CDR   : natural := 7;
   constant EV_SPUR  : natural := 8;
   constant EV_IRQ   : natural := 9;
   constant EV_ECHOP : natural := 10;
   constant EV_ECPU  : natural := 11;
   constant EV_EFIFO : natural := 12;
   constant EV_BUSW  : natural := 13;
   constant EV_BUSR  : natural := 14;
   constant EV_RST   : natural := 15;
   constant EV_PAUSE : natural := 16;
   constant EV_STALL : natural := 17;
   constant EV_CNT0  : natural := 18;  -- ram_ena with ram_cnt 0..3 (18..21)
   constant EV_ENA_BUSY : natural := 22; -- ram_ena while cpuPaused = 0 never counted; here: starts with canDMA low
   constant EV_BUSCOIN : natural := 23;  -- bus strobe in the cycle the reference starts a transfer
   constant EV_WAITING : natural := 24;  -- DMA_GPU_waiting cycles
   constant EV_FIFOREAD : natural := 25;
   constant EV_TO : natural := 26;       -- IDLE timeouts
   constant EV_WDOG : natural := 27;     -- watchdog resets

   -- hex string to unsigned
   function hex(s : string) return unsigned is
      variable r : unsigned(31 downto 0) := (others => '0');
      variable d : integer;
   begin
      for k in s'range loop
         case s(k) is
            when '0' to '9' => d := character'pos(s(k)) - character'pos('0');
            when 'a' to 'f' => d := character'pos(s(k)) - character'pos('a') + 10;
            when 'A' to 'F' => d := character'pos(s(k)) - character'pos('A') + 10;
            when others     => d := 0;
         end case;
         r := r(27 downto 0) & to_unsigned(d, 4);
      end loop;
      return r;
   end function;

   function dec(s : string) return integer is
      variable r : integer := 0;
      variable neg : boolean := false;
   begin
      for k in s'range loop
         if s(k) = '-' then neg := true;
         elsif s(k) >= '0' and s(k) <= '9' then r := r * 10 + character'pos(s(k)) - character'pos('0');
         end if;
      end loop;
      if neg then return -r; else return r; end if;
   end function;

begin

   ----------------------------------------------------------------- clocks
   clkgen : process
      variable ph : natural := 0;
   begin
      loop
         case ph is
            when 0 => clk3x <= '1'; clk1x <= '1';
            when 1 => clk3x <= '0'; clk3xIndex <= '1';
            when 2 => clk3x <= '1';
            when 3 => clk3x <= '0'; clk1x <= '0'; clk3xIndex <= '0';
            when 4 => clk3x <= '1';
            when others => clk3x <= '0';
         end case;
         ph := (ph + 1) mod 6;
         wait for 1 ns;
         exit when finished;
      end loop;
      wait;
   end process;

   reset <= rst_seq or wd_rst;
   ce <= ce_seq and ce_rnd;
   cpuPaused <= cp_top when G_MODE = 0 else (cp_top and not cp_wild);

   gi <= (clk1x => clk1x, clk3x => clk3x, clk3xIndex => clk3xIndex, ce => ce, reset => reset,
          TURBO => TURBO, TURBO_CACHE => TURBO_CACHE, ram8mb => ram8mb, ignoreCDTiming => ignoreCDTiming,
          canDMA => canDMA, cpuPaused => cpuPaused, dma_wr => dma_wr, dma_reqprocessed => dma_reqprocessed,
          dma_data => dma_data, ram_dmafifo_read => ram_dmafifo_read, gpu_dmaRequest => gpu_req,
          DMA_GPU_read => gpu_rd, mdec_dmaWriteRequest => mdec_wreq, mdec_dmaReadRequest => mdec_rreq,
          DMA_MDEC_read => mdec_rd, cd_memctrl => cd_memctrl, com0_delay => com0_delay, DMA_CD_read => cd_rd,
          spu_timing_on => spu_timing_on, spu_timing_value => spu_timing_value, spu_dmaRequest => spu_req,
          DMA_SPU_read => spu_rd, bus_addr => bus_addr, bus_dataWrite => bus_data, bus_read => bus_read,
          bus_write => bus_write);

   ref : entity work.dma_side generic map (G_IMPL => "golden")  port map (i => gi, o => go);
   dut : entity work.dma_side generic map (G_IMPL => G_DUT)     port map (i => gi, o => do);

   probe : block
      alias a_isOn  is <<signal .tb_dma.ref.gold.idma.isOn : std_logic>>;
      alias a_chan  is <<signal .tb_dma.ref.gold.idma.activeChannel : integer range 0 to 6>>;
      alias a_todev is <<signal .tb_dma.ref.gold.idma.toDevice : std_logic>>;
      alias a_trig  is <<signal .tb_dma.ref.gold.idma.triggerchannel : integer range 0 to 6>>;
   begin
      ref_isOn  <= a_isOn;
      ref_chan  <= a_chan;
      ref_todev <= a_todev;
      ref_trig  <= a_trig;
   end block;

   ----------------------------------------------------------------- cpuPaused / ce / canDMA
   -- the top's switch (psx_top_pocket.vhd 819-824), driven by the reference
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (reset = '1') then
            cp_top <= '0';
         elsif ((cp_top = '1' and go.dmaOn = '1') or (go.dmaRequest = '1' and canDMA = '1')) then
            cp_top <= '1';
         elsif (go.dmaOn = '0') then
            cp_top <= '0';
         end if;
      end if;
   end process;

   process (clk1x)
      variable r   : unsigned(31 downto 0) := to_unsigned(G_SEED * 7 + 11, 32);
      variable seg : integer := 0;
      variable ceseg : integer := 0;
   begin
      if rising_edge(clk1x) then
         r := xs(r);
         -- cpuPaused glitches (mode 1): cpuPaused drops for 1..40 cycles, rarely enough that REP_counter still
         -- reaches its target
         if (seg > 0) then
            seg := seg - 1;
            if (seg = 0) then cp_wild <= '0'; end if;
         elsif (G_MODE = 1 and (to_integer(r(23 downto 8)) mod 5000) = 0) then
            cp_wild <= '1';
            seg := 1 + (to_integer(r(3 downto 0)) mod 40) + (to_integer(r(30 downto 28)) mod 2);
         end if;
         r := xs(r);
         if (ceseg > 0) then
            ceseg := ceseg - 1;
            if (ceseg = 0) then ce_rnd <= '1'; end if;
         elsif (G_MODE = 1 and pct(r, 3) and ram_idle = '1' and go.ram_ena = '0' and ref_isOn = '0' and go.dmaRequest = '0') then
            ce_rnd <= '0';
            ceseg  := 1 + (to_integer(r(7 downto 0)) mod 6);
         end if;
      end if;
   end process;

   process (clk1x)
      variable r    : unsigned(31 downto 0) := to_unsigned(G_SEED * 13 + 5, 32);
      variable busy : integer := 0;
   begin
      if rising_edge(clk1x) then
         r := xs(r);
         if (busy > 0) then
            busy := busy - 1;
         elsif (bus_read = '1' or bus_write = '1') then
            busy := 2;
         elsif (pct(r, dev_busy_p) or (G_MODE = 1 and pct(r, 25))) then
            busy := 1 + (to_integer(r(19 downto 16)) mod 6);
         end if;
         if (busy > 0) then canDMA <= '0'; else canDMA <= '1'; end if;
      end if;
   end process;

   ----------------------------------------------------------------- device request / data lines
   process (clk1x)
      variable r : unsigned(31 downto 0) := to_unsigned(G_SEED * 17 + 3, 32);
      variable seen : natural := 0;
   begin
      if rising_edge(clk1x) then
         if (req_n /= seen) then
            seen := req_n;
            gpu_req <= req_set(0); mdec_wreq <= req_set(1); mdec_rreq <= req_set(2); spu_req <= req_set(3);
         end if;
         r := xs(r); if pct(r, dev_gpu_flip) then gpu_req  <= not gpu_req;  end if;
         r := xs(r); if pct(r, dev_mdw_flip) then mdec_wreq <= not mdec_wreq; end if;
         r := xs(r); if pct(r, dev_mdr_flip) then mdec_rreq <= not mdec_rreq; end if;
         r := xs(r); if pct(r, dev_spu_flip) then spu_req  <= not spu_req;  end if;
         r := xs(r); gpu_rd  <= std_logic_vector(r);
         r := xs(r); mdec_rd <= std_logic_vector(r);
         r := xs(r); cd_rd   <= std_logic_vector(r(7 downto 0));
         r := xs(r); spu_rd  <= std_logic_vector(r(15 downto 0));
      end if;
   end process;

   ----------------------------------------------------------------- RAM model, read side
   process (clk1x)
      type adr_q_t is array (0 to 7) of natural;
      type cnt_q_t is array (0 to 7) of natural;
      variable qa : adr_q_t;
      variable qc : cnt_q_t;
      variable qn : natural := 0;
      variable ph : natural := 0;          -- 0 idle, 1 wait reqprocessed, 2 wait burst, 3 burst
      variable wt : integer := 0;
      variable beat : natural := 0;
      variable r  : unsigned(31 downto 0) := to_unsigned(G_SEED * 29 + 1, 32);
      variable lo, hi : integer;
      variable ena_q  : std_logic := '0';
   begin
      if rising_edge(clk1x) then
         dma_wr           <= '0';
         dma_reqprocessed <= '0';
         r := xs(r);
         dma_data <= std_logic_vector(r);        -- garbage unless dma_wr
         if (go.ram_ena = '1' and ena_q = '0' and reset = '0') then
            assert qn < 8 report "ERROR RAM request queue overflow" severity failure;
            qa(qn) := to_integer(unsigned(go.ram_Adr(20 downto 2)));
            qc(qn) := to_integer(unsigned(go.ram_cnt));
            qn := qn + 1;
            cov_ev(EV_CNT0 + to_integer(unsigned(go.ram_cnt))) := cov_ev(EV_CNT0 + to_integer(unsigned(go.ram_cnt))) + 1;
         end if;
         ena_q := go.ram_ena;                    -- a pulse held across a ce pause is one request
         case ph is
            when 0 =>
               if (qn > 0) then
                  r := xs(r);
                  lo := dev_lat1_min; hi := dev_lat1_max;
                  wt := lo + (to_integer(r(15 downto 4)) mod (hi - lo + 1));
                  ph := 1;
               end if;
            when 1 =>
               if (wt <= 0) then
                  dma_reqprocessed <= '1';
                  r := xs(r);
                  lo := dev_lat2_min; hi := dev_lat2_max;
                  wt := lo + (to_integer(r(15 downto 4)) mod (hi - lo + 1));
                  ph := 2;
               else
                  wt := wt - 1;
               end if;
            when 2 =>
               if (wt <= 0) then
                  ph := 3; beat := 0;
               else
                  wt := wt - 1;
               end if;
            when others => null;
         end case;
         if (ph = 0 and qn = 0) then ram_idle <= '1'; else ram_idle <= '0'; end if;
         if (ph = 3) then
            dma_wr   <= '1';
            dma_data <= ram.rd(qa(0) + beat);
            cov_ev(EV_RAMRD) := cov_ev(EV_RAMRD) + 1;
            if (beat = qc(0)) then
               for k in 0 to 6 loop qa(k) := qa(k + 1); qc(k) := qc(k + 1); end loop;
               qn := qn - 1;
               ph := 0;
            else
               beat := beat + 1;
            end if;
         end if;
      end if;
   end process;

   ----------------------------------------------------------------- RAM model, DMA FIFO drain (clk3x)
   process (clk3x)
      variable r     : unsigned(31 downto 0) := to_unsigned(G_SEED * 31 + 9, 32);
      variable stable : natural := 0;
      variable skip  : natural := 0;
   begin
      if rising_edge(clk3x) then
         r := xs(r);
         ram_dmafifo_read <= '0';
         if (go.ram_dmafifo_empty = '0') then
            if (stable < 3) then stable := stable + 1; end if;
         else
            stable := 0;
         end if;
         if (skip > 0) then
            skip := skip - 1;
         elsif (stable >= 2 and ram_dmafifo_read = '0' and pct(r, dev_fifo_p)) then
            ram_dmafifo_read <= '1';
            ram.wr(to_integer(unsigned(go.ram_dmafifo_adr(20 downto 2))), go.ram_dmafifo_data);
            skip := 1;
            stable := 0;
            cov_ev(EV_FIFOREAD) := cov_ev(EV_FIFOREAD) + 1;
         end if;
      end if;
   end process;

   ----------------------------------------------------------------- compare and coverage
   process
      variable k      : natural := 0;
      variable d      : dma_out_t;
      variable on_q   : std_logic := '0';
      variable fault_n : integer := 0;
      variable on_len  : natural := 0;
      variable wd_len  : natural := 0;

      procedure fault(sig : integer; v : inout dma_out_t) is
      begin
         case sig is
            when 0 => v.bus_dataRead(0)      := not v.bus_dataRead(0);
            when 1 => v.ram_Adr(2)           := not v.ram_Adr(2);
            when 2 => v.dmaOn                := not v.dmaOn;
            when 3 => v.dma_cache_data(3)    := not v.dma_cache_data(3);
            when 4 => v.ram_dmafifo_data(0)  := not v.ram_dmafifo_data(0);
            when 5 => v.irqOut               := not v.irqOut;
            when 6 => v.ram_dmafifo_adr(5)   := not v.ram_dmafifo_adr(5);
            when 7 => v.dmaRequest           := not v.dmaRequest;
            when others => v.ram_cnt(0)      := not v.ram_cnt(0);
         end case;
      end procedure;
   begin
      cmp.configure(max_log => 12);
      wait until finished = false and armed = '1';
      loop
         wait until falling_edge(clk3x);
         exit when finished;
         d := do;
         if (fault_n = G_FAULT_AT) then fault(G_FAULT_SIG, d); end if;
         fault_n := fault_n + 1;
         cmp.compare("errorCHOP", cycle_n, go.errorCHOP, d.errorCHOP);
         cmp.compare("errorDMACPU", cycle_n, go.errorDMACPU, d.errorDMACPU);
         cmp.compare("errorDMAFIFO", cycle_n, go.errorDMAFIFO, d.errorDMAFIFO);
         cmp.compare("dmaRequest", cycle_n, go.dmaRequest, d.dmaRequest);
         cmp.compare("dmaStallCPU", cycle_n, go.dmaStallCPU, d.dmaStallCPU);
         cmp.compare("dmaOn", cycle_n, go.dmaOn, d.dmaOn);
         cmp.compare("irqOut", cycle_n, go.irqOut, d.irqOut);
         cmp.compare("ram_Adr", cycle_n, go.ram_Adr, d.ram_Adr);
         cmp.compare("ram_cnt", cycle_n, go.ram_cnt, d.ram_cnt);
         cmp.compare("ram_ena", cycle_n, go.ram_ena, d.ram_ena);
         cmp.compare("ram_dmafifo_adr", cycle_n, go.ram_dmafifo_adr, d.ram_dmafifo_adr);
         cmp.compare("ram_dmafifo_data", cycle_n, go.ram_dmafifo_data, d.ram_dmafifo_data);
         cmp.compare("ram_dmafifo_empty", cycle_n, go.ram_dmafifo_empty, d.ram_dmafifo_empty);
         cmp.compare("dma_cache_Adr", cycle_n, go.dma_cache_Adr, d.dma_cache_Adr);
         cmp.compare("dma_cache_data", cycle_n, go.dma_cache_data, d.dma_cache_data);
         cmp.compare("dma_cache_write", cycle_n, go.dma_cache_write, d.dma_cache_write);
         cmp.compare("DMA_GPU_waiting", cycle_n, go.DMA_GPU_waiting, d.DMA_GPU_waiting);
         cmp.compare("DMA_GPU_writeEna", cycle_n, go.DMA_GPU_writeEna, d.DMA_GPU_writeEna);
         cmp.compare("DMA_GPU_readEna", cycle_n, go.DMA_GPU_readEna, d.DMA_GPU_readEna);
         cmp.compare("DMA_GPU_write", cycle_n, go.DMA_GPU_write, d.DMA_GPU_write, (31 downto 0 => go.DMA_GPU_writeEna));
         cmp.compare("DMA_MDEC_writeEna", cycle_n, go.DMA_MDEC_writeEna, d.DMA_MDEC_writeEna);
         cmp.compare("DMA_MDEC_readEna", cycle_n, go.DMA_MDEC_readEna, d.DMA_MDEC_readEna);
         cmp.compare("DMA_MDEC_write", cycle_n, go.DMA_MDEC_write, d.DMA_MDEC_write, (31 downto 0 => go.DMA_MDEC_writeEna));
         cmp.compare("DMA_CD_readEna", cycle_n, go.DMA_CD_readEna, d.DMA_CD_readEna);
         cmp.compare("DMA_SPU_writeEna", cycle_n, go.DMA_SPU_writeEna, d.DMA_SPU_writeEna);
         cmp.compare("DMA_SPU_readEna", cycle_n, go.DMA_SPU_readEna, d.DMA_SPU_readEna);
         cmp.compare("DMA_SPU_write", cycle_n, go.DMA_SPU_write, d.DMA_SPU_write);
         cmp.compare("bus_dataRead", cycle_n, go.bus_dataRead, d.bus_dataRead);
         cmp.compare("SS_idle", cycle_n, go.SS_idle, d.SS_idle);
         k := k + 1;
         if (k mod 3 = 0) then
            cycle_n <= cycle_n + 1;
         end if;
         -- coverage, once per clk1x cycle
         if (k mod 3 = 1) then
            if (go.dma_cache_write = '1')    then cov_ev(EV_RAMWR) := cov_ev(EV_RAMWR) + 1; end if;
            if (go.DMA_GPU_writeEna = '1')   then cov_ev(EV_GPUW)  := cov_ev(EV_GPUW) + 1; end if;
            if (go.DMA_MDEC_writeEna = '1')  then cov_ev(EV_MDECW) := cov_ev(EV_MDECW) + 1; end if;
            if (go.DMA_SPU_writeEna = '1')   then cov_ev(EV_SPUW)  := cov_ev(EV_SPUW) + 1; end if;
            if (go.DMA_GPU_readEna = '1')    then cov_ev(EV_GPUR)  := cov_ev(EV_GPUR) + 1; end if;
            if (go.DMA_MDEC_readEna = '1')   then cov_ev(EV_MDECR) := cov_ev(EV_MDECR) + 1; end if;
            if (go.DMA_CD_readEna = '1')     then cov_ev(EV_CDR)   := cov_ev(EV_CDR) + 1; end if;
            if (go.DMA_SPU_readEna = '1')    then cov_ev(EV_SPUR)  := cov_ev(EV_SPUR) + 1; end if;
            if (go.irqOut = '1')             then cov_ev(EV_IRQ)   := cov_ev(EV_IRQ) + 1; end if;
            if (go.errorCHOP = '1')          then cov_ev(EV_ECHOP) := cov_ev(EV_ECHOP) + 1; end if;
            if (go.errorDMACPU = '1')        then cov_ev(EV_ECPU)  := cov_ev(EV_ECPU) + 1; end if;
            if (go.errorDMAFIFO = '1')       then cov_ev(EV_EFIFO) := cov_ev(EV_EFIFO) + 1; end if;
            if (go.dmaStallCPU = '1')        then cov_ev(EV_STALL) := cov_ev(EV_STALL) + 1; end if;
            if (go.DMA_GPU_waiting = '1')    then cov_ev(EV_WAITING) := cov_ev(EV_WAITING) + 1; end if;
            if (bus_write = '1' and reset = '0') then cov_ev(EV_BUSW) := cov_ev(EV_BUSW) + 1; end if;
            if (bus_read = '1' and reset = '0')  then cov_ev(EV_BUSR) := cov_ev(EV_BUSR) + 1; end if;
            if (ref_isOn = '1' and on_q = '0') then
               if (ref_todev = '1') then
                  cov_xfer(ref_chan * 2 + 1) := cov_xfer(ref_chan * 2 + 1) + 1;
               else
                  cov_xfer(ref_chan * 2)     := cov_xfer(ref_chan * 2) + 1;
               end if;
            end if;
            on_q := ref_isOn;
            if (wd_rst = '1') then
               wd_len := wd_len + 1;
               if (wd_len >= 70) then wd_rst <= '0'; end if;
            end if;
            if (ref_isOn = '1') then
               on_len := on_len + 1;
               if ((on_len >= 40000 and ref_chan /= 6) or on_len >= 200000) and wd_rst = '0' and not (go.dmaRequest = '1' and ref_trig < 2) then
                  wd_rst <= '1';
                  wd_len := 0;
                  cov_ev(EV_WDOG) := cov_ev(EV_WDOG) + 1;
               end if;
            else
               on_len := 0;
            end if;
         end if;
      end loop;
      wait;
   end process;

   ----------------------------------------------------------------- sequencer
   process
      file f : text;
      variable l : line;
      variable cmd, a1, a2, a3, a4 : string(1 to 24);
      variable n0, n1, n2, n3, n4 : natural;
      variable status : file_open_status;
      variable idle_n, to_n : natural;
      variable ok : boolean;
      variable r : unsigned(31 downto 0) := to_unsigned(G_SEED * 37 + 2, 32);

      procedure tick is
      begin
         wait until rising_edge(clk1x);
         wait for 200 ps;
      end procedure;

      procedure ticks(n : natural) is
      begin
         for i in 1 to n loop tick; end loop;
      end procedure;

      procedure next_tok(variable ln : inout line; variable t : out string(1 to 24); variable n : out natural) is
         variable c : character;
         variable good : boolean;
         variable cnt : natural := 0;
      begin
         t := (others => ' ');
         loop
            read(ln, c, good);
            exit when not good or (c /= ' ' and c /= HT);
         end loop;
         while good and c /= ' ' and c /= HT loop
            cnt := cnt + 1;
            if cnt <= 24 then t(cnt) := c; end if;
            read(ln, c, good);
         end loop;
         n := cnt;
      end procedure;

      procedure garbage is
      begin
         r := xs(r);
         bus_addr <= unsigned(r(6 downto 0));
         r := xs(r);
         bus_data <= std_logic_vector(r);
      end procedure;

      procedure bus_op(isw : boolean; a : unsigned(6 downto 0); d : std_logic_vector(31 downto 0)) is
         variable guard : natural := 0;
      begin
         loop
            ok := true;
            if (G_MODE = 0 and cpuPaused = '1') then ok := false; end if;
            if (isw and (ref_isOn = '1' or reset = '1')) then ok := false; end if;
            exit when ok;
            guard := guard + 1;
            assert guard < 2000000 report "ERROR bus slot never opened" severity failure;
            garbage;
            tick;
         end loop;
         if (G_ECHO >= 2) then
            report "BUS " & boolean'image(isw) & " addr=" & to_hstring(a) & " data=" & to_hstring(d) & " cycle=" & integer'image(cycle_n) severity note;
         end if;
         bus_addr <= a;
         bus_data <= d;
         if (isw) then bus_write <= '1'; else bus_read <= '1'; end if;
         if (go.dmaRequest = '1' and canDMA = '1') then cov_ev(EV_BUSCOIN) := cov_ev(EV_BUSCOIN) + 1; end if;
         tick;
         bus_write <= '0'; bus_read <= '0';
         garbage;
      end procedure;

   begin
      ram.init;
      file_open(status, f, G_VECFILE, read_mode);
      assert status = open_ok report "ERROR cannot open vector file " & G_VECFILE severity failure;
      rst_seq <= '1';
      ticks(70);
      rst_seq <= '0';
      ticks(4);
      armed <= '1';
      while not endfile(f) loop
         readline(f, l);
         next_tok(l, cmd, n0);
         if (n0 > 0 and cmd(1) = '#' and G_ECHO /= 0) then
            report "SCEN at cycle " & integer'image(cycle_n) & ": " & cmd(1 to n0) & l.all severity note;
         end if;
         if (n0 > 0 and cmd(1) /= '#') then
            if (cmd(1 to 3) = "CFG") then
               next_tok(l, a1, n1); next_tok(l, a2, n2); next_tok(l, a3, n3); next_tok(l, a4, n4);
               TURBO <= '0'; TURBO_CACHE <= '0'; ram8mb <= '0'; ignoreCDTiming <= '0';
               if (dec(a1) /= 0) then TURBO <= '1'; end if;
               if (dec(a2) /= 0) then TURBO_CACHE <= '1'; end if;
               if (dec(a3) /= 0) then ram8mb <= '1'; end if;
               if (dec(a4) /= 0) then ignoreCDTiming <= '1'; end if;
            elsif (cmd(1 to 3) = "DEV") then
               -- DEV gpu_flip mdw_flip mdr_flip spu_flip fifo_p lat1_min lat1_max lat2_min lat2_max busy_p
               next_tok(l, a1, n1); dev_gpu_flip <= dec(a1);
               next_tok(l, a1, n1); dev_mdw_flip <= dec(a1);
               next_tok(l, a1, n1); dev_mdr_flip <= dec(a1);
               next_tok(l, a1, n1); dev_spu_flip <= dec(a1);
               next_tok(l, a1, n1); dev_fifo_p   <= dec(a1);
               next_tok(l, a1, n1); dev_lat1_min <= dec(a1);
               next_tok(l, a1, n1); dev_lat1_max <= dec(a1);
               next_tok(l, a1, n1); dev_lat2_min <= dec(a1);
               next_tok(l, a1, n1); dev_lat2_max <= dec(a1);
               next_tok(l, a1, n1); dev_busy_p   <= dec(a1);
            elsif (cmd(1 to 3) = "CDT") then
               -- CDT memctrl8 com0_delay spu_timing_on spu_timing_value
               next_tok(l, a1, n1); next_tok(l, a2, n2); next_tok(l, a3, n3); next_tok(l, a4, n4);
               cd_memctrl <= (others => '0');
               if (dec(a1) /= 0) then cd_memctrl(8) <= '1'; end if;
               com0_delay <= to_unsigned(dec(a2), 4);
               if (dec(a3) /= 0) then spu_timing_on <= '1'; else spu_timing_on <= '0'; end if;
               spu_timing_value <= to_unsigned(dec(a4), 4);
            elsif (cmd(1 to 3) = "REQ") then
               -- REQ gpu mdec_w mdec_r spu: force the request levels (they then flip at the DEV rates)
               next_tok(l, a1, n1); next_tok(l, a2, n2); next_tok(l, a3, n3); next_tok(l, a4, n4);
               req_set <= std_logic_vector(to_unsigned(dec(a4), 1)) & std_logic_vector(to_unsigned(dec(a3), 1)) &
                          std_logic_vector(to_unsigned(dec(a2), 1)) & std_logic_vector(to_unsigned(dec(a1), 1));
               tick;
               req_n <= req_n + 1;
            elsif (cmd(1 to 3) = "MEM") then
               next_tok(l, a1, n1); next_tok(l, a2, n2);
               ram.wr(to_integer(hex(a1(1 to n1)) srl 2), std_logic_vector(hex(a2(1 to n2))));
            elsif (cmd(1 to 2) = "BW") then
               next_tok(l, a1, n1); next_tok(l, a2, n2);
               bus_op(true, hex(a1(1 to n1))(6 downto 0), std_logic_vector(hex(a2(1 to n2))));
            elsif (cmd(1 to 2) = "BR") then
               next_tok(l, a1, n1);
               bus_op(false, hex(a1(1 to n1))(6 downto 0), bus_data);
            elsif (cmd(1 to 3) = "GAP") then
               next_tok(l, a1, n1);
               for i in 1 to dec(a1) loop garbage; tick; end loop;
            elsif (cmd(1 to 4) = "IDLE") then
               idle_n := 0; to_n := 0;
               while idle_n < 12 loop
                  tick;
                  if (go.dmaOn = '0' and go.dmaRequest = '0' and ref_isOn = '0' and cpuPaused = '0' and reset = '0') then
                     idle_n := idle_n + 1;
                  else
                     idle_n := 0;
                  end if;
                  to_n := to_n + 1;
                  if (to_n > 3000000) then
                     report "ERROR IDLE timeout" severity error;
                     cov_ev(EV_TO) := cov_ev(EV_TO) + 1;
                     exit;
                  end if;
               end loop;
            elsif (cmd(1 to 3) = "RST") then
               next_tok(l, a1, n1);
               -- a start requested for the MDEC channels would run on the cleared arrays with the wrong direction,
               -- which the golden reports as a failure; other channels may start across a reset
               while (go.dmaRequest = '1' and ref_trig < 2) loop tick; end loop;
               rst_seq <= '1';
               ticks(dec(a1));
               rst_seq <= '0';
               ticks(2);
               cov_ev(EV_RST) := cov_ev(EV_RST) + 1;
            elsif (cmd(1 to 5) = "PAUSE") then
               next_tok(l, a1, n1);
               to_n := 0;
               while not (cpuPaused = '0' and go.dmaRequest = '0' and canDMA = '1' and go.SS_idle = '1') and to_n < 200000 loop
                  tick; to_n := to_n + 1;
               end loop;
               ce_seq <= '0';
               ticks(dec(a1));
               ce_seq <= '1';
               cov_ev(EV_PAUSE) := cov_ev(EV_PAUSE) + 1;
            elsif (cmd(1 to 3) = "END") then
               exit;
            else
               report "ERROR unknown command " & cmd(1 to n0) severity failure;
            end if;
         end if;
      end loop;
      ticks(40);
      finished <= true;
      wait for 20 ns;
      cmp.report_result(cycle_n);
      wait;
   end process;

   -- coverage report: one COV line per counter, before the RESULT line
   process (finished)
      type names_t is array (0 to 27) of string(1 to 9);
      constant evn : names_t := ("ram_rd   ", "ram_wr   ", "gpu_w    ", "mdec_w   ", "spu_w    ", "gpu_r    ", "mdec_r   ",
                                 "cd_r     ", "spu_r    ", "irq      ", "err_chop ", "err_cpu  ", "err_fifo ", "bus_w    ",
                                 "bus_r    ", "reset    ", "pause    ", "stall    ", "cnt0     ", "cnt1     ", "cnt2     ",
                                 "cnt3     ", "ena_busy ", "buscoin  ", "gpuwait  ", "fiford   ", "timeout  ", "wdog     ");
      variable l : line;
   begin
      if (finished) then
         for c in 0 to 6 loop
            write(l, string'("COV xfer_c") & integer'image(c) & "_from " & integer'image(cov_xfer(c * 2)));
            writeline(output, l);
            write(l, string'("COV xfer_c") & integer'image(c) & "_to " & integer'image(cov_xfer(c * 2 + 1)));
            writeline(output, l);
         end loop;
         for e in 0 to 27 loop
            if (e /= 22) then
               write(l, string'("COV ") & evn(e) & " " & integer'image(cov_ev(e)));
               writeline(output, l);
            end if;
         end loop;
      end if;
   end process;

end architecture;
