library ieee; use ieee.std_logic_1164.all;
entity tb_vhdl_top is end;
architecture a of tb_vhdl_top is
  component vmod is port(clk: in std_logic; a: in std_logic_vector(7 downto 0); q: out std_logic_vector(7 downto 0)); end component;
  component vhmod is port(clk: in std_logic; d: in std_logic_vector(7 downto 0); q: out std_logic_vector(7 downto 0)); end component;
  signal clk: std_logic := '0'; signal a, m, q: std_logic_vector(7 downto 0);
begin
  clk <= not clk after 5 ns;
  u1: component vhmod port map (clk => clk, d => a, q => m);
  u2: component vmod port map (clk => clk, a => m, q => q);
  process begin a <= x"10"; wait for 30 ns; assert q = x"13" report "bad q" severity failure; report "PASS"; std.env.finish; end process;
end;
