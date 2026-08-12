//
// heap.cpp — what the Free Pascal memory manager needs from Circle that
// Circle does not already declare as C.
//
// THE ALLOCATOR IS CIRCLE'S, AND IT IS NOT A CROSSING. Every other device on
// the board belongs to the core that owns it, and the application core reaches
// one only through circle-libsdl2. Memory is different: CHeapAllocator guards
// itself with a spin lock that holds across cores, so an allocation made on
// the application core is safe as it stands. That is why the Pascal side calls
// malloc directly instead of marshalling the way the file layer must.
//
// SO THERE IS ALMOST NOTHING HERE. malloc, calloc, realloc and free are
// already declared as C, by circle/alloc.h, and in a linked kernel they are
// Circle's own — libcircle.a(alloc.o) defines them and newlib's are never
// pulled in. The Pascal runtime declares those four by name and calls them.
//
// The two routines below are the rest: the questions Free Pascal's memory
// manager has to answer that C has no call for. Both are behind C++.
//
#include "libfpc.h"

#include <circle/heapallocator.h>
#include <circle/memory.h>
#include <circle/sysconfig.h>
#include <circle/types.h>

// THE SIZE OF AN ALLOCATED BLOCK.
//
// Circle rounds every allocation up to one of its bucket sizes and writes the
// result into a THeapBlockHeader that sits immediately before the block it
// hands back. CHeapAllocator finds that header the same way on every free and
// every reallocation, so this is the allocator's own arithmetic rather than an
// assumption about its layout.
//
// The magic word is checked because this answer must never be too large. Free
// Pascal grows a string inside its own block whenever MemSize says there is
// room, so a number bigger than the block is a buffer overrun, while a number
// smaller than the block only costs a copy.
extern "C" size_t LibFPC_HeapBlockSize(const void *pBlock)
{
    if (pBlock == 0)
    {
        return 0;
    }

    const THeapBlockHeader *pHeader = (const THeapBlockHeader *)
        ((uintptr) pBlock - sizeof(THeapBlockHeader));

    if (pHeader->nMagic != HEAP_BLOCK_ALLOC_MAGIC)
    {
        return 0;
    }

    return pHeader->nSize;
}

// WHAT IS LEFT OF THE HEAP'S TAIL.
//
// The heap Circle serves malloc from is named by HEAP_DEFAULT_MALLOC, the same
// constant malloc itself uses, so this follows the world's configuration
// rather than restating it.
//
// GetFreeSpace() reports the part of that region no block has ever been carved
// out of. Blocks on a free list are not counted, which is the property that
// makes the number useful: repeatedly allocating and freeing a size that is
// already on a free list does not move it at all.
//
// THIS IS THE WHOLE BOARD'S NUMBER. There is one heap and every core allocates
// from it, so the core that owns the devices moves this while a Pascal program
// runs, and the longer the program runs the further it moves. It measures
// whether memory is being reused. It does NOT measure whether the Pascal
// program is leaking, and the memory manager's own count is what does.
extern "C" size_t LibFPC_HeapFreeSpace(void)
{
    return CMemorySystem::Get()->GetHeapFreeSpace(HEAP_DEFAULT_MALLOC);
}
