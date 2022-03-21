library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.spwpkg.all;

entity packet_rx is

--    generic (
--        -- System clock frequency in Hz.
--        sysfreq:    real := 20.0e6;

--        -- txclk frequency in Hz (if tximpl = impl_fast).
--        txclkfreq:  real := 0.0;

--        -- 2-log of division factor from system clock freq to timecode freq.
--        tickdiv:    integer range 12 to 24 := 20;

--        -- Receiver front-end implementation.
--        -- CANNOT PLACE impl_generic here due to bad importing of type structure
--        rximpl:     spw_implementation_type := impl_generic;

--        -- Maximum number of bits received per system clock (impl_fast only).
--        rxchunk:    integer range 1 to 4 := 1;

--        -- Transmitter implementation.
--        tximpl:     spw_implementation_type := impl_generic;

--        -- Size of receive FIFO.
--        rxfifosize_bits: integer range 6 to 14 := 11;

--        -- Size of transmit FIFO.
--        txfifosize_bits: integer range 2 to 14 := 11 );

    port (
        -- System clock.
        clk:        in  std_logic;

        -- Receiver sample clock (only for impl_fast).
        rxclk:      in  std_logic;

        -- Transmit clock (only for impl_fast).
        txclk:      in  std_logic;

        -- Synchronous reset (active-high).
        rst:        in  std_logic;

        -- Enables spontaneous link start.
        linkstart:  in  std_logic;

        -- Enables automatic link start on receipt of a NULL token.
        autostart:  in  std_logic;

        -- Enable sending test patterns to spwstream.
        senddata:   in  std_logic;

        -- Enable sending time codes to spwstream.
        sendtick:   in  std_logic;

        -- Scaling factor minus 1 for TX bitrate.
        txdivcnt:   in  std_logic_vector(7 downto 0);

        -- Link in state Started.
        linkstarted: out std_logic;

        -- Link in state Connecting.
        linkconnecting: out std_logic;

        -- Link in state Run.
        linkrun:    out std_logic;

        -- Link error (one cycle pulse, not directly suitable for LED)
        linkerror:  out std_logic;

        -- High when taking a byte from the receive FIFO.
        gotdata:    out std_logic;

        -- Incorrect or unexpected data received (sticky).
        dataerror:  out std_logic;

        -- Incorrect or unexpected time code received (sticky).
        tickerror:  out std_logic;
        
        -- DEV OUTPUTS:

        -- Output for txwrite bit
        txwrite_o: out std_logic;
        
        -- Output for txrdy bit
        txrdy_o: out std_logic;
        
        -- Output for rxread bit
        rxread_o: out std_logic;
        
        -- Output for rxvalid bit
        rxvalid_o: out std_logic;
        
        -- Output for rxdata
        rxdata_o: out std_logic_vector(7 downto 0);


        -- SpaceWire signals.
        spw_di:     in  std_logic;
        spw_si:     in  std_logic;
        spw_do:     out std_logic;
        spw_so:     out std_logic );

end entity packet_rx;

architecture packet_rx_arch of packet_rx is
    
        -- System clock frequency in Hz.
        constant sysfreq:    real := 20.0e6;

        -- txclk frequency in Hz (if tximpl = impl_fast).
        constant txclkfreq:  real := 0.0;

        -- 2-log of division factor from system clock freq to timecode freq.
        constant tickdiv:    integer range 12 to 24 := 20;

        -- Receiver front-end implementation.
        -- CANNOT PLACE impl_generic here due to bad importing of type structure
        constant rximpl:     spw_implementation_type := impl_generic;

        -- Maximum number of bits received per system clock (impl_fast only).
        constant rxchunk:    integer range 1 to 4 := 1;

        -- Transmitter implementation.
        constant tximpl:     spw_implementation_type := impl_generic;

        -- Size of receive FIFO.
        constant rxfifosize_bits: integer range 6 to 14 := 11;

        -- Size of transmit FIFO.
        constant txfifosize_bits: integer range 2 to 14 := 11;

    -- Update 16-bit maximum length LFSR by 8 steps
    function lfsr16(x: in std_logic_vector) return std_logic_vector is
        variable y: std_logic_vector(15 downto 0);
    begin
        -- poly = x^16 + x^14 + x^13 + x^11 + 1
        -- tap positions = x(0), x(2), x(3), x(5)
        y(7 downto 0)  := x(15 downto 8);
        y(15 downto 8) := x(7 downto 0) xor x(9 downto 2) xor x(10 downto 3) xor x(12 downto 5);
        return y;
    end function;

    -- Sending side state.
    type tx_state_type is ( txst_idle, txst_prepare, txst_data );

    -- Receiving side state.
    type rx_state_type is ( rxst_idle, rxst_data );

    -- Registers.
    type regs_type is record
        tx_state:       tx_state_type;
        tx_timecnt:     std_logic_vector((tickdiv-1) downto 0);
        tx_quietcnt:    std_logic_vector(15 downto 0);
        tx_pktlen:      std_logic_vector(15 downto 0);
        tx_lfsr:        std_logic_vector(15 downto 0);
        tx_enabledata:  std_ulogic;
        rx_state:       rx_state_type;
        rx_quietcnt:    std_logic_vector(15 downto 0);
        rx_enabledata:  std_ulogic;
        rx_gottick:     std_ulogic;
        rx_expecttick:  std_ulogic;
        rx_expectglitch: unsigned(5 downto 0);
        rx_badpacket:   std_ulogic;
        rx_pktlen:      std_logic_vector(15 downto 0);
        rx_prev:        std_logic_vector(15 downto 0);
        rx_lfsr:        std_logic_vector(15 downto 0);
        running:        std_ulogic;
        tick_in:        std_ulogic;
        time_in:        std_logic_vector(5 downto 0);
        txwrite:        std_ulogic;
        txflag:         std_ulogic;
        txdata:         std_logic_vector(7 downto 0);
        rxread:         std_ulogic;
        gotdata:        std_ulogic;
        dataerror:      std_ulogic;
        tickerror:      std_ulogic;
    end record;

    -- Reset state.
    constant regs_reset: regs_type := (
        tx_state        => txst_idle,
        tx_timecnt      => (others => '0'),
        tx_quietcnt     => (others => '0'),
        tx_pktlen       => (others => '0'),
        tx_lfsr         => (1 => '1', others => '0'),
        tx_enabledata   => '1',
        rx_state        => rxst_idle,
        rx_quietcnt     => (others => '0'),
        rx_enabledata   => '1',
        rx_gottick      => '0',
        rx_expecttick   => '0',
        rx_expectglitch => "000001",
        rx_badpacket    => '0',
        rx_pktlen       => (others => '0'),
        rx_prev         => (others => '0'),
        rx_lfsr         => (others => '0'),
        running         => '0',
        tick_in         => '0',
        time_in         => (others => '0'),
        txwrite         => '0',
        txflag          => '0',
        txdata          => (others => '0'),
        rxread          => '0',
        gotdata         => '0',
        dataerror       => '0',
        tickerror       => '0' );

    signal r:   regs_type := regs_reset;
    signal rin: regs_type;

    -- Interface signals.
    signal s_txrdy:     std_logic;
    signal s_tickout:   std_logic;
    signal s_timeout:   std_logic_vector(5 downto 0);
    signal s_rxvalid:   std_logic;
    signal s_rxflag:    std_logic;
    signal s_rxdata:    std_logic_vector(7 downto 0);
    signal s_running:   std_logic;
    signal s_errdisc:   std_logic;
    signal s_errpar:    std_logic;
    signal s_erresc:    std_logic;
    signal s_errcred:   std_logic;
    
    -- Do not start link and/or disconnect current link.
    signal linkdisable: std_logic;

begin

    -- spwstream instance
    spwstream_inst: spwstream
        generic map (
            sysfreq         => sysfreq,
            txclkfreq       => txclkfreq,
            rximpl          => rximpl,
            rxchunk         => rxchunk,
            tximpl          => tximpl,
            rxfifosize_bits => rxfifosize_bits,
            txfifosize_bits => txfifosize_bits )
        port map (
            clk         => clk,
            rxclk       => rxclk,
            txclk       => txclk,
            rst         => s_errcred,
            autostart   => autostart,
            linkstart   => linkstart,
            linkdis     => linkdisable,
            txdivcnt    => txdivcnt,
            tick_in     => r.tick_in,
            ctrl_in     => (others => '0'),
            time_in     => r.time_in,
            txwrite     => r.txwrite,
            txflag      => r.txflag,
            txdata      => r.txdata,
            txrdy       => s_txrdy,
            txhalff     => open,
            tick_out    => s_tickout,
            ctrl_out    => open,
            time_out    => s_timeout,
            rxvalid     => s_rxvalid,
            rxhalff     => open,
            rxflag      => s_rxflag,
            rxdata      => s_rxdata,
            rxread      => r.rxread,
            started     => linkstarted,
            connecting  => linkconnecting,
            running     => s_running,
            errdisc     => s_errdisc,
            errpar      => s_errpar,
            erresc      => s_erresc,
            errcred     => s_errcred,
            spw_di      => spw_di,
            spw_si      => spw_si,
            spw_do      => spw_do,
            spw_so      => spw_so );

    -- Drive status indications.
    linkrun     <= s_running;
    linkerror   <= s_errcred;
    gotdata     <= r.gotdata;
    
    -- Dev outputs
    txwrite_o <= r.txwrite;
    txrdy_o <= s_txrdy;
    rxread_o <= r.rxread;
    rxvalid_o <= s_rxvalid;
    rxdata_o <= s_rxdata;

    process (r, rst, senddata, sendtick, s_txrdy, s_tickout, s_timeout, s_rxvalid, s_rxflag, s_rxdata, s_running) is
        variable v: regs_type;
    begin
        v           := r;

        -- Blink light when receiving data.
        v.gotdata   := s_rxvalid and r.rxread;

        -- RECIEVER/TRANSCIEVER
        linkdisable <= '0';
		v.rxread    := '0';
		v.txwrite	:= '0';
		if s_rxvalid = '1' and s_txrdy = '1' then
			v.rxread    := '1'; -- activate read bit
			v.txwrite   := '1'; -- activate write bit
			v.txflag	:= s_rxflag;
			v.txdata 	:= s_rxdata;
		end if;
		
        -- Synchronous reset.
        if rst = '1' then
            v := regs_reset;
        end if;

        -- Update registers.
        rin <= v;
    end process;

    -- Update registers.
    process (clk) is
    begin
        if rising_edge(clk) then
            r <= rin;
        end if;
    end process;

end architecture packet_rx_arch;
