# Building everything from source

These scripts rebuild the entire boot chain — bitstream RTL, FSBL, u-boot,
kernel, rootfs — on a current machine. They exist because the upstream sources
are between eight and twelve years old and none of them build unmodified with a
2020s toolchain, in ways whose symptoms rarely point at the cause.

Verified end to end on Vivado 2025.2.1 / Ubuntu 24.04, booting to an xv6 shell
on real hardware.

## Layout

Everything is driven by three variables, all overridable:

| | default | |
|---|---|---|
| `XV6_REPO` | this repository | |
| `FPGA_ZYNQ` | `../fpga-zynq` | a [fpga-zynq](https://github.com/ucb-bar/fpga-zynq) checkout with this repo's `board/` copied in as `pynqz1/` |
| `OUT` | `../sw-build` | where finished artifacts land |

`pynqz1/` has to be a real directory, not a symlink: `Makefrag` computes
`base_dir` with `$(abspath ..)`, which resolves physically, so a symlink lands
it in this repository instead of in fpga-zynq.

## Order

```bash
# once: submodules. riscv-tools is only needed for fesvr; the rest of the
# bitstream path does not want it, and it is large.
git -C $FPGA_ZYNQ submodule update --init rocket-chip testchipip \
    common/u-boot-xlnx common/linux-xlnx
git -C $FPGA_ZYNQ/rocket-chip submodule update --init chisel3 firrtl hardfloat riscv-tools
git -C $FPGA_ZYNQ/rocket-chip/riscv-tools submodule update --init riscv-fesvr

scripts/apply-patches.sh      # every upstream tree this repo patches
scripts/build-rtl.sh          # Chisel -> Top.ZynqFPGAConfig.v
# then the Vivado project and bitstream (see the main README), and:
(cd $FPGA_ZYNQ/pynqz1 && vivado -mode batch -source $XV6_REPO/scripts/export-xsa.tcl)
scripts/build-fsbl.sh
scripts/build-linux.sh        # u-boot, uImage, devicetree.dtb
scripts/build-userland.sh     # fesvr-zynq, hello.riscv, pl-probe, xv6, busybox
scripts/build-rootfs.sh       # initramfs, with a verification pass that matters
scripts/build-boot.sh         # boot.bin and the five SD-card files
```

## What each script is really working around

- **`build-rtl.sh`** — firrtl has to be built and placed in `rocket-chip/lib`
  *before* `sbt pack`, because chisel3 decides whether to add a managed firrtl
  dependency by inspecting the unmanaged classpath. Get the order wrong and it
  reports an unresolved dependency, which looks like a dead repository.
- **`build-fsbl.sh`** — `xsct` is gone in Vitis 2025.x and
  `create_platform_component` fails with an unexplained RPC error. `empyro` is
  the working path.
- **`build-linux.sh`** — `-fcommon` and `-fgnu89-inline`, on both the host and
  target compilers. See the comments in the script; the `-fgnu89-inline` symptom
  in particular (ARM MM symbols duplicated into `fs/ext4`) does not resemble its
  cause.
- **`build-userland.sh`** — `-lfesvr` must follow the sources on the link line.
- **`build-rootfs.sh`** — checks the architecture of every ELF before packing.
  Two bugs here produced images that built cleanly and failed only on the board.

## Toolchain

The [vivado-docker](https://github.com/eecsmap/vivado-docker) image carries all
of it. If you are assembling your own: `gcc-arm-linux-gnueabihf`,
`g++-arm-linux-gnueabihf`, `gcc-arm-none-eabi` **plus
`libnewlib-arm-none-eabi`** (a *recommends*, so `--no-install-recommends` drops
it and the compiler links nothing), `gcc-riscv64-unknown-elf`, `openjdk-8`
(9+ refuses `-XX:MaxPermSize`, which `Makefrag` passes), `device-tree-compiler`,
`u-boot-tools`, `cmake`, `ninja`, `bison`, `flex`, `bc`, `cpio`.
