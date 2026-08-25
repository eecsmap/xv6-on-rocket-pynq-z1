/*
 * pl-probe: read the Zynq adapter register block that the Rocket Chip
 * design exposes on AXI GP0, straight out of /dev/mem.
 *
 * This is the same window and the same offsets fesvr-zynq's zynq_driver_t
 * uses (common/csrc/zynq_driver.cc), so if this prints sane values the
 * bitstream is loaded, the PL is clocked, and the PS->PL path works --
 * which is everything fesvr needs before it can talk to the core.
 *
 * A PL that is unconfigured, unclocked, or held in reset typically reads
 * back as all-ones (0xffffffff) on every offset.
 *
 * Only COUNT/status registers are read. The *_FIFO_DATA registers are
 * deliberately skipped: reading one POPS the FIFO, which would steal a
 * word out from under fesvr.
 *
 * Build (static, so it needs nothing from the rootfs):
 *   arm-linux-gnueabihf-gcc -O2 -static -Wall -o pl-probe pl-probe.c
 *
 * Expected on a healthy ZynqFPGAConfig build, before fesvr runs:
 *   TSI_IN_FIFO_COUNT      = 0x10   (SerialFIFODepth = 16)
 *   BLKDEV_RESP_FIFO_COUNT = 0x10   (BlockDeviceFIFODepth = 16)
 *   SYSTEM_RESET           = 0x01   (core held in reset until fesvr starts)
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define ZYNQ_BASE_PADDR 0x43C00000L

static const struct { int off; const char *name; } regs[] = {
	{ 0x04, "TSI_OUT_FIFO_COUNT"        },
	{ 0x0C, "TSI_IN_FIFO_COUNT"         },
	{ 0x10, "SYSTEM_RESET"              },
	{ 0x24, "BLKDEV_REQ_FIFO_COUNT"     },
	{ 0x2C, "BLKDEV_DATA_FIFO_COUNT"    },
	{ 0x34, "BLKDEV_RESP_FIFO_COUNT"    },
	{ 0x38, "BLKDEV_NSECTORS"           },
	{ 0x3C, "BLKDEV_MAX_REQUEST_LENGTH" },
	{ 0x44, "NET_OUT_FIFO_COUNT"        },
	{ 0x4C, "NET_IN_FIFO_COUNT"         },
};

int main(void)
{
	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		perror("open /dev/mem");
		return 1;
	}

	long pagesize = sysconf(_SC_PAGESIZE);
	volatile uint8_t *dev = mmap(0, pagesize, PROT_READ | PROT_WRITE,
				     MAP_SHARED, fd, ZYNQ_BASE_PADDR);
	if (dev == MAP_FAILED) {
		perror("mmap");
		close(fd);
		return 1;
	}

	printf("Zynq adapter @ 0x%08lx (FIFO_DATA regs skipped: reads pop)\n\n",
	       ZYNQ_BASE_PADDR);

	int ones = 0;
	size_t n = sizeof(regs) / sizeof(regs[0]);
	for (size_t i = 0; i < n; i++) {
		uint32_t v = *(volatile uint32_t *)(dev + regs[i].off);
		printf("  +0x%02x  %-26s = 0x%08x\n", regs[i].off, regs[i].name, v);
		if (v == 0xffffffffU)
			ones++;
	}

	printf("\n");
	if (ones == (int)n)
		printf("VERDICT: every register reads 0xffffffff -- PL looks "
		       "unconfigured, unclocked, or held in reset.\n");
	else
		printf("VERDICT: PL responds with real data (%d/%zu regs "
		       "all-ones). PS->PL path is alive.\n", ones, n);

	munmap((void *)dev, pagesize);
	close(fd);
	return 0;
}
