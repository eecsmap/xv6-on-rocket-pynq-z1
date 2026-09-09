#!/usr/bin/env bash
# u-boot 2014.07, Linux 3.15 and the devicetree, with a current toolchain.
#
# Three flags the README's Building section does not mention, all of them
# because these sources predate GCC 10:
#
#   HOSTCFLAGS=-fcommon    scripts/dtc has duplicate tentative definitions
#                          (yylloc) that the host compiler now rejects.
#   KCFLAGS=-fcommon       the same, in target code (nop_dma_map_area).
#   KCFLAGS=-fgnu89-inline gnu89 and C99 give `extern inline` opposite meanings.
#                          3.15 assumes gnu89, where it emits nothing; a current
#                          GCC emits a definition per translation unit. The
#                          symptom is arch/arm/mm symbols turning up duplicated
#                          in, of all places, fs/ext4 object files.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
U="$FPGA_ZYNQ/common/u-boot-xlnx"
K="$FPGA_ZYNQ/common/linux-xlnx"

say "u-boot"
make -C "$U" ARCH=arm CROSS_COMPILE=$CROSS_ARM- zynq_pynqz1_config
make -C "$U" ARCH=arm CROSS_COMPILE=$CROSS_ARM- \
     KCFLAGS="-fcommon -fgnu89-inline" -j"$JOBS" u-boot
cp "$U/u-boot" "$OUT/u-boot.elf"

say "kernel"
export PATH="$U/tools:$PATH"          # mkimage, for uImage
make -C "$K" ARCH=arm CROSS_COMPILE=$CROSS_ARM- HOSTCFLAGS="-fcommon" xilinx_zynq_defconfig
# CONFIG_STRICT_DEVMEM must stay off: fesvr-zynq maps 0x43C00000 through
# /dev/mem rather than the vestigial generic-uio node in the devicetree.
grep -q "^# CONFIG_STRICT_DEVMEM is not set" "$K/.config" \
  || { echo "FATAL: STRICT_DEVMEM is enabled; fesvr cannot map /dev/mem"; exit 1; }
make -C "$K" ARCH=arm CROSS_COMPILE=$CROSS_ARM- \
     HOSTCFLAGS="-fcommon" KCFLAGS="-fcommon -fgnu89-inline" \
     UIMAGE_LOADADDR=0x8000 -j"$JOBS" uImage
cp "$K/arch/arm/boot/uImage" "$OUT/uImage"

say "devicetree"
# -i: the .dts includes zynq-7000.dtsi, which lives in the kernel tree.
dtc -I dts -O dtb -i "$K/arch/arm/boot/dts" \
    -o "$OUT/devicetree.dtb" "$XV6_REPO/board/soft_config/pynqz1_devicetree.dts"
ls -la "$OUT"/u-boot.elf "$OUT"/uImage "$OUT"/devicetree.dtb
