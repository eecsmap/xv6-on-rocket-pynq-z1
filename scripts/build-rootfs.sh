#!/usr/bin/env bash
# Assemble the initramfs and wrap it for u-boot.
#
# The verification pass at the end is not belt-and-braces. Two separate bugs
# here produced an image that built cleanly and only failed on the board:
#
#   * `make install` without ARCH/CROSS_COMPILE exported rebuilds busybox for
#     the host, silently replacing the ARM binary. The board reports
#     "Failed to execute /sbin/init (error -8)" and panics.
#   * globbing for a library ("find / -name 'libstdc++.so.6*'") matches
#     /usr/share/gdb/auto-load/...-gdb.py -- a Python script -- which installs
#     as /lib/libstdc++.so.6 and yields "invalid ELF header" the first time
#     anything dynamically linked runs.
#
# Neither is visible in the build log. Both are caught by checking every ELF.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

RD="${RD:-$OUT/rootfs}"
X="${XV6_SRC:-$OUT/xv6-riscv}"
B="${BUSYBOX_SRC:-$OUT/busybox}"

say "busybox install"
rm -rf "$RD"; mkdir -p "$RD"
# Exported here too, or `install` rebuilds natively. See above.
make -C "$B" ARCH=arm CROSS_COMPILE=$CROSS_ARM- CONFIG_PREFIX="$RD" install >/dev/null

say "skeleton and config"
cd "$RD"; mkdir -p dev etc mnt proc root sys tmp usr/local/lib lib
cp -r "$XV6_REPO/rootfs/etc/." etc/
chmod 755 etc/init.d/rcS

say "runtime libraries"
# From the cross sysroot only. Never from /usr/lib/gcc-cross (libstdc++.so
# there is a linker script) and never from a loose find.
for l in ld-linux-armhf.so.3 libc.so.6 libm.so.6 libstdc++.so.6 libgcc_s.so.1; do
  cp -L "$SYSROOT_ARM/lib/$l" lib/ || { echo "FATAL: $SYSROOT_ARM/lib/$l missing"; exit 1; }
done
cp "$COMMON_BUILD/libfesvr.so" usr/local/lib/

say "/root"
cp "$COMMON_BUILD/fesvr-zynq"          root/
cp "$XV6_REPO/riscv-test/hello.riscv"  root/
cp "$OUT/pl-probe"                     root/
cp "$X/kernel/kernel"                  root/xv6-kernel
cp "$X/fs.img"                         root/fs.img
cp "$X/fs.img"                         root/fs.img.orig
chmod 755 root/fesvr-zynq root/hello.riscv root/pl-probe root/xv6-kernel

say "verify every ELF"
bad=0
while IFS= read -r f; do
  [ "$(head -c4 "$f" | tail -c3)" = ELF ] || continue
  m=$(readelf -h "$f" 2>/dev/null | awk -F: '/Machine/{print $2}' | xargs)
  case "$f" in ./root/xv6-kernel|./root/hello.riscv) want=RISC-V ;; *) want=ARM ;; esac
  if [ "$m" != "$want" ]; then echo "  BAD  $f -> '$m' (want $want)"; bad=1
  else echo "  ok   $f -> $m"; fi
done < <(find . -type f)

say "verify the dynamic closure"
for n in $($CROSS_ARM-readelf -d root/fesvr-zynq | sed -n 's/.*NEEDED.*\[\(.*\)\].*/\1/p'); do
  p=""; for d in lib usr/local/lib usr/lib; do [ -f "$d/$n" ] && p="$d/$n" && break; done
  [ -n "$p" ] && echo "  ok   $n -> $p" || { echo "  MISSING $n"; bad=1; }
done
[ $bad -eq 0 ] || { echo "FATAL: rootfs would not run on the board"; exit 1; }

say "pack"
find . | cpio -H newc -o 2>/dev/null | gzip -9 > "$OUT/uramdisk.cpio.gz"
mkimage -A arm -O linux -T ramdisk -d "$OUT/uramdisk.cpio.gz" "$OUT/uramdisk.image.gz" >/dev/null
rm -f "$OUT/uramdisk.cpio.gz"
ls -la "$OUT/uramdisk.image.gz"
