-- defNsArcBus.vhd

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package defNsArcBus is

  constant kArcBusAddrWidth : integer := 32;
  constant kArcBusDataWidth : integer := 32;

  subtype arcBusDataType is std_logic_vector(kArcBusDataWidth-1 downto 0);
  subtype arcBusAddrType is std_logic_vector(kArcBusAddrWidth-1 downto 0);

  type arcDataArrayAbst is array (natural range <>) of arcBusDataType;

  constant kArcBusRead       : std_logic_vector(1 downto 0) :="10";
  constant kArcBusWrite      : std_logic_vector(1 downto 0) :="01";

end package defNsArcBus;
