# xv6-riscv on the Rocket Chip core

Porting [xv6-riscv](https://github.com/mit-pdos/xv6-riscv) to the Rocket core in
the PL, driven by `fesvr-zynq` from ARM Linux on the PS.

**Status:** working, and **the full upstream `usertests` suite passes on the
hardware** — all 64 tests including the slow ones, in 25 minutes. The kernel
boots, mounts the filesystem off the testchipip block device, runs `init`,
execs `sh`, and gives an interactive shell.

```
~ # cd /root && ./fesvr-zynq +blkdev=fs.img ./xv6-kernel

xv6 kernel is booting

blkdev: 4000 sectors (1 MB), max request 16 sectors
init: starting sh
$ ls
.              1 1 1024
..             1 1 1024
README         2 2 2441
cat            2 3 36760
echo           2 4 35608
...
console        3 23 0
$ echo hello rocket
hello rocket
$ cat README
xv6 is a re-implementation of Dennis Ritchie's and Ken Thompson's Unix
Version 6 (v6). ...
```

Boot to the prompt takes about **0.67 seconds**.

```
$ usertests
usertests starting
test copyin: OK
test copyout: OK
...
test sbrkbasic: OK
test sbrkmuch: OK
...
usertests slow tests starting
test bigdir: OK
test manywrites: OK
test badwrite: OK
test execout: OK
test diskfull: balloc: out of blocks
OK
test outofinodes: ialloc: no inodes
OK
ALL TESTS PASSED
```

`balloc: out of blocks` and `ialloc: no inodes` are `diskfull` and `outofinodes`
doing their job, not errors. So are the ~113 `usertrap(): unexpected scause`
reports: that is `kernmem` forking children which deliberately dereference
`KERNBASE` to prove user mode cannot reach it.

What actually costs time is measured in
[page allocation is DRAM-bound](#page-allocation-is-dram-bound) below — it is
not the console. The console moves 2950 B/s and the whole suite only emits
14KB, i.e. under 5 seconds of the total.

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

## The two bugs worth reading about

Both of these presented as a total, silent freeze with no output whatsoever, and
neither is in code specific to this port. They cost far more time than the
porting work did.

### The DMA silently drops the tail of a misaligned transfer

**Symptom:** xv6 booted, ran `init`, exec'd `sh`, printed a prompt, accepted a
command — and then the whole core froze, forever, with no output.

The child process was executing an **illegal instruction at user PC `0xbfa`**,
the first instruction of `sbrk()`. That page of `sh`'s text was **zeros**.

It was not a VM bug: `uvmcopy` reported copying all 5 pages with none skipped,
`vmfault` never ran, and dumping the page showed it was correct at every 256-byte
sample. Only the *tails* of two 1024-byte regions were zero, starting at `0x3d0`
and `0xbe0` — different lengths, which is what made it look like random file
corruption.

Reading blocks straight out of the buffer cache and diffing them against
`fs.img` on the host showed 5 of 29 blocks losing 8, 16, 16, 32 and 32 trailing
bytes. Re-reading a block gave byte-identical results, so it was not a race.

The cause is alignment. testchipip moves each 64-byte chunk with a single Put:

```scala
val put_acq = edge.Put(
    fromSource = 0.U,
    toAddress  = req.addr,
    lgSize     = log2Ceil(cacheBlockBytes).U,   // = 6, i.e. 64 bytes
    data       = io.bdev.resp.bits.data)._2
```

TileLink requires a `2^6`-byte Put to be **64-byte aligned**. The RTL just
advances `req.addr` by `cacheBlockBytes` per burst and never checks. Upstream's
`struct buf` is **1112 bytes**, not a multiple of 64, so every buffer in `bcache`
sits at a different 64-byte phase — and only the misaligned ones came back short.

Reading one known block into every 8-byte offset of a 64-byte-aligned buffer,
with the destination pre-filled with `0xee`, maps it out exactly:

| destination offset | result |
|---|---|
| 0 | entire block correct |
| 8 | last 8 bytes still `0xee` |
| 16–56 | last 16+ bytes still `0xee` |

The missing bytes keep the poison value, so they are **never written at all** —
the data is not corrupted in flight, it simply never arrives.

**Fix:** one attribute in `kernel/buf.h`.

```c
uchar data[BSIZE] __attribute__((aligned(64)));
```

That aligns the field *and* rounds `sizeof(struct buf)` up to 1152, a multiple of
64, so every element of the `bcache` array stays aligned too. Any DMA target on
this SoC needs the same treatment.

### Non-delegable exceptions land in `timervec`

Upstream's `timervec` is installed as `mtvec` and assumes every machine-mode trap
is the timer. That assumption does not survive contact with this core.

rocket-chip only allows a *subset* of exceptions to be delegated
(`rocket/CSR.scala`):

```scala
val delegable_exceptions = UInt(Seq(
  Causes.misaligned_fetch,
  Causes.fetch_page_fault,
  Causes.breakpoint,
  Causes.load_page_fault,
  Causes.store_page_fault,
  Causes.user_ecall).map(1 << _).sum)
```

and the write is masked with it:

```scala
when (decoded_addr(CSRs.medeleg)) { reg_medeleg := wdata & delegable_exceptions }
```

So `start.c`'s `w_medeleg(0xffff)` is silently stored as **`0xB109`**. Illegal
instruction (2), misaligned load/store (4/6) and the access faults (1/5/7) can
*never* reach supervisor mode — they always trap to M-mode, i.e. into `timervec`.

Treating an exception as a timer tick means rearming the CLINT and `mret`ing
straight back to the faulting instruction, which faults again immediately. The
core livelocks, retiring zero instructions, producing no output at all. Every
fault in one of those classes became an unexplained hang.

**Fix:** `timervec` now dispatches on `mcause`, and reflects anything that is not
the machine timer down to supervisor mode the way hardware delegation would —
copying `mcause`/`mepc`/`mtval` into `scause`/`sepc`/`stval`, setting
`sstatus.SPP` from `mstatus.MPP`, moving `SIE` into `SPIE`, and `mret`ing to
`stvec` with `MPP=S`. `satp` and `sscratch` are left alone, so entry through
`uservec` or `kernelvec` works unchanged.

Faults now report themselves:

```
usertrap(): unexpected scause 0x2 pid=3
            sepc=0xbfa stval=0x0
```

and the shell survives and returns to its prompt instead of taking the machine
down. Fixing this first is what made the alignment bug findable.

---

## What else the port changes, and why

xv6 targets QEMU's `virt` machine. The memory map, happily, needs no changes:

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

The bootrom hands off with `csrw mepc, DRAM_BASE; mret` and never touches `MPP`,
so the core lands in M-mode at `0x80000000` — exactly what `entry.S` expects.

### Console → HTIF (`kernel/htif.c`)

This Rocket configuration has no UART at all; the console is the HTIF channel
`fesvr-zynq` already polls. `htif.c` is a drop-in replacement for `uart.c`,
keeping the same four entry points (`uartinit`, `uartintr`, `uartwrite`,
`uartputc_sync`) so nothing else has to change.

The protocol details that matter (from `fesvr/htif.cc` and `fesvr/device.cc`):

- `tohost = (device << 56) | (cmd << 48) | payload`
- The **host** signals it consumed a command by writing **0 back to `tohost`**.
- The host writes `fromhost` only when it reads as 0, so the target must zero it
  after consuming a reply.
- `bcd_t::handle_write()` **never calls `respond()`** — a console write produces
  *no* `fromhost` reply. Waiting on `fromhost` after a `putc` hangs forever. Only
  reads get a reply, as `0x100 | ch`.

HTIF has no interrupt line, so input must be polled. Polling only from the timer
tick caps input at one character per tick, which is unusable. The port polls from
the **scheduler's idle path** instead (`proc.c`, replacing upstream's `wfi`), so
input is bounded by how fast fesvr answers rather than by the tick rate, and
costs nothing while a read is already outstanding.

### Timer → CLINT (`start.c`, `kernelvec.S`, `trap.c`)

Upstream xv6 (since `92e60dd`) uses **Sstc**: supervisor timer interrupts via
`stimecmp`, enabled through `menvcfg`. This core has *neither* CSR —
`grep -ri "menvcfg\|stimecmp\|sstc" rocket-chip/src/main/scala` returns nothing —
and writing a CSR that does not exist traps as an illegal instruction.

The fix restores upstream's own pre-`92e60dd` scheme: take the timer interrupt in
machine mode at `timervec`, rearm the CLINT there, and reflect it down as a
supervisor **software** interrupt, which `devintr()` treats as a tick. `SIE_SSIE`
has to be re-enabled for this (upstream dropped it in `29ba4ec`).
`MENVCFG_ADUE` (upstream `0e8b331`) is likewise removed.

The CLINT also has to be mapped into the kernel page table again. Upstream
removed that mapping when it moved to Sstc, since with `stimecmp` the supervisor
never touches the CLINT; here it does.

### Timer rearm must be absolute (`kernelvec.S`)

Upstream's `timervec` does `mtimecmp += interval` — rearming relative to the
*old* compare value, which assumes the handler always finishes well inside one
interval. That does not hold here: `blkdev_rw()` spins with interrupts disabled
for the length of a disk transfer, so `mtime` can run past `mtimecmp + interval`.
The next interrupt is then already due the moment the handler returns, and the
core livelocks in the timer handler.

This showed up as the shell accepting a command and then hanging forever, with
the tick counter accelerating from 2.5/sec to ~33/sec the instant a command
triggered disk I/O. `timervec` now rearms from the current `mtime`, so a late
tick is dropped rather than compounding.

### Page-table A/D bits (`vm.c`, `riscv.h`)

This is the subtle one, and it is what made the kernel hang the moment paging
came on. From rocket-chip `rocket/PTW.scala`:

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
since `D` is only consulted after `W` has passed. Non-leaf *table* PTEs are left
alone: `table()` does not test `A`.

### Disk → testchipip block device (`kernel/blkdev.c`)

Nothing answers on the TileLink bus at `0x10001000`, so probing virtio faults.
The disk here is testchipip's block device, a DMA engine with a register file at
`0x10015000` whose backing store is the file passed to `fesvr-zynq` as
`+blkdev=<file>`. `blkdev.c` replaces `virtio_disk.c`.

Three things to know:

- **Reading the `allocate` register at `+0x11` is what issues the request.**
  Address/offset/length/direction must all be written first.
- **The destination must be 64-byte aligned** — see the alignment bug above.
- The DMA master hangs off the coherent system bus (`sbus.fromPort` in
  `HasPeripheryBlockDevice`), so no cache maintenance is needed; a fence to order
  the MMIO writes is enough.

The MMIO page also has to be added to `kvmmake()`; without it the first register
read takes a load page fault (`scause=0xd`, `stval=0x10015018`).

### Page allocation is DRAM-bound (`kalloc.c`)

Anything that touches a lot of pages dominates this port's runtime, and nothing
else comes close — not the console, not the disk. Two separate causes, found by
measuring rather than guessing.

**First, `memset()` and `memmove()` were the bottleneck, not the memory.**
Upstream's are byte-at-a-time loops. Measured on this 25MHz in-order core they
run at **5.03 cycles per byte** — which is exactly a `sb`/increment/compare/
branch loop, not a memory limit: it only moves 0.19 bytes per cycle, orders of
magnitude below what the AXI HP port to the PS's DDR can carry. Rewriting both
to move 8 bytes per iteration takes it to **1.86 cycles/byte**.

The alignment handling in those loops is not optional: a misaligned load or
store is one of the exceptions rocket-chip refuses to delegate, so getting it
wrong traps to M-mode instead of faulting cleanly.

**Second, pages were being written three times.**

One alloc/free round trip wrote a 4KB page three times over:

| | |
|---|---|
| `kalloc()` | `memset(r, 5, PGSIZE)` — poison, to catch uninitialised reads |
| `uvmalloc()` etc. | `memset(mem, 0, PGSIZE)` — **required**, or freed data leaks between processes |
| `kfree()` | `memset(pa, 1, PGSIZE)` — poison, to catch dangling references |

12KB of DRAM traffic per 4KB page. That is invisible on QEMU and dominant here.

It shows up most starkly in `usertests`, whose `countfree()` walks the entire
free list one `sbrk(PGSIZE)` at a time — and `drivetests()` calls it **twice**
per run. At `PHYSTOP` = 128MB that is ~32000 pages, so ~768MB of `memset`:
**162 seconds** by the numbers above. Measured, every `usertests` invocation
took ~165s *regardless of which test was selected*:

| | upstream | one memset less | + word-at-a-time | + 40 MHz |
|---|---|---|---|---|
| `usertests copyin` | 164.5s | 56.3s | 35.5s | **23.0s** |
| `usertests forkforkfork` | 171.8s | 62.1s | 40.0s | **26.0s** |
| `usertests kernmem` | 166.7s | 57.1s | 35.5s | **23.0s** |
| full suite | 4317s | 2762s | — | **1482s** |
| boot to shell | 1.16s | 0.99s | 0.97s | **0.67s** |

**7.2× on a single test, 2.9× on the full suite**, with all 64 tests still
passing. The last column is the clock, covered in
[Raising the Rocket clock](#raising-the-rocket-clock) below.

**`kalloc()`'s poison is removed outright**, and this is not a debug-for-speed
trade: it cannot catch anything in this kernel. Every caller overwrites the
whole page before reading it — `walk()`, `uvmcreate()`, `uvmalloc()` and
`vmfault()` all `memset(0)` immediately, and `uvmcopy()` `memmove()`s over it.
The poison is destroyed before it can ever be observed, so it was pure DRAM
traffic.

**`kfree()`'s poison does have real value**, so it stays, behind a switch that
defaults off on this port:

```c
#define KFREE_POISON 0   // set to 1 when chasing a memory bug
```

It is also always skipped while `kinit()` builds the initial free list, since
those pages have never been allocated and so cannot be dangling references.
That alone is what makes `PHYSTOP` = 128MB affordable: poisoning 128MB at boot
cost 27 seconds, which used to be the entire boot time.

### Raising the Rocket clock

Upstream fpga-zynq runs this core at **25 MHz** (`RC_CLK_DIVIDE 40.0` in
`board/src/verilog/clocking.vh`), and leaves a lot on the table: with that
loose a constraint the routed design reported **WNS = +16.1 ns on a 40 ns
period**, i.e. a critical path of only 23.9 ns.

Tightening the constraint also makes Vivado work harder — at a 25 ns target
the same design routes to a 21.6 ns critical path. **40 MHz closes with
WNS = +3.395 ns** and passes the full suite.

The reason this helps as much as it does is worth knowing. It would be
reasonable to expect little gain, since page-zeroing stalls on memory and DRAM
latency is fixed wall-clock time — a faster core would just spend more cycles
waiting. But `rocketchip_wrapper.v` drives the block design's `ext_clk_in`
from the MMCM output, so **the AXI interconnect and the PS's `S_AXI_HP0` port
run at the Rocket clock too**. Raising it speeds up the memory path in step
with the core.

The measurement confirms it: **cycles per byte barely moves** (1.860 → 1.888
for a 16MB `memset`), so the work per byte is unchanged and the whole gain is
each cycle being shorter. Wall-clock for that `memset` goes 1.249 s → 0.792 s,
and the suite tracks the clock ratio almost exactly (1.54× measured for a 1.6×
clock).

**50 MHz** also closes timing, but at **WNS = +0.249 ns**. It booted and passed
three individual tests; a full-suite run was not completed, so it is unverified
and not shipped. A quarter of a nanosecond is inside the noise of on-chip
variation and temperature.

Testing a new bitstream does not need the SD card: the board has `/dev/xdevcfg`,
so `cat bitstream.bin > /dev/xdevcfg` reprograms the PL in about 0.1 s. Produce
the `.bin` with `bootgen -image x.bif -arch zynq -process_bitstream bin`.

---

## Measured hardware facts (not what the docs claim)

- **CLINT `mtime` runs at 250kHz**, i.e. the 25MHz Rocket clock / 100 — not the
  1MHz that rocket-chip's `DTSTimebase` advertises, and nothing like QEMU's
  10MHz. Timer intervals have to be derived from 250kHz.
- **`medeleg` is `0xB109`, whatever you write to it** (see above).
- **DRAM writes sustain ~4.7 MB/s** from the core, and the HTIF console moves
  ~2950 B/s. Those two numbers explain essentially all of this port's
  performance behaviour.
- **`mtval`/`stval` exist** under rocket's older `mbadaddr`/`sbadaddr` names —
  same CSR numbers (`0x343`/`0x143`), so the assembler's modern mnemonics work.

---

## Host-side prerequisites

Running xv6 needs the ARM/Rocket memory split configured correctly, or a program
on Rocket will overwrite the running ARM kernel. See the top-level README:
`rocketchip_wrapper.v` maps Rocket `0x8xxxxxxx` to Zynq `0x1xxxxxxx`, so Linux
must be confined to the low 256MB and u-boot must be told to place the ramdisk
there too.

xv6 writes to its disk image, and a crashed run leaves the log dirty, so keep a
pristine copy and restore it between runs:

```sh
cp /root/fs.img.orig /root/fs.img
```
