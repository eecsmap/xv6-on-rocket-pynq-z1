#!/usr/bin/env bash
# Build the Zynq-7000 FSBL.
#
# Not the flow in the README's Building section: xsct does not exist in Vitis
# 2025.x. Vitis's own create_platform_component also fails here, with nothing
# but "Application error processing RPC" to go on. empyro is the path that
# works. zynq_fsbl is not in its advertised template list but is accepted.
#
# Needs an .xsa: scripts/export-xsa.tcl writes one from the built project.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

XSA="${XSA:-$BOARD/pynqz1_rocketchip_ZynqFPGAConfig.xsa}"
WS="${WS:-$OUT/fsbl}"
ESW="${ESW:-$(dirname "$(command -v vitis)")/../data/embeddedsw}"
[ -f "$XSA" ] || { echo "no XSA at $XSA -- run scripts/export-xsa.tcl first"; exit 1; }

say "system device tree"
rm -rf "$WS"; mkdir -p "$WS/sdt"
sdtgen "$(dirname "$(command -v vitis)")/../vitis-server/scripts/platformutil.tcl" "$XSA" "$WS/sdt"

say "BSP"
empyro repo -st "$ESW" >/dev/null
empyro create_bsp -w "$WS/bsp" -o standalone -t zynq_fsbl \
       -p ps7_cortexa9_0 -s "$WS/sdt/system-top.dts"
empyro build_bsp -d "$WS/bsp"

say "application"
empyro create_app -w "$WS/app" -n fsbl -d "$WS/bsp" -t zynq_fsbl
cp "$XV6_REPO/fsbl/main.c"                 "$WS/app/src/main.c"
cp "$XV6_REPO/fsbl/stack_init_override.c"  "$WS/app/src/"
# FSBL_DEBUG_INFO is not optional: without it every fsbl_printf compiles out and
# a healthy FSBL boots silently, which is indistinguishable from a dead one.
python3 - "$WS/app/src/UserConfig.cmake" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('set(USER_COMPILE_DEFINITIONS\n""\n)',
              'set(USER_COMPILE_DEFINITIONS\n"FSBL_DEBUG_INFO"\n)', 1)
s = s.replace('set(USER_COMPILE_SOURCES\n)',
              'set(USER_COMPILE_SOURCES\n${CMAKE_SOURCE_DIR}/stack_init_override.c\n)', 1)
s = s.replace('set(USER_COMPILE_OPTIMIZATION_LEVEL -O0)',
              'set(USER_COMPILE_OPTIMIZATION_LEVEL )', 1)
s = s.replace('set(USER_COMPILE_OPTIMIZATION_OTHER_FLAGS )',
              'set(USER_COMPILE_OPTIMIZATION_OTHER_FLAGS -Og)', 1)
open(p, "w").write(s)
PY
empyro build_app -w "$WS/app"
cp "$WS/app/build/fsbl.elf" "$OUT/fsbl.elf"
ls -la "$OUT/fsbl.elf"
