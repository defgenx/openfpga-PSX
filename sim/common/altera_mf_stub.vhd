-- Behavioural stand-ins for the altera_mf primitives the rtl/ sources instantiate (altsyncram, altdpram).
-- Library altera_mf, package altera_mf_components. Only the generics and ports rtl/ uses are modelled:
--  altsyncram: BIDIR_DUAL_PORT, independent widths, byte enables, registered address/data, unregistered q
--              (q follows the address registered at the clock edge; a write on the same edge is seen: new data)
--  altdpram:   one write port (registered on inclock), asynchronous read port
-- Memory powers up as zeros (power_up_uninitialized => FALSE).
library ieee;
use ieee.std_logic_1164.all;

package altera_mf_components is
   component altsyncram
      generic (
         address_reg_b                 : string  := "CLOCK1";
         clock_enable_input_a          : string  := "NORMAL";
         clock_enable_input_b          : string  := "NORMAL";
         clock_enable_output_a         : string  := "NORMAL";
         clock_enable_output_b         : string  := "NORMAL";
         indata_reg_b                  : string  := "CLOCK1";
         init_file                     : string  := "UNUSED";
         intended_device_family        : string  := "Cyclone V";
         lpm_type                      : string  := "altsyncram";
         numwords_a                    : natural := 0;
         numwords_b                    : natural := 0;
         operation_mode                : string  := "BIDIR_DUAL_PORT";
         outdata_aclr_a                : string  := "NONE";
         outdata_aclr_b                : string  := "NONE";
         outdata_reg_a                 : string  := "UNREGISTERED";
         outdata_reg_b                 : string  := "UNREGISTERED";
         power_up_uninitialized        : string  := "FALSE";
         read_during_write_mode_port_a : string  := "NEW_DATA_NO_NBE_READ";
         read_during_write_mode_port_b : string  := "NEW_DATA_NO_NBE_READ";
         widthad_a                     : natural := 1;
         widthad_b                     : natural := 1;
         width_a                       : natural := 1;
         width_b                       : natural := 1;
         width_byteena_a               : natural := 1;
         width_byteena_b               : natural := 1;
         wrcontrol_wraddress_reg_b     : string  := "CLOCK1"
      );
      port (
         address_a : in  std_logic_vector(widthad_a-1 downto 0) := (others => '0');
         address_b : in  std_logic_vector(widthad_b-1 downto 0) := (others => '0');
         byteena_a : in  std_logic_vector(width_byteena_a-1 downto 0) := (others => '1');
         byteena_b : in  std_logic_vector(width_byteena_b-1 downto 0) := (others => '1');
         clock0    : in  std_logic := '1';
         clock1    : in  std_logic := '1';
         clocken0  : in  std_logic := '1';
         clocken1  : in  std_logic := '1';
         data_a    : in  std_logic_vector(width_a-1 downto 0) := (others => '1');
         data_b    : in  std_logic_vector(width_b-1 downto 0) := (others => '1');
         wren_a    : in  std_logic := '0';
         wren_b    : in  std_logic := '0';
         q_a       : out std_logic_vector(width_a-1 downto 0);
         q_b       : out std_logic_vector(width_b-1 downto 0)
      );
   end component;

   component altdpram
      generic (
         indata_aclr                        : string  := "OFF";
         indata_reg                         : string  := "INCLOCK";
         intended_device_family             : string  := "Cyclone V";
         lpm_type                           : string  := "altdpram";
         outdata_aclr                       : string  := "OFF";
         outdata_reg                        : string  := "UNREGISTERED";
         ram_block_type                     : string  := "MLAB";
         rdaddress_aclr                     : string  := "OFF";
         rdaddress_reg                      : string  := "UNREGISTERED";
         rdcontrol_aclr                     : string  := "OFF";
         rdcontrol_reg                      : string  := "UNREGISTERED";
         read_during_write_mode_mixed_ports : string  := "CONSTRAINED_DONT_CARE";
         width                              : natural := 1;
         widthad                            : natural := 1;
         width_byteena                      : natural := 1;
         wraddress_aclr                     : string  := "OFF";
         wraddress_reg                      : string  := "INCLOCK";
         wrcontrol_aclr                     : string  := "OFF";
         wrcontrol_reg                      : string  := "INCLOCK"
      );
      port (
         inclock   : in  std_logic := '1';
         wren      : in  std_logic := '0';
         data      : in  std_logic_vector(width-1 downto 0);
         wraddress : in  std_logic_vector(widthad-1 downto 0);
         rdaddress : in  std_logic_vector(widthad-1 downto 0);
         q         : out std_logic_vector(width-1 downto 0)
      );
   end component;
end package;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity altsyncram is
   generic (
      address_reg_b                 : string  := "CLOCK1";
      clock_enable_input_a          : string  := "NORMAL";
      clock_enable_input_b          : string  := "NORMAL";
      clock_enable_output_a         : string  := "NORMAL";
      clock_enable_output_b         : string  := "NORMAL";
      indata_reg_b                  : string  := "CLOCK1";
      init_file                     : string  := "UNUSED";
      intended_device_family        : string  := "Cyclone V";
      lpm_type                      : string  := "altsyncram";
      numwords_a                    : natural := 0;
      numwords_b                    : natural := 0;
      operation_mode                : string  := "BIDIR_DUAL_PORT";
      outdata_aclr_a                : string  := "NONE";
      outdata_aclr_b                : string  := "NONE";
      outdata_reg_a                 : string  := "UNREGISTERED";
      outdata_reg_b                 : string  := "UNREGISTERED";
      power_up_uninitialized        : string  := "FALSE";
      read_during_write_mode_port_a : string  := "NEW_DATA_NO_NBE_READ";
      read_during_write_mode_port_b : string  := "NEW_DATA_NO_NBE_READ";
      widthad_a                     : natural := 1;
      widthad_b                     : natural := 1;
      width_a                       : natural := 1;
      width_b                       : natural := 1;
      width_byteena_a               : natural := 1;
      width_byteena_b               : natural := 1;
      wrcontrol_wraddress_reg_b     : string  := "CLOCK1"
   );
   port (
      address_a : in  std_logic_vector(widthad_a-1 downto 0) := (others => '0');
      address_b : in  std_logic_vector(widthad_b-1 downto 0) := (others => '0');
      byteena_a : in  std_logic_vector(width_byteena_a-1 downto 0) := (others => '1');
      byteena_b : in  std_logic_vector(width_byteena_b-1 downto 0) := (others => '1');
      clock0    : in  std_logic := '1';
      clock1    : in  std_logic := '1';
      clocken0  : in  std_logic := '1';
      clocken1  : in  std_logic := '1';
      data_a    : in  std_logic_vector(width_a-1 downto 0) := (others => '1');
      data_b    : in  std_logic_vector(width_b-1 downto 0) := (others => '1');
      wren_a    : in  std_logic := '0';
      wren_b    : in  std_logic := '0';
      q_a       : out std_logic_vector(width_a-1 downto 0);
      q_b       : out std_logic_vector(width_b-1 downto 0)
   );
end entity;

architecture sim of altsyncram is
   constant BITS_A : natural := (2**widthad_a) * width_a;
begin
   assert BITS_A = (2**widthad_b) * width_b report "altsyncram: port sizes differ" severity failure;

   process (clock0, clock1)
      -- bit i of the array is bit (i mod w) of word (i / w) on a port of width w
      variable mem : std_logic_vector(BITS_A-1 downto 0) := (others => '0');

      procedure access_port(addr : std_logic_vector; w, nbe : natural; wren : std_logic;
                            data, be : std_logic_vector; q : out std_logic_vector) is
         variable base  : natural := to_integer(unsigned(addr)) * w;
         variable bsize : natural := w / nbe;
      begin
         if wren = '1' then
            for i in 0 to w-1 loop
               if be(i / bsize) = '1' then
                  mem(base + i) := data(i);
               end if;
            end loop;
         end if;
         q := mem(base + w - 1 downto base);
      end procedure;

      variable qa : std_logic_vector(width_a-1 downto 0);
      variable qb : std_logic_vector(width_b-1 downto 0);
   begin
      if rising_edge(clock0) and clocken0 = '1' then
         access_port(address_a, width_a, width_byteena_a, wren_a, data_a, byteena_a, qa);
         q_a <= qa;
      end if;
      if rising_edge(clock1) and clocken1 = '1' then
         access_port(address_b, width_b, width_byteena_b, wren_b, data_b, byteena_b, qb);
         q_b <= qb;
      end if;
   end process;
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity altdpram is
   generic (
      indata_aclr                        : string  := "OFF";
      indata_reg                         : string  := "INCLOCK";
      intended_device_family             : string  := "Cyclone V";
      lpm_type                           : string  := "altdpram";
      outdata_aclr                       : string  := "OFF";
      outdata_reg                        : string  := "UNREGISTERED";
      ram_block_type                     : string  := "MLAB";
      rdaddress_aclr                     : string  := "OFF";
      rdaddress_reg                      : string  := "UNREGISTERED";
      rdcontrol_aclr                     : string  := "OFF";
      rdcontrol_reg                      : string  := "UNREGISTERED";
      read_during_write_mode_mixed_ports : string  := "CONSTRAINED_DONT_CARE";
      width                              : natural := 1;
      widthad                            : natural := 1;
      width_byteena                      : natural := 1;
      wraddress_aclr                     : string  := "OFF";
      wraddress_reg                      : string  := "INCLOCK";
      wrcontrol_aclr                     : string  := "OFF";
      wrcontrol_reg                      : string  := "INCLOCK"
   );
   port (
      inclock   : in  std_logic := '1';
      wren      : in  std_logic := '0';
      data      : in  std_logic_vector(width-1 downto 0);
      wraddress : in  std_logic_vector(widthad-1 downto 0);
      rdaddress : in  std_logic_vector(widthad-1 downto 0);
      q         : out std_logic_vector(width-1 downto 0)
   );
end entity;

architecture sim of altdpram is
begin
   process (inclock, rdaddress)
      type ram_t is array (0 to 2**widthad-1) of std_logic_vector(width-1 downto 0);
      variable mem : ram_t := (others => (others => '0'));
   begin
      if rising_edge(inclock) and wren = '1' then
         mem(to_integer(unsigned(wraddress))) := data;
      end if;
      q <= mem(to_integer(unsigned(rdaddress)));
   end process;
end architecture;
