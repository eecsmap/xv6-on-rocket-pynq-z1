# JTAG debugging a silent Zynq boot

Notes from tracking down the FSBL crash (bug #1 in the README). The technique
generalises to any "board boots to nothing" situation on Zynq-7000.

## Setup

`xsct` ships with Vivado — a full Vitis install is not required. With a
Vivado-only install it lives at `Vivado/2024.1/xsct-trim/bin/xsct`.

```bash
# hw_server must be running (it binds :3121)
~/tools/Xilinx/Vivado/2024.1/bin/hw_server &
```

`xsct` in script mode does **not** echo command results the way the interactive
REPL does — wrap everything in `puts` or you get a silent, apparently-successful
script:

```tcl
connect
puts [targets]
targets -set -filter {name =~ "ARM*#0"}
puts "state: [state]  pc: [rrd pc]"
```

## The core loop: reset, download, breakpoint

This reproduces a crash in a couple of seconds, with no SD card and no power
cycling — the single biggest speedup in this whole exercise.

```tcl
connect
targets -set -filter {name =~ "ARM*#0"}
if {[state] == "Running"} { stop }
after 100
rst -processor
after 300
dow /path/to/executable.elf
bpremove -all
bpadd -addr 0x1b5c          ;# address of main, from `nm`
con
after 500
puts "reached?: [state] PC=[rrd pc]"
```

Gotchas that cost real time:

- **`rst -processor` silently does nothing if the core is still `Running`.**
  It must genuinely transition to `Stopped` first. A halted-then-reset core
  stops at the reset vector with `Stopped: (Vector Catch)` and `pc = 0`; if you
  see anything else, the reset didn't take.
- **`dow` sets PC to the ELF entry point**, so a second `dow` of a different ELF
  needs no manual `rwr pc`.
- Breakpoint addresses are **build-specific**. Re-read them from `nm` after every
  rebuild — a stale address silently never hits and looks like a crash.
- `con` on an already-running target errors out; guard with `[state]`.
- Boot completes (or dies) in well under a second, so you cannot "attach and
  catch it in the act". Always reset → download → breakpoint.

## Reading fault state

```tcl
puts "DFAR/IFAR: [rrd cp15 c6]"
puts "DFSR/IFSR: [rrd cp15 c5]"
puts "SCTLR:     [rrd cp15 c1]"   ;# bit 0 = MMU enabled
puts "TTBR0:     [rrd cp15 c2]"
puts "MIDR:      [rrd cp15 c0]"   ;# silicon revision, for errata questions
```

**Decode `DFSR` properly before trusting `DFAR`.** This is the trap that cost
the most time here:

| `FS[4:0]` | meaning | is `DFAR` valid? |
|---|---|---|
| `0b00110` (6) | asynchronous external abort | **no — UNPREDICTABLE** |
| `0b01000` (8) | synchronous external abort | yes |
| `0b10110` (22) | asynchronous parity error | no |
| `0b00101`/`0b00111` | translation fault | yes |
| `0b01101`/`0b01111` | permission fault | yes |

`DFSR = 0x1c06` is **asynchronous**, so its `DFAR = 0x00000000` meant nothing —
it was not a null-pointer dereference, though it looks exactly like one. Bit 11
(`WnR`) does stay valid and correctly said "write".

Trick: temporarily marking the faulting region **Strongly-Ordered** in the
translation table turns an imprecise asynchronous abort into a *synchronous*
one (`DFSR = 0x1808`), at which point `DFAR` becomes trustworthy and names the
address directly. That is what finally produced `DFAR = 0xFFFDFFF4` and pointed
straight at the stack.

## Single-stepping the C runtime

`stpi` steps one instruction. To find where execution leaves the expected path:

```tcl
bpadd -addr 0x8518          ;# memset, from `nm`
con
after 300
puts "r0=[rrd r0] r1=[rrd r1] r2=[rrd r2]"   ;# dest, fill, len
bpremove -all
for {set i 0} {$i < 15} {incr i} {
    puts "step $i: PC=[rrd pc] SP=[rrd sp]"
    stpi
}
```

Watching `SP` here is what exposed the bug: the stack pointer was fine at
`_mainCRTStartup` (`0xFFFF6000`) and wrong a few instructions later.

## Mapping a running PC back to source

u-boot relocates itself to high DRAM, so its runtime PCs match nothing in the
ELF. Recover the offset from the global data struct — after `board_init_f`
returns, `r9` holds `gd`:

```tcl
puts "gd: [rrd r9]"
puts "relocaddr (gd+0x2c): [mrd <gd+0x2c>]"
puts "reloc_off (gd+0x40): [mrd <gd+0x40>]"
```

Then `link_addr = runtime_pc - reloc_off`, and look that up with `nm`. This
turned an opaque `0x1f94bce0` into `do_bootm_states` → `memmove_wd`.

`dis pc 15` disassembles at the current PC — useful for telling "running real
code" from "executing garbage". It requires a stopped target.

## Other notes

- **OCM aliasing.** `OCM_CFG` (SLCR `0xF8000910`) selects, per 64 KB bank,
  whether it appears at the low alias (`0x00000000`) or the high one
  (`0xFFFF0000`). The bits *move* banks, they don't duplicate them — writing
  `0xF` moved bank 0 away from address 0 and broke FSBL's own code, and left
  the core unable to reset until the register was restored over JTAG.
- **`ps7_init` from xsct.** `source ps7_init.tcl` then call `ps7_init` to bring
  up clocks/DDR/MIO without booting anything. Required before DDR is readable
  via `mrd`. It *rewrites* DDR state, so it destroys crash evidence — but OCM
  (at `0x0`) and all CPU/CP15 registers are readable without it.
- **Programming a bitstream over JTAG:**
  ```tcl
  targets -set -filter {name =~ "xc7z*"}
  fpga -file system_wrapper.bit
  ```
- **A wedged core** (PC wandered into unmapped PL space) can stop responding to
  `stop` entirely — "Cannot halt processor core, timeout". Only a physical power
  cycle recovers it.
- **USB renumbering.** The FTDI serial port moves (`ttyUSB2` → `ttyUSB4` …) after
  power cycles. Watch a range of ports, not a fixed one, and start the listener
  *before* powering on — boot output appears within ~2 s and is easily missed.
