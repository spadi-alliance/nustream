library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.pack_axi.all;
use work.pack_ipv4_types.all;
use work.pack_arp_types.all;

use work.defNsArc.all;

Library xpm;
use xpm.vcomponents.all;

entity BcResponder is
  generic(
    kDstPort            : integer:= 5007;
    kEnDebug            : boolean:= false
  );
  port (
    -- system signals
    reset               : in  STD_LOGIC;
    clk	                : in  STD_LOGIC;

    ipAddress           : in std_logic_vector(31 downto 0);
    macAddress          : in std_logic_vector(47 downto 0);
    fwId                : in std_logic_vector(31 downto 0);

    -- UDP TX signals
    udpTxStart          : out std_logic;	-- indicates req to tx UDP
    udpTxi              : out udp_tx_type;	-- UDP tx cxns
    udpTxResult         : in std_logic_vector (1 downto 0);-- tx status (changes during transmission)
    udpTxDataOutReady   : in std_logic;	-- indicates udp_tx is ready to take data

    -- UDP RX signals
    udpRxStart          : in std_logic;		-- indicates receipt of udp header
    udpRxo              : in udp_rx_type

  );
end BcResponder;


architecture RTL of BcResponder is

  attribute mark_debug  : boolean;

  -- Internal signal declaration ---------------------------------------
  signal reg_src_ip_addr  : std_logic_vector(udpRxo.hdr.src_ip_addr'range);
  signal reg_src_port     : std_logic_vector(udpRxo.hdr.src_port'range);
  signal reg_dst_port     : std_logic_vector(udpRxo.hdr.src_port'range);

  -- RX --
  signal force_reset_rx  : std_logic;
  signal prev_hdr_is_valid : std_logic;

  signal is_valid_packet : std_logic;
  signal trg_reply       : std_logic;
  signal src_port_1     : std_logic_vector(15 downto 0);

  type DefStateRx is (Idle, CheckMagic, RecvSrcPort, Finalize);
  signal state_rx : DefStateRx;


  function compareBcMagic(
    index : integer;
    data  : std_logic_vector
  ) return boolean is
    constant  kBcMagic  : std_logic_vector(15 downto 0):= X"FFBC";

  begin
    if(kBcMagic(8*(index+1)-1 downto 8*index) = data) then
      return true;
    else
      return false;
    end if;
  end function;

  -- TX --
  constant kDataLength    : integer:= 32+48+32;
  constant kLenInByte     : integer:= kDataLength/8;
  type DefStateTx is (Idle, FirstPayload, StreamPayload, Finalize);
  signal state_tx     : DefStateTx;
  signal udp_tx_start : std_logic;
  signal udp_txi      : udp_tx_type;

  signal tx_payload   : std_logic_vector(kDataLength-1 downto 0);

  -- debug --------------------------------------------------------------
  attribute mark_debug of reg_src_port  : signal is kEnDebug;
  attribute mark_debug of state_rx  : signal is kEnDebug;
  attribute mark_debug of state_tx  : signal is kEnDebug;
  attribute mark_debug of trg_reply  : signal is kEnDebug;
  attribute mark_debug of is_valid_packet  : signal is kEnDebug;

begin
  -- =========================== body ===============================

  udpTxStart  <= udp_tx_start;
  udpTxi      <= udp_txi;

  tx_payload  <= ipAddress & macAddress & fwId;

  -------------------------------------------------------------------------------
  -- Broadcast RX state machine
  -------------------------------------------------------------------------------
  process(clk)
    variable counter: integer:=0;
  begin
    if(clk'event and clk='1') then
      if(reset = '1') then
        counter         := 0;
        force_reset_rx  <= '0';
      else
        if(state_rx /= Idle and udpRxStart = '0') then
          counter := counter +1;

          if(counter > 100) then
            force_reset_rx  <= '1';
            counter         := 0;
          end if;
        else
          force_reset_rx  <= '0';
          counter         := 0;
        end if;

      end if;
    end if;
  end process;

  process(clk)
    variable  data_index : integer:= 1;
  begin
    if(clk'event and clk='1') then
      if(reset = '1' or force_reset_rx = '1') then
        is_valid_packet <= '0';
        trg_reply       <= '0';
        prev_hdr_is_valid <= '0';
        state_rx        <=  Idle;
      else
        prev_hdr_is_valid <= udpRxo.hdr.is_valid;

        case state_rx is
          when Idle =>
            trg_reply <= '0';
            if( prev_hdr_is_valid = '0' and udpRxo.hdr.is_valid = '1' and udpRxo.hdr.is_broadcast = '1') then
              reg_src_ip_addr   <= udpRxo.hdr.src_ip_addr;
              --reg_src_port      <= udpRxo.hdr.src_port;
  --            reg_dst_ip_addr   <= udpRxo.hdr.dst_ip_addr;
              reg_dst_port      <= udpRxo.hdr.dst_port;

              if(udpRxo.hdr.dst_port = std_logic_vector(to_unsigned(kDstPort, 16))) then
                is_valid_packet <= '1';
                data_index      := 1;
                state_rx        <=  CheckMagic;
              end if;
            end if;

          when CheckMagic =>
            if(udpRxo.data.data_in_valid = '1') then
              if( compareBcMagic(data_index, udpRxo.data.data_in) /= true ) then
                is_valid_packet <= '0';
              end if;

              if(data_index = 1) then
                data_index  := 0;
              else
                data_index  := 1;
                state_rx    <= RecvSrcPort;
              end if;
            end if;

          when RecvSrcPort =>
            if(udpRxo.data.data_in_valid = '1') then
              if(data_index = 1) then
                reg_src_port(15 downto 8) <= udpRxo.data.data_in;
                data_index  := 0;
              else
                reg_src_port(7 downto 0) <= udpRxo.data.data_in;
                state_rx    <= Finalize;
              end if;
            end if;

          when Finalize =>
            trg_reply       <= is_valid_packet;
            state_rx        <= Idle;

          when others =>
            state_rx        <= Idle;

        end case;
      end if;
    end if;
  end process;

  -------------------------------------------------------------------------------
  -- Reply TX state machine
  -------------------------------------------------------------------------------
  --udpTxi.hdr.src_ip_addr <= reg_dst_ip_addr;
  udp_txi.hdr.dst_ip_addr <= reg_src_ip_addr;
  udp_txi.hdr.src_port    <= reg_dst_port;
  udp_txi.hdr.dst_port    <= reg_src_port;
  udp_txi.hdr.checksum    <= (others=>'0');

  process(clk)
    variable index  : integer:= 0;
  begin
    if(clk'event and clk = '1')then
      if( reset='1' ) then
        udp_tx_start                  <= '0';
        udp_txi.data.data_out_valid  <= '0';
        udp_txi.data.data_out_last   <= '0';
        udp_txi.data.data_out        <= (others=>'0');
        udp_txi.hdr.data_length      <= (others=>'0');

        state_tx  <=  Idle;
      else
      case state_tx is
        when Idle =>
          if(trg_reply = '1') then
            index                     := kLenInByte -1;
            udp_txi.hdr.data_length   <= std_logic_vector(to_unsigned(kLenInByte, 16));
            state_tx                  <= FirstPayload;
          end if;

          when FirstPayload =>
            udp_tx_start                  <= '1';
            udp_txi.data.data_out_valid   <= '1';
            udp_txi.data.data_out         <= tx_payload(8*index+7 downto 8*index);
            index                         := index -1;
            state_tx                      <= StreamPayload;

          when StreamPayload =>
            if( udpTxResult = UDPTX_RESULT_ERR )then
              udp_tx_start                  <= '0';
              udp_txi.data.data_out_valid   <= '0';
              udp_txi.data.data_out_last    <= '0';
              state_tx                      <= Idle;
            elsif(udpTxDataOutReady = '1') then
              udp_tx_start                  <= '1';
              udp_txi.data.data_out_valid   <= '1';
              udp_txi.data.data_out         <= tx_payload(8*index+7 downto 8*index);

              if(index = 0) then
                udp_txi.data.data_out_last  <= '1';
                state_tx                    <= Finalize;
              end if;

              index                         := index -1;
            end if;

          when Finalize =>
            if udpTxDataOutReady='1' then
              udp_txi.data.data_out_valid <= '0';
              udp_txi.data.data_out_last  <= '0';
              udp_tx_start                <= '0';
              state_tx                    <= Idle;
            end if;

          when others =>
            state_tx <= Idle;

        end case;
      end if;
    end if;
  end process;



end RTL;

