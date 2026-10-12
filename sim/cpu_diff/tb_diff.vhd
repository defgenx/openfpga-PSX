library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use IEEE.std_logic_textio.all;
library STD;
use STD.textio.all;

use work.pexport.all;
use work.trace_cmp_pkg.all;

-- Differential testbench: golden cpu vs cpu_dut in lock step on one bus model.
--
-- The bus model follows the golden's outputs and drives both CPUs with the same inputs. It implements what the
-- CPU sees of memorymux: read latency, mem_done only for reads, the mem_tagvalids protocol of an instruction
-- fetch (memorymux.vhd:588-616), the icache fill stream (cache_wr/cache_data/cache_addr, written before mem_done),
-- rotated data reads, a write FIFO with mem_fifofull, and the GTE (busy after a command, register file behind
-- gte_readAddr). Pauses of ce and dmaStallCPU start only when the bus is quiescent, like the top's pause FSM.
--
-- Every clk1x edge (values before the edge) compares all outputs (see "compare list" in cmp_cycle); at every
-- retire (cpu_done) the whole cpu_export record. Image file: lines "AAAAAAAA DDDDDDDD" (physical byte address,
-- word), see gen_prog.py.
entity tb_diff is
   generic
   (
      G_IMAGE         : string  := "image.txt";
      G_CYCLES        : natural := 100000;
      G_SEED          : natural := 1;
      G_LAT_MAX       : natural := 8;      -- read latency 1..G_LAT_MAX clk1x
      G_SLOW_PCT      : natural := 3;      -- % of reads that take 20..40
      G_CE_PCT        : natural := 2;      -- % per quiescent cycle that a ce pause starts
      G_DMA_PCT       : natural := 2;      -- % per quiescent cycle that a DMA stall starts
      G_IRQ_PERMILLE  : natural := 3;      -- per mille per cycle that irqRequest is raised
      G_IRQ_LEN       : natural := 40;     -- it stays high for 1..G_IRQ_LEN cycles
      G_FIFO_THR      : natural := 6;      -- mem_fifofull when the write FIFO holds this many entries
      G_FIFO_DRAIN    : natural := 3;      -- one entry drains per 1..G_FIFO_DRAIN cycles
      G_GTE_MAX       : natural := 40;     -- GTE busy 3..G_GTE_MAX cycles after a command
      G_RESET_EVERY   : natural := 0;      -- mean cycles between warm resets, 0: only at the start
      G_LONGWAIT      : natural := 0;      -- 1 in n reads waits 520..560 cycles (error2)
      G_VARY_TIMING   : boolean := true;   -- seed mod 4: 1 as given, 2 latency 1-2, 3 latency 1 without slow reads, 0 latency 1-14
      G_NO_COP0_DEBUG : boolean := false;
      G_MAX_LOG       : natural := 12;
      G_TRACE         : natural := 0;      -- print the first N retired pc/opcode pairs
      G_STOP_FAILS    : natural := 40;     -- end the run after this many mismatches
      -- fault injection into the compared DUT outputs (selftest); 0 = off
      G_FAULT         : natural := 0;
      G_FAULT_CYCLE   : natural := 5000
   );
end entity;

architecture arch of tb_diff is

   shared variable cmp : trace_cmp_t;

   signal clk1x : std_logic := '1';
   signal clk2x : std_logic := '1';
   signal clk3x : std_logic := '1';

   -- shared stimulus
   signal ce, reset, ss_reset, irq, dmastall, cpupaused : std_logic := '0';
   signal mem_dataRead   : std_logic_vector(31 downto 0) := (others => '0');
   signal mem_done       : std_logic := '0';
   signal mem_fifofull   : std_logic := '0';
   signal mem_tagvalids  : std_logic_vector(3 downto 0) := (others => '0');
   signal cache_wr       : std_logic_vector(3 downto 0) := (others => '0');
   signal cache_data     : std_logic_vector(31 downto 0) := (others => '0');
   signal cache_addr     : std_logic_vector(7 downto 0) := (others => '0');
   signal ram_done, ram_rnw, dma_cache_write : std_logic := '0';
   signal ram_dataRead, dma_cache_data : std_logic_vector(31 downto 0) := (others => '0');
   signal dma_cache_Adr  : std_logic_vector(20 downto 0) := (others => '0');
   signal gte_busy       : std_logic := '0';

   type gte_regs_t is array (0 to 63) of unsigned(31 downto 0);
   signal gte_regs : gte_regs_t := (others => (others => '0'));

   -- golden outputs
   signal g_error, g_error2, g_req, g_rnw, g_isData, g_isCache, g_stallNext : std_logic;
   signal g_oldtag, g_wmask : std_logic_vector(3 downto 0);
   signal g_addrI, g_addrD : unsigned(31 downto 0);
   signal g_reqsize : unsigned(1 downto 0);
   signal g_dataW : std_logic_vector(31 downto 0);
   signal g_gRdEna, g_gWrEna, g_gCmdEna : std_logic;
   signal g_gRdAddr, g_gWrAddr : unsigned(5 downto 0);
   signal g_gWrData, g_gCmdData : unsigned(31 downto 0);
   signal g_gRdData : unsigned(31 downto 0);
   signal g_ssidle, g_done : std_logic;
   signal g_export : cpu_export_type;

   -- dut outputs
   signal d_error, d_error2, d_req, d_rnw, d_isData, d_isCache, d_stallNext : std_logic;
   signal d_oldtag, d_wmask : std_logic_vector(3 downto 0);
   signal d_addrI, d_addrD : unsigned(31 downto 0);
   signal d_reqsize : unsigned(1 downto 0);
   signal d_dataW : std_logic_vector(31 downto 0);
   signal d_gRdEna, d_gWrEna, d_gCmdEna : std_logic;
   signal d_gRdAddr, d_gWrAddr : unsigned(5 downto 0);
   signal d_gWrData, d_gCmdData : unsigned(31 downto 0);
   signal d_gRdData : unsigned(31 downto 0);
   signal d_ssidle, d_done : std_logic;
   signal d_export : cpu_export_type;

   function flat(e : cpu_export_type) return std_logic_vector is
      variable r : std_logic_vector(35 * 32 - 1 downto 0);
   begin
      for i in 0 to 31 loop
         r(32 * i + 31 downto 32 * i) := std_logic_vector(e.regs(i));
      end loop;
      r(32 * 32 + 31 downto 32 * 32) := std_logic_vector(e.pc);
      r(32 * 33 + 31 downto 32 * 33) := std_logic_vector(e.opcode);
      r(32 * 34 + 31 downto 32 * 34) := std_logic_vector(e.cause);
      return r;
   end function;

   -- xorshift32
   procedure rnd(variable s : inout unsigned(31 downto 0); variable r : out natural) is
      variable x : unsigned(31 downto 0) := s;
   begin
      x := x xor shift_left(x, 13);
      x := x xor shift_right(x, 17);
      x := x xor shift_left(x, 5);
      s := x;
      r := to_integer(x(30 downto 0));
   end procedure;

   type mem_t is array (natural range <>) of std_logic_vector(31 downto 0);

begin

   clk1x <= not clk1x after 15 ns;
   clk2x <= not clk2x after 7500 ps;
   clk3x <= not clk3x after 5 ns;

   igold : entity work.cpu
   port map
   (
      clk1x => clk1x, clk2x => clk2x, clk3x => clk3x, ce => ce, reset => reset,
      TURBO => '0', TURBO_CACHE => '0', TURBO_CACHE50 => '0',
      irqRequest => irq, dmaStallCPU => dmastall, cpuPaused => cpupaused,
      error => g_error, error2 => g_error2,
      mem_request => g_req, mem_rnw => g_rnw, mem_isData => g_isData, mem_isCache => g_isCache,
      mem_oldtagvalids => g_oldtag, mem_addressInstr => g_addrI, mem_addressData => g_addrD,
      mem_reqsize => g_reqsize, mem_writeMask => g_wmask, mem_dataWrite => g_dataW,
      mem_dataRead => mem_dataRead, mem_done => mem_done, mem_fifofull => mem_fifofull, mem_tagvalids => mem_tagvalids,
      cache_wr => cache_wr, cache_data => cache_data, cache_addr => cache_addr,
      stallNext => g_stallNext,
      dma_cache_Adr => dma_cache_Adr, dma_cache_data => dma_cache_data, dma_cache_write => dma_cache_write,
      ram_done => ram_done, ram_rnw => ram_rnw, ram_dataRead => ram_dataRead,
      gte_busy => gte_busy, gte_readEna => g_gRdEna, gte_readAddr => g_gRdAddr, gte_readData => g_gRdData,
      gte_writeAddr => g_gWrAddr, gte_writeData => g_gWrData, gte_writeEna => g_gWrEna,
      gte_cmdData => g_gCmdData, gte_cmdEna => g_gCmdEna,
      SS_reset => ss_reset, SS_DataWrite => (others => '0'), SS_Adr => (others => '0'),
      SS_wren_CPU => '0', SS_wren_SCP => '0', SS_rden_CPU => '0', SS_rden_SCP => '0',
      SS_DataRead_CPU => open, SS_DataRead_SCP => open, SS_idle => g_ssidle,
      cpu_done => g_done, cpu_export => g_export,
      debug_firstGTE => '0'
   );

   idut : entity work.cpu_dut
   generic map (G_NO_COP0_DEBUG => G_NO_COP0_DEBUG)
   port map
   (
      clk1x => clk1x, clk2x => clk2x, clk3x => clk3x, ce => ce, reset => reset,
      TURBO => '0', TURBO_CACHE => '0', TURBO_CACHE50 => '0',
      irqRequest => irq, dmaStallCPU => dmastall, cpuPaused => cpupaused,
      error => d_error, error2 => d_error2,
      mem_request => d_req, mem_rnw => d_rnw, mem_isData => d_isData, mem_isCache => d_isCache,
      mem_oldtagvalids => d_oldtag, mem_addressInstr => d_addrI, mem_addressData => d_addrD,
      mem_reqsize => d_reqsize, mem_writeMask => d_wmask, mem_dataWrite => d_dataW,
      mem_dataRead => mem_dataRead, mem_done => mem_done, mem_fifofull => mem_fifofull, mem_tagvalids => mem_tagvalids,
      cache_wr => cache_wr, cache_data => cache_data, cache_addr => cache_addr,
      stallNext => d_stallNext,
      dma_cache_Adr => dma_cache_Adr, dma_cache_data => dma_cache_data, dma_cache_write => dma_cache_write,
      ram_done => ram_done, ram_rnw => ram_rnw, ram_dataRead => ram_dataRead,
      gte_busy => gte_busy, gte_readEna => d_gRdEna, gte_readAddr => d_gRdAddr, gte_readData => d_gRdData,
      gte_writeAddr => d_gWrAddr, gte_writeData => d_gWrData, gte_writeEna => d_gWrEna,
      gte_cmdData => d_gCmdData, gte_cmdEna => d_gCmdEna,
      SS_reset => ss_reset, SS_idle => d_ssidle,
      cpu_done => d_done, cpu_export => d_export
   );

   -- the GTE register file answers each CPU on its own address
   g_gRdData <= gte_regs(to_integer(g_gRdAddr));
   d_gRdData <= gte_regs(to_integer(d_gRdAddr));

   main : block is
   -- coverage probes into the golden
   alias p_stall1       is <<signal .tb_diff.igold.stall1 : std_logic>>;
   alias p_stall2       is <<signal .tb_diff.igold.stall2 : std_logic>>;
   alias p_stall3       is <<signal .tb_diff.igold.stall3 : std_logic>>;
   alias p_stall4       is <<signal .tb_diff.igold.stall4 : std_logic>>;
   alias p_stall        is <<signal .tb_diff.igold.stall : unsigned(4 downto 0)>>;
   alias p_exception    is <<signal .tb_diff.igold.exception : unsigned(4 downto 0)>>;
   alias p_exceptionBp  is <<signal .tb_diff.igold.exceptionBreakpoint : std_logic>>;
   alias p_exNew5       is <<signal .tb_diff.igold.exceptionNew5 : std_logic>>;
   alias p_exNew3       is <<signal .tb_diff.igold.exceptionNew3 : std_logic>>;
   alias p_exCode3      is <<signal .tb_diff.igold.exceptionCode_3 : unsigned(3 downto 0)>>;
   alias p_exBrslot     is <<signal .tb_diff.igold.exception_brslot : std_logic>>;
   alias p_exCause      is <<signal .tb_diff.igold.exception_CAUSE : unsigned(31 downto 0)>>;
   alias p_exeBrTaken   is <<signal .tb_diff.igold.EXEBranchTaken : std_logic>>;
   alias p_exeBrSlot    is <<signal .tb_diff.igold.EXEBranchdelaySlot : std_logic>>;
   alias p_exeMult      is <<signal .tb_diff.igold.EXEcalcMULT : std_logic>>;
   alias p_exeMultu     is <<signal .tb_diff.igold.EXEcalcMULTU : std_logic>>;
   alias p_exeDiv       is <<signal .tb_diff.igold.EXEcalcDIV : std_logic>>;
   alias p_exeDivu      is <<signal .tb_diff.igold.EXEcalcDIVU : std_logic>>;
   alias p_hilocalc     is <<signal .tb_diff.igold.dbg_hc : integer>>;
   alias p_hiloWait     is <<signal .tb_diff.igold.dbg_hw : integer>>;
   alias p_exeStall     is <<signal .tb_diff.igold.dbg_est : integer>>;
   alias p_exeReadEna   is <<signal .tb_diff.igold.executeReadEnable : std_logic>>;
   alias p_exeReadAddr  is <<signal .tb_diff.igold.executeReadAddress : unsigned(31 downto 0)>>;
   alias p_exeLoadType  is <<signal .tb_diff.igold.dbg_lt : integer>>;
   alias p_exeWrEna     is <<signal .tb_diff.igold.executeMemWriteEnable : std_logic>>;
   alias p_exeWrMask    is <<signal .tb_diff.igold.executeMemWriteMask : std_logic_vector(3 downto 0)>>;
   alias p_exeGteRd     is <<signal .tb_diff.igold.executeGTEReadEnable : std_logic>>;
   alias p_lrBypass     is <<signal .tb_diff.igold.lateReadBypass : std_logic>>;
   alias p_lrWrite      is <<signal .tb_diff.igold.lateReadWrite : std_logic>>;
   alias p_lrStall      is <<signal .tb_diff.igold.lateReadStall : std_logic>>;
   alias p_lrWAW        is <<signal .tb_diff.igold.lateReadWriteAfterWrite : std_logic>>;
   alias p_decLateStall is <<signal .tb_diff.igold.decodeLateStall : std_logic>>;
   alias p_blockLoadFwd is <<signal .tb_diff.igold.blockLoadforward : std_logic>>;
   alias p_cacheHit     is <<signal .tb_diff.igold.cacheHit : std_logic>>;
   alias p_cacheHitLast is <<signal .tb_diff.igold.cacheHitLast : std_logic>>;
   alias p_tagWr        is <<signal .tb_diff.igold.tag_wren_a : std_logic>>;
   alias p_wbInvEna     is <<signal .tb_diff.igold.writebackInvalidateCacheEna : std_logic>>;
   alias p_blockIRQ     is <<signal .tb_diff.igold.blockIRQ : std_logic>>;
   alias p_mem4Pending  is <<signal .tb_diff.igold.mem4_pending : std_logic>>;
   alias p_exeResWr     is <<signal .tb_diff.igold.EXEresultWriteEnable : std_logic>>;
   alias p_decodeOP     is <<signal .tb_diff.igold.decodeOP : unsigned(5 downto 0)>>;
   alias p_decodeFunct  is <<signal .tb_diff.igold.decodeFunct : unsigned(5 downto 0)>>;
   alias p_decodeSrc1   is <<signal .tb_diff.igold.decodeSource1 : unsigned(4 downto 0)>>;
   alias p_decodeRD     is <<signal .tb_diff.igold.decodeRD : unsigned(4 downto 0)>>;
   alias p_cop0SR       is <<signal .tb_diff.igold.cop0_SR : unsigned(31 downto 0)>>;
   alias p_cop0Cause    is <<signal .tb_diff.igold.cop0_CAUSE : unsigned(31 downto 0)>>;
   alias p_exeCop0Wr    is <<signal .tb_diff.igold.EXECOP0WriteEnable : std_logic>>;
   alias p_exeCop0Dst   is <<signal .tb_diff.igold.EXECOP0WriteDestination : unsigned(4 downto 0)>>;
   alias p_exeBreakpt   is <<signal .tb_diff.igold.EXEBreakpoint : std_logic>>;
   alias p_fetchAddr    is <<signal .tb_diff.igold.FetchAddr : unsigned(31 downto 0)>>;
   alias p_tagq         is <<signal .tb_diff.igold.tag_q_b : std_logic_vector(23 downto 0)>>;
   alias p_fetchLast    is <<signal .tb_diff.igold.FetchLastAddr : unsigned(31 downto 0)>>;
   alias p_fetchReadyNow is <<signal .tb_diff.igold.fetchReadyNow : std_logic>>;

   begin
   process
      -- memory
      variable ram    : mem_t(0 to 524287) := (others => (others => '0'));
      variable bios   : mem_t(0 to 131071) := (others => (others => '0'));
      variable lat_max  : natural := G_LAT_MAX;
      variable slow_pct : natural := G_SLOW_PCT;
      variable seed   : unsigned(31 downto 0) := resize(to_unsigned(G_SEED + 1, 32) * unsigned'(x"9E3779B1"), 32) xor x"2545F491";
      variable r      : natural;
      variable cyc    : natural := 0;
      variable rstate : natural := 0;       -- reset sequence step
      variable rcnt   : natural := 0;
      variable next_reset : natural := 0;
      variable started : boolean := false;
      variable cmp_en : boolean := false;

      -- bus state
      variable rd_active : boolean := false;
      variable rd_cnt    : natural := 0;
      variable fifo_cnt  : natural := 0;
      variable fifo_t    : natural := 0;
      variable done_n    : std_logic;
      variable data_n    : std_logic_vector(31 downto 0) := (others => '0');
      variable tag_n     : std_logic_vector(3 downto 0) := (others => '0');
      variable accept    : boolean;
      variable phys      : unsigned(31 downto 0);
      variable widx      : natural;
      variable lat       : natural;
      variable w         : std_logic_vector(31 downto 0);
      variable fill_w    : natural;
      variable fill_cnt  : natural;
      variable fill_line : std_logic_vector(7 downto 0);
      variable fill_base : natural;
      variable fill_k    : natural := 0;       -- next word of a running fill, 4 = none
      variable fill_first : natural := 0;
      variable pause_n   : natural := 0;
      variable dma_n     : natural := 0;
      variable quiet     : boolean;
      variable ce_n      : std_logic;
      variable dma_next  : std_logic;
      variable irq_n     : std_logic;
      variable irq_cnt   : natural := 0;
      variable busy_cnt  : natural := 0;
      variable busy_n    : std_logic := '0';
      variable ssz       : natural;
      variable cf        : std_logic_vector(35 * 32 - 1 downto 0);
      variable df        : std_logic_vector(35 * 32 - 1 downto 0);
      variable l         : line;
      file f             : text;
      variable fstat     : file_open_status;
      variable a32       : std_logic_vector(31 downto 0);
      variable d32       : std_logic_vector(31 downto 0);
      variable fdone     : boolean;
      variable lin_ok    : boolean;
      variable rot       : natural;
      variable f_req, f_stall, f_ssidle, f_error2, f_cmdEna, f_done, f_isData, f_rnw, f_isCache, f_error, f_rdEna : std_logic;
      variable f_addrI, f_wdata, f_gwdata : std_logic_vector(31 downto 0);
      variable f_oldtag, f_wmask : std_logic_vector(3 downto 0);
      variable m         : std_logic;

      -- compare tallies
      variable n_retire : natural := 0;
      variable n_cmpcyc : natural := 0;

      -- coverage counters (golden internals), index names in cov_name
      type cov_t is array (0 to 79) of natural;
      variable cov : cov_t := (others => 0);

      procedure bump(i : natural) is begin cov(i) := cov(i) + 1; end procedure;

      function rotr(x : std_logic_vector(31 downto 0); n : natural) return std_logic_vector is
      begin
         case n is
            when 1 => return x"00" & x(31 downto 8);
            when 2 => return x"0000" & x(31 downto 16);
            when 3 => return x"000000" & x(31 downto 24);
            when others => return x;
         end case;
      end function;

      impure function rd_word(a : unsigned(31 downto 0)) return std_logic_vector is
         variable p : unsigned(31 downto 0) := a and x"1FFFFFFF";
      begin
         if p < x"00800000" then
            return ram(to_integer(p(20 downto 2)));
         elsif p >= x"1FC00000" and p < x"1FC80000" then
            return bios(to_integer(p(18 downto 2)));
         else
            return std_logic_vector((p xor x"A5A5C3C3") + x"01000193");
         end if;
      end function;

      procedure wr_word(a : unsigned(31 downto 0); d : std_logic_vector(31 downto 0); mask : std_logic_vector(3 downto 0)) is
         variable p : unsigned(31 downto 0) := a and x"1FFFFFFF";
         variable o : std_logic_vector(31 downto 0);
      begin
         if p < x"00800000" then
            o := ram(to_integer(p(20 downto 2)));
            for i in 0 to 3 loop
               if mask(i) = '1' then o(8 * i + 7 downto 8 * i) := d(8 * i + 7 downto 8 * i); end if;
            end loop;
            ram(to_integer(p(20 downto 2))) := o;
         end if;
      end procedure;

      procedure cmpv(name : string; g, d : std_logic_vector) is
      begin
         cmp.compare(name, cyc, g, d);
      end procedure;
      procedure cmpu(name : string; g, d : unsigned) is
      begin
         cmp.compare(name, cyc, g, d);
      end procedure;
      procedure cmpb(name : string; g, d : std_logic) is
      begin
         cmp.compare(name, cyc, g, d);
      end procedure;

   begin
      cmp.configure(G_MAX_LOG);
      if G_VARY_TIMING then
         case G_SEED mod 4 is
            when 2 => lat_max := 2;
            when 3 => lat_max := 1; slow_pct := 0;
            when 0 => lat_max := 14;
            when others => null;
         end case;
      end if;

      -- load the image
      file_open(fstat, f, G_IMAGE, read_mode);
      assert fstat = open_ok report "cannot open image " & G_IMAGE severity failure;
      while not endfile(f) loop
         readline(f, l);
         if l'length > 0 then
            hread(l, a32);
            hread(l, d32);
            if unsigned(a32) < x"00800000" then
               ram(to_integer(unsigned(a32(20 downto 2)))) := d32;
            elsif unsigned(a32) >= x"1FC00000" and unsigned(a32) < x"1FC80000" then
               bios(to_integer(unsigned(a32(18 downto 2)))) := d32;
            end if;
         end if;
      end loop;
      file_close(f);

      -- GTE register file contents
      for i in 0 to 63 loop
         rnd(seed, r);
         gte_regs(i) <= to_unsigned(r, 32) xor to_unsigned(i * 16#01010101#, 32);
      end loop;

      if G_RESET_EVERY > 0 then
         rnd(seed, r);
         next_reset := 2000 + (r mod (2 * G_RESET_EVERY));
      end if;

      loop
         wait until rising_edge(clk1x);
         cyc := cyc + 1;

         ------------------------------------------------------------ compare (values before this edge)
         if cmp_en then
            n_cmpcyc := n_cmpcyc + 1;
            -- DUT outputs, with the selftest fault of G_FAULT applied from cycle G_FAULT_CYCLE (sticky flip of bit 0)
            f_req := d_req; f_stall := d_stallNext; f_addrI := std_logic_vector(d_addrI); f_oldtag := d_oldtag; f_ssidle := d_ssidle;
            f_error2 := d_error2; f_cmdEna := d_gCmdEna; f_done := d_done; f_wdata := d_dataW; f_gwdata := std_logic_vector(d_gWrData);
            f_wmask := d_wmask; f_isData := d_isData; f_rnw := d_rnw; f_isCache := d_isCache; f_error := d_error; f_rdEna := d_gRdEna;
            if cyc >= G_FAULT_CYCLE then
               case G_FAULT is
                  when 1 => f_wdata(0) := not f_wdata(0);
                  when 3 => f_stall := not f_stall;
                  when 4 => f_req := not f_req;
                  when 5 => f_addrI(0) := not f_addrI(0);
                  when 6 => f_oldtag(0) := not f_oldtag(0);
                  when 7 => f_ssidle := not f_ssidle;
                  when 8 => f_error2 := not f_error2;
                  when 9 => f_cmdEna := not f_cmdEna;
                  when 10 => f_gwdata(0) := not f_gwdata(0);
                  when 11 => f_done := not f_done;
                  when 12 => f_wmask(0) := not f_wmask(0);
                  when 13 => f_isData := not f_isData;
                  when 14 => f_rnw := not f_rnw;
                  when 15 => f_isCache := not f_isCache;
                  when 16 => f_error := not f_error;
                  when 17 => f_rdEna := not f_rdEna;
                  when others => null;
               end case;
            end if;
            cmpb("error", g_error, f_error);
            cmpb("error2", g_error2, f_error2);
            cmpb("mem_request", g_req, f_req);
            cmpb("mem_rnw", g_rnw, f_rnw);
            cmpb("mem_isData", g_isData, f_isData);
            cmpb("mem_isCache", g_isCache, f_isCache);
            cmpv("mem_oldtagvalids", g_oldtag, f_oldtag);
            cmpv("mem_addressInstr", std_logic_vector(g_addrI), f_addrI);
            if g_req = '1' and g_isData = '1' then cmpu("mem_addressData", g_addrD, d_addrD); end if;
            cmpu("mem_reqsize", g_reqsize, d_reqsize);
            cmpv("mem_writeMask", g_wmask, f_wmask);
            cmpv("mem_dataWrite", g_dataW, f_wdata);
            cmpb("stallNext", g_stallNext, f_stall);
            -- GTE fields are compared where the GTE samples them: with their strobe
            cmpb("gte_readEna", g_gRdEna, f_rdEna);
            if g_gRdEna = '1' then cmpu("gte_readAddr", g_gRdAddr, d_gRdAddr); end if;
            cmpb("gte_writeEna", g_gWrEna, d_gWrEna);
            if g_gWrEna = '1' then
               cmpu("gte_writeAddr", g_gWrAddr, d_gWrAddr);
               cmpv("gte_writeData", std_logic_vector(g_gWrData), f_gwdata);
            end if;
            cmpb("gte_cmdEna", g_gCmdEna, f_cmdEna);
            if g_gCmdEna = '1' then cmpu("gte_cmdData", g_gCmdData, d_gCmdData); end if;
            cmpb("SS_idle", g_ssidle, f_ssidle);
            cmpb("cpu_done", g_done, f_done);
            if g_done = '1' then
               n_retire := n_retire + 1;
               if n_retire <= G_TRACE then
                  write(l, string'("TRACE ") & integer'image(n_retire) & string'(" cyc=") & integer'image(cyc) & string'(" pc=") & to_hstring(g_export.pc) & string'(" op=") & to_hstring(g_export.opcode));
                  writeline(output, l);
               end if;
               cf := flat(g_export);
               df := flat(d_export);
               if G_FAULT = 2 and cyc >= G_FAULT_CYCLE then df(0) := not df(0); end if;
               cmpv("cpu_export", cf, df);
               if cf /= df then
                  for i in 0 to 34 loop
                     if cf(32 * i + 31 downto 32 * i) /= df(32 * i + 31 downto 32 * i) then
                        write(l, string'("  export field ") & integer'image(i) & string'(" (0-31 regs, 32 pc, 33 opcode, 34 cause) gold=") &
                              to_hstring(cf(32 * i + 31 downto 32 * i)) & string'(" dut=") & to_hstring(df(32 * i + 31 downto 32 * i)));
                        writeline(output, l);
                     end if;
                  end loop;
               end if;
            end if;
            if cmp.mismatches >= G_STOP_FAILS then
               report "too many mismatches" severity note;
               write(l, string'("ABORT after ") & integer'image(cyc) & string'(" cycles, ") & integer'image(n_retire) & string'(" retires"));
               writeline(output, l);
               cmp.report_result(cyc);
            end if;
         end if;

         ------------------------------------------------------------ coverage (golden internals, before the edge)
         if cmp_en and ce = '1' then
            if p_stall1 = '1' then bump(0); end if;
            if p_stall3 = '1' then bump(1); end if;
            if p_stall4 = '1' then bump(2); end if;
            if p_stall2 = '1' then bump(3); end if;
            if dmastall = '1' then bump(4); end if;
            if p_stall = 0 then
               if p_exeBrSlot = '1' and p_exeBrTaken = '1' then bump(5); end if;
               if p_exeBrSlot = '1' and p_exeBrTaken = '0' then bump(6); end if;
               if p_exeMult = '1' then bump(7); end if;
               if p_exeMultu = '1' then bump(8); end if;
               if p_exeDiv = '1' then bump(9); end if;
               if p_exeDivu = '1' then bump(10); end if;
               if (p_exeDiv = '1' or p_exeDivu = '1') and p_hilocalc = 4 then bump(11); end if;
               if p_exNew3 = '1' then bump(12); end if;
               if p_exNew5 = '1' then bump(13); end if;
               if p_exCode3 = x"C" and p_exNew3 = '1' then bump(14); end if;
               if (p_exCode3 = x"4" or p_exCode3 = x"5") and p_exNew3 = '1' then bump(15); end if;
               if p_exCode3 = x"8" and p_exNew3 = '1' then bump(16); end if;
               if p_exCode3 = x"9" and p_exNew3 = '1' then bump(17); end if;
               if p_exCode3 = x"A" and p_exNew3 = '1' then bump(18); end if;
               if p_exCode3 = x"B" and p_exNew3 = '1' then bump(19); end if;
               if p_exNew3 = '1' and p_exeBrSlot = '1' then bump(20); end if;
               if p_exeBreakpt = '1' then bump(21); end if;
               if p_exeCop0Wr = '1' then bump(22); end if;
               if p_exeCop0Wr = '1' and p_exeCop0Dst = 12 then bump(23); end if;
               if p_exeReadEna = '1' then
                  if p_exeReadAddr(31 downto 29) = "000" or p_exeReadAddr(31 downto 29) = "100" then
                     if p_exeReadAddr(28 downto 10) = "1111110000000000000" then bump(24); end if;
                  end if;
                  if p_exeReadAddr = x"FFFE0130" then bump(25); end if;
                  if p_exeLoadType = 2 then bump(26); end if;
                  if p_exeLoadType = 6 then bump(27); end if;
                  if p_exeLoadType = 0 or p_exeLoadType = 4 then bump(28); end if;
                  if p_exeLoadType = 1 or p_exeLoadType = 5 then bump(29); end if;
                  if p_exeGteRd = '1' then bump(30); end if;
               end if;
               if p_exeWrEna = '1' then
                  if p_exeWrMask /= "1111" then bump(31); end if;
                  if p_exeReadAddr(28 downto 10) = "1111110000000000000" then bump(32); end if;
                  if p_cop0SR(16) = '1' then bump(33); end if;
               end if;
            end if;
            if p_lrBypass = '1' then bump(34); end if;
            if p_lrWrite = '1' then bump(35); end if;
            if p_lrStall = '1' then bump(36); end if;
            if p_lrWAW = '1' then bump(37); end if;
            if p_decLateStall = '1' then bump(38); end if;
            if p_blockLoadFwd = '1' then bump(39); end if;
            if p_cacheHit = '1' then bump(40); end if;
            if p_cacheHitLast = '1' then bump(41); end if;
            if p_wbInvEna = '1' then bump(42); if p_fetchLast(31 downto 29) = "101" then bump(41 - 41 + 59); end if; end if;
            if p_blockIRQ = '1' then bump(43); end if;
            if p_exeStall = 1 or p_exeStall = 2 then bump(44); end if;
            if p_exeStall = 3 then bump(45); end if;
            if p_exeStall = 4 then bump(46); end if;
            if g_gCmdEna = '1' then bump(47); end if;
            if g_gWrEna = '1' then bump(48); end if;
            if g_gRdEna = '1' then bump(49); end if;
            if p_exceptionBp = '1' then bump(50); end if;
            if g_req = '1' and g_isData = '0' and g_isCache = '1' then bump(51); end if;
            if g_req = '1' and g_isData = '0' and g_isCache = '0' then bump(52); end if;
            if g_req = '1' and g_isData = '1' and g_rnw = '0' then bump(53); end if;
            if g_req = '1' and g_isData = '1' and g_rnw = '1' then bump(54); end if;
            if g_req = '1' and g_isData = '0' and g_oldtag /= "0000" then bump(55); end if;
            if mem_fifofull = '1' then bump(56); end if;
            if g_req = '1' and g_isData = '1' and g_rnw = '0' and mem_fifofull = '1' then bump(64); end if;
            if g_error = '1' then bump(57); end if;
            if g_error2 = '1' then bump(58); end if;
            if p_exeStall = 1 or p_exeStall = 2 then bump(59); end if;
            if irq = '1' then bump(60); end if;
            -- compact-tag evidence: a cached fetch whose 13-bit key and valid bit match but whose 20-bit tag does not
            if (p_fetchAddr(31 downto 29) = "000" or p_fetchAddr(31 downto 29) = "100") and
               p_tagq(19) = p_fetchAddr(31) and p_tagq(16) = p_fetchAddr(28) and unsigned(p_tagq(10 downto 0)) = p_fetchAddr(22 downto 12) and
               p_tagq(20 + to_integer(p_fetchAddr(3 downto 2))) = '1' and unsigned(p_tagq(19 downto 0)) /= p_fetchAddr(31 downto 12) then
               bump(63);
            end if;
            -- 18-bit tag evidence: a stored tag equal to the fetch address except in bits 30:29, on a cached fetch
            if (p_fetchAddr(31 downto 29) = "000" or p_fetchAddr(31 downto 29) = "100") and
               p_tagq(19) = p_fetchAddr(31) and unsigned(p_tagq(16 downto 0)) = p_fetchAddr(28 downto 12) and
               unsigned(p_tagq(18 downto 17)) /= p_fetchAddr(30 downto 29) then
               bump(61);
               if p_tagq(20 + to_integer(p_fetchAddr(3 downto 2))) = '1' then bump(62); end if;
            end if;
         end if;

         ------------------------------------------------------------ end of run
         if cyc >= G_CYCLES then
            write(l, string'("COVER"));
            for i in 0 to 64 loop
               write(l, string'(" c") & integer'image(i) & string'("=") & integer'image(cov(i)));
            end loop;
            writeline(output, l);
            write(l, string'("STATS cycles=") & integer'image(cyc) & string'(" retires=") & integer'image(n_retire) &
                     string'(" cmpcycles=") & integer'image(n_cmpcyc));
            writeline(output, l);
            cmp.report_result(cyc);
         end if;

         ------------------------------------------------------------ reset sequence (as the top: reset, SS_reset x2, reset x61)
         ce_n := ce;
         if rstate = 0 and (not started) then
            started := true; rstate := 1; rcnt := 3; reset <= '1';
         elsif G_RESET_EVERY > 0 and rstate = 0 and cyc >= next_reset then
            rstate := 1; rcnt := 3; reset <= '1';
            rnd(seed, r);
            next_reset := cyc + 2000 + (r mod (2 * G_RESET_EVERY));
         end if;
         if rstate > 0 then
            -- bus state is cleared while any reset phase runs
            rd_active := false; rd_cnt := 0; fifo_cnt := 0; fill_k := 4;
            mem_done <= '0'; mem_fifofull <= '0'; cache_wr <= (others => '0');
            cmp_en := false;
            busy_n := '0'; busy_cnt := 0; gte_busy <= '0';
            if rcnt > 0 then rcnt := rcnt - 1; end if;
            if rcnt = 0 then
               case rstate is
                  when 1 => rstate := 2; rcnt := 2; reset <= '0'; ss_reset <= '1';
                  when 2 => rstate := 3; rcnt := 61; reset <= '1'; ss_reset <= '0';
                  when others => rstate := 0; reset <= '0'; cmp_en := true; ce_n := '1'; ce <= '1';
               end case;
            end if;
            ce <= '1';
            dmastall <= '0';
            pause_n := 0; dma_n := 0;
         else
            ----------------------------------------------------------- bus model, one edge
            done_n := '0';
            accept := false;

            -- stimulus that does not follow the bus
            rnd(seed, r);
            irq_n := irq;
            if irq = '1' then
               if irq_cnt > 0 then irq_cnt := irq_cnt - 1; end if;
               if irq_cnt = 0 then irq_n := '0'; end if;
            elsif (r mod 1000) < G_IRQ_PERMILLE then
               irq_n := '1';
               rnd(seed, r);
               irq_cnt := 1 + (r mod G_IRQ_LEN);
            end if;
            irq <= irq_n;
            rnd(seed, r);
            ram_done <= '0'; ram_rnw <= '0';
            if (r mod 4) = 0 then ram_done <= '1'; end if;
            if (r mod 8) = 1 then ram_rnw <= '1'; end if;
            ram_dataRead <= std_logic_vector(to_unsigned(r, 32)) xor x"5A5A0F0F";
            dma_cache_write <= '0';
            if (r mod 16) = 2 then dma_cache_write <= '1'; end if;
            dma_cache_data <= std_logic_vector(to_unsigned(r, 32)) xor x"C3C33C3C";
            dma_cache_Adr <= std_logic_vector(to_unsigned(r, 21));
            cpupaused <= '0';
            if (r mod 64) = 3 then cpupaused <= '1'; end if;

            -- GTE: busy after a command, register file writes
            if ce = '1' then
               if g_gWrEna = '1' then gte_regs(to_integer(g_gWrAddr)) <= g_gWrData; end if;
               if busy_cnt > 0 then
                  busy_cnt := busy_cnt - 1;
                  if busy_cnt = 0 then
                     busy_n := '0';
                     rnd(seed, r);
                     gte_regs(r mod 64) <= to_unsigned(r, 32) xor x"7F00FF00";
                  end if;
               end if;
               if g_gCmdEna = '1' then
                  rnd(seed, r);
                  busy_n := '1';
                  busy_cnt := 3 + (r mod (G_GTE_MAX - 2));
               end if;
               gte_busy <= busy_n;
            end if;

            if ce = '1' then
               -- write FIFO drains
               if fifo_cnt > 0 then
                  if fifo_t > 0 then fifo_t := fifo_t - 1;
                  else
                     fifo_cnt := fifo_cnt - 1;
                     rnd(seed, r);
                     fifo_t := r mod G_FIFO_DRAIN;
                  end if;
               end if;

               -- read countdown
               if rd_active then
                  if rd_cnt <= 1 then
                     done_n := '1'; rd_active := false;
                     mem_dataRead <= data_n;
                  else
                     rd_cnt := rd_cnt - 1;
                  end if;
               end if;

               -- icache fill words, one per cycle, always before mem_done
               cache_wr <= (others => '0');
               if fill_k < 4 then
                  cache_wr(fill_k) <= '1';
                  cache_data <= ram(fill_base + fill_k);
                  cache_addr <= fill_line;
                  cache_wr <= transport (others => '0') after 25 ns;
                  if fill_k = 3 then fill_k := 4; else fill_k := fill_k + 1; end if;
               end if;

               -- accept a request
               accept := (g_req = '1');
               if accept then
                  phys := g_addrI and x"1FFFFFFF";
                  if g_isData = '1' then
                     phys := g_addrD and x"1FFFFFFF";
                     if g_rnw = '0' then
                        wr_word(g_addrD, g_dataW, g_wmask);
                        fifo_cnt := fifo_cnt + 1;
                        accept := false;
                     else
                        rnd(seed, r);
                        lat := 1 + (r mod lat_max);
                        if phys >= x"00800000" and not (phys >= x"1FC00000" and phys < x"1FC80000") then
                           lat := 2 + (r mod 6);
                        end if;
                        data_n := rotr(rd_word(g_addrD), to_integer(g_addrD(1 downto 0)));
                     end if;
                  else
                     rnd(seed, r);
                     lat := 1 + (r mod lat_max);
                     data_n := rd_word(g_addrI);
                     if phys < x"00800000" then
                        case g_addrI(3 downto 2) is
                           when "00" => tag_n := "1111";
                           when "01" => tag_n := "1110";
                           when "10" => tag_n := "1100";
                           when others => tag_n := "1000";
                        end case;
                        if g_isCache = '1' then
                           -- fill the line words w..3 before the done
                           fill_first := to_integer(g_addrI(3 downto 2));
                           fill_k := fill_first;
                           fill_base := to_integer(phys(20 downto 4)) * 4;
                           fill_line := std_logic_vector(g_addrI(11 downto 4));
                           if lat < (4 - fill_first) + 1 then lat := (4 - fill_first) + 1; end if;
                        end if;
                     elsif phys >= x"1FC00000" and phys < x"1FC80000" then
                        tag_n := g_oldtag;
                        tag_n(to_integer(g_addrI(3 downto 2))) := '1';
                        if (r mod 4) = 0 then lat := 25 + (r mod 3); end if;
                     else
                        tag_n := "0000";
                        data_n := x"0000000C";      -- not a RAM/BIOS address: SYSCALL, so a test can trap out of it
                     end if;
                     mem_tagvalids <= tag_n;
                  end if;
                  if accept then
                     if G_TRACE > 0 and cyc < 400 then
                        write(l, string'("BUS cyc=") & integer'image(cyc) & string'(" isData=") & std_logic'image(g_isData) & string'(" addrI=") & to_hstring(g_addrI) & string'(" addrD=") & to_hstring(g_addrD) & string'(" lat=") & integer'image(lat) & string'(" data=") & to_hstring(data_n) & string'(" tag=") & to_hstring(tag_n));
                        writeline(output, l);
                     end if;
                     rnd(seed, r);
                     if (r mod 100) < slow_pct then lat := 20 + (r mod 21); end if;
                     if G_LONGWAIT > 0 and (r mod G_LONGWAIT) = 1 then lat := 520 + (r mod 41); end if;
                     -- reads queue behind the write FIFO
                     lat := lat + fifo_cnt; fifo_cnt := 0;
                     rd_active := true; rd_cnt := lat;
                     if rd_cnt <= 1 then
                        done_n := '1'; rd_active := false;
                        mem_dataRead <= data_n;
                     end if;
                  end if;
               end if;

               if fifo_cnt >= G_FIFO_THR then mem_fifofull <= '1'; else mem_fifofull <= '0'; end if;
            end if;
            mem_done <= done_n;
            if rd_active then ce_n := '1'; end if;

            -- ce and DMA stalls start only while the bus is quiet
            quiet := (not rd_active) and done_n = '0' and mem_done = '0' and fill_k = 4 and (not accept);
            if pause_n > 0 then
               pause_n := pause_n - 1;
               if pause_n = 0 then ce_n := '1'; end if;
            elsif ce = '1' and quiet and g_stallNext = '0' then
               rnd(seed, r);
               if (r mod 100) < G_CE_PCT then
                  ce_n := '0';
                  rnd(seed, r);
                  pause_n := 1 + (r mod 12);
               end if;
            end if;
            ce <= ce_n;
            if dma_n > 0 then
               dma_n := dma_n - 1;
               if dma_n = 0 then dmastall <= '0'; end if;
            elsif quiet and ce = '1' and ce_n = '1' then
               rnd(seed, r);
               if (r mod 100) < G_DMA_PCT then
                  dmastall <= '1';
                  rnd(seed, r);
                  dma_n := 1 + (r mod 30);
               end if;
            end if;
         end if;
      end loop;
   end process;
   end block;

end architecture;
