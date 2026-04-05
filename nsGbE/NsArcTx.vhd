library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.pack_axi.all;
use work.pack_ipv4_types.all;
use work.pack_arp_types.all;

use work.defNsArc.all;

Library xpm;
use xpm.vcomponents.all;

entity ArcTx is
  generic(
    kWidthUdpData       : integer:= 8;
    kWidthHeadOut       : integer:= 136;
    kWidthDataOut       : integer:= 32;
    kEnDebug            : boolean := false
  );
  port (
    -- system signals
    reset               : in  STD_LOGIC;
    clk	                : in  STD_LOGIC;

    -- UDP TX signals
    udpTxStart          : out std_logic;	-- indicates req to tx UDP
    udpTxi              : out udp_tx_type;	-- UDP tx cxns
    udpTxResult         : in std_logic_vector (1 downto 0);-- tx status (changes during transmission)
    udpTxDataOutReady   : in std_logic;	-- indicates udp_tx is ready to take data

    -- Arc TX signals
    startArcTx          : in std_logic;
    arcHeadTxo          : in fifo_in_types(data_in(kWidthHeadOut-1 downto 0));
    arcDataTxo          : in fifo_in_types(data_in(kWidthDataOut-1 downto 0))
  );
end ArcTx;


architecture RTL of ArcTx is

  attribute mark_debug  : boolean;

  -- Internal signal declaration ---------------------------------------
  --signal reg_dst_ip_addr  : std_logic_vector(udpRxo.hdr.dst_ip_addr'range);
  signal reg_src_ip_addr  : std_logic_vector(udpTxi.hdr.dst_ip_addr'range);
--  signal reg_dst_port     : std_logic_vector(udpRxo.hdr.dst_port'range);
  signal reg_src_port     : std_logic_vector(udpTxi.hdr.dst_port'range);

  -- Data buffer --
  signal fifo_data_in    : std_logic_vector(kWidthDataOut-1 downto 0);
  signal fifo_data_out   : std_logic_vector(7 downto 0);
  signal fifo_read_en    : std_logic;
  signal fifo_empty      : std_logic;
  signal fifo_read_valid : std_logic;

  -- ARC TX --
  signal header_data  : std_logic_vector(95 downto 0);
  signal reg_arc_head : std_logic_vector(kWidthHeadOut-1 downto 0);
  signal reg_start_tx : std_logic;

  signal rx_address   : std_logic_vector(kPosArcAddr'length-1 downto 0);
  signal rx_reserve   : std_logic_vector(kPosArcRsv'length-1 downto 0);
  signal tx_length    : std_logic_vector(kPosArcLen'length-1 downto 0);
  signal rx_flag      : std_logic_vector(kPosArcFlag'length-1 downto 0);
  signal rx_mode      : std_logic_vector(kPosArcMode'length-1 downto 0);
  signal rx_command   : std_logic_vector(3 downto 0);
  signal rx_version   : std_logic_vector(3 downto 0);

  signal tx_data_inbyte : std_logic_vector(15 downto 0);
  signal fifo_data_count : std_logic_vector(8 downto 0);

  -- TX --
  type DefStateTx is (Idle, FirstHeader, StreamHeader, StreamPayload, Finalize);
  signal state_tx     : DefStateTx;
  signal tx_count     : unsigned(15 downto 0);
  signal udp_tx_start : std_logic;
  signal udp_txi      : udp_tx_type;

-- debug --------------------------------------------------------------
attribute mark_debug of udp_tx_start  : signal is kEnDebug;
attribute mark_debug of udp_txi       : signal is kEnDebug;
attribute mark_debug of state_tx      : signal is kEnDebug;
attribute mark_debug of tx_count      : signal is kEnDebug;
attribute mark_debug of startArcTx     : signal is kEnDebug;
attribute mark_debug of fifo_read_en    : signal is kEnDebug;
attribute mark_debug of fifo_data_out   : signal is kEnDebug;
attribute mark_debug of fifo_read_valid : signal is kEnDebug;
attribute mark_debug of udpTxDataOutReady : signal is kEnDebug;
attribute mark_debug of udpTxResult : signal is kEnDebug;

begin
  -- =========================== body ===============================

  udpTxStart  <= udp_tx_start;
  udpTxi      <= udp_txi;


  -------------------------------------------------------------------------------
  -- ARC Header/Data Buffer
  -------------------------------------------------------------------------------
  header_data(95 downto 88) <= X"5A";
  header_data(87 downto 84) <= rx_version;
  header_data(83 downto 80) <= rx_command;
  header_data(79 downto 72) <= rx_mode;
  header_data(71 downto 64) <= rx_flag or kArcFlagAck; -- set the ack flag
  header_data(63 downto 48) <= tx_length;
  header_data(47 downto 32) <= rx_reserve;
  header_data(31 downto 0)  <= rx_address;

  rx_address        <= reg_arc_head(31 downto 0);
  rx_reserve        <= reg_arc_head(47 downto 32);
  tx_length         <= tx_data_inbyte when(isReadCmd(rx_command)) else (others=>'0');
  rx_flag           <= reg_arc_head(71 downto 64);
  rx_mode           <= reg_arc_head(79 downto 72);
  rx_command        <= reg_arc_head(83 downto 80);
  rx_version        <= reg_arc_head(87 downto 84);
  reg_src_port      <= reg_arc_head(103 downto 88);
  reg_src_ip_addr   <= reg_arc_head(135 downto 104);

  u_header_buf : process(clk)
  begin
    if(clk'event and clk = '1') then
      if(reset = '1') then
        reg_arc_head <= (others=>'0');
      else
        reg_start_tx  <= startArcTx;
        if(arcHeadTxo.write_en = '1') then
          reg_arc_head <= arcHeadTxo.data_in;
        end if;
      end if;
    end if;
  end process;

  tx_data_inbyte  <= "00000" & fifo_data_count(8 downto 0) & "00";
  fifo_data_in    <= arcDataTxo.data_in(7 downto 0) &
                     arcDataTxo.data_in(15 downto 8) &
                     arcDataTxo.data_in(23 downto 16) &
                     arcDataTxo.data_in(31 downto 24);


  u_ArcRxDataFile : xpm_fifo_sync
    generic map (
      CASCADE_HEIGHT    => 0,        -- DECIMAL
      DOUT_RESET_VALUE  => "0",    -- String
      ECC_MODE          => "no_ecc",       -- String
      FIFO_MEMORY_TYPE  => "auto", -- String
      SIM_ASSERT_CHK    => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
      WAKEUP_TIME       => 0,           -- DECIMAL
      READ_MODE         => "fwft",         -- String
      FIFO_READ_LATENCY => 0,     -- DECIMAL

      WRITE_DATA_WIDTH  => 32,     -- DECIMAL
      FIFO_WRITE_DEPTH  => 256,    -- DECIMAL
      WR_DATA_COUNT_WIDTH => 9,    -- DECIMAL
      READ_DATA_WIDTH   => 8,      -- DECIMAL
      RD_DATA_COUNT_WIDTH => 11,   -- DECIMAL

      USE_ADV_FEATURES => "1004", -- String
      FULL_RESET_VALUE => 0,      -- DECIMAL
      PROG_EMPTY_THRESH => 10,    -- DECIMAL
      PROG_FULL_THRESH => 10     -- DECIMAL
    )
    port map (
      rst             => reset,
      wr_rst_busy     => open,
      rd_rst_busy     => open,
      sleep           => '0',

      injectdbiterr   => '0',
      injectsbiterr   => '0',
      sbiterr         => open,
      dbiterr         => open,

      wr_clk          => clk,
      din             => fifo_data_in,
      wr_en           => arcDataTxo.write_en,
      wr_ack          => open,
      full            => open,
      almost_full     => open,
      prog_full       => open,
      overflow        => open,
      wr_data_count   => fifo_data_count,

      dout            => fifo_data_out,
      rd_en           => fifo_read_en and udpTxDataOutReady,
      data_valid      => fifo_read_valid,
      empty           => fifo_empty,
      almost_empty    => open,
      prog_empty      => open,
      underflow       => open,
      rd_data_count   => open

    );

  -------------------------------------------------------------------------------
  -- ARC TX state machine
  -------------------------------------------------------------------------------
  --udpTxi.hdr.src_ip_addr <= reg_dst_ip_addr;
  udp_txi.hdr.dst_ip_addr <= reg_src_ip_addr;
  udp_txi.hdr.src_port    <= std_logic_vector(to_unsigned(5004, 16));
  udp_txi.hdr.dst_port    <= reg_src_port;
  udp_txi.hdr.checksum    <= (others=>'0');

  process(clk)
  begin
    if(clk'event and clk = '1') then
      if(reset = '1') then
        udp_tx_start                  <= '0';
        udp_txi.data.data_out_valid  <= '0';
        udp_txi.data.data_out_last   <= '0';
        udp_txi.data.data_out        <= (others=>'0');
        udp_txi.hdr.data_length      <= (others=>'0');

        fifo_read_en                 <= '0';

        state_tx  <=  Idle;
      else
        case state_tx is
          when Idle =>
            fifo_read_en <= '0';
            tx_count     <= (others => '0');

            if(reg_start_tx = '1') then
              udp_txi.hdr.data_length  <= std_logic_vector(unsigned(tx_length) + 12); -- header size
              tx_count                <= to_unsigned(11, 16); -- header size -1
              state_tx                <= FirstHeader;
            end if;

          when FirstHeader =>
            udp_tx_start                  <= '1';
            udp_txi.data.data_out_valid   <= '1';
            udp_txi.data.data_out         <= header_data(8*to_integer(tx_count)+7 downto 8*to_integer(tx_count));
            tx_count                      <= tx_count-1;
            state_tx                      <= StreamHeader;

          when StreamHeader =>
            if( udpTxResult = UDPTX_RESULT_ERR )then
              udp_tx_start                  <= '0';
              udp_txi.data.data_out_valid   <= '0';
              udp_txi.data.data_out_last    <= '0';
              state_tx                      <= Idle;
            elsif(udpTxDataOutReady = '1') then
              udp_tx_start                  <= '1';
              udp_txi.data.data_out_valid   <= '1';
              udp_txi.data.data_out         <= header_data(8*to_integer(tx_count)+7 downto 8*to_integer(tx_count));

              if(tx_count = 0 and fifo_empty = '1') then
                udp_txi.data.data_out_last  <= '1';
                state_tx                   <= Finalize;
              elsif(tx_count = 0 and fifo_empty = '0') then
                fifo_read_en                <= '1';
                tx_count                    <= unsigned(tx_length)-1;
                state_tx                    <= StreamPayload;
              else
                tx_count                    <= tx_count-1;
              end if;
            end if;

          when StreamPayload =>
            if( udpTxResult = UDPTX_RESULT_ERR )then
              udp_tx_start                  <= '0';
              udp_txi.data.data_out_valid  <= '0';
              udp_txi.data.data_out_last   <= '0';
              fifo_read_en                <= '0';
              state_tx                    <= Idle;
            elsif(udpTxDataOutReady = '1') then
              udp_tx_start                 <= '1';
              udp_txi.data.data_out_valid  <= '1';
              udp_txi.data.data_out        <= fifo_data_out;
              fifo_read_en                 <= '1';
              tx_count                     <= tx_count-1;

              if(tx_count = 0) then
                udp_txi.data.data_out_last  <= '1';
                state_tx                    <= Finalize;
              end if;
            end if;

          when Finalize =>
            if udpTxDataOutReady='1' then
              fifo_read_en                 <= '0';

              udp_txi.data.data_out_valid <= '0';
              udp_txi.data.data_out_last  <= '0';
              udp_txi.data.data_out       <= (others=>'0');
              udp_tx_start                 <= '0';
              state_tx                   <= Idle;
            end if;
        end case;
      end if;
    end if;
  end process;


end RTL;

