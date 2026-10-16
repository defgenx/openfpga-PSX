-- SPU of the Pocket build: the ports and, with the ties listed in docs/pocket/SPU.md, the outputs of spu.vhd on every clk1x
-- clock. Registers, voice state and the reverb coefficients live in RAM, the reverb arithmetic is removed (NO_REVERB) and a
-- voice read cache sits in front of the SPU RAM port (L1_CACHE). Harness: sim/spu_diff.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library mem;

entity spu_pocket is
   generic
   (
      NO_REVERB : boolean := true;
      L1_CACHE  : boolean := true
   );
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
      
      -- SDRAM interface        
      sdram_dataWrite      : out std_logic_vector(31 downto 0);
      sdram_Adr            : out std_logic_vector(18 downto 0);
      sdram_be             : out std_logic_vector(3 downto 0);
      sdram_rnw            : out std_logic;
      sdram_ena            : out std_logic;
      sdram_dataRead       : in  std_logic_vector(31 downto 0);
      sdram_done           : in  std_logic;
      
      -- DDR3 interface
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
      
      -- savestates
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

architecture arch of spu_pocket is

   function clamp16(value_in: signed) return signed is
      variable result: signed(15 downto 0);
   begin
 
      if (value_in < -32768) then result := x"8000";
      elsif (value_in > 32767) then result := x"7FFF";
      else result := value_in(15 downto 0);
      end if;
      
      return result;  
   end;
   
   function adsr_step_f(rate : unsigned(6 downto 0); dec : std_logic) return signed is
      variable shift : integer range 0 to 11 := 0;
      variable base  : signed(15 downto 0);
   begin
      if (rate(6 downto 2) <= 11) then
         shift := 11 - to_integer(rate(6 downto 2));
      end if;
      if (dec = '1') then
         base := to_signed(-8, 16) + to_integer(rate(1 downto 0));
      else
         base := to_signed( 7, 16) - to_integer(rate(1 downto 0));
      end if;
      if (rate < 48) then
         return shift_left(base, shift);
      else
         return base;
      end if;
   end function;

   -- the output and CD stages use the shared pipelined multiplier of the golden; true: products formed directly (not exact when a reset
   -- interrupts a stage, see docs/pocket/SPU.md)
   constant DIRECT_MUL : boolean := false;

   -- bus registers held in RAM (global_regs): word = (bus_addr - 0x180) / 2
   function in_gram(idx : unsigned(5 downto 0)) return boolean is
      variable i : natural := to_integer(idx);
   begin
      if (i = 19 or i = 22 or i = 26 or i = 27) then return true; end if;   -- TRANSFERADDR, TRANSFER_CNT, EXT_VOL_L/R
      if (i >= 8 and i <= 11) then return true; end if;                     -- PITCHMODENA, NOISEMODE
      if (i = 0 or i = 1 or i = 17 or i = 18 or i = 21 or i = 24 or i = 25) then return true; end if;   -- bus copies of registers the engine reads from flip-flops
      if (NO_REVERB and (i = 2 or i = 3 or i = 12 or i = 13 or i >= 32)) then return true; end if;   -- reverb registers, REVERBON
      return false;
   end function;

   signal GRAM_mapped         : std_logic;
   signal bus_reg             : std_logic_vector(15 downto 0);
   signal brd_sel             : std_logic_vector(1 downto 0) := "00";
   signal bus_rd_en           : std_logic;
   signal VBQ, VOLBQ, GBQ     : std_logic_vector(15 downto 0);
   signal GRAM_write          : std_logic;
   signal GRAM_addrA          : unsigned(5 downto 0);
   signal GRAM_dataA          : std_logic_vector(15 downto 0);
   type tgram_addrB is array(0 to 2) of unsigned(5 downto 0);
   type tgram_dataB is array(0 to 2) of std_logic_vector(15 downto 0);
   signal GRAM_addrB          : tgram_addrB;
   signal GRAM_dataB          : tgram_dataB;
   signal gram_hi             : unsigned(5 downto 0);
   signal pmon_bit            : std_logic;
   signal non_bit             : std_logic;

   -- voiceregs
   signal RamVoice_addrA      : unsigned(7 downto 0) := (others => '0');
   signal RamVoice_dataA      : std_logic_vector(15 downto 0) := (others => '0');
   signal RamVoice_write      : std_logic := '0';     
   
   type tvoiceregs_addrB is array(0 to 1) of unsigned(7 downto 0);
   signal RamVoice_addrB      : tvoiceregs_addrB;
   signal vw_eng7, vw_eng6, vw_bus, vw_zero, vw_we : std_logic;
   signal voice_pre           : std_logic;
   signal vq_re               : std_logic_vector(0 to 7);
   signal vvq_re              : std_logic_vector(0 to 1);
   signal vw_addr             : unsigned(7 downto 0);
   signal vw_data             : std_logic_vector(15 downto 0);
   type tvq is array(0 to 7) of std_logic_vector(15 downto 0);
   signal VQ                  : tvq;
   function to_stdl(b : boolean) return std_logic is
   begin
      if b then return '1'; else return '0'; end if;
   end function;
   
   type tvoiceregs_dataB is array(0 to 1) of std_logic_vector(15 downto 0);
   signal RamVoice_dataB     : tvoiceregs_dataB; 
  
   -- adpcm ram
   type tadpcm_addr is array(0 to 3) of unsigned(7 downto 0);
   type tadpcm_data is array(0 to 3) of std_logic_vector(15 downto 0);
   
   signal adpcm_ram_address_a : unsigned(7 downto 0);
   signal adpcm_ram_data_a    : tadpcm_data;
   signal adpcm_ram_wren_a    : std_logic_vector(3 downto 0);
   signal adpcm_res           : signed(15 downto 0);
   signal adpcm_wr_dec        : std_logic;
   signal adpcm_wr_copy       : std_logic;
   signal adpcm_wr_key        : std_logic;
   signal adpcm_ram_address_b : tadpcm_addr := (others => (others => '0')); 
   signal adpcm_ram_q_b       : tadpcm_data; 

   -- voice volume
   signal RamVoiceVolumes_addrA      : unsigned(5 downto 0) := (others => '0');
   signal RamVoiceVolumes_dataA      : std_logic_vector(15 downto 0) := (others => '0');
   signal RamVoiceVolumes_write      : std_logic := '0';     
   
   type tvoiceVolumes_addrB is array(0 to 1) of unsigned(5 downto 0);
   signal RamVoiceVolumes_addrB      : tvoiceVolumes_addrB;
   signal vvw_env, vvw_we            : std_logic;
   signal vvw_addr                   : unsigned(5 downto 0);
   signal vvw_data                   : std_logic_vector(15 downto 0);
   type tvvq is array(0 to 1) of std_logic_vector(15 downto 0);
   signal VVQ                        : tvvq;
   
   type tvoiceVolumes_dataB is array(0 to 1) of std_logic_vector(15 downto 0);
   signal RamVoiceVolumes_dataB      : tvoiceVolumes_dataB; 
   
   -- envelope counter ram
   signal EnvCounterRam_addrA : unsigned(5 downto 0);
   signal EnvCounterRam_addrB : unsigned(5 downto 0) := (others => '0');
   signal EnvCounterRam_dataA : std_logic_vector(21 downto 0);
   signal EnvCounterRam_dataB : std_logic_vector(21 downto 0) := (others => '0');
   signal EnvCounterRam_write : std_logic;
   
   -- Regs                          
	signal VOLUME_LEFT         : std_logic_vector(15 downto 0);  -- 0x1F801D80
	signal VOLUME_RIGHT        : std_logic_vector(15 downto 0);  -- 0x1F801D82
                              
	signal KEYON               : std_logic_vector(31 downto 0);  -- 0x1F801D88
	signal KEYOFF              : std_logic_vector(31 downto 0);  -- 0x1F801D8C
	signal REVERBON            : std_logic_vector(31 downto 0);  -- 0x1F801D98
	signal ENDX                : std_logic_vector(31 downto 0);  -- 0x1F801D9C
                              
	signal IRQ_ADDR            : std_logic_vector(15 downto 0);  -- 0x1F801DA4
   
                              
	signal CNT                 : std_logic_vector(15 downto 0);  -- 0x1F801DAA
	signal STAT                : std_logic_vector(15 downto 0);  -- 0x1F801DAE
                              
	signal CDAUDIO_VOL_L       : std_logic_vector(15 downto 0);  -- 0x1F801DB0	
	signal CDAUDIO_VOL_R       : std_logic_vector(15 downto 0);  -- 0x1F801DB2	
	signal CURVOL_L            : std_logic_vector(15 downto 0);  -- 0x1F801DB8	
	signal CURVOL_R            : std_logic_vector(15 downto 0);  -- 0x1F801DBA	
   
	signal REVERB_vLOUT        : std_logic_vector(15 downto 0);  -- 0x1F801D84
	signal REVERB_vROUT        : std_logic_vector(15 downto 0);  -- 0x1F801D86
	signal REVERB_mBASE        : std_logic_vector(15 downto 0);  -- 0x1F801DA2
	signal REVERB_dAPF1        : std_logic_vector(15 downto 0);  -- 0x1F801DC0
	signal REVERB_dAPF2        : std_logic_vector(15 downto 0);  -- 0x1F801DC2
	signal REVERB_vIIR         : std_logic_vector(15 downto 0);  -- 0x1F801DC4
	signal REVERB_vCOMB1       : std_logic_vector(15 downto 0);  -- 0x1F801DC6
	signal REVERB_vCOMB2       : std_logic_vector(15 downto 0);  -- 0x1F801DC8
	signal REVERB_vCOMB3       : std_logic_vector(15 downto 0);  -- 0x1F801DCA
	signal REVERB_vCOMB4       : std_logic_vector(15 downto 0);  -- 0x1F801DCC
	signal REVERB_vWALL        : std_logic_vector(15 downto 0);  -- 0x1F801DCE
	signal REVERB_vAPF1        : std_logic_vector(15 downto 0);  -- 0x1F801DD0
	signal REVERB_vAPF2        : std_logic_vector(15 downto 0);  -- 0x1F801DD2
	signal REVERB_mLSAME       : std_logic_vector(15 downto 0);  -- 0x1F801DD4
	signal REVERB_mRSAME       : std_logic_vector(15 downto 0);  -- 0x1F801DD6
	signal REVERB_mLCOMB1      : std_logic_vector(15 downto 0);  -- 0x1F801DD8
	signal REVERB_mRCOMB1      : std_logic_vector(15 downto 0);  -- 0x1F801DDA
	signal REVERB_mLCOMB2      : std_logic_vector(15 downto 0);  -- 0x1F801DDC
	signal REVERB_mRCOMB2      : std_logic_vector(15 downto 0);  -- 0x1F801DDE
	signal REVERB_dLSAME       : std_logic_vector(15 downto 0);  -- 0x1F801DE0
	signal REVERB_dRSAME       : std_logic_vector(15 downto 0);  -- 0x1F801DE2
	signal REVERB_mLDIFF       : std_logic_vector(15 downto 0);  -- 0x1F801DE4
	signal REVERB_mRDIFF       : std_logic_vector(15 downto 0);  -- 0x1F801DE6
	signal REVERB_mLCOMB3      : std_logic_vector(15 downto 0);  -- 0x1F801DE8
	signal REVERB_mRCOMB3      : std_logic_vector(15 downto 0);  -- 0x1F801DEA
	signal REVERB_mLCOMB4      : std_logic_vector(15 downto 0);  -- 0x1F801DEC
	signal REVERB_mRCOMB4      : std_logic_vector(15 downto 0);  -- 0x1F801DEE
	signal REVERB_dLDIFF       : std_logic_vector(15 downto 0);  -- 0x1F801DF0
	signal REVERB_dRDIFF       : std_logic_vector(15 downto 0);  -- 0x1F801DF2
	signal REVERB_mLAPF1       : std_logic_vector(15 downto 0);  -- 0x1F801DF4
	signal REVERB_mRAPF1       : std_logic_vector(15 downto 0);  -- 0x1F801DF6
	signal REVERB_mLAPF2       : std_logic_vector(15 downto 0);  -- 0x1F801DF8
	signal REVERB_mRAPF2       : std_logic_vector(15 downto 0);  -- 0x1F801DFA
	signal REVERB_vLIN         : std_logic_vector(15 downto 0);  -- 0x1F801DFC
	signal REVERB_vRIN         : std_logic_vector(15 downto 0);  -- 0x1F801DFE
   
   -- fifoIn
   signal FifoIn_reset        : std_logic := '0';
   signal FifoIn_Din          : std_logic_vector(15 downto 0) := (others => '0');
   signal FifoIn_Wr           : std_logic := '0'; 
   signal FifoIn_Full         : std_logic; 
   signal FifoIn_Dout         : std_logic_vector(15 downto 0);
   signal FifoIn_Rd           : std_logic := '0';
   signal FifoIn_Empty        : std_logic;
   
   -- fifoOut
   signal FifoOut_reset       : std_logic := '0';
   signal FifoOut_Din         : std_logic_vector(15 downto 0) := (others => '0');
   signal FifoOut_Wr          : std_logic := '0'; 
   signal FifoOut_NearFull    : std_logic; 
   signal FifoOut_Dout        : std_logic_vector(15 downto 0);
   signal FifoOut_Rd          : std_logic := '0';
   signal FifoOut_Empty       : std_logic;
   
   
   -- Data transfer
   signal ramTransferAddr     : unsigned(18 downto 0);
   
   -- interrupt
   signal IRQ9                : std_logic := '0';
   signal irqSaved            : std_logic := '0';
   signal irqVoicetrigger     : std_logic := '0';
   
   -- processing
   signal busy                : std_logic := '0';
   signal capturePosition     : unsigned(9 downto 0) := (others => '0');
   signal sampleticks         : unsigned(9 downto 0) := (others => '0');
   signal stashedSamples      : integer range 0 to 15 := 0;
   
   -- ram
   signal ram_dataWrite       : std_logic_vector(15 downto 0) := (others => '0');
   signal ram_Adr             : std_logic_vector(18 downto 0) := (others => '0');
   signal ram_request         : std_logic := '0';
   signal ram_check_irq       : std_logic := '0';
   signal ram_rnw             : std_logic := '0';
   signal ram_dataRead        : std_logic_vector(15 downto 0);
   signal ram_done            : std_logic;
   
   signal ram_isVoice         : std_logic := '0';
   
   -- statemachine
   type tState is
   (
      IDLE,
      
      VOICE_START,
      VOICE_READHEADER,
      VOICE_EVALHEADER,
      VOICE_EVALSAMPLE,
      VOICE_DECODESAMPLE,
      VOICE_PICKSAMPLE,
      VOICE_APPLYADSR,
      VOICE_APPLYVOLUME,
      VOICE_CHECKEND,
      VOICE_CHECKKEY,
      VOICE_END,
      
      RAM_READ,
      RAM_WRITE,
      RAM_WAIT,
      
      REVERB_READ1,
      REVERB_PROCOUT,
      REVERB_WRITE1,
      REVERB_READ2,
      REVERB_PROCIN,
      REVERB_WRITE2,
      REVERB_END,
      
      CAPTURE0,
      CAPTURE1,
      CAPTURE2,
      CAPTURE3
   );
   signal state : tState := IDLE;
   
   signal index        : integer range 0 to 23;
   signal voiceCounter : integer range 0 to 31;
   
   constant ADSRPHASE_OFF     : unsigned(2 downto 0) := "000";
   constant ADSRPHASE_ATTACK  : unsigned(2 downto 0) := "001";
   constant ADSRPHASE_DECAY   : unsigned(2 downto 0) := "010";
   constant ADSRPHASE_SUSTAIN : unsigned(2 downto 0) := "011";
   constant ADSRPHASE_RELEASE : unsigned(2 downto 0) := "100";
   constant ADSR_OFF         : integer := 0;
   constant ADSR_ATTACK      : integer := 1;
   constant ADSR_DECAY       : integer := 2;
   constant ADSR_SUSTAIN     : integer := 3;
   constant ADSR_RELEASE     : integer := 4;
   type voiceRecord is record
      currentAddr      : unsigned(15 downto 0);
      adpcmLast0       : signed(15 downto 0);
      adpcmLast1       : signed(15 downto 0);
      adpcmSamplePos   : unsigned(19 downto 0);
      adpcmDecodePtr   : unsigned(5 downto 0);
      adsrphase        : unsigned(2 downto 0);
      adsrTicks        : unsigned(20 downto 0);
      firstBlock       : std_logic;
      ignoreLoopWB     : std_logic;
   end record;
   
   signal voice        : voiceRecord := ((others => '0'), (others => '0'), (others => '0'), (others => '0'), (others => '0'), (others => '0'), (others => '0'), '0', '0');
   
   signal voice_lastVolume  : signed(15 downto 0);   -- clamp of volume
   signal voice_lastVolume1 : signed(15 downto 0);
   signal voice_lastVolume3 : signed(15 downto 0);
   
   signal voice_adsrWrite   : std_logic_vector(23 downto 0) := (others => '0');
   signal voice_repeatWrite : std_logic_vector(23 downto 0) := (others => '0');
   
   -- voicerecordram
   signal RamVoiceRecord_addrA : unsigned(4 downto 0);
   signal RamVoiceRecord_dataA : std_logic_vector(99 downto 0);
   signal RamVoiceRecord_write : std_logic;
   signal voice_store          : std_logic;
   
   type tvoicerecords_addrB is array(0 to 0) of unsigned(4 downto 0);
   signal RamVoiceRecord_addrB : tvoicerecords_addrB;
   
   type tvoicerecords_dataB is array(0 to 0) of std_logic_vector(99 downto 0);
   signal RamVoiceRecord_dataB : tvoicerecords_dataB; 
   
   --type tvoicearray is array(0 to 23) of voiceRecord;
   --signal voiceArray : tvoicearray := (others => ((others => '0'), (others => '0'), (others => '0'), (others => '0'), (others => '0'), (others => '0'), (others => '0'), (others => '0')));
   
   -- voice intermediate
   signal adpcmShift     : unsigned(3 downto 0);
   signal adpcmFilter    : unsigned(2 downto 0);
   signal loopEnd        : std_logic;
   signal loopRepeat     : std_logic;
   signal updateRepeat   : std_logic;
   signal adpcmData      : std_logic_vector(15 downto 0);
   signal decodeCnt      : integer range 0 to 3;
   
   signal gauss1         : signed(15 downto 0);
   signal gauss2         : signed(15 downto 0);
   signal gauss3         : signed(15 downto 0);
   signal gauss4         : signed(15 downto 0);
   
   type tfilterArray is array(0 to 4) of integer range -128 to 127;
   constant filtertablePos : tfilterArray := ( 0, 60, 115, 98, 122 );
	constant filtertableNeg : tfilterArray := ( 0, 0, -52, -55, -60 );
   
   type tadpcmSamples is array(0 to 3) of signed(15 downto 0);
   --type tadpcmSamples is array(0 to 23, 0 to 30) of signed(15 downto 0);
  -- signal adpcmSamples : tadpcmSamples := (others => (others => (others => '0')));
   signal adpcmSamples : tadpcmSamples := (others => (others => '0'));
   
   signal sample         : signed(15 downto 0);
   signal step           : unsigned(15 downto 0);
   signal volumeSetting  : unsigned(15 downto 0);
   signal volumeSettingR : unsigned(15 downto 0);   
   signal adsrSetting    : unsigned(31 downto 0);
   signal adsrVolume     : signed(15 downto 0);
   signal adsrVolumeNew  : signed(15 downto 0);
   
   signal volume         : signed(16 downto 0);  
   signal volLeft        : signed(15 downto 0);  
   signal volRight       : signed(15 downto 0);  
   signal chanLeft       : signed(17 downto 0);  
   signal chanRight      : signed(17 downto 0);  
   
   signal soundleft      : signed(23 downto 0) := (others => '0');  
   signal soundright     : signed(23 downto 0) := (others => '0');     
    
   -- envelope
   type tenvelopeState is
   (
      ENV_IDLE,
      ENV_START,
      ENV_CALC,
      ENV_WRITE
   );
   signal envelopeState      : tenvelopeState := ENV_IDLE;
   signal envelopeVoice      : std_logic := '0'; 
   signal envelopeRight      : std_logic := '0'; 
   signal envelope_startnext : std_logic := '0'; 
   signal envelopeIndex      : integer range 0 to 49;
   signal envVolume          : signed(15 downto 0);
   signal envTicks           : unsigned(20 downto 0);
   signal envTicksNew        : std_logic := '0'; 
   signal env_step           : signed(15 downto 0);   -- step of the sweep set by volumeSetting
   
   -- adsr
   -- parameters of the one phase selected by adsr_ph
   signal adsr_ph       : unsigned(2 downto 0);
   signal adsr_r        : unsigned(6 downto 0);
   signal adsr_d        : std_logic;
   signal adsr_e        : std_logic;
   signal adsr_tk       : unsigned(20 downto 0);
   signal adsr_st       : signed(15 downto 0);
   signal adsr_dec_cur  : std_logic;
   signal adsr_target   : unsigned(14 downto 0);
   
   signal reset_adsr    : std_logic := '0';
   
   -- reverb
   signal reverbRight            : std_logic := '0';
   signal reverbCurrentAddress   : unsigned(17 downto 0);
   
   signal reverbsumleft          : signed(23 downto 0) := (others => '0');  
   signal reverbsumright         : signed(23 downto 0) := (others => '0');  
   signal reverb_sample          : signed(23 downto 0);
   
   signal reverb_reqAddr         : unsigned(15 downto 0);
   signal reverb_reqAddr2        : unsigned(17 downto 0);
   signal reverbAddAddr          : unsigned(18 downto 0);
   signal reverb_calcAddr        : unsigned(18 downto 0);
   
   signal reverb_count           : integer range 0 to 13;
   
   signal REVERB_mSAME           : unsigned(15 downto 0);
	signal REVERB_mCOMB1          : unsigned(15 downto 0);
	signal REVERB_mCOMB2          : unsigned(15 downto 0);
	signal REVERB_dSAME           : unsigned(15 downto 0);
	signal REVERB_mDIFF           : unsigned(15 downto 0);
	signal REVERB_mCOMB3          : unsigned(15 downto 0);
	signal REVERB_mCOMB4          : unsigned(15 downto 0);
	signal REVERB_dDIFF           : unsigned(15 downto 0);
	signal REVERB_mAPF1           : unsigned(15 downto 0);
	signal REVERB_mAPF2           : unsigned(15 downto 0);
	signal REVERB_vIN             : signed(15 downto 0);
   
   signal reverbReadval1         : signed(15 downto 0);
   signal reverbReadval2         : signed(15 downto 0);
   signal reverbReadval3         : signed(15 downto 0);
   signal reverbReadval4         : signed(15 downto 0);
   signal reverbReadval5         : signed(15 downto 0);
   signal reverbReadval6         : signed(15 downto 0);
   
   signal IIR_INPUT_B            : signed(15 downto 0);
   signal IIR_A                  : signed(15 downto 0);
   signal IIR_B                  : signed(15 downto 0);
   
   signal reverb_acc             : signed(19 downto 0);
   signal apf1neg                : signed(15 downto 0);
   signal apf2neg                : signed(15 downto 0);
   signal MDA                    : signed(15 downto 0);
   signal MDB                    : signed(15 downto 0);
   
   signal reverbLastLeft         : signed(15 downto 0);
   signal reverbLastRight        : signed(15 downto 0);

   signal reverbL_d1             : signed(15 downto 0) := (others => '0');
   signal reverbL_d2             : signed(15 downto 0) := (others => '0');
   signal reverbL_d3             : signed(15 downto 0) := (others => '0');
   signal reverbL_d4             : signed(15 downto 0) := (others => '0');
   signal reverbR_d1             : signed(15 downto 0) := (others => '0');
   signal reverbR_d2             : signed(15 downto 0) := (others => '0');
   signal reverbR_d3             : signed(15 downto 0) := (others => '0');
   signal reverbR_d4             : signed(15 downto 0) := (others => '0');
   signal reverbDownLeft         : signed(15 downto 0) := (others => '0');
   signal reverbDownRight        : signed(15 downto 0) := (others => '0');

   signal reverbPartA_L          : signed(24 downto 0) := (others => '0');
   signal reverbPartB_L          : signed(24 downto 0) := (others => '0');
   signal reverbPartA_R          : signed(24 downto 0) := (others => '0');
   signal reverbPartB_R          : signed(24 downto 0) := (others => '0');
   
   -- noise
   signal noiseLevel             : unsigned(15 downto 0);
   signal noiseCnt               : unsigned(31 downto 0);
   signal noiseCheck             : unsigned(31 downto 0);

   -- cd processing
   signal cdProcStep             : integer range 0 to 4 := 4;
   signal cd_next_left           : signed(16 downto 0);
   signal cd_next_right          : signed(16 downto 0);

   -- end processing
   signal endProcStep            : integer range 0 to 4 := 4;
   
   signal soundmulresult14       : signed(25 downto 0);
   signal soundmulresult14_1     : signed(25 downto 0);
   signal soundmulresult15       : signed(24 downto 0);
   signal soundmul1              : signed(23 downto 0);
   signal soundmul2              : signed(15 downto 0);

   signal writeDMAReady          : std_logic;

      
   signal ss_voice_loading    : std_logic := '0';
   
   signal ss_timeout          : unsigned(13 downto 0) := (others => '0');   -- samples; bit 13 = timeout
      
  
begin 

   ififoIn: entity work.spu_pocket_fifo
   generic map (SIZEBITS => 7, DATAWIDTH => 16, NEARFULL_AT => 32)
   port map
   (
      clk      => clk1x,
      reset    => FifoIn_reset,
      Din      => FifoIn_Din,
      Wr       => FifoIn_Wr,
      Full     => FifoIn_Full,
      NearFull => open,
      Dout     => FifoIn_Dout,
      Rd       => FifoIn_Rd,
      Empty    => FifoIn_Empty
   );
   
   ififoOut: entity work.spu_pocket_fifo
   generic map (SIZEBITS => 6, DATAWIDTH => 16, NEARFULL_AT => 32)
   port map
   (
      clk      => clk1x,
      reset    => FifoOut_reset,
      Din      => FifoOut_Din,
      Wr       => FifoOut_Wr,
      Full     => open,
      NearFull => FifoOut_NearFull,
      Dout     => FifoOut_Dout,
      Rd       => FifoOut_Rd,
      Empty    => FifoOut_Empty
   );
   
   FifoOut_Rd   <= dma_read     when (FifoOut_Empty = '0') else '0';
   dma_readdata <= FifoOut_Dout when (FifoOut_Empty = '0') else (others => '0');
   
   writeDMAReady <= FifoIn_Empty;
   
   STAT(15) <= '0'; -- unused
   STAT(14) <= '0'; -- unused
   STAT(13) <= '0'; -- unused
   STAT(12) <= '0'; -- unused
   STAT(11) <= capturePosition(9); -- Writing to First/Second half of Capture Buffers (0=First, 1=Second)
   STAT(10) <= busy; -- Data Transfer Busy Flag
   STAT( 9) <= '1' when (CNT(5 downto 4) = "10" and writeDMAReady    = '1') else '0'; -- Data Transfer DMA Write Request   -- todo no$ has 9 as read, duckstation 9 as write?
   STAT( 8) <= '1' when (CNT(5 downto 4) = "11" and FifoOut_NearFull = '1') else '0'; -- Data Transfer DMA Read Request    -- todo no$ has 8 as write, duckstation 8 as read?
   STAT( 7) <= STAT(8) or STAT(9); -- Data Transfer DMA Read/Write Request ;seems to be same as SPUCNT.Bit5
   STAT( 6) <= IRQ9;
   STAT(5 downto 0) <= CNT(5 downto 0);

   spu_dmaRequest <= STAT(7);
   
   
   ispu_gauss : entity work.spu_pocket_gauss
   port map
   (
      clk1x          => clk1x,
      interpolIndex  => voice.adpcmSamplePos(11 downto 4),
      shift          => voice.adpcmSamplePos(13 downto 12),
      g0             => gauss1,
      g1             => gauss2,
      g2             => gauss3,
      g3             => gauss4
   );
   
-- global registers in RAM: igramB serves the bus, copies 1 and 2 the reverb address and the voice flag lookups
   gGRAM : for i in 1 to 2 generate
   begin
      itagramGRAM : entity mem.RamMLAB
      GENERIC MAP
      (
         width         => 16,
         widthad       => 6,
         width_byteena => 1
      )
      PORT MAP (
         inclock    => clk1x,
         wren       => GRAM_write,
         data       => GRAM_dataA,
         wraddress  => std_logic_vector(GRAM_addrA),
         rdaddress  => std_logic_vector(GRAM_addrB(i)),
         q          => GRAM_dataB(i)
      );
   end generate;

   GRAM_mapped <= '1' when (bus_addr(9 downto 7) = "011" and bus_addr(0) = '0' and in_gram(bus_addr(6 downto 1))) else '0';
   igramB : entity work.spu_pocket_sdp
   generic map (ADDR_WIDTH => 6, DATA_WIDTH => 16)
   port map (clk => clk1x, we => GRAM_write, wa => std_logic_vector(GRAM_addrA), d => GRAM_dataA,
             re => bus_rd_en, ra => std_logic_vector(bus_addr(6 downto 1)), q => GBQ);

   -- the clear after SS_reset also zeroes the first 64 words; a bus write goes in directly
   GRAM_write <= '1' when (ss_voice_loading = '1' and RamVoice_addrA(7 downto 6) = "00") else
                 '1' when (reset = '0' and ce = '1' and bus_write = '1' and GRAM_mapped = '1') else
                 '0';
   GRAM_addrA <= RamVoice_addrA(5 downto 0) when (ss_voice_loading = '1') else bus_addr(6 downto 1);
   GRAM_dataA <= x"0000" when (ss_voice_loading = '1') else bus_dataWrite;

-- VOICEREGS  
 
   -- bus copies: registered read (the address is captured by a bus read, q holds until the next one), fed by the
   -- registered write signals; bus_dataRead takes q while brd_sel names the copy and bus_reg otherwise
   bus_rd_en <= bus_read and ce and (not reset);
   bus_dataRead <= VBQ   when (brd_sel = "01") else
                   VOLBQ when (brd_sel = "10") else
                   GBQ   when (brd_sel = "11") else
                   bus_reg;

   ivregB : entity work.spu_pocket_sdp
   generic map (ADDR_WIDTH => 8, DATA_WIDTH => 16)
   port map (clk => clk1x, we => RamVoice_write, wa => std_logic_vector(RamVoice_addrA), d => RamVoice_dataA,
             re => bus_rd_en, ra => std_logic_vector(bus_addr(8 downto 1)), q => VBQ);
   
   
   -- the engine reads each register through its own RAM copy (registered read, address of the voice of the next VOICE_START);
   -- the copies are written in the clock of the write, one clock before the bus copy (which is written from registered signals),
   -- so both show a write from the same clock on
   -- the registers of a voice that the golden copies at the start of the slot are the held outputs of their RAM copies: the
   -- read enable stays high until the clock that copies, and q keeps that word for the rest of the slot
   voice_pre  <= '1' when (state = IDLE or state = RAM_WAIT) else '0';
   vq_re(4)   <= '1' when (voice_pre = '1' or (state = VOICE_START and (bus_write = '1' or ce = '0'))) else '0';
   vq_re(5)   <= '1' when (voice_pre = '1' or state = VOICE_START or (state = VOICE_READHEADER and ce = '0')) else '0';
   vq_re(6)   <= '1' when (voice_pre = '1' or state = VOICE_START or state = VOICE_READHEADER or state = VOICE_EVALHEADER or
                           state = VOICE_EVALSAMPLE or state = VOICE_DECODESAMPLE or (state = VOICE_PICKSAMPLE and ce = '0')) else '0';
   vq_re(0 to 3) <= (others => '1');
   vq_re(7)   <= '1';
   -- the sweep engine reads volLeft and volRight and can outlive the voice state (a reset), so q is held until it is idle
   vvq_re(0)  <= vq_re(4) when (envelopeState = ENV_IDLE) else '0';
   vvq_re(1)  <= vq_re(5) when (envelopeState = ENV_IDLE) else '0';
   adsrSetting <= unsigned(std_logic_vector'(VQ(5) & VQ(4)));
   adsrVolume  <= signed(VQ(6));
   volLeft     <= signed(VVQ(0));
   volRight    <= signed(VVQ(1));

   vw_eng7 <= '1' when (state = VOICE_APPLYVOLUME and ce = '1' and reset = '0' and bus_write = '0' and updateRepeat = '1') else '0';
   vw_eng6 <= '1' when (state = VOICE_CHECKEND and ce = '1' and reset = '0' and bus_write = '0') else '0';
   vw_bus  <= '1' when (ce = '1' and reset = '0' and bus_write = '1' and bus_addr < 16#180#) else '0';
   vw_zero <= '1' when (voice.adpcmSamplePos(19 downto 12) >= 28 and loopEnd = '1' and loopRepeat = '0' and non_bit = '0') else '0';

   vw_we   <= vw_eng7 or vw_eng6 or vw_bus or ss_voice_loading;
   vw_addr <= to_unsigned(index, 5) & "111"                      when (vw_eng7 = '1') else
              to_unsigned(index, 5) & "110"                      when (vw_eng6 = '1') else
              bus_addr(8 downto 1)                               when (vw_bus = '1')  else
              RamVoice_addrA;
   vw_data <= std_logic_vector(voice.currentAddr)                when (vw_eng7 = '1') else
              (15 downto 0 => '0')                               when (vw_eng6 = '1' and vw_zero = '1') else
              std_logic_vector(adsrVolumeNew)                    when (vw_eng6 = '1') else
              bus_dataWrite                                      when (vw_bus = '1')  else
              (15 downto 0 => '0');

   gVREGE : for r in 0 to 7 generate
   begin
      ivregE : entity work.spu_pocket_sdp
      generic map (ADDR_WIDTH => 5, DATA_WIDTH => 16)
      port map
      (
         clk => clk1x,
         we  => vw_we and to_stdl(vw_addr(2 downto 0) = r),
         wa  => std_logic_vector(vw_addr(7 downto 3)),
         d   => vw_data,
         re  => vq_re(r),
         ra  => std_logic_vector(RamVoiceRecord_addrB(0)),
         q   => VQ(r)
      );
   end generate;
                        
-- VOICEVOLUMES
 
   ivolB : entity work.spu_pocket_sdp
   generic map (ADDR_WIDTH => 6, DATA_WIDTH => 16)
   port map (clk => clk1x, we => RamVoiceVolumes_write, wa => std_logic_vector(RamVoiceVolumes_addrA), d => RamVoiceVolumes_dataA,
             re => bus_rd_en, ra => std_logic_vector(bus_addr(6 downto 1)), q => VOLBQ);
   
   
   -- engine copies (left and right word of a voice), registered read, written in the clock of the write like the voice register copies
   vvw_env <= '1' when (envelopeState = ENV_WRITE and ce = '1' and reset = '0' and envelopeVoice = '1') else '0';
   vvw_we  <= '1' when (vvw_env = '1' or (ss_voice_loading = '1' and RamVoice_addrA < 48)) else '0';
   vvw_addr <= to_unsigned(envelopeIndex, 6) when (vvw_env = '1') else RamVoice_addrA(5 downto 0);
   vvw_data <= std_logic_vector(envVolume) when (vvw_env = '1') else (15 downto 0 => '0');

   gVVOL : for r in 0 to 1 generate
   begin
      ivvolE : entity work.spu_pocket_sdp
      generic map (ADDR_WIDTH => 5, DATA_WIDTH => 16)
      port map
      (
         clk => clk1x,
         we  => vvw_we and to_stdl((vvw_addr(0) = '1') = (r = 1)),
         wa  => std_logic_vector(vvw_addr(5 downto 1)),
         d   => vvw_data,
         re  => vvq_re(r),
         ra  => std_logic_vector(RamVoiceRecord_addrB(0)),
         q   => VVQ(r)
      );
   end generate;                                     -- right value
     
-- VOICERECORDS
 
   gVOICERECORDS : for i in 0 to 0 generate
   begin
      itagramVOICECORDS : entity work.spu_pocket_sdp
      generic map (ADDR_WIDTH => 5, DATA_WIDTH => 100)
      port map
      (
         clk => clk1x,
         we  => RamVoiceRecord_write,
         wa  => std_logic_vector(RamVoiceRecord_addrA),
         d   => RamVoiceRecord_dataA,
         ra  => std_logic_vector(RamVoiceRecord_addrB(i)),
         q   => RamVoiceRecord_dataB(i)
      );
   end generate;

   -- registered read: the address is that of the voice the next VOICE_START loads
   RamVoiceRecord_addrB(0)  <= to_unsigned(0, 5)         when (state = IDLE) else
                               to_unsigned(index + 1, 5) when (state = RAM_WAIT) else
                               to_unsigned(index, 5);

   -- the working copy goes back to the record RAM in the clock of VOICE_END; the clear after SS_reset zeroes the first 24 words
   voice_store          <= '1' when (state = VOICE_END and ce = '1' and reset = '0') else '0';
   RamVoiceRecord_write <= voice_store when (voice_store = '1') else
                           '1' when (ss_voice_loading = '1' and RamVoice_addrA < 24) else '0';
   RamVoiceRecord_addrA <= to_unsigned(index, 5) when (voice_store = '1') else RamVoice_addrA(4 downto 0);
   RamVoiceRecord_dataA <= (voice.ignoreLoopWB & voice.firstBlock & std_logic_vector(voice.adsrTicks) & std_logic_vector(voice.adsrphase) &
                            std_logic_vector(voice.adpcmDecodePtr) & std_logic_vector(voice.adpcmSamplePos) &
                            std_logic_vector(voice.adpcmLast1) & std_logic_vector(voice.adpcmLast0) & std_logic_vector(voice.currentAddr))
                           when (voice_store = '1') else (others => '0');
   
     
-- adpcmSamples
   gram_adpcmSamples: for i in 0 to 3 generate
   begin
      iram_adpcmSamples: entity mem.dpram
      generic map (addr_width => 8, data_width => 16)
      port map
      (
         clock_a     => clk1x,
         address_a   => std_logic_vector(adpcm_ram_address_a),
         data_a      => adpcm_ram_data_a(i),
         wren_a      => adpcm_ram_wren_a(i),
         
         clock_b     => clk1x,
         address_b   => std_logic_vector(adpcm_ram_address_b(i)),
         data_b      => x"0000",
         wren_b      => '0',
         q_b         => adpcm_ram_q_b(i)
      );
   end generate; 
   
-- envelopecounters  
 
   iEnvCounterRam : entity work.spu_pocket_sdp
   generic map (ADDR_WIDTH => 6, DATA_WIDTH => 22)
   port map
   (
      clk => clk1x,
      we  => EnvCounterRam_write,
      wa  => std_logic_vector(EnvCounterRam_addrA),
      d   => EnvCounterRam_dataA,
      ra  => std_logic_vector(EnvCounterRam_addrB),
      q   => EnvCounterRam_dataB
   );
   
   -- registered read: the index the next ENV_START uses (ENV_WRITE advances envelopeIndex)
   EnvCounterRam_addrB <= to_unsigned(envelopeIndex + 1, 6) when (envelopeState = ENV_WRITE and envelopeIndex < 49) else
                          to_unsigned(envelopeIndex, 6);

   -- the counters of a sweep are stored in the clock of ENV_WRITE; the clear after SS_reset zeroes the first 50 words
   EnvCounterRam_write <= '1' when (envelopeState = ENV_WRITE and ce = '1' and reset = '0') else
                          '1' when (ss_voice_loading = '1' and RamVoice_addrA < 50) else '0';
   EnvCounterRam_addrA <= to_unsigned(envelopeIndex, 6) when (envelopeState = ENV_WRITE and ce = '1' and reset = '0') else RamVoice_addrA(5 downto 0);
   EnvCounterRam_dataA <= (envTicksNew & std_logic_vector(envTicks)) when (envelopeState = ENV_WRITE and ce = '1' and reset = '0') else (others => '0');
     
-- savestates
     

      

-- cpu interface + processing
   process(clk1x)
      variable env_calcticks       : unsigned(20 downto 0);
      variable env_rate            : unsigned(6 downto 0);
      variable env_calcstep        : signed(16 downto 0);
      variable envVolumeSum        : signed(17 downto 0);
      variable adsr_stepcalc       : signed(16 downto 0);
      variable adsr_volumeCalc     : signed(16 downto 0);
      variable adsrVolumeSum       : signed(17 downto 0);
      variable interpol1           : signed(30 downto 0);
      variable interpol2           : signed(30 downto 0);
      variable interpol3           : signed(30 downto 0);
      variable interpol4           : signed(30 downto 0);
      variable soundmulresult      : signed(39 downto 0);
      variable reverbInputLeft_v   : signed(15 downto 0);
      variable reverbInputRight_v  : signed(15 downto 0);
   begin
      if (rising_edge(clk1x)) then
            
         FifoIn_Wr               <= '0';
         FifoIn_Rd               <= '0';
         FifoIn_reset            <= '0';
         
         FifoOut_Wr              <= '0';
         FifoOut_reset           <= '0';
               
         RamVoice_write          <= '0';
         RamVoiceVolumes_write   <= '0';
            
               
               
         ram_request             <= '0';
         ram_check_irq           <= '0';
         ram_isVoice             <= '0';
            
         sound_timeout           <= '0';
         
         if (SS_reset = '1') then
            ss_voice_loading <= '1';
            RamVoice_write <= '1';
            RamVoice_dataA <= x"0000";
            RamVoice_addrA <= (others => '0');
         end if;
         
         if (ss_voice_loading = '1') then
            RamVoice_write <= '1';
            RamVoice_addrA <= RamVoice_addrA + 1;
            if (RamVoice_addrA = 191) then
               ss_voice_loading <= '0';
            end if;
            if (RamVoice_addrA < 48) then
               RamVoiceVolumes_write <= '1';
               RamVoiceVolumes_dataA <= (others => '0');
               RamVoiceVolumes_addrA <= RamVoice_addrA(5 downto 0);
            end if;
            if (RamVoice_addrA < 50) then
            end if;
         end if;
      
         if (reset = '1') then
            
            state                <= IDLE;
            irqOut               <= '0';
            irqSaved             <= '0';
            stashedSamples       <= 0;
            
            FifoOut_reset        <= '1';
            FifoIn_reset         <= '1';
               
            sound_out_left       <= (others => '0');
            sound_out_right      <= (others => '0');
            
            reverbLastLeft       <= (others => '0');
            reverbLastRight      <= (others => '0');
            reverbL_d1           <= (others => '0');
            reverbL_d2           <= (others => '0');
            reverbL_d3           <= (others => '0');
            reverbL_d4           <= (others => '0');
            reverbR_d1           <= (others => '0');
            reverbR_d2           <= (others => '0');
            reverbR_d3           <= (others => '0');
            reverbR_d4           <= (others => '0');
            reverbDownLeft       <= (others => '0');
            reverbDownRight      <= (others => '0');
            reverbPartA_L        <= (others => '0');
            reverbPartB_L        <= (others => '0');
            reverbPartA_R        <= (others => '0');
            reverbPartB_R        <= (others => '0');
            
            cd_next_left         <= (others => '0');
            cd_next_right        <= (others => '0');
               
            sampleticks          <= to_unsigned(512, 10); --unsigned(ss_in(1)(9 downto 0));
            
            if (true) then
               capturePosition      <= (others => '0');
               ramTransferAddr      <= (others => '0');
               reverbCurrentAddress <= (others => '0');
               reverbRight          <= '0';
               noiseLevel           <= x"0001";
               noiseCnt             <= (others => '0');
               
               IRQ9                 <= '0';
                  
               KEYON                <= (others => '0');
               KEYOFF               <= (others => '0');
               REVERBON             <= (others => '0');
               ENDX                 <= (others => '0');
                     
               VOLUME_LEFT          <= (others => '0');
               VOLUME_RIGHT         <= (others => '0');
               CNT		            <= (others => '0');
               CDAUDIO_VOL_L        <= (others => '0');
               CDAUDIO_VOL_R        <= (others => '0');
               CURVOL_L	            <= (others => '0');
               CURVOL_R	            <= (others => '0');
               IRQ_ADDR             <= (others => '0');
               REVERB_vLOUT         <= (others => '0');
               REVERB_vROUT         <= (others => '0');
               REVERB_mBASE         <= (others => '0');
               REVERB_dAPF1         <= (others => '0');
               REVERB_dAPF2         <= (others => '0');
               REVERB_vIIR          <= (others => '0');
               REVERB_vCOMB1        <= (others => '0');
               REVERB_vCOMB2        <= (others => '0');
               REVERB_vCOMB3        <= (others => '0');
               REVERB_vCOMB4        <= (others => '0');
               REVERB_vWALL         <= (others => '0');
               REVERB_vAPF1         <= (others => '0');
               REVERB_vAPF2         <= (others => '0');
               REVERB_mLSAME        <= (others => '0');
               REVERB_mRSAME        <= (others => '0');
               REVERB_mLCOMB1       <= (others => '0');
               REVERB_mRCOMB1       <= (others => '0');
               REVERB_mLCOMB2       <= (others => '0');
               REVERB_mRCOMB2       <= (others => '0');
               REVERB_dLSAME        <= (others => '0');
               REVERB_dRSAME        <= (others => '0');
               REVERB_mLDIFF        <= (others => '0');
               REVERB_mRDIFF        <= (others => '0');
               REVERB_mLCOMB3       <= (others => '0');
               REVERB_mRCOMB3       <= (others => '0');
               REVERB_mLCOMB4       <= (others => '0');
               REVERB_mRCOMB4       <= (others => '0');
               REVERB_dLDIFF        <= (others => '0');
               REVERB_dRDIFF        <= (others => '0');
               REVERB_mLAPF1        <= (others => '0');
               REVERB_mRAPF1        <= (others => '0');
               REVERB_mLAPF2        <= (others => '0');
               REVERB_mRAPF2        <= (others => '0');
               REVERB_vLIN          <= (others => '0');
               REVERB_vRIN          <= (others => '0');
            end if;
            
         elsif (ce = '1') then
         
            irqOut <= '0';
            
            envelope_startnext <= '0';
            
            if ((ram_request = '1' or ram_check_irq = '1') and cnt(15) = '1' and cnt(6) = '1' and (IRQ_ADDR = ram_Adr(18 downto 3)) and irq9 = '0') then
               if (irqVoicetrigger = '1' or (state /= VOICE_EVALHEADER and state /= VOICE_EVALSAMPLE)) then
                  if (REPRODUCIBLESPUIRQ = '1') then
                     irqSaved <= '1';
                  else
                     IRQ9 <= '1';
                     irqOut <= '1';
                  end if;
               end if;
            end if;
            
            if (SPUIRQTrigger = '1') then
               if (REPRODUCIBLESPUIRQ = '1') then
                  irqSaved <= '1';
               else
                  IRQ9 <= '1';
                  irqOut <= '1';
               end if;
            end if;
         
            if (bus_write = '1') then
               
               if (bus_addr < 16#180#) then
                  RamVoice_write <= '1';
                  RamVoice_dataA <= bus_dataWrite;
                  RamVoice_addrA <= bus_addr(8 downto 1);

                  case (bus_addr(3 downto 0)) is
                     when x"8" | x"A" => voice_adsrWrite(to_integer(bus_addr(8 downto 4)))   <= '1';
                     when x"E"        => voice_repeatWrite(to_integer(bus_addr(8 downto 4))) <= '1';
                     when others => null;
                  end case;
                  
               else
                  case (to_integer(bus_addr)) is
                     when 16#180# => VOLUME_LEFT               <= bus_dataWrite;
                     when 16#182# => VOLUME_RIGHT              <= bus_dataWrite;
                  
                     when 16#188# => KEYON(15 downto 0)        <= bus_dataWrite;
                     when 16#18A# => KEYON(31 downto 16)       <= bus_dataWrite;
                     when 16#18C# => KEYOFF(15 downto 0)       <= bus_dataWrite;
                     when 16#18E# => KEYOFF(31 downto 16)      <= bus_dataWrite;
                     when 16#198# => if (not NO_REVERB) then REVERBON(15 downto 0)  <= bus_dataWrite; end if;
                     when 16#19A# => if (not NO_REVERB) then REVERBON(31 downto 16) <= bus_dataWrite; end if;
                     
                     when 16#1A4# => IRQ_ADDR                  <= bus_dataWrite;
                                     
                     when 16#1A6# => 
                        ramTransferAddr  <= unsigned(bus_dataWrite) & "000";
                     
                     when 16#1A8# =>
                        if (FifoIn_Full = '0') then
                           FifoIn_Wr  <= '1';
                           FifoIn_Din <= bus_dataWrite;
                        end if;
                                                             
                     when 16#1AA# => 
                        if ((CNT(5 downto 4) /= bus_dataWrite(5 downto 4)) and bus_dataWrite(5 downto 4) = "00") then
                           if (CNT(5 downto 4) = "11") then -- read
                              FifoOut_reset <= '1';
                           else -- write
                              FifoIn_reset <= '1';
                           end if;
                        end if;

                        -- todo if enable turned off changed -> mute
                        CNT <= bus_dataWrite;
                        
                        if (bus_dataWrite(6) = '0') then
                           IRQ9 <= '0';
                        end if;
                        
                                     
                     when 16#1B0# => CDAUDIO_VOL_L             <= bus_dataWrite;
                     when 16#1B2# => CDAUDIO_VOL_R             <= bus_dataWrite;
                     
                     when 16#184# => if (not NO_REVERB) then REVERB_vLOUT <= bus_dataWrite; end if;
                     when 16#186# => if (not NO_REVERB) then REVERB_vROUT <= bus_dataWrite; end if;
                     when 16#1A2# => REVERB_mBASE              <= bus_dataWrite; reverbCurrentAddress <= unsigned(bus_dataWrite) & "00";
                     when 16#1C0# => if (not NO_REVERB) then REVERB_dAPF1 <= bus_dataWrite; end if;
                     when 16#1C2# => if (not NO_REVERB) then REVERB_dAPF2 <= bus_dataWrite; end if;
                     when 16#1C4# => if (not NO_REVERB) then REVERB_vIIR <= bus_dataWrite; end if;
                     when 16#1C6# => if (not NO_REVERB) then REVERB_vCOMB1 <= bus_dataWrite; end if;
                     when 16#1C8# => if (not NO_REVERB) then REVERB_vCOMB2 <= bus_dataWrite; end if;
                     when 16#1CA# => if (not NO_REVERB) then REVERB_vCOMB3 <= bus_dataWrite; end if;
                     when 16#1CC# => if (not NO_REVERB) then REVERB_vCOMB4 <= bus_dataWrite; end if;
                     when 16#1CE# => if (not NO_REVERB) then REVERB_vWALL <= bus_dataWrite; end if;
                     when 16#1D0# => if (not NO_REVERB) then REVERB_vAPF1 <= bus_dataWrite; end if;
                     when 16#1D2# => if (not NO_REVERB) then REVERB_vAPF2 <= bus_dataWrite; end if;
                     when 16#1D4# => if (not NO_REVERB) then REVERB_mLSAME <= bus_dataWrite; end if;
                     when 16#1D6# => if (not NO_REVERB) then REVERB_mRSAME <= bus_dataWrite; end if;
                     when 16#1D8# => if (not NO_REVERB) then REVERB_mLCOMB1 <= bus_dataWrite; end if;
                     when 16#1DA# => if (not NO_REVERB) then REVERB_mRCOMB1 <= bus_dataWrite; end if;
                     when 16#1DC# => if (not NO_REVERB) then REVERB_mLCOMB2 <= bus_dataWrite; end if;
                     when 16#1DE# => if (not NO_REVERB) then REVERB_mRCOMB2 <= bus_dataWrite; end if;
                     when 16#1E0# => if (not NO_REVERB) then REVERB_dLSAME <= bus_dataWrite; end if;
                     when 16#1E2# => if (not NO_REVERB) then REVERB_dRSAME <= bus_dataWrite; end if;
                     when 16#1E4# => if (not NO_REVERB) then REVERB_mLDIFF <= bus_dataWrite; end if;
                     when 16#1E6# => if (not NO_REVERB) then REVERB_mRDIFF <= bus_dataWrite; end if;
                     when 16#1E8# => if (not NO_REVERB) then REVERB_mLCOMB3 <= bus_dataWrite; end if;
                     when 16#1EA# => if (not NO_REVERB) then REVERB_mRCOMB3 <= bus_dataWrite; end if;
                     when 16#1EC# => if (not NO_REVERB) then REVERB_mLCOMB4 <= bus_dataWrite; end if;
                     when 16#1EE# => if (not NO_REVERB) then REVERB_mRCOMB4 <= bus_dataWrite; end if;
                     when 16#1F0# => if (not NO_REVERB) then REVERB_dLDIFF <= bus_dataWrite; end if;
                     when 16#1F2# => if (not NO_REVERB) then REVERB_dRDIFF <= bus_dataWrite; end if;
                     when 16#1F4# => if (not NO_REVERB) then REVERB_mLAPF1 <= bus_dataWrite; end if;
                     when 16#1F6# => if (not NO_REVERB) then REVERB_mRAPF1 <= bus_dataWrite; end if;
                     when 16#1F8# => if (not NO_REVERB) then REVERB_mLAPF2 <= bus_dataWrite; end if;
                     when 16#1FA# => if (not NO_REVERB) then REVERB_mRAPF2 <= bus_dataWrite; end if;
                     when 16#1FC# => if (not NO_REVERB) then REVERB_vLIN <= bus_dataWrite; end if;
                     when 16#1FE# => if (not NO_REVERB) then REVERB_vRIN <= bus_dataWrite; end if;
                     
                     when others => null;
                  end case;
               end if;
            
            end if; -- end bus write
         
            if (bus_read = '1') then
               bus_reg <= (others => '1');
               brd_sel <= "00";
               if (bus_addr < 16#180#) then
                  brd_sel <= "01";
               elsif (bus_addr >= 16#200# and bus_addr < 16#260#) then
                  brd_sel <= "10";
               elsif (GRAM_mapped = '1') then
                  brd_sel <= "11";
               else
                  case (to_integer(bus_addr)) is
                     when 16#180# => bus_reg <= VOLUME_LEFT;
                     when 16#182# => bus_reg <= VOLUME_RIGHT;
                  
                     when 16#188# => bus_reg <= KEYON(15 downto 0);
                     when 16#18A# => bus_reg <= KEYON(31 downto 16);
                     when 16#18C# => bus_reg <= KEYOFF(15 downto 0);
                     when 16#18E# => bus_reg <= KEYOFF(31 downto 16);
                     when 16#198# => if (not NO_REVERB) then bus_reg <= REVERBON(15 downto 0);  end if;
                     when 16#19A# => if (not NO_REVERB) then bus_reg <= REVERBON(31 downto 16); end if;
                     when 16#19C# => bus_reg <= ENDX(15 downto 0);
                     when 16#19E# => bus_reg <= ENDX(31 downto 16);
                  
                     when 16#1A4# => bus_reg <= IRQ_ADDR;
                     
                
                     when 16#1AA# => bus_reg <= CNT;
                     when 16#1AE# => bus_reg <= STAT;
                   
                     when 16#1B0# => bus_reg <= CDAUDIO_VOL_L;
                     when 16#1B2# => bus_reg <= CDAUDIO_VOL_R;
                     when 16#1B8# => bus_reg <= CURVOL_L;
                     when 16#1BA# => bus_reg <= CURVOL_R;
                     
                     when 16#184# => if (not NO_REVERB) then bus_reg <= REVERB_vLOUT; end if;  
                     when 16#186# => if (not NO_REVERB) then bus_reg <= REVERB_vROUT; end if;  
                     when 16#1A2# => bus_reg <= REVERB_mBASE;  
                     when 16#1C0# => if (not NO_REVERB) then bus_reg <= REVERB_dAPF1; end if;  
                     when 16#1C2# => if (not NO_REVERB) then bus_reg <= REVERB_dAPF2; end if;  
                     when 16#1C4# => if (not NO_REVERB) then bus_reg <= REVERB_vIIR; end if;   
                     when 16#1C6# => if (not NO_REVERB) then bus_reg <= REVERB_vCOMB1; end if; 
                     when 16#1C8# => if (not NO_REVERB) then bus_reg <= REVERB_vCOMB2; end if; 
                     when 16#1CA# => if (not NO_REVERB) then bus_reg <= REVERB_vCOMB3; end if; 
                     when 16#1CC# => if (not NO_REVERB) then bus_reg <= REVERB_vCOMB4; end if; 
                     when 16#1CE# => if (not NO_REVERB) then bus_reg <= REVERB_vWALL; end if;  
                     when 16#1D0# => if (not NO_REVERB) then bus_reg <= REVERB_vAPF1; end if;  
                     when 16#1D2# => if (not NO_REVERB) then bus_reg <= REVERB_vAPF2; end if;  
                     when 16#1D4# => if (not NO_REVERB) then bus_reg <= REVERB_mLSAME; end if; 
                     when 16#1D6# => if (not NO_REVERB) then bus_reg <= REVERB_mRSAME; end if; 
                     when 16#1D8# => if (not NO_REVERB) then bus_reg <= REVERB_mLCOMB1; end if;
                     when 16#1DA# => if (not NO_REVERB) then bus_reg <= REVERB_mRCOMB1; end if;
                     when 16#1DC# => if (not NO_REVERB) then bus_reg <= REVERB_mLCOMB2; end if;
                     when 16#1DE# => if (not NO_REVERB) then bus_reg <= REVERB_mRCOMB2; end if;
                     when 16#1E0# => if (not NO_REVERB) then bus_reg <= REVERB_dLSAME; end if; 
                     when 16#1E2# => if (not NO_REVERB) then bus_reg <= REVERB_dRSAME; end if; 
                     when 16#1E4# => if (not NO_REVERB) then bus_reg <= REVERB_mLDIFF; end if; 
                     when 16#1E6# => if (not NO_REVERB) then bus_reg <= REVERB_mRDIFF; end if; 
                     when 16#1E8# => if (not NO_REVERB) then bus_reg <= REVERB_mLCOMB3; end if;
                     when 16#1EA# => if (not NO_REVERB) then bus_reg <= REVERB_mRCOMB3; end if;
                     when 16#1EC# => if (not NO_REVERB) then bus_reg <= REVERB_mLCOMB4; end if;
                     when 16#1EE# => if (not NO_REVERB) then bus_reg <= REVERB_mRCOMB4; end if;
                     when 16#1F0# => if (not NO_REVERB) then bus_reg <= REVERB_dLDIFF; end if; 
                     when 16#1F2# => if (not NO_REVERB) then bus_reg <= REVERB_dRDIFF; end if; 
                     when 16#1F4# => if (not NO_REVERB) then bus_reg <= REVERB_mLAPF1; end if; 
                     when 16#1F6# => if (not NO_REVERB) then bus_reg <= REVERB_mRAPF1; end if; 
                     when 16#1F8# => if (not NO_REVERB) then bus_reg <= REVERB_mLAPF2; end if; 
                     when 16#1FA# => if (not NO_REVERB) then bus_reg <= REVERB_mRAPF2; end if; 
                     when 16#1FC# => if (not NO_REVERB) then bus_reg <= REVERB_vLIN; end if;   
                     when 16#1FE# => if (not NO_REVERB) then bus_reg <= REVERB_vRIN; end if;   
                        
                     when others => null;
                  end case;
               end if;
            end if;
            
            -- envelope
            env_calcticks := (to_unsigned(1, 21) sll to_integer(env_rate(6 downto 2)) - 11);
            env_rate      := unsigned(volumeSetting(6 downto 0));
            
            case (envelopeState) is
            
               when ENV_IDLE =>
                  null;
               
               when ENV_START =>
                  if (volumeSetting(15) = '0') then
                     envelopeState <= ENV_WRITE;
                     envVolume     <= signed(volumeSetting(14 downto 0) & '0');
                     envTicksNew   <= '1';
                  else
                     if (envelopeVoice = '1') then
                        if (envelopeRight = '1') then
                           envVolume <= volRight;
                        else
                           envVolume <= volLeft;
                        end if;
                     else
                        if (envelopeRight = '1') then
                           envVolume <= signed(CURVOL_R);
                        else
                           envVolume <= signed(CURVOL_L);
                        end if;
                     end if;
                     
                     envTicks        <= unsigned(EnvCounterRam_dataB(20 downto 0)); 
                     envTicksNew     <= EnvCounterRam_dataB(21);
                  
                     envelopeState <= ENV_CALC;
                     
                     if (EnvCounterRam_dataB(21) = '1') then
                        envTicks    <= env_calcticks;
                        envTicksNew <= '0';
                     end if;
                     
                  end if;
                  
               when ENV_CALC =>
                  envelopeState <= ENV_WRITE;
                  if (envTicks < 2) then
                     env_calcstep := resize(env_step, 17);   -- env_step: combinational, volumeSetting does not change between ENV_START and ENV_CALC
                     envTicks     <= env_calcticks;
                     if (volumeSetting(14) = '1') then 
                        if (volumeSetting(13) = '1') then 
                           env_calcstep := resize(shift_right(env_calcstep * envVolume, 15), 17);
                        else
                           if (envVolume >= 16#6000#) then
                              if (env_rate < 40) then
                                 env_calcstep := shift_right(env_calcstep, 2);
                              elsif (env_rate >= 44) then
                                 envTicks <= "00" & env_calcticks(20 downto 2);
                              else
                                 env_calcstep := shift_right(env_calcstep, 1);
                                 envTicks     <= (others => '0');   -- env_calcticks is 0 below rate 44
                              end if;
                           end if;
                        
                        end if;
                     end if;
                     
                     envVolumeSum := resize(envVolume, 18) + resize(env_calcstep, 18);
                     
                     if (envVolumeSum < 0) then
                        envVolume <= (others => '0');
                     elsif (envVolumeSum > 16#7FFF#) then 
                        envVolume <= x"7FFF";
                     else 
                        envVolume <= resize(envVolumeSum, 16);
                     end if;
                  else
                     envTicks <= envTicks - 1;
                  end if;
                  
               when ENV_WRITE =>
                  if (envelopeVoice = '1') then
                     RamVoiceVolumes_write <= '1';
                     RamVoiceVolumes_dataA <= std_logic_vector(envVolume);
                     RamVoiceVolumes_addrA <= to_unsigned(envelopeIndex, 6);
                  else
                     if (envelopeRight = '1') then
                        CURVOL_R <= std_logic_vector(envVolume);
                     else
                        CURVOL_L <= std_logic_vector(envVolume);
                     end if;
                  end if;
                  
                     
                  if (envelopeIndex < 49) then
                     envelopeIndex  <= envelopeIndex + 1;
                  end if;
                  if (envelopeRight = '1') then
                     envelopeState   <= ENV_IDLE;
                  else
                     volumeSetting   <= volumeSettingR;
                     envelopeState   <= ENV_START;
                     envelopeRight   <= '1';
                  end if;
                  
            end case;
            
            
            -- processing
            spu_tick <= '0';
            if (sampleticks < 767) then
               sampleticks <= sampleticks + 1;
            else
               sampleticks <= (others => '0');
               spu_tick    <= '1';
               if (irqSaved = '1') then
                  irqSaved <= '0';
                  IRQ9     <= '1';
                  irqOut   <= '1';
               end if;
            end if;
            
            noiseCheck <= shift_right(to_unsigned(16#8000#, 16), to_integer(unsigned(cnt(13 downto 10)))) & x"0000";
            
            if (sampleticks = 0 and state /= IDLE) then
               if (stashedSamples < 15) then
                  stashedSamples    <= stashedSamples + 1;
               else
                  sound_timeout <= '1';
               end if;
            end if;
            
            if (voiceCounter < 31) then
               voiceCounter <= voiceCounter + 1;
            end if;

            case (state) is
            
               when IDLE =>
                  if (sampleticks = 0 or stashedSamples > 0) then
                     state          <= VOICE_START;
                     index          <= 0;
                     envelopeIndex  <= 0;
                     envelopeVoice  <= '1';
                     
                     soundleft      <= (others => '0');
                     soundright     <= (others => '0');
                     reverbsumleft  <= (others => '0');
                     reverbsumright <= (others => '0');
                     
                     if (stashedSamples > 0 and sampleticks /= 0) then
                        stashedSamples <= stashedSamples - 1;
                     end if;
                  end if;
               
               -- VOICE
               when VOICE_START =>
                  if (bus_write = '0') then
                     state         <= VOICE_READHEADER;
                     voiceCounter  <= 0;
                     
                     
                     --voice         <= voiceArray(index);
                     voice.currentAddr    <= unsigned(RamVoiceRecord_dataB(0)( 15 downto   0));
                     voice.adpcmLast0     <=   signed(RamVoiceRecord_dataB(0)( 31 downto  16));
                     voice.adpcmLast1     <=   signed(RamVoiceRecord_dataB(0)( 47 downto  32));
                     voice.adpcmSamplePos <= unsigned(RamVoiceRecord_dataB(0)( 67 downto  48));
                     voice.adpcmDecodePtr <= unsigned(RamVoiceRecord_dataB(0)( 73 downto  68));
                     voice.adsrphase      <= unsigned(RamVoiceRecord_dataB(0)( 76 downto  74));
                     voice.adsrTicks      <= unsigned(RamVoiceRecord_dataB(0)( 97 downto  77));
                     voice.firstBlock     <= RamVoiceRecord_dataB(0)(98);
                     voice.ignoreLoopWB   <= RamVoiceRecord_dataB(0)(99);
                        
                     reset_adsr <= '0';
                     if (voice_adsrWrite(index) = '1') then
                        voice_adsrWrite(index) <= '0'; 
                        reset_adsr             <= '1';
                     end if;
                     
                     if (voice_repeatWrite(index) = '1') then
                        voice_repeatWrite(index) <= '0'; 
                        if (RamVoiceRecord_dataB(0)(98) = '0') then
                           voice.ignoreLoopWB <= '1';
                        end if;
                     end if;
                     
                     
                  end if;
                     
               when VOICE_READHEADER =>
                  state           <= VOICE_EVALHEADER;
                  ram_request     <= '1';
                  ram_isVoice     <= '1';
                  ram_rnw         <= '1';
                  ram_Adr         <= std_logic_vector(voice.currentAddr) & "000";
                  
                  irqVoicetrigger <= '0';
                  if (voice.adpcmDecodePtr <= voice.adpcmSamplePos(17 downto 12)) then
                     irqVoicetrigger <= '1';
                  end if;
                  
   
                  

               when VOICE_EVALHEADER =>
                  if (ram_done = '1') then
                     if (unsigned(ram_dataRead(3 downto 0)) > 12) then
                        adpcmShift <= to_unsigned(9, 4);
                     else
                        adpcmShift <= unsigned(ram_dataRead(3 downto 0));
                     end if;
                     if (unsigned(ram_dataRead(6 downto 4)) > 4) then
                        adpcmFilter <= to_unsigned(4, 3);
                     else
                        adpcmFilter <= unsigned(ram_dataRead(6 downto 4));
                     end if;
                     loopEnd      <= ram_dataRead(8);
                     loopRepeat   <= ram_dataRead(9);
                     updateRepeat <= '0';
                     if (ram_dataRead(10) = '1' and voice.adpcmDecodePtr = 0 and voice.ignoreLoopWB = '0') then -- write ADPCM Repeat Address
                        updateRepeat <= '1';
                     end if;
                     volumeSetting      <= unsigned(VQ(0));
                     envelope_startnext <= '1';
                     envelopeRight      <= '0';
                     envelopeState      <= ENV_START; 
                     
                     state           <= VOICE_EVALSAMPLE;
                     ram_request     <= '1';
                     ram_isVoice     <= '1';
                     ram_rnw         <= '1';
                     ram_Adr         <= std_logic_vector((voice.currentAddr & "000" ) + (voice.adpcmDecodePtr(5 downto 2) & '0') + 2);
                     
                     for c in 0 to 3 loop
                        adpcmSamples(c) <= signed(adpcm_ram_q_b(c));
                     end loop;
                  
                  end if;
                  
               when VOICE_EVALSAMPLE =>
                  if (ram_done = '1') then
                     if (voice.adpcmDecodePtr <= voice.adpcmSamplePos(17 downto 12)) then
                        state  <= VOICE_DECODESAMPLE;
                     else
                        state  <= VOICE_PICKSAMPLE;
                     end if;
                     adpcmData <= ram_dataRead;
                     decodeCnt <= 0;
                  end if;
                  
                  if (envelope_startnext = '1') then
                     volumeSettingR     <= unsigned(VQ(1));
                  end if;
                  
                  if (reset_adsr = '1' and voice.adsrphase <= ADSRPHASE_RELEASE) then
                     voice.adsrTicks <= adsr_tk;
                  end if;
               
               when VOICE_DECODESAMPLE =>
                  if (decodeCnt < 3) then
                     decodeCnt <= decodeCnt + 1;
                  else
                     state <= VOICE_PICKSAMPLE;
                  end if;
                  
                  voice.adpcmLast1 <= voice.adpcmLast0;
                  voice.adpcmLast0 <= adpcm_res;
                  
                  -- the sample enters the window while decodeCnt <= the sub-sample index; it is stored in its RAM column
                  if (decodeCnt <= to_integer(voice.adpcmSamplePos(13 downto 12))) then
                     adpcmSamples((decodeCnt + 3) mod 4) <= adpcm_res;
                  end if;
                  
                  voice.adpcmDecodePtr <= voice.adpcmDecodePtr + 1;
               
               when VOICE_PICKSAMPLE =>
                  state      <= VOICE_APPLYADSR;
                  
                  interpol1  := resize(gauss1 * adpcmSamples(0), 31); 
                  interpol2  := resize(gauss2 * adpcmSamples(1), 31); 
                  interpol3  := resize(gauss3 * adpcmSamples(2), 31); 
                  interpol4  := resize(gauss4 * adpcmSamples(3), 31); 
                  
                  sample     <= resize(shift_right(interpol1 + interpol2 + interpol3 + interpol4, 15), 16);
                  
                  if (non_bit = '1') then
                     sample <= signed(noiseLevel);
                  end if;
               
               when VOICE_APPLYADSR =>
                  state                <= VOICE_APPLYVOLUME;
                  adsr_volumeCalc      := resize(shift_right(sample * adsrVolume, 15), 17);
                  volume               <= adsr_volumeCalc;
                  
                  step       <= unsigned(VQ(2));
                  if (index > 0 and pmon_bit = '1') then
                     step <= resize(shift_right(unsigned(VQ(2)) * unsigned(voice_lastVolume + x"8000"), 15), 16);
                  end if;
                  
                  
                  -- adsr new volume
                  adsrVolumeNew <= adsrVolume;
                  if (voice.adsrphase /= ADSRPHASE_OFF) then
                     if (voice.adsrTicks < 2) then
                        
                        voice.adsrTicks <= adsr_tk;
                        
                        adsr_stepcalc := resize(adsr_st, 17);
                        if (adsr_e = '1') then
                           if (adsr_d = '1') then
                              adsr_stepcalc := resize(shift_right(adsr_stepcalc * adsrVolume, 15), 17);
                           else
                              if (adsrVolume >= 16#6000#) then
                                 if (adsr_r < 40) then
                                    adsr_stepcalc := shift_right(adsr_stepcalc, 2);
                                 elsif (adsr_r >= 44) then
                                    voice.adsrTicks <= "00" & adsr_tk(20 downto 2);
                                 else
                                    adsr_stepcalc   := shift_right(adsr_stepcalc, 1);
                                    voice.adsrTicks <= (others => '0');   -- adsr_tk is 1 below rate 48, half of it is 0
                                 end if;
                              end if;
                           end if;
                        end if;
                        
                        adsrVolumeSum := resize(adsrVolume, 18) + resize(adsr_stepcalc, 18);
                        
                        if (adsrVolumeSum < 0) then
                           adsrVolumeNew <= (others => '0');
                        elsif (adsrVolumeSum > 16#7FFF#) then 
                           adsrVolumeNew <= x"7FFF";
                        else 
                           adsrVolumeNew <= resize(adsrVolumeSum, 16);
                        end if;
                        
                     else
                        voice.adsrTicks <= voice.adsrTicks - 1;
                     end if;
                  end if;
                  
               when VOICE_APPLYVOLUME =>
                  if (bus_write = '0') then
                     state      <= VOICE_CHECKEND;
                     
                     
                     if (step < 16#3FFF#) then
                        voice.adpcmSamplePos <= voice.adpcmSamplePos + step;
                     else
                        voice.adpcmSamplePos <= voice.adpcmSamplePos + 16#3FFF#;
                     end if;
                     
                     -- adsr phase switch
                     if (voice.adsrphase /= ADSRPHASE_OFF and voice.adsrphase /= ADSRPHASE_SUSTAIN) then
                        if ((adsr_dec_cur = '1' and to_integer(adsrVolumeNew) <= to_integer(adsr_target)) or (adsr_dec_cur = '0' and to_integer(adsrVolumeNew) >= to_integer(adsr_target))) then
                           voice.adsrTicks <= adsr_tk;
                           case (voice.adsrphase) is
                              when ADSRPHASE_ATTACK  => voice.adsrphase <= ADSRPHASE_DECAY;
                              when ADSRPHASE_DECAY   => voice.adsrphase <= ADSRPHASE_SUSTAIN;
                              when ADSRPHASE_RELEASE => voice.adsrphase <= ADSRPHASE_OFF;
                              when others => null;
                           end case;
                        end if;
                     end if;
                     
                     -- writeback repeat address
                     if (updateRepeat = '1') then
                        RamVoice_write <= '1';
                        RamVoice_dataA <= std_logic_vector(voice.currentAddr);
                        RamVoice_addrA <= to_unsigned((index * 8) + 7, 8); 
                     end if;
                     
                  end if;
                  
               when VOICE_CHECKEND =>
                  if (bus_write = '0') then
                     state            <= VOICE_CHECKKEY;
                     
                     -- writeback current ADSR volume
                     RamVoice_write <= '1';
                     RamVoice_dataA <= std_logic_vector(adsrVolumeNew);
                     RamVoice_addrA <= to_unsigned((index * 8) + 6, 8); 
                     
                     if (voice.adpcmSamplePos(19 downto 12) >= 28) then
                        voice.firstBlock      <= '0';
                        voice.adpcmSamplePos  <= voice.adpcmSamplePos - 114688; -- (28 << 12)
                        voice.AdpcmDecodePtr  <= (others => '0');
                        --adpcmSamples(index,0) <= adpcmSamples(index,28);
                        --adpcmSamples(index,1) <= adpcmSamples(index,29);
                        --adpcmSamples(index,2) <= adpcmSamples(index,30);
                        if (loopEnd = '1') then
                           ENDX(index)           <= '1';
                           voice.currentAddr     <= unsigned(VQ(7)(15 downto 1)) & '0';
                           if (loopRepeat = '0' and non_bit = '0') then
                              voice.adsrphase <= ADSRPHASE_OFF;
                              RamVoice_dataA  <= (others => '0');
                           end if;
                        else
                           voice.currentAddr <= voice.currentAddr + 2;
                        end if;
                     end if;
                     
                     -- spu off
                     --if (cnt(15) = '0') then
                     --   RamVoice_dataA  <= (others => '0');
                     --end if;
                     
                  end if;
                  
               when VOICE_CHECKKEY =>
                  state <= VOICE_END;
               
                  if (KEYOFF(index) = '1') then
                     KEYOFF(index) <= '0';
                     if (voice.adsrphase /= ADSRPHASE_OFF and voice.adsrphase /= ADSR_RELEASE) then
                        voice.adsrphase <= ADSRPHASE_RELEASE;
                        voice.adsrTicks <= adsr_tk;
                     end if;
                  end if;  
               
                  if (KEYON(index) = '1') then
                     KEYON(index)            <= '0';
                     ENDX(index)             <= '0';
                     voice_adsrWrite(index)  <= '0'; 
                     voice.firstBlock        <= '1'; 
                     voice.ignoreLoopWB      <= '0'; 
                     voice.adpcmDecodePtr    <= (others => '0');
                     voice.currentAddr       <= unsigned(VQ(3)(15 downto 1)) & '0';
                     voice.adsrphase         <= ADSRPHASE_ATTACK;
                     voice.adpcmSamplePos    <= (others => '0');
                     voice.adpcmLast0        <= (others => '0');
                     voice.adpcmLast1        <= (others => '0');
                     voice.adsrTicks         <= adsr_tk;
                     --adpcmSamples(index,0)  <= (others => '0');
                     --adpcmSamples(index,1)  <= (others => '0');
                     --adpcmSamples(index,2)  <= (others => '0');
                  end if;   
                  
                  -- spu off
                  --if (cnt(15) = '0') then
                  --   voice.adsrphase <= ADSRPHASE_OFF;
                  --end if;
                  
               when VOICE_END =>
                  if (cnt(14) = '1') then -- mute voices
                     soundleft  <= soundleft  + resize(chanLeft , 24);
                     soundright <= soundright + resize(chanRight, 24);
                  end if;
                  if (not NO_REVERB and REVERBON(index) = '1') then
                     reverbsumleft  <= reverbsumleft  + resize(chanLeft , 24);
                     reverbsumright <= reverbsumright + resize(chanRight, 24);
                  end if;
                  
                  if (index = 1) then voice_lastVolume1 <= voice_lastVolume; end if;
                  if (index = 3) then voice_lastVolume3 <= voice_lastVolume; end if;
                  
                  ram_Adr         <= std_logic_vector(ramTransferAddr);
                  
                  if (CNT(5 downto 4) = "11" and FifoOut_NearFull = '0') then
                     state           <= RAM_READ;
                     ram_request     <= '1';
                     ram_rnw         <= '1';
                     ramTransferAddr <= ramTransferAddr + 2;
                  elsif (FifoIn_Empty = '0') then
                     state           <= RAM_WRITE;
                     ram_request     <= '1';
                     ram_rnw         <= '0';
                     ram_dataWrite   <= FifoIn_Dout;
                     FifoIn_Rd       <= '1';
                     ramTransferAddr <= ramTransferAddr + 2;
                  else
                     state         <= RAM_WAIT;
                     ram_check_irq <= '1'; -- seperate signal, so there is no useless SPU request to ddr3
                  end if;
                  

               -- DATA TRANSFER   
               when RAM_READ =>
                  if (ram_done = '1') then
                     state       <= RAM_WAIT;
                     FifoOut_Din <= ram_dataRead;
                     FifoOut_Wr  <= '1';
                  end if;
               
               when RAM_WRITE =>
                  if (ram_done = '1') then
                     state <= RAM_WAIT;
                  end if;
                  
               when RAM_WAIT =>
                  if (voiceCounter >= 23) then
                     if (index = 23) then
                        if (not NO_REVERB) then
                        if (cnt(0) = '1' and cnt(2) = '1') then
                           reverbInputLeft_v  := clamp16(reverbsumleft  + resize(cd_next_left, 24));
                           reverbInputRight_v := clamp16(reverbsumright + resize(cd_next_right, 24));
                        else
                           reverbInputLeft_v  := clamp16(reverbsumleft);
                           reverbInputRight_v := clamp16(reverbsumright);
                        end if;
                        reverbDownLeft  <= clamp16(shift_right(reverbPartA_L + reverbPartB_L, 4));
                        reverbDownRight <= clamp16(shift_right(reverbPartA_R + reverbPartB_R, 4));
                        reverbPartA_L <= resize(reverbInputLeft_v, 25)
                                         + shift_left(resize(reverbL_d1, 25), 2);
                        reverbPartB_L <= shift_left(resize(reverbL_d2, 25), 2) + shift_left(resize(reverbL_d2, 25), 1)
                                         + shift_left(resize(reverbL_d3, 25), 2)
                                         + resize(reverbL_d4, 25);
                        reverbPartA_R <= resize(reverbInputRight_v, 25)
                                         + shift_left(resize(reverbR_d1, 25), 2);
                        reverbPartB_R <= shift_left(resize(reverbR_d2, 25), 2) + shift_left(resize(reverbR_d2, 25), 1)
                                         + shift_left(resize(reverbR_d3, 25), 2)
                                         + resize(reverbR_d4, 25);
                        reverbL_d4 <= reverbL_d3;
                        reverbL_d3 <= reverbL_d2;
                        reverbL_d2 <= reverbL_d1;
                        reverbL_d1 <= reverbInputLeft_v;
                        reverbR_d4 <= reverbR_d3;
                        reverbR_d3 <= reverbR_d2;
                        reverbR_d2 <= reverbR_d1;
                        reverbR_d1 <= reverbInputRight_v;
                        end if;

                        if (not NO_REVERB and cnt(7) = '1' and REVERBOFF = '0') then
                           state           <= REVERB_READ1;
                        else
                           state           <= REVERB_READ2;
                        end if;
                        reverb_count <= 0;
                        
                        -- CD audio add
                        cdProcStep     <= 0;
                        if (cnt(0) = '1') then
                           soundleft      <= soundleft  + resize(cd_next_left, 24);
                           soundright     <= soundright + resize(cd_next_right,24);
                           if (not NO_REVERB and cnt(2) = '1') then
                              reverbsumleft  <= reverbsumleft  + resize(cd_next_left, 24);
                              reverbsumright <= reverbsumright + resize(cd_next_right,24);
                           end if;
                        end if;
                        
                     else
                        state <= VOICE_START;
                        index <= index + 1;
                     end if;
                  end if;

               -- REVERB
               when REVERB_READ1 =>
                  if (not NO_REVERB) then
                  if (reverb_count = 0 or ram_done = '1') then
                     reverb_count <= reverb_count + 1;
                     if (reverb_count < 4) then
                        ram_request    <= '1';
                        ram_rnw        <= '1';
                        ram_Adr        <= std_logic_vector(reverb_calcAddr);
                     end if;
                     case (reverb_count) is
                        when 1 => reverbReadval1 <= signed(ram_dataRead); 
                        when 2 => reverbReadval2 <= signed(ram_dataRead);
                        when 3 => reverbReadval3 <= signed(ram_dataRead);
                        when 4 => reverbReadval4 <= signed(ram_dataRead); state <= REVERB_PROCOUT; reverb_count <= 0;
                        when others => null;                     
                     end case;
                  end if;
                  if (ram_done = '1') then
                  end if;
                  end if;
               
               when REVERB_PROCOUT =>
                  if (not NO_REVERB) then
                  reverb_count <= reverb_count + 1;
                  case (reverb_count) is
                     when 0 => 
                        -- wallmult = (value1 * PSXRegs.SPU_REVERB_vWALL) >> 14;
                        soundmul1 <= resize(reverbReadval1, 24); 
                        soundmul2 <= signed(REVERB_vWALL);  
                        
                     when 1 =>
                        -- volmult = (sample * REVERB_vIN) >> 14;
                        soundmul1 <= reverb_sample;              
                        soundmul2 <= signed(REVERB_vIN);  
                        
                     when 2 => 
                        -- wallmult = (value2 * PSXRegs.SPU_REVERB_vWALL) >> 14;     
                        soundmul1 <= resize(reverbReadval2, 24); 
                        soundmul2 <= signed(REVERB_vWALL);                     
                        
                     when 3 =>
                        --IIR_INPUT_A = clamp16((wallmult + volmult) >> 1);
                        -- IIRmultNew = (IIR_INPUT_A * PSXRegs.SPU_REVERB_vIIR) >> 14;                     
                        soundmul1 <= resize(clamp16(shift_right(soundmulresult14 + soundmulresult14_1, 1)), 24);
                        soundmul2 <= signed(REVERB_vIIR);
                     
                     when 4 =>
                        --IIR_INPUT_B = clamp16((wallmult + volmult) >> 1);
                        IIR_INPUT_B <= clamp16(shift_right(soundmulresult14 + soundmulresult14_1, 1));
                        --IIRMultOld = IIASM(PSXRegs.SPU_REVERB_vIIR, value3) >> 14;
                        soundmul2 <= reverbReadval3;
                        if (signed(REVERB_vIIR) = -32768) then
                           if (reverbReadval3 = -32768) then
                              soundmul1 <= (others => '0');
                           else
                              soundmul1 <= to_signed(-65536, 24);
                           end if;
                        else
                           soundmul1 <= to_signed(32768, 24) - resize(signed(REVERB_vIIR), 24);
                        end if;
                        
                     when 5 =>
                        -- IIRmultNew = (IIR_INPUT_B * PSXRegs.SPU_REVERB_vIIR) >> 14;#
                        soundmul1 <= resize(IIR_INPUT_B, 24);
                        soundmul2 <= signed(REVERB_vIIR);
                        
                     when 6 =>
                        -- IIR_A = clamp16((IIRmultNew + IIRMultOld) >> 1);
                        IIR_A <= clamp16(shift_right(soundmulresult14 + soundmulresult14_1, 1));
                        -- IIRMultOld = IIASM(PSXRegs.SPU_REVERB_vIIR, value4) >> 14;
                        soundmul2 <= reverbReadval4;
                        if (signed(REVERB_vIIR) = -32768) then
                           if (reverbReadval4 = -32768) then
                              soundmul1 <= (others => '0');
                           else
                              soundmul1 <= to_signed(-65536, 24);
                           end if;
                        else
                           soundmul1 <= to_signed(32768, 24) - resize(signed(REVERB_vIIR), 24);
                        end if;
                        
                     when 7 => null;
                     
                     when 8 => 
                        -- IIR_B = clamp16((IIRmultNew + IIRMultOld) >> 1);
                        IIR_B <= clamp16(shift_right(soundmulresult14 + soundmulresult14_1, 1));
                     
                        state <= REVERB_WRITE1; 
                        reverb_count <= 0;
                     when others => null;                     
                  end case;
                  end if;
               
               when REVERB_WRITE1 =>
                  if (not NO_REVERB) then
                  if (reverb_count = 0 or ram_done = '1') then
                     reverb_count <= reverb_count + 1;
                     if (reverb_count < 2) then
                        ram_request    <= '1';
                        ram_rnw        <= '0';
                        ram_Adr        <= std_logic_vector(reverb_calcAddr);
                     end if;
                     case (reverb_count) is
                        when 0 => ram_dataWrite <= std_logic_vector(IIR_A); 
                        when 1 => ram_dataWrite <= std_logic_vector(IIR_B); 
                        when 2 => state <= REVERB_READ2; reverb_count <= 0;
                        when others => null;                     
                     end case;
                  end if;
                  end if;
               
               when REVERB_READ2 =>
                  if (reverb_count = 0 or ram_done = '1') then
                     reverb_count <= reverb_count + 1;
                     if (reverb_count < 6) then
                        ram_request    <= '1';
                        ram_rnw        <= '1';
                        ram_Adr        <= std_logic_vector(reverb_calcAddr);
                     end if;
                     if (reverb_count = 6) then
                        state <= REVERB_PROCIN; reverb_count <= 0;
                     end if;
                     if (not NO_REVERB) then
                     case (reverb_count) is
                        when 1 => reverbReadval1 <= signed(ram_dataRead); 
                        when 2 => reverbReadval2 <= signed(ram_dataRead);
                        when 3 => reverbReadval3 <= signed(ram_dataRead);
                        when 4 => reverbReadval4 <= signed(ram_dataRead);
                        when 5 => reverbReadval5 <= signed(ram_dataRead);
                        when 6 => reverbReadval6 <= signed(ram_dataRead);
                        when others => null;                     
                     end case;
                     end if;
                  end if;
                  
                               
                  -- start envelope calculation
                  if (reverb_count = 0) then 
                     envelopeVoice  <= '0';
                     volumeSetting  <= unsigned(VOLUME_LEFT);
                     volumeSettingR <= unsigned(VOLUME_RIGHT);
                     envelopeRight  <= '0';
                     envelopeState  <= ENV_START; 
                  end if;
               
               when REVERB_PROCIN =>
                  reverb_count <= reverb_count + 1;
                  if (NO_REVERB) then
                     if (reverb_count = 12) then
                        reverb_count <= 0;
                        state        <= REVERB_END;
                     end if;
                  else
                  case (reverb_count) is
                     when 0 => 
                        -- acc_mul1 = (valueOut1 * PSXRegs.SPU_REVERB_vCOMB1) >> 14;
                        soundmul1 <= resize(reverbReadval1, 24); 
                        soundmul2 <= signed(REVERB_vCOMB1);  
                        
                     when 1 => 
                        -- acc_mul2 = (valueOut1 * PSXRegs.SPU_REVERB_vCOMB1) >> 14;
                        soundmul1 <= resize(reverbReadval2, 24); 
                        soundmul2 <= signed(REVERB_vCOMB2);  
                        
                     when 2 => 
                        reverb_acc <= resize(soundmulresult14, 20);
                        -- acc_mul3 = (valueOut1 * PSXRegs.SPU_REVERB_vCOMB1) >> 14;
                        soundmul1 <= resize(reverbReadval3, 24); 
                        soundmul2 <= signed(REVERB_vCOMB3);  
                        
                     when 3 => 
                        reverb_acc <= reverb_acc + resize(soundmulresult14, 20);
                        -- acc_mul4 = (valueOut1 * PSXRegs.SPU_REVERB_vCOMB1) >> 14;
                        soundmul1 <= resize(reverbReadval4, 24); 
                        soundmul2 <= signed(REVERB_vCOMB4);  

                     when 4 =>
                        reverb_acc <= reverb_acc + resize(soundmulresult14, 20);
                        -- apf1negMul = (valueOut5 * apf1neg) >> 14;
                        soundmul1 <= resize(reverbReadval5, 24); 
                        soundmul2 <= signed(apf1neg);  
                     
                     when 5 => 
                        reverb_acc <= reverb_acc + resize(soundmulresult14, 20);
                     
                     when 6 =>
                        -- MDA = clamp16((ACC + apf1negMul) >> 1);
                        MDA <= clamp16(shift_right(reverb_acc + soundmulresult14, 1));
                        -- apf2negMul = (valueOut6 * apf2neg) >> 14;
                        soundmul1 <= resize(reverbReadval6, 24); 
                        soundmul2 <= signed(apf2neg);  
                        
                     when 7 =>
                        -- apf1posMul = (MDA * PSXRegs.SPU_REVERB_vAPF1) >> 14;
                        soundmul1 <= resize(MDA, 24); 
                        soundmul2 <= signed(REVERB_vAPF1);  
                        
                     when 8 => null;
                     
                     when 9 =>
                        -- MDB = clamp16(valueOut5 + ((apf1posMul + apf2negMul) >> 1));
                        MDB <= clamp16(resize(reverbReadval5, 26) + shift_right(soundmulresult14 + soundmulresult14_1, 1));

                     when 10 =>
                        -- apf2posMul = (MDB * PSXRegs.SPU_REVERB_vAPF2) >> 15;
                        soundmul1 <= resize(MDB, 24); 
                        soundmul2 <= signed(REVERB_vAPF2); 

                     when 11 => null;

                     when 12 =>
                        -- IVB = clamp16(valueOut6 + apf2posMul);
                        if (reverbRight = '1') then
                           reverbLastRight <= clamp16(resize(reverbReadval6, 25) + soundmulresult15);
                        else
                           reverbLastLeft  <= clamp16(resize(reverbReadval6, 25) + soundmulresult15);
                        end if;
                        
                        reverb_count <= 0;
                        if (cnt(7) = '1' and REVERBOFF = '0') then
                           state <= REVERB_WRITE2;
                        else
                           state <= REVERB_END;
                        end if;
                        
                     when others => null;                     
                  end case;
                  end if;
               
               when REVERB_WRITE2 =>
                  if (not NO_REVERB) then
                  if (reverb_count = 0 or ram_done = '1') then
                     reverb_count <= reverb_count + 1;
                     if (reverb_count < 2) then
                        ram_request    <= '1';
                        ram_rnw        <= '0';
                        ram_Adr        <= std_logic_vector(reverb_calcAddr);
                     end if;
                     case (reverb_count) is
                        when 0 => ram_dataWrite <= std_logic_vector(MDA); 
                        when 1 => ram_dataWrite <= std_logic_vector(MDB); 
                        when 2 => state <= REVERB_END; reverb_count <= 0;
                        when others => null;                     
                     end case;
                  end if;
                  end if;
                  
               when REVERB_END =>
                  reverb_count <= reverb_count + 1;
                  case (reverb_count) is
                     when 0 => 
                        -- left = (reverbLastLeft * PSXRegs.SPU_REVERB_vLOUT) >> 15;
                        if (not NO_REVERB) then
                           soundmul1 <= resize(reverbLastLeft, 24); 
                           soundmul2 <= signed(REVERB_vLOUT); 
                        end if;
                        
                     when 1 =>
                        -- right = (reverbLastRight * PSXRegs.SPU_REVERB_vROUT) >> 15;
                        if (not NO_REVERB) then
                           soundmul1 <= resize(reverbLastRight, 24); 
                           soundmul2 <= signed(REVERB_vROUT); 
                        end if;
                        
                     when 2 =>
                        if (not NO_REVERB and REVERBOFF = '0') then
                           soundleft <= soundleft + resize(soundmulresult15, 24);
                        end if;
                     
                     when 3 =>
                        if (not NO_REVERB and REVERBOFF = '0') then
                           soundright  <= soundright + resize(soundmulresult15, 24);
                        end if;
                        state       <= CAPTURE0;
                        endProcStep <= 0;
                        reverbRight <= not reverbRight;
                        if (reverbRight = '1') then
                           if (reverbCurrentAddress = 16#3FFFF#) then
                              reverbCurrentAddress <= unsigned(REVERB_mBASE) & "00";
                           else
                              reverbCurrentAddress <= reverbCurrentAddress + 1;
                           end if;
                        end if;
                     
                     when others => null; 
                     
                  end case;

               -- CAPTURE
               when CAPTURE0 =>
                  state <= CAPTURE1;
                  ram_request   <= '1';
                  ram_rnw       <= '0';
                  ram_Adr       <= "0000000" & "00" & std_logic_vector(capturePosition);
                  ram_dataWrite <= std_logic_vector(cd_left);  
                  
               when CAPTURE1 =>
                  state <= CAPTURE2;
                  ram_request   <= '1';
                  ram_rnw       <= '0';
                  ram_Adr       <= "0000000" & "01" & std_logic_vector(capturePosition);
                  ram_dataWrite <= std_logic_vector(cd_right); 
                  
                  -- noise
                  case (CNT(9 downto 8)) is
                     when "01" => noiseCnt <= noiseCnt + 84;
                     when "10" => noiseCnt <= noiseCnt + 140;
                     when "11" => noiseCnt <= noiseCnt + 180;
                     when others => null;
                  end case;
               
               when CAPTURE2 =>
                  state <= CAPTURE3;
                  ram_request   <= '1';
                  ram_rnw       <= '0';
                  ram_Adr       <= "0000000" & "10" & std_logic_vector(capturePosition);
                  ram_dataWrite <= std_logic_vector(voice_lastVolume1);  

                  -- noise
                  if (noiseCnt(15 downto 0) >= 210) then
                     noiseCnt <= noiseCnt + 16#20000# - 210;
                  else
                     noiseCnt <= noiseCnt + 16#10000#;
                  end if;                  
               
               when CAPTURE3 =>
                  capturePosition <= capturePosition + 2;
                  state           <= IDLE;
               
                  ram_request   <= '1';
                  ram_rnw       <= '0';
                  ram_Adr       <= "0000000" & "11" & std_logic_vector(capturePosition);
                  ram_dataWrite <= std_logic_vector(voice_lastVolume3); 
                  
                  -- updateNoise
                  --CNT(13 downto 8) <= std_logic_vector(unsigned(CNT(13 downto 8)) + 1); -- autotest, never synthesize!
                  
                  if (noiseCnt >= noiseCheck) then
                     noiseCnt   <= noiseCnt and (noiseCheck - 1);
                     noiseLevel <= noiseLevel(14 downto 0) & (noiseLevel(15) xor noiseLevel(12) xor noiseLevel(11) xor noiseLevel(10) xor '1');
                  end if;
                  
            end case;

            busy <= '0';
            if (CNT(5 downto 4) = "10" and FifoIn_Empty = '0') then
               busy <= '1';
            end if;
            if (CNT(5 downto 4) = "11" and FifoOut_NearFull = '0') then
               busy <= '1';
            end if;
            
            -- cd sound processing
            if (NO_REVERB and DIRECT_MUL) then
               -- no shared multiplier: the products are formed in the clock that used to load it
               case (cdProcStep) is
                  when 0 => cd_next_left  <= resize(shift_right(cd_left  * signed(CDAUDIO_VOL_L), 15), 17);
                  when 1 => cd_next_right <= resize(shift_right(cd_right * signed(CDAUDIO_VOL_R), 15), 17);
                  when others => null;
               end case;
            else
            case (cdProcStep) is
               when 0 =>
                  soundmul1 <= resize(cd_left, 24);
                  soundmul2 <= signed(CDAUDIO_VOL_L);
                  
               when 1 =>
                  soundmul1 <= resize(cd_right, 24);
                  soundmul2 <= signed(CDAUDIO_VOL_R); 
                  
               when 2 =>
                  cd_next_left <= resize(soundmulresult15, 17);
               
               when 3 =>
                  cd_next_right <= resize(soundmulresult15, 17);
               
               when others => null;
            end case;
            end if;
            if (cdProcStep < 4) then
               cdProcStep <= cdProcStep + 1;
            end if; 
            
            -- sound end processing
            if (NO_REVERB and DIRECT_MUL) then
               case (endProcStep) is
                  when 2 => sound_out_left  <= std_logic_vector(clamp16(shift_right(soundleft  * signed(CURVOL_L), 15)));
                  when 3 => sound_out_right <= std_logic_vector(clamp16(shift_right(soundright * signed(CURVOL_R), 15)));
                  when others => null;
               end case;
            else
            case (endProcStep) is
               when 0 =>
                  soundmul1 <= soundleft;
                  soundmul2 <= signed(CURVOL_L);
                  
               when 1 =>
                  soundmul1 <= soundright;
                  soundmul2 <= signed(CURVOL_R); 
                  
               when 2 =>
                  if (soundmulresult15 < -32768) then sound_out_left <= x"8000";
                  elsif (soundmulresult15 > 32767) then sound_out_left <= x"7FFF";
                  else sound_out_left <= std_logic_vector(soundmulresult15(15 downto 0));
                  end if;
               
               when 3 =>
                  if (soundmulresult15 < -32768) then sound_out_right <= x"8000";
                  elsif (soundmulresult15 > 32767) then sound_out_right <= x"7FFF";
                  else sound_out_right <= std_logic_vector(soundmulresult15(15 downto 0));
                  end if;
               
               when others => null;
            end case;
            end if;
            if (endProcStep < 4) then
               endProcStep <= endProcStep + 1;
            end if; 
            
            if (not (NO_REVERB and DIRECT_MUL)) then
               soundmulresult := soundmul1 * soundmul2;
               soundmulresult14 <= resize(shift_right(soundmulresult, 14), 26);  
               soundmulresult15 <= resize(shift_right(soundmulresult, 15), 25);  
               
               soundmulresult14_1 <= soundmulresult14;
            end if;

         end if; -- ce
         
         if (dma_write = '1' and ce = '1') then
            if (FifoIn_Full = '0') then
               FifoIn_Wr  <= '1';
               FifoIn_Din <= dma_writedata;
            end if;
         end if;
         
      end if;
   end process;
   
--##############################################################
--############################### ADPCM decode and the write port of the sample RAMs
--##############################################################

   -- read address of the four sample RAMs: the 4-sample window of the current position, then the last row for the copy back
   gadpcmr : for i in 0 to 3 generate
   begin
      adpcm_ram_address_b(i) <= to_unsigned(index, 5) & "111" when (state = VOICE_APPLYVOLUME or state = VOICE_CHECKEND) else
                                to_unsigned(index, 5) & (voice.adpcmSamplePos(16 downto 14) + 1)
                                   when (voice.adpcmSamplePos(13 downto 12) > i and i < 3) else
                                to_unsigned(index, 5) & voice.adpcmSamplePos(16 downto 14);
   end generate;

   gdec : block
      signal nib   : signed(3 downto 0);
      signal d0    : signed(15 downto 0);
      signal d1    : signed(17 downto 0);
      signal d2    : signed(17 downto 0);
      signal dsum  : signed(19 downto 0);
   begin
      nib   <= signed(adpcmData( 3 downto  0)) when (decodeCnt = 0) else
               signed(adpcmData( 7 downto  4)) when (decodeCnt = 1) else
               signed(adpcmData(11 downto  8)) when (decodeCnt = 2) else
               signed(adpcmData(15 downto 12));
      d0    <= shift_right(nib & x"000", to_integer(adpcmShift));
      d1    <= resize(shift_right(voice.adpcmLast0 * filtertablePos(to_integer(adpcmFilter)), 6), 18);
      d2    <= resize(shift_right(voice.adpcmLast1 * filtertableNeg(to_integer(adpcmFilter)), 6), 18);
      dsum  <= resize(d0, 20) + resize(d1, 20) + resize(d2, 20);
      adpcm_res <= x"8000" when (dsum < -32768) else
                   x"7FFF" when (dsum > 32767) else
                   dsum(15 downto 0);
   end block;

   adpcm_wr_dec  <= '1' when (state = VOICE_DECODESAMPLE and ce = '1' and reset = '0') else '0';
   adpcm_wr_copy <= '1' when (state = VOICE_CHECKEND and ce = '1' and reset = '0' and bus_write = '0' and voice.adpcmSamplePos(19 downto 12) >= 28) else '0';
   adpcm_wr_key  <= '1' when (state = VOICE_CHECKKEY and ce = '1' and reset = '0' and KEYON(index) = '1') else '0';

   adpcm_ram_address_a <= to_unsigned(index, 5) & voice.adpcmDecodePtr(4 downto 2)       when (adpcm_wr_dec = '1' and decodeCnt = 0) else
                          to_unsigned(index, 5) & (voice.adpcmDecodePtr(4 downto 2) + 1) when (adpcm_wr_dec = '1') else
                          to_unsigned(index, 5) & "000"                                  when (adpcm_wr_copy = '1' or adpcm_wr_key = '1') else
                          RamVoice_addrA;

   gadpcmw : for i in 0 to 3 generate
   begin
      adpcm_ram_data_a(i) <= std_logic_vector(adpcm_res) when (adpcm_wr_dec = '1') else
                             adpcm_ram_q_b(i)            when (adpcm_wr_copy = '1') else
                             (others => '0');
      adpcm_ram_wren_a(i) <= '1' when (adpcm_wr_dec = '1' and ((decodeCnt + 3) mod 4) = i) else
                             '1' when ((adpcm_wr_copy = '1' or adpcm_wr_key = '1') and i < 3) else
                             '0' when (adpcm_wr_dec = '1' or adpcm_wr_copy = '1' or adpcm_wr_key = '1') else
                             ss_voice_loading;
   end generate;

--##############################################################
--############################### ADSR
--##############################################################

   adsr_ph <= ADSRPHASE_DECAY   when (state = VOICE_APPLYVOLUME and voice.adsrphase = ADSRPHASE_ATTACK) else
              ADSRPHASE_SUSTAIN when (state = VOICE_APPLYVOLUME and voice.adsrphase = ADSRPHASE_DECAY)  else
              ADSRPHASE_OFF     when (state = VOICE_APPLYVOLUME) else
              ADSRPHASE_ATTACK  when (state = VOICE_CHECKKEY and KEYON(index) = '1') else
              ADSRPHASE_RELEASE when (state = VOICE_CHECKKEY) else
              voice.adsrphase;

   adsr_r <= adsrSetting(14 downto 8)                    when (adsr_ph = ADSRPHASE_ATTACK)  else
             '0' & adsrSetting(7 downto 4) & "00"        when (adsr_ph = ADSRPHASE_DECAY)   else
             adsrSetting(28 downto 22)                   when (adsr_ph = ADSRPHASE_SUSTAIN) else
             adsrSetting(20 downto 16) & "00"            when (adsr_ph = ADSRPHASE_RELEASE) else
             (others => '0');

   adsr_d <= '0'               when (adsr_ph = ADSRPHASE_ATTACK)  else
             adsrSetting(30)   when (adsr_ph = ADSRPHASE_SUSTAIN) else
             '1';

   adsr_e <= adsrSetting(15)   when (adsr_ph = ADSRPHASE_ATTACK)  else
             adsrSetting(31)   when (adsr_ph = ADSRPHASE_SUSTAIN) else
             adsrSetting(21)   when (adsr_ph = ADSRPHASE_RELEASE) else
             '1'               when (adsr_ph = ADSRPHASE_DECAY)   else
             '0';

   adsr_tk <= (to_unsigned(1, 21) sll to_integer(adsr_r(6 downto 2)) - 11) when (adsr_r >= 48) else to_unsigned(1, 21);

   adsr_st <= adsr_step_f(adsr_r, adsr_d);

   chanLeft  <= resize(shift_right(volume *  volLeft, 15), 18);
   chanRight <= resize(shift_right(volume * volRight, 15), 18);

   voice_lastVolume <= x"8000" when (volume < -32768) else
                       x"7FFF" when (volume > 32767) else
                       volume(15 downto 0);

   env_step <= adsr_step_f(unsigned(volumeSetting(6 downto 0)), volumeSetting(13));

   adsr_dec_cur <= '0' when (voice.adsrphase = ADSRPHASE_ATTACK) else '1';

   adsr_target  <= (others => '1')                                      when (voice.adsrphase = ADSRPHASE_ATTACK) else
                   (others => '1')                                      when (voice.adsrphase = ADSRPHASE_DECAY and adsrSetting(3 downto 0) = "1111") else
                   (adsrSetting(3 downto 0) + 1) & "00000000000"        when (voice.adsrphase = ADSRPHASE_DECAY) else
                   (others => '0');

     
--##############################################################
--############################### REVERB
--##############################################################  
  
   gRevRegs : if not NO_REVERB generate
   REVERB_mSAME  <= unsigned(REVERB_mLSAME ) when (reverbRight = '0') else unsigned(REVERB_mRSAME );
   REVERB_mCOMB1 <= unsigned(REVERB_mLCOMB1) when (reverbRight = '0') else unsigned(REVERB_mRCOMB1);
   REVERB_mCOMB2 <= unsigned(REVERB_mLCOMB2) when (reverbRight = '0') else unsigned(REVERB_mRCOMB2);
   REVERB_dSAME  <= unsigned(REVERB_dLSAME ) when (reverbRight = '0') else unsigned(REVERB_dRSAME );
   REVERB_mDIFF  <= unsigned(REVERB_mLDIFF ) when (reverbRight = '0') else unsigned(REVERB_mRDIFF );
   REVERB_mCOMB3 <= unsigned(REVERB_mLCOMB3) when (reverbRight = '0') else unsigned(REVERB_mRCOMB3);
   REVERB_mCOMB4 <= unsigned(REVERB_mLCOMB4) when (reverbRight = '0') else unsigned(REVERB_mRCOMB4);
   REVERB_dDIFF  <= unsigned(REVERB_dRDIFF ) when (reverbRight = '0') else unsigned(REVERB_dLDIFF );
   REVERB_mAPF1  <= unsigned(REVERB_mLAPF1 ) when (reverbRight = '0') else unsigned(REVERB_mRAPF1 );
   REVERB_mAPF2  <= unsigned(REVERB_mLAPF2 ) when (reverbRight = '0') else unsigned(REVERB_mRAPF2 );
   REVERB_vIN    <=   signed(REVERB_vLIN   ) when (reverbRight = '0') else   signed(REVERB_vRIN   );
   -- Feed the reverb core from the lightweight 5-tap low-pass output.
   reverb_sample <= resize(reverbDownLeft, 24) when (reverbRight = '0') else resize(reverbDownRight, 24);
   
   apf1neg <= x"7FFF" when (REVERB_vAPF1 = x"8000") else (to_signed(0, 16) - signed(REVERB_vAPF1));
   apf2neg <= x"7FFF" when (REVERB_vAPF2 = x"8000") else (to_signed(0, 16) - signed(REVERB_vAPF2));
   
   reverb_reqAddr  <= REVERB_dSAME                            when (state = REVERB_READ1  and reverb_count = 0) else
                      REVERB_dDIFF                            when (state = REVERB_READ1  and reverb_count = 1) else
                      REVERB_mSAME                            when (state = REVERB_READ1  and reverb_count = 2) else
                      REVERB_mDIFF                            when (state = REVERB_READ1  and reverb_count = 3) else
                      REVERB_mSAME                            when (state = REVERB_WRITE1 and reverb_count = 0) else
                      REVERB_mDIFF                            when (state = REVERB_WRITE1 and reverb_count = 1) else
                      REVERB_mCOMB1                           when (state = REVERB_READ2  and reverb_count = 0) else
                      REVERB_mCOMB2                           when (state = REVERB_READ2  and reverb_count = 1) else
                      REVERB_mCOMB3                           when (state = REVERB_READ2  and reverb_count = 2) else
                      REVERB_mCOMB4                           when (state = REVERB_READ2  and reverb_count = 3) else
                      (REVERB_mAPF1 - unsigned(REVERB_dAPF1)) when (state = REVERB_READ2  and reverb_count = 4) else
                      (REVERB_mAPF2 - unsigned(REVERB_dAPF2)) when (state = REVERB_READ2  and reverb_count = 5) else
                      REVERB_mAPF1                            when (state = REVERB_WRITE2 and reverb_count = 0) else
                      REVERB_mAPF2;
                 
   end generate;

   -- NO_REVERB: only the READ2 request addresses are formed; the coefficients come from the global registers
   gram_hi <= to_unsigned(1, 6) when (index >= 16) else to_unsigned(0, 6);
   pmon_bit <= GRAM_dataB(1)(index mod 16);
   non_bit  <= GRAM_dataB(1)(index mod 16);

   gRevNo : if not NO_REVERB generate
   begin
      GRAM_addrB(1) <= to_unsigned(8, 6) + gram_hi  when (state = VOICE_APPLYADSR) else
                       to_unsigned(10, 6) + gram_hi;
      GRAM_addrB(2) <= (others => '0');
   end generate;

   gRevRam : if NO_REVERB generate
      signal base5 : unsigned(4 downto 0);
   begin
      base5 <= to_unsigned(22, 5) when (reverb_count = 0) else
               to_unsigned(23, 5) when (reverb_count = 1) else
               to_unsigned(26, 5) when (reverb_count = 2) else
               to_unsigned(27, 5) when (reverb_count = 3) else
               to_unsigned(29, 5) when (reverb_count = 4) else
               to_unsigned(30, 5);
      GRAM_addrB(1) <= to_unsigned(8, 6) + gram_hi  when (state = VOICE_APPLYADSR) else
                       to_unsigned(10, 6) + gram_hi when (state = VOICE_PICKSAMPLE or state = VOICE_CHECKEND) else
                       base5 & reverbRight;
      GRAM_addrB(2) <= to_unsigned(32, 6) when (reverb_count = 4) else to_unsigned(33, 6);
      reverb_reqAddr <= unsigned(GRAM_dataB(1)) when (reverb_count < 4) else (unsigned(GRAM_dataB(1)) - unsigned(GRAM_dataB(2)));
   end generate;

   reverb_reqAddr2 <= ((reverb_reqAddr & "00") - 1) when (state = REVERB_READ1 and (reverb_count = 2 or reverb_count = 3)) else
                      (reverb_reqAddr & "00");                    
                 
   reverbAddAddr   <= ('0' & reverb_reqAddr2) + ('0' & reverbCurrentAddress);
   
   reverb_calcAddr <= resize(reverbAddAddr + (unsigned(REVERB_mBASE) & "00"), 18) & '0' when (reverbAddAddr(18) = '1') else resize(reverbAddAddr, 18) & '0';
   
--##############################################################
--############################### RAM IF
--##############################################################
   
   SS_RAM_dataRead   <= (others => '0');
   SS_RAM_done       <= '0';
   SS_DataRead       <= (others => '0');
   mem_request       <= '0';
   mem_BURSTCNT      <= (others => '0');
   mem_ADDR          <= (others => '0');
   mem_DIN           <= (others => '0');
   mem_BE            <= (others => '0');
   mem_WE            <= '0';
   mem_RD            <= '0';

   ispu_ram : entity work.spu_pocket_ram
   generic map (L1_CACHE => L1_CACHE)
   port map
   (
      clk1x                => clk1x,
      reset                => reset,
      ram_dataWrite        => ram_dataWrite,
      ram_Adr              => ram_Adr,
      ram_request          => ram_request,
      ram_rnw              => ram_rnw,
      ram_dataRead         => ram_dataRead,
      ram_done             => ram_done,
      ram_isVoice          => ram_isVoice,
      ram_VoiceIndex       => index,
      sdram_dataWrite      => sdram_dataWrite,
      sdram_Adr            => sdram_Adr,
      sdram_be             => sdram_be,
      sdram_rnw            => sdram_rnw,
      sdram_ena            => sdram_ena,
      sdram_dataRead       => sdram_dataRead,
      sdram_done           => sdram_done
   );
   
   
--##############################################################
--############################### savestates
--##############################################################

   process (clk1x)
   begin
      if (rising_edge(clk1x)) then
         
         SS_idle <= '0';
         if ((FifoIn_Empty = '1' or ss_timeout(13) = '1') and (FifoOut_Empty = '1' or ss_timeout(13) = '1') and state = IDLE and sampleticks < 760 and sampleticks > 0 and stashedSamples = 0) then
            SS_idle    <= '1';
         end if;
         
         if (FifoIn_Empty = '1' and FifoOut_Empty = '1') then
            ss_timeout <= (others => '0');
         elsif (spu_tick = '1' and ss_timeout(13) = '0') then
            ss_timeout <= ss_timeout + 1;
         end if;
         
      
      end if;
   end process;



end architecture;





