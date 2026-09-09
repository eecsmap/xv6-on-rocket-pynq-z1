# Shared configuration for the build scripts. Source it, do not run it.
#
#   FPGA_ZYNQ  a fpga-zynq checkout with this repo's board/ wired in as pynqz1/
#   XV6_REPO   this repository
#   OUT        where finished boot artifacts land
#
# Override any of them in the environment; the defaults assume the layout in
# scripts/README.md.
set -euo pipefail

XV6_REPO="${XV6_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FPGA_ZYNQ="${FPGA_ZYNQ:-$(cd "$XV6_REPO/.." && pwd)/fpga-zynq}"
OUT="${OUT:-$(cd "$XV6_REPO/.." && pwd)/sw-build}"

ROCKET="$FPGA_ZYNQ/rocket-chip"
BOARD="$FPGA_ZYNQ/pynqz1"
COMMON_BUILD="$FPGA_ZYNQ/common/build"

# Ubuntu 24.04 cross toolchains. The vivado-docker image carries these; the
# names Makefrag uses (arm-xilinx-linux-gnueabi-) have not existed for years.
CROSS_ARM="${CROSS_ARM:-arm-linux-gnueabihf}"
CROSS_BM="${CROSS_BM:-arm-none-eabi}"
CROSS_RV="${CROSS_RV:-riscv64-unknown-elf}"
SYSROOT_ARM="${SYSROOT_ARM:-/usr/$CROSS_ARM}"

JOBS="${JOBS:-$(nproc)}"

# Both sbt generations this build needs are launched through rocket-chip's
# vendored launcher. -XX:MaxPermSize is inherited from common/Makefrag: JDK 8
# warns and ignores it, JDK 9+ refuses to start, which is why openjdk-8 is not
# optional here.
SBT_CACHE="${SBT_CACHE:-$OUT/.sbt}"
SBT="${SBT:-java -Xmx2G -Xss8M -XX:MaxPermSize=256M \
  -Dsbt.boot.directory=$SBT_CACHE/boot \
  -Dsbt.ivy.home=$SBT_CACHE/ivy \
  -Dsbt.global.base=$SBT_CACHE/global \
  -jar $ROCKET/sbt-launch.jar}"

mkdir -p "$OUT"
say() { printf '\n===== %s =====\n' "$*"; }
