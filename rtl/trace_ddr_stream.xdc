# trace_ddr_stream_top constraints — A7-Lite (XC7A35T-FGG484).
# doc 21 S2: same pinout as trace_ddr_selftest_top + trace pins from
# trace_stream.xdc. DDR3 pins come from the MIG IP's own generated XDC
# (mig_ddr3.xci) — do not duplicate them here.

# ---- sys clk / reset ----
set_property PACKAGE_PIN J19 [get_ports sys_clk_50]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk_50]
create_clock -period 20.000 -name sys_clk_50 [get_ports sys_clk_50]

set_property PACKAGE_PIN L18 [get_ports rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports rst_n]
set_false_path -from [get_ports rst_n]

# ---- Trace input pins (from STM32 TPIU / CURTPM), BANK 16 ----
# TRACECLK on MRCC D17; TRACED0..3 on F13/E14/D14/E16.
set_property PACKAGE_PIN D17 [get_ports trace_clk_in]
set_property PACKAGE_PIN F13 [get_ports {trace_data_in[0]}]
set_property PACKAGE_PIN E14 [get_ports {trace_data_in[1]}]
set_property PACKAGE_PIN D14 [get_ports {trace_data_in[2]}]
set_property PACKAGE_PIN E16 [get_ports {trace_data_in[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports trace_clk_in]
set_property IOSTANDARD LVCMOS33 [get_ports {trace_data_in[*]}]

# TRACECLK from H743 CURTPM/ETM. 12 ns period covers ~83 MHz with margin.
create_clock -period 12.000 -name trace_clk_in [get_ports trace_clk_in]
# BUFIO/BUFR mode: allow the dedicated-route demotion (D17 may not be in the
# BUFR's clock region for all placements).
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_pins u_capture/g_bufr.u_bufio_clk/O]]

# ---- Source-synchronous input timing for the DDR trace capture ----
# WHY: without set_input_delay on trace_data_in[*] vs trace_clk_in, the IDDR
# data capture is UNCONSTRAINED — Vivado's timing report flagged it as
# "no_input_delay (HIGH)". Each data pin then routes to its IDDR with an
# arbitrary, unequal delay and setup/hold at the sampling edge is never
# analysed. On the flying-wire rig this let per-lane / per-DDR-phase margin
# drift enough that some lanes (measured: TRACED0/PE3 and TRACED3/PE6) sampled
# the wrong value on one edge while others were fine — a silent, per-lane
# capture fault invisible to STA. Constraining the interface forces the tool to
# (a) analyse setup/hold and (b) balance the lane routing to a defined window.
#
# The STM32 TPIU is centre-aligned DDR: the data eye is centred on each
# TRACECLK edge (LA-measured: data transitions land ~mid-UI, ~4 ns from either
# sampling edge). Model a symmetric valid window around both clock edges.
# Half-UI @ the constrained 12 ns period = 6 ns; with ~3 ns edges the stable
# eye is ~±2.5 ns about the clock edge. Use max/min delays that describe a
# data-valid window of [1.2, 4.8] ns after the launching clock edge for both
# rising and falling (DDR), i.e. a 2.4 ns eye centred on the next edge.
# 2.4 ns is what the board shows at the shipped 56.25 MHz pin clock: every
# IDELAY tap 0..28 (2.2 ns of sweep) decodes clean, so the eye is wider than
# that plus the IDDR aperture. It is a lower bound for that frequency, not a
# datasheet value. The eye is narrower above ~75 MHz (see AGENT.md); there the
# run-time tap (CSR 0x05/0x06) is what has to be tuned, STA cannot judge it.
# The IDELAY tap IDLY_INIT (16) is the value STA closes with: at 4.8/1.2 the
# worst setup/hold slack is ~+0.05/+0.03 ns.
set _td [get_ports {trace_data_in[*]}]
set_input_delay -clock trace_clk_in -max 4.8 $_td
set_input_delay -clock trace_clk_in -min 1.2 $_td
set_input_delay -clock trace_clk_in -max 4.8 $_td -clock_fall -add_delay
set_input_delay -clock trace_clk_in -min 1.2 $_td -clock_fall -add_delay

# ---- RGMII (RTL8211E), BANK 15 ----
set_property PACKAGE_PIN K18 [get_ports phy_rx_clk]
set_property PACKAGE_PIN K19 [get_ports phy_rx_ctl]
set_property PACKAGE_PIN M16 [get_ports {phy_rxd[3]}]
set_property PACKAGE_PIN L16 [get_ports {phy_rxd[2]}]
set_property PACKAGE_PIN M15 [get_ports {phy_rxd[1]}]
set_property PACKAGE_PIN L14 [get_ports {phy_rxd[0]}]
set_property PACKAGE_PIN K17 [get_ports phy_tx_clk]
set_property PACKAGE_PIN N20 [get_ports phy_tx_ctl]
set_property PACKAGE_PIN M13 [get_ports {phy_txd[3]}]
set_property PACKAGE_PIN L13 [get_ports {phy_txd[2]}]
set_property PACKAGE_PIN L15 [get_ports {phy_txd[1]}]
set_property PACKAGE_PIN K16 [get_ports {phy_txd[0]}]
set_property PACKAGE_PIN N22 [get_ports phy_reset_n]
set_property PACKAGE_PIN M22 [get_ports phy_mdc]
set_property PACKAGE_PIN M20 [get_ports phy_mdio]
set_property IOSTANDARD LVCMOS33 [get_ports phy_*]
create_clock -period 8.000 -name phy_rx_clk [get_ports phy_rx_clk]

# ---- LEDs ----
set_property PACKAGE_PIN N18 [get_ports led0]
set_property PACKAGE_PIN M18 [get_ports led1]
set_property IOSTANDARD LVCMOS33 [get_ports led0]
set_property IOSTANDARD LVCMOS33 [get_ports led1]

# ---- Bitstream config (same as other DDR tops for QSPI compatibility) ----
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
