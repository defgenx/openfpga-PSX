library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pGPU_pocket.all;

-- Probe of one side's polygon unit. span.valid pulses on the clk2x edge after a non-skipped PREPARELINE;
-- issue pulses on entering ISSUE. The architecture (and its hierarchical paths) is specific to the side:
--   span_probe_gold  span_probe_gold.vhd         the frozen gpu (built from build/gpu_poly_dbg.vhd)
--   span_probe_dut   span_dut_golden.vhd or span_dut_pocket.vhd, chosen by the Makefile
entity span_probe_gold is
   port (clk2x : in std_logic; span : out t_span; issue : out std_logic);
end entity;

library IEEE;
use IEEE.std_logic_1164.all;
use work.pGPU_pocket.all;

entity span_probe_dut is
   port (clk2x : in std_logic; span : out t_span; issue : out std_logic);
end entity;
