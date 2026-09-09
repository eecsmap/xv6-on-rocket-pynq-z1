#!/usr/bin/env bash
# Apply every patch this repo carries for the upstream trees.
#
# All of them exist because the sources predate the current toolchain by roughly
# a decade. They are idempotent: already-applied patches are skipped.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

apply_to() {                       # apply_to <tree> <patch-dir>
  local tree="$1" dir="$2" p
  [ -d "$tree" ] || { echo "skip $dir: $tree not checked out"; return 0; }
  for p in "$XV6_REPO/patches/$dir"/0*.patch; do
    [ -e "$p" ] || continue
    if git -C "$tree" apply --check "$p" 2>/dev/null; then
      git -C "$tree" apply "$p" && echo "  applied  $dir/$(basename "$p")"
    elif git -C "$tree" apply --reverse --check "$p" 2>/dev/null; then
      echo "  already  $dir/$(basename "$p")"
    else
      echo "  FAILED   $dir/$(basename "$p")"; return 1
    fi
  done
}

say "patching upstream trees"
apply_to "$ROCKET/firrtl"                       rocket-chip-firrtl
apply_to "$ROCKET/riscv-tools/riscv-fesvr"      riscv-fesvr
apply_to "$FPGA_ZYNQ/common/u-boot-xlnx"        u-boot-xlnx
apply_to "$FPGA_ZYNQ/common/linux-xlnx"         linux-xlnx

# Loose files the patches expect alongside them.
cp -f "$XV6_REPO/patches/u-boot-xlnx/compiler-gcc13.h" \
      "$FPGA_ZYNQ/common/u-boot-xlnx/include/linux/" 2>/dev/null || true
cp -f "$XV6_REPO/patches/linux-xlnx/compiler-gcc13.h" \
      "$FPGA_ZYNQ/common/linux-xlnx/include/linux/" 2>/dev/null || true
cp -f "$XV6_REPO/board/soft_config/zynq_pynqz1.h" \
      "$FPGA_ZYNQ/common/u-boot-xlnx/include/configs/" 2>/dev/null || true
echo "done"
