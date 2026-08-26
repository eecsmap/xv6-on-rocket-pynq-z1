//
// HTIF console for xv6 on a Rocket Chip core reached over testchipip's TSI
// link (fpga-zynq / PYNQ-Z1).
//
// Drop-in replacement for uart.c: this Rocket configuration has no NS16550
// at 0x10000000. The only console is the HTIF channel that fesvr-zynq
// already polls on the ARM side, so console traffic rides that instead.
//
// Protocol (see riscv-fesvr fesvr/htif.cc and fesvr/device.cc):
//
//   tohost   = (device << 56) | (cmd << 48) | payload
//
//   The *host* signals it consumed a command by writing 0 back to tohost,
//   so the target waits for tohost == 0 rather than for a fromhost reply.
//   That distinction matters: bcd_t::handle_write() never calls respond(),
//   so a console write produces NO fromhost reply. Waiting on fromhost
//   after a putc would hang forever.
//
//   The host writes fromhost only when it reads as 0, so the target must
//   zero it after consuming a reply or the host stalls.
//
//   device 1 (bcd) cmd 1 = write, payload = character
//   device 1 (bcd) cmd 0 = read, reply arrives in fromhost as (0x100 | ch)
//
#include "types.h"
#include "param.h"
#include "memlayout.h"
#include "riscv.h"
#include "spinlock.h"
#include "proc.h"
#include "defs.h"

// fesvr locates these two by symbol name in the kernel ELF. They must keep
// these exact names and must live in memory the host can reach: xv6's kernel
// mapping is an identity map of KERNBASE upward, so a kernel global's virtual
// address equals its physical address, which is what HTIF needs.
volatile uint64 tohost __attribute__((aligned(64)));
volatile uint64 fromhost __attribute__((aligned(64)));

#define HTIF_DEV_BCD   1UL
#define HTIF_CMD_READ  0UL
#define HTIF_CMD_WRITE 1UL

static struct spinlock htif_tx_lock;

// Is a console read request already outstanding? Only one HTIF command may
// be in flight at a time, so we must not queue a second read before the
// first is answered.
static int read_pending;

static void
htif_send(uint64 dev, uint64 cmd, uint64 payload)
{
  // Wait for any previous command to be consumed by the host.
  while (tohost != 0)
    ;
  tohost = (dev << 56) | (cmd << 48) | (payload & 0xffffffffffffUL);
  // Wait for this one to be consumed too, so callers get simple ordering.
  while (tohost != 0)
    ;
}

void
uartinit(void)
{
  initlock(&htif_tx_lock, "htif");
  read_pending = 0;
}

// Blocking, lock-free single character out. Used by printk and by the
// console for echo, including from panic paths where locks may be held.
void
uartputc_sync(int c)
{
  htif_send(HTIF_DEV_BCD, HTIF_CMD_WRITE, (uint64)(c & 0xff));
}

// xv6 has no interrupt-driven path here: HTIF has no interrupt line, so
// there is no "async" mode to defer to. Writing straight through keeps the
// console correct at the cost of being slow, which is fine for bring-up.
void
uartwrite(char buf[], int n)
{
  acquire(&htif_tx_lock);
  for (int i = 0; i < n; i++)
    htif_send(HTIF_DEV_BCD, HTIF_CMD_WRITE, (uint64)(buf[i] & 0xff));
  release(&htif_tx_lock);
}

// Non-blocking: returns -1 when no character is ready.
//
// Issues a read request and picks up the answer on a later call, so this
// never blocks the caller waiting on a human.
static int
htif_getc(void)
{
  uint64 fh = fromhost;

  if (fh != 0) {
    fromhost = 0;               // let the host queue the next reply
    read_pending = 0;
    if (fh & 0x100)             // 0x100 marks a valid character
      return (int)(fh & 0xff);
    return -1;
  }

  if (!read_pending) {
    htif_send(HTIF_DEV_BCD, HTIF_CMD_READ, 0);
    read_pending = 1;
  }
  return -1;
}

// Called from the timer tick (see trap.c) rather than from a device
// interrupt, since HTIF cannot raise one.
void
uartintr(void)
{
  int c;

  while ((c = htif_getc()) != -1) {
    consoleintr(c);
  }
}
