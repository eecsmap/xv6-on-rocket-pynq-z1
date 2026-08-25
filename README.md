# PYNQ-Z1 Rocket Chip + Linux bring-up

Booting Linux on a Digilent/TUL **PYNQ-Z1** (Zynq-7020, `xc7z020clg400-1`) with a
Rocket Chip bitstream in the PL, built on **Vivado 2024.1** and a modern
GCC 13 host toolchain.

The upstream starting point, [`ucb-bar/fpga-zynq`](https://github.com/ucb-bar/fpga-zynq),
targets Vivado 2016.2 and has no PYNQ-Z1 board port. This repo holds the board
port plus the fixes needed to make an 8-year-old build system produce a working
boot chain on current tools.

**Status:** boots end to end to an interactive shell.

```
BootROM → FSBL → u-boot 2014.07 → Linux 3.15 → busybox → ~ #
```

---

## The four bugs

Every one of these presented as "no output" or "garbage on the console", and
none of them were in code we wrote. They're recorded here in detail because the
symptoms are badly misleading and the root causes are all latent bugs in the
standard Xilinx/newlib/upstream combination rather than anything specific to
this design.

### 1. FSBL crashed before printing a single byte

**Symptom:** completely silent boot. JTAG showed the CPU spinning in
`Xil_DataAbortHandler` at a fixed address, on every power cycle, with a
Data Fault Status Register value that decodes to *asynchronous external abort*
and `DFAR = 0x00000000` — which reads exactly like a null-pointer write and
sent the investigation in the wrong direction for a long time. (For
*asynchronous* aborts the ARM spec says `DFAR` is UNPREDICTABLE; the zero was
meaningless.)

**What it actually was:** single-stepping the C runtime startup showed the
fault hit on the **first stack push inside `memset()`** while zeroing BSS.
Xilinx's `boot.S` correctly programs every CPU-mode stack pointer from the
linker script, all inside the one 64 KB OCM bank that `OCM_CFG` maps to the
high address alias (`0xFFFF0000–0xFFFFFFFF`, `OCM_CFG = 0x18` by default).
Then newlib's generic **weak `_stack_init()`**, called later from
`_mainCRTStartup`, recomputes all of those stack pointers with hardcoded
byte-offset arithmetic (`sp - 4096 - 4096 - 4096 - 8192 - 32768`, masked) that
knows nothing about `OCM_CFG`. Starting from `0xFFFF6000` that lands on
`0xFFFE0000` — an OCM bank *not* mapped at the high alias. The first write
there is a real external bus error.

Xilinx's FSBL template never provides a strong `_stack_init` to override
newlib's, so the bug is latent in the standard BSP + modern toolchain pairing.

**Fix:** [`fsbl/stack_init_override.c`](fsbl/stack_init_override.c) — a no-op
strong `_stack_init()` so `boot.S`'s correct setup survives.

Ruled out along the way (all innocent): the custom block design and HP0 port,
the PS7 register configuration, the MMU translation table, the L2 cache
controller (PL310), the SCU, and Cortex-A9 errata 742230/743622 (the silicon
is r3p0, `MIDR = 0x413fc090`, which doesn't need them).

### 2 & 3. Garbled console — the same bug in two codebases

PYNQ-Z1's PS reference oscillator is **50 MHz**
(`PCW_CRYSTAL_PERIPHERAL_FREQMHZ = 50` in the board preset). Zedboard/ZC702 use
33.333 MHz, and both u-boot and the kernel hardcode that value as a default.

`ps7_init()` programs the PLLs correctly from the real hardware, so the clocks
*are* right — but both codebases recompute every derived rate, including the
UART baud divisor, **in software** from their compile-time constant. Wrong
constant → wrong divisor → unreadable console, while everything else keeps
running fine.

- **u-boot:** `CONFIG_ZYNQ_PS_CLK_FREQ` defaults to `33333333` in
  `arch/arm/cpu/armv7/zynq/clk.c` and was never overridden.
  Fixed in [`board/soft_config/zynq_pynqz1.h`](board/soft_config/zynq_pynqz1.h).
- **kernel:** `zynq-7000.dtsi` hardcodes `ps-clk-frequency = <33333333>`.
  Overridden in [`board/soft_config/pynqz1_devicetree.dts`](board/soft_config/pynqz1_devicetree.dts).

### 4. Kernel panic, then a shell respawn loop

Two small userspace issues, back to back:

- **`Unable to mount root fs on unknown-block(1,0)`** — the initramfs unpacked
  fine, but our busybox rootfs has `/sbin/init` and `/linuxrc`, no `/init`.
  The kernel looks for `/init` specifically, doesn't find it, silently falls
  back to mounting `root=` as a block device, and panics.
  Fixed with `rdinit=/sbin/init` in the devicetree `bootargs`.
- **`can't open /dev/ttyPS0: No such file or directory`**, repeating forever —
  `CONFIG_DEVTMPFS_MOUNT` only auto-mounts `/dev` when the kernel mounts a
  *real* root filesystem; it deliberately skips initramfs. `/dev` stayed empty,
  so inittab's getty died in a respawn loop.
  Fixed with `mount -t devtmpfs devtmpfs /dev` in
  [`rootfs/etc/init.d/rcS`](rootfs/etc/init.d/rcS).

---

## Layout

```
board/
  Makefile                     BOARD=pynqz1, xc7z020clg400-1, ZynqFPGAConfig
  ps7_init.tcl                 PS7 init sequence (also usable from xsct for JTAG debug)
  src/tcl/pynqz1_bd.tcl        block design; board preset instead of a Zedboard PS7 dump
  src/tcl/*.tcl                project + bitstream generation
  src/constrs/base.xdc         125 MHz clock on pin H16
  src/verilog/clocking.vh      MMCM for 125 MHz in / 25 MHz Rocket clock
  src/verilog/rocketchip_wrapper.v
  soft_config/zynq_pynqz1.h    u-boot board config (UART0, 512 MB, 50 MHz PS clk)
  soft_config/pynqz1_devicetree.dts
fsbl/
  stack_init_override.c        bug #1 fix
  main.c                       FSBL main with an explicit UART0 CR write
rootfs/etc/                    inittab + rcS (bug #4 fix)
patches/
  u-boot-xlnx/                 modern-toolchain fixes + board config
  linux-xlnx/                  modern-toolchain fixes
docs/JTAG-DEBUGGING.md         the methodology that found bug #1
```

Vivado build output, generated Verilog, busybox binaries and the packaged boot
images are **not** tracked — see `.gitignore`.

---

## Board differences vs Zedboard

| | Zedboard | PYNQ-Z1 |
|---|---|---|
| Part | `xc7z020clg484-1` | `xc7z020clg400-1` |
| Console UART | UART1 | **UART0** (MIO 14/15) |
| DDR | 256 MB | **512 MB** |
| PS ref clock | 33.333 MHz | **50 MHz** |
| PL clock in | 100 MHz | **125 MHz** (pin H16) |

---

## Building

Prerequisites: Vivado 2024.1, `arm-none-eabi-gcc` (FSBL), `arm-linux-gnueabihf-gcc`
(u-boot/kernel), the PYNQ-Z1 board files, and a `fpga-zynq` checkout with its
submodules.

Because the upstream sources predate GCC 5, both builds need extra flags. The
patches under `patches/` cover the source-level fixes; these are the build
invocations:

```bash
# u-boot
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- zynq_pynqz1_config
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- \
     KCFLAGS="-fcommon -fgnu89-inline" u-boot

# FSBL BSP (the generated top-level Makefile blanks COMPILER_FLAGS, so pass
# EXTRA_COMPILER_FLAGS; its `archive:` rule is also missing $(ARCHIVER))
make -C zynq_fsbl_bsp COMPILER=arm-none-eabi-gcc ARCHIVER=arm-none-eabi-ar \
     EXTRA_COMPILER_FLAGS="-c -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard \
       -Og -g3 -Wall -Wno-attribute-alias -fgnu89-inline"
arm-none-eabi-ar -r ps7_cortexa9_0/lib/libxil.a ps7_cortexa9_0/lib/*.o

# FSBL app  (do NOT pass -nostartfiles: it drops _init/_fini)
make CC=arm-none-eabi-gcc \
     CFLAGS="-Wall -Og -g3 -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard \
             -DFSBL_DEBUG_INFO"

# boot.bin  (Zynq-7000 uses `the_ROM_image:`, not `image:`)
bootgen -image output.bif -w -o boot.bin
```

`FSBL_DEBUG_INFO` matters: without it every `fsbl_printf` is compiled out and
FSBL boots silently even when healthy.

The BSP needs `XPAR_CPU_CORTEXA9_0_CPU_CLK_FREQ_HZ` defined (`108333333`, the
650 MHz CPU 6x clock ÷ 6) in `xparameters_ps.h`; regenerating the BSP wipes it.

### SD card

FAT32, four files at the root:

```
boot.bin  devicetree.dtb  uImage  uramdisk.image.gz
```

Boot mode jumper set to SD.

---

## Next step

`fesvr-zynq` and `libfesvr.so` are already in the rootfs at `/root/`. Talking to
the Rocket Chip core over the HTIF/testchipip serial link is the next milestone,
and the original motivation for this work — eventually booting xv6 on the RISC-V
core while Linux runs on the ARM PS.
