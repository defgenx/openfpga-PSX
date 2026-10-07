-- Micro-word layout, source codes and busy table of gte_serial.
-- Owning doc: docs/pocket/GTE.md ("Sequencer and micro-op format").
-- rtl/gen/gte_ucode.py mirrors every constant here: change both together.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

package gte_serial_pkg is

   constant UW : integer := 97;  -- micro-word width

   -- read port p (p = 0, 1) at RD_BASE(p)
   constant RD0_LSB : integer := 0;
   constant RD1_LSB : integer := 12;
   constant RD_EN   : integer := 0;   -- offsets inside a read-port field
   constant RD_BASE : integer := 1;   -- 2 bits
   constant RD_OFF  : integer := 3;   -- 6 bits
   constant RD_DST  : integer := 9;   -- 3 bits
   constant RD_W    : integer := 12;

   constant BASE_ABS : integer := 0;
   constant BASE_MAT : integer := 1;
   constant BASE_VEC : integer := 2;
   constant BASE_TRV : integer := 3;

   -- lane L at LA_LSB / LB_LSB
   constant LA_LSB  : integer := 24;
   constant LB_LSB  : integer := 55;
   constant L_V     : integer := 0;
   constant L_M0    : integer := 1;
   constant L_ROW   : integer := 2;   -- 2 bits
   constant L_ASEL  : integer := 4;   -- 6 bits
   constant L_BSEL  : integer := 10;  -- 6 bits
   constant L_XS    : integer := 16;
   constant L_SSEL  : integer := 17;  -- 4 bits
   constant L_K     : integer := 21;  -- 2 bits
   constant L_ADD   : integer := 23;  -- 3 bits
   constant L_SUB   : integer := 26;
   constant L_SWAP  : integer := 27;
   constant L_WB    : integer := 28;  -- 3 bits
   constant L_W     : integer := 31;

   -- side effects
   constant SE_RGB   : integer := 86;
   constant SE_OTZ   : integer := 87;
   constant SE_SZ    : integer := 88;
   constant SE_HSLOT : integer := 89;  -- 3 bits
   constant SE_SXY   : integer := 92;
   constant SE_SNAP  : integer := 93;  -- 2 bits: 0 none, 1 slot 0, 2 slot 1
   constant SE_VSNAP : integer := 95;
   constant W_HALT   : integer := 96;

   -- k codes
   constant K_0    : integer := 0;
   constant K_4    : integer := 1;
   constant K_12   : integer := 2;
   constant K_SF12 : integer := 3;   -- sf ? 12 : 0

   -- addend codes
   constant ADD_ZERO    : integer := 0;
   constant ADD_ACC     : integer := 1;
   constant ADD_MACLAST : integer := 2;
   constant ADD_S       : integer := 3;
   constant ADD_S_SH12  : integer := 4;

   -- MAC1-3 writeback modes (MAC0: bit 0 useIR with IRshift, bit 1 checkOvf)
   constant WB_NONE  : integer := 0;
   constant WB_STD   : integer := 1;
   constant WB_RTP3  : integer := 2;
   constant WB_FC    : integer := 3;
   constant WB_MVBUG : integer := 4;

   -- A sources (18-bit signed); 1..16 = staging slot s half h: 1 + 2*s + h, sign-extended
   constant A_ZERO     : integer := 0;
   constant A_IR1      : integer := 17;
   constant A_IR2      : integer := 18;
   constant A_IR3      : integer := 19;
   constant A_IR0      : integer := 20;
   constant A_SX0      : integer := 21;  -- SX1, SX2 follow
   constant A_SZ0      : integer := 24;  -- SZ1..SZ3 follow, zero-extended
   constant A_RGBC_R   : integer := 28;  -- G, B follow, zero-extended
   constant A_RGB0_R   : integer := 31;  -- G, B follow, zero-extended
   constant A_RSH4     : integer := 34;  -- +(RGBC R << 4)
   constant A_RSH4_NEG : integer := 35;  -- -(RGBC R << 4)
   constant A_SNAP1_0  : integer := 36;  -- snap IR1 slot 0, slot 1
   constant A_SNAP2_0  : integer := 38;  -- snap IR2 slot 0, slot 1

   -- B sources (19-bit signed); 1..16 = staging halves as for A
   constant B_ZERO   : integer := 0;
   constant B_IR1    : integer := 17;
   constant B_IR2    : integer := 18;
   constant B_IR3    : integer := 19;
   constant B_IR0    : integer := 20;
   constant B_RGBC_R : integer := 21;  -- G, B follow, zero-extended
   constant B_VSNAP0 : integer := 24;  -- vsnap 1, 2 follow
   constant B_DIV    : integer := 27;  -- div_result, zero-extended 17 bits
   constant B_SY0    : integer := 28;  -- SY1, SY2 follow
   constant B_C1000  : integer := 31;
   constant B_C10000 : integer := 32;

   -- S sources (32-bit); 1..8 = staging slot 0..7
   constant S_ZERO : integer := 0;
   constant S_MAC1 : integer := 9;   -- MAC2, MAC3 follow

   -- golden CALC-state edges per opcode, 0 = no program (gte.vhd:576-607)
   function busy_edges(op : unsigned(5 downto 0)) return integer;

end package;

package body gte_serial_pkg is

   function busy_edges(op : unsigned(5 downto 0)) return integer is
   begin
      case to_integer(op) is
         when 16#01# => return 26;  -- RTPS
         when 16#06# => return 12;  -- NCLIP
         when 16#0C# => return 8;   -- OP
         when 16#10# => return 11;  -- DPCS
         when 16#11# => return 11;  -- INTPL
         when 16#12# => return 11;  -- MVMVA
         when 16#13# => return 34;  -- NCDS
         when 16#14# => return 21;  -- CDP
         when 16#16# => return 84;  -- NCDT
         when 16#1B# => return 30;  -- NCCS
         when 16#1C# => return 17;  -- CC
         when 16#1E# => return 23;  -- NCS
         when 16#20# => return 55;  -- NCT
         when 16#28# => return 6;   -- SQR
         when 16#29# => return 11;  -- DPCL
         when 16#2A# => return 29;  -- DPCT
         when 16#2D# => return 6;   -- AVSZ3
         when 16#2E# => return 8;   -- AVSZ4
         when 16#30# => return 42;  -- RTPT
         when 16#3D# => return 5;   -- GPF
         when 16#3E# => return 6;   -- GPL
         when 16#3F# => return 74;  -- NCCT
         when others => return 0;
      end case;
   end function;

end package body;
