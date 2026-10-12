library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Simple dual-port RAM, one write port (clk_w) and one registered read port (clk_r), inferred as M10K without a
-- read-during-write check (cpu_pocket reads in the middle of the write clock's cycle, so the two never meet).
entity cpu_pocket_ram is
   generic
   (
      WIDTH : natural;
      ABITS : natural
   );
   port
   (
      clk_w : in  std_logic;
      we    : in  std_logic;
      wa    : in  std_logic_vector(ABITS - 1 downto 0);
      d     : in  std_logic_vector(WIDTH - 1 downto 0);
      clk_r : in  std_logic;
      ra    : in  std_logic_vector(ABITS - 1 downto 0);
      q     : out std_logic_vector(WIDTH - 1 downto 0)
   );
end entity;

architecture arch of cpu_pocket_ram is
   type ram_t is array (0 to 2 ** ABITS - 1) of std_logic_vector(WIDTH - 1 downto 0);
   signal ram : ram_t := (others => (others => '0'));
   attribute ramstyle : string;
   attribute ramstyle of ram : signal is "M10K, no_rw_check";
begin

   process (clk_w)
   begin
      if (rising_edge(clk_w)) then
         if (we = '1') then
            ram(to_integer(unsigned(wa))) <= d;
         end if;
      end if;
   end process;

   process (clk_r)
   begin
      if (rising_edge(clk_r)) then
         q <= ram(to_integer(unsigned(ra)));
      end if;
   end process;

end architecture;

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library mem;

use work.pexport.all;

-- Pocket CPU: the golden cpu.vhd (TURBO off, savestate ports unused) with the same ports and cycle-exact behaviour,
-- restructured for area. Documented in docs/pocket/CPU.md (levers, equivalences, results).
entity cpu_pocket is
   generic
   (
      NO_COP0_DEBUG         : boolean := false   -- true: BPC/BDA/DCIC/BDAM/BPCM read 0 and there is no breakpoint exception
   );
   port
   (
      clk1x                 : in  std_logic;
      clk2x                 : in  std_logic;
      clk3x                 : in  std_logic;
      ce                    : in  std_logic;
      reset                 : in  std_logic;

      TURBO                 : in  std_logic;
      TURBO_CACHE           : in  std_logic;
      TURBO_CACHE50         : in  std_logic;

      irqRequest            : in  std_logic;
      dmaStallCPU           : in  std_logic;
      cpuPaused             : in  std_logic;

      error                 : out std_logic := '0';
      error2                : out std_logic := '0';

      mem_request           : out std_logic;
      mem_rnw               : out std_logic;
      mem_isData            : out std_logic;
      mem_isCache           : out std_logic;
      mem_oldtagvalids      : out std_logic_vector(3 downto 0);
      mem_addressInstr      : out unsigned(31 downto 0);
      mem_addressData       : out unsigned(31 downto 0);
      mem_reqsize           : out unsigned(1 downto 0);
      mem_writeMask         : out std_logic_vector(3 downto 0);
      mem_dataWrite         : out std_logic_vector(31 downto 0);
      mem_dataRead          : in  std_logic_vector(31 downto 0);
      mem_done              : in  std_logic;
      mem_fifofull          : in  std_logic;
      mem_tagvalids         : in  std_logic_vector(3 downto 0);

      cache_wr              : in  std_logic_vector(3 downto 0);
      cache_data            : in  std_logic_vector(31 downto 0);
      cache_addr            : in  std_logic_vector(7 downto 0);

      stallNext             : out std_logic;

      dma_cache_Adr         : in  std_logic_vector(20 downto 0);
      dma_cache_data        : in  std_logic_vector(31 downto 0);
      dma_cache_write       : in  std_logic;

      ram_done              : in  std_logic;
      ram_rnw               : in  std_logic;
      ram_dataRead          : in  std_logic_vector(31 downto 0);

      gte_busy              : in  std_logic;
      gte_readEna           : out std_logic := '0';
      gte_readAddr          : out unsigned(5 downto 0);
      gte_readData          : in  unsigned(31 downto 0);
      gte_writeAddr         : out unsigned(5 downto 0);
      gte_writeData         : out unsigned(31 downto 0);
      gte_writeEna          : out std_logic := '0';
      gte_cmdData           : out unsigned(31 downto 0);
      gte_cmdEna            : out std_logic := '0';

      SS_reset              : in  std_logic;
      SS_DataWrite          : in  std_logic_vector(31 downto 0);
      SS_Adr                : in  unsigned(7 downto 0);
      SS_wren_CPU           : in  std_logic;
      SS_wren_SCP           : in  std_logic;
      SS_rden_CPU           : in  std_logic;
      SS_rden_SCP           : in  std_logic;
      SS_DataRead_CPU       : out std_logic_vector(31 downto 0);
      SS_DataRead_SCP       : out std_logic_vector(31 downto 0);
      SS_idle               : out std_logic;

      -- driven only in simulation; the ports stay for synthesis because psx_top_pocket declares them in the component
      cpu_done              : out std_logic := '0';
      cpu_export            : out cpu_export_type := ((others => (others => '0')), (others => '0'), (others => '0'), (others => '0'));

      debug_firstGTE        : in  std_logic
   );
end entity;

architecture arch of cpu_pocket is

   -- icache tag key: the golden stores and compares address bits 31:12. Bits 30:29 are 0 in every cached fetch, and a tag
   -- written with another value (an invalidation after an uncached fetch) has no valid bit and never hits, so 31 and 28:12 do.
   constant TAGW : natural := 18;

   function tagkey(a : unsigned(31 downto 2)) return std_logic_vector is
   begin
      return std_logic_vector(a(31 downto 31)) & std_logic_vector(a(28 downto 12));
   end function;

   function reverse(x : unsigned(31 downto 0)) return unsigned is
      variable r : unsigned(31 downto 0);
   begin
      for i in 0 to 31 loop
         r(i) := x(31 - i);
      end loop;
      return r;
   end function;

   constant C_PRID : unsigned(31 downto 0) := x"00000002";
   constant C_BPV  : unsigned(31 downto 0) := x"80000040";
   constant C_VEC0 : unsigned(31 downto 0) := x"80000080";
   constant C_VEC1 : unsigned(31 downto 0) := x"BFC00180";
   constant C_RST  : unsigned(31 downto 0) := x"BFC00000";
   constant C_CCTL : unsigned(31 downto 0) := x"FFFE0130";

   -- register file
   signal regs_address_a               : std_logic_vector(4 downto 0);
   signal regs_data_a                  : std_logic_vector(31 downto 0);
   signal regs_wren_a                  : std_logic;
   signal regs1_q_b                    : std_logic_vector(31 downto 0);
   signal regs2_q_b                    : std_logic_vector(31 downto 0);
   signal clrcnt                       : unsigned(4 downto 0) := (others => '0');

   -- other register
   signal hi                           : unsigned(31 downto 0) := (others => '0');
   signal lo                           : unsigned(31 downto 0) := (others => '0');

   signal cop0_BPC                     : unsigned(31 downto 0) := (others => '0');
   signal cop0_BDA                     : unsigned(31 downto 0) := (others => '0');
   signal cop0_JUMPDEST                : unsigned(31 downto 0) := (others => '0');
   signal cop0_DCIC                    : unsigned(31 downto 0) := (others => '0');
   signal cop0_BADVADDR                : unsigned(31 downto 0) := (others => '0');
   signal cop0_BDAM                    : unsigned(31 downto 0) := (others => '0');
   signal cop0_BPCM                    : unsigned(31 downto 0) := (others => '0');
   signal cop0_SR                      : unsigned(31 downto 0) := (others => '0');
   signal cop0_CAUSE                   : unsigned(31 downto 0) := (others => '0');
   signal cop0_EPC                     : unsigned(31 downto 0) := (others => '0');

   signal CACHECONTROL                 : unsigned(31 downto 0) := (others => '0');

   -- common
   signal ce_1                         : std_logic := '0';

   signal stallNew1                    : std_logic := '0';
   signal stallNew3                    : std_logic := '0';
   signal stallNew4                    : std_logic := '0';

   signal stall1                       : std_logic := '0';
   signal stall2                       : std_logic := '0';
   signal stall3                       : std_logic := '0';
   signal stall4                       : std_logic := '0';
   signal stall                        : unsigned(4 downto 0) := (others => '0');

   signal exception                    : unsigned(4 downto 0) := (others => '0');
   signal exceptionBreakpoint          : std_logic;

   signal exceptionNew3                : std_logic := '0';
   signal exceptionNew5                : std_logic := '0';
   signal exceptionNew                 : unsigned(4 downto 0) := (others => '0');

   signal exception_SR                 : unsigned(31 downto 0) := (others => '0');
   signal exception_CAUSE              : unsigned(31 downto 0) := (others => '0');
   signal exception_EPC                : unsigned(31 downto 0) := (others => '0');
   signal exception_JMP                : unsigned(31 downto 0) := (others => '0');

   signal exceptionCode                : unsigned(3 downto 0);
   signal exceptionCode_3              : unsigned(3 downto 0);
   signal exceptionInstr               : unsigned(1 downto 0);
   signal exception_PC                 : unsigned(31 downto 0);
   signal exception_branch             : std_logic;
   signal exception_brslot             : std_logic;

   signal memoryMuxStage4              : std_logic := '0';
   signal memoryMuxBusy                : std_logic := '0';
   signal mem1_request_latched         : std_logic := '0';

   signal opcode0                      : unsigned(31 downto 0) := (others => '0');

   signal PCold0                       : unsigned(31 downto 2) := (others => '0');
   signal PCold1                       : unsigned(31 downto 2) := (others => '0');

   signal value1                       : unsigned(31 downto 0) := (others => '0');
   signal value2                       : unsigned(31 downto 0) := (others => '0');

   -- stage 1
   signal tag_address_a                : std_logic_vector(7 downto 0);
   signal tag_data_a                   : std_logic_vector(TAGW + 3 downto 0);
   signal tag_wren_a                   : std_logic;
   signal tag_valid_wr                 : std_logic_vector(3 downto 0);
   signal tag_idx_nt                   : std_logic_vector(7 downto 0);
   signal tag_idx_t                    : std_logic_vector(7 downto 0);
   signal tag_sel_t                    : std_logic;
   signal tag_q_nt                     : std_logic_vector(TAGW + 3 downto 0);
   signal tag_q_t                      : std_logic_vector(TAGW + 3 downto 0);
   signal tag_q_b                      : std_logic_vector(TAGW + 3 downto 0);
   signal tagEq                        : std_logic;

   signal cache_wr_any                 : std_logic;
   signal cache_waddr                  : std_logic_vector(9 downto 0);
   signal cache_raddr                  : std_logic_vector(9 downto 0);
   signal cache_q_b                    : std_logic_vector(31 downto 0);

   signal PC                           : unsigned(31 downto 2) := (others => '0');
   signal FetchAddr                    : unsigned(31 downto 2) := (others => '0');
   signal FetchLastAddr                : unsigned(31 downto 2) := (others => '0');
   signal FetchLastCache               : std_logic := '0';
   signal FetchLastTagvalids           : std_logic_vector(3 downto 0);

   signal cacheValueLast               : unsigned(31 downto 0) := (others => '0');
   signal cacheHitLast                 : std_logic := '0';

   signal blockIRQ                     : std_logic := '0';
   signal blockIRQCnt                  : integer range 0 to 10;
   signal cacheHit                     : std_logic := '0';

   signal mem1_request                 : std_logic := '0';
   signal mem1_cacherequest            : std_logic := '0';
   signal mem1_tagvalids               : std_logic_vector(3 downto 0);

   signal PCnext                       : unsigned(31 downto 2) := (others => '0');
   signal opcodeNext                   : unsigned(31 downto 0) := (others => '0');
   signal fetchReadyNow                : std_logic := '0';
   signal cacheHitTest                 : std_logic;
   signal cacheHitNext                 : std_logic := '0';
   signal blockIRQNext                 : std_logic := '0';
   signal blockIRQCntNext              : integer range 0 to 10;

   -- stage 2
   signal decodeException              : std_logic := '0';
   signal decodeImmData                : unsigned(15 downto 0) := (others => '0');
   signal decodeSource1                : unsigned(4 downto 0) := (others => '0');
   signal decodeSource2                : unsigned(4 downto 0) := (others => '0');
   signal decodeValue1                 : unsigned(31 downto 0) := (others => '0');
   signal decodeValue2                 : unsigned(31 downto 0) := (others => '0');
   signal decodeOP                     : unsigned(5 downto 0) := (others => '0');
   signal decodeCE                     : unsigned(1 downto 0) := (others => '0');   -- opcode(27:26) of the last decoded instruction
   -- derived from the decode registers
   signal decodeFunct                  : unsigned(5 downto 0);
   signal decodeShamt                  : unsigned(4 downto 0);
   signal decodeRD                     : unsigned(4 downto 0);
   signal decodeTarget                 : unsigned(4 downto 0);
   signal decodeJumpTarget             : unsigned(25 downto 0);
   signal decode_gte_readAddr          : unsigned(5 downto 0);

   signal decodeReqSource1             : std_logic := '0';
   signal decodeReqSource2             : std_logic := '0';
   signal decodeLateStall              : std_logic := '0';

   -- wires
   signal opcodeCacheMuxed             : unsigned(31 downto 0) := (others => '0');

   signal decImmData                   : unsigned(15 downto 0);
   signal decSource1                   : unsigned(4 downto 0);
   signal decSource2                   : unsigned(4 downto 0);
   signal decOP                        : unsigned(5 downto 0);
   signal decFunct                     : unsigned(5 downto 0);

   signal decReqSource1                : std_logic;
   signal decReqSource2                : std_logic;

   -- stage 3
   type CPU_LOADTYPE is
   (
      LOADTYPE_SBYTE,
      LOADTYPE_SWORD,
      LOADTYPE_LEFT,
      LOADTYPE_DWORD,
      LOADTYPE_BYTE,
      LOADTYPE_WORD,
      LOADTYPE_RIGHT
   );

   type CPU_EXESTALLTYPE is
   (
      EXESTALLTYPE_NONE,
      EXESTALLTYPE_READLO,
      EXESTALLTYPE_READHI,
      EXESTALLTYPE_GTE,
      EXESTALLTYPE_GTECMD
   );

   --regs
   signal blockLoadforward             : std_logic := '0';
   signal executeException             : std_logic := '0';
   signal resultWriteEnable            : std_logic := '0';
   signal executeGTEReadEnable         : std_logic := '0';
   signal executeBranchdelaySlot       : std_logic := '0';
   signal executeBranchTaken           : std_logic := '0';
   signal resultTarget                 : unsigned(4 downto 0) := (others => '0');
   signal resultData                   : unsigned(31 downto 0) := (others => '0');
   signal executeMemWriteEnable        : std_logic;
   signal executeMemWriteData          : unsigned(31 downto 0) := (others => '0');
   signal executeMemWriteMask          : std_logic_vector(3 downto 0) := (others => '0');
   signal executeAddr                  : unsigned(31 downto 0) := (others => '0');   -- read address; the write address is executeAddr(31:2) & "00"
   signal executeLoadType              : CPU_LOADTYPE;
   signal executeReadEnable            : std_logic := '0';
   signal executeGTETarget             : unsigned(4 downto 0) := (others => '0');
   signal hiloWait                     : integer range 0 to 38;
   signal executeStalltype             : CPU_EXESTALLTYPE;
   signal execute_gte_writeEna         : std_logic := '0';
   signal execute_gte_cmdData          : unsigned(24 downto 0) := (others => '0');
   signal execute_gte_cmdEna           : std_logic := '0';
   signal execute_gte_addr             : unsigned(5 downto 0) := (others => '0');
   signal execute_lastreadCOP          : std_logic := '0';

   --wires
   signal branch                       : std_logic := '0';
   signal PCbranch                     : unsigned(31 downto 0) := (others => '0');
   signal EXEresultWriteEnable         : std_logic;
   signal EXEresultData                : unsigned(31 downto 0);
   signal EXEresultTarget              : unsigned(4 downto 0) := (others => '0');
   signal EXEBranchdelaySlot           : std_logic := '0';
   signal EXEBranchTaken               : std_logic := '0';
   signal EXEMemWriteEnable            : std_logic := '0';
   signal EXEMemWriteData              : unsigned(31 downto 0) := (others => '0');
   signal EXEMemWriteMask              : std_logic_vector(3 downto 0) := (others => '0');
   signal EXEMemAddr                   : unsigned(31 downto 0);
   signal EXEMemWriteException         : std_logic := '0';
   signal EXELoadType                  : CPU_LOADTYPE;
   signal EXEReadEnable                : std_logic := '0';
   signal EXEReadException             : std_logic := '0';
   signal EXEGTeReadEnable             : std_logic := '0';
   signal EXEcalcMULT                  : std_logic := '0';
   signal EXEcalcMULTU                 : std_logic := '0';
   signal EXEcalcDIV                   : std_logic := '0';
   signal EXEcalcDIVU                  : std_logic := '0';
   signal EXEhiUpdate                  : std_logic := '0';
   signal EXEloUpdate                  : std_logic := '0';
   signal EXEstalltype                 : CPU_EXESTALLTYPE;
   signal EXEgte_writeEna              : std_logic := '0';
   signal EXEgte_cmdEna                : std_logic := '0';
   signal EXElastreadCOP               : std_logic := '0';
   signal EXEBreakpoint                : std_logic := '0';
   signal EXECOP0WriteEnable           : std_logic := '0';
   signal EXECOP0WriteDestination      : unsigned(4 downto 0) := (others => '0');
   signal EXECOP0WriteValue            : unsigned(31 downto 0) := (others => '0');

   type CPU_RES is (RES_ADD, RES_SHIFT, RES_LOGIC, RES_SLT, RES_HI, RES_LO, RES_LINK, RES_COP0, RES_GTE, RES_V2);
   signal EXEres                       : CPU_RES;
   signal aluB                         : unsigned(31 downto 0);
   signal aluBx                        : unsigned(31 downto 0);
   signal aluSub                       : std_logic;
   signal aluSum                       : unsigned(32 downto 0);
   signal aluOvf                       : std_logic;
   signal aluSum34                     : unsigned(33 downto 0);
   signal sltRes                       : unsigned(31 downto 0);
   signal aluLt                        : std_logic;
   signal sltUnsigned                  : std_logic;
   signal aluLogic                     : unsigned(31 downto 0);
   signal shiftLeft                    : std_logic;
   signal shiftAmt                     : unsigned(4 downto 0);
   signal shiftIn                      : unsigned(31 downto 0);
   signal shiftFill                    : std_logic;
   signal shiftOut                     : unsigned(31 downto 0);
   signal shiftRes                     : unsigned(31 downto 0);
   signal cop0Rd                       : unsigned(31 downto 0);

   --MULT/DIV
   -- running mult/div: hiloIsDiv selects the divider result, mulSigned the 33 x 33 product's signedness
   signal hiloIsDiv                    : std_logic := '0';
   signal mulSigned                    : std_logic := '0';
   signal mul1                         : unsigned(31 downto 0);
   signal mul2                         : unsigned(31 downto 0);
   signal mulResult                    : signed(65 downto 0);
   signal mulA                         : signed(32 downto 0);
   signal mulB                         : signed(32 downto 0);

   signal DIVstart                     : std_logic;
   signal DIVquotient                  : unsigned(31 downto 0);
   signal DIVremainder                 : unsigned(31 downto 0);

   -- stage 4
   signal scratchpad_address_a         : std_logic_vector(7 downto 0);
   signal scratchpad_wren_a            : std_logic_vector(3 downto 0);
   signal scratchpad_q_b               : std_logic_vector(31 downto 0);
   signal scratchpad_address_b         : std_logic_vector(7 downto 0);
   signal scratchpad_dataread          : unsigned(31 downto 0);

   -- reg
   signal writebackException           : std_logic := '0';
   signal writebackTarget              : unsigned(4 downto 0) := (others => '0');
   signal writebackData                : unsigned(31 downto 0) := (others => '0');
   signal writebackWriteEnable         : std_logic := '0';
   signal writebackGTEReadEnable       : std_logic := '0';
   signal writebackLoadType            : CPU_LOADTYPE;
   signal writebackAddrLow             : unsigned(1 downto 0) := (others => '0');
   signal writebackInvalidateCacheEna  : std_logic := '0';
   signal writebackInvalidateCacheLine : unsigned(7 downto 0) := (others => '0');
   signal WBgte_writeAddr              : unsigned(5 downto 0);

   signal lateReadTarget               : unsigned(4 downto 0) := (others => '0');
   signal lateReadOldData              : unsigned(31 downto 0) := (others => '0');
   signal lateReadData                 : unsigned(31 downto 0) := (others => '0');
   signal lateReadWrite                : std_logic := '0';
   signal lateReadBypass               : std_logic := '0';
   signal lateReadReqDone              : std_logic := '0';
   signal lateReadWriteAfterWrite      : std_logic := '0';
   signal lateReadStall                : std_logic := '0';
   signal lateReadRam                  : std_logic := '0';

   -- wire
   signal mem4_request                 : std_logic := '0';
   signal mem4_address                 : unsigned(31 downto 0) := (others => '0');
   signal mem4_reqsize                 : unsigned(1 downto 0) := (others => '0');
   signal mem4_rnw                     : std_logic := '0';
   signal mem4_pending                 : std_logic := '0';
   signal WBCACHECONTROL               : unsigned(31 downto 0) := (others => '0');
   signal WBinvalidateCacheEna         : std_logic := '0';
   signal WBinvalidateCacheLine        : unsigned(7 downto 0) := (others => '0');

   -- stage 5
   signal writeDoneTarget              : unsigned(4 downto 0) := (others => '0');
   signal writeDoneData                : unsigned(31 downto 0) := (others => '0');
   signal writeDoneWriteEnable         : std_logic := '0';

   signal debugStallcounter            : unsigned(9 downto 0);
   signal debug300exception            : std_logic := '0';

-- synthesis translate_off
   signal opcode1                      : unsigned(31 downto 0) := (others => '0');
   signal opcode2                      : unsigned(31 downto 0) := (others => '0');
   signal opcode3                      : unsigned(31 downto 0) := (others => '0');
   signal opcode4                      : unsigned(31 downto 0) := (others => '0');
   signal PCold2                       : unsigned(31 downto 0) := (others => '0');
   signal PCold3                       : unsigned(31 downto 0) := (others => '0');
   signal PCold4                       : unsigned(31 downto 0) := (others => '0');
   type tRegs is array(0 to 31) of unsigned(31 downto 0);
   signal regs                         : tRegs := (others => (others => '0'));
-- synthesis translate_on

begin

   -- IO
   mem_request       <= mem1_request or mem1_request_latched or mem4_request when (memoryMuxBusy = '0' or mem_done = '1') else '0';
   mem_isCache       <= FetchLastCache     when (mem1_request_latched = '1') else mem1_cacherequest;
   mem_oldtagvalids  <= FetchLastTagvalids when (mem1_request_latched = '1') else mem1_tagvalids;
   mem_addressInstr  <= FetchLastAddr & "00" when (mem1_request_latched = '1') else FetchAddr & "00";
   mem_isData        <= mem4_request;
   mem_rnw           <= mem4_rnw     when mem4_request = '1' else '1';
   mem_addressData   <= mem4_address;
   mem_reqsize       <= mem4_reqsize when mem4_request = '1' else "10";
   mem_dataWrite     <= std_logic_vector(executeMemWriteData);
   mem_writeMask     <= executeMemWriteMask;

   mem1_cacherequest <= '1' when (FetchAddr(31 downto 29) = "000" or FetchAddr(31 downto 29) = "100") else '0';

   stallNext         <= mem_request or stallNew3;

   -- common
   stall        <= dmaStallCPU & stall4 & stall3 & stall2 & stall1;

   exceptionNew <= exceptionNew5 & '0' & exceptionNew3 & '0' & '0';

   mem4_pending <= memoryMuxBusy and memoryMuxStage4;

   SS_DataRead_CPU <= (others => '0');
   SS_DataRead_SCP <= (others => '0');

   process (clk1x)
   begin
      if (rising_edge(clk1x)) then
         if (reset = '1') then

            memoryMuxStage4       <= '0';
            memoryMuxBusy         <= '0';
            mem1_request_latched  <= '0';

         elsif (ce = '1') then

            if (mem1_request = '1') then
               FetchLastAddr      <= FetchAddr;
               FetchLastCache     <= mem1_cacherequest;
               FetchLastTagvalids <= mem1_tagvalids;
               if (mem4_request = '1' or memoryMuxBusy = '1') then
                  mem1_request_latched <= '1';
               end if;
            end if;

            if (mem_done = '1') then
               memoryMuxBusy <= '0';
            end if;

            if (mem_request = '1' and (memoryMuxBusy = '0' or mem_done = '1')) then
               memoryMuxStage4  <= mem4_request;
               if (mem4_request = '1') then
                  memoryMuxBusy <= mem4_rnw;
               else
                  memoryMuxBusy <= '1';
               end if;
               if (mem4_request = '0') then
                  mem1_request_latched <= '0';
               end if;
            end if;

         end if;
      end if;
   end process;

--##############################################################
--############################### register file
--##############################################################
   -- two copies, one read port each; read at clk2x in the middle of the cycle (the address comes from registers), the
   -- result is sampled by the clk1x decode registers at the end of the cycle, before the write of the same edge
   iregisterfile1 : entity work.cpu_pocket_ram
   generic map ( WIDTH => 32, ABITS => 5)
   port map
   (
      clk_w => clk1x,
      we    => regs_wren_a,
      wa    => regs_address_a,
      d     => regs_data_a,
      clk_r => clk2x,
      ra    => std_logic_vector(opcodeCacheMuxed(25 downto 21)),
      q     => regs1_q_b
   );

   iregisterfile2 : entity work.cpu_pocket_ram
   generic map ( WIDTH => 32, ABITS => 5)
   port map
   (
      clk_w => clk1x,
      we    => regs_wren_a,
      wa    => regs_address_a,
      d     => regs_data_a,
      clk_r => clk2x,
      ra    => std_logic_vector(opcodeCacheMuxed(20 downto 16)),
      q     => regs2_q_b
   );

   -- reset clears the 32 registers (the golden clears them from SS_reset; the reset window is 61 cycles)
   regs_wren_a    <= '1' when (reset = '1') else
                     '1' when (lateReadWrite = '1') else
                     '1' when (ce = '1' and stall = 0 and writebackWriteEnable = '1' and writebackException = '0' and writebackTarget > 0) else
                     '0';

   regs_data_a    <= (others => '0') when (reset = '1') else
                     std_logic_vector(lateReadData) when (lateReadWrite = '1') else
                     std_logic_vector(writebackData);

   regs_address_a <= std_logic_vector(clrcnt) when (reset = '1') else
                     std_logic_vector(lateReadTarget) when (lateReadWrite = '1') else
                     std_logic_vector(writebackTarget);

   process (clk1x)
   begin
      if (rising_edge(clk1x)) then
         if (reset = '1') then
            if (clrcnt /= 31) then clrcnt <= clrcnt + 1; end if;
         else
            clrcnt <= (others => '0');
         end if;
      end if;
   end process;

--##############################################################
--############################### stage 1
--##############################################################

   -- Tag RAM: two M10K copies written together and read at clk2x in the middle of the cycle, replacing the golden's
   -- asynchronous read. One copy is read at the index the fetch uses without a taken branch (exception vector or PC), the
   -- other at the branch target; the branch decision picks the word. Every address comes from registers, so it is settled
   -- at the half cycle; a write at the clk1x edge shows in the next cycle's reads, as in the golden.
   itagram0 : entity work.cpu_pocket_ram
   generic map ( WIDTH => TAGW + 4, ABITS => 8)
   port map
   (
      clk_w => clk1x,
      we    => tag_wren_a,
      wa    => tag_address_a,
      d     => tag_data_a,
      clk_r => clk2x,
      ra    => tag_idx_nt,
      q     => tag_q_nt
   );

   itagram1 : entity work.cpu_pocket_ram
   generic map ( WIDTH => TAGW + 4, ABITS => 8)
   port map
   (
      clk_w => clk1x,
      we    => tag_wren_a,
      wa    => tag_address_a,
      d     => tag_data_a,
      clk_r => clk2x,
      ra    => tag_idx_t,
      q     => tag_q_t
   );

   tag_idx_nt <= x"04" when (exceptionBreakpoint = '1') else
                 x"18" when (exception > 0 and cop0_SR(22) = '1') else
                 x"08" when (exception > 0) else
                 std_logic_vector(PC(11 downto 4));
   tag_idx_t  <= std_logic_vector(PCbranch(11 downto 4));
   tag_sel_t  <= '1' when (exceptionBreakpoint /= '1' and exception = 0 and branch = '1') else '0';
   tag_q_b    <= tag_q_t when (tag_sel_t = '1') else tag_q_nt;

   -- tag RAM word: valid bits (TAGW+3:TAGW), key (TAGW-1:0)
   tag_valid_wr  <= "0000" when (writebackInvalidateCacheEna = '1') else mem_tagvalids;
   tag_address_a <= std_logic_vector(writebackInvalidateCacheLine) when (writebackInvalidateCacheEna = '1') else std_logic_vector(FetchLastAddr(11 downto 4));

   tag_data_a    <= tag_valid_wr & tagkey(FetchLastAddr);

   -- icache words: one 1024 x 32 RAM, written per word, read by word address
   cache_wr_any <= cache_wr(0) or cache_wr(1) or cache_wr(2) or cache_wr(3);
   cache_waddr  <= cache_addr & "00" when cache_wr(0) = '1' else
                   cache_addr & "01" when cache_wr(1) = '1' else
                   cache_addr & "10" when cache_wr(2) = '1' else
                   cache_addr & "11";
   cache_raddr  <= std_logic_vector(FetchAddr(11 downto 2));

   icache: entity work.dpram
   generic map ( addr_width => 10, data_width => 32)
   port map
   (
      clock_a     => clk3x,
      address_a   => cache_waddr,
      data_a      => cache_data,
      wren_a      => cache_wr_any,

      clock_b     => clk1x,
      address_b   => cache_raddr,
      data_b      => x"00000000",
      wren_b      => '0',
      q_b         => cache_q_b
   );

   FetchAddr       <= C_BPV(31 downto 2) when (exceptionBreakpoint = '1') else
                      C_VEC1(31 downto 2) when (exception > 0 and cop0_SR(22) = '1') else
                      C_VEC0(31 downto 2) when (exception > 0 and cop0_SR(22) = '0') else
                      PCbranch(31 downto 2) when branch = '1' else
                      PC;

   tagEq           <= '1' when (tag_q_b(TAGW - 1 downto 0) = tagkey(FetchAddr)) else '0';
   cacheHitTest    <= tagEq and tag_q_b(TAGW + to_integer(FetchAddr(3 downto 2)));

   process (all)
   begin
      PCnext          <= FetchAddr;
      fetchReadyNow   <= '0';
      stallNew1       <= stall1;
      opcodeNext      <= opcode0;
      blockirqNext    <= blockirq;
      blockirqCntNext <= blockirqCnt;

      exceptionNew5   <= '0';

      tag_wren_a      <= '0';

      mem1_request    <= '0';
      cacheHitNext    <= '0';
      mem1_tagvalids  <= "0000";

      if (mem_done = '1' and memoryMuxStage4 = '0') then
         if (FetchLastAddr(31 downto 29) = "000" or FetchLastAddr(31 downto 29) = "100") then -- cached
            tag_wren_a   <= '1';
         end if;
      end if;

      if (writebackInvalidateCacheEna = '1') then
         tag_wren_a   <= '1';
      end if;

      if (exception = 0 and blockirq = '0' and cop0_SR(0) = '1' and (cop0_SR(10 downto 8) and cop0_CAUSE(10 downto 8)) /= "000") then

         if (stall = 0) then
            blockirqNext    <= '1';
            blockirqCntNext <= 10;
            exceptionNew5   <= '1';
         elsif (stall1 = '1') then
            if (mem_done = '1' and memoryMuxStage4 = '0') then
               stallNew1 <= '0';
            end if;
         end if;

      elsif (stall = 0) then

         if (reset = '0') then

            if (FetchAddr(31 downto 29) = "000" or FetchAddr(31 downto 29) = "100") then -- cache
               if (cacheHitTest = '1') then
                  cacheHitNext      <= '1';
                  PCnext            <= FetchAddr + 1;
               else
                  mem1_request      <= '1';
                  stallNew1         <= '1';
                  if (tagEq = '1') then
                     mem1_tagvalids <= tag_q_b(TAGW + 3 downto TAGW);
                  end if;
               end if;
            elsif (FetchAddr(31 downto 29) = "101") then
               mem1_request      <= '1';
               stallNew1         <= '1';
            end if;

         end if;

         if (exception > 0) then

            blockirqNext    <= '1';
            blockirqCntNext <= 10;

         else

            if (blockirqCnt > 0) then
               blockirqCntNext <= blockirqCnt - 1;
               if (blockirqCnt = 1) then
                  blockirqNext <= '0';
               end if;
            end if;

         end if;

      elsif (stall1 = '1') then

         if (mem_done = '1' and memoryMuxStage4 = '0') then

            stallNew1      <= '0';
            PCnext         <= FetchAddr + 1;
            fetchReadyNow  <= '1';
            opcodeNext     <= unsigned(mem_dataRead);

         end if;

      end if;

   end process;

   process (clk1x)
   begin
      if (rising_edge(clk1x)) then

         ce_1 <= ce;

         if (reset = '1') then

            stall1         <= '0';
            PC             <= C_RST(31 downto 2);

            blockIRQ       <= '0';
            blockirqCnt    <= 0;
            opcode0        <= (others => '0');
            PCold0         <= (others => '0');

            cacheHit       <= '0';
            cacheHitLast   <= '0';

         elsif (ce = '1') then

            PC             <= PCnext;
            stall1         <= stallNew1;

            blockirq       <= blockirqNext;
            blockirqCnt    <= blockirqCntNext;

            cacheHit       <= cacheHitNext;
            if (cacheHit = '1' and stall > 0) then
               cacheHitLast   <= '1';
               cacheValueLast <= unsigned(cache_q_b);
            elsif (stall = 0) then
               cacheHitLast <= '0';
            end if;

            if (fetchReadyNow = '1') then
               opcode0        <= opcodeNext;
               PCold0         <= PC;
            end if;

            if (cacheHitNext = '1') then
               PCold0 <= FetchAddr;
            end if;

         elsif (ce_1 = '1') then

            if (cacheHit = '1') then
               cacheHitLast   <= '1';
               cacheValueLast <= unsigned(cache_q_b);
            end if;

         end if;
      end if;

   end process;


--##############################################################
--############################### stage 2
--##############################################################

   opcodeCacheMuxed <= cacheValueLast when cacheHitLast = '1' else
                       unsigned(cache_q_b) when cacheHit = '1' else
                       opcode0;

   decImmData    <= opcodeCacheMuxed(15 downto 0);
   decSource1    <= opcodeCacheMuxed(25 downto 21);
   decSource2    <= opcodeCacheMuxed(20 downto 16);
   decOP         <= opcodeCacheMuxed(31 downto 26);
   decFunct      <= opcodeCacheMuxed(5 downto 0);

   -- fields of the decoded instruction (all zero after an exception flush)
   decodeFunct      <= decodeImmData(5 downto 0);
   decodeShamt      <= decodeImmData(10 downto 6);
   decodeRD         <= decodeImmData(15 downto 11);
   decodeTarget     <= decodeSource2 when (decodeOP > 0) else decodeRD;
   decodeJumpTarget <= decodeSource1 & decodeSource2 & decodeImmData;
   decode_gte_readAddr <= decodeSource1(1) & decodeRD when (decodeOP = 16#12#) else '0' & decodeSource2;

   -- find which value is required by which opcode for blocking
   process (all)
   begin

      decReqSource1 <= '0';
      decReqSource2 <= '0';

      case (to_integer(decOP)) is

         when 16#00# =>
            case (to_integer(decFunct)) is

               when 16#08# | -- JR
                    16#09# | -- JALR
                    16#11# | -- MTHI
                    16#13#   -- MTLO
               => decReqSource1 <= '1';

               when 16#00# | -- SLL
                    16#02# | -- SRL
                    16#03#   -- SRA
               => decReqSource2 <= '1';

               when 16#04# | -- SLLV
                    16#06# | -- SRLV
                    16#07# | -- SRAV
                    16#18# | -- MULT
                    16#19# | -- MULTU
                    16#1A# | -- DIV
                    16#1B# | -- DIVU
                    16#20# | -- ADD
                    16#21# | -- ADDU
                    16#22# | -- SUB
                    16#23# | -- SUBU
                    16#24# | -- AND
                    16#25# | -- OR
                    16#26# | -- XOR
                    16#27# | -- NOR
                    16#2A# | -- SLT
                    16#2B#   -- SLTI
               => decReqSource1 <= '1';
                  decReqSource2 <= '1';

               when others => null;

            end case;

         when 16#01# | -- B: BLTZ, BGEZ, BLTZAL, BGEZAL
              16#06# | -- BLEZ
              16#07# | -- BGTZ
              16#08# | -- ADDI
              16#09# | -- ADDIU
              16#0A# | -- SLTI
              16#0B# | -- SLTIU
              16#0C# | -- ANDI
              16#0D# | -- ORI
              16#0E# | -- XORI
              16#20# | -- LB
              16#21# | -- LH
              16#23# | -- LW
              16#24# | -- LBU
              16#25# | -- LHU
              16#32# | -- LWC2
              16#3A#   -- SWC2
            => decReqSource1 <= '1';

         when 16#04# | -- BEQ
              16#05# | -- BNE
              16#28# | -- SB
              16#29# | -- SH
              16#2A# | -- SWL
              16#2B# | -- SW
              16#2E# | -- SWR
              16#22# | -- LWL
              16#26#   -- LWR
            => decReqSource1 <= '1';
               decReqSource2 <= '1';

         when 16#10# => -- COP0
            if (to_integer(decSource1) = 4) then
               decReqSource2 <= '1';
            end if;

         when 16#12# => -- COP2
            if (to_integer(decSource1) = 4 or to_integer(decSource1) = 6) then
               decReqSource2 <= '1';
            end if;

         when others =>
            null;

      end case;

   end process;

   process (clk1x)
   begin
      if (rising_edge(clk1x)) then
         if (reset = '1') then

            stall2     <= '0';

            decodeException  <= '0';
            decodeImmData    <= (others => '0');
            decodeSource1    <= (others => '0');
            decodeSource2    <= (others => '0');
            decodeValue1     <= (others => '0');
            decodeValue2     <= (others => '0');
            decodeOP         <= (others => '0');
            decodeCE         <= (others => '0');

            decodeReqSource1 <= '0';
            decodeReqSource2 <= '0';
-- synthesis translate_off
            opcode1          <= (others => '0');
-- synthesis translate_on

         elsif (ce = '1') then

            if (stall = 0) then

               if (exception(4 downto 1) > 0) then

                  if (exception(4) = '1') then decodeException <= '1'; end if;

                  decodeImmData    <= (others => '0');
                  decodeSource1    <= (others => '0');
                  decodeSource2    <= (others => '0');
                  decodeValue1     <= (others => '0');
                  decodeValue2     <= (others => '0');
                  decodeOP         <= (others => '0');

               else

                  decodeException <= '0';

                  decodeCE         <= opcodeCacheMuxed(27 downto 26);
-- synthesis translate_off
                  opcode1          <= opcodeCacheMuxed;
-- synthesis translate_on

                  decodeValue1     <= unsigned(regs1_q_b);
                  decodeValue2     <= unsigned(regs2_q_b);

                  decodeImmData    <= decImmData;
                  decodeSource1    <= decSource1;
                  decodeSource2    <= decSource2;
                  decodeOP         <= decOP;

                  decodeReqSource1 <= decReqSource1;
                  decodeReqSource2 <= decReqSource2;

               end if;

            end if;

            if (mem4_pending = '1') then
               if ((decReqSource1    = '1' and decSource1    = lateReadTarget) or (decodeReqSource1 = '1' and decodeSource1 = lateReadTarget) or
                   (decReqSource2    = '1' and decSource2    = lateReadTarget) or (decodeReqSource2 = '1' and decodeSource2 = lateReadTarget)) then
                  stall2          <= '1';
                  -- for some reason the original cpu stalls 1 cycle longer than needed if the value is required by next op...need to compensate
                  if (stall2 = '0') then
                     decodeLateStall <= not stall4;
                  end if;
               end if;
            elsif (stall4 = '0' or decodeLateStall = '0') then
               stall2 <= '0';
            end if;

         end if;
      end if;
   end process;

   PCold1_proc : process (clk1x)
   begin
      if (rising_edge(clk1x)) then
         if (reset = '1') then
            PCold1 <= (others => '0');
         elsif (ce = '1' and stall = 0 and exception(4 downto 1) = 0) then
            PCold1 <= PCold0;
         end if;
      end if;
   end process;


--##############################################################
--############################### stage 3
--##############################################################

   process (all)
   begin

      value1 <= decodeValue1;
      if    (decodeSource1 > 0 and resultTarget    = decodeSource1 and resultWriteEnable    = '1' and execute_lastreadCOP = '0') then value1 <= resultData;
      elsif (decodeSource1 = lateReadTarget and lateReadBypass = '1' and blockLoadforward = '0' )                                then value1 <= lateReadData;
      elsif (decodeSource1 > 0 and writebackTarget = decodeSource1 and writebackWriteEnable = '1' and blockLoadforward = '0')    then value1 <= writebackData;
      elsif (decodeSource1 > 0 and writeDoneTarget = decodeSource1 and writeDoneWriteEnable = '1')                               then value1 <= writeDoneData;
      end if;

      value2 <= decodeValue2;
      if    (decodeSource2 > 0 and resultTarget    = decodeSource2 and resultWriteEnable    = '1' and execute_lastreadCOP = '0') then value2 <= resultData;
      elsif (decodeSource2 = lateReadTarget and lateReadBypass = '1' and blockLoadforward = '0' )                                then value2 <= lateReadData;
      elsif (decodeSource2 > 0 and writebackTarget = decodeSource2 and writebackWriteEnable = '1' and blockLoadforward = '0'   ) then value2 <= writebackData;
      elsif (decodeSource2 > 0 and writeDoneTarget = decodeSource2 and writeDoneWriteEnable = '1')                               then value2 <= writeDoneData;
      end if;

   end process;

   gdebug : if not NO_COP0_DEBUG generate
      EXEBreakpoint <= '1' when ((cop0_DCIC(31 downto 29) = "111" and cop0_DCIC(24 downto 23) = "11") and (((PCold1 & "00" xor cop0_BPC) and cop0_BPCM) = x"00000000")) else '0';
   end generate;
   gnodebug : if NO_COP0_DEBUG generate
      EXEBreakpoint <= '0';
   end generate;

   -- ALU datapath: one adder/subtractor (add, sub, compare, memory address), one logic unit, one shifter.
   -- The case below selects the result (EXEres) and the control; the data is computed here.
   aluB <= value2 when (decodeOP = 0) else
           x"0000" & decodeImmData when (decodeOP = 16#0C# or decodeOP = 16#0D# or decodeOP = 16#0E#) else
           decodeImmData & x"0000" when (decodeOP = 16#0F#) else
           unsigned(resize(signed(decodeImmData), 32));

   aluSub <= (decodeFunct(1) and not decodeFunct(2)) when (decodeOP = 0) else
             '1' when (decodeOP(5 downto 1) = "00101") else
             '0';

   aluBx   <= aluB xor (31 downto 0 => aluSub);
   aluSum34 <= ('0' & value1 & '1') + ('0' & aluBx & aluSub);
   aluSum  <= aluSum34(33 downto 1);

   aluOvf  <= (aluSum(31) xor value1(31)) and (aluSum(31) xor aluBx(31));

   -- A - B borrow; a signed compare flips the unsigned result when the signs differ
   sltUnsigned <= decodeFunct(0) when (decodeOP = 0) else decodeOP(0);
   aluLt   <= (not aluSum(32)) xor ((value1(31) xor aluB(31)) and not sltUnsigned);
   sltRes  <= (0 => aluLt, others => '0');

   process (all)
      variable lsel : unsigned(2 downto 0);
   begin
      if (decodeOP = 16#0F#) then
         lsel := "100";
      elsif (decodeOP = 0) then
         lsel := '0' & decodeFunct(1 downto 0);
      else
         lsel := '0' & decodeOP(1 downto 0);
      end if;
      case (to_integer(lsel)) is
         when 0      => aluLogic <= value1 and aluB;
         when 1      => aluLogic <= value1 or aluB;
         when 2      => aluLogic <= value1 xor aluB;
         when 3      => aluLogic <= value1 nor aluB;
         when others => aluLogic <= aluB;
      end case;
   end process;

   -- one barrel shifter for left and right shifts: left shifts run on the bit-reversed operand
   shiftLeft  <= not decodeFunct(1);
   shiftAmt   <= value1(4 downto 0) when (decodeFunct(2) = '1') else decodeShamt;
   shiftIn    <= reverse(value2) when (shiftLeft = '1') else value2;
   shiftFill  <= decodeFunct(0) and value2(31);
   shiftOut   <= resize(unsigned(shift_right(signed(shiftFill & std_logic_vector(shiftIn)), to_integer(shiftAmt))), 32);
   shiftRes   <= reverse(shiftOut) when (shiftLeft = '1') else shiftOut;

   process (all)
   begin
      case (to_integer(decodeRD)) is
         when 16#3# => if not NO_COP0_DEBUG then cop0Rd <= cop0_BPC; else cop0Rd <= (others => '0'); end if;
         when 16#5# => if not NO_COP0_DEBUG then cop0Rd <= cop0_BDA; else cop0Rd <= (others => '0'); end if;
         when 16#6# => cop0Rd <= cop0_JUMPDEST;
         when 16#7# => if not NO_COP0_DEBUG then cop0Rd <= cop0_DCIC; else cop0Rd <= (others => '0'); end if;
         when 16#8# => cop0Rd <= cop0_BADVADDR;
         when 16#9# => if not NO_COP0_DEBUG then cop0Rd <= cop0_BDAM; else cop0Rd <= (others => '0'); end if;
         when 16#B# => if not NO_COP0_DEBUG then cop0Rd <= cop0_BPCM; else cop0Rd <= (others => '0'); end if;
         when 16#C# => cop0Rd <= cop0_SR;
         when 16#D# => cop0Rd <= cop0_CAUSE;
         when 16#E# => cop0Rd <= cop0_EPC;
         when 16#F# => cop0Rd <= C_PRID;
         when others => cop0Rd <= (others => '0');
      end case;
   end process;

   EXEresultData <= shiftRes                               when (EXEres = RES_SHIFT) else
                    aluLogic                               when (EXEres = RES_LOGIC) else
                    sltRes                                 when (EXEres = RES_SLT)   else
                    hi                                     when (EXEres = RES_HI)    else
                    lo                                     when (EXEres = RES_LO)    else
                    PC & "00"                              when (EXEres = RES_LINK)  else
                    cop0Rd                                 when (EXEres = RES_COP0)  else
                    gte_readData                           when (EXEres = RES_GTE)   else
                    value2                                 when (EXEres = RES_V2)    else
                    aluSum(31 downto 0);

   EXEMemAddr <= aluSum(31 downto 0);

   process (all)
      variable calcMemAddr  : unsigned(31 downto 0);
   begin

      branch                  <= '0';
      exceptionNew3           <= '0';
      stallNew3               <= stall3;
      PCbranch                <= PCold0 & "00";
      EXEresultTarget         <= decodeTarget;
      EXEresultWriteEnable    <= '0';
      EXEres                  <= RES_ADD;

      calcMemAddr             := aluSum(31 downto 0);

      EXEMemWriteEnable       <= '0';
      EXEMemWriteData         <= value2;
      EXEMemWriteMask         <= "1111";
      EXEMemWriteException    <= '0';

      EXELoadType             <= LOADTYPE_DWORD;
      EXEReadEnable           <= '0';
      EXEReadException        <= '0';
      EXEGTeReadEnable        <= '0';

      EXECOP0WriteEnable      <= '0';
      EXECOP0WriteDestination <= decodeRD;
      EXECOP0WriteValue       <= value2;

      EXEBranchdelaySlot      <= '0';
      EXEBranchTaken          <= '0';

      EXEcalcMULT             <= '0';
      EXEcalcMULTU            <= '0';
      EXEcalcDIV              <= '0';
      EXEcalcDIVU             <= '0';

      EXEhiUpdate             <= '0';
      EXEloUpdate             <= '0';

      EXElastreadCOP          <= '0';

      EXEgte_cmdEna           <= '0';

      EXEgte_writeEna         <= '0';

      exceptionCode_3         <= x"0";

      EXEstalltype            <= EXESTALLTYPE_NONE;

      gte_readAddr            <= decode_gte_readAddr;
      gte_readEna             <= '0';

      if (executeStalltype = EXESTALLTYPE_GTE and gte_busy = '0' and gte_cmdEna = '0' and ce = '1') then
         gte_readEna         <= '1';
         gte_readAddr        <= execute_gte_addr;
      end if;

      if (EXEBreakpoint = '1') then

         exceptionNew3   <= '1';
         exceptionCode_3 <= x"9";

      elsif (exception(4 downto 2) = 0 and stall = 0) then

         case (to_integer(decodeOP)) is

            when 16#00# =>
               case (to_integer(decodeFunct)) is

                  when 16#00# | 16#04# | 16#02# | 16#03# | 16#06# | 16#07# => -- SLL SRL SRA SLLV SRLV SRAV
                     EXEresultWriteEnable <= '1';
                     EXEres               <= RES_SHIFT;

                  when 16#08# => -- JR
                     EXEBranchdelaySlot <= '1';
                     EXEBranchTaken     <= '1';
                     PCbranch           <= value1;
                     if (value1(1 downto 0) > 0) then
                        exceptionNew3   <= '1';
                        exceptionCode_3 <= x"4";
                     else
                        branch <= '1';
                     end if;

                  when 16#09# => -- JALR
                     EXEBranchdelaySlot   <= '1';
                     EXEBranchTaken       <= '1';
                     PCbranch             <= value1;
                     EXEresultWriteEnable <= '1';
                     EXEres               <= RES_LINK;
                     EXEresultTarget      <= decodeRD;
                     if (value1(1 downto 0) > 0) then
                        exceptionNew3   <= '1';
                        exceptionCode_3 <= x"4";
                     else
                        branch <= '1';
                     end if;

                  when 16#0C# => -- SYSCALL
                     exceptionNew3   <= '1';
                     exceptionCode_3 <= x"8";

                  when 16#0D# => -- BREAK
                     exceptionNew3   <= '1';
                     exceptionCode_3 <= x"9";

                  when 16#10# => -- MFHI
                     EXEresultWriteEnable <= '1';
                     if (hiloWait > 1) then
                        stallNew3    <= '1';
                        EXEstalltype <= EXESTALLTYPE_READHI;
                     else
                        EXEres       <= RES_HI;
                     end if;

                  when 16#11# => -- MTHI
                     EXEhiUpdate <= '1';

                  when 16#12# => -- MFLO
                     EXEresultWriteEnable <= '1';
                     if (hiloWait > 1) then
                        stallNew3    <= '1';
                        EXEstalltype <= EXESTALLTYPE_READLO;
                     else
                        EXEres       <= RES_LO;
                     end if;

                  when 16#13# => -- MTLO
                     EXEloUpdate <= '1';

                  when 16#18# => -- MULT
                     EXEcalcMULT <= '1';

                  when 16#19# => -- MULTU
                     EXEcalcMULTU <= '1';

                  when 16#1A# => -- DIV
                     EXEcalcDIV <= '1';

                  when 16#1B# => -- DIVU
                     EXEcalcDIVU <= '1';

                  when 16#20# => -- ADD
                     if (aluOvf = '1') then
                        exceptionNew3   <= '1';
                        exceptionCode_3 <= x"C";
                     else
                        EXEresultWriteEnable <= '1';
                     end if;

                  when 16#21# | 16#23# => -- ADDU SUBU
                     EXEresultWriteEnable <= '1';

                  when 16#22# => -- SUB
                     if (aluOvf = '1') then
                        exceptionNew3   <= '1';
                        exceptionCode_3 <= x"C";
                     else
                        EXEresultWriteEnable <= '1';
                     end if;

                  when 16#24# | 16#25# | 16#26# | 16#27# => -- AND OR XOR NOR
                     EXEresultWriteEnable <= '1';
                     EXEres               <= RES_LOGIC;

                  when 16#2A# | 16#2B# => -- SLT SLTU
                     EXEresultWriteEnable <= '1';
                     EXEres               <= RES_SLT;

                  when others =>
                     exceptionNew3   <= '1';
                     exceptionCode_3 <= x"A";

               end case;

            when 16#01# => -- B: BLTZ, BGEZ, BLTZAL, BGEZAL
               EXEBranchdelaySlot <= '1';
               if (decodeSource2(0) = '1') then
                  if (signed(value1) >= 0) then
                     EXEBranchTaken <= '1';
                     branch         <= '1';
                  end if;
               else
                  if (signed(value1) < 0) then
                     EXEBranchTaken <= '1';
                     branch         <= '1';
                  end if;
               end if;
               if (decodeSource2(4 downto 1) = "1000") then
                    EXEresultWriteEnable <= '1';
                    EXEres               <= RES_LINK;
                    EXEresultTarget      <= to_unsigned(31, 5);
               end if;
               PCbranch <= (PCold0 + unsigned(resize(signed(decodeImmData), 30))) & "00";

            when 16#02# => -- J
               EXEBranchdelaySlot <= '1';
               EXEBranchTaken     <= '1';
               branch             <= '1';
               PCbranch           <= PCold0(31 downto 28) & decodeJumpTarget & "00";

            when 16#03# => -- JAL
               EXEBranchdelaySlot   <= '1';
               EXEBranchTaken       <= '1';
               branch               <= '1';
               EXEresultWriteEnable <= '1';
               EXEres               <= RES_LINK;
               EXEresultTarget      <= to_unsigned(31, 5);
               PCbranch             <= PCold0(31 downto 28) & decodeJumpTarget & "00";

            when 16#04# => -- BEQ
               EXEBranchdelaySlot   <= '1';
               PCbranch             <= (PCold0 + unsigned(resize(signed(decodeImmData), 30))) & "00";
               if (value1 = value2) then
                  EXEBranchTaken    <= '1';
                  branch            <= '1';
               end if;

            when 16#05# => -- BNE
               EXEBranchdelaySlot   <= '1';
               PCbranch             <= (PCold0 + unsigned(resize(signed(decodeImmData), 30))) & "00";
               if (value1 /= value2) then
                  EXEBranchTaken    <= '1';
                  branch            <= '1';
               end if;

            when 16#06# => -- BLEZ
               EXEBranchdelaySlot   <= '1';
               PCbranch             <= (PCold0 + unsigned(resize(signed(decodeImmData), 30))) & "00";
               if (signed(value1) <= 0) then
                  EXEBranchTaken    <= '1';
                  branch            <= '1';
               end if;

            when 16#07# => -- BGTZ
               EXEBranchdelaySlot   <= '1';
               PCbranch             <= (PCold0 + unsigned(resize(signed(decodeImmData), 30))) & "00";
               if (signed(value1) > 0) then
                  EXEBranchTaken    <= '1';
                  branch            <= '1';
               end if;

            when 16#08# => -- ADDI
               if (aluOvf = '1') then
                  exceptionNew3   <= '1';
                  exceptionCode_3 <= x"C";
               else
                  EXEresultWriteEnable <= '1';
               end if;

            when 16#09# => -- ADDIU
               EXEresultWriteEnable <= '1';

            when 16#0A# | 16#0B# => -- SLTI SLTIU
               EXEresultWriteEnable <= '1';
               EXEres               <= RES_SLT;

            when 16#0C# | 16#0D# | 16#0E# | 16#0F# => -- ANDI ORI XORI LUI
               EXEresultWriteEnable <= '1';
               EXEres               <= RES_LOGIC;

            when 16#10# => -- COP0
               if (cop0_SR(1) = '1' and cop0_SR(28) = '0') then
                  exceptionNew3   <= '1';
                  exceptionCode_3 <= x"B";
               else
                  if (decodeSource1(4) = '1') then
                     case (to_integer(decodeImmData(6 downto 0))) is
                        when 1 | 2 | 4 | 8 =>
                           exceptionNew3   <= '1';
                           exceptionCode_3 <= x"A";

                        when 16 => -- Cop0Op - rfe
                           EXECOP0WriteEnable      <= '1';
                           EXECOP0WriteDestination <= to_unsigned(12, 5);
                           EXECOP0WriteValue       <= cop0_SR(31 downto 4) & cop0_SR(5 downto 2);

                        when others => report "should not happen" severity failure;
                     end case;
                  else
                     case (to_integer(decodeSource1)) is

                        when 0 => -- mfcn
                           EXEresultWriteEnable <= '1';
                           EXElastreadCOP       <= '1';
                           EXEres               <= RES_COP0;

                        when 4 => -- mtcn
                           EXECOP0WriteEnable      <= '1';
                           EXECOP0WriteDestination <= decodeRD;
                           EXECOP0WriteValue       <= value2;

                        when others => report "should not happen" severity failure;
                     end case;
                  end if;
               end if;

            when 16#11# => -- COP1 -> NOP
               null;

            when 16#12# => -- COP2
               if (cop0_SR(30) = '0') then -- COP2 disabled
                  exceptionNew3   <= '1';
                  exceptionCode_3 <= x"B";
               else
                  if (decodeSource1(4) = '1') then
                     EXEgte_cmdEna <= '1';
                     if (gte_busy = '1' or execute_gte_cmdEna = '1') then
                        stallNew3    <= '1';
                        EXEstalltype <= EXESTALLTYPE_GTECMD;
                     end if;
                  else
                     case (decodeSource1(3 downto 0)) is
                        when x"0" | x"2" => --mfcn cfcn
                           EXEresultWriteEnable <= '1';
                           EXEres               <= RES_GTE;
                           EXElastreadCOP       <= '1';
                           if (gte_busy = '1' or gte_cmdEna = '1' or execute_gte_cmdEna = '1' or gte_writeEna = '1') then
                              stallNew3    <= '1';
                              EXEstalltype <= EXESTALLTYPE_GTE;
                           else
                              gte_readEna          <= ce;
                           end if;

                        when x"4" | x"6" => --mtcn ctcn
                           EXEgte_writeEna      <= '1';
                           if (gte_busy = '1' or execute_gte_cmdEna = '1') then
                              stallNew3    <= '1';
                              EXEstalltype <= EXESTALLTYPE_GTECMD;
                           end if;

                        when others => null;
                     end case;
                  end if;
               end if;

            when 16#13# => -- COP3 -> NOP
               null;

            when 16#20# => -- LB
               EXELoadType   <= LOADTYPE_SBYTE;
               EXEReadEnable <= '1';

             when 16#21# => -- LH
               EXELoadType <= LOADTYPE_SWORD;
               if (calcMemAddr(0) = '1') then
                  exceptionNew3    <= '1';
                  exceptionCode_3  <= x"4";
                  EXEReadException <= '1';
               else
                  EXEReadEnable <= '1';
               end if;

            when 16#22# => -- LWL
               EXELoadType   <= LOADTYPE_LEFT;
               EXEReadEnable <= '1';
               EXEres        <= RES_V2;

            when 16#23# => -- LW
               EXELoadType <= LOADTYPE_DWORD;
               if (calcMemAddr(1 downto 0) /= "00") then
                  exceptionNew3    <= '1';
                  exceptionCode_3  <= x"4";
                  EXEReadException <= '1';
               else
                  EXEReadEnable <= '1';
               end if;

            when 16#24# => -- LBU
               EXELoadType <= LOADTYPE_BYTE;
               EXEReadEnable <= '1';

            when 16#25# => -- LHU
               EXELoadType <= LOADTYPE_WORD;
               if (calcMemAddr(0) = '1') then
                  exceptionNew3    <= '1';
                  exceptionCode_3  <= x"4";
                  EXEReadException <= '1';
               else
                  EXEReadEnable <= '1';
               end if;

            when 16#26# => -- LWR
               EXELoadType   <= LOADTYPE_RIGHT;
               EXEReadEnable <= '1';
               EXEres        <= RES_V2;

            when 16#28# => -- SB
               case (to_integer(calcMemAddr(1 downto 0))) is
                  when 0 => EXEMemWriteMask <= "0001"; EXEMemWriteData <= value2;
                  when 1 => EXEMemWriteMask <= "0010"; EXEMemWriteData <= value2(23 downto 0) & x"00";
                  when 2 => EXEMemWriteMask <= "0100"; EXEMemWriteData <= value2(15 downto 0) & x"0000";
                  when 3 => EXEMemWriteMask <= "1000"; EXEMemWriteData <= value2(7 downto 0) & x"000000";
                  when others => null;
               end case;
               EXEMemWriteEnable <= '1';

            when 16#29# => -- SH
               if (calcMemAddr(1) = '1') then
                  EXEMemWriteData <= value2(15 downto 0) & x"0000";
                  EXEMemWriteMask <= "1100";
               else
                  EXEMemWriteData <= value2;
                  EXEMemWriteMask <= "0011";
               end if;
               if (calcMemAddr(0) = '1') then
                  exceptionNew3        <= '1';
                  exceptionCode_3      <= x"5";
                  EXEMemWriteException <= '1';
               else
                  EXEMemWriteEnable <= '1';
               end if;

            when 16#2A# => -- SWL
               case (to_integer(calcMemAddr(1 downto 0))) is
                  when 0 => EXEMemWriteMask <= "0001"; EXEMemWriteData <= x"000000" & value2(31 downto 24);
                  when 1 => EXEMemWriteMask <= "0011"; EXEMemWriteData <= x"0000" & value2(31 downto 16);
                  when 2 => EXEMemWriteMask <= "0111"; EXEMemWriteData <= x"00" & value2(31 downto 8);
                  when 3 => EXEMemWriteMask <= "1111"; EXEMemWriteData <= value2;
                  when others => null;
               end case;
               EXEMemWriteEnable <= '1';

            when 16#2B# => -- SW
               if (calcMemAddr(1 downto 0) /= "00") then
                  exceptionNew3        <= '1';
                  exceptionCode_3      <= x"5";
                  EXEMemWriteException <= '1';
               else
                  EXEMemWriteEnable <= '1';
               end if;

            when 16#2E# => -- SWR
               case (to_integer(calcMemAddr(1 downto 0))) is
                  when 0 => EXEMemWriteMask <= "1111"; EXEMemWriteData <= value2;
                  when 1 => EXEMemWriteMask <= "1110"; EXEMemWriteData <= value2(23 downto 0) & x"00";
                  when 2 => EXEMemWriteMask <= "1100"; EXEMemWriteData <= value2(15 downto 0) & x"0000";
                  when 3 => EXEMemWriteMask <= "1000"; EXEMemWriteData <= value2( 7 downto 0) & x"000000";
                  when others => null;
               end case;
               EXEMemWriteEnable <= '1';

            when 16#30# => -- LWC0 -> NOP
               null;

            when 16#31# => -- LWC1 -> NOP
               null;

            when 16#32# => -- LWC2
               if (cop0_SR(30) = '0') then -- COP2 disabled
                  exceptionNew3   <= '1';
                  exceptionCode_3 <= x"B";
               else
                  EXEGTeReadEnable <= '1';
                  EXELoadType      <= LOADTYPE_DWORD;
                  EXEReadEnable    <= '1';
                  if (gte_busy = '1' or execute_gte_cmdEna = '1') then
                     stallNew3    <= '1';
                     EXEstalltype <= EXESTALLTYPE_GTECMD;
                  end if;
               end if;

            when 16#33# => -- LWC3 -> NOP
               null;

            when 16#38# => -- SWC0 -> NOP
               null;

            when 16#39# => -- SWC1 -> NOP
               null;

            when 16#3A# => -- SWC2
               if (cop0_SR(30) = '0') then -- COP2 disabled
                  exceptionNew3   <= '1';
                  exceptionCode_3 <= x"B";
               else
                  EXEMemWriteEnable <= '1';
                  EXEMemWriteData   <= gte_readData;
                  if (gte_busy = '1' or execute_gte_cmdEna = '1' or gte_writeEna = '1') then
                     stallNew3    <= '1';
                     EXEstalltype <= EXESTALLTYPE_GTE;
                  else
                     gte_readEna  <= ce;
                  end if;
               end if;

            when 16#3B# => -- SWC3 -> NOP
               null;

            when others =>
               exceptionNew3   <= '1';
               exceptionCode_3 <= x"A";

         end case;

      end if;

   end process;

   process (clk1x)
   begin
      if (rising_edge(clk1x)) then
         if (reset = '1') then

            stall3                        <= '0';

            cop0_BPC                      <= (others => '0');
            cop0_BDA                      <= (others => '0');
            cop0_JUMPDEST                 <= (others => '0');
            cop0_DCIC                     <= (others => '0');
            cop0_BDAM                     <= (others => '0');
            cop0_BPCM                     <= (others => '0');
            cop0_SR                       <= (others => '0');
            cop0_CAUSE                    <= (others => '0');
            cop0_EPC                      <= (others => '0');

            blockLoadforward              <= '0';

            executeException              <= '0';
            resultWriteEnable             <= '0';
            resultData                    <= (others => '0');
            resultTarget                  <= (others => '0');
            executeBranchdelaySlot        <= '0';
            executeBranchTaken            <= '0';
            executeMemWriteData           <= (others => '0');
            executeMemWriteMask           <= (others => '0');
            executeAddr                   <= (others => '0');
            executeMemWriteEnable         <= '0';
            executeLoadType               <= CPU_LOADTYPE'VAL(0);
            executeReadEnable             <= '0';
            hiloWait                      <= 0;

            hi                            <= (others => '0');
            lo                            <= (others => '0');

            executeStalltype              <= EXESTALLTYPE_NONE;

            executeGTEReadEnable          <= '0';
            executeGTETarget              <= (others => '0');

            execute_gte_writeEna          <= '0';

            execute_gte_cmdData           <= (others => '0');
            execute_gte_cmdEna            <= '0';
            execute_gte_addr          <= (others => '0');

            execute_lastreadCOP           <= '0';
-- synthesis translate_off
            opcode2                       <= (others => '0');
-- synthesis translate_on

         elsif (ce = '1') then

            -- mul/div calc/wait
            if (hiloWait > 0) then
               hiloWait <= hiloWait - 1;
               if (hiloWait = 1) then
                  case (executeStalltype) is
                     when EXESTALLTYPE_READHI => resultData <= hi; stall3 <= '0'; executeStalltype <= EXESTALLTYPE_NONE;
                     when EXESTALLTYPE_READLO => resultData <= lo; stall3 <= '0'; executeStalltype <= EXESTALLTYPE_NONE;
                     when others => null;
                  end case;
               end if;
            end if;

            mulResult <= mulA * mulB;

            if (hiloWait = 2) then
               if (hiloIsDiv = '1') then
                  hi <= DIVremainder; lo <= DIVquotient;
               else
                  hi <= unsigned(mulResult(63 downto 32)); lo <= unsigned(mulResult(31 downto 0));
               end if;
            end if;

            -- GTE
            if (executeStalltype = EXESTALLTYPE_GTE and gte_readEna = '1') then
               resultData          <= gte_readData;
               executeMemWriteData <= gte_readData;
               stall3              <= '0';
               executeStalltype    <= EXESTALLTYPE_NONE;
            end if;

            if (executeStalltype = EXESTALLTYPE_GTECMD and gte_busy = '0') then
               stall3              <= '0';
               executeStalltype    <= EXESTALLTYPE_NONE;
            end if;

            if (stall = 0) then

               if (exception(4 downto 2) > 0) then

                  executeException              <= '1';

                  stall3                        <= '0';

                  resultWriteEnable             <= '0';
                  executeReadEnable             <= '0';
                  executeMemWriteEnable         <= '0';
                  executeGTEReadEnable          <= '0';

                  executeStalltype              <= EXESTALLTYPE_NONE;

               else

-- synthesis translate_off
                  PCold2                        <= PCold1 & "00";
                  opcode2                       <= opcode1;
-- synthesis translate_on
                  executeException              <= decodeException;

                  stall3                        <= stallNew3;

                  -- from calculation
                  resultWriteEnable             <= EXEresultWriteEnable;

                  resultData                    <= EXEresultData;
                  resultTarget                  <= EXEresultTarget;

                  executeBranchdelaySlot        <= EXEBranchdelaySlot;
                  executeBranchTaken            <= EXEBranchTaken;

                  executeMemWriteData           <= EXEMemWriteData;
                  executeMemWriteMask           <= EXEMemWriteMask;
                  executeAddr                   <= EXEMemAddr;
                  executeMemWriteEnable         <= EXEMemWriteEnable;

                  executeLoadType               <= EXELoadType;
                  executeReadEnable             <= EXEReadEnable;

                  executeGTEReadEnable          <= EXEGTeReadEnable;
                  executeGTETarget              <= decodeSource2;

                  executeStalltype              <= EXEstalltype;

                  execute_gte_writeEna          <= EXEgte_writeEna;

                  execute_gte_cmdData           <= decodeSource1(3 downto 0) & decodeSource2 & decodeImmData;
                  execute_gte_cmdEna            <= EXEgte_cmdEna;

                  execute_gte_addr          <= decode_gte_readAddr;
                  execute_lastreadCOP           <= EXElastreadCOP;

                  if (EXECOP0WriteEnable = '1') then
                     case (to_integer(EXECOP0WriteDestination)) is
                        when 16#3# => if not NO_COP0_DEBUG then cop0_BPC   <= EXECOP0WriteValue; end if;
                        when 16#5# => if not NO_COP0_DEBUG then cop0_BDA   <= EXECOP0WriteValue; end if;
                        when 16#7# => if not NO_COP0_DEBUG then cop0_DCIC  <= EXECOP0WriteValue and x"FF80F03F"; end if;
                        when 16#9# => if not NO_COP0_DEBUG then cop0_BDAM  <= EXECOP0WriteValue; end if;
                        when 16#B# => if not NO_COP0_DEBUG then cop0_BPCM  <= EXECOP0WriteValue; end if;
                        when 16#C# => cop0_SR    <= EXECOP0WriteValue and x"F27FFF3F";
                        when 16#D# => cop0_CAUSE <= EXECOP0WriteValue and x"00000300";
                        when others => null;
                     end case;
                  end if;

                  if (executeException = '1') then
                     cop0_SR        <= exception_SR;
                     cop0_CAUSE     <= exception_CAUSE;
                     cop0_EPC       <= exception_EPC;
                     cop0_JUMPDEST  <= exception_JMP;
                  end if;

                  cop0_CAUSE(10) <= irqRequest;

                  blockLoadforward <= '0';
                  if (executeReadEnable = '1' and EXEReadEnable = '1' and EXEGTeReadEnable = '0' and resultTarget = EXEresultTarget) then
                     blockLoadforward <= '1';
                  end if;

                  -- new mul/div; the divider returns the PSX results for a zero divisor and 0x80000000 / -1 by itself
                  if (EXEcalcMULT = '1' or EXEcalcMULTU = '1') then
                     mul1       <= value1;
                     mul2       <= value2;
                     hiloIsDiv  <= '0';
                     mulSigned  <= EXEcalcMULT;
                  end if;

                  if (EXEcalcMULT = '1') then
                     if    (value1(31 downto 11) = 0 or value1(31 downto 11) = 16#1FFFFF#) then hiloWait <= 7;
                     elsif (value1(31 downto 20) = 0 or value1(31 downto 20) = 16#FFF#)    then hiloWait <= 10;
                     else  hiloWait <= 14;
                     end if;
                  end if;

                  if (EXEcalcMULTU = '1') then
                     if    (value1(31 downto 11) = 0) then hiloWait <= 7;
                     elsif (value1(31 downto 20) = 0) then hiloWait <= 10;
                     else  hiloWait <= 14;
                     end if;
                  end if;

                  if (EXEcalcDIV = '1' or EXEcalcDIVU = '1') then
                     hiloWait   <= 37;
                     hiloIsDiv  <= '1';
                  end if;

                  if (EXEhiUpdate = '1') then hi <= value1; end if;
                  if (EXEloUpdate = '1') then lo <= value1; end if;

               end if;

            end if;

         end if;

      end if;
   end process;

   mulA <= signed((mul1(31) and mulSigned) & mul1);
   mulB <= signed((mul2(31) and mulSigned) & mul2);

   DIVstart    <= '1' when (reset = '0' and ce = '1' and stall = 0 and exception(4 downto 2) = 0 and (EXEcalcDIV = '1' or EXEcalcDIVU = '1')) else '0';


--##############################################################
--############################### stage 4
--##############################################################


   -- scratchpad ###############################################
   scratchpad_address_a <= std_logic_vector(executeAddr(9 downto 2));

   scratchpad_address_b <= std_logic_vector(executeAddr(9 downto 2));

   gscratchpad: for i in 0 to 3 generate
   begin
      iscratch: entity work.dpram
      generic map ( addr_width => 8, data_width => 8)
      port map
      (
         clock_a     => clk1x,
         clken_a     => ce,
         address_a   => scratchpad_address_a,
         data_a      => std_logic_vector(executeMemWriteData((8*i) + 7 downto (8*i))),
         wren_a      => scratchpad_wren_a(i),

         clock_b     => clk2x,
         address_b   => scratchpad_address_b,
         data_b      => x"00",
         wren_b      => '0',
         q_b         => scratchpad_q_b((8*i) + 7 downto (8*i))
      );
   end generate;

   scratchpad_dataread <= unsigned(scratchpad_q_b);

   -- stage 4 processes ########################################

   process (all)
      variable skipmem : std_logic;
   begin

      mem4_request   <= '0';
      stallNew4      <= stall4;

      WBCACHECONTROL <= CACHECONTROL;

      mem4_address   <= executeAddr(31 downto 2) & "00";
      mem4_rnw       <= '1';
      mem4_reqsize   <= "10";

      WBinvalidateCacheEna  <= '0';
      WBinvalidateCacheLine <= executeAddr(11 downto 4);

      scratchpad_wren_a    <= "0000";

      -- ############
      -- stall handling for data load pipeline
      -- ############
      if (mem4_pending = '1') then
         -- unstalling possible after read request has been sent, but only if next command is no read/write and data is not going to GTE
         if (lateReadReqDone = '1' and executeReadEnable = '0' and writebackGTEReadEnable = '0' and executeMemWriteEnable = '0') then
            stallNew4 <= '0';
         end if;

         -- stall when exception happens next
         if (exceptionNew /= 0) then
            stallNew4 <= '1';
         end if;

         -- stall when next action would be a read/write request
         if (EXEReadEnable = '1' or EXEMemWriteEnable = '1') then
            stallNew4 <= '1';
         end if;

         -- must stall for 1 cycle when data is received to have a spot in register write
         if (mem_done = '1' and memoryMuxStage4 = '1' and writebackGTEReadEnable = '0') then
            stallNew4   <= '1';
         end if;
      end if;

      -- ############
      -- Load/Store
      -- ############

      if (exception(4 downto 3) = 0 and stall = 0) then

         if (executeMemWriteEnable = '1') then
            skipmem := '0';

            case (to_integer(unsigned(executeAddr(31 downto 29)))) is

               when 0 | 4 => -- cached
                  if (cop0_SR(16) = '1') then -- cache isolation
                     skipmem               := '1';
                     WBinvalidateCacheEna  <= '1';
                  end if;

                  if (executeAddr(28 downto 10) = 16#7E000#) then -- scratchpad
                     skipmem := '1';
                     scratchpad_wren_a <= executeMemWriteMask;
                  end if;

               when 6 | 7 => -- KSEG2
                  skipmem := '1';
                  if (executeAddr(31 downto 2) = C_CCTL(31 downto 2)) then
                     WBCACHECONTROL <= executeMemWriteData;
                  end if;

               when others => null;

            end case;

            if (skipmem = '0') then
               mem4_request   <= '1';
               mem4_rnw       <= '0';
               stallNew4      <= mem_fifofull;
            end if;

         end if;

         if (executeReadEnable = '1') then

            case (executeLoadType) is
               when LOADTYPE_SBYTE => mem4_reqsize <= "00";
               when LOADTYPE_SWORD => mem4_reqsize <= "01";
               when LOADTYPE_LEFT  => mem4_reqsize <= "10";
               when LOADTYPE_DWORD => mem4_reqsize <= "10";
               when LOADTYPE_BYTE  => mem4_reqsize <= "00";
               when LOADTYPE_WORD  => mem4_reqsize <= "01";
               when LOADTYPE_RIGHT => mem4_reqsize <= "10";
            end case;

            if ((executeAddr(31 downto 29) = "000" or executeAddr(31 downto 29) = "100") and executeAddr(28 downto 10) = 16#7E000#) then
               -- scratchpad
            elsif (executeAddr = C_CCTL) then
               -- cachecontrol
            else
               mem4_request   <= '1';
               mem4_address   <= executeAddr;
               if (executeLoadType = LOADTYPE_LEFT or executeLoadType = LOADTYPE_RIGHT) then
                  mem4_address(1 downto 0) <= "00";
               end if;
               mem4_rnw       <= '1';
               stallNew4      <= '1';
            end if;

         end if;

      end if;

   end process;

   process (clk1x)
      variable dataReadData : unsigned(31 downto 0);
      variable oldData      : unsigned(31 downto 0);
   begin
      if (rising_edge(clk1x)) then

         if (ce = '1') then
            gte_writeEna  <= '0';
            gte_cmdEna    <= '0';
         end if;

         if (reset = '1') then

            stall4                           <= '0';

            CACHECONTROL                     <= (others => '0');

            writebackTarget                  <= (others => '0');
            writebackData                    <= (others => '0');
            writebackWriteEnable             <= '0';

            writebackInvalidateCacheEna      <= '0';

            writebackException               <= '0';

            writebackGTEReadEnable           <= '0';
            WBgte_writeAddr                  <= (others => '0');

            gte_writeEna                     <= '0';
            gte_cmdEna                       <= '0';

            lateReadWrite                    <= '0';
            lateReadBypass                   <= '0';
            lateReadReqDone                  <= '0';

         elsif (ce = '1') then

            stall4         <= stallNew4;
            dataReadData   := unsigned(mem_dataRead);
            oldData        := writebackData;

            writebackInvalidateCacheEna  <= WBinvalidateCacheEna;
            writebackInvalidateCacheLine <= WBinvalidateCacheLine;

            if (lateReadBypass = '1' and stall4 = '0') then
               lateReadRam <= '0';
            end if;

            lateReadReqDone <= '0';
            if (mem4_request = '1' and mem4_rnw = '1') then
               lateReadReqDone <= '1';

               -- need to compensate for timing in original design on back to back reads:
               -- this is due to unclear reason why the original design is slower here than it could be
               if (lateReadBypass = '1') then
                  -- one additional wait cycle if target of first read is to be used after second read
                  if ((decodeReqSource1 = '1' and decodeSource1 = lateReadTarget) or (decodeReqSource2 = '1' and decodeSource2 = lateReadTarget)) then
                     lateReadStall <= '1';
                  end if;
                  -- one additional wait cycle if target of both reads is the same and goes to ram
                  if (resultTarget = lateReadTarget and executeAddr(28 downto 0) < 16#800000# and lateReadRam = '1') then
                     lateReadStall <= '1';
                  end if;
               end if;
               if (executeAddr(28 downto 0) < 16#800000#) then
                  lateReadRam <= '1';
               end if;
            end if;

            if (resultWriteEnable = '1' and mem4_pending = '1' and resultTarget = lateReadTarget) then
               lateReadWriteAfterWrite <= '1';
            end if;


            if (stall = 0) then

               lateReadBypass <= '0';

               if (exception(4 downto 3) > 0) then

                  writebackException           <= '1';

               else

-- synthesis translate_off
                  PCold3                       <= PCold2;
                  opcode3                      <= opcode2;
-- synthesis translate_on
                  writebackTarget              <= resultTarget;
                  writebackData                <= resultData;

                  writebackException           <= executeException;

                  CACHECONTROL                 <= WBCACHECONTROL;

                  writebackGTEReadEnable       <= executeGTEReadEnable;
                  WBgte_writeAddr              <= '0' & executeGTETarget;

                  oldData := resultData;
                  if (lateReadTarget = resultTarget and lateReadBypass = '1') then
                     oldData := lateReadData;
                  elsif (writebackTarget = resultTarget and writebackWriteEnable = '1') then
                     oldData := writebackData;
                  end if;

                  writebackWriteEnable <= '0';
                  if (executeReadEnable = '1') then
                     if (((executeAddr(31 downto 29) = "000" or executeAddr(31 downto 29) = "100") and executeAddr(28 downto 10) = 16#7E000#)) then -- scratchpad read
                        if (executeGTEReadEnable = '1') then
                           gte_writeAddr <= '0' & executeGTETarget;
                           gte_writeData <= scratchpad_dataread;
                           gte_writeEna  <= '1';
                        else
                           writebackWriteEnable <= '1';

                           case (executeLoadType) is
                              when LOADTYPE_SBYTE =>
                                 case (executeAddr(1 downto 0)) is
                                    when "00" => writebackData <= unsigned(resize(signed(scratchpad_dataread( 7 downto  0)), 32));
                                    when "01" => writebackData <= unsigned(resize(signed(scratchpad_dataread(15 downto  8)), 32));
                                    when "10" => writebackData <= unsigned(resize(signed(scratchpad_dataread(23 downto 16)), 32));
                                    when "11" => writebackData <= unsigned(resize(signed(scratchpad_dataread(31 downto 24)), 32));
                                    when others => null;
                                 end case;

                              when LOADTYPE_SWORD =>
                                 if (executeAddr(1) = '0') then
                                    writebackData <= unsigned(resize(signed(scratchpad_dataread(15 downto 0)), 32));
                                 else
                                    writebackData <= unsigned(resize(signed(scratchpad_dataread(31 downto 16)), 32));
                                 end if;

                              when LOADTYPE_LEFT =>
                                 case (to_integer(executeAddr(1 downto 0))) is
                                    when 0 => writebackData <= scratchpad_dataread( 7 downto 0) & oldData(23 downto 0);
                                    when 1 => writebackData <= scratchpad_dataread(15 downto 0) & oldData(15 downto 0);
                                    when 2 => writebackData <= scratchpad_dataread(23 downto 0) & oldData( 7 downto 0);
                                    when 3 => writebackData <= scratchpad_dataread;
                                    when others => null;
                                 end case;

                              when LOADTYPE_DWORD => writebackData <= scratchpad_dataread;

                              when LOADTYPE_BYTE  =>
                                 case (executeAddr(1 downto 0)) is
                                    when "00" => writebackData <= x"000000" & scratchpad_dataread( 7 downto  0);
                                    when "01" => writebackData <= x"000000" & scratchpad_dataread(15 downto  8);
                                    when "10" => writebackData <= x"000000" & scratchpad_dataread(23 downto 16);
                                    when "11" => writebackData <= x"000000" & scratchpad_dataread(31 downto 24);
                                    when others => null;
                                 end case;

                              when LOADTYPE_WORD  =>
                                 if (executeAddr(1) = '0') then
                                    writebackData <= x"0000" & scratchpad_dataread(15 downto 0);
                                 else
                                    writebackData <= x"0000" & scratchpad_dataread(31 downto 16);
                                 end if;

                              when LOADTYPE_RIGHT =>
                                 case (to_integer(executeAddr(1 downto 0))) is
                                    when 0 => writebackData <= scratchpad_dataread;
                                    when 1 => writebackData <= oldData(31 downto 24) & scratchpad_dataread(31 downto  8);
                                    when 2 => writebackData <= oldData(31 downto 16) & scratchpad_dataread(31 downto 16);
                                    when 3 => writebackData <= oldData(31 downto  8) & scratchpad_dataread(31 downto 24);
                                    when others => null;
                                 end case;
                           end case;
                        end if;
                     elsif (executeAddr = C_CCTL) then
                        writebackWriteEnable <= '1';
                        writebackData        <= CACHECONTROL;
                     else
                        writebackLoadType       <= executeLoadType;
                        writebackAddrLow        <= executeAddr(1 downto 0);
                        lateReadTarget          <= resultTarget;
                        lateReadOldData         <= oldData;
                        lateReadWriteAfterWrite <= '0';
                     end if;
                  else
                     writebackWriteEnable <= resultWriteEnable;
                  end if;

                  if (execute_gte_writeEna = '1') then
                     gte_writeAddr <= execute_gte_addr;
                     gte_writeData <= executeMemWriteData;
                     gte_writeEna  <= '1';
                  end if;

                  if (execute_gte_cmdEna = '1') then
                     gte_cmdData <= unsigned'("0100101") & execute_gte_cmdData;
                     gte_cmdEna  <= '1';
                  end if;

               end if;

            else

               if (mem_fifofull = '0' and mem4_pending = '0') then
                  lateReadStall <= '0';
                  if (lateReadStall = '0') then
                     stall4 <= '0';
                  end if;
               end if;

               lateReadWrite <= '0';

               if (lateReadWrite = '1') then
                  lateReadBypass <= '1';
               end if;

            end if;

            if (mem_done = '1' and memoryMuxStage4 = '1') then
               if (writebackGTEReadEnable = '1') then
                  gte_writeAddr <= WBgte_writeAddr;
                  gte_writeData <= dataReadData;
                  gte_writeEna  <= '1';
               else
                  if (lateReadTarget > 0 and lateReadWriteAfterWrite = '0') then
                     if (resultWriteEnable = '0' or resultTarget /= lateReadTarget) then -- write after write in same cycle -> ignore
                        lateReadWrite <= '1';
                     else
                        lateReadRam   <= '0';
                     end if;
                  end if;

                  case (writebackLoadType) is

                     when LOADTYPE_SBYTE => lateReadData <= unsigned(resize(signed(dataReadData(7 downto 0)), 32));
                     when LOADTYPE_SWORD => lateReadData <= unsigned(resize(signed(dataReadData(15 downto 0)), 32));
                     when LOADTYPE_LEFT =>
                        case (to_integer(writebackAddrLow)) is
                           when 0 => lateReadData <= dataReadData( 7 downto 0) & lateReadOldData(23 downto 0);
                           when 1 => lateReadData <= dataReadData(15 downto 0) & lateReadOldData(15 downto 0);
                           when 2 => lateReadData <= dataReadData(23 downto 0) & lateReadOldData( 7 downto 0);
                           when 3 => lateReadData <= dataReadData;
                           when others => null;
                        end case;

                     when LOADTYPE_DWORD => lateReadData <= dataReadData;
                     when LOADTYPE_BYTE  => lateReadData <= x"000000" & dataReadData(7 downto 0);
                     when LOADTYPE_WORD  => lateReadData <= x"0000" & dataReadData(15 downto 0);
                     when LOADTYPE_RIGHT =>
                        case (to_integer(writebackAddrLow)) is
                           when 0 => lateReadData <= dataReadData;
                           when 1 => lateReadData <= lateReadOldData(31 downto 24) & dataReadData(31 downto  8);
                           when 2 => lateReadData <= lateReadOldData(31 downto 16) & dataReadData(31 downto 16);
                           when 3 => lateReadData <= lateReadOldData(31 downto  8) & dataReadData(31 downto 24);
                           when others => null;
                        end case;

                  end case;
               end if;
            end if;

         end if;

      end if;
   end process;

--##############################################################
--############################### stage 5
--##############################################################
   process (clk1x)
   begin
      if (rising_edge(clk1x)) then

-- synthesis translate_off
         cpu_done <= '0';
-- synthesis translate_on

         if (reset = '1') then

            writeDoneTarget      <= (others => '0');
            writeDoneData        <= (others => '0');
            writeDoneWriteEnable <= '0';

         elsif (ce = '1') then

            if (stall = 0) then

-- synthesis translate_off
               PCold4               <= PCold3;
               opcode4              <= opcode3;
-- synthesis translate_on

               writeDoneTarget      <= writebackTarget;
               writeDoneData        <= writebackData;
               writeDoneWriteEnable <= writebackWriteEnable;

-- synthesis translate_off
               if (writebackWriteEnable = '1' and writebackException = '0' and writebackTarget > 0) then
                  regs(to_integer(writebackTarget)) <= writebackData;
               end if;

               cpu_done          <= '1';
               cpu_export.pc     <= PCold4;
               cpu_export.opcode <= opcode4;
               cpu_export.cause  <= cop0_CAUSE;
               for i in 0 to 31 loop
                  cpu_export.regs(i) <= regs(i);
               end loop;
-- synthesis translate_on

            end if;

-- synthesis translate_off
            if (lateReadBypass = '1') then
               regs(to_integer(lateReadTarget)) <= lateReadData;
            end if;
-- synthesis translate_on

         end if;

-- synthesis translate_off
         if (reset = '1') then
            regs(to_integer(clrcnt)) <= (others => '0');
         end if;
-- synthesis translate_on

      end if;
   end process;

--##############################################################
--############################### exception handling
--##############################################################

   process (clk1x)
   begin
      if (rising_edge(clk1x)) then

         if (reset = '1') then

            exception            <= (others => '0');

            cop0_BADVADDR        <= (others => '0');

            exception_SR         <= (others => '0');
            exception_CAUSE      <= (others => '0');
            exception_EPC        <= (others => '0');
            exception_JMP        <= (others => '0');

         elsif (ce = '1') then

            if (stall = 0) then

               exception           <= exceptionNew;
               exceptionBreakpoint <= EXEBreakpoint;
               if (exceptionNew5 = '1') then -- interrupt
                  exceptionCode     <= x"0";
                  exceptionInstr    <= decodeCE;
                  exception_PC      <= PCold1 & "00";
                  exception_branch  <= executeBranchTaken;
                  exception_brslot  <= executeBranchdelaySlot;
               else                             -- execute stage
                  exceptionCode     <= exceptionCode_3;
                  exceptionInstr    <= decodeCE;
                  if (EXEBranchTaken = '1') then
                     exception_PC      <= PCbranch;
                     exception_branch  <= '0';
                     exception_brslot  <= '0';
                     if (exceptionNew3 = '1') then
                        cop0_BADVADDR     <= PCbranch;
                     end if;
                  else
                     exception_PC      <= PCold1 & "00";
                     exception_branch  <= executeBranchTaken;
                     exception_brslot  <= executeBranchdelaySlot;
                     if (EXEMemWriteException = '1' or EXEReadException = '1') then
                        cop0_BADVADDR  <= EXEMemAddr;
                     end if;
                  end if;
               end if;

               if (exception > 0) then
                  exception_SR    <= cop0_SR(31 downto 6) & cop0_SR(3 downto 0) & "00";
                  exception_CAUSE <= cop0_CAUSE;
                  exception_CAUSE(5 downto 2)   <= exceptionCode;
                  exception_CAUSE(29 downto 28) <= exceptionInstr;
                  exception_CAUSE(30) <= exception_branch;
                  exception_CAUSE(31) <= exception_brslot;
                  if (exception_brslot = '1') then
                     exception_EPC <= exception_PC - 4;
                     exception_JMP <= PCold1 & "00";    -- PCold1 now = PCold0 of the cycle the exception was detected
                  else
                     exception_EPC <= exception_PC;
                  end if;
               end if;

            end if;

         end if;
      end if;
   end process;

--##############################################################
--############################### submodules
--##############################################################

   idivider : entity work.divider_pocket
   port map
   (
      clk       => clk1x,
      start     => DIVstart,
      isSigned  => EXEcalcDIV,
      dividend  => value1,
      divisor   => value2,
      quotient  => DIVquotient,
      remainder => DIVremainder
   );

--##############################################################
--############################### status
--##############################################################

   process (clk1x)
   begin
      if (rising_edge(clk1x)) then

         SS_idle <= '0';
         if (hiloWait = 0 and blockIRQ = '0' and (irqRequest = '0' or cop0_SR(0) = '0') and mem_done = '0' and lateReadWrite = '0' and lateReadBypass = '0') then
            SS_idle <= '1';
         end if;

         error  <= '0';
         error2 <= '0';

         if (reset = '1') then

            debugStallcounter <= (others => '0');
            debug300exception <= '0';

         elsif (ce = '1') then

            if (stall = 0) then
               debugStallcounter <= (others => '0');
            elsif (cpuPaused = '0') then
               debugStallcounter <= debugStallcounter + 1;
            end if;

            debug300exception <= '0';
            if (mem_request = '1' and mem4_request = '1' and mem4_rnw = '1' and mem4_address = x"00000300") then
               debug300exception <= '1';
            end if;

            if (debug300exception = '1') then
               error        <= '1';
            end if;

            if (debugStallcounter(9) = '1') then
               error2       <= '1';
            end if;

         end if;

      end if;
   end process;

end architecture;
