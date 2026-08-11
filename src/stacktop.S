/*
 * stacktop.S
 *
 * Half of the two-symbol contract. The aarch64-embedded System unit's
 * StackTop returns the ADDRESS of _stack_top, so the symbol is absolute and
 * its value is the top of the stack the Pascal code runs on.
 *
 * A host kernel calls PASCALMAIN from core 0's kernel stack, whose top Circle
 * names MEM_KERNEL_STACK -- the same value sysinit's GetCurrentStack reports
 * for core 0. Taking it from Circle's own header keeps the two in step when
 * the world is configured with a different KERNEL_STACK_SIZE or
 * KERNEL_MAX_SIZE.
 *
 * This is an archive member. A host kernel that runs Pascal somewhere else
 * defines _stack_top in one of its own objects instead, and the linker
 * prefers that: an object linked directly into a kernel is taken before an
 * archive member of the same name.
 */

#include <circle/memorymap.h>

	.global	_stack_top
	.set	_stack_top, MEM_KERNEL_STACK
