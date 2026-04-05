library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use ieee.math_real.all;

use work.pack_axi.all;
use work.pack_ipv4_types.all;
use work.pack_arp_types.all;

use work.defNsArcBus.all;
use work.defNuStream.all;

entity StrTx is
  generic (
    kFifoDepth          : integer := 4096;
    kEnDebug            : boolean := false

    );
  port (
    -- system signals
    reset               : in  STD_LOGIC;
    clk	                : in  STD_LOGIC;

    -- Control registers --
    useDefault          : in std_logic;
    ctrlRegData         : in arcDataArrayAbst(kNumCtrlReg - 1 downto 0);

    -- Data source from DAQ FIFO
    dataDaqFifo : in std_logic_vector (7 downto 0);
    dataValidDaqFifo : in std_logic;
    programmableFullDataFifo : out std_logic;

    -- UDP TX signals
    udpTxStart          : out std_logic;	-- indicates req to tx UDP
    udpTxi              : out udp_tx_type;	-- UDP tx cxns
    udpTxResult         : in std_logic_vector (1 downto 0);-- tx status (changes during transmission)
    udpTxDataOutReady   : in std_logic	-- indicates udp_tx is ready to take data

  );
end StrTx;


architecture RTL of StrTx is

  attribute mark_debug  : boolean;

  -- Internal signal declaration ---------------------------------------

  -- TX --
  type DefStateTx is (Idle, FirstPayload, StreamPayload, Finalize);
  signal state_tx     : DefStateTx;
--  signal tx_count     : unsigned(15 downto 0);
  signal tx_count     : unsigned(15 downto 0);
  signal udp_tx_start : std_logic;
  signal udp_txi      : udp_tx_type;


  signal in_idle      : std_logic := '0';
  signal idle_ready   : std_logic := '0';
  signal frame_max_r  : std_logic := '0';
  signal frame_max_r_delay : std_logic := '0';
  signal frame_max_found_r : std_logic := '0';

  signal timeout_count    : unsigned(kDefaultTimeoutLen'range) := (others => '0');
  signal timeout_r        : std_logic := '0';
  signal timeout_r_delay  : std_logic := '0';
  --signal timeout_found_r : std_logic := '0';
  signal idle_waiting_count : unsigned(kDefaultIdleWaitingTime'range) := (others => '0');

  signal wr_en_datafifo_r : std_logic := '0';
  signal empty_datafifo_r : std_logic := '0';
  signal data_wr_datafifo_r : std_logic_vector(7 downto 0) := (others => '0');
  signal rd_en_datafifo_r : std_logic := '0';
  signal rd_en_datafifo_valid_r : std_logic := '0';
  signal data_rd_datafifo_r : std_logic_vector(7 downto 0) := (others => '0');
  signal prog_full_datafifo_r : std_logic := '0';
  signal data_count_datafifo_r : std_logic_vector(15 downto 0) := (others => '0');
  signal data_count_us : unsigned(15 downto 0) := (others => '0');

  constant kWidthDataCount  : integer:= integer(ceil(log2(real(kFifoDepth)))) +1;

  -- TODO: This IP will be replaced by XPM FIFO until release. --
--  COMPONENT datafifo_8b
--  PORT (
--    clk : IN STD_LOGIC;
--    srst : IN STD_LOGIC;
--    din : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
--    wr_en : IN STD_LOGIC;
--    rd_en : IN STD_LOGIC;
--    dout : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
--    data_count : OUT STD_LOGIC_VECTOR(12 DOWNTO 0);
--    full : OUT STD_LOGIC;
--    almost_full : OUT STD_LOGIC;
--    empty : OUT STD_LOGIC
--  );
--  END COMPONENT;

  signal udpTxData_being_sent_r : std_logic := '0';

  signal state_tx_int           : std_logic_vector(1 downto 0) := (others => '0');
  signal data_tx_r              : std_logic_vector(7 downto 0) := (others => '0');
  signal header_r               : std_logic_vector(8*kHeaderLength - 1 downto 0) := (others => '0');
  signal header_index_r         : integer range 0 to kHeaderLength + 5:= 0;
  signal frame_type_r           : std_logic := '0';

  -- Control registers --
  signal max_length         : unsigned(kDefaultMaxLen'range) := kDefaultMaxLen;
  signal timeout_length     : unsigned(kDefaultTimeoutLen'range) := kDefaultTimeoutLen;
  signal timeout_limit      : unsigned(kDefaultTimeoutLimit'range) := kDefaultTimeoutLimit;
  signal length_margin      : unsigned(kDefaultLengthMargin'range) := kDefaultLengthMargin;
  signal idle_waiting_time  : unsigned(kDefaultIdleWaitingTime'range) := kDefaultIdleWaitingTime;

  -- degbug --------------------------------------------------------------
  attribute mark_debug of udpTxDataOutReady       : signal is kEnDebug;
  attribute mark_debug of udp_tx_start            : signal is kEnDebug;
  attribute mark_debug of wr_en_datafifo_r        : signal is kEnDebug;
  attribute mark_debug of rd_en_datafifo_r        : signal is kEnDebug;
  attribute mark_debug of rd_en_datafifo_valid_r  : signal is kEnDebug;
  attribute mark_debug of prog_full_datafifo_r  : signal is kEnDebug;
  attribute mark_debug of udpTxData_being_sent_r  : signal is kEnDebug;
  attribute mark_debug of frame_max_r             : signal is kEnDebug;
  attribute mark_debug of timeout_r               : signal is kEnDebug;
  attribute mark_debug of state_tx_int            : signal is kEnDebug;
  attribute mark_debug of data_tx_r               : signal is kEnDebug;
  attribute mark_debug of data_count_datafifo_r   : signal is kEnDebug;
  attribute mark_debug of state_tx                : signal is kEnDebug;
  attribute mark_debug of udpTxResult             : signal is kEnDebug;

begin
  -- =========================== body ===============================

  udpTxStart  <= udp_tx_start;
  udpTxi      <= udp_txi;

  -------------------------------------------------------------------------------
  -- Control register
  -------------------------------------------------------------------------------
  max_length              <= kDefaultMaxLen       when(useDefault = '1') else unsigned(ctrlRegData(kMaxLengthId)(max_length'range));
  timeout_length          <= kDefaultTimeoutLen   when(useDefault = '1') else unsigned(ctrlRegData(kTimeoutLengthId)(timeout_length'range));
  timeout_limit           <= kDefaultTimeoutLimit when(useDefault = '1') else unsigned(ctrlRegData(kTimeoutLimitId)(timeout_limit'range));
  length_margin           <= kDefaultLengthMargin when(useDefault = '1') else unsigned(ctrlRegData(kLengthMarginId)(length_margin'range));
  idle_waiting_time       <= kDefaultIdleWaitingTime when(useDefault = '1') else unsigned(ctrlRegData(kIdleWaitingTimeId)(idle_waiting_time'range));
  udp_txi.hdr.dst_ip_addr <= kDefaultDstIpAddr       when(useDefault = '1') else ctrlRegData(kDstIpAddrId);
  udp_txi.hdr.dst_port    <= kDefaultDstPort         when(useDefault = '1') else ctrlRegData(kDstPortId)(udp_txi.hdr.dst_port'range);

  -------------------------------------------------------------------------------
  -- DAQ FIFO reading logic
  -------------------------------------------------------------------------------

  process(clk)
  begin
    if rising_edge(clk) then
  	  timeout_r <= '0';
  	  timeout_r_delay <= timeout_r;
  	  if (dataValidDaqFifo = '1') then
  	    timeout_count <= (others => '0');
  	  elsif (dataValidDaqFifo = '0' and empty_datafifo_r = '0' and data_count_us >= timeout_length + length_margin and timeout_count < timeout_limit) then
  	    timeout_count <= timeout_count + 1;
  	  elsif (dataValidDaqFifo = '0' and empty_datafifo_r = '0' and data_count_us >= timeout_length + length_margin and timeout_count >= timeout_limit) then
  	    timeout_count <= (others => '0');
  	    timeout_r <= '1';
  	  end if;
  	end if;
  end process;

  --timeout_found_r <= timeout_r and (not timeout_r_delay);

  frame_max_r <= '1' when data_count_us >= max_length + length_margin else '0';

  process(clk)
  begin
  	if rising_edge(clk) then
  	  frame_max_r_delay <= frame_max_r;
  	end if;
  end process;

  frame_max_found_r <= frame_max_r and (not frame_max_r_delay);

  -------------------------------------------------------------------------------
  -- FIFO instances
  -------------------------------------------------------------------------------

  wr_en_datafifo_r <= dataValidDaqFifo;
  data_wr_datafifo_r <= dataDaqFifo;

  programmableFullDataFifo <= prog_full_datafifo_r; -- Any definition by users
  data_count_us <= unsigned(data_count_datafifo_r);

--  -- TODO: This IP will be replaced by XPM FIFO until release. --
--  datafifo_8b_inst : datafifo_8b
--  port map(
--    clk => clk,
--    srst => reset,
--    din => data_wr_datafifo_r,
--    wr_en => wr_en_datafifo_r,
--    rd_en => rd_en_datafifo_r,
--    dout => data_rd_datafifo_r,
--    data_count => data_count_datafifo_r(12 downto 0),
--    almost_full => prog_full_datafifo_r,
--    full => open,
--    empty => empty_datafifo_r
--  );

  u_datafifo : xpm_fifo_sync
    generic map (
      CASCADE_HEIGHT    => 0,        -- DECIMAL
      DOUT_RESET_VALUE  => "0",    -- String
      ECC_MODE          => "no_ecc",       -- String
      FIFO_MEMORY_TYPE  => "auto", -- String
      SIM_ASSERT_CHK    => 0,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
      WAKEUP_TIME       => 0,           -- DECIMAL
      READ_MODE         => "fwft",         -- String
      FIFO_READ_LATENCY => 0,     -- DECIMAL

      WRITE_DATA_WIDTH  => 8,     -- DECIMAL
      FIFO_WRITE_DEPTH  => kFifoDepth,    -- DECIMAL
      WR_DATA_COUNT_WIDTH => kWidthDataCount,    -- DECIMAL
      READ_DATA_WIDTH   => 8,      -- DECIMAL
      RD_DATA_COUNT_WIDTH => kWidthDataCount,   -- DECIMAL

      USE_ADV_FEATURES => "0006", -- String
      FULL_RESET_VALUE => 0,      -- DECIMAL
      PROG_EMPTY_THRESH => 10,    -- DECIMAL
      PROG_FULL_THRESH => kFifoDepth - 100     -- DECIMAL
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
      din             => data_wr_datafifo_r,
      wr_en           => wr_en_datafifo_r,
      wr_ack          => open,
      full            => open,
      almost_full     => open,
      prog_full       => open,
      overflow        => open,
      wr_data_count   => data_count_datafifo_r(kWidthDataCount-1 downto 0),

      dout            => data_rd_datafifo_r,
      rd_en           => rd_en_datafifo_r,
      data_valid      => open,
      empty           => empty_datafifo_r,
      almost_empty    => open,
      prog_empty      => prog_full_datafifo_r,
      underflow       => open,
      rd_data_count   => open

    );


  -------------------------------------------------------------------------------
  -- DHCP TX state machine
  -------------------------------------------------------------------------------
  udp_txi.hdr.src_port    <= kDefaultSrcPort; -- fixed as 5005
  udp_txi.hdr.checksum    <= (others=>'0');

  rd_en_datafifo_r <= udpTxDataOutReady and rd_en_datafifo_valid_r;

  process(clk)
  begin
  	if rising_edge(clk) then
  	  udpTxData_being_sent_r <= rd_en_datafifo_r;
  	end if;
  end process;


  process(clk)
  begin
    if rising_edge(clk) then

--        in_idle <= '0';
--        idle_ready <= '0';
--        rd_en_datafifo_valid_r <= '0';

  		if reset='1' then
  			udp_tx_start                <= '0';
  			udp_txi.data.data_out_valid <= '0';
  			udp_txi.data.data_out_last  <= '0';
  			udp_txi.data.data_out       <= (others=>'0');
  			udp_txi.hdr.data_length     <= (others=>'0');
  			idle_waiting_count          <= (others => '0');

        in_idle                     <= '0';
        idle_ready                  <= '0';
        rd_en_datafifo_valid_r      <= '0';

  			state_tx  <=  Idle;
  		else
  			case state_tx is
  				when Idle =>
  				  state_tx_int <= "00";
  					tx_count  <=  (others => '0');
  					in_idle   <= '1';

  					if(idle_waiting_count < idle_waiting_time) then
  					  idle_waiting_count <= idle_waiting_count + '1';
  					  idle_ready <= '0';
  					else
  					  idle_ready <= '1';
  					end if;

  					if (frame_max_r = '1' and idle_ready = '1') then
  						udp_txi.hdr.data_length   <= std_logic_vector(max_length + kHeaderLength + 1);
              tx_count                  <= max_length + kHeaderLength;
  						state_tx                  <= FirstPayload;
  						rd_en_datafifo_valid_r    <= '0';
  						frame_type_r              <= '0';
  						header_index_r            <= 0;
  					end if;

  					if (timeout_r = '1' and idle_ready = '1') then
  						udp_txi.hdr.data_length   <= std_logic_vector(data_count_us + kHeaderLength + 1 - length_margin);
              tx_count                  <= data_count_us + kHeaderLength - length_margin;
  						state_tx                  <= FirstPayload;
  						rd_en_datafifo_valid_r    <= '0';
  						frame_type_r              <= '1';
  						header_index_r            <= 0;
  					end if;


          when FirstPayload =>
  				  state_tx_int                  <= "01";
  		      header_r                      <= std_logic_vector(unsigned(header_r) + '1');
            udp_tx_start                  <= '1';
            udp_txi.data.data_out_valid   <= '1';
            udp_txi.data.data_out         <= kPreamble;
            data_tx_r                     <= kPreamble;
            tx_count                      <= tx_count-1;
            state_tx                      <= StreamPayload;
            rd_en_datafifo_valid_r        <= '0';

  				when StreamPayload =>
  				  state_tx_int <= "10";

            if( udpTxResult = UDPTX_RESULT_ERR )then
              udp_tx_start                  <= '0';
  			      udp_txi.data.data_out_valid   <= '0';
  			      udp_txi.data.data_out_last    <= '0';
  			      state_tx                      <= Idle;
            elsif(udpTxDataOutReady = '1') then
              udp_tx_start                  <= '1';
              udp_txi.data.data_out_valid   <= '1';
              tx_count                      <= tx_count-1;

              if(header_index_r <= kHeaderLength + 1) then
      			    header_index_r <= header_index_r + 1;
      			  else
      			    header_index_r <= header_index_r;
      			  end if;

              if(header_index_r < kHeaderLength - 1) then
        			  rd_en_datafifo_valid_r <= '0';
        			else
        			  rd_en_datafifo_valid_r <= '1';
        			end if;

              if(header_index_r < kHeaderLength) then
        			  udp_txi.data.data_out <= header_r((header_index_r+1)*8-1 downto header_index_r*8);
        			  data_tx_r             <= header_r((header_index_r+1)*8-1 downto header_index_r*8);
        			else
                udp_txi.data.data_out        <= data_rd_datafifo_r;
                data_tx_r        <= data_rd_datafifo_r;
  			      end if;

              if(tx_count = 0) then
                udp_txi.data.data_out_last  <= '1';
                state_tx                   <= Finalize;
                rd_en_datafifo_valid_r        <= '0';
              end if;

            end if;

          when Finalize =>
            state_tx_int <= "11";
              rd_en_datafifo_valid_r      <= '0';
          	if (udpTxDataOutReady='1') then
          		udp_txi.data.data_out_valid <= '0';
          		udp_txi.data.data_out_last  <= '0';
          		udp_txi.data.data_out       <= (others=>'0');
          		udp_tx_start                <= '0';
              idle_waiting_count          <= (others => '0');
          		state_tx                    <= Idle;
          	end if;

          when others =>
            state_tx <= Idle;

  			end case;
  		end if;
  	end if;
  end process;

end RTL;


