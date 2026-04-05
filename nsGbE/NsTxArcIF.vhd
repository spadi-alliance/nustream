library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.defNsArcBus.all;
use work.defNuStream.all;

entity TxArcIF is
  generic(
    kAddrOffset         : std_logic_vector(15 downto 0):= x"0000";
    kEnDebug            : boolean := false
  );
  port (
    -- system signals
    reset               : in  STD_LOGIC;
    clk	                : in  STD_LOGIC;

    -- Register output --
    ctrlRegData         : out arcDataArrayAbst(kNumCtrlReg - 1 downto 0);

    -- External bus signals
    busDataIn           : in  std_logic_vector(kArcBusDataWidth-1 downto 0);
    busDataOut          : out std_logic_vector(kArcBusDataWidth-1 downto 0);
    busAddress          : in  std_logic_vector(kArcBusAddrWidth-1 downto 0);
    busRW               : in  std_logic_vector(1 downto 0);
    busAck              : out std_logic
  );
end TxArcIF;


architecture RTL of TxArcIF is

  attribute mark_debug  : boolean;

  -- Internal signal declaration ---------------------------------------
  type DefStateBus is (Idle, Connect, Write, Read, Finalize, Done);
  signal state_bus : DefStateBus;

  signal reg_rw : std_logic_vector(1 downto 0);

  signal reg_ctrl       : arcDataArrayAbst(kNumCtrlReg - 1 downto 0);

  function makeIndex(addr : std_logic_vector) return integer is
    variable idx : integer;
  begin
    case addr(15 downto 0) is
      when x"0000" => idx := kMaxLengthId      ;
      when x"0001" => idx := kTimeoutLengthId  ;
      when x"0002" => idx := kTimeoutLimitId   ;
      when x"0003" => idx := kLengthMarginId   ;
      when x"0004" => idx := kIdleWaitingTimeId;
      when x"0005" => idx := kDstIpAddrId      ;
      when x"0006" => idx := kDstPortId        ;
      when others => idx := -1; -- Invalid address
    end case;
    return idx;
  end function;

  -- debug --------------------------------------------------------------
  attribute mark_debug of state_bus      : signal is kEnDebug;
  attribute mark_debug of busRW          : signal is kEnDebug;
  attribute mark_debug of busAddress     : signal is kEnDebug;
  attribute mark_debug of reg_ctrl       : signal is kEnDebug;

begin
  -- =========================== body ===============================

  ctrlRegData <= reg_ctrl;

  process(reset, clk)
  begin
    if(reset='1') then
      busAck      <= '0';
      busDataOut  <= (others=>'Z');
      reg_rw      <= (others=>'0');
      reg_ctrl(kMaxLengthId)        <= X"0000" & std_logic_vector(kDefaultMaxLen);
      reg_ctrl(kTimeoutLengthId)    <= X"0000" & std_logic_vector(kDefaultTimeoutLen);
      reg_ctrl(kTimeoutLimitId)     <= X"0000" & std_logic_vector(kDefaultTimeoutLimit);
      reg_ctrl(kLengthMarginId)     <= X"0000" & std_logic_vector(kDefaultLengthMargin);
      reg_ctrl(kIdleWaitingTimeId)  <= X"0000" & std_logic_vector(kDefaultIdleWaitingTime);
      reg_ctrl(kDstIpAddrId)        <= kDefaultDstIpAddr;
      reg_ctrl(kDstPortId)          <= X"0000" & kDefaultDstPort;

      state_bus   <= Idle;
    elsif(clk'event and clk = '1') then
      reg_rw    <= busRW;

      case state_bus is
        when Idle =>
          busAck    <= '0';
          busDataOut<= (others=>'Z');
          if(busRW /= "00" and reg_rw = "00") then
            state_bus <= Connect;
          end if;

        when Connect =>
          if(busRW = kArcBusWrite) then
            state_bus <= Write;
          elsif(busRW = kArcBusRead) then
            state_bus <= Read;
          else
            state_bus <= Idle;
          end if;

        when Write =>
          if(makeIndex(busAddress(15 downto 0)) = -1) then
            -- Bus error. Does not return ACK.
            state_bus <= Done;
          else
            reg_ctrl(makeIndex(busAddress(15 downto 0))) <= busDataIn;
            state_bus <= Finalize;
          end if;

        when Read =>
          if(makeIndex(busAddress(15 downto 0)) = -1) then
            -- Bus error. Does not return ACK.
            busDataOut <= (others=>'Z');
            state_bus <= Done;
          else
            busDataOut <= reg_ctrl(makeIndex(busAddress(15 downto 0)));
            state_bus <= Finalize;
          end if;

        when Finalize =>
          busAck    <= '1';
          state_bus <= Done;

        when Done =>
          busAck    <= '0';
          state_bus <= Idle;

        when others =>
          busAck      <= '0';
          busDataOut  <= (others=>'Z');

      end case;
    end if;
  end process;

end RTL;

