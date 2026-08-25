# xv6-riscv on the Rocket Chip core

Porting [xv6-riscv](https://github.com/mit-pdos/xv6-riscv) to the Rocket core in
the PL, driven by `fesvr-zynq` from ARM Linux on the PS.

**Status:** the kernel boots, mounts the filesystem off the testchipip block
device, runs `init`, execs `sh`, and prints a prompt. Console **output** is
fully working. Console **input** is not usable yet — see "Known problem" below.

```
~ # cd /root && ./fesvr-zynq +blkdev=fs.img ./xv6-kernel

xv6 kernel is booting

blkdev: 4000 sectors (1 MB), max request 16 sectors
init: starting sh
$
```

The block driver is verified working: tracing every request shows the log
recovery pass, `init` being read off disk, and `sh` being exec'd, all
completing normally.

## Known problem: console input

Keystrokes reach the kernel (instrumenting `uartintr()` shows the right
characters arriving) but far too slowly to use — on the order of one character
per tens of seconds, so a command line never completes.

The structure of the problem is understood; the fix is not finished:

- HTIF allows only **one outstanding read** at a time, so at most one character
  can be collected per poll.
- Polling happens in `uartintr()`, which this port drives from the timer tick,
  so **console input rate == tick rate**.
- Each poll costs an HTIF round trip, and on this board HTIF rides the TSI
  serial link, where every `tohost`/`fromhost` access is a slow target-memory
  transaction issued by fesvr on the ARM side.

Raising the tick rate is not a fix on its own: at ~25Hz the round trips stop
fitting inside a tick and the kernel livelocks in interrupt context.

The likely right answer is to stop driving console polling from the timer and
instead poll from the scheduler's idle path, so input is limited by link
latency rather than by the tick, without stealing time from running processes.

## Measured hardware facts (not what the docs claim)

- **CLINT `mtime` runs at 250kHz**, i.e. the 25MHz Rocket clock / 100 — not the
  1MHz that rocket-chip's `DTSTimebase` advertises, and nothing like QEMU's
  10MHz. Timer intervals have to be derived from 250kHz.

Apply with:

```bash
git clone https://github.com/mit-pdos/xv6-riscv
cd xv6-riscv
git checkout $(cat ../xv6/BASE_COMMIT)
git apply ../xv6/0001-xv6-rocket-port.patch
cp ../xv6/htif.c kernel/htif.c
cp ../xv6/blkdev.c kernel/blkdev.c
make kernel/kernel        # needs riscv64-unknown-elf-gcc
```

`BASE_COMMIT` pins the upstream revision the patch was generated against
(`35b0884`, "test for nlink overflow").

---

## What the port changes, and why

xv6 targets QEMU's `virt` machine. Four of its assumptions do not hold on a
2018-era Rocket core. The memory map, happily, needs no changes at all:

| | Rocket (ZynqFPGAConfig) | xv6 / QEMU virt | |
|---|---|---|---|
| CLINT | `0x02000000` | `0x02000000` | match |
| PLIC | `0x0C000000` | `0x0C000000` | match |
| RAM base | `0x80000000` | `0x80000000` | match |
| Entry privilege | M-mode | M-mode | match |
| Console | HTIF | NS16550 @ `0x10000000` | **ported** |
| Timer | CLINT only | Sstc (`stimecmp`) | **ported** |
| PTE A/D | software | hardware (`menvcfg.ADUE`) | **ported** |
| Disk | testchipip @ `0x10015000` | virtio @ `0x10001000` | **ported** |

The bootrom hands off with `csrw mepc, DRAM_BASE; mret` and never touches
`MPP`, so the core lands in M-mode at `0x80000000` — exactly what `entry.S`
expects.

### 1. Console → HTIF (`kernel/htif.c`)

This Rocket configuration has no UART at all; the console is the HTIF channel
`fesvr-zynq` already polls. `htif.c` is a drop-in replacement for `uart.c`,
keeping the same four entry points (`uartinit`, `uartintr`, `uartwrite`,
`uartputc_sync`) so nothing else has to change.

The protocol detail that matters (from `fesvr/htif.cc` and `fesvr/device.cc`):

- `tohost = (device << 56) | (cmd << 48) | payload`
- The **host** signals it consumed a command by writing **0 back to `tohost`**.
- The host writes `fromhost` only when it reads as 0, so the target must zero
  it after consuming a reply.
- `bcd_t::handle_write()` **never calls `respond()`** — a console write
  produces *no* `fromhost` reply. Waiting on `fromhost` after a `putc` hangs
  forever. Only reads get a reply, as `0x100 | ch`.

HTIF has no interrupt line, so console input is polled from the timer tick
instead of arriving via the PLIC.

### 2. Timer → CLINT (`start.c`, `kernelvec.S`, `trap.c`)

Upstream xv6 (since commit `92e60dd`) uses the **Sstc** extension: supervisor
timer interrupts via `stimecmp`, enabled through `menvcfg`. This core has
*neither* CSR — `grep -ri "menvcfg\|stimecmp\|sstc" rocket-chip/src/main/scala`
returns nothing — and writing a CSR that does not exist traps as an illegal
instruction.

The fix restores upstream's own pre-`92e60dd` scheme: take the timer interrupt
in machine mode at `timervec`, rearm the CLINT there, and reflect it down as a
supervisor **software** interrupt, which `devintr()` treats as a tick. `SIE_SSIE`
has to be re-enabled for this (upstream dropped it in `29ba4ec`).

`MENVCFG_ADUE` (upstream `0e8b331`) is likewise removed.

### 3. Page-table A/D bits (`vm.c`, `riscv.h`)

This is the subtle one, and it is what made the kernel hang the moment paging
came on. From rocket-chip `src/main/scala/rocket/PTW.scala`:

```scala
def leaf(dummy: Int = 0) = v && (r || (x && !w)) && a
def sw(dummy: Int = 0)   = leaf() && w && d
```

A PTE is not even a *leaf* unless `A` is set, and a store additionally requires
`D`. This PTW does **no hardware A/D update** — it just faults. That is exactly
the case upstream's `MENVCFG_ADUE` commit describes: "the hardware generates a
page fault trap for the kernel implementation to update the bits in software
(**which xv6 does not do**)."

So every PTE is created with `A` and `D` already set, in `mappages()` — xv6's
single choke point for leaf PTEs. Setting `D` on a read-only page is harmless,
since `D` is only consulted after `W` has passed. Non-leaf *table* PTEs are
left alone: `table()` does not test `A`.

### 4. Disk → testchipip block device (`kernel/blkdev.c`)

Nothing answers on the TileLink bus at `0x10001000`, so probing virtio faults.
The disk here is testchipip's block device, a DMA engine with a register file
at `0x10015000` whose backing store is the file passed to `fesvr-zynq` as
`+blkdev=<file>`. `blkdev.c` replaces `virtio_disk.c`.

Two things to know:

- **Reading the `allocate` register at `+0x11` is what issues the request.**
  Address/offset/length/direction must all be written first.
- The DMA master hangs off the coherent system bus (`sbus.fromPort` in
  `HasPeripheryBlockDevice`), so no cache maintenance is needed — a fence to
  order the MMIO writes is enough.

The MMIO page also has to be added to `kvmmake()`; without it the first
register read takes a load page fault (`scause=0xd`, `stval=0x10015018`).

### 5. Timer rearm must be absolute (`kernelvec.S`)

Upstream's `timervec` does `mtimecmp += interval` — it rearms relative to the
*old* compare value, which assumes the handler always finishes well inside one
interval. That does not hold here: `blkdev_rw()` spins with interrupts disabled
for the length of a disk transfer, so `mtime` can run past
`mtimecmp + interval`. The next interrupt is then already due the moment the
handler returns, and the core livelocks in the timer handler.

This showed up as the shell accepting a command and then hanging forever, with
the tick counter accelerating from 2.5/sec to ~33/sec the instant a command
triggered disk I/O. `timervec` now rearms from the current `mtime`, so a late
tick is dropped rather than compounding.

---

## Host-side prerequisites

Running xv6 needs the ARM/Rocket memory split configured correctly, or a
program on Rocket will overwrite the running ARM kernel. See the top-level
README: `rocketchip_wrapper.v` maps Rocket `0x8xxxxxxx` to Zynq `0x1xxxxxxx`,
so Linux must be confined to the low 256MB and u-boot must be told to place the
ramdisk there too.
