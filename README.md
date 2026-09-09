# MIT xv6 on a UCB Rocket Chip, on a PYNQ-Z1

Running **MIT's [xv6-riscv](https://github.com/mit-pdos/xv6-riscv)** on a
**UC Berkeley [Rocket Chip](https://github.com/chipsalliance/rocket-chip)**
RV64GC core synthesized into the FPGA fabric of a Digilent/TUL **PYNQ-Z1**
(Zynq-7020, `xc7z020clg400-1`) — built with **Vivado 2024.1** and a modern
GCC 13 host toolchain.

The upstream starting point, [`ucb-bar/fpga-zynq`](https://github.com/ucb-bar/fpga-zynq),
is deprecated, targets Vivado 2016.2, and has no PYNQ-Z1 board port. This repo
holds the board port, the fixes needed to make an 8-year-old build system produce
a working boot chain on current tools, and the xv6 port itself.

**Status:** working end to end. Linux boots to an interactive shell; the Rocket
Chip core in the PL runs RISC-V programs driven from that shell; and **xv6 runs
on Rocket with an interactive shell of its own**, off its own disk. The full
upstream **`usertests` suite passes on the hardware** — all 64 tests, including
the slow ones (see [`xv6/`](xv6/)).

```
BootROM → FSBL → u-boot 2014.07 → Linux 3.15 → busybox → ~ #
                                                          └─ fesvr-zynq → Rocket (RV64) → xv6 → $
```

![xv6 booting on the Rocket core and listing its filesystem](docs/img/xv6-shell.png)

*On real hardware: `fesvr-zynq` launched from the ARM shell, xv6 booting on the
Rocket core in the PL, and `ls` listing its own filesystem.*

```
~ # cd /root && ./fesvr-zynq ./hello.riscv
Hello from Rocket Chip on PYNQ-Z1!
sum(1..100) = 5050 (expected 5050)
64-bit shift OK (1<<40)
PASS
```

---

## How it fits together

The Zynq-7020 is two processors in one package, and this project uses both.

```
┌─ PS: hard silicon ───────────────┐   ┌─ PL: FPGA fabric ──────────┐
│  ARM Cortex-A9 dual-core         │   │  Rocket Chip RV64GC        │
│  Linux 3.15 + busybox            │   │  ZynqFPGAConfig, 25 MHz    │
│                                  │   │                            │
│  fesvr-zynq  ──── TSI / HTIF ────┼───┼──►  xv6                    │
└──────────────────────────────────┘   └────────────────────────────┘
         AXI HP0 ──► shared DDR ◄── Rocket 0x8xxxxxxx = Zynq 0x1xxxxxxx
```

**xv6 does not own the board.** It runs on the soft RISC-V core in the fabric,
while the hard ARM core beside it runs Linux and acts as xv6's front-end server.
`fesvr-zynq` loads the RV64 ELF into Rocket's DRAM over the TSI serial link,
releases the core from reset, and then services everything xv6 cannot do for
itself:

- **Console.** This Rocket configuration has *no UART at all*. xv6's output is
  HTIF messages that fesvr turns into writes on the ARM console, and its input is
  characters fesvr hands back the same way. That is why the port replaces
  `uart.c` with [`xv6/htif.c`](xv6/htif.c).
- **Disk.** `+blkdev=fs.img` is an ordinary file on the ARM side. testchipip's
  DMA engine in the fabric pulls blocks across the same link, so
  [`xv6/blkdev.c`](xv6/blkdev.c) replaces `virtio_disk.c`.

So the ARM Linux bring-up is not a detour: without a working shell on the PS
there is nothing to launch `fesvr-zynq`, and therefore no way to run anything on
Rocket at all. The four bugs below were all in service of getting that far.

One consequence to keep in mind: **the two processors share the same physical
DRAM.** `rocketchip_wrapper.v` maps Rocket's `0x8xxxxxxx` onto Zynq DDR
`0x1xxxxxxx`, so Linux has to be confined to the low 256MB or a program running
on Rocket writes straight over the running ARM kernel — see
[the memory split](#the-armrocket-memory-split).

> Note on the name: upstream `fpga-zynq`'s own goal was booting *Linux on Rocket*.
> That is **not** what this does. Linux here runs on the ARM core; the RISC-V core
> runs xv6.

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

Two more of the same character turned up on the RISC-V side — a block-device DMA
that silently drops the tail of any transfer to a destination that is not
64-byte aligned, and a whole class of exceptions that rocket-chip refuses to
delegate, which upstream xv6 then mistakes for timer interrupts and retries
forever. Both are written up in [`xv6/README.md`](xv6/README.md).

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
board/uEnv.txt                 u-boot ramdisk placement (see memory split below)
xv6/                           xv6-riscv port: HTIF console, CLINT timer, PTE A/D,
                               testchipip disk, M-mode trap reflection
riscv-test/                    minimal RV64 HTIF test program for the Rocket core
tools/pl-probe.c               dumps the Zynq adapter regs to check the PS->PL link
tools/send-kernel.py           push a rebuilt RV64 kernel to the board over serial
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
| Rocket clock | 25 MHz | **40 MHz** (see `clocking.vh`) |

---

## What it costs on the chip

Post-place utilisation of the 40 MHz build on the xc7z020-clg400:

| Resource | Used | Available | % |
|---|---|---|---|
| Slice LUTs | 30,761 | 53,200 | 57.8 |
| — as logic | 29,730 | 53,200 | 55.9 |
| — as distributed RAM | 1,030 | 17,400 | 5.9 |
| Slice registers | 16,497 | 106,400 | 15.5 |
| **Slices occupied** | **9,723** | **13,300** | **73.1** |
| Block RAM tiles | 24 | 140 | 17.1 |
| DSP48E1 | 15 | 220 | 6.8 |
| MMCM | 1 | 4 | 25.0 |

**The real constraint is slice occupancy at 73%, not the 58% LUT figure.** The
gap between them is congestion: many slices are claimed with only some of their
LUTs used. "42% of LUTs free" is not 42% of headroom. It also shows up in the
critical path, where **58% of the delay is routing**:

```
Slack (MET):      3.395ns          period = 25.000ns
Source:           top/target/adapter/addr_reg[4]/C
Destination:      top/target/bh/TLBroadcastTracker_3/o_data/ram_mask_reg_.../RAMA_D1/I
Data Path Delay:  21.222ns   (logic 8.838ns 41.6% / route 12.384ns 58.4%)
Logic Levels:     36  (CARRY4=19  LUT2=2 LUT3=3 LUT4=4 LUT5=1 LUT6=7)
```

19 CARRY4s is a ~76-bit carry chain — the Zynq adapter's address decode feeding
the broadcast hub's mask RAM. 21.222 ns puts the ceiling at about **47 MHz**
without touching RTL; going higher means pipelining that path.

### The same design under Vivado 2025.2.1

Built again with everything held constant except the tool version — same
`Top.ZynqFPGAConfig.v`, same constraints, same board files, same
`Vivado Implementation Defaults`. It closes, and the bitstream boots xv6 on
hardware, but with noticeably less margin:

| | 2024.1 | 2025.2.1 |
|---|---|---|
| WNS (40 MHz) | +3.395 ns | **+1.542 ns** |
| Failing endpoints | 0 | 0 |
| Slices occupied | 9723 (73.11%) | 9633 (72.43%) |
| Slice LUTs | 30761 | 30662 |
| BRAM / DSP / MMCM | 24 / 15 / 1 | 24 / 15 / 1 |

Resource usage is unchanged, marginally better. The 1.853 ns goes entirely into
delay: **route +1.227 ns, logic +0.531 ns, clock skew +0.095 ns**.

It is not one path getting unlucky. The critical endpoint moves — 2024.1 ends in
`bh/TLBroadcastTracker_3`, 2025.2.1 in `pbus/sync_xing/Queue` — but the source is
the same `adapter/addr_reg[*]`, the shape is the same (36 logic levels,
`CARRY4=19` both), and the whole critical cluster shifts together: the ten worst
paths span 3.395–3.614 ns under 2024.1 and 1.542–1.822 ns under 2025.2.1. Same
netlist, worse physical implementation of it. `report_design_analysis
-congestion` finds no window above level 5 in either, so this is distance, not
congestion.

`usertests` settles what that costs at runtime: **nothing**. The full 64-test
suite passes on the 2025.2.1 bitstream in **1482 s** — the same figure as the
2024.1 build, to the second. Which on reflection is the only possible answer:
WNS says whether a clock period is met, not how many periods the work takes, and
with the same 40 MHz clock driving byte-identical RTL the cycle count cannot
move. Less slack means closer to failing, not slower.

Practically: 40 MHz still has room, but the ceiling estimated above drops from
about 46 MHz to about 43 MHz, and the 50 MHz setting that closed at +0.249 ns on
2024.1 should be assumed not to close here.

**`phys_opt_design` does not help.** It is disabled in
`Vivado Implementation Defaults`, and turning it on — plus
`post_route_phys_opt_design` — changes nothing at all: identical WNS to three
decimals on all ten worst paths. It reports `TNS=0.000` and exits, because it
optimises paths with *negative* slack and this design has none. Physical
optimisation is not a way to buy margin on a design that already passes; the
lever for that is still pipelining the adapter-to-broadcast-hub path.

### Why a bigger cache is not the next move

BRAM sits at 17%, which invites the idea of enlarging the caches. It would not
help. The config is `nSets=64, nWays=4, blockBytes=64` — 16KB each for L1I and
L1D — and the workload that dominates runtime is page zeroing and page copying:
**pure streaming with no reuse.** Each 4KB page is touched once and never read
again, so every line misses exactly once no matter how large the cache is. The
number of fills and writebacks does not change.

What does look promising is that `WithNBigCores` explicitly overrides
`DCacheParams`'s default of 1 with **`nMSHRs = 0`**, making the D-cache
*blocking*: every miss stalls the pipeline until DRAM answers, with no overlap.
That is the measured ~125 cycles per 64-byte line. Streaming writes to
consecutive lines are exactly the pattern that should overlap.

Two caveats before anyone tries it. MSHRs cost LUTs and FFs — the SDQ, the RPQ
and their state machines — not BRAM, and at 73% slice occupancy the design may
not fit, or may fit and lose the 40 MHz. And the upside is bounded: `memset` is
roughly half of the per-page cost, so even perfect overlap caps out near 2×.
Changing it also means regenerating `Top.ZynqFPGAConfig.v` through the Chisel
build, so it is not a one-line experiment.

---

## Building

Prerequisites: Vivado 2024.1 or 2025.2.1, `arm-none-eabi-gcc` (FSBL), `arm-linux-gnueabihf-gcc`
(u-boot/kernel), `riscv64-unknown-elf-gcc` (xv6), `openjdk-8` (the Chisel build),
the PYNQ-Z1 board files, and a `fpga-zynq` checkout with its submodules.

[**vivado-docker**](https://github.com/eecsmap/vivado-docker) is a container
with all of that already in it, pinned to an OS Vivado supports. It is what this
was last built and verified on, and it saves rediscovering which of these are
`Recommends` that a `--no-install-recommends` install quietly leaves out.

### The board file is load-bearing, and its absence is silent

Of that list, the PYNQ-Z1 board files are the one that will not tell you when
they are missing. `src/tcl/pynqz1_bd.tcl` sets exactly **one** `CONFIG.PCW_*`
property by hand — `PCW_USE_S_AXI_HP0`. Everything else about the PS7 comes from
a single line:

```tcl
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {apply_board_preset "1"} [get_bd_cells processing_system7_0]
```

That preset is where the 50 MHz reference clock, UART0 on MIO 14/15, the 512 MB
DDR part and every PLL divider come from. Without the board file,
`set_property board_part` fails, the automation applies nothing, and the PS7
falls back to defaults that carry **Zedboard's 33.333 MHz** reference clock.

Synthesis, placement, routing and `write_bitstream` all still succeed. The
design comes up on the board. The only symptom is an unreadable console — which
is [bug #2/#3](#2--3-garbled-console--the-same-bug-in-two-codebases) all over
again, reintroduced at the point where it is hardest to recognise as a
configuration problem rather than a software one.

Get them from [Digilent/vivado-boards](https://github.com/Digilent/vivado-boards)
and point Vivado at the directory containing `pynq-z1/`:

```tcl
set_param board.repoPaths [list /path/to/vivado-boards/new/board_files]
```

Then check that it took, before trusting anything downstream:

```bash
cd pynqz1 && vivado -mode batch -source check_ps7.tcl
```

`board/check_ps7.tcl` reads the properties back off the block design and fails
loudly if the crystal is not 50 MHz. It is the only place in the flow where this
mistake is cheap to catch.

**There are scripts for all of this.** [`scripts/`](scripts/) rebuilds the whole
chain — RTL, FSBL, u-boot, kernel, rootfs — and has been run end to end on
Vivado 2025.2.1 / Ubuntu 24.04, booting to an xv6 shell on hardware. Start from
[`scripts/README.md`](scripts/README.md); what follows is the reasoning behind
what those scripts do.

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

### The FSBL on Vitis 2025.x

The invocations above are the classic flow. `xsct`, which generated that BSP,
does not exist in Vitis 2025.x, and Vitis's own `create_platform_component`
fails here with nothing to go on but `Application error processing RPC`. The
path that works is `empyro`, and `zynq_fsbl` is accepted as a template even
though it is not in the advertised list:

```bash
empyro repo -st $VITIS/data/embeddedsw
empyro create_bsp -t zynq_fsbl -p ps7_cortexa9_0 -s <sdt>/system-top.dts -w bsp
empyro build_bsp  -d bsp
empyro create_app -t zynq_fsbl -d bsp -n fsbl -w app
empyro build_app  -w app
```

`fsbl/main.c` and `fsbl/stack_init_override.c` go in through
`UserConfig.cmake`'s `USER_COMPILE_SOURCES` and `USER_COMPILE_DEFINITIONS`.
[`scripts/build-fsbl.sh`](scripts/build-fsbl.sh) does the whole thing.

One consequence worth recording: **[bug #1](#1-fsbl-crashed-before-printing-a-single-byte)
does not exist on this path.** The 2025.x standalone BSP enters through its own
`_start` rather than newlib's `_mainCRTStartup`, so `_stack_init` is never
called and `--gc-sections` drops it. The 2024.1 FSBL binary contains both
symbols; the 2025.2.1 one contains neither, and boots. The override is kept
because it costs nothing and the classic flow still needs it.

### The kernel needs three flags this section used to omit

```
HOSTCFLAGS="-fcommon"                 # scripts/dtc, duplicate yylloc
KCFLAGS="-fcommon -fgnu89-inline"     # target code
dtc -i <kernel>/arch/arm/boot/dts     # the .dts includes zynq-7000.dtsi
```

`-fgnu89-inline` is the one that costs an afternoon. gnu89 and C99 give
`extern inline` opposite meanings; 3.15 assumes gnu89, where it emits nothing,
and a current GCC emits a definition per translation unit. It presents as
`arch/arm/mm` symbols — `nop_dma_map_area` — multiply defined in `fs/ext4`
object files.

And on the fesvr link line, `-lfesvr` must come *after* the sources. `Makefrag`
puts it first, which was fine when ld scanned libraries regardless of position;
it now resolves left to right, and `context_t::switch_to()` comes back
undefined.

The BSP needs `XPAR_CPU_CORTEXA9_0_CPU_CLK_FREQ_HZ` defined (`108333333`, the
650 MHz CPU 6x clock ÷ 6) in `xparameters_ps.h`; regenerating the BSP wipes it.

### Regenerating the Rocket RTL

`board/src/verilog/Top.ZynqFPGAConfig.v` is not tracked; it comes out of
rocket-chip's Chisel build. That build is from 2018 and does not come up on a
current machine without two fixes.

**One resolver is gone.** `firrtl/project/plugins.sbt` names
`scalasbt.artifactoryonline.com`, which has been decommissioned — DNS does not
even resolve it, so `scalastyle-sbt-plugin`, `org.apache.ant#ant` and
`org.ow2.asm#asm` all come back UNRESOLVED. The artifacts themselves are fine
and still on Maven Central; only the resolver is dead. Drop that line:

```bash
git -C rocket-chip/firrtl apply /path/to/patches/rocket-chip-firrtl/0001-*.patch
```

Nothing else needs touching. sbt 1.1.1, sbt 0.13.15 (which `common/` uses — a
different major version from rocket-chip's), all six plugins, Scala 2.11.12,
json4s 3.5.3 and scalamacros paradise 2.1.0 all still resolve from Maven Central.

**The build steps are ordered, and the order is load-bearing.** Running
`sbt pack` first fails with `unresolved dependency:
edu.berkeley.cs#firrtl_2.11;1.2-SNAPSHOT`, which looks like another dead
resolver and is not: `chisel3/build.sbt` inspects the unmanaged classpath and
only adds a *managed* dependency on firrtl when `firrtl.jar` is absent from it.
So firrtl has to be built and dropped in `rocket-chip/lib/` first. `Makefrag`
encodes this; if you drive sbt by hand, do the same:

```bash
make -C rocket-chip/firrtl SBT="$SBT" root_dir=$PWD/rocket-chip/firrtl build-scala
cp rocket-chip/firrtl/utils/bin/firrtl.jar rocket-chip/lib/
(cd rocket-chip && $SBT pack)
(cd pynqz1 && make rocket)          # Chisel elaboration -> .fir -> firrtl -> .v
```

**Use JDK 8.** `common/Makefrag` passes `-XX:MaxPermSize` to every sbt
invocation. On 8 that is a warning (`ignoring option MaxPermSize`); on 9 and
later it is `Unrecognized VM option` and the JVM refuses to start. Scala 2.11.12
wants 8 anyway.

Verified end to end: with these, the regenerated `Top.ZynqFPGAConfig.v` is
byte-identical to the one that produced the shipped bitstream.

### SD card

FAT32, five files at the root:

```
boot.bin  devicetree.dtb  uImage  uramdisk.image.gz  uEnv.txt
```

Boot mode jumper set to SD.

Keep the partition small — 1GB is plenty. Some USB card readers cannot address
past 4GB, and a FAT32 filesystem spanning a whole 32GB card will happily allocate
above that line: the files then read back as the right size with garbage
contents, silently, only when written through that reader. A 1GB partition keeps
everything inside the region such a reader can verify.

---

## Talking to the Rocket core

`fesvr-zynq` runs on the ARM side, loads an RV64 ELF into the Rocket core's
DRAM over the TSI serial link, releases the core from reset, and then services
its HTIF syscalls (so the RISC-V program's `write()` lands on the ARM console).

Two things to know that are easy to get wrong:

- **`fesvr-zynq` does not use UIO.** The devicetree carries a
  `htif@43c00000` node with `compatible = "generic-uio"`, inherited from the
  upstream boards, and on a modern kernel it fails to probe:

  ```
  uio_pdrv_genirq 43c00000.htif: failed to get IRQ
  uio_pdrv_genirq: probe of 43c00000.htif failed with error -22
  ```

  This is a **red herring** — `zynq_driver_t` opens `/dev/mem` and mmaps
  `0x43C00000` directly. The node is vestigial. (The probe failure is itself a
  kernel bug of this vintage: `uio_pdrv_genirq` supports IRQ-less operation but
  only when `platform_get_irq()` returns `-ENXIO`, while for DT devices it
  returns `of_irq_get()`'s `-EINVAL`, so the IRQ-less path is unreachable.)

- **`CONFIG_STRICT_DEVMEM` must be off**, or the `/dev/mem` mapping is refused.

### Checking the link before blaming software

[`tools/pl-probe.c`](tools/pl-probe.c) dumps the adapter's status registers.
On a healthy build, before fesvr runs:

```
  +0x0c  TSI_IN_FIFO_COUNT          = 0x00000010   <- SerialFIFODepth = 16
  +0x10  SYSTEM_RESET               = 0x00000001   <- core held in reset
  +0x34  BLKDEV_RESP_FIFO_COUNT     = 0x00000010   <- BlockDeviceFIFODepth = 16
```

Those depths coming back as exactly the Chisel config values is what
distinguishes a live design from a floating bus. All-`0xffffffff` means the PL
is unconfigured, unclocked, or in reset.

### Test program

[`riscv-test/`](riscv-test/) is a self-contained RV64 bare-metal program — no
riscv-tests or pk needed. It talks HTIF directly: syscalls by writing a request
buffer address to `tohost` and waiting on `fromhost`, exit by writing
`(code << 1) | 1`. It links at `0x80000000` (`ExtMem` base for this config).

```bash
cd riscv-test && make          # -> hello.riscv, needs riscv64-unknown-elf-gcc
# copy hello.riscv to /root in the rootfs, then on the board:
#   cd /root && ./fesvr-zynq ./hello.riscv
```

## The ARM/Rocket memory split

**This matters before running anything non-trivial on Rocket.**
`rocketchip_wrapper.v` wires the Rocket memory port to AXI HP0 like this:

```verilog
assign S_AXI_araddr = {4'd1, mem_araddr[27:0]};
assign S_AXI_awaddr = {4'd1, mem_awaddr[27:0]};
```

So Rocket's `0x80000000–0x8FFFFFFF` **is** Zynq DDR `0x10000000–0x1FFFFFFF` —
the upper half of the PYNQ-Z1's 512MB. It is not separate memory. Three things
have to agree about that:

| Setting | Value | Why |
|---|---|---|
| devicetree `memory` | `reg = <0x0 0x10000000>` | Linux owns only the low 256MB. Give it all 512MB and any Rocket program scribbles over the running ARM kernel — xv6's `kinit()` alone memsets 128MB, which produced slab-allocator Oopses on the ARM side. zedboard does the same (512MB board, `0x10000000` here). |
| `uEnv.txt` `bootm_size` | `0x08000000` | u-boot still sees 512MB and would otherwise place the ramdisk at the top, where Linux cannot reach it. |
| `bootargs` | `cma=16M` | The kernel is built with `CONFIG_CMA_SIZE_MBYTES=128` — fine at 512MB, but half the RAM at 256MB, and the reservation lands on top of the ramdisk. |

The last two interact: at `bootm_size=0x10000000` the ramdisk lands at
`~0x0FBD3000` and collides with the `cma=16M` reservation at `0x0F000000`. The
kernel then dies **before printing anything at all**, which looks alarming but
is just an overlap. `0x08000000` keeps them apart.

## Running it

Power on with the boot mode jumper on SD; the whole chain comes up by itself.

**Do not send anything to the serial port during u-boot's autoboot countdown** —
any keystroke stops it at `zynq-uboot>`. If that happens, type `boot`.

The board's FT2232H exposes two interfaces: `if00` is JTAG, `if01` is the PS
UART0 console, at 115200 8N1. A third `ttyUSB` appears only if some other FTDI
device is also attached — which is where the "console is `/dev/ttyUSB2`" advice
in earlier versions of this file came from, and why it does not travel. The
number is not stable in any case: it moves whenever the board is power cycled
and the bridge re-enumerates. Resolve it by name instead:

```sh
screen "$(readlink -f /dev/serial/by-id/usb-Digilent*Adept*-if01-port0)" 115200
```

To capture a boot rather than watch one, use
[`tools/serial-listen.py`](tools/serial-listen.py) and start it *before*
powering on — it is read-only, and it rescans so it survives the re-enumeration
that a plain `screen` does not.

(`Ctrl-A K` to quit screen.) Then, on the board:

```sh
# a bare-metal RV64 program on Rocket
cd /root && ./fesvr-zynq ./hello.riscv

# xv6, with a disk
cp /root/fs.img.orig /root/fs.img       # reset the disk to pristine
cd /root && ./fesvr-zynq +blkdev=fs.img ./xv6-kernel
```

Ctrl-C leaves fesvr and returns to the ARM shell. xv6 reaches its `$` prompt in
about 4 seconds.

Resetting the disk between runs matters: xv6 writes to the image, and a crashed
run leaves the log dirty, which shows up as `ireclaim: orphaned inode` or
`panic: freeing free block` on the next boot.

### The rootfs is in RAM

`/root` lives in the initramfs, so **anything written there is gone on reboot**
and the board reverts to whatever is in `uramdisk.image.gz` on the SD card.

While iterating that is a feature — a reboot is a guaranteed clean slate, and it
is the easiest way to restore a damaged `fs.img`. To make a change permanent,
rebuild the ramdisk and rewrite the card.

### Iterating without touching the SD card

Because the rootfs is in RAM, a rebuilt kernel can go straight down the console
rather than via the SD card:

```sh
make kernel/kernel                                    # in your xv6 tree
/path/to/tools/send-kernel.py kernel/kernel
```

About 13 seconds to push, 4 to boot. See
[`tools/send-kernel.py`](tools/send-kernel.py) for the several ways this can go
wrong quietly (tty line-buffer limits, flow control, stripping).

The destination is an argument, and the transport does not care what it is
carrying, so **anything in the RAM rootfs** can be replaced the same way — a
library, `fs.img`, `fesvr-zynq`. That is usually faster than rebuilding the
ramdisk and moving the card, and it is the only option when the card is not to
hand:

```sh
tools/send-kernel.py libstdc++.so.6 /lib/libstdc++.so.6
tools/send-kernel.py fs.img         /root/fs.img.orig
```

What each change actually costs:

| changed | how to get it onto the board |
|---|---|
| xv6 kernel, `fs.img`, anything under the RAM rootfs | `send-kernel.py`, seconds, board stays up |
| bitstream only | JTAG — see [`docs/JTAG-DEBUGGING.md`](docs/JTAG-DEBUGGING.md) |
| `uImage`, `devicetree.dtb`, `uramdisk.image.gz` | SD card, or teach u-boot to TFTP them (`Net: Gem.e000b000` is up) |
| `boot.bin` — FSBL or u-boot itself | SD card |

Only the last row genuinely requires the card. It is worth knowing which row you
are in before pulling the board apart.

---

## Next step

xv6 passes `usertests` in full, so the port itself is in good shape. Ranked by
what the measurements actually point at:

- **A non-blocking D-cache** (`nMSHRs > 0`) — the best-identified lever, with
  the caveats in [What it costs on the chip](#what-it-costs-on-the-chip).
  Note this is *not* "more cache": see why in that section.
- **More clock.** 40 MHz ships with 3.4 ns to spare; 50 MHz closes at 0.25 ns
  but is unverified. Past ~47 MHz means pipelining the critical path from the
  Zynq adapter's address decode into the TileLink broadcast hub.
- **Boot Linux on Rocket** — what upstream `fpga-zynq` was originally for, and
  what this repo's old name wrongly implied. Needs a bigger Rocket config than
  `ZynqFPGAConfig` and a RISC-V Linux build, but the board port, bitstream flow
  and fesvr plumbing underneath already work. Fitting a bigger config is the
  open question at 73% slice occupancy.
