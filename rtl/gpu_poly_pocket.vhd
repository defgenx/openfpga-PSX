library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all; 

library mem;

use work.pGPU.all;
use work.pGPU_pocket.all;

-- Polygon unit of gpu_pocket: gpu_poly with two shared dividers, 20-bit interpolators and
-- time-shared multipliers. Design and exactness arguments: docs/pocket/GPU.md "Polygon unit".

entity gpu_poly_pocket is
   port 
   (
      clk2x                : in  std_logic;
      clk2xIndex           : in  std_logic;
      ce                   : in  std_logic;
      reset                : in  std_logic;
      
      REPRODUCIBLEGPUTIMING: in  std_logic;
      textureFilter        : in  std_logic_vector(1 downto 0);
      textureFilterStrength: in  std_logic_vector(1 downto 0);
      textureFilter2DOff   : in  std_logic;
      
      error                : out std_logic;
      
      DrawPixelsMask       : in  std_logic;
      interlacedDrawing    : in  std_logic;
      activeLineLSB        : in  std_logic;
      drawingOffsetX       : in  signed(10 downto 0);
      drawingOffsetY       : in  signed(10 downto 0);
      drawingAreaLeft      : in  unsigned(9 downto 0);
      drawingAreaRight     : in  unsigned(9 downto 0);
      drawingAreaTop       : in  unsigned(8 downto 0);
      drawingAreaBottom    : in  unsigned(8 downto 0);
      
      drawModeRec          : out unsigned(11 downto 0);
      drawModeNew          : out std_logic := '0';
      drawmode_dithering   : in  std_logic := '0';
      
      divE_req             : out tdiv_req;
      divE_rsp             : in  tdiv_rsp;
      divG_req             : out tdiv_req;
      divG_rsp             : in  tdiv_rsp;
      slot0_prev           : in  std_logic;
      slot0_upd            : out std_logic := '0';
      slot0_val            : out std_logic := '0';
      
      fifoOut_idle         : in  std_logic;
      pipeline_busy        : in  std_logic;
      pipeline_stall       : in  std_logic;
      pipeline_new         : out std_logic;
      pipeline_texture     : out std_logic;
      pipeline_transparent : out std_logic;
      pipeline_rawTexture  : out std_logic;
      pipeline_dithering   : out std_logic;
      pipeline_x           : out unsigned(9 downto 0);
      pipeline_y           : out unsigned(8 downto 0);
      pipeline_cr          : out unsigned(7 downto 0);
      pipeline_cg          : out unsigned(7 downto 0);
      pipeline_cb          : out unsigned(7 downto 0);
      pipeline_u           : out unsigned(7 downto 0);
      pipeline_v           : out unsigned(7 downto 0);
      
      proc_idle            : in  std_logic;
      fifo_Valid           : in  std_logic;
      fifo_data            : in  std_logic_vector(31 downto 0);
      requestFifo          : out std_logic := '0';
      done                 : out std_logic := '0';
      CmdDone              : out std_logic := '0';
      
      requestVRAMEnable    : out std_logic;
      requestVRAMXPos      : out unsigned(9 downto 0);
      requestVRAMYPos      : out unsigned(8 downto 0);
      requestVRAMSize      : out unsigned(10 downto 0);
      requestVRAMIdle      : in  std_logic;
      requestVRAMDone      : in  std_logic;
      
      textPalNew           : out std_logic := '0';
      textPalX             : out unsigned(9 downto 0) := (others => '0');   
      textPalY             : out unsigned(8 downto 0) := (others => '0'); 
      
      vramLineEna          : out std_logic;
      vramLineAddr         : out unsigned(9 downto 0)
   );
end entity;

architecture arch of gpu_poly_pocket is
   
   type tState is
   (
      IDLE,
      REQUESTCOLOR,
      REQUESTPOS,
      REQUESTTEXTURE,
      ISSUE,
      SORTVERTICES,
      CALCBOUNDARY1,
      CALCBOUNDARY2,
      PREPAREHALF,
      PREPAREDECMODE,
      PREPARELINE,
      REQUESTFIRST,
      REQUESTLINE,
      READWAIT,
      PROCPIXELS
   );
   signal state     : tState := IDLE;
   
   signal rec_shading         : std_logic := '0';
   signal rec_quad            : std_logic := '0';
   signal rec_texture         : std_logic := '0';
   signal rec_transparency    : std_logic := '0';
   signal rec_rawTexture      : std_logic := '0';
   signal rec_dithering       : std_logic := '0';
   
   type tVertex is record
      x         : integer range -2048 to 2047; 
      y         : integer range -2048 to 2047;    
      r         : unsigned(7 downto 0);
      g         : unsigned(7 downto 0);
      b         : unsigned(7 downto 0);
      u         : unsigned(7 downto 0);
      v         : unsigned(7 downto 0);
   end record;

   -- the four received vertices live in memories with one read port per sorted position
   signal we_xy               : std_logic;
   signal we_col              : std_logic;
   signal we_uv               : std_logic;
   signal wd_xy               : std_logic_vector(23 downto 0);
   signal wa_col              : unsigned(1 downto 0);

   signal rec_index           : integer range 0 to 3;
   
   signal rec_textPalX        : unsigned(9 downto 0) := (others => '0');   
   signal rec_textPalY        : unsigned(8 downto 0) := (others => '0');

   signal quadFirst           : std_logic := '0';
   signal nextQuad            : std_logic := '0';
   
   type tworkVertexArray is array(0 to 2) of tVertex;
   signal vt                  : tworkVertexArray := (others => (0, 0, (others => '0') , (others => '0') , (others => '0') , (others => '0') , (others => '0')));
   type tIdx is array(0 to 2) of integer range 0 to 3;
   signal vtIdx               : tIdx := (0, 1, 2);
   signal coreVertex          : integer range 0 to 2;
   signal vo                  : integer range 0 to 1;
   signal vp                  : integer range 0 to 1;
   signal denom               : signed(24 downto 0) := (others => '0');
   
   signal rightFacing         : integer range 0 to 1;
   signal baseStep            : signed(43 downto 0) := (others => '0');
   signal boundCoordUs        : signed(43 downto 0) := (others => '0');
   signal boundCoordLs        : signed(43 downto 0) := (others => '0');
   signal X2                  : signed(43 downto 0) := (others => '0');
   
   signal firsthalf           : std_logic := '0';
   signal secondhalf          : std_logic := '0';
   
   -- interpolator channels: 0 R, 1 G, 2 B, 3 U, 4 V; all arithmetic mod 2^20
   type tArr20 is array(0 to 4) of unsigned(19 downto 0);
   signal dxC                 : tArr20 := (others => (others => '0'));
   signal dyC                 : tArr20 := (others => (others => '0'));
   signal rowAcc              : tArr20 := (others => (others => '0'));
   signal rowAux              : tArr20 := (others => (others => '0'));
   signal workv               : tArr20;
   signal use_ch              : std_logic_vector(0 to 4);
   type tArr8 is array(0 to 4) of unsigned(7 downto 0);
   signal pixv                : tArr8;
   signal gStart              : std_logic := '0';
   signal tacc                : unsigned(19 downto 0) := (others => '0');
   
   -- edge/denom setup multiplier (one DSP): pr = mA * mB, two cycles after the operands are set
   signal mA                  : signed(23 downto 0) := (others => '0');
   signal mB                  : signed(12 downto 0) := (others => '0');
   signal pr                  : signed(36 downto 0) := (others => '0');
   
   -- per-pixel multipliers (five DSP): dx * x
   type tArr30 is array(0 to 4) of unsigned(29 downto 0);
   signal lineProd            : tArr30;
   
   signal dX10                : signed(12 downto 0);
   signal dX21                : signed(12 downto 0);
   signal dY10                : signed(12 downto 0);
   signal dY21                : signed(12 downto 0);
   
   -- edge setup sequencing
   signal pc                  : integer range 0 to 4;
   signal vc                  : integer range 0 to 10;
   signal es                  : integer range 0 to 3;
   signal acc                 : signed(43 downto 0) := (others => '0');
   signal sA                  : std_logic := '0';
   signal prevLsb             : std_logic := '0';
   signal adj                 : integer range -1 to 1 := 0;
   
   -- gradient engine (second setup multiplier, one DSP); items 0..5 = R,G,B dx,dy; 6..9 = U,V dx,dy; 10 = none
   signal gn                  : integer range 0 to 10;
   signal gd                  : integer range 0 to 9;
   signal gpi                 : integer range 0 to 9;
   signal gen                 : std_logic := '0';
   signal gall                : std_logic := '0';
   signal gbusy               : std_logic := '0';
   signal nrdy                : std_logic := '0';
   signal nsp                 : integer range 0 to 4;
   signal pp                  : integer range 0 to 2;
   signal s0p                 : std_logic := '0';
   signal s0pv                : std_logic := '0';
   signal nacc                : signed(32 downto 0) := (others => '0');
   signal mA2                 : signed(19 downto 0) := (others => '0');
   signal mB2                 : signed(12 downto 0) := (others => '0');
   signal prod2               : signed(32 downto 0);
   signal pr2                 : signed(21 downto 0) := (others => '0');

   signal yCoord              : integer range -2048 to 2047; 
   signal yBound              : integer range -2048 to 2047; 
   signal xShort              : signed(43 downto 0) := (others => '0');
   signal xLong               : signed(43 downto 0) := (others => '0');
   signal xStart              : signed(43 downto 0);
   signal xEnd                : signed(43 downto 0);
   signal stepShort           : signed(43 downto 0);
   signal decMode             : integer range 0 to 1;
   
   signal xPos                : signed(11 downto 0) := (others => '0'); 
   signal yPos                : signed(10 downto 0) := (others => '0'); 
   signal xStop               : signed(11 downto 0) := (others => '0'); 
   signal xSize               : unsigned(10 downto 0) := (others => '0'); 

   signal firstPixel          : std_logic;
   signal emit                : std_logic;
   
   -- simulation-only probes, pruned by synthesis
   signal spanv               : std_logic := '0';
   signal span_dbg            : t_span;
   signal issue_dbg           : std_logic;
   
   function next_item(n : integer; tex : std_logic) return integer is
   begin
      if (n = 5)  then
         if (tex = '1') then return 6; else return 10; end if;
      end if;
      if (n = 9)  then return 10; end if;
      return n + 1;
   end function;
   
   -- vertex coordinate plus drawing offset: 11 bits wrap with a negative offset, 12 bits otherwise
   function vpos(off : signed(10 downto 0); w : std_logic_vector(10 downto 0)) return signed is
      variable t : signed(11 downto 0);
   begin
      if (off < 0) then
         t := resize(off, 12) + signed('0' & w);
         return resize(t(10 downto 0), 12);
      end if;
      return resize(signed(w), 12) + resize(off, 12);
   end function;

   function chan(v : tVertex; ch : integer) return unsigned is
   begin
      case ch is
         when 0      => return v.r;
         when 1      => return v.g;
         when 2      => return v.b;
         when 3      => return v.u;
         when others => return v.v;
      end case;
   end function;
   
begin 

   process (clk2x) begin if rising_edge(clk2x) then error <= '0'; end if; end process;

   requestFifo <= '1' when (state = REQUESTCOLOR or state = REQUESTPOS or state = REQUESTTEXTURE) else '0';
   
   requestVRAMEnable <= '1'                        when (state = REQUESTLINE and requestVRAMIdle = '1' and pipeline_stall = '0') else '0';
   requestVRAMXPos   <= unsigned(xPos(9 downto 0)) when (state = REQUESTLINE and requestVRAMIdle = '1' and pipeline_stall = '0') else (others => '0');
   requestVRAMYPos   <= unsigned(yPos(8 downto 0)) when (state = REQUESTLINE and requestVRAMIdle = '1' and pipeline_stall = '0') else (others => '0');
   requestVRAMSize   <= xSize                      when (state = REQUESTLINE and requestVRAMIdle = '1' and pipeline_stall = '0') else (others => '0');
   
   vramLineEna  <= '1' when (state = PROCPIXELS) else '0';
   vramLineAddr <= unsigned(xPos(9 downto 0)) when (state = PROCPIXELS) else (others => '0');
   
   -- the short edge (boundCoordUs, then Ls) and the long edge (baseStep) are tracked apart from left/right
   stepShort <= boundCoordUs when secondhalf = '1' else boundCoordLs;
   xStart    <= xShort when rightFacing = 0 else xLong;
   xEnd      <= xLong  when rightFacing = 0 else xShort;
   
   -- vt(k) is the k-th vertex of the triangle in sorted order; a flat colour is the colour of vertex 0
   -- (the golden copies it into all four)
   gvt : for k in 0 to 2 generate
      signal ca    : unsigned(1 downto 0);
      signal q_xy  : std_logic_vector(23 downto 0);
      signal q_col : std_logic_vector(23 downto 0);
      signal q_uv  : std_logic_vector(15 downto 0);
   begin
      ca <= to_unsigned(vtIdx(k), 2) when rec_shading = '1' else "00";

      ixy : entity mem.RamMLAB
      generic map ( width => 24, widthad => 2 )
      port map
      (
         inclock => clk2x, wren => we_xy, data => wd_xy, wraddress => std_logic_vector(to_unsigned(rec_index, 2)),
         rdaddress => std_logic_vector(to_unsigned(vtIdx(k), 2)), q => q_xy
      );
      icol : entity mem.RamMLAB
      generic map ( width => 24, widthad => 2 )
      port map
      (
         inclock => clk2x, wren => we_col, data => fifo_data(23 downto 0), wraddress => std_logic_vector(wa_col),
         rdaddress => std_logic_vector(ca), q => q_col
      );
      iuv : entity mem.RamMLAB
      generic map ( width => 16, widthad => 2 )
      port map
      (
         inclock => clk2x, wren => we_uv, data => fifo_data(15 downto 0), wraddress => std_logic_vector(to_unsigned(rec_index, 2)),
         rdaddress => std_logic_vector(to_unsigned(vtIdx(k), 2)), q => q_uv
      );

      vt(k).x <= to_integer(signed(q_xy(23 downto 12)));
      vt(k).y <= to_integer(signed(q_xy(11 downto 0)));
      vt(k).r <= unsigned(q_col( 7 downto  0));
      vt(k).g <= unsigned(q_col(15 downto  8));
      vt(k).b <= unsigned(q_col(23 downto 16));
      vt(k).u <= unsigned(q_uv( 7 downto 0));
      vt(k).v <= unsigned(q_uv(15 downto 8));
   end generate;

   -- writes of the receive states (the process below holds the state they decode)
   we_col <= ce and (not reset) and (fifo_Valid) when (state = REQUESTCOLOR) else
             ce and (not reset) and proc_idle and fifo_Valid when (state = IDLE and fifo_data(31 downto 29) = "001") else '0';
   wa_col <= to_unsigned(rec_index, 2) when state = REQUESTCOLOR else "00";
   we_xy  <= ce and (not reset) and fifo_Valid when (state = REQUESTPOS) else '0';
   we_uv  <= ce and (not reset) and fifo_Valid when (state = REQUESTTEXTURE) else '0';
   wd_xy  <= std_logic_vector(vpos(drawingOffsetX, fifo_data(10 downto 0))) & std_logic_vector(vpos(drawingOffsetY, fifo_data(26 downto 16)));

   dX10 <= to_signed(vt(1).x - vt(0).x, 13);
   dX21 <= to_signed(vt(2).x - vt(1).x, 13);
   dY10 <= to_signed(vt(1).y - vt(0).y, 13);
   dY21 <= to_signed(vt(2).y - vt(1).y, 13);
   
   -- the pixel of this cycle, all zero when none: the pixel pipeline latches it
   emit <= '1' when (state = PROCPIXELS and pipeline_stall = '0' and (firstPixel = '0' or pipeline_busy = '0') and
                     xPos >= to_integer(drawingAreaLeft) and xPos <= to_integer(drawingAreaRight)) else '0';
   pipeline_new         <= emit;
   pipeline_texture     <= emit and rec_texture;
   pipeline_transparent <= emit and rec_transparency;
   pipeline_rawTexture  <= emit and rec_rawTexture;
   pipeline_dithering   <= emit and rec_dithering;
   pipeline_x           <= unsigned(xPos(9 downto 0)) when emit = '1' else (others => '0');
   pipeline_y           <= unsigned(yPos(8 downto 0)) when emit = '1' else (others => '0');
   pipeline_cr          <= pixv(0) when emit = '1' else (others => '0');
   pipeline_cg          <= pixv(1) when emit = '1' else (others => '0');
   pipeline_cb          <= pixv(2) when emit = '1' else (others => '0');
   pipeline_u           <= pixv(3) when emit = '1' else (others => '0');
   pipeline_v           <= pixv(4) when emit = '1' else (others => '0');

   -- an unused channel (flat colour, untextured) is the core vertex value, not an interpolator
   use_ch <= (rec_shading, rec_shading, rec_shading, rec_texture, rec_texture);
   gpix : for i in 0 to 4 generate
      pixv(i) <= workv(i)(19 downto 12) when use_ch(i) = '1' else chan(vt(coreVertex), i);
   end generate;
   
   -- interpolator at pixel x of the line = rowAcc + dx*x (x <= 1023 for every pixel that is output)
   glineProd : for i in 0 to 4 generate
      lineProd(i) <= dxC(i) * unsigned(xPos(9 downto 0));
      workv(i)    <= rowAcc(i) + lineProd(i)(19 downto 0);
   end generate;
   
   prod2 <= mA2 * mB2;
   
   divG_req.start    <= gStart;
   divG_req.dividend <= nacc & x"000"                when gStart = '1' else (others => '0');
   divG_req.divisor  <= denom                     when gStart = '1' else (others => '0');
   divG_req.qbits    <= 31;
   
   process (clk2x)
   begin
      if rising_edge(clk2x) then
         pr   <= mA * mB;
         pr2  <= prod2(21 downto 0);
      end if;
   end process;
   
   -- debug view of a drawn line, valid in the cycle after its PREPARELINE edge
   span_dbg.valid   <= spanv;
   span_dbg.y       <= yCoord;
   span_dbg.xs_int  <= xStart(43 downto 32);
   span_dbg.xe_int  <= xEnd(43 downto 32);
   span_dbg.xs_frac <= unsigned(xStart(31 downto 0));
   span_dbg.xe_frac <= unsigned(xEnd(31 downto 0));
   span_dbg.r       <= workv(0) when use_ch(0) = '1' else chan(vt(coreVertex), 0) & x"800";
   span_dbg.g       <= workv(1) when use_ch(1) = '1' else chan(vt(coreVertex), 1) & x"800";
   span_dbg.b       <= workv(2) when use_ch(2) = '1' else chan(vt(coreVertex), 2) & x"800";
   span_dbg.u       <= workv(3) when use_ch(3) = '1' else chan(vt(coreVertex), 3) & x"800";
   span_dbg.v       <= workv(4) when use_ch(4) = '1' else chan(vt(coreVertex), 4) & x"800";
   issue_dbg        <= '1' when state = ISSUE else '0';
   
   process (clk2x)
      variable cull     : std_logic;    
      variable dx1      : signed(44 downto 0);
      variable dx2      : signed(44 downto 0);
      variable dx3      : signed(44 downto 0);
      variable dy1      : signed(12 downto 0);
      variable dy2      : signed(12 downto 0);
      variable dy3      : signed(12 downto 0);
      variable calc1    : signed(43 downto 0);
      variable calc3    : signed(43 downto 0);
      variable baseC    : signed(43 downto 0);
      variable stop     : std_logic;
      variable skip     : std_logic; 
      variable xdir     : integer range -1 to 1;
      variable ydir     : integer range -1 to 1;
      variable nxt      : integer range 0 to 3;
      variable adjv     : integer range -2 to 2;
      variable dD       : signed(43 downto 0);
      variable qv       : signed(43 downto 0);
      variable ch       : integer range 0 to 4;
      variable isDy     : boolean;
      variable c0       : unsigned(19 downto 0);
      variable gsum     : unsigned(19 downto 0);
      variable delta    : integer range -4096 to 4095;
      variable gnext    : boolean;
      variable a_now    : boolean;
      variable doneG    : boolean;
      variable dfree    : boolean;
      variable allfin   : boolean;
      variable startG   : boolean;
      variable c10      : signed(8 downto 0);
      variable c21      : signed(8 downto 0);
   begin
      if rising_edge(clk2x) then
         
         -- must be done here, so it also is effected when ce is off = paused
         if (state = READWAIT) then
            if (requestVRAMDone = '1') then
               state <= PROCPIXELS;
            end if;
         end if;
         
         if (reset = '1') then
         
            state <= IDLE;
         
         elsif (ce = '1') then
         
            done                 <= '0';
            CmdDone              <= '0';

            drawModeNew          <= '0';
            
            textPalNew           <= '0';
            textPalX             <= (others => '0');
            textPalY             <= (others => '0');
            
            divE_req             <= DIV_REQ_IDLE;
            gStart               <= '0';
            slot0_upd            <= '0';
            spanv                <= '0';
            
            xdir := 0;
            ydir := 0;
            
            case (state) is
            
               when IDLE =>
                  firstPixel   <= '1';
                  if (proc_idle = '1' and fifo_Valid = '1' and fifo_data(31 downto 29) = "001") then
                     state             <= REQUESTPOS;
                     rec_index         <= 0;
                     rec_shading       <= fifo_data(28);
                     rec_quad          <= fifo_data(27);
                     quadFirst         <= fifo_data(27);
                     rec_texture       <= fifo_data(26);
                     rec_transparency  <= fifo_data(25);
                     rec_rawTexture    <= fifo_data(24);
                     rec_dithering     <= fifo_data(28) or (fifo_data(26) and (not fifo_data(24)));
                  end if;
                              
               when REQUESTCOLOR =>
                  if (fifo_Valid = '1') then
                     state             <= REQUESTPOS;
                  end if;   
                  
               when REQUESTPOS =>
                  if (fifo_Valid = '1') then
                     if (rec_texture = '1') then
                        state    <= REQUESTTEXTURE;  
                     elsif ((rec_quad = '1' and rec_index = 3) or (rec_quad = '0' and rec_index = 2)) then
                        state    <= ISSUE; 
                        CmdDone  <= '1';                        
                     else
                        rec_index <= rec_index +1;
                        if (rec_shading = '1') then
                           state  <= REQUESTCOLOR;
                        else
                           state  <= REQUESTPOS;
                        end if;
                     end if;
                  end if;
                  
               when REQUESTTEXTURE =>
                  if (fifo_Valid = '1') then
                     if (rec_index = 0) then
                        rec_textPalX  <= unsigned(fifo_data(21 downto 16)) & "0000";
                        rec_textPalY  <= unsigned(fifo_data(30 downto 22));
                     end if;
                     if (rec_index = 1) then
                        drawModeRec   <= unsigned(fifo_data(27 downto 16));
                        drawModeNew   <= '1';
                     end if;
                     if (rec_index = 2) then
                        textPalX    <= rec_textPalX;
                        textPalY    <= rec_textPalY;
                        textPalNew  <= '1';
                     end if;
                     
                     if ((rec_quad = '1' and rec_index = 3) or (rec_quad = '0' and rec_index = 2)) then
                        state    <= ISSUE;  
                        CmdDone  <= '1'; 
                     else
                        rec_index <= rec_index +1;
                        if (rec_shading = '1') then
                           state  <= REQUESTCOLOR;
                        else
                           state  <= REQUESTPOS;
                        end if;
                     end if;
                  end if;
            
               when ISSUE =>
                  state    <= SORTVERTICES;
                  nextQuad <= '0';
                  if (rec_quad = '0' or quadFirst = '1') then
                     vtIdx <= (0, 1, 2);
                     quadFirst <= '0';
                     if (rec_quad = '1') then
                        nextQuad <= '1';
                     end if;
                  else
                     vtIdx <= (2, 1, 3);
                  end if;
                  if (drawingAreaLeft > drawingAreaRight or drawingAreaTop > drawingAreaBottom) then
                     state <= IDLE;
                     done  <= '1';
                  end if; 

               when SORTVERTICES =>
                  state     <= CALCBOUNDARY1;
                  firsthalf <= '1';
                  if (vt(0).y <= vt(2).y and vt(2).y <= vt(1).y) then -- 0 2 1
                     vtIdx <= (vtIdx(0), vtIdx(2), vtIdx(1));
                  elsif (vt(1).y <= vt(0).y and vt(0).y <= vt(2).y) then -- 1 0 2
                     vtIdx <= (vtIdx(1), vtIdx(0), vtIdx(2));
                  elsif (vt(1).y <= vt(2).y and vt(2).y <= vt(0).y) then -- 1 2 0
                     vtIdx <= (vtIdx(1), vtIdx(2), vtIdx(0));
                  elsif (vt(2).y <= vt(0).y and vt(0).y <= vt(1).y) then -- 2 0 1
                     vtIdx <= (vtIdx(2), vtIdx(0), vtIdx(1));
                  elsif (vt(2).y <= vt(1).y and vt(1).y <= vt(0).y) then -- 2 1 0
                     vtIdx <= (vtIdx(2), vtIdx(1), vtIdx(0));
                  end if; -- 0 1 2 requires no resorting
               
               when CALCBOUNDARY1 =>
                  state <= CALCBOUNDARY2;
                  
                  coreVertex <= 0;
                  vo         <= 0;
                  vp         <= 0;
                  if (vt(1).x <= vt(0).x) then
                     coreVertex <= 1;
                     vo         <= 1;
                     if(vt(2).x <= vt(1).x) then
                        coreVertex <= 2;
                        vp         <= 1;
                     end if;
                  elsif (vt(2).x < vt(0).x) then
                     coreVertex <= 2;
                     vo         <= 1;
                     vp         <= 1;
                  end if;
                  
                  -- denom = dX10*dY21 - dX21*dY10 on the setup multiplier
                  mA <= resize(dX10, 24);
                  mB <= dY21;
                  pc <= 1;
                  vc <= 0;
                  es <= 0;
                  
                  gen    <= rec_shading or rec_texture;
                  gall   <= not (rec_shading or rec_texture);
                  gbusy  <= '0';
                  nrdy   <= '0';
                  nsp    <= 0;
                  pp     <= 0;
                  s0p    <= '0';
                  if    (rec_shading = '1') then gn <= 0;
                  elsif (rec_texture = '1') then gn <= 6;
                  else                           gn <= 10; end if;
                  
                  dy1 := (to_signed(vt(2).y, 13) - to_signed(vt(0).y, 13));
                  dx1 := (to_signed(vt(2).x, 13) - to_signed(vt(0).x, 13)) & x"00000000";
                  if    (dx1 < 0) then dx1 := dx1 - (dy1 - 1); 
                  elsif (dx1 > 0) then dx1 := dx1 + (dy1 - 1); end if;
                  sA                 <= dx1(44);
                  prevLsb            <= slot0_prev;
                  divE_req.start     <= '1';
                  divE_req.dividend  <= dx1;
                  divE_req.divisor   <= x"000" & dy1;
                  divE_req.qbits     <= 43;
                  
                  -- culling of large polygons
                  cull := '0';
                  if (vt(0).y = vt(2).y)                 then cull := '1'; end if;
                  if (abs(vt(2).x - vt(0).x) >= 16#400#) then cull := '1'; end if;
                  if (abs(vt(2).x - vt(1).x) >= 16#400#) then cull := '1'; end if;
                  if (abs(vt(1).x - vt(0).x) >= 16#400#) then cull := '1'; end if;
                  if (abs(vt(2).y - vt(0).y) >= 16#200#) then cull := '1'; end if;
                  
                  if (cull = '1') then
                     divE_req <= DIV_REQ_IDLE;
                     if (nextQuad = '1') then 
                        state <= ISSUE;
                     else
                        state <= IDLE;
                        done  <= '1';
                     end if;
                  end if;
                  
               when CALCBOUNDARY2 =>
                  -- denom
                  case (pc) is
                     when 1 => mA <= resize(dX21, 24); mB <= dY10; pc <= 2;
                     when 2 => acc <= resize(pr, 44); pc <= 3;
                     when 3 => denom <= resize(acc - resize(pr, 44), 25); pc <= 4;
                     when others => null;
                  end case;
                  
                  a_now := false;
                  
                  -- X1/X2 = base edge x + diff * (baseStep with the stale bit 0) for the first/second half,
                  -- diff * baseStep as two 22-bit halves on the setup multiplier (GPU.md "Stale quotient bit")
                  baseC := signed'(to_signed(vt(0).x, 12) & x"FFFFF800");
                  dD := to_signed(vt(vo).y - vt(0).y, 44);
                  if (vc >= 1 and vc <= 9) then 
                     vc <= vc + 1; 
                  end if;
                  case (vc) is
                     when 1 => mA <= signed("00" & std_logic_vector(baseStep(21 downto 0))); mB <= to_signed(vt(vo).y - vt(0).y, 13);
                     when 2 => mA <= resize(baseStep(43 downto 22), 24);                     mB <= to_signed(vt(vo).y - vt(0).y, 13);
                     when 3 => acc <= baseC + resize(pr, 44);
                     when 4 => 
                        acc <= acc + shift_left(resize(pr, 44), 22);
                        mA <= signed("00" & std_logic_vector(baseStep(21 downto 0))); mB <= to_signed(vt(1 + vp).y - vt(0).y, 13);
                     when 5 =>
                        if    (adj =  1) then acc <= acc + dD;
                        elsif (adj = -1) then acc <= acc - dD; end if;
                        mA <= resize(baseStep(43 downto 22), 24);                     mB <= to_signed(vt(1 + vp).y - vt(0).y, 13);
                     when 6 => xLong <= acc; acc <= baseC + resize(pr, 44);
                     when 7 => acc <= acc + shift_left(resize(pr, 44), 22);
                     when 8 =>
                        dD := to_signed(vt(1 + vp).y - vt(0).y, 44);
                        if    (adj =  1) then acc <= acc + dD;
                        elsif (adj = -1) then acc <= acc - dD; end if;
                     when 9 => X2 <= acc; vc <= 10;
                     when others => null;
                  end case;
                  
                  -- edge divisions 0-2, 0-1, 1-2, one after the other on the edge divider
                  nxt := 0;
                  qv  := divE_rsp.quotient(43 downto 0);
                  if (divE_rsp.done = '1') then
                     case (es) is
                        when 0 =>
                           a_now     := true;
                           baseStep  <= qv;
                           slot0_upd <= '1';
                           slot0_val <= divE_rsp.qmag_lsb;
                           adjv := 0;
                           if (prevLsb = '1')            then adjv := adjv + 1; end if;
                           if (divE_rsp.qmag_lsb = '1')  then adjv := adjv - 1; end if;
                           if (sA = '1') then adjv := -adjv; end if;
                           adj <= adjv;
                           if (denom = 0) then
                              if (nextQuad = '1') then 
                                 state <= ISSUE;
                              else
                                 state <= IDLE;
                                 done  <= '1';
                              end if;
                           else
                              vc  <= 1;
                              nxt := 1;
                           end if;
                        when 1 =>
                           boundCoordUs <= qv;
                           if (qv > baseStep) then rightFacing <= 1; else rightFacing <= 0; end if;
                           nxt := 2;
                        when 2 =>
                           boundCoordLs <= qv;
                           nxt := 3;
                        when others => null;
                     end case;
                  end if;
                  
                  if (nxt = 1) then
                     if (vt(1).y = vt(0).y) then
                        boundCoordUs <= (others => '0');
                        if (vt(1).x > vt(0).x) then rightFacing <= 1; else rightFacing <= 0; end if;
                        nxt := 2;
                     else
                        dy2 := (to_signed(vt(1).y, 13) - to_signed(vt(0).y, 13));
                        dx2 := (to_signed(vt(1).x, 13) - to_signed(vt(0).x, 13)) & x"00000000";
                        if    (dx2 < 0) then dx2 := dx2 - (dy2 - 1); 
                        elsif (dx2 > 0) then dx2 := dx2 + (dy2 - 1); end if;
                        divE_req.start     <= '1';
                        divE_req.dividend  <= dx2;
                        divE_req.divisor   <= x"000" & dy2;
                        divE_req.qbits     <= 43;
                        es <= 1;
                     end if;
                  end if;
                  if (nxt = 2) then
                     if (vt(2).y = vt(1).y) then
                        boundCoordLs <= (others => '0');
                        nxt := 3;
                     else
                        dy3 := (to_signed(vt(2).y, 13) - to_signed(vt(1).y, 13));
                        dx3 := (to_signed(vt(2).x, 13) - to_signed(vt(1).x, 13)) & x"00000000";
                        if    (dx3 < 0) then dx3 := dx3 - (dy3 - 1); 
                        elsif (dx3 > 0) then dx3 := dx3 + (dy3 - 1); end if;
                        divE_req.start     <= '1';
                        divE_req.dividend  <= dx3;
                        divE_req.divisor   <= x"000" & dy3;
                        divE_req.qbits     <= 43;
                        es <= 2;
                     end if;
                  end if;
                  if (nxt = 3) then
                     es <= 3;
                  end if;
                  
                  -- gradients on the gradient divider, started as soon as denom is known and nonzero:
                  -- numerator on the second multiplier while the previous item divides
                  if (s0p = '1' and es /= 0) then
                     slot0_upd <= '1';
                     slot0_val <= s0pv;
                     s0p       <= '0';
                  end if;
                  
                  doneG  := (gbusy = '1' and divG_rsp.done = '1');
                  dfree  := (gbusy = '0');
                  allfin := false;
                  if (doneG) then
                     ch   := gd / 2;
                     if (gd mod 2 = 1) then
                        dyC(ch) <= unsigned(divG_rsp.quotient(19 downto 0));
                        if (coreVertex = 0)     then delta := vt(1).y - vt(0).y;
                        elsif (coreVertex = 2)  then delta := vt(1).y - vt(2).y;
                        else                         delta := 0; end if;
                        mB2 <= to_signed(delta, 13);
                     else
                        dxC(ch) <= unsigned(divG_rsp.quotient(19 downto 0));
                        mB2 <= to_signed(-vt(coreVertex).x, 13);
                     end if;
                     mA2    <= signed(divG_rsp.quotient(19 downto 0));
                     pp     <= 2;
                     gpi    <= gd;
                     gbusy  <= '0';
                     dfree  := true;
                     if (gd = 0 or gd = 6) then
                        if (es = 0 or a_now) then
                           s0p  <= '1';
                           s0pv <= divG_rsp.qmag_lsb;
                        else
                           slot0_upd <= '1';
                           slot0_val <= divG_rsp.qmag_lsb;
                        end if;
                     end if;
                  end if;
                  
                  if (pp = 2) then
                     pp <= 1;
                  elsif (pp = 1) then
                     pp <= 0;
                     ch := gpi / 2;
                     if (gpi mod 2 = 1) then
                        gsum := tacc + unsigned(pr2(19 downto 0));
                        if    (coreVertex = 2) then rowAcc(ch) <= gsum;
                        elsif (coreVertex = 0) then rowAux(ch) <= gsum; end if;
                     else
                        c0   := chan(vt(coreVertex), ch) & x"800";
                        gsum := c0 + unsigned(pr2(19 downto 0));
                        rowAcc(ch) <= gsum;
                        rowAux(ch) <= gsum;
                        tacc       <= gsum;
                     end if;
                     if (next_item(gpi, rec_texture) = 10) then
                        allfin := true;
                        gall   <= '1';
                     end if;
                  end if;
                  
                  -- numerator of item gn: dx = C10*dY21 - C21*dY10, dy = C21*dX10 - C10*dX21
                  ch   := (gn / 2) mod 5;
                  isDy := (gn mod 2 = 1);
                  c10  := signed('0' & chan(vt(1), ch)) - signed('0' & chan(vt(0), ch));
                  c21  := signed('0' & chan(vt(2), ch)) - signed('0' & chan(vt(1), ch));
                  case (nsp) is
                     when 0 =>
                        if (gen = '1' and nrdy = '0' and gn /= 10 and pp = 0 and not doneG) then
                           if (isDy) then
                              mA2 <= resize(c21, 20);
                              mB2 <= dX10;
                           else
                              mA2 <= resize(c10, 20);
                              mB2 <= dY21;
                           end if;
                           nsp <= 2;
                        end if;
                     when 2 =>
                        if (isDy) then
                           mA2 <= resize(c10, 20);
                           mB2 <= dX21;
                        else
                           mA2 <= resize(c21, 20);
                           mB2 <= dY10;
                        end if;
                        nsp <= 3;
                     when 3 =>
                        nacc <= resize(pr2, 33);
                        nsp  <= 4;
                     when others =>
                        nacc <= nacc - resize(pr2, 33);
                        nrdy <= '1';
                        nsp  <= 0;
                  end case;
                  
                  if (dfree and nrdy = '1' and gen = '1' and pc = 4 and denom /= 0) then
                     gStart <= '1';
                     gd     <= gn;
                     gbusy  <= '1';
                     nrdy   <= '0';
                     gn     <= next_item(gn, rec_texture);
                  end if;
                  
                  if ((nxt = 3 or es = 3) and vc = 10 and (gall = '1' or allfin)) then
                     state <= PREPAREHALF;
                  end if;
                  
               when PREPAREHALF =>
                  state <= PREPARELINE;
                  if (firsthalf = '1') then
                     firsthalf  <= '0';
                     secondhalf <= '1';
                     yCoord     <= vt(vo).y;
                     yBound     <= vt(1-vo).y;
                     calc1      := signed'(to_signed(vt(vo).x, 12) & x"FFFFF800");
                     xShort     <= calc1;
                     decMode    <= vo;
                     if (vo = 1) then
                        state <= PREPAREDECMODE;
                     end if;
                  else
                     secondhalf <= '0';
                     yCoord     <= vt(1 + vp).y;
                     yBound     <= vt(2 - vp).y;
                     rowAcc     <= rowAux;
                     calc3      := signed'(to_signed(vt(1 + vp).x, 12) & x"FFFFF800");
                     xShort     <= calc3;
                     xLong      <= X2;
                     decMode    <= vp;
                     if (vp = 1) then
                        state <= PREPAREDECMODE;
                     end if;
                  end if;
                  
               when PREPAREDECMODE =>
                  state <= PREPARELINE;
                  ydir  := -1;
                  xdir  := -1;
                  
               when PREPARELINE =>
                  if (xStart(43 downto 32) < 0) then
                     xPos  <= (others => '0');
                  else
                     xPos  <= xStart(43 downto 32);
                  end if;
                  yPos  <= to_signed(yCoord, 11);
                  xStop <= xEnd(43 downto 32);
                  if (xStart(43 downto 32) < 0 and xEnd(43 downto 32) > 1023) then
                     xSize <= to_unsigned(1024, 11);
                  elsif (xStart(43 downto 32) >= 0 and xEnd(43 downto 32) > 1023) then
                     xSize <= to_unsigned(1024, 11) - unsigned(xStart(41 downto 32));
                  else 
                     xSize <= ('0' & (unsigned(xEnd(41 downto 32)) - unsigned(xStart(41 downto 32)))) + 1;
                  end if;
               
                  if (rec_transparency = '1' or DrawPixelsMask = '1') then
                     if (firstPixel = '1') then
                        state <= REQUESTFIRST;
                     else
                        state <= REQUESTLINE;
                     end if;
                  else
                     state <= PROCPIXELS;
                  end if;
                  
                  stop := '0';
                  skip := '0';
                  
                  if (xStart(43 downto 32) = xEnd(43 downto 32)) then
                     skip := '1';
                  end if;
                  
                  if (xStart(43) = '0' and unsigned(xStart(42 downto 32)) > drawingAreaRight) then
                     skip := '1';
                  end if;                  
                  
                  if (xEnd(43 downto 32) <= 0) then
                     skip := '1';
                  end if;
                  
                  if (interlacedDrawing = '1' and (activeLineLSB = to_signed(yCoord, 12)(0))) then
                     skip := '1';
                  end if;
                  
                  if (decMode = 1) then
                     if (to_signed(yCoord, 11) < to_integer(drawingAreaTop))    then stop := '1'; end if;
                     if (to_signed(yCoord, 11) > to_integer(drawingAreaBottom)) then skip := '1'; end if;
                  else
                     if (to_signed(yCoord, 11) > to_integer(drawingAreaBottom)) then stop := '1'; end if;
                     if (to_signed(yCoord, 11) < to_integer(drawingAreaTop))    then skip := '1'; end if;
                  end if;
                  
                  if (skip = '1') then
                     state  <= PREPARELINE;
                     if (decMode = 1) then
                        ydir := -1;
                        xdir := -1;
                     else
                        ydir := 1;
                        xdir := 1;
                     end if;
                  end if;
                  
                  if (decMode = 1) then
                     if (yCoord < yBound) then stop := '1'; end if;
                  else
                     if (yCoord >= yBound) then stop := '1'; end if;
                  end if;
                  
                  if (stop = '1') then
                     if (secondhalf = '1') then
                        state <= PREPAREHALF;
                     else
                        if (nextQuad = '1') then 
                           state <= ISSUE;
                        else
                           state <= IDLE;
                           done  <= '1';
                        end if;
                     end if;
                  elsif (skip = '0') then
                     spanv <= '1';
                  end if;
                       
               when REQUESTFIRST =>
                  if (pipeline_busy = '0' and fifoOut_idle = '1') then
                     state <= REQUESTLINE;
                  end if;
                       
               when REQUESTLINE =>
                  if (pipeline_stall = '0' and requestVRAMIdle = '1') then
                     state  <= READWAIT;
                  end if;
                  
               when READWAIT => null; -- handled outside due to ce
               
               when PROCPIXELS =>
                  if (pipeline_stall = '0' and (firstPixel = '0' or pipeline_busy = '0')) then
                     firstPixel <= '0';
                     
                     xPos  <= xPos + 1;
                     
                     if (xPos + 1 >= xStop) then
                        if (decMode = 1) then
                           ydir := -1;
                           xdir := -1;
                        else
                           ydir := 1;
                           xdir := 1;
                        end if;
                        state  <= PREPARELINE;
                     end if; 
                     
                  end if;
                      
            end case;
            
            -- every change of yCoord moves the row accumulators and the edges with it
            if (xdir = 1) then
               xShort <= xShort + stepShort;
               xLong  <= xLong  + baseStep;
            elsif (xdir = -1) then
               xShort <= xShort - stepShort;
               xLong  <= xLong  - baseStep;
            end if;
            if (ydir = 1) then
               yCoord <= yCoord + 1;
               for i in 0 to 4 loop
                  rowAcc(i) <= rowAcc(i) + dyC(i);
               end loop;
            elsif (ydir = -1) then
               yCoord <= yCoord - 1;
               for i in 0 to 4 loop
                  rowAcc(i) <= rowAcc(i) - dyC(i);
               end loop;
            end if;
         
         end if;
         
      end if;
   end process;

end architecture;
