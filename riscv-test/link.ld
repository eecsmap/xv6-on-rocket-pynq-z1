OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  /* ExtMem base for the rocket-chip DefaultConfig used by ZynqFPGAConfig */
  . = 0x80000000;

  .text : {
    *(.text.start)
    *(.text .text.*)
  }

  .rodata : { *(.rodata .rodata.*) }
  .data   : { *(.data .data.*) }

  /* fesvr locates tohost/fromhost by symbol, but keeping them in their own
     aligned section makes the layout obvious in the map file. */
  . = ALIGN(8);
  .htif : { *(.htif) }

  . = ALIGN(8);
  _bss_start = .;
  .bss : { *(.bss .bss.*) *(COMMON) }
  . = ALIGN(8);
  _bss_end = .;

  . = ALIGN(16);
  . = . + 0x1000;
  _stack_top = .;
}
