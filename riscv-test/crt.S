# Minimal RV64 startup: set up a stack and call main().
# Entry is at 0x80000000 (DRAM_BASE); fesvr loads us here over TSI and the
# bootrom jumps in.
	.section .text.start, "ax", @progbits
	.globl _start
_start:
	# clear any pending state and set up sp at the top of our stack
	la      sp, _stack_top
	# zero the BSS
	la      t0, _bss_start
	la      t1, _bss_end
1:
	bgeu    t0, t1, 2f
	sd      zero, 0(t0)
	addi    t0, t0, 8
	j       1b
2:
	call    main
	# main should not return; if it does, spin.
3:
	j       3b
