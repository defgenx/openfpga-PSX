# Run from this directory after ports.py: python3 ports.py && python3 gen_stub.py && python3 gen_inst.py && python3 gen_flat.py
# ports.py reads the entity of rtl/psx_top_pocket.vhd; gen_stub.py writes psx_top_stub.v, gen_flat.py psx_top_pocket_flat.vhd,
# gen_inst.py the stub instance and glue wiring that core_top.v carries (copy the output by hand).
import json,re
P=json.load(open('ports_t.json'))
fields=['PadPortEnable','PadPortDigital','PadPortAnalog','PadPortMouse','PadPortGunCon','PadPortNeGcon','PadPortJustif','PadPortDS','PadPortStick','PadPortPopn','WheelMap','ToggleDS',
'KeyTriangle','KeyCircle','KeyCross','KeySquare','KeySelect','KeyStart','KeyRight','KeyLeft','KeyUp','KeyDown','KeyR1','KeyR2','KeyR3','KeyL1','KeyL2','KeyL3']
def width(t):
    m=re.search(r'\(\s*(\d+)\s+downto\s+(\d+)\s*\)',t)
    return int(m.group(1))-int(m.group(2))+1 if m else 1
def flat(t):
    if t=='std_logic': return 'std_logic'
    if t=='joypad_t': return 'std_logic_vector(59 downto 0)'
    if t.startswith('integer'): return 'std_logic_vector(1 downto 0)'
    m=re.search(r'\(\s*(\d+)\s+downto\s+(\d+)\s*\)',t)
    return f'std_logic_vector({m.group(1)} downto {m.group(2)})'
o=[]
a=o.append
a("""-- psx_top_pocket with flat ports: the VHDL record joypad_t, the integer savestate_number and the signed/unsigned ports
-- become std_logic_vector, so a Verilog parent can instantiate it. Same port names and widths as the Verilog stub
-- psx_top_stub.v. joypadN packs the record, first field in the MSB: PadPort{Enable,Digital,Analog,Mouse,GunCon,NeGcon,
-- Justif,DS,Stick,Popn}, WheelMap, ToggleDS, Key{Triangle,Circle,Cross,Square,Select,Start,Right,Left,Up,Down,R1,R2,R3,L1,L2,L3},
-- Analog1X, Analog1Y, Analog2X, Analog2Y.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.pJoypad.all;

entity psx_top_pocket_flat is
   generic
   (
      is_simu               : std_logic := '0';
      NO_MDEC               : boolean   := false;
      G_GPU_IMPL            : string    := "pocket";
      G_CPU_IMPL            : string    := "golden";
      G_SPU_IMPL            : string    := "golden";
      G_CD_IMPL             : string    := "golden";
      G_DMA_IMPL            : string    := "golden";
      G_BUS_IMPL            : string    := "golden";
      G_JOYPAD_IMPL         : string    := "golden";
      G_MEMCARD_IMPL        : string    := "golden";
      G_MDEC_IMPL           : string    := "golden"
   );
   port
   (""")
a(";\n".join(f"      {n:<22}: {'in ' if d=='in' else 'out'} {flat(t)}" for n,d,t in P))
a("""   );
end entity;

architecture arch of psx_top_pocket_flat is

   function to_joypad(v : std_logic_vector(59 downto 0)) return joypad_t is
      variable j : joypad_t;
   begin""")
for i,f in enumerate(fields):
    a(f"      j.{f} := v({59-i});")
a("""      j.Analog1X := signed(v(31 downto 24));
      j.Analog1Y := signed(v(23 downto 16));
      j.Analog2X := signed(v(15 downto 8));
      j.Analog2Y := signed(v(7 downto 0));
      return j;
   end function;
""")
conv_in={'unsigned':lambda n:f"unsigned({n})",'signed':lambda n:f"signed({n})"}
a("   signal core_Cheats_BusAddr : std_logic_vector(20 downto 0);\n   signal core_DisplayWidth : unsigned(10 downto 0);\n   signal core_DisplayHeight : unsigned(9 downto 0);\n   signal core_DisplayOffsetX : unsigned(9 downto 0);\n   signal core_DisplayOffsetY : unsigned(8 downto 0);\n   signal core_exe : std_logic;\nbegin")
a("   core : entity work.psx_top_pocket")
a("      generic map (is_simu => is_simu, NO_MDEC => NO_MDEC, G_GPU_IMPL => G_GPU_IMPL, G_CPU_IMPL => G_CPU_IMPL, G_SPU_IMPL => G_SPU_IMPL,\n                   G_CD_IMPL => G_CD_IMPL, G_DMA_IMPL => G_DMA_IMPL, G_BUS_IMPL => G_BUS_IMPL, G_JOYPAD_IMPL => G_JOYPAD_IMPL,\n                   G_MEMCARD_IMPL => G_MEMCARD_IMPL, G_MDEC_IMPL => G_MDEC_IMPL)")
a("      port map (")
pm=[]
for n,d,t in P:
    if t=='joypad_t': pm.append(f"         {n} => to_joypad({n})")
    elif t.startswith('integer'): pm.append(f"         {n} => to_integer(unsigned({n}))")
    elif t.startswith('unsigned') and d=='in': pm.append(f"         {n} => unsigned({n})")
    elif t.startswith('signed') and d=='in': pm.append(f"         {n} => signed({n})")
    elif t.startswith(('unsigned','signed')) and d=='out': pm.append(f"         {n} => core_{n}")
    elif n=='Cheats_BusAddr': pm.append(f"         {n} => core_{n}")
    else: pm.append(f"         {n} => {n}")
a(",\n".join(pm)+");")
a("   Cheats_BusAddr <= core_Cheats_BusAddr;")
for n,d,t in P:
    if d=='out' and t.startswith(('unsigned','signed')): a(f"   {n} <= std_logic_vector(core_{n});")
a("end architecture;")
s="\n".join(o)+"\n"
s=s.replace("   signal core_exe : std_logic;\n","")
open('psx_top_pocket_flat.vhd','w').write(s)
