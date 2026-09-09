#!/usr/bin/env bash
# Everything that ends up inside the initramfs: fesvr-zynq, the RV64 test
# program, pl-probe, xv6, and busybox.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

say "libfesvr + fesvr-zynq"
mkdir -p "$COMMON_BUILD"
( cd "$COMMON_BUILD" && "$ROCKET/riscv-tools/riscv-fesvr/configure" --host="$CROSS_ARM" \
  && make libfesvr.so )
# -lfesvr goes AFTER the sources. Makefrag puts it first, which worked when ld
# scanned libraries regardless of position; current ld resolves left to right,
# so an early -lfesvr contributes nothing and context_t::switch_to comes back
# undefined.
$CROSS_ARM-g++ -O2 -std=c++11 -Wall -Wl,-rpath,/usr/local/lib \
  -I "$FPGA_ZYNQ/common/csrc" -I "$FPGA_ZYNQ/testchipip/csrc" \
  -I "$ROCKET/riscv-tools/riscv-fesvr/" \
  -o "$COMMON_BUILD/fesvr-zynq" \
  "$FPGA_ZYNQ/common/csrc/fesvr_zynq.cc" "$FPGA_ZYNQ/common/csrc/zynq_driver.cc" \
  "$FPGA_ZYNQ/testchipip/csrc/blkdev.cc" \
  -L"$COMMON_BUILD" -lfesvr

say "hello.riscv and pl-probe"
make -C "$XV6_REPO/riscv-test"
$CROSS_ARM-gcc -O2 -static -o "$OUT/pl-probe" "$XV6_REPO/tools/pl-probe.c"

say "xv6"
X="${XV6_SRC:-$OUT/xv6-riscv}"
[ -d "$X" ] || git clone https://github.com/mit-pdos/xv6-riscv.git "$X"
git -C "$X" checkout -q "$(cat "$XV6_REPO/xv6/BASE_COMMIT")"
git -C "$X" apply --check "$XV6_REPO/xv6/0001-xv6-rocket-port.patch" 2>/dev/null \
  && git -C "$X" apply "$XV6_REPO/xv6/0001-xv6-rocket-port.patch"
cp "$XV6_REPO/xv6/htif.c" "$XV6_REPO/xv6/blkdev.c" "$X/kernel/"
make -C "$X" TOOLPREFIX=$CROSS_RV- -j"$JOBS" kernel/kernel fs.img

say "busybox"
B="${BUSYBOX_SRC:-$OUT/busybox}"
[ -d "$B" ] || git clone --branch 1_36_1 --depth 1 \
    https://github.com/mirror/busybox.git "$B"
# This repo does not carry a busybox .config; upstream defconfig plus
# CONFIG_STATIC is what the rootfs needs, and reproduces the shipped binary.
make -C "$B" ARCH=arm CROSS_COMPILE=$CROSS_ARM- defconfig >/dev/null
sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/;s/^CONFIG_TC=y/# CONFIG_TC is not set/' "$B/.config"
make -C "$B" ARCH=arm CROSS_COMPILE=$CROSS_ARM- oldconfig >/dev/null </dev/null
make -C "$B" ARCH=arm CROSS_COMPILE=$CROSS_ARM- -j"$JOBS"
ls -la "$COMMON_BUILD/fesvr-zynq" "$X/kernel/kernel" "$X/fs.img" "$B/busybox"
