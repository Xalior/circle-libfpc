//
// libfpc.h — the C half of circle-libfpc.
//
// Free Pascal calls C, and Circle is C++, so everything this library reaches
// Circle with is declared here as C. Two audiences read it. A host kernel
// needs the Pascal entry point the compiler emits and the halt path the Pascal
// runtime takes when the program ends. The Free Pascal runtime layer needs the
// rest, and it does not read this header at all — it declares each routine by
// name on its own side of the language boundary — so the declarations here are
// what states the contract for a reader.
//
#ifndef LIBFPC_H
#define LIBFPC_H

// size_t, as the world defines it. A consumer of this header is a Circle
// kernel and already has these on its include path.
#include <circle/types.h>

#ifdef __cplusplus
extern "C" {
#endif

// THE PASCAL ENTRY POINT.
//
// Free Pascal emits this symbol in the object it compiles a `program` module
// to. It initialises the units, runs the program body, and finishes through
// the halt path below.
//
// The host kernel calls it on the application core, and on no other: the
// Pascal program runs on a machine with one core and never leaves it.
//
// It returns when the program has ended — see LibFPC_ExitCode below.
void PASCALMAIN(void);

// THE HALT PATH.
//
// `_haltproc` is the symbol Free Pascal's system unit for this target calls
// when the program ends, whether by falling off the end of its body or by
// Halt. This library defines it. It records the exit code and returns, which
// hands control back to whoever called PASCALMAIN — the host kernel.
//
// A host kernel does not call it. It reads the code afterwards.
int LibFPC_ExitCode(void);

// Non-zero once the Pascal program has ended, so that a host kernel can tell
// an exit code of zero from a program that never got there.
int LibFPC_Halted(void);

// THE HEAP.
//
// Free Pascal's memory manager is Circle's allocator. Most of it needs nothing
// here: malloc, calloc, realloc and free are declared as C by Circle itself,
// in circle/alloc.h, and they are Circle's allocator rather than newlib's, so
// the Pascal runtime declares those four by name and calls them directly.
//
// What is left is the two questions a Free Pascal memory manager has to answer
// that C has no call for. Both are behind C++ — a Circle structure and a
// Circle class — so both are wrapped here.

// The usable size of a block malloc returned, which is what Free Pascal's
// MemSize means. Circle rounds an allocation up to a bucket size and records
// it in a header immediately before the block, so the answer is exact rather
// than the size that was asked for, and a string that grows inside its own
// block does not have to be moved.
//
// Zero for a null pointer, and zero for a pointer whose header does not carry
// Circle's "this block is allocated" mark. Under-reporting is safe — the
// runtime then copies where it could have grown in place — and over-reporting
// would not be, so a pointer this cannot account for is reported as nothing.
size_t LibFPC_HeapBlockSize(const void *pBlock);

// How much of the heap malloc allocates from has never been handed out.
//
// This is the heap's tail, not its free memory: Circle carves a new block off
// the tail only when the free list for that block size is empty, and a block
// that is freed goes back on that list rather than back to the tail. So it
// falls when the allocator has to find new memory, and it stays where it is
// for as long as everything being asked for can be met from what has already
// been freed. That is what makes it the measure of whether memory is REUSED.
//
// IT IS THE WHOLE BOARD'S, AND IT IS NOT A LEAK DETECTOR. There is one heap
// and every core allocates from it. The core that owns the devices allocates
// from it for as long as the board runs — USB plug-and-play and HID polling
// are on its service loop, on every lap — so this number drifts down under a
// Pascal program that is doing nothing wrong, at a rate set by how long the
// program runs rather than by what it allocates. A drop of one block here is
// the board, not the program.
//
// What a Pascal program has taken and not given back is a different question,
// and only the memory manager can answer it: it counts its own allocations,
// and reports the answer as TFPCHeapStatus.CurrHeapUsed.
size_t LibFPC_HeapFreeSpace(void);

#ifdef __cplusplus
}
#endif

#endif
