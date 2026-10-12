# AGENT.md — cortrace-fpga working conventions

## What this repo is
Artix-7 FPGA capture of a Cortex-M parallel ETM trace port, streamed over UDP
to the host, decoded by cortrace. See README.md and docs/00-migration-plan.md.

## Hardware / environment
- **FPGA**: A7-Lite, `xc7a35tfgg484-2`. Program via FT232H (`0403:6014`) with
  `host/scripts/fpga_flash.sh <bit>`: it writes the QSPI flash (survives power-off),
  verifies it, reloads the FPGA from the flash and prints the design version it
  reports. `--sram` loads into SRAM only (volatile), to try a design. It wraps
  `openFPGALoader -c ft232 --fpga-part xc7a35tfgg484 [-f --verify] <bit>`.
- **FPGA IP = `<FPGA_IP>`** (fixed in the bitstream; see `DEFAULT_FPGA_IP` in
  cortrace's `python/cortrace/fpga/net.py`). It answers ARP only, no ICMP — normal.
- **Trace NIC** (direct-attached, `<nic>`) MUST hold **`<HOST_IP>`** (the
  address the bitstream streams to, port 5555). After reboot:
  `sudo ip addr add <HOST_IP>/24 dev <nic>`. Wrong host IP => ARP ok,
  discover ok, but the `:5555` stream is 0 bytes.
- **Capture tools live in the cortrace package** (`cortrace-grab`, `cortrace fpga
  ctrl|net|health`, `cortrace capture|serve`); install its .deb. `cortrace-grab`
  needs NO privileges on Linux >= 5.7 (verified: 75 MB/s, 0 lost, no caps, no
  sudo); only ARP discovery (`cortrace fpga net`) needs CAP_NET_RAW.
- **Vivado 2021.1**: `source <vivado-install>/settings64.sh`.
  The DDR3/clock IP `.xci` are pinned to this version.
- **STM32 target**: firmware in the sibling `stm32h743-etm-trace-firmware`
  repo. OpenOCD reliable halt while selftrace runs: connect under reset —
  `-c "reset_config srst_only connect_assert_srst"` then `reset halt`.
- Port :5555 often held by a stale grab: `sudo fuser -k 5555/udp` or
  `pkill -9 -x cortrace-grab`.

## Build discipline
- Long Vivado builds: run in the background with the log redirected to a file;
  don't repeatedly foreground `vivado | grep`. Sweep parameters inside one
  vivado process, not one process per point.

## Verify before shipping
- RTL: `python3 sim/run_verilog_tests.py` (must be all-pass; la_ddr_ring TEST F
  gates the -1024 burst-reorder fix, prbs_cdc_pack gates the lane-skew fix).
- Host: `cd host/scripts && python3 -m pytest test_commit_msg_hook.py`. Capture, decoding and fusion live in cortrace (the Python decoders in `host/decode/` were retired; `stream_grab`/`trace_ctrl`/`fpga_net`/`fpga_health`/`itm_capture`/`cortrace_live` moved there).
- Board byte-exact: `host/scripts/prbs_soak.py --minutes N` (framed PRBS, 0
  byte errors expected).
- Board end-to-end: `host/scripts/e2e_soak.py --minutes N` (real trace through
  cortrace: 0 fatal, balanced, 0 dropped calls).

## Git
- Commit author: the maintainer's `<name> <email>` (set as repo-local git config once).
- Conventional-Commit subjects enforced by `.githooks/commit-msg`
  (`scripts/install-hooks.sh` wires `core.hooksPath`). English commit messages.
- Never write scratch files under `.git/`. Write commit messages with
  `git commit -m` in the terminal.
- Push is the user's job.

## Versioning
`VERSION` (X.Y.Z) is the design version. `fpga_flow/build_trace_stream.tcl` stamps it, the git
commit, flags (dirty / pre-release / not-a-tag) and the synthesis time (`BUILD_ID`, Unix time) into
the readout registers `0xFF70..0xFF7F`, plus a `FEATURES` bitmap of what the bitstream implements.
`cortrace fpga health` prints them (read over UDP :5001, no JTAG). Bump `VERSION` for any change to
the register map or the datapath, and build releases from a clean tree at the `v<VERSION>` tag. When
you add or wire a monitor, update `FEATURES` in `trace_ddr_stream_top.v` and the host side in
cortrace `fpga/health.py` together.

## Key finding baked into the design
The STM32 TPIU drives the parallel port **centre-aligned** (data stable around
the TRACECLK edge, LA-confirmed), so the capture is plain IBUF→IDDR edge
sampling with **no IDELAY** — frequency-independent, one bitstream for any
TRACECLK the board SI supports (<=56 MHz pin clean; 112 MHz is board-SI-limited,
not a capture-logic limit). Do not re-introduce IDELAY taps.
