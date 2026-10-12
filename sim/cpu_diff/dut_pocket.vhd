-- DUT flavour "pocket": cpu_pocket, savestate ports tied like the Pocket top does.
architecture pocket of cpu_dut is
begin
   icpu : entity work.cpu_pocket
   generic map (NO_COP0_DEBUG => G_NO_COP0_DEBUG)
   port map
   (
      clk1x => clk1x, clk2x => clk2x, clk3x => clk3x, ce => ce, reset => reset,
      TURBO => TURBO, TURBO_CACHE => TURBO_CACHE, TURBO_CACHE50 => TURBO_CACHE50,
      irqRequest => irqRequest, dmaStallCPU => dmaStallCPU, cpuPaused => cpuPaused,
      error => error, error2 => error2,
      mem_request => mem_request, mem_rnw => mem_rnw, mem_isData => mem_isData, mem_isCache => mem_isCache,
      mem_oldtagvalids => mem_oldtagvalids, mem_addressInstr => mem_addressInstr, mem_addressData => mem_addressData,
      mem_reqsize => mem_reqsize, mem_writeMask => mem_writeMask, mem_dataWrite => mem_dataWrite,
      mem_dataRead => mem_dataRead, mem_done => mem_done, mem_fifofull => mem_fifofull, mem_tagvalids => mem_tagvalids,
      cache_wr => cache_wr, cache_data => cache_data, cache_addr => cache_addr,
      stallNext => stallNext,
      dma_cache_Adr => dma_cache_Adr, dma_cache_data => dma_cache_data, dma_cache_write => dma_cache_write,
      ram_done => ram_done, ram_rnw => ram_rnw, ram_dataRead => ram_dataRead,
      gte_busy => gte_busy, gte_readEna => gte_readEna, gte_readAddr => gte_readAddr, gte_readData => gte_readData,
      gte_writeAddr => gte_writeAddr, gte_writeData => gte_writeData, gte_writeEna => gte_writeEna,
      gte_cmdData => gte_cmdData, gte_cmdEna => gte_cmdEna,
      SS_reset => SS_reset, SS_DataWrite => (others => '0'), SS_Adr => (others => '0'),
      SS_wren_CPU => '0', SS_wren_SCP => '0', SS_rden_CPU => '0', SS_rden_SCP => '0',
      SS_DataRead_CPU => open, SS_DataRead_SCP => open, SS_idle => SS_idle,
      cpu_done => cpu_done, cpu_export => cpu_export,
      debug_firstGTE => '0'
   );
end architecture;
