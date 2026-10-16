-- SPU RAM interface of spu_pocket: capture buffers (first 4 KB) and the 64 KB reverb area (top 64 KB) on chip, the rest
-- forwarded to the sdram_* port. One request at a time; ram_done is the sdram_done of the request or, one clock after
-- the request, the done of an on-chip access. L1_CACHE adds the voice read cache (docs/pocket/SPU.md, "L1 block cache").
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library mem;

entity spu_pocket_ram is
   generic
   (
      L1_CACHE             : boolean := true
   );
   port
   (
      clk1x                : in  std_logic;
      reset                : in  std_logic;

      ram_dataWrite        : in  std_logic_vector(15 downto 0);
      ram_Adr              : in  std_logic_vector(18 downto 0);
      ram_request          : in  std_logic;
      ram_rnw              : in  std_logic;
      ram_dataRead         : out std_logic_vector(15 downto 0);
      ram_done             : out std_logic;
      ram_isVoice          : in  std_logic;
      ram_VoiceIndex       : in  integer range 0 to 23;

      sdram_dataWrite      : out std_logic_vector(31 downto 0);
      sdram_Adr            : out std_logic_vector(18 downto 0);
      sdram_be             : out std_logic_vector(3 downto 0);
      sdram_rnw            : out std_logic;
      sdram_ena            : out std_logic;
      sdram_dataRead       : in  std_logic_vector(31 downto 0);
      sdram_done           : in  std_logic
   );
end entity;

architecture arch of spu_pocket_ram is

   signal ram_isCapture       : std_logic;
   signal ram_ReverbSpace     : std_logic;
   signal captureram_we       : std_logic;
   signal reverbram_we        : std_logic;
   signal captureram_readdata : std_logic_vector(15 downto 0);
   signal reverbram_readdata  : std_logic_vector(15 downto 0);
   signal ram_processed       : std_logic := '0';
   signal sdram_space         : std_logic;

   -- L1: per voice one 16-byte block, tag + valid bit per 16-bit word
   signal l1_lookup           : std_logic;
   signal l1_hit              : std_logic;
   signal l1_hit_r            : std_logic := '0';
   signal l1_fill_pending     : std_logic := '0';
   signal l1_fill             : std_logic;
   signal l1_idx              : unsigned(4 downto 0);
   signal l1_word             : unsigned(2 downto 0);
   signal l1_tag_q            : std_logic_vector(14 downto 0);
   signal l1_valid_q          : std_logic_vector(7 downto 0);
   signal l1_tag_we           : std_logic;
   signal l1_tag_wa           : std_logic_vector(4 downto 0);
   signal l1_tag_wd           : std_logic_vector(14 downto 0);
   signal l1_valid_wd         : std_logic_vector(7 downto 0);
   signal l1_data_q           : std_logic_vector(15 downto 0);
   signal l1_sweep            : std_logic := '1';
   signal l1_sweep_cnt        : unsigned(4 downto 0) := (others => '0');
   signal sdram_ena_i         : std_logic;

begin

   sdram_space <= '1' when (ram_isCapture = '0' and ram_ReverbSpace = '0') else '0';

   ram_isCapture   <= '1' when (ram_Adr(18 downto 12) = "0000000") else '0';
   ram_ReverbSpace <= '1' when (ram_Adr(18 downto 16) = "111")     else '0';

   captureram_we <= '1' when (ram_request = '1' and ram_rnw = '0' and ram_isCapture = '1')   else '0';
   reverbram_we  <= '1' when (ram_request = '1' and ram_rnw = '0' and ram_ReverbSpace = '1') else '0';

   iram_capture : entity mem.dpram
   generic map (addr_width => 11, data_width => 16)
   port map
   (
      clock_a   => clk1x,
      address_a => ram_Adr(11 downto 1),
      data_a    => ram_dataWrite,
      wren_a    => captureram_we,
      q_a       => captureram_readdata,

      clock_b   => clk1x,
      address_b => (10 downto 0 => '0'),
      data_b    => x"0000",
      wren_b    => '0',
      q_b       => open
   );

   iram_reverb : entity mem.dpram
   generic map (addr_width => 15, data_width => 16)
   port map
   (
      clock_a   => clk1x,
      address_a => ram_Adr(15 downto 1),
      data_a    => ram_dataWrite,
      wren_a    => reverbram_we,
      q_a       => reverbram_readdata,

      clock_b   => clk1x,
      address_b => (14 downto 0 => '0'),
      data_b    => x"0000",
      wren_b    => '0',
      q_b       => open
   );

   sdram_dataWrite <= x"0000" & ram_dataWrite;
   sdram_Adr       <= ram_Adr;
   sdram_be        <= "0011";
   sdram_rnw       <= ram_rnw;
   sdram_ena_i     <= '0' when (sdram_space = '0' or l1_hit = '1') else ram_request;
   sdram_ena       <= sdram_ena_i;

   ram_dataRead    <= captureram_readdata         when (ram_isCapture = '1')   else
                      reverbram_readdata          when (ram_ReverbSpace = '1') else
                      l1_data_q                   when (l1_hit_r = '1')        else
                      sdram_dataRead(15 downto 0);

   ram_done        <= ram_processed or sdram_done or l1_hit_r;

   gL1 : if L1_CACHE generate
   begin
      l1_idx  <= to_unsigned(ram_VoiceIndex, 5);
      l1_word <= unsigned(ram_Adr(3 downto 1));

      l1_lookup <= '1' when (ram_request = '1' and ram_rnw = '1' and ram_isVoice = '1' and sdram_space = '1' and l1_sweep = '0') else '0';
      l1_hit    <= '1' when (l1_lookup = '1' and l1_tag_q = ram_Adr(18 downto 4) and l1_valid_q(to_integer(l1_word)) = '1') else '0';

      -- the response to a miss fills the word; a different block replaces the line
      l1_fill     <= '1' when (l1_fill_pending = '1' and sdram_done = '1' and l1_sweep = '0') else '0';
      l1_tag_we   <= '1' when (l1_sweep = '1') else l1_fill;
      l1_tag_wa   <= std_logic_vector(l1_sweep_cnt) when (l1_sweep = '1') else std_logic_vector(l1_idx);
      l1_tag_wd   <= ram_Adr(18 downto 4);
      l1_valid_wd <= (others => '0') when (l1_sweep = '1') else
                     (l1_valid_q or std_logic_vector(shift_left(to_unsigned(1, 8), to_integer(l1_word)))) when (l1_tag_q = ram_Adr(18 downto 4)) else
                     std_logic_vector(shift_left(to_unsigned(1, 8), to_integer(l1_word)));

      itag : entity mem.RamMLAB
      generic map (width => 15, widthad => 5, width_byteena => 1)
      port map (inclock => clk1x, wren => l1_tag_we, data => l1_tag_wd, wraddress => l1_tag_wa,
                rdaddress => std_logic_vector(l1_idx), q => l1_tag_q);

      ivalid : entity mem.RamMLAB
      generic map (width => 8, widthad => 5, width_byteena => 1)
      port map (inclock => clk1x, wren => l1_tag_we, data => l1_valid_wd, wraddress => l1_tag_wa,
                rdaddress => std_logic_vector(l1_idx), q => l1_valid_q);

      idata : entity mem.dpram
      generic map (addr_width => 8, data_width => 16)
      port map
      (
         clock_a   => clk1x,
         address_a => std_logic_vector(l1_idx) & std_logic_vector(l1_word),
         data_a    => sdram_dataRead(15 downto 0),
         wren_a    => l1_fill,
         q_a       => open,
         clock_b   => clk1x,
         address_b => std_logic_vector(l1_idx) & std_logic_vector(l1_word),
         data_b    => x"0000",
         wren_b    => '0',
         q_b       => l1_data_q
      );

      process (clk1x)
      begin
         if (rising_edge(clk1x)) then
            l1_hit_r <= l1_hit;
            if (reset = '1') then
               l1_fill_pending <= '0';
            elsif (ram_request = '1' and ram_rnw = '1' and ram_isVoice = '1' and sdram_space = '1' and l1_sweep = '0' and l1_hit = '0') then
               l1_fill_pending <= '1';
            elsif (sdram_done = '1') then
               l1_fill_pending <= '0';
            end if;
            -- a write to SPU RAM, and reset, invalidate every line
            if (reset = '1' or (ram_request = '1' and ram_rnw = '0' and sdram_space = '1')) then
               l1_sweep     <= '1';
               l1_sweep_cnt <= (others => '0');
            elsif (l1_sweep = '1') then
               l1_sweep_cnt <= l1_sweep_cnt + 1;
               if (l1_sweep_cnt = 23) then
                  l1_sweep <= '0';
               end if;
            end if;
         end if;
      end process;
   end generate;

   gNoL1 : if not L1_CACHE generate
   begin
      l1_hit    <= '0';
      l1_hit_r  <= '0';
      l1_data_q <= (others => '0');
   end generate;

   process (clk1x)
   begin
      if (rising_edge(clk1x)) then
         ram_processed <= '0';
         if (reset = '0' and ram_request = '1' and (ram_isCapture = '1' or ram_ReverbSpace = '1')) then
            ram_processed <= '1';
         end if;
      end if;
   end process;

end architecture;
