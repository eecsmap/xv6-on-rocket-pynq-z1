/*
 * boot.S already sets up every CPU-mode stack pointer (IRQ/SVC/ABT/FIQ/UND/SYS)
 * using the linker script's correct addresses within the OCM bank that is
 * actually mapped to the high alias (per OCM_CFG). newlib's own weak
 * _stack_init (pulled in from libc.a via _mainCRTStartup) then re-derives
 * stack addresses via hardcoded byte-offset arithmetic from the current SP,
 * ignoring OCM_CFG and landing in an OCM bank that is not mapped at the high
 * alias, causing a genuine external abort on first use. Override it as a
 * no-op so boot.S's correct setup is left alone.
 */
void _stack_init(void)
{
}
