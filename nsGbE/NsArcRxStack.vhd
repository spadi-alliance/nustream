library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.pack_axi.all;
use work.pack_ipv4_types.all;
use work.pack_arp_types.all;

use work.defNsArc.all;

Library xpm;
use xpm.vcomponents.all;

entity ArcRxStack is
  generic(
    kWidthUdpData       : integer:= 8;
    kWidthHeadOut       : integer:= 136;
    kWidthDataOut       : integer:= 32;
    kDstPort            : integer:= 5004;
    kEnDebug            : boolean:= false
  );
  port (
    -- system signals
    reset               : in  STD_LOGIC;
    clk	                : in  STD_LOGIC;
    udpRxIsRejected     : out std_logic;

    -- UDP RX signals
    udpRxStart          : in std_logic;		-- indicates receipt of udp header
    udpRxo              : in udp_rx_type;

    -- ARC RX Stack signals
    arcHeadRxi          : in fifo_in_types(data_in(0 downto 0));
    arcDataRxi          : in fifo_in_types(data_in(0 downto 0));
    arcHeadRxo          : out fifo_out_types(data_out(kWidthHeadOut-1 downto 0));
    arcDataRxo          : out fifo_out_types(data_out(kWidthDataOut-1 downto 0))

  );
end ArcRxStack;


architecture RTL of ArcRxStack is

  attribute mark_debug  : boolean;

  -- Internal signal declaration ---------------------------------------
  signal reg_src_ip_addr  : std_logic_vector(udpRxo.hdr.src_ip_addr'range);
  signal reg_src_port     : std_logic_vector(udpRxo.hdr.src_port'range);

  -- RX --
  signal is_valid_header : std_logic;
  signal is_rejected     : std_logic;

  type DefStateRx is (Idle, CheckMagic, CheckVersion, CheckMode, CheckFlag, CheckLength, StackArcHeader, StackArcData, Finalize);
  signal state_rx : DefStateRx;
  signal we_hstack_fifo  : std_logic;
  signal we_dstack_fifo  : std_logic;
  signal stack_almost_full : std_logic;
  signal din_hstack_fifo : std_logic_vector(kWidthHeadOut-1 downto 0);
  signal reg_arc_header   : std_logic_vector(kWidthHeadOut-1-32-16 downto 0); -- -32-16 means src ip addr and src port
  signal reg_arc_data     : std_logic_vector(kWidthDataOut-1 downto 0);
  signal reg_cmd         : std_logic_vector(kArcCmdRead'range);


-- debug --------------------------------------------------------------
  attribute mark_debug of udpRxo            : signal is kEnDebug;
  attribute mark_debug of is_valid_header   : signal is kEnDebug;
  attribute mark_debug of is_rejected       : signal is kEnDebug;
  attribute mark_debug of state_rx          : signal is kEnDebug;
  attribute mark_debug of we_dstack_fifo    : signal is kEnDebug;
  attribute mark_debug of we_hstack_fifo    : signal is kEnDebug;
  attribute mark_debug of stack_almost_full : signal is kEnDebug;
  attribute mark_debug of reg_arc_header     : signal is kEnDebug;
  attribute mark_debug of din_hstack_fifo   : signal is kEnDebug;
  attribute mark_debug of reg_arc_data       : signal is kEnDebug;

begin
  -- =========================== body ===============================

udpRxIsRejected   <= is_rejected;

-------------------------------------------------------------------------------
-- UDP ARC RX state machine
-------------------------------------------------------------------------------
process(clk)
  variable  data_index : integer:= 1;
begin
	if(clk'event and clk='1') then
		if(reset = '1') then
      is_valid_header <= '0';
      is_rejected     <= '0';
			state_rx        <=  Idle;
		else
			case state_rx is
				when Idle =>
          we_dstack_fifo  <= '0';
          we_hstack_fifo  <= '0';

					if( udpRxo.hdr.is_valid ='1') then
            reg_src_ip_addr   <= udpRxo.hdr.src_ip_addr;
            reg_src_port      <= udpRxo.hdr.src_port;
            --reg_dst_ip_addr   <= udpRxo.hdr.dst_ip_addr;
            --reg_dst_port      <= udpRxo.hdr.dst_port;

            if(udpRxo.hdr.dst_port = std_logic_vector(to_unsigned(kDstPort, 16))) then
              if(stack_almost_full = '0') then
                data_index      := 0;
                is_valid_header <= '1';
              else
                is_valid_header <= '0';
                is_rejected     <= '1';
              end if;

              state_rx        <=  CheckMagic;
            end if;
					end if;

        when CheckMagic =>
          if(udpRxo.data.data_in_valid = '1') then
            if( compareMagic(data_index, udpRxo.data.data_in) /= true ) then
              is_valid_header <= '0';
            end if;

            if(data_index = 0) then
              state_rx  <= CheckVersion;
            end if;

            data_index := data_index -1;
          end if;

        when CheckVersion =>
          if(udpRxo.data.data_in_valid = '1') then
            if((kArcVersion /= udpRxo.data.data_in(7 downto 4)) or compareCmd(udpRxo.data.data_in(3 downto 0)) /= true) then
              is_valid_header <= '0';
            end if;

            reg_cmd   <= udpRxo.data.data_in(3 downto 0);
            reg_arc_header(kPosArcVerCmd'range) <= udpRxo.data.data_in;
            state_rx  <= CheckMode;
          end if;

        when CheckMode =>
          if(udpRxo.data.data_in_valid = '1') then
            reg_arc_header(kPosArcMode'range) <= udpRxo.data.data_in;
            state_rx  <= CheckFlag;
          end if;

        when CheckFlag =>
          if(udpRxo.data.data_in_valid = '1') then
            reg_arc_header(kPosArcFlag'range) <= udpRxo.data.data_in;
            data_index   := 1;
            state_rx     <= CheckLength;
          end if;

        when CheckLength =>
          if(udpRxo.data.data_in_valid = '1') then
            if(data_index = 1) then
              reg_arc_header(kPosArcLen'high downto kPosArcLen'high-7) <= udpRxo.data.data_in;
              data_index  := 0;
            else
              reg_arc_header(kPosArcLen'low+7 downto kPosArcLen'low)   <= udpRxo.data.data_in;
              data_index  := 5;
              state_rx    <= StackArcHeader;
            end if;
          end if;

        when StackArcHeader =>
          -- Check length here --
          if(reg_arc_header(kPosArcLen'range) > kMaxPayloadLen) then
            is_valid_header <= '0';
          elsif(reg_arc_header(kPosArcLen'low+1) = '1' and (reg_arc_header(kPosArcMode'range) and kArcModeList) = kArcModeList and isWriteCmd(reg_cmd) = true) then
            is_valid_header <= '0';
          elsif(reg_arc_header(kPosArcLen'range) = X"0000" and isWriteCmd(reg_cmd) = true) then
            is_valid_header <= '0';
          --elsif(reg_arc_header(kPosArcLen'range) /= X"0000" and reg_cmd = kArcCmdRead) then
--            is_valid_header <= '0';
          end if;

          -- Stack remaining header --
          if(udpRxo.data.data_in_valid = '1') then
            reg_arc_header(kWidthUdpData*(data_index+1)-1 downto kWidthUdpData*data_index) <= udpRxo.data.data_in;

            if(isWriteCmd(reg_cmd) = true and udpRxo.data.data_in_last = '1')  then
              -- Abort if write command but no data --
              is_valid_header <= '0';
              state_rx        <= Finalize;
            elsif(data_index = 0) then
              -- Normal header stacking done --
              if(isWriteCmd(reg_cmd) = true) then
                data_index  := 3;
                state_rx    <= StackArcData;
              elsif(isReadCmd(reg_cmd) = true) then
                if((reg_arc_header(kPosArcMode'range) and kArcModeList) = kArcModeList) then
                  data_index  := 3;
                  state_rx    <= StackArcData;
                else
                  state_rx    <= Finalize;
                end if;
              else
                is_valid_header <= '0';
                state_rx        <= Finalize;
              end if;
            else
              -- Repeat for next header word --
              data_index  := data_index -1;
            end if;
          end if;

        when StackArcData =>
          if(udpRxo.data.data_in_valid = '1') then
            reg_arc_data(kWidthUdpData*(data_index+1)-1 downto kWidthUdpData*data_index) <= udpRxo.data.data_in;

            if(udpRxo.data.data_in_last = '1') then
              state_rx        <= Finalize;
            end if;

            if(data_index = 0) then
              we_dstack_fifo  <= is_valid_header;
              data_index      := 3;
            else
              if(udpRxo.data.data_in_last = '1') then
                we_dstack_fifo  <= is_valid_header;
              else
                we_dstack_fifo  <= '0';
              end if;
              data_index      := data_index -1;
            end if;

          end if;

				when Finalize =>
          we_dstack_fifo  <= '0';
          we_hstack_fifo  <= is_valid_header;
          is_rejected     <= '0';
          state_rx        <= Idle;

        when others =>
          state_rx        <= Idle;

			end case;
		end if;
	end if;
end process;

-------------------------------------------------------------------------------
-- ARC RX Stack
-------------------------------------------------------------------------------

din_hstack_fifo   <=  reg_src_ip_addr & reg_src_port & reg_arc_header;

  u_ArcHeaderFifo : xpm_fifo_sync
    generic map (
      CASCADE_HEIGHT      => 0,        -- DECIMAL
      DOUT_RESET_VALUE    => "0",    -- String
      ECC_MODE            => "no_ecc",       -- String
      FIFO_MEMORY_TYPE    => "auto", -- String
      SIM_ASSERT_CHK      => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
      WAKEUP_TIME         => 0,           -- DECIMAL
      READ_MODE           => "fwft",         -- String
      FIFO_READ_LATENCY   => 0,     -- DECIMAL

      WRITE_DATA_WIDTH    => 136,     -- DECIMAL
      FIFO_WRITE_DEPTH    => 16,    -- DECIMAL
      WR_DATA_COUNT_WIDTH => 5,    -- DECIMAL
      READ_DATA_WIDTH     => 136,      -- DECIMAL
      RD_DATA_COUNT_WIDTH => 5,   -- DECIMAL

      USE_ADV_FEATURES    => "1008", -- String
      FULL_RESET_VALUE    => 0,      -- DECIMAL
      PROG_EMPTY_THRESH   => 5,    -- DECIMAL
      PROG_FULL_THRESH    => 5     -- DECIMAL
    )
    port map (
      rst               => reset,
      wr_rst_busy       => open,
      rd_rst_busy       => open,
      sleep             => '0',
                                    -- block is in power saving mode.
      injectdbiterr     => '0',
      injectsbiterr     => '0',
      sbiterr           => open,
      dbiterr           => open,

      wr_clk            => clk,                                    -- write clock input
      din               => din_hstack_fifo,
      wr_en             => we_hstack_fifo,
      wr_ack            => open,
      full              => open,
      almost_full       => stack_almost_full,
      prog_full         => open,
      overflow          => open,
      wr_data_count     => open,

      dout              => arcHeadRxo.data_out,
      rd_en             => arcHeadRxi.read_en,
      data_valid        => arcHeadRxo.read_valid,
      empty             => arcHeadRxo.empty,
      almost_empty      => open,
      prog_empty        => open,
      underflow         => open,
      rd_data_count     => open
  );

  u_ArcRxDataFile : xpm_fifo_sync
    generic map (
      CASCADE_HEIGHT        => 0,        -- DECIMAL
      DOUT_RESET_VALUE      => "0",    -- String
      ECC_MODE              => "no_ecc",       -- String
      FIFO_MEMORY_TYPE      => "auto", -- String
      SIM_ASSERT_CHK        => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
      WAKEUP_TIME           => 0,           -- DECIMAL
      READ_MODE             => "fwft",         -- String
      FIFO_READ_LATENCY     => 0,     -- DECIMAL

      WRITE_DATA_WIDTH      => 32,     -- DECIMAL
      FIFO_WRITE_DEPTH      => 512,    -- DECIMAL
      WR_DATA_COUNT_WIDTH   => 10,    -- DECIMAL
      READ_DATA_WIDTH       => 32,      -- DECIMAL
      RD_DATA_COUNT_WIDTH   => 10,   -- DECIMAL

      USE_ADV_FEATURES      => "1000", -- String
      FULL_RESET_VALUE      => 0,      -- DECIMAL
      PROG_EMPTY_THRESH     => 10,    -- DECIMAL
      PROG_FULL_THRESH      => 10     -- DECIMAL
    )
    port map (
      rst             => reset,
      wr_rst_busy     => open,
      rd_rst_busy     => open,
      sleep           => '0',      -- block is in power saving mode.

      injectdbiterr   => '0',
      injectsbiterr   => '0',
      sbiterr         => open,
      dbiterr         => open,

      wr_clk          => clk,       -- write clock input
      din             => reg_arc_data,
      wr_en           => we_dstack_fifo,
      wr_ack          => open,
      full            => open,
      almost_full     => open,
      prog_full       => open,
      overflow        => open,
      wr_data_count   => open,

      dout            => arcDataRxo.data_out,
      rd_en           => arcDataRxi.read_en,
      data_valid      => arcDataRxo.read_valid,
      empty           => open,
      almost_empty    => open,
      prog_empty      => open,
      underflow       => open,
      rd_data_count   => open
    );

end RTL;
