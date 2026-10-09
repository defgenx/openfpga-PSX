library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity vhmod is port(clk: in std_logic; d: in std_logic_vector(7 downto 0); q: out std_logic_vector(7 downto 0)); end;
architecture a of vhmod is begin
  process(clk) begin if rising_edge(clk) then q <= std_logic_vector(unsigned(d)+2); end if; end process;
end;
