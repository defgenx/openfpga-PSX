library ieee; use ieee.std_logic_1164.all;
entity tb_inout is end;
architecture a of tb_inout is
  component vio is port(en, d: in std_logic; pin: inout std_logic); end component;
  signal en, d: std_logic := '0'; signal b: std_logic;
begin
  u: component vio port map (en => en, d => d, pin => b);
end;
