#!/usr/bin/env bash
# Package FSBL + bitstream + u-boot into boot.bin, and lay out the SD card.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

BIT="${BIT:-$BOARD/pynqz1_rocketchip_ZynqFPGAConfig/pynqz1_rocketchip_ZynqFPGAConfig.runs/impl_1/rocketchip_wrapper.bit}"
for f in "$OUT/fsbl.elf" "$BIT" "$OUT/u-boot.elf"; do
  [ -f "$f" ] || { echo "FATAL: missing $f"; exit 1; }
done

say "bootgen"
# Zynq-7000 uses `the_ROM_image:`, not `image:`.
cat > "$OUT/output.bif" <<BIF
the_ROM_image:
{
	[bootloader]$OUT/fsbl.elf
	$BIT
	$OUT/u-boot.elf
}
BIF
( cd "$OUT" && bootgen -image output.bif -w -o boot.bin )

say "SD card contents"
SD="${SD:-$OUT/sdcard}"; mkdir -p "$SD"
cp "$OUT/boot.bin" "$OUT/uImage" "$OUT/devicetree.dtb" "$OUT/uramdisk.image.gz" "$SD/"
cp "$XV6_REPO/board/uEnv.txt" "$SD/"
ls -la "$SD"
echo
echo "Copy these five files to the root of a FAT32 partition; see the README"
echo "for why that partition should stay small."
