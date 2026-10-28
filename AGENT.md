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
the TRACECLK edge, LA-confirmed). TRACECLK reaches the IDDR C pins ~3.3 ns after
the pin (IBUF + BUFIO) while the data only sees the IBUF (~1.3 ns), so a bare
IBUF→IDDR samples ~2 ns late: Vivado's ~-1.2 ns hold violation on the four data
inputs was real. That was invisible up to ~56 MHz pin clock and broke 75 MHz.
Each data lane therefore has an **IDELAYE2 (VAR_LOAD, 78 ps/tap)** tuned at run
time: CSR 0x05 sets all lanes, CSR 0x06 one lane (`{lane[6:5], tap[4:0]}`), power-on
tap 16 (`cortrace fpga ctrl set-tap`). Measured on the H743 rig (4-bit, 5 s
captures decoded with cortrace, `lost-sync` and usable ETM bytes):

| TRACECLK pin | clean taps |
|---|---|
| 56.25 MHz | all (0..28 tried) |
| 75 MHz | 12..30 |
| 83 MHz | 12..22 |
| 90 MHz and up | none (best: 89.6 MHz tap 12, still ~90 lost-sync per 3 MB) |

Tap 16 is inside the clean range from 56 to 83 MHz. Above that the eye is too
narrow for one tap for all lanes; per-lane taps (CSR 0x06) are the next thing
to try. STA cannot judge the tap: the XDC models a 2.4 ns eye (`-min 1.2 -max
4.8`, a lower bound from the 56 MHz sweep) and closes with tap 16; the tap is
re-tuned against the real decode, not against STA. Do not remove the IDELAY: a
direct IBUF→IDDR front end is what failed at 75 MHz.
