-- defNsArc.vhd

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package defNsArc is

  -- ARC header structure ----------------------------------------------
  -- | 31          24 23          16 15             8 7            0 |
  -- +---------------+---------------+---------------+---------------+
  -- |  Magic (0x5A) |Ver(4)| Cmd(4) |    Mode (8)   |   Flags (8)   |
  -- +---------------+---------------+---------------+---------------+
  -- |         Length (16)          |       Reserved (16)            |
  -- +---------------+---------------+---------------+---------------+
  -- |                         Address (32)                          |
  -- +---------------------------------------------------------------+

  -- ARC packet version --
  constant kArcVersion    : std_logic_vector(3 downto 0):= "0001";

  -- ARC header field positions --
  constant kPosArcVerCmd  : std_logic_vector(87 downto 80):= (others => '0');
  constant kPosArcMode    : std_logic_vector(79 downto 72):= (others => '0');
  constant kPosArcFlag    : std_logic_vector(71 downto 64):= (others => '0');
  constant kPosArcLen     : std_logic_vector(63 downto 48):= (others => '0');
  constant kPosArcRsv     : std_logic_vector(47 downto 32):= (others => '0');
  constant kPosArcAddr    : std_logic_vector(31 downto 0):= (others => '0');

  -- ARC mode bits --
  constant kArcModeList    : std_logic_vector(7 downto 0):= "00000001";
  constant kArcModeAutoInc : std_logic_vector(7 downto 0):= "00000010";

  -- ARC flag bits --
  constant kArcFlagAck     : std_logic_vector(7 downto 0):= "00000001";
  constant kArcFlagUdpErr  : std_logic_vector(7 downto 0):= "00000010";
  constant kArcFlagBusErr  : std_logic_vector(7 downto 0):= "00000100";

  -- ARC command codes --
  constant kArcCmdRead       : std_logic_vector(3 downto 0):= "0001"; -- For external bus
  constant kArcCmdWrite      : std_logic_vector(3 downto 0):= "0010"; -- For external bus
  constant kArcCmdIntRead    : std_logic_vector(3 downto 0):= "0011"; -- For internal bus
  constant kArcCmdIntWrite   : std_logic_vector(3 downto 0):= "0100"; -- For internal bus

  -- ARC length parameters --
  constant kMaxPayloadLen  : std_logic_vector(15 downto 0):= x"0400"; -- 1024 bytes

  -- Stack FIFO IO types --
  type fifo_out_types is record
    data_out    : std_logic_vector;
    read_valid  : std_logic;
    empty       : std_logic;
    full        : std_logic;
    almost_full : std_logic;
    prog_full   : std_logic;
  end record;

  type fifo_in_types is record
    data_in  : std_logic_vector;
    write_en : std_logic;
    read_en  : std_logic;
  end record;

  -- Utility functions --
  function compareMagic(index : integer; data  : std_logic_vector ) return boolean;
  function compareCmd( cmd : std_logic_vector ) return boolean;
  function isWriteCmd( cmd : std_logic_vector ) return boolean;
  function isReadCmd(  cmd : std_logic_vector ) return boolean;
  function isInternalCmd(  cmd : std_logic_vector ) return boolean;

end package defNsArc;

package body defNsArc is
    function compareMagic(
    index : integer;
    data  : std_logic_vector
  ) return boolean is
    constant  kMagic  : std_logic_vector(7 downto 0):= X"5A";

  begin
    if(kMagic(8*(index+1)-1 downto 8*index) = data) then
      return true;
    else
      return false;
    end if;
  end function;

  function compareCmd(
    cmd : std_logic_vector
  ) return boolean is
  begin
    if(kArcCmdRead = cmd) then
      return true;
    elsif(kArcCmdWrite = cmd) then
      return true;
    elsif(kArcCmdIntRead = cmd) then
      return true;
    elsif(kArcCmdIntWrite = cmd) then
      return true;
    else
      return false;
    end if;
  end function;

  function isWriteCmd(
    cmd : std_logic_vector
  ) return boolean is
  begin
    if(kArcCmdWrite = cmd) then
      return true;
    elsif(kArcCmdIntWrite = cmd) then
      return true;
    else
      return false;
    end if;
  end function;

  function isReadCmd(
    cmd : std_logic_vector
  ) return boolean is
  begin
    if(kArcCmdRead = cmd) then
      return true;
    elsif(kArcCmdIntRead = cmd) then
      return true;
    else
      return false;
    end if;
  end function;

  function isInternalCmd(
    cmd : std_logic_vector
  ) return boolean is
  begin
    if(kArcCmdIntRead = cmd) then
      return true;
    elsif(kArcCmdIntWrite = cmd) then
      return true;
    else
      return false;
    end if;
  end function;


end package body defNsArc;
