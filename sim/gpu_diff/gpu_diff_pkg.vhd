library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

package gpu_diff_pkg is

   -- Option inputs of gpu / gpu_pocket. The tb fills one constant of this type (the TIE-OFF block).
   type t_gpu_opts is record
      ditherOff             : std_logic;
      interlaced480pHack    : std_logic;
      REPRODUCIBLEGPUTIMING : std_logic;
      videoout_on           : std_logic;
      isPal                 : std_logic;
      pal60                 : std_logic;
      fpscountOn            : std_logic;
      noTexture             : std_logic;
      textureFilter         : std_logic_vector(1 downto 0);
      textureFilterStrength : std_logic_vector(1 downto 0);
      textureFilter2DOff    : std_logic;
      dither24              : std_logic;
      render24              : std_logic;
      drawSlow              : std_logic;
      debugmodeOn           : std_logic;
      syncVideoOut          : std_logic;
      syncInterlace         : std_logic;
      rotate180             : std_logic;
      fixedVBlank           : std_logic;
      vCrop                 : std_logic_vector(1 downto 0);
      hCrop                 : std_logic;
      oldGPU                : std_logic;
      Gun1CrosshairOn       : std_logic;
      Gun2CrosshairOn       : std_logic;
      cdSlow                : std_logic;
      errorOn               : std_logic;
      errorEna              : std_logic;
      LBAOn                 : std_logic;
   end record;

   -- one accepted VRAM write
   type t_vwrite is record
      addr  : std_logic_vector(27 downto 0);
      data  : std_logic_vector(63 downto 0);
      be    : std_logic_vector(7 downto 0);
      burst : std_logic_vector(7 downto 0);
      prim  : integer;
      op    : integer;
      cyc   : integer;
   end record;

   -- FIFO of captured writes: one producer process, one consumer process
   type t_wqueue is protected
      procedure push(v : t_vwrite);
      impure function empty return boolean;
      impure function peek return t_vwrite;
      procedure pop;
      impure function count return integer;
      impure function pushed return integer;
   end protected;

end package;

package body gpu_diff_pkg is

   type t_wqueue is protected body
      constant CAP : integer := 65536;
      type t_arr is array (0 to CAP - 1) of t_vwrite;
      variable buf  : t_arr;
      variable head : integer := 0;
      variable tail : integer := 0;
      variable n    : integer := 0;
      variable tot  : integer := 0;

      procedure push(v : t_vwrite) is
      begin
         assert n < CAP report "write queue overflow" severity failure;
         buf(tail) := v;
         tail := (tail + 1) mod CAP;
         n    := n + 1;
         tot  := tot + 1;
      end procedure;

      impure function empty return boolean is
      begin
         return n = 0;
      end function;

      impure function peek return t_vwrite is
      begin
         return buf(head);
      end function;

      procedure pop is
      begin
         head := (head + 1) mod CAP;
         n    := n - 1;
      end procedure;

      impure function count return integer is
      begin
         return n;
      end function;

      impure function pushed return integer is
      begin
         return tot;
      end function;
   end protected body;

end package body;
