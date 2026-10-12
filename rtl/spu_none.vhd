library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- SPU stand-in for builds without sound (G_SPU_IMPL = "none"). Port list equals entity spu.
-- Register window: every halfword echoes the last value written, except SPUSTAT (0x1AE), which
-- mirrors SPUCNT(5:0) so the BIOS's wait-for-mode loop terminates. Busy and IRQ bits read 0.
-- DMA4: spu_dmaRequest follows SPUCNT bit 5 as in spu.vhd; writes are dropped and reads return 0.
-- Documented in docs/pocket/POCKET_TOP.md, "Per-block implementation generics".

entity spu_none is
   port
   (
      clk1x                : in  std_logic;
      clk2x                : in  std_logic;
      clk2xIndex           : in  std_logic;
      ce                   : in  std_logic;
      reset                : in  std_logic;

      SPUon                : in  std_logic;
      SPUIRQTrigger        : in  std_logic;
      useSDRAM             : in  std_logic;
      REPRODUCIBLESPUIRQ   : in  std_logic;
      REPRODUCIBLESPUDMA   : in  std_logic;
      REVERBOFF            : in  std_logic;

      cpuPaused            : in  std_logic;

      spu_tick             : out std_logic := '0';
      cd_left              : in  signed(15 downto 0);
      cd_right             : in  signed(15 downto 0);

      irqOut               : out std_logic := '0';

      sound_timeout        : out std_logic := '0';

      sound_out_left       : out std_logic_vector(15 downto 0) := (others => '0');
      sound_out_right      : out std_logic_vector(15 downto 0) := (others => '0');

      bus_addr             : in  unsigned(9 downto 0);
      bus_dataWrite        : in  std_logic_vector(15 downto 0);
      bus_read             : in  std_logic;
      bus_write            : in  std_logic;
      bus_dataRead         : out std_logic_vector(15 downto 0);

      spu_dmaRequest       : out std_logic;
      dma_read             : in  std_logic;
      dma_readdata         : out std_logic_vector(15 downto 0);
      dma_write            : in  std_logic;
      dma_writedata        : in  std_logic_vector(15 downto 0);

      sdram_dataWrite      : out std_logic_vector(31 downto 0);
      sdram_Adr            : out std_logic_vector(18 downto 0);
      sdram_be             : out std_logic_vector(3 downto 0);
      sdram_rnw            : out std_logic;
      sdram_ena            : out std_logic;
      sdram_dataRead       : in  std_logic_vector(31 downto 0);
      sdram_done           : in  std_logic;

      mem_request          : out std_logic := '0';
      mem_BURSTCNT         : out std_logic_vector(7 downto 0) := (others => '0');
      mem_ADDR             : out std_logic_vector(19 downto 0) := (others => '0');
      mem_DIN              : out std_logic_vector(63 downto 0) := (others => '0');
      mem_BE               : out std_logic_vector(7 downto 0) := (others => '0');
      mem_WE               : out std_logic := '0';
      mem_RD               : out std_logic := '0';
      mem_ack              : in  std_logic;
      mem_DOUT             : in  std_logic_vector(63 downto 0);
      mem_DOUT_READY       : in  std_logic;

      SS_reset             : in  std_logic;
      loading_savestate    : in  std_logic;
      SS_DataWrite         : in  std_logic_vector(31 downto 0);
      SS_Adr               : in  unsigned(8 downto 0);
      SS_wren              : in  std_logic;
      SS_rden              : in  std_logic;
      SS_DataRead          : out std_logic_vector(31 downto 0);
      SS_idle              : out std_logic;

      SS_RAM_dataWrite     : in  std_logic_vector(15 downto 0);
      SS_RAM_Adr           : in  std_logic_vector(18 downto 0);
      SS_RAM_request       : in  std_logic;
      SS_RAM_rnw           : in  std_logic;
      SS_RAM_dataRead      : out std_logic_vector(15 downto 0);
      SS_RAM_done          : out std_logic
   );
end entity;

architecture arch of spu_none is

   constant IDX_SPUCNT  : integer := 16#1AA# / 2;
   constant IDX_SPUSTAT : integer := 16#1AE# / 2;

   type tregs is array(0 to 511) of std_logic_vector(15 downto 0);
   signal regs        : tregs := (others => (others => '0'));
   attribute ramstyle : string;
   attribute ramstyle of regs : signal is "M10K";
   signal reg_q       : std_logic_vector(15 downto 0) := (others => '0');
   signal reg_isstat  : std_logic := '0';

   signal cnt         : std_logic_vector(5 downto 0) := (others => '0');
   signal sampleticks : unsigned(9 downto 0) := (others => '0');

begin

   process (clk1x)
      variable idx : integer range 0 to 511;
   begin
      if rising_edge(clk1x) then

         idx := to_integer(bus_addr(9 downto 1));

         if (bus_write = '1') then
            regs(idx) <= bus_dataWrite;
         end if;
         if (bus_read = '1') then
            reg_q <= regs(idx);
            if (idx = IDX_SPUSTAT) then reg_isstat <= '1'; else reg_isstat <= '0'; end if;
         end if;

         -- cnt lives outside the RAM so it is available for SPUSTAT and the DMA request
         if (reset = '1') then
            cnt <= (others => '0');
         elsif (bus_write = '1' and idx = IDX_SPUCNT) then
            cnt <= bus_dataWrite(5 downto 0);
         end if;

         -- same 768-clock period as spu.vhd; the CD uses it as its sample clock
         spu_tick <= '0';
         if (ce = '1') then
            if (sampleticks < 767) then
               sampleticks <= sampleticks + 1;
            else
               sampleticks <= (others => '0');
               spu_tick    <= '1';
            end if;
         end if;

      end if;
   end process;

   bus_dataRead <= x"00" & "00" & cnt when (reg_isstat = '1') else reg_q;

   spu_dmaRequest <= cnt(5);
   dma_readdata   <= (others => '0');

   irqOut          <= '0';
   sound_timeout   <= '0';
   sound_out_left  <= (others => '0');
   sound_out_right <= (others => '0');

   sdram_dataWrite <= (others => '0');
   sdram_Adr       <= (others => '0');
   sdram_be        <= (others => '0');
   sdram_rnw       <= '1';
   sdram_ena       <= '0';

   mem_request  <= '0';
   mem_BURSTCNT <= (others => '0');
   mem_ADDR     <= (others => '0');
   mem_DIN      <= (others => '0');
   mem_BE       <= (others => '0');
   mem_WE       <= '0';
   mem_RD       <= '0';

   SS_DataRead     <= (others => '0');
   SS_idle         <= '1';
   SS_RAM_dataRead <= (others => '0');
   SS_RAM_done     <= '0';

end architecture;
