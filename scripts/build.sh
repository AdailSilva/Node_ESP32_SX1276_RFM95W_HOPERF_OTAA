#!/bin/sh
# Builds (and optionally flashes / monitors) the node firmware for one board.
#
#   BOARD             Module (DevKit)                  IDF_TARGET  Console (UART0)
#   esp32             ESP32-WROOM-32U                  esp32       /dev/ttyUSB0
#   esp32s3_n16r8     ESP32-S3-WROOM-1U-N16R8          esp32s3     /dev/ttyUSB0 ("UART" connector)
#   esp32s3_n32r16v   ESP32-S3-WROOM-2-N32R16V         esp32s3     /dev/ttyUSB0 ("UART" connector)
#   esp32s3           = esp32s3_n32r16v
#
#   scripts/build.sh esp32                                 # build only
#   scripts/build.sh esp32s3_n16r8
#   scripts/build.sh esp32s3_n32r16v
#   scripts/build.sh esp32           flash   /dev/ttyUSB0  # build + flash + monitor
#   scripts/build.sh esp32s3_n16r8   flash   /dev/ttyUSB0
#   scripts/build.sh esp32s3_n32r16v flash   /dev/ttyUSB0
#   scripts/build.sh esp32           monitor /dev/ttyUSB0  # monitor only (no build)
#   scripts/build.sh esp32           erase   /dev/ttyUSB0  # erase the whole flash (factory reset, FCnt 0)
#   scripts/build.sh all                                   # build the three boards
#
# Build directory and sdkconfig per board (same scheme as the gateway):
#   build-esp32/            + sdkconfig.esp32
#   build-esp32s3_n16r8/    + sdkconfig.esp32s3_n16r8
#   build-esp32s3_n32r16v/  + sdkconfig.esp32s3_n32r16v
# Options: sdkconfig.defaults + boards/<board>.defaults (CMakeLists.txt).
# Factory pins of the RFM95W per board: main/node_board.h.
# The DevKitC-1 with a CH343 USB-UART shows up as /dev/ttyACM0: pass the port.
# Console speed: 115200 bps. If "Velocidade da serial" was changed on the web
# page (Hardware), run with BAUD=<speed>, e.g. BAUD=9600 sh scripts/build.sh ...
# Run ". $IDF_PATH/export.sh" (ESP-IDF) before this script.
set -e
cd "$(dirname "$0")/.."

usage() {
	echo "usage: $0 <esp32|esp32s3_n16r8|esp32s3_n32r16v|all> [flash|monitor|erase <port>]"
	exit 1
}

board="$1"
case "$board" in
	esp32)                         target=esp32 ;;
	esp32s3_n16r8|esp32s3_n32r16v) target=esp32s3 ;;
	esp32s3)                       board=esp32s3_n32r16v; target=esp32s3 ;;
	all)
		[ -z "$2" ] || usage
		# every board is built even if one fails; the failures are listed at the end
		failed=""
		for b in esp32 esp32s3_n16r8 esp32s3_n32r16v; do sh "$0" "$b" || failed="$failed $b"; done
		[ -z "$failed" ] || { echo "FAILED:$failed"; exit 1; }
		exit 0 ;;
	*) usage ;;
esac

command -v idf.py >/dev/null || { echo "idf.py not found: run '. \$IDF_PATH/export.sh' first"; exit 1; }

# build-<board>/ configured in another folder (e.g. the workspace moved from
# ~/Apps/esp-idf_workspace to ~/Apps/lorawan_workspace): CMake and idf.py refuse
# the old cache ("CMakeCache.txt directory ... is different", "configured for
# project ..."). Remove it so this build configures from scratch.
if [ -f "build-$board/CMakeCache.txt" ]; then
	cached=$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "build-$board/CMakeCache.txt")
	if [ -n "$cached" ] && [ "$cached" != "$(pwd)" ] && [ "$cached" != "$(pwd -P)" ]; then
		echo "note: build-$board/ was configured in $cached: removing it (stale cache)"
		rm -rf "build-$board"
	fi
fi

[ -n "$BAUD" ] && export IDF_MONITOR_BAUD="$BAUD"
idf="idf.py -B build-$board -D SDKCONFIG=sdkconfig.$board -D IDF_TARGET=$target -D BOARD=$board"
port="${3:-/dev/ttyUSB0}"
echo ">>> board $board (IDF_TARGET $target): $idf"

case "$2" in
	monitor) $idf -p "$port" monitor ;;
	erase)   $idf -p "$port" erase-flash ;;
	flash)   $idf build && $idf -p "$port" flash monitor ;;
	"")      $idf build ;;
	*)       usage ;;
esac
