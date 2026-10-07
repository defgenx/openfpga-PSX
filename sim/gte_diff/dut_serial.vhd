-- DUT flavour "serial": the replacement core. clk4x / clk4xIndex are left
-- unconnected until the core takes them.
architecture serial of gte_dut is
begin
   igte : entity work.gte_serial
   port map
   (
      clk1x                => clk1x,
      clk2x                => clk2x,
      clk2xIndex           => clk2xIndex,
      ce                   => ce,
      reset                => reset,
      WIDESCREEN           => WIDESCREEN,
      TURBO                => TURBO,
      gte_busy             => gte_busy,
      gte_readAddr         => gte_readAddr,
      gte_readData         => gte_readData,
      gte_readEna          => gte_readEna,
      gte_writeAddr_in     => gte_writeAddr_in,
      gte_writeData_in     => gte_writeData_in,
      gte_writeEna_in      => gte_writeEna_in,
      gte_cmdData          => gte_cmdData,
      gte_cmdEna           => gte_cmdEna,
      loading_savestate    => loading_savestate,
      SS_reset             => SS_reset,
      SS_DataWrite         => SS_DataWrite,
      SS_Adr               => SS_Adr,
      SS_wren              => SS_wren,
      SS_rden              => SS_rden,
      SS_DataRead          => SS_DataRead,
      SS_idle              => SS_idle,
      debug_firstGTE       => debug_firstGTE
   );
end architecture;
