library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library mem;

-- gpu_pixelpipeline with the Pocket tie-offs applied (texture filter, render24, drawSlow, oldGPU off): same
-- requests, same stall protocol and the same pixel stream cycle for cycle, in narrower registers.
-- Design and exactness arguments: docs/pocket/GPU.md "Pixel pipeline".
entity gpu_pixelpipeline_pocket is
   port
   (
      clk2x                : in  std_logic;
      ce                   : in  std_logic;
      reset                : in  std_logic;

      noTexture            : in  std_logic;
      ditherOn             : in  std_logic;

      drawMode_in          : in  unsigned(8 downto 0);
      DrawPixelsMask_in    : in  std_logic;
      SetMask_in           : in  std_logic;

      clearCacheTexture    : in  std_logic;
      clearCachePalette    : in  std_logic;

      fifoOut_idle         : in  std_logic;
      pipeline_busy        : out std_logic;
      pipeline_stall       : out std_logic;
      pipeline_new         : in  std_logic;
      pipeline_texture     : in  std_logic;
      pipeline_transparent : in  std_logic;
      pipeline_rawTexture  : in  std_logic;
      pipeline_dithering   : in  std_logic;
      pipeline_x           : in  unsigned(9 downto 0);
      pipeline_y           : in  unsigned(8 downto 0);
      pipeline_cr          : in  unsigned(7 downto 0);
      pipeline_cg          : in  unsigned(7 downto 0);
      pipeline_cb          : in  unsigned(7 downto 0);
      pipeline_u           : in  unsigned(7 downto 0);
      pipeline_v           : in  unsigned(7 downto 0);

      requestVRAMEnable    : out std_logic;
      requestVRAMXPos      : out unsigned(9 downto 0);
      requestVRAMYPos      : out unsigned(8 downto 0);
      requestVRAMSize      : out unsigned(10 downto 0);
      requestVRAMIdle      : in  std_logic;
      requestVRAMDone      : in  std_logic;
      vram_DOUT            : in  std_logic_vector(63 downto 0);
      vram_DOUT_READY      : in  std_logic;

      vramLineData         : in  std_logic_vector(15 downto 0);

      textPalInNew         : in  std_logic;
      textPalInX           : in  unsigned(9 downto 4);
      textPalInY           : in  unsigned(8 downto 0);

      pixelStall           : in  std_logic;
      pixelColor           : out std_logic_vector(15 downto 0);
      pixelAddr            : out unsigned(19 downto 0);
      pixelWrite           : out std_logic
   );
end entity;

architecture arch of gpu_pixelpipeline_pocket is

   type tDither is array(0 to 3, 0 to 3) of integer range -4 to 4;
   constant DITHERMATRIX : tDither :=
   (
      (-4, +0, -3, +1),
      (+2, -2, +3, -1),
      (-3, +1, -4, +0),
      (+3, -1, +2, -2)
   );

   constant EPW : integer := 9;   -- epoch width; 0 is "not valid"

   -- palette read sizes in words (multiples of 16)
   constant PS_16  : unsigned(8 downto 4) := "00001";
   constant PS_64  : unsigned(8 downto 4) := "00100";
   constant PS_128 : unsigned(8 downto 4) := "01000";
   constant PS_192 : unsigned(8 downto 4) := "01100";
   constant PS_256 : unsigned(8 downto 4) := "10000";

   signal drawMode            : unsigned(8 downto 0) := (others => '0');
   signal drawMode_eff        : unsigned(8 downto 0);
   signal DrawPixelsMask      : std_logic := '0';
   signal SetMask             : std_logic := '0';
   signal palette8bit         : std_logic := '0';

   -- texture cache tags: entry = tag(10) & epoch(EPW); valid when its epoch is the current one
   signal ep                  : unsigned(EPW-1 downto 0) := to_unsigned(1, EPW);
   signal a0                  : unsigned(7 downto 0) := (others => '0');
   signal a1                  : unsigned(7 downto 0) := (others => '0');
   signal d0                  : unsigned(9 downto 0) := (others => '0');
   signal nxt_u               : unsigned(7 downto 0);
   signal nxt_v               : unsigned(7 downto 0);
   signal nxt_a               : unsigned(7 downto 0);
   signal nxt_d               : unsigned(9 downto 0);
   signal rd_a                : unsigned(7 downto 0);
   signal tag_q               : std_logic_vector(10+EPW-1 downto 0);
   signal tag_address_a       : unsigned(7 downto 0) := (others => '0');
   signal tag_data_a          : unsigned(9 downto 0) := (others => '0');
   signal tag_wren_a          : std_logic := '0';
   signal bp_valid            : std_logic := '0';
   signal bp_addr             : unsigned(7 downto 0) := (others => '0');
   signal bp_tag              : unsigned(9 downto 0) := (others => '0');
   signal cachehit            : std_logic;
   signal wr_en               : std_logic;
   signal wr_a                : unsigned(7 downto 0);
   signal wr_d                : std_logic_vector(10+EPW-1 downto 0);
   signal wr_e                : std_logic_vector(EPW-1 downto 0);

   -- background invalidation of entries of earlier epochs
   signal sw_cur              : unsigned(7 downto 0) := (others => '0');
   signal sw_a                : unsigned(7 downto 0);
   signal sw_q                : std_logic_vector(EPW-1 downto 0);
   signal sw_stale            : std_logic;
   signal sw_retry            : std_logic;
   signal sw_wr               : std_logic;

   signal cache_wren_a        : std_logic := '0';
   signal cache_address_b     : unsigned(7 downto 0);
   signal cache_q_b           : std_logic_vector(63 downto 0);

   signal CLUTaddrA           : unsigned(5 downto 0) := (others => '0');
   signal CLUTwrenA           : std_logic;
   signal CLUTaddrB           : std_logic_vector(7 downto 0);
   signal CLUTDataB           : std_logic_vector(15 downto 0);

   signal clearCacheBuffer    : std_logic := '0';

   signal textPalReq          : std_logic := '0';
   signal textPalReqX         : unsigned(9 downto 4) := (others => '0');
   signal textPalReqY         : unsigned(8 downto 0) := (others => '0');
   signal textPalFetched      : std_logic := '0';
   signal textPalX            : unsigned(9 downto 4) := (others => '0');
   signal textPalY            : unsigned(8 downto 0) := (others => '0');
   signal textPalFetchNext    : integer range 0 to 3 := 0;
   signal palCont             : std_logic := '0';
   signal palSize             : unsigned(8 downto 4) := (others => '0');

   type tState is
   (
      IDLE,
      REQUESTTEXTURE,
      WAITTEXTURE,
      REQUESTPALETTE,
      WAITPALETTE
   );
   signal state : tState := IDLE;

   signal pipeline_stall_1    : std_logic := '0';
   signal pipeline_stall_i    : std_logic;
   signal pipeline_busy_i     : std_logic;
   signal reqEna              : std_logic;
   signal adv                 : std_logic;
   signal texX                : unsigned(9 downto 0);
   signal texY                : unsigned(8 downto 0);

   -- flags of a pixel: valid, texture, transparent, rawTexture, dithering
   subtype tFlags is std_logic_vector(4 downto 0);
   constant F_VALID : integer := 4;
   constant F_TEX   : integer := 3;
   constant F_TRANS : integer := 2;
   constant F_RAW   : integer := 1;
   constant F_DITH  : integer := 0;

   -- the pixel the units emitted on the last edge waits here until stage 0 takes it; its position, colour and
   -- destination pixel are in the ring
   signal p_flags             : tFlags := (others => '0');
   signal p_u                 : unsigned(7 downto 0) := (others => '0');
   signal p_v                 : unsigned(7 downto 0) := (others => '0');
   signal p_fresh             : std_logic := '0';
   signal p_m                 : std_logic := '0';
   signal m_eff               : std_logic;

   signal stage0_flags        : tFlags := (others => '0');
   signal stage0_u            : unsigned(3 downto 0) := (others => '0');

   -- stage 1: texture fetch
   signal stage1_flags        : tFlags := (others => '0');
   signal stage1_u            : unsigned(3 downto 0) := (others => '0');
   signal texdata_raw         : std_logic_vector(15 downto 0);
   signal wordSel             : unsigned(1 downto 0);

   -- stage 2: palette read
   signal stage2_flags        : tFlags := (others => '0');
   signal stage2_texdata      : std_logic_vector(15 downto 0) := (others => '0');
   signal texdata_palette     : std_logic_vector(15 downto 0);

   -- stage 3: texel
   signal stage3_flags        : tFlags := (others => '0');
   signal stage3_tex          : std_logic_vector(15 downto 0) := (others => '0');

   -- stage 4: dither offset
   signal stage4_flags        : tFlags := (others => '0');
   signal stage4_tex          : std_logic_vector(15 downto 0) := (others => '0');

   -- ring of the position, colour and destination pixel of the pixels in flight: the waiting pixel is at wp, the one in stage k at wp - 1 - k
   signal wp                  : unsigned(2 downto 0) := (others => '0');
   signal wp_n                : unsigned(2 downto 0);
   signal ring_wd_a           : std_logic_vector(27 downto 0);
   signal ring_wd_b           : std_logic_vector(18 downto 0);
   signal ring_ra             : unsigned(2 downto 0);
   signal ring_rb             : unsigned(2 downto 0);
   signal ring_qa             : std_logic_vector(27 downto 0);
   signal ring_qb             : std_logic_vector(18 downto 0);
   signal ring_qc             : std_logic_vector(14 downto 0);
   signal s5_x                : unsigned(9 downto 0);
   signal s5_y                : unsigned(8 downto 0);
   signal s5_old              : std_logic_vector(14 downto 0);
   signal s4_c                : unsigned(23 downto 0);
   signal s4_ditherAdd        : signed(3 downto 0);

   -- stage 5: colour
   signal stage5_c            : unsigned(14 downto 0) := (others => '0');
   signal stage5_valid        : std_logic := '0';
   signal stage5_transparent  : std_logic := '0';
   signal stage5_alphacheck   : std_logic := '0';
   signal stage5_alphabit     : std_logic := '0';

   -- stage 6: output
   signal stage6_valid        : std_logic := '0';
   signal stage6_alphabit     : std_logic := '0';
   signal stage6_x            : unsigned(9 downto 0) := (others => '0');
   signal stage6_y            : unsigned(8 downto 0) := (others => '0');
   signal stage6_c            : std_logic_vector(14 downto 0) := (others => '0');

   -- address of the texel in VRAM (halfword x in 10:1, y in 19:11): 64x64 pixel for 4bit mode, 32*64 for 8bit, 32*32 for 15 bit
   function texaddr(dm : unsigned(8 downto 0); u : unsigned(7 downto 0); v : unsigned(7 downto 0)) return unsigned is
      variable a : unsigned(19 downto 0);
   begin
      a(19 downto 11) := dm(4) & v;
      a(0)            := '0';
      if (dm(8 downto 7) = "00") then
         a(10 downto 1) := (dm(3 downto 0) & "000000") + u(7 downto 2);
      elsif (dm(8 downto 7) = "01") then
         a(10 downto 1) := (dm(3 downto 0) & "000000") + u(7 downto 1);
      else
         a(10 downto 1) := (dm(3 downto 0) & "000000") + u;
      end if;
      return a;
   end function;

   function tagIndex(dm : unsigned(8 downto 0); a : unsigned(19 downto 0)) return unsigned is
   begin
      if (dm(8) = '0') then return a(16 downto 11) & a(4 downto 3); end if;
      return a(15 downto 11) & a(5 downto 3);
   end function;

   function tagValue(dm : unsigned(8 downto 0); a : unsigned(19 downto 0)) return unsigned is
   begin
      if (dm(8) = '0') then return dm(8) & a(19 downto 17) & a(10 downto 5); end if;
      return dm(8) & a(19 downto 16) & a(10 downto 6);
   end function;

   -- one colour channel of a textured pixel: texel(5) * colour(8) / 16, optional dither, clamp, top 5 bits
   function modulate(t : unsigned(4 downto 0); c : unsigned(7 downto 0); dith : std_logic; d : signed(3 downto 0)) return unsigned is
      variable p : unsigned(12 downto 0);
      variable v : signed(10 downto 0);
   begin
      p := t * c;
      if (dith = '1') then
         v := signed('0' & '0' & p(12 downto 4)) + resize(d, 11);
         if (v < 0)   then return to_unsigned(0, 5); end if;
         if (v > 255) then return to_unsigned(31, 5); end if;
         return unsigned(v(7 downto 3));
      end if;
      if (p(12) = '1') then return to_unsigned(31, 5); end if;
      return p(11 downto 7);
   end function;

   -- one colour channel of an untextured pixel: dither offset, clamp, top 5 bits
   function plain(c : unsigned(7 downto 0); dith : std_logic; d : signed(3 downto 0)) return unsigned is
      variable v : signed(10 downto 0);
   begin
      if (dith = '1') then
         v := signed("000" & c) + resize(d, 11);
         if (v < 0)   then return to_unsigned(0, 5); end if;
         if (v > 255) then return to_unsigned(31, 5); end if;
         return unsigned(v(7 downto 3));
      end if;
      return c(7 downto 3);
   end function;

   -- one channel of the semi-transparency blend, in 5 bit units
   function blend(b : unsigned(4 downto 0); f : unsigned(4 downto 0); mode : unsigned(1 downto 0)) return unsigned is
      variable s : unsigned(5 downto 0);
   begin
      case mode is
         when "00" =>
            s := ('0' & b) + ('0' & f);
            return s(5 downto 1);
         when "01" =>
            s := ('0' & b) + ('0' & f);
            if (s(5) = '1') then return to_unsigned(31, 5); end if;
            return s(4 downto 0);
         when "10" =>
            if (b < f) then return to_unsigned(0, 5); end if;
            return b - f;
         when others =>
            s := ('0' & b) + ("000" & f(4 downto 2));
            if (s(5) = '1') then return to_unsigned(31, 5); end if;
            return s(4 downto 0);
      end case;
   end function;

begin

   pipeline_stall_i <= '1' when (pixelStall = '1' or state /= IDLE) else '0';
   pipeline_stall   <= pipeline_stall_i;

   pipeline_busy_i <= pipeline_stall_i or stage0_flags(F_VALID) or stage1_flags(F_VALID) or stage2_flags(F_VALID) or
                      stage3_flags(F_VALID) or stage4_flags(F_VALID) or stage5_valid or stage6_valid;
   pipeline_busy   <= pipeline_busy_i;

   adv <= ce and (not reset) and (not pipeline_stall_i);

   -- the texel request of a miss is rebuilt from the tag it stores (the two low x bits never matter for a one word read)
   texX <= tag_data_a(5 downto 0) & tag_address_a(1 downto 0) & "00" when tag_data_a(9) = '0' else
           tag_data_a(4 downto 0) & tag_address_a(2 downto 0) & "00";
   texY <= tag_data_a(8 downto 6) & tag_address_a(7 downto 2) when tag_data_a(9) = '0' else
           tag_data_a(8 downto 5) & tag_address_a(7 downto 3);

   reqEna            <= '1' when (requestVRAMIdle = '1' and (state = REQUESTTEXTURE or (state = REQUESTPALETTE and fifoOut_idle = '1'))) else '0';
   requestVRAMEnable <= reqEna;
   requestVRAMXPos   <= (others => '0') when reqEna = '0' else
                        texX when state = REQUESTTEXTURE else
                        (others => '0') when palCont = '1' else
                        textPalX & "0000";
   requestVRAMYPos   <= (others => '0') when reqEna = '0' else
                        texY when state = REQUESTTEXTURE else
                        textPalY;
   requestVRAMSize   <= (others => '0') when reqEna = '0' else
                        to_unsigned(1, 11) when state = REQUESTTEXTURE else
                        "00" & palSize & "0000";

   -- address of the next stage 0 pixel, with the draw mode it will see
   nxt_u        <= p_u;
   nxt_v        <= p_v;
   drawMode_eff <= drawMode_in when (ce = '1' and reset = '0' and pipeline_busy_i = '0') else drawMode;
   nxt_a        <= tagIndex(drawMode_eff, texaddr(drawMode_eff, nxt_u, nxt_v));
   nxt_d        <= tagValue(drawMode_eff, texaddr(drawMode_eff, nxt_u, nxt_v));

   rd_a <= nxt_a when adv = '1' else a0;

   -- tag copy for the pixel lookups and a copy of the epochs for the invalidation walk
   wr_en <= tag_wren_a or sw_wr;
   wr_a  <= tag_address_a when tag_wren_a = '1' else sw_cur;
   wr_d  <= std_logic_vector(tag_data_a) & std_logic_vector(ep) when tag_wren_a = '1' else (others => '0');
   wr_e  <= std_logic_vector(ep) when tag_wren_a = '1' else (others => '0');

   itags : entity work.dpram
   generic map ( addr_width => 8, data_width => 10+EPW )
   port map
   (
      clock_a   => clk2x,
      address_a => std_logic_vector(wr_a),
      data_a    => wr_d,
      wren_a    => wr_en,

      clock_b   => clk2x,
      address_b => std_logic_vector(rd_a),
      data_b    => (others => '0'),
      wren_b    => '0',
      q_b       => tag_q
   );

   iepochs : entity work.dpram
   generic map ( addr_width => 8, data_width => EPW )
   port map
   (
      clock_a   => clk2x,
      address_a => std_logic_vector(wr_a),
      data_a    => wr_e,
      wren_a    => wr_en,

      clock_b   => clk2x,
      address_b => std_logic_vector(sw_a),
      data_b    => (others => '0'),
      wren_b    => '0',
      q_b       => sw_q
   );

   -- a fill written on the last edge is not yet on the read data
   cachehit <= '1' when (bp_valid = '1' and bp_addr = a0) and bp_tag = d0 else
               '1' when not (bp_valid = '1' and bp_addr = a0) and unsigned(tag_q(EPW-1 downto 0)) = ep and
                        unsigned(tag_q(10+EPW-1 downto EPW)) = d0 else
               '0';

   -- walk over all entries; one of an earlier epoch is made invalid unless a fill touches it at the same time
   sw_stale <= '1' when (unsigned(sw_q) /= 0 and unsigned(sw_q) /= ep) else '0';
   sw_retry <= sw_stale when (tag_wren_a = '1' or (bp_valid = '1' and bp_addr = sw_cur)) else '0';
   sw_wr    <= sw_stale and (not sw_retry);
   sw_a     <= sw_cur when sw_retry = '1' else sw_cur + 1;

   icache : entity work.dpram
   generic map ( addr_width => 8, data_width => 64)
   port map
   (
      clock_a   => clk2x,
      address_a => std_logic_vector(tag_address_a),
      data_a    => vram_DOUT,
      wren_a    => cache_wren_a,

      clock_b   => clk2x,
      address_b => std_logic_vector(cache_address_b),
      data_b    => x"0000000000000000",
      wren_b    => '0',
      q_b       => cache_q_b
   );

   cache_address_b <= a1 when (pipeline_stall_i = '1') else a0;

   wordSel    <= stage1_u(3 downto 2) when drawMode(8 downto 7) = "00" else
                 stage1_u(2 downto 1) when drawMode(8 downto 7) = "01" else
                 stage1_u(1 downto 0);
   texdata_raw <= cache_q_b(15 downto  0) when (wordSel = "00") else
                  cache_q_b(31 downto 16) when (wordSel = "01") else
                  cache_q_b(47 downto 32) when (wordSel = "10") else
                  cache_q_b(63 downto 48);

   iCLUTram : entity work.dpram_dif
   generic map
   (
      addr_width_a  => 6,
      data_width_a  => 64,
      addr_width_b  => 8,
      data_width_b  => 16
   )
   port map
   (
      clock_a   => clk2x,
      address_a => std_logic_vector(CLUTaddrA),
      data_a    => vram_DOUT,
      wren_a    => CLUTwrenA,

      clock_b   => clk2x,
      clken_b   => (not pipeline_stall_i),
      address_b => CLUTaddrB,
      data_b    => x"0000",
      wren_b    => '0',
      q_b       => CLUTDataB
   );

   CLUTaddrB <= x"0" & texdata_raw( 3 downto  0) when (drawMode(7) = '0' and stage1_u(1 downto 0) = "00") else
                x"0" & texdata_raw( 7 downto  4) when (drawMode(7) = '0' and stage1_u(1 downto 0) = "01") else
                x"0" & texdata_raw(11 downto  8) when (drawMode(7) = '0' and stage1_u(1 downto 0) = "10") else
                x"0" & texdata_raw(15 downto 12) when (drawMode(7) = '0' and stage1_u(1 downto 0) = "11") else
                texdata_raw( 7 downto 0) when (drawMode(7) = '1' and stage1_u(0) = '0') else
                texdata_raw(15 downto 8);

   texdata_palette <= stage2_texdata when (drawMode(8) = '1') else CLUTDataB;

   cache_wren_a <= '1' when (vram_DOUT_READY = '1' and state = WAITTEXTURE) else '0';
   CLUTwrenA    <= '1' when (vram_DOUT_READY = '1' and state = WAITPALETTE) else '0';


   -- A ring keeps what the stages only carry along. A pixel is written when the units emit it, its destination pixel
   -- one cycle later (the line buffer read), then it waits at wp until stage 0 takes it.
   wp_n      <= wp + 1;
   ring_wd_a <= std_logic_vector(pipeline_cr & pipeline_cg & pipeline_cb & pipeline_x(1 downto 0) & pipeline_y(1 downto 0));
   ring_wd_b <= std_logic_vector(pipeline_x & pipeline_y);
   ring_ra   <= wp - 5;
   ring_rb   <= wp - 6;

   iringa : entity mem.RamMLAB
   generic map ( width => 28, widthad => 3 )
   port map
   (
      inclock   => clk2x,
      wren      => adv,
      data      => ring_wd_a,
      wraddress => std_logic_vector(wp_n),
      rdaddress => std_logic_vector(ring_ra),
      q         => ring_qa
   );

   iringb : entity mem.RamMLAB
   generic map ( width => 19, widthad => 3 )
   port map
   (
      inclock   => clk2x,
      wren      => adv,
      data      => ring_wd_b,
      wraddress => std_logic_vector(wp_n),
      rdaddress => std_logic_vector(ring_rb),
      q         => ring_qb
   );

   iringc : entity mem.RamMLAB
   generic map ( width => 15, widthad => 3 )
   port map
   (
      inclock   => clk2x,
      wren      => p_fresh,
      data      => vramLineData(14 downto 0),
      wraddress => std_logic_vector(wp),
      rdaddress => std_logic_vector(ring_rb),
      q         => ring_qc
   );

   m_eff <= vramLineData(15) when p_fresh = '1' else p_m;

   s4_c         <= unsigned(ring_qa(27 downto 4));
   s4_ditherAdd <= to_signed(DITHERMATRIX(to_integer(unsigned(ring_qa(1 downto 0))), to_integer(unsigned(ring_qa(3 downto 2)))), 4);
   s5_x         <= unsigned(ring_qb(18 downto 9));
   s5_y         <= unsigned(ring_qb(8 downto 0));
   s5_old       <= ring_qc;

   -- the walk and the lookup bypass run on every clock
   process (clk2x)
   begin
      if rising_edge(clk2x) then
         sw_cur   <= sw_a;
         p_fresh  <= adv;
         if (p_fresh = '1') then
            p_m <= vramLineData(15);
         end if;
         bp_valid <= tag_wren_a;
         bp_addr  <= tag_address_a;
         bp_tag   <= tag_data_a;
      end if;
   end process;

   process (clk2x)
      variable tr, tg, tb : unsigned(4 downto 0);
      variable dd         : signed(3 downto 0);
      variable na         : unsigned(7 downto 0);
   begin
      if rising_edge(clk2x) then

         tag_wren_a <= '0';

         -- must be done here, so it also is effected when ce is off = paused
         if (state = WAITTEXTURE) then
            if (requestVRAMDone = '1') then
               state <= IDLE;
            end if;
            if (vram_DOUT_READY = '1') then
               tag_wren_a <= '1';
            end if;
         end if;

         if (state = WAITPALETTE) then
            if (requestVRAMDone = '1') then
               textPalFetchNext <= 0;
               if (textPalFetchNext > 0) then
                  case (textPalFetchNext) is
                     when 3      => palSize <= PS_192;
                     when 2      => palSize <= PS_128;
                     when others => palSize <= PS_64;
                  end case;
                  state   <= REQUESTPALETTE;
                  palCont <= '1';
               else
                  state <= IDLE;
               end if;
            end if;
            if (vram_DOUT_READY = '1') then
               CLUTaddrA <= CLUTaddrA + 1;
            end if;
         end if;

         if (reset = '1') then

            state                   <= IDLE;
            stage0_flags(F_VALID)   <= '0';
            stage1_flags(F_VALID)   <= '0';
            stage3_flags(F_VALID)   <= '0';
            stage4_flags(F_VALID)   <= '0';
            stage5_valid            <= '0';
            stage6_valid            <= '0';
            textPalFetched          <= '0';

         elsif (ce = '1') then

            stage6_valid    <= '0';
            stage6_alphabit <= '0';
            stage6_c        <= (others => '0');
            stage6_y        <= (others => '0');
            stage6_x        <= (others => '0');

            pipeline_stall_1 <= pipeline_stall_i;

            -- fetch of texture and palette data
            case (state) is
               when IDLE =>
                  if (clearCacheBuffer = '1' and pipeline_busy_i = '0') then
                     clearCacheBuffer <= '0';
                     if (ep = to_unsigned(2**EPW - 1, EPW)) then
                        ep <= to_unsigned(1, EPW);
                     else
                        ep <= ep + 1;
                     end if;
                  end if;
                  if (textPalReq = '1' and pipeline_busy_i = '0') then
                     textPalReq     <= '0';
                     state          <= REQUESTPALETTE;
                     CLUTaddrA      <= (others => '0');
                     textPalFetched <= '1';
                     textPalX       <= textPalReqX;
                     textPalY       <= textPalReqY;
                     palCont        <= '0';
                     if (drawMode_in(7) = '1') then
                        case to_integer(textPalReqX) is
                           when 60     => palSize <= PS_64; textPalFetchNext <= 3;
                           when 56     => palSize <= PS_128; textPalFetchNext <= 2;
                           when 52     => palSize <= PS_192; textPalFetchNext <= 1;
                           when others => palSize <= PS_256; textPalFetchNext <= 0;
                        end case;
                     else
                        palSize <= PS_16;
                     end if;
                  elsif (stage0_flags(F_VALID) = '1' and stage0_flags(F_TEX) = '1' and cachehit = '0') then
                     state           <= REQUESTTEXTURE;
                     tag_data_a      <= d0;
                     tag_address_a   <= a0;
                  end if;

               when REQUESTTEXTURE =>
                  -- cannot wait for fifoOut_idle here as this would kill the performance completly
                  -- also it's totally unclear what real hardware does when primitives draw into their own texture
                  if (requestVRAMIdle = '1') then
                     state <= WAITTEXTURE;
                  end if;

               when WAITTEXTURE => null; -- handled outside due to ce

               when REQUESTPALETTE =>
                  if (requestVRAMIdle = '1' and fifoOut_idle = '1') then
                     state <= WAITPALETTE;
                  end if;

               when WAITPALETTE => null; -- handled outside due to ce
            end case;

            -- new palette request
            if (pipeline_busy_i = '0') then
               drawMode       <= drawMode_in;
               DrawPixelsMask <= DrawPixelsMask_in;
               SetMask        <= SetMask_in;
            end if;

            if (textPalInNew = '1' and drawMode_in(8) = '0' and (textPalFetched = '0' or textPalInX /= textPalX or textPalInY /= textPalY or palette8bit /= drawMode_in(7) or textPalReq = '1')) then
               textPalReq  <= not noTexture;
               textPalReqX <= textPalInX;
               textPalReqY <= textPalInY;
               palette8bit <= drawMode_in(7);
            end if;

            -- clear cache request
            if (clearCacheTexture = '1') then
               clearCacheBuffer <= '1';
            end if;

            if (clearCachePalette = '1') then
               textPalFetched   <= '0';
            end if;

            -- pixel pipeline
            if (pipeline_stall_i = '0') then

               -- the waiting pixel moves to stage 0, the one emitted now waits
               wp          <= wp_n;
               p_flags     <= pipeline_new & pipeline_texture & pipeline_transparent & pipeline_rawTexture & pipeline_dithering;
               p_u         <= pipeline_u;
               p_v         <= pipeline_v;
               a0          <= nxt_a;
               d0          <= nxt_d;
               stage0_flags(F_VALID) <= p_flags(F_VALID) and ((not DrawPixelsMask) or (not m_eff));
               stage0_flags(F_TEX)   <= p_flags(F_TEX) and (not noTexture);
               stage0_flags(F_TRANS) <= p_flags(F_TRANS);
               stage0_flags(F_RAW)   <= p_flags(F_RAW);
               stage0_flags(F_DITH)  <= p_flags(F_DITH) and ditherOn;
               stage0_u              <= p_u(3 downto 0);

               -- stage 1 - fetch texture
               stage1_flags <= stage0_flags;
               stage1_u     <= stage0_u;
               a1           <= a0;

               -- stage 2 - texture palette reading
               stage2_flags   <= stage1_flags;
               stage2_texdata <= texdata_raw;

               -- stage 3 - texel
               stage3_flags <= stage2_flags;
               stage3_tex   <= texdata_palette;

               -- stage 4 - dither offset
               stage4_flags     <= stage3_flags;
               stage4_tex       <= stage3_tex;

               -- stage 5 - apply blending or raw color
               stage5_valid       <= stage4_flags(F_VALID);
               stage5_transparent <= stage4_flags(F_TRANS);

               dd := s4_ditherAdd;
               tr := unsigned(stage4_tex( 4 downto  0));
               tg := unsigned(stage4_tex( 9 downto  5));
               tb := unsigned(stage4_tex(14 downto 10));
               if (stage4_flags(F_TEX) = '1') then
                  stage5_alphacheck <= stage4_tex(15);
                  stage5_alphabit   <= stage4_tex(15);
                  if (tr = 0 and tg = 0 and tb = 0 and stage4_tex(15) = '0') then
                     stage5_valid <= '0';
                  end if;
                  if (stage4_flags(F_RAW) = '1') then
                     stage5_c <= tb & tg & tr;
                  else
                     stage5_c <= modulate(tb, s4_c( 7 downto  0), stage4_flags(F_DITH), dd) &
                                 modulate(tg, s4_c(15 downto  8), stage4_flags(F_DITH), dd) &
                                 modulate(tr, s4_c(23 downto 16), stage4_flags(F_DITH), dd);
                  end if;
               else
                  stage5_c <= plain(s4_c( 7 downto  0), stage4_flags(F_DITH), dd) &
                              plain(s4_c(15 downto  8), stage4_flags(F_DITH), dd) &
                              plain(s4_c(23 downto 16), stage4_flags(F_DITH), dd);
                  stage5_alphacheck <= '1';
                  stage5_alphabit   <= '0';
               end if;

               -- stage 6 - apply alpha
               stage6_valid    <= stage5_valid;
               stage6_alphabit <= stage5_alphabit or SetMask;
               stage6_x        <= s5_x;
               stage6_y        <= s5_y;

               if (stage5_transparent = '1' and stage5_alphacheck = '1') then
                  stage6_c <= std_logic_vector(
                     blend(unsigned(s5_old(14 downto 10)), stage5_c(14 downto 10), drawMode(6 downto 5)) &
                     blend(unsigned(s5_old( 9 downto  5)), stage5_c( 9 downto  5), drawMode(6 downto 5)) &
                     blend(unsigned(s5_old( 4 downto  0)), stage5_c( 4 downto  0), drawMode(6 downto 5)));
               else
                  stage6_c <= std_logic_vector(stage5_c);
               end if;

            end if;

         end if;

      end if;
   end process;

   pixelColor <= stage6_alphabit & stage6_c;
   pixelAddr  <= stage6_y & stage6_x & '0';
   pixelWrite <= stage6_valid;

end architecture;
