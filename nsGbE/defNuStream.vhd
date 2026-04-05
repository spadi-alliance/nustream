-- defNuStream.vhd

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package defNuStream is

  -- NuStream specific definitions
  constant kHeaderLength       : integer := 4;
  -- Preamble(8) + FrameID(23) --
  constant kPreamble           : std_logic_vector(7 downto 0) := X"AB";

  -- Tx definitions --
  constant kDefaultDstIpAddr  : std_logic_vector(31 downto 0) := X"c0a80a02"; -- 192.168.10.2
  constant kDefaultSrcPort    : std_logic_vector(15 downto 0) := X"138d"; -- 5005
  constant kDefaultDstPort    : std_logic_vector(15 downto 0) := X"138e"; -- 5006

  constant kNumCtrlReg         : integer := 7;

  constant kMaxLengthId       : integer := 0;
  constant kTimeoutLengthId   : integer := 1;
  constant kTimeoutLimitId    : integer := 2;
  constant kLengthMarginId    : integer := 3;
  constant kIdleWaitingTimeId : integer := 4;
  constant kDstIpAddrId       : integer := 5;
  constant kDstPortId         : integer := 6;

  constant kDefaultMaxLen           : unsigned(15 downto 0) := X"0100";
  constant kDefaultTimeoutLen       : unsigned(15 downto 0) := X"0010";
  constant kDefaultTimeoutLimit     : unsigned(15 downto 0) := X"3000";
  constant kDefaultLengthMargin     : unsigned(15 downto 0) := X"0003";
  constant kDefaultIdleWaitingTime  : unsigned(15 downto 0) := X"002F";



end package defNuStream;

