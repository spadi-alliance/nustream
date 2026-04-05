library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.defNsArcBus.all;

entity DummySecond is
  generic(
    kAddrOffset         : std_logic_vector(7 downto 0):= x"00"
  );
  port (
    -- system signals
    reset               : in  STD_LOGIC;
    clk	                : in  STD_LOGIC;

    -- External bus signals
    busDataIn           : in  std_logic_vector(kArcBusDataWidth-1 downto 0);
    busDataOut          : out std_logic_vector(kArcBusDataWidth-1 downto 0);
    busAddress          : in  std_logic_vector(kArcBusAddrWidth-1 downto 0);
    busRW               : in  std_logic_vector(1 downto 0);
    busAck              : out std_logic
  );
end DummySecond;


architecture RTL of DummySecond is

  attribute mark_debug  : string;

  -- Internal signal declaration ---------------------------------------
  type DefStateBus is (Idle, Connect, Write, Read, Finalize, Done);
  signal state_bus : DefStateBus;

  signal reg_rw : std_logic_vector(1 downto 0);

  signal my_data        : std_logic_vector(kArcBusDataWidth-1 downto 0):= (others=>'0');
  signal my_reg_address : std_logic_vector(31 downto 0):= kAddrOffset & x"B0C001";

-- debug --------------------------------------------------------------
attribute mark_debug of state_bus      : signal is "true";
attribute mark_debug of busRW      : signal is "true";
attribute mark_debug of busAddress      : signal is "true";

begin
  -- =========================== body ===============================

  process(reset, clk)
    variable counter : integer:=0;
  begin
    if(reset='1') then
      busAck      <= '0';
      busDataOut  <= (others=>'Z');
      reg_rw      <= (others=>'0');
      state_bus   <= Idle;
    elsif(clk'event and clk = '1') then
      reg_rw    <= busRW;

      case state_bus is
        when Idle =>
          busAck    <= '0';
          busDataOut<= (others=>'Z');
          if(busRW /= "00" and reg_rw = "00") then
            counter   := 9;
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
          if(busAddress = my_reg_address) then
            my_data   <= busDataIn;
            state_bus <= Finalize;
          else
            state_bus <= Done;
          end if;

        when Read =>
          if(busAddress = my_reg_address) then
            busDataOut <= my_data;
            state_bus <= Finalize;
          else
            busDataOut <= (others=>'Z');
            state_bus <= Done;
          end if;

        when Finalize =>
          busAck    <= '1';
          state_bus <= Done;

        when Done =>
          busAck    <= '0';
          state_bus <= Idle;

        when others =>
          busAck      <= '0';
          busDataOut  <= (others=>'0');

      end case;
    end if;
  end process;

end RTL;

