#!/usr/bin/env bash
# fpga_flash.sh -- put a bitstream on the A7-Lite (xc7a35tfgg484) through the
# FT232H JTAG.
#
#   fpga_flash.sh <bitstream.bit>          write the QSPI flash, verify it, then
#                                          reload the FPGA from the flash
#   fpga_flash.sh --sram <bitstream.bit>   load into SRAM only (lost at power-off)
#
# The flash write survives power-off; the SRAM load is for trying a design.
# The last step prints the design version the FPGA reports, so a bitstream
# that did not take shows up at once.
#
# The QSPI flash must be the boot source (the board's mode setting). To go back
# to an earlier design, write its .bit the same way.
set -euo pipefail

CABLE="${FPGA_CABLE:-ft232}"
PART="${FPGA_PART:-xc7a35tfgg484}"
LOADER=(openFPGALoader -c "$CABLE" --fpga-part "$PART")

sram=0
if [ "${1:-}" = "--sram" ]; then
  sram=1
  shift
fi
bit="${1:?usage: $0 [--sram] <bitstream.bit>}"
[ -f "$bit" ] || { echo "no such file: $bit" >&2; exit 1; }

if [ "$sram" = 1 ]; then
  "${LOADER[@]}" "$bit"
else
  "${LOADER[@]}" -f --verify "$bit"
  # JPROGRAM: the FPGA configures itself from the flash again, as at power-on.
  "${LOADER[@]}" --reset
fi

sleep 6
if command -v cortrace >/dev/null; then
  CORTRACE_NO_BANNER=1 cortrace fpga health | sed -n 1,3p
fi
