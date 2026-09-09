#!/usr/bin/env bash
# Regenerate Top.ZynqFPGAConfig.v from Chisel.
#
# The step order is not cosmetic. Running `sbt pack` first fails with
# "unresolved dependency: edu.berkeley.cs#firrtl_2.11;1.2-SNAPSHOT", which reads
# like a dead repository and is not: chisel3/build.sbt inspects the unmanaged
# classpath and only adds a *managed* firrtl dependency when firrtl.jar is
# absent from it. Build firrtl first, drop it in rocket-chip/lib, and the
# managed dependency never appears.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

say "firrtl.jar"
make -C "$ROCKET/firrtl" SBT="$SBT" root_dir="$ROCKET/firrtl" build-scala
mkdir -p "$ROCKET/lib"
cp "$ROCKET/firrtl/utils/bin/firrtl.jar" "$ROCKET/lib/firrtl.jar"

say "sbt pack (rocket-chip, sbt 1.1.1)"
( cd "$ROCKET" && $SBT pack )

say "make rocket (common/, sbt 0.13.15 -> .fir -> firrtl -> .v)"
make -C "$BOARD" rocket SBT="$SBT" JOBS="$JOBS"
ls -la "$BOARD/src/verilog/Top.ZynqFPGAConfig.v"
