-- Behavioural check of altera_mf_stub.vhd through the rtl/ wrappers that instantiate it.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;
library altera_mf;
use altera_mf.altera_mf_components.all;

entity altera_mf_tb is
end entity;

architecture sim of altera_mf_tb is
   signal ca, cb : std_logic := '0';
   -- rtl/dpram.vhd: dpram 4 x 8
   signal a_addr, b_addr : std_logic_vector(3 downto 0) := (others => '0');
   signal a_data, b_data, a_q, b_q : std_logic_vector(7 downto 0) := (others => '0');
   signal a_we : std_logic := '0';
   -- rtl/dpram.vhd: dpram_dif, a 8 x 16 and b 16 x 8
   signal d_aaddr : std_logic_vector(2 downto 0) := (others => '0');
   signal d_baddr : std_logic_vector(3 downto 0) := (others => '0');
   signal d_adata, d_aq : std_logic_vector(15 downto 0) := (others => '0');
   signal d_bq : std_logic_vector(7 downto 0);
   signal d_we : std_logic := '0';
   -- rtl/RamMLAB.vhd: 4 x 8
   signal m_wr, m_rd : std_logic_vector(3 downto 0) := (others => '0');
   signal m_data, m_q : std_logic_vector(7 downto 0) := (others => '0');
   signal m_we : std_logic := '0';
   -- altsyncram with byte enables, 32 bit
   signal e_addr : std_logic_vector(2 downto 0) := (others => '0');
   signal e_data, e_q : std_logic_vector(31 downto 0) := (others => '0');
   signal e_be : std_logic_vector(3 downto 0) := (others => '0');
   signal e_we : std_logic := '0';
   signal e_qb : std_logic_vector(31 downto 0);
begin
   ca <= not ca after 5 ns;
   cb <= not cb after 7 ns;

   i_dp : entity work.dpram generic map (addr_width => 4, data_width => 8)
      port map (clock_a => ca, address_a => a_addr, data_a => a_data, wren_a => a_we, q_a => a_q,
                clock_b => cb, address_b => b_addr, data_b => b_data, q_b => b_q);

   i_dif : entity work.dpram_dif generic map (addr_width_a => 3, data_width_a => 16, addr_width_b => 4, data_width_b => 8)
      port map (clock_a => ca, address_a => d_aaddr, data_a => d_adata, wren_a => d_we, q_a => d_aq,
                clock_b => cb, address_b => d_baddr, q_b => d_bq);

   i_ml : entity work.RamMLAB generic map (width => 8, widthad => 4)
      port map (inclock => ca, wren => m_we, data => m_data, wraddress => m_wr, rdaddress => m_rd, q => m_q);

   i_be : altsyncram
      generic map (numwords_a => 8, numwords_b => 8, operation_mode => "BIDIR_DUAL_PORT", widthad_a => 3, widthad_b => 3,
                   width_a => 32, width_b => 32, width_byteena_a => 4, width_byteena_b => 4)
      port map (address_a => e_addr, address_b => e_addr, clock0 => ca, clock1 => cb, data_a => e_data, wren_a => e_we,
                byteena_a => e_be, q_a => e_q, q_b => e_qb);

   process
      variable l : line;
      variable bad : natural := 0;
      procedure expect(what : string; got, want : std_logic_vector) is
      begin
         if got /= want then
            bad := bad + 1;
            write(l, "STUBCHECK " & what & " got=" & to_hstring(got) & " want=" & to_hstring(want));
            writeline(output, l);
         end if;
      end procedure;
   begin
      -- dpram: write on A, read on B; write-through on A
      wait until falling_edge(ca);
      a_addr <= x"3"; a_data <= x"A5"; a_we <= '1';
      wait until rising_edge(ca); wait for 1 ns;
      expect("dpram write-through q_a", a_q, x"A5");
      a_we <= '0';
      b_addr <= x"3";
      wait until rising_edge(cb); wait for 1 ns;
      expect("dpram cross-port q_b", b_q, x"A5");
      b_addr <= x"4";
      wait until rising_edge(cb); wait for 1 ns;
      expect("dpram zero fill", b_q, x"00");
      -- dpram_dif: 16 bit word 1 is bytes 2 (low) and 3 (high) on the 8 bit port
      wait until falling_edge(ca);
      d_aaddr <= "001"; d_adata <= x"BEEF"; d_we <= '1';
      wait until rising_edge(ca); wait for 1 ns;
      d_we <= '0'; d_baddr <= x"2";
      wait until rising_edge(cb); wait for 1 ns;
      expect("dpram_dif low byte", d_bq, x"EF");
      d_baddr <= x"3";
      wait until rising_edge(cb); wait for 1 ns;
      expect("dpram_dif high byte", d_bq, x"BE");
      -- RamMLAB: asynchronous read of the written word
      wait until falling_edge(ca);
      m_wr <= x"5"; m_data <= x"3C"; m_we <= '1'; m_rd <= x"5";
      wait until rising_edge(ca); wait for 1 ns;
      expect("RamMLAB read", m_q, x"3C");
      m_we <= '0'; m_rd <= x"6"; wait for 1 ns;
      expect("RamMLAB other address", m_q, x"00");
      -- byte enables: write all, then only bytes 0 and 2
      wait until falling_edge(ca);
      e_addr <= "010"; e_data <= x"11223344"; e_be <= "1111"; e_we <= '1';
      wait until rising_edge(ca);
      wait until falling_edge(ca);
      e_data <= x"AABBCCDD"; e_be <= "0101";
      wait until rising_edge(ca); wait for 1 ns;
      e_we <= '0';
      expect("altsyncram byteena", e_q, x"11BB33DD");
      wait until rising_edge(cb); wait for 1 ns;
      expect("altsyncram q_b", e_qb, x"11BB33DD");
      if bad = 0 then
         write(l, string'("STUBCHECK PASS"));
         writeline(output, l);
         stop(0);
      else
         write(l, string'("STUBCHECK FAIL"));
         writeline(output, l);
         stop(1);
      end if;
   end process;
end architecture;
