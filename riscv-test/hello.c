/*
 * Minimal RV64 bare-metal test for a Rocket Chip core reached over TSI.
 *
 * Communicates with fesvr using the HTIF protocol: fesvr finds the
 * `tohost` / `fromhost` symbols in this ELF's symbol table and polls them.
 *
 *   - a syscall is issued by writing the physical address of an 8-word
 *     request buffer to `tohost`, then waiting for fesvr to acknowledge
 *     by writing a non-zero value to `fromhost`.
 *   - exiting is a write of ((code << 1) | 1) to `tohost`, which is why
 *     an exit code of 0 shows up as the value 1.
 */
#include <stdint.h>

#define SYS_write 64

volatile uint64_t tohost   __attribute__((section(".htif")));
volatile uint64_t fromhost __attribute__((section(".htif")));

static volatile uint64_t syscall_buf[8];

static void htif_syscall(uint64_t n, uint64_t a0, uint64_t a1, uint64_t a2)
{
	syscall_buf[0] = n;
	syscall_buf[1] = a0;
	syscall_buf[2] = a1;
	syscall_buf[3] = a2;
	syscall_buf[4] = 0;
	syscall_buf[5] = 0;
	syscall_buf[6] = 0;
	syscall_buf[7] = 0;

	__asm__ volatile ("fence" ::: "memory");

	tohost = (uint64_t)(uintptr_t)syscall_buf;

	/* fesvr signals completion via fromhost; ack it by clearing. */
	while (fromhost == 0)
		;
	fromhost = 0;
}

static void print(const char *s)
{
	uint64_t len = 0;
	while (s[len])
		len++;
	htif_syscall(SYS_write, 1 /*stdout*/, (uint64_t)(uintptr_t)s, len);
}

static void htif_exit(int code)
{
	__asm__ volatile ("fence" ::: "memory");
	tohost = ((uint64_t)code << 1) | 1;
	for (;;)
		;
}

int main(void)
{
	print("Hello from Rocket Chip on PYNQ-Z1!\n");

	/* Prove the core is really executing, not just echoing: do some
	 * arithmetic and a 64-bit shift that only a working RV64 datapath
	 * gets right. */
	uint64_t acc = 0;
	for (uint64_t i = 1; i <= 100; i++)
		acc += i;

	char buf[] = "sum(1..100) = 5050 (expected 5050)\n";
	if (acc != 5050) {
		print("ARITHMETIC MISMATCH\n");
		htif_exit(1);
	}
	print(buf);

	uint64_t wide = 1ULL << 40;
	if (wide != 1099511627776ULL) {
		print("RV64 SHIFT MISMATCH\n");
		htif_exit(1);
	}
	print("64-bit shift OK (1<<40)\n");

	print("PASS\n");
	htif_exit(0);
	return 0;
}
