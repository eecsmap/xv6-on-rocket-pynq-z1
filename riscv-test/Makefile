# Minimal RV64 bare-metal test for the Rocket Chip core, run via fesvr-zynq.
#
#   make            -> hello.riscv
#   make dump       -> disassembly
#
# Copy hello.riscv into the rootfs (/root) and on the board run:
#   cd /root && ./fesvr-zynq ./hello.riscv

CROSS   ?= riscv64-unknown-elf-
CC      := $(CROSS)gcc
OBJDUMP := $(CROSS)objdump
NM      := $(CROSS)nm

# ZynqFPGAConfig is rocket-chip's DefaultConfig: RV64 with C. No FP is used
# here, so imac is a safe subset. medany keeps us position-independent-ish
# for the 0x80000000 link address.
ARCH    := rv64imac
ABI     := lp64

CFLAGS  := -march=$(ARCH) -mabi=$(ABI) -mcmodel=medany \
           -nostdlib -nostartfiles -ffreestanding -O2 -Wall

all: hello.riscv

hello.riscv: crt.S hello.c link.ld
	$(CC) $(CFLAGS) -T link.ld -o $@ crt.S hello.c
	@echo
	@$(NM) $@ | grep -E ' (tohost|fromhost|_start|main)$$'

dump: hello.riscv
	$(OBJDUMP) -d $<

clean:
	rm -f hello.riscv

.PHONY: all dump clean
