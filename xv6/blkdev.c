//
// Driver for testchipip's block device, as instantiated in the Rocket Chip
// SoC on the PYNQ-Z1 (fpga-zynq). Replaces virtio_disk.c: there is no virtio
// device at 0x10001000 on this SoC.
//
// The backing store lives on the ARM side -- fesvr-zynq is started with
// `+blkdev=<file>` and services requests over the same TSI link the console
// uses. From the RISC-V core's point of view this is a simple DMA engine
// with a register file at 0x10015000 (testchipip BlockDevice.scala):
//
//   0x00  64  W   physical address to DMA to/from
//   0x08  32  W   offset, in 512-byte sectors, into the backing file
//   0x0C  32  W   length, in sectors
//   0x10   1  W   1 = write to disk, 0 = read from disk
//   0x11   R      allocate: reading takes a tracker tag AND issues the request
//   0x12   R      nallocate: number of free trackers
//   0x13   R      complete: reading pops the tag of a finished request
//   0x14   R      ncomplete: number of finished requests waiting
//   0x18  32  R   nsectors in the backing store
//   0x1C  32  R   maximum request length, in sectors
//
// Two details worth knowing:
//
//   - Reading the `allocate` register is what launches the transfer. The
//     address/offset/len/write registers must all be set up first.
//   - The DMA master is attached to the coherent system bus
//     (`sbus.fromPort` in HasPeripheryBlockDevice), so no manual cache
//     maintenance is needed; a fence to order the MMIO writes is enough.
//
// This driver polls rather than using the device's PLIC interrupt: xv6's
// bread()/bwrite() block anyway, and polling keeps the port independent of
// how interrupts happen to be numbered on this SoC.
//
#include "types.h"
#include "param.h"
#include "memlayout.h"
#include "riscv.h"
#include "spinlock.h"
#include "sleeplock.h"
#include "fs.h"
#include "buf.h"
#include "defs.h"

#define BLKDEV_BASE BLKDEV0

#define BLKDEV_ADDR      (BLKDEV_BASE + 0x00)
#define BLKDEV_OFFSET    (BLKDEV_BASE + 0x08)
#define BLKDEV_LEN       (BLKDEV_BASE + 0x0C)
#define BLKDEV_WRITE     (BLKDEV_BASE + 0x10)
#define BLKDEV_ALLOC     (BLKDEV_BASE + 0x11)
#define BLKDEV_NALLOC    (BLKDEV_BASE + 0x12)
#define BLKDEV_COMPLETE  (BLKDEV_BASE + 0x13)
#define BLKDEV_NCOMPLETE (BLKDEV_BASE + 0x14)
#define BLKDEV_NSECTORS  (BLKDEV_BASE + 0x18)
#define BLKDEV_MAX_LEN   (BLKDEV_BASE + 0x1C)

#define SECTOR_SIZE       512
#define SECTORS_PER_BLOCK (BSIZE / SECTOR_SIZE)

#define R8(a)  (*(volatile uint8 *)(a))
#define R32(a) (*(volatile uint32 *)(a))
#define W8(a, v)  (*(volatile uint8 *)(a) = (v))
#define W32(a, v) (*(volatile uint32 *)(a) = (v))
#define W64(a, v) (*(volatile uint64 *)(a) = (v))

static struct spinlock blkdev_lock;
static uint32 blkdev_nsectors;

void
blkdev_init(void)
{
  initlock(&blkdev_lock, "blkdev");

  blkdev_nsectors = R32(BLKDEV_NSECTORS);
  uint32 max_len = R32(BLKDEV_MAX_LEN);

  printk("blkdev: %d sectors (%d MB), max request %d sectors\n", blkdev_nsectors,
         blkdev_nsectors / (1024 * 1024 / SECTOR_SIZE), max_len);

  if (blkdev_nsectors == 0)
    printk("blkdev: no backing store -- start fesvr-zynq with +blkdev=<file>\n");
}

// Read (write==0) or write (write==1) one BSIZE block, synchronously.
void
blkdev_rw(struct buf *b, int write)
{
  // xv6 identity-maps the kernel, so a kernel virtual address is already the
  // physical address the DMA engine needs.
  uint64 pa = (uint64)b->data;
  uint32 offset = b->blockno * SECTORS_PER_BLOCK;

  if (blkdev_nsectors != 0 && offset + SECTORS_PER_BLOCK > blkdev_nsectors)
    panic("blkdev_rw: out of range");

  acquire(&blkdev_lock);

  // Wait for a free tracker.
  while (R8(BLKDEV_NALLOC) == 0)
    ;

  W64(BLKDEV_ADDR, pa);
  W32(BLKDEV_OFFSET, offset);
  W32(BLKDEV_LEN, SECTORS_PER_BLOCK);
  W8(BLKDEV_WRITE, write ? 1 : 0);

  // Make sure the request registers have landed before the read below
  // launches the transfer.
  __sync_synchronize();

  // Reading `allocate` issues the request; the value is the tracker tag.
  (void)R8(BLKDEV_ALLOC);

  // Wait for it to finish and consume the completion.
  while (R8(BLKDEV_NCOMPLETE) == 0)
    ;
  (void)R8(BLKDEV_COMPLETE);

  __sync_synchronize();

  b->disk = 0;

  release(&blkdev_lock);
}

// The device does have a PLIC interrupt line, but this driver polls, so
// there is nothing to do here. Kept so trap.c has something to call.
void
blkdev_intr(void)
{
}
