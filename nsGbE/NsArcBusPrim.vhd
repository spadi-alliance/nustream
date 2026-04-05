library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.pack_axi.all;
use work.pack_ipv4_types.all;
use work.pack_arp_types.all;

use work.defNsArc.all;
use work.defNsArcBus.all;

entity ArcBusPrim is
  generic(
    kWidthUdpData       : integer:= 8;
    kWidthHeadOut       : integer:= 136;
    kWidthDataOut       : integer:= 32;
    kEnDebug            : boolean:= false
  );
  port (
    -- system signals
    reset               : in  STD_LOGIC;
    clk	                : in  STD_LOGIC;

    -- External bus signals
    busDataOut          : out std_logic_vector(kWidthDataOut-1 downto 0);
    busDataIn           : in std_logic_vector(kWidthDataOut-1 downto 0);
    busAddress          : out std_logic_vector(kArcBusAddrWidth-1 downto 0);
    busRW               : out std_logic_vector(1 downto 0);
    busAck              : in std_logic;
    busInternalMode     : out std_logic;

    -- ARC RX Stack signals
    arcHeadRxi          : out fifo_in_types(data_in(0 downto 0));
    arcDataRxi          : out fifo_in_types(data_in(0 downto 0));
    arcHeadRxo          : in fifo_out_types(data_out(kWidthHeadOut-1 downto 0));
    arcDataRxo          : in fifo_out_types(data_out(kWidthDataOut-1 downto 0));

    -- ARC TX signals --
    startArcTx          : out std_logic;
    arcHeadTxo          : out fifo_in_types(data_in(kWidthHeadOut-1 downto 0));
    arcDataTxo          : out fifo_in_types(data_in(kWidthDataOut-1 downto 0))

  );
end ArcBusPrim;


architecture RTL of ArcBusPrim is

  attribute mark_debug  : boolean;

  -- Internal signal declaration ---------------------------------------
  --signal reg_dst_ip_addr  : std_logic_vector(udpRxo.hdr.dst_ip_addr'range);
  signal src_ip_addr  : std_logic_vector(31 downto 0);
  signal src_port     : std_logic_vector(15 downto 0);
  signal rx_address   : std_logic_vector(kPosArcAddr'length-1 downto 0);
  signal rx_reserve   : std_logic_vector(kPosArcRsv'length-1 downto 0);
  signal rx_length    : std_logic_vector(kPosArcLen'length-1 downto 0);
  signal rx_flag      : std_logic_vector(kPosArcFlag'length-1 downto 0);
  signal rx_mode      : std_logic_vector(kPosArcMode'length-1 downto 0);
  signal rx_command   : std_logic_vector(3 downto 0);
  signal rx_version   : std_logic_vector(3 downto 0);
  signal reg_write_data : std_logic_vector(kWidthDataOut-1 downto 0);
  signal reg_address  : std_logic_vector(busAddress'range);
  signal ready_ext_bus : std_logic;

  type DefStateRx is (Idle, ParseArcHeader, ReadBusData, ReadDataStack, ReadDataStackListWr, WaitExtBusAck, Finalize, WaitStartTx, Done);
  signal state_rx : DefStateRx;

  -- Bus signals --
  constant kAckWaitMax  : integer := 1000;
  signal error_flags    : std_logic_vector(rx_flag'range);
  signal reg_data       : std_logic_vector(kWidthDataOut-1 downto 0);
  signal reg_ack        : std_logic;

  -- debug --------------------------------------------------------------
  attribute mark_debug of src_ip_addr  : signal is kEnDebug;
  attribute mark_debug of src_port     : signal is kEnDebug;
  attribute mark_debug of rx_address   : signal is kEnDebug;
  attribute mark_debug of rx_length    : signal is kEnDebug;
  attribute mark_debug of rx_flag      : signal is kEnDebug;
  attribute mark_debug of rx_mode      : signal is kEnDebug;
  attribute mark_debug of rx_command   : signal is kEnDebug;
  attribute mark_debug of rx_version   : signal is kEnDebug;
  attribute mark_debug of state_rx      : signal is kEnDebug;
  attribute mark_debug of reg_write_data      : signal is kEnDebug;

  attribute mark_debug of busAck       : signal is kEnDebug;

begin
  -- =========================== body ===============================

  arcHeadTxo.data_in(31 downto 0)   <= arcHeadRxo.data_out(31 downto 0);
  arcHeadTxo.data_in(47 downto 32)  <= arcHeadRxo.data_out(47 downto 32);
  arcHeadTxo.data_in(63 downto 48)  <= arcHeadRxo.data_out(63 downto 48);
  arcHeadTxo.data_in(71 downto 64)  <= arcHeadRxo.data_out(71 downto 64) or error_flags;
  arcHeadTxo.data_in(79 downto 72)  <= arcHeadRxo.data_out(79 downto 72);
  arcHeadTxo.data_in(83 downto 80)  <= arcHeadRxo.data_out(83 downto 80);
  arcHeadTxo.data_in(87 downto 84)  <= arcHeadRxo.data_out(87 downto 84);
  arcHeadTxo.data_in(103 downto 88)  <= arcHeadRxo.data_out(103 downto 88);
  arcHeadTxo.data_in(135 downto 104) <= arcHeadRxo.data_out(135 downto 104);

  -------------------------------------------------------------------------------
  -- Read RX packet from ARC RX stack
  -------------------------------------------------------------------------------
  rx_address   <= arcHeadRxo.data_out(31 downto 0);
  rx_reserve   <= arcHeadRxo.data_out(47 downto 32);
  rx_length    <= arcHeadRxo.data_out(63 downto 48);
  rx_flag      <= arcHeadRxo.data_out(71 downto 64);
  rx_mode      <= arcHeadRxo.data_out(79 downto 72);
  rx_command   <= arcHeadRxo.data_out(83 downto 80);
  rx_version   <= arcHeadRxo.data_out(87 downto 84);
  src_port     <= arcHeadRxo.data_out(103 downto 88);
  src_ip_addr  <= arcHeadRxo.data_out(135 downto 104);

  u_read_sm : process(clk)
    variable num_word : std_logic_vector(15 downto 0);
    variable ack_wait_count : integer:=0;
    variable tx_wait_count  : integer range 0 to 15 :=0;
    variable req_second_data : boolean:= false;
  begin
    if(clk'event and clk='1') then
      if(reset='1') then
        arcHeadRxi.read_en   <= '0';
        arcDataRxi.read_en   <= '0';
        arcHeadTxo.write_en  <= '0';
        ready_ext_bus       <= '0';
        startArcTx          <= '0';
        error_flags         <= (others=>'0');
        ack_wait_count      := 0;
        tx_wait_count       := 5;
        req_second_data     := false;
        state_rx            <= Idle;
      else
        case state_rx is
          when Idle =>
            arcHeadRxi.read_en <= '0';
            arcDataRxi.read_en <= '0';
            ready_ext_bus     <= '0';

            if(arcHeadRxo.empty = '0' and arcHeadRxo.read_valid = '1') then
              state_rx <= ParseArcHeader;
            end if;

          when ParseArcHeader =>
            num_word    := "00" & rx_length(rx_length'high downto 2);

            if((rx_mode and kArcModeList) = kArcModeList) then
              -- List mode --
              if(isReadCmd(rx_command) = true) then
                arcDataRxi.read_en <= '1';
                state_rx          <= ReadDataStack;
              elsif(isWriteCmd(rx_command) = true) then
                arcDataRxi.read_en <= '1';
                state_rx          <= ReadDataStackListWr;
              else
                -- This condition should not happen --
                state_rx  <= Finalize;
              end if;
            else
              -- Sequential mode --
              reg_address <= rx_address;

              if(isReadCmd(rx_command) = true) then
                state_rx          <= ReadBusData;
              elsif(isWriteCmd(rx_command) = true) then
                arcDataRxi.read_en <= '1';
                state_rx          <= ReadDataStack;
              else
                -- This condition should not happen --
                state_rx  <= Finalize;
              end if;
            end if;

          when ReadBusData =>
            -- bus read operation for sequential mode --
            -- bus write operation for list mode --
            if(unsigned(num_word) = 0) then
              -- This condition should not happen --
              arcDataRxi.read_en <= '0';
              state_rx          <= Finalize;
            else
              num_word          := std_logic_vector(unsigned(num_word) - 1);
              ack_wait_count    := kAckWaitMax;
              ready_ext_bus     <= '1';
              state_rx          <= WaitExtBusAck;
            end if;

          when ReadDataStack =>
            if(unsigned(num_word) = 0) then
              --This condition should not happen --
              arcDataRxi.read_en <= '0';
              state_rx          <= Finalize;
            else
              if(arcDataRxo.empty = '0' and arcDataRxo.read_valid = '1') then
                arcDataRxi.read_en <= '0';
                if((rx_mode and kArcModeList) = kArcModeList) then
                  -- if list mode, bus address is specified in each data word --
                  -- bus read operation for list mode --
                  reg_address     <= arcDataRxo.data_out;
                else
                  -- sequential mode, address is specified in header --
                  -- bus write operation for sequential mode --
                  reg_write_data  <= arcDataRxo.data_out;
                end if;

                num_word          := std_logic_vector(unsigned(num_word) - 1);
                ack_wait_count    := kAckWaitMax;
                ready_ext_bus     <= '1';
                state_rx          <= WaitExtBusAck;
              else
                -- Abort read if no data available --
                arcDataRxi.read_en <= '0';
                state_rx          <= Finalize;
              end if;
            end if;

          when ReadDataStackListWr =>
            if(unsigned(num_word) = 0) then
              --This condition should not happen --
              arcDataRxi.read_en <= '0';
              state_rx          <= Finalize;
            else
              if(arcDataRxo.empty = '0' and arcDataRxo.read_valid = '1') then
                if(req_second_data = false) then
                  -- First word is address --
                  reg_address       <= arcDataRxo.data_out;
                  req_second_data   := true;
                  state_rx          <= ReadDataStackListWr;
                else
                  -- Second word is data --
                  reg_write_data    <= arcDataRxo.data_out;
                  req_second_data   := false;
                  arcDataRxi.read_en <= '0';

                  num_word          := std_logic_vector(unsigned(num_word) - 2);
                  ack_wait_count    := kAckWaitMax;
                  ready_ext_bus     <= '1';
                  state_rx          <= WaitExtBusAck;
                end if;
              else
                -- Abort read if no data available --
                arcDataRxi.read_en <= '0';
                state_rx          <= Finalize;
              end if;
            end if;

          when WaitExtBusAck =>
            arcDataRxi.read_en <= '0';

            if(busAck = '1' or ack_wait_count = 0) then
              -- Timeout for waiting bus ack --
              if(ack_wait_count = 0) then
                error_flags <= error_flags or kArcFlagBusErr;
              end if;

              ready_ext_bus <= '0';
              if((rx_mode and kArcModeAutoInc) = kArcModeAutoInc) then
                reg_address <= std_logic_vector(unsigned(reg_address) + 1);
              end if;

              if(unsigned(num_word) = 0) then
                arcDataRxi.read_en <= '1';
                state_rx          <= Finalize;
              else
                if((rx_mode and kArcModeList) = kArcModeList) then
                  -- List mode --
                  if(isWriteCmd(rx_command) = true) then
                    arcDataRxi.read_en <= '1';
                    state_rx          <= ReadDataStackListWr;
                  elsif(isReadCmd(rx_command) = true) then
                    arcDataRxi.read_en <= '1';
                    state_rx          <= ReadDataStack;
                  end if;
                else
                  -- Sequential mode --
                  if(isWriteCmd(rx_command) = true) then
                    arcDataRxi.read_en <= '1';
                    state_rx          <= ReadDataStack;
                  elsif(isReadCmd(rx_command) = true) then
                    state_rx          <= ReadBusData;
                  end if;
                end if;
              end if;

            else
              ack_wait_count := ack_wait_count -1;
            end if;

          when Finalize =>
            arcHeadTxo.write_en  <= '1';
            arcHeadRxi.read_en   <= '1';
            arcDataRxi.read_en   <= '0';

            tx_wait_count       := 5;
            state_rx            <= WaitStartTx;

          when WaitStartTx =>
            arcHeadTxo.write_en  <= '0';
            arcHeadRxi.read_en   <= '0';

            if(tx_wait_count = 0) then
              startArcTx           <= '1';
              state_rx            <= Done;
            else
              tx_wait_count       := tx_wait_count - 1;
            end if;

          when Done =>
            error_flags         <= (others=>'0');
            startArcTx           <= '0';
            arcHeadTxo.write_en  <= '0';
            arcHeadRxi.read_en   <= '0';
            arcDataRxi.read_en   <= '0';

            if(tx_wait_count = 0) then

              state_rx            <= Idle;
            end if;

          when others =>
            arcHeadRxi.read_en <= '0';
            arcDataRxi.read_en <= '0';
            state_rx        <= Idle;
        end case;
      end if;
    end if;
  end process;

  -------------------------------------------------------------------------------
  -- TX process
  -------------------------------------------------------------------------------
  -- Make acknowledge packet for slow control operation --

  u_tx_process : process(clk)
    variable req_second_data : boolean:= false;
  begin
    if(clk'event and clk='1') then
      if(reset='1') then
        req_second_data     := false;
        arcDataTxo.write_en  <= '0';
        reg_ack             <= '0';
      else
        reg_ack   <= busAck;

        if((rx_mode and kArcModeList) = kArcModeList) then
          -- List mode --
          if(busAck = '1' and reg_ack = '0' and isReadCmd(rx_command) = true) then
            -- Data is latched on the leading edge of busAck --
            req_second_data     := true;
            reg_data            <= busDataIn;
            arcDataTxo.data_in   <= reg_address;
            arcDataTxo.write_en  <= '1';
          elsif(req_second_data = true) then
            req_second_data     := false;
            arcDataTxo.data_in   <= reg_data;
            arcDataTxo.write_en  <= '1';
          else
            arcDataTxo.write_en  <= '0';
          end if;
        else
          -- Sequential mode --
          if(busAck = '1' and reg_ack = '0' and isReadCmd(rx_command) = true) then
            -- Data is latched on the leading edge of busAck --
            arcDataTxo.data_in <= busDataIn;
            arcDataTxo.write_en <= '1';
          else
            arcDataTxo.write_en <= '0';
          end if;
        end if;

      end if;
    end if;
  end process;

  -------------------------------------------------------------------------------
  -- External bus sequential process
  -------------------------------------------------------------------------------
  u_ext_bus_sm : process(clk)
    begin
    if(clk'event and clk='1') then
      if(reset='1') then
        busAddress      <= (others=>'0');
        busRW           <= (others=>'0');
        busInternalMode <= '0';
      else
        if(ready_ext_bus = '1') then
          busAddress <= reg_address;

          if(isInternalCmd(rx_command) = true) then
            busInternalMode <= '1';
          else
            busInternalMode <= '0';
          end if;

          if(isWriteCmd(rx_command) = true) then
            busDataOut <= reg_write_data;
            busRW      <= kArcBusWrite;  -- write --
          elsif(isReadCmd(rx_command) = true) then
            busRW      <= kArcBusRead;  -- read --
          else
            busRW      <= "00";  -- idle --
          end if;
        else
          busRW           <= "00";    -- idle --
          busInternalMode <= '0';
        end if;
      end if;
    end if;
  end process;

end RTL;

