# xv6-riscv on the Rocket Chip core

Porting [xv6-riscv](https://github.com/mit-pdos/xv6-riscv) to the Rocket core in
the PL, driven by `fesvr-zynq` from ARM Linux on the PS.

**Status:** the kernel boots and completes its entire init sequence, then stops
at the first filesystem access — there is no block-device driver yet.

```
~ # cd /root && ./fesvr-zynq ./xv6-kernel

xv6 kernel is booting

kinit → kvminit → kvminithart → procinit → trapinit → trapinithart
      → plicinit → plicinithart → binit → iinit → fileinit → userinit
                                                                  ^
                              userinit() calls namei("/"), which needs a disk
```

Apply with:

```bash
git clone https://github.com/mit-pdos/xv6-riscv
cd xv6-riscv
git checkout $(cat ../xv6/BASE_COMMIT)
git apply ../xv6/0001-xv6-rocket-port.patch
cp ../xv6/htif.c kernel/htif.c
make kernel/kernel        # needs riscv64-unknown-elf-gcc
```

`BASE_COMMIT` pins the upstream revision the patch was generated against
(`35b0884`, "test for nlink overflow").

---

## What the port changes, and why

xv6 targets QEMU's `virt` machine. Three of its assumptions do not hold on a
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
| Disk | testchipip | virtio @ `0x10001000` | **not done** |

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

### 4. Disk — not done

`virtio_disk_init()` is commented out in `main.c`: nothing answers on the
TileLink bus at `0x10001000`, so probing it faults. The real block device is
testchipip's, reached through `fesvr-zynq`'s `+blkdev=<file>` option, and needs
a driver written against the FIFO registers in
[`../tools/pl-probe.c`](../tools/pl-probe.c)'s register map
(`BLKDEV_REQ_FIFO_*`, `BLKDEV_DATA_FIFO_*`, `BLKDEV_RESP_FIFO_*`).

Until that exists, `userinit()`'s `namei("/")` blocks in `bread()` forever.

---

## Host-side prerequisites

Running xv6 needs the ARM/Rocket memory split configured correctly, or a
program on Rocket will overwrite the running ARM kernel. See the top-level
README: `rocketchip_wrapper.v` maps Rocket `0x8xxxxxxx` to Zynq `0x1xxxxxxx`,
so Linux must be confined to the low 256MB and u-boot must be told to place the
ramdisk there too.
