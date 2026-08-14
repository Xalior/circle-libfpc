# The heap

`TMemoryManager` is Circle's allocator. `AnsiString`, `UnicodeString`,
dynamic arrays, classes and `GetMem` all work, and so does raising an
exception, which builds an object and could not be done before there was
somewhere to build it.

**Memory is the one thing the application core reaches without crossing to
another core.** Every device on the board belongs to the core that owns it,
and a Pascal program reaches one only through `circle-libsdl2`. Circle's
allocator is different: it guards itself with a spin lock that holds across
cores, so an allocation made on the application core is safe as it stands.
The memory manager therefore calls `malloc` and its family directly. There is
no mailbox and no second core anywhere in the path a string takes.

Circle's own allocator is the whole of it. This library adds no allocator, no
pool and no arena, and it wraps only the two questions Free Pascal's memory
manager asks that C has no call for: the usable size of a block, and how much
of the heap has never been handed out. Both are in `src/heap.cpp`; read
`include/libfpc.h` for what each answers.

**The heap is fixed when the board comes up.** Circle sizes it from the
world's configuration and nothing grows it at run time, so a Pascal program
that runs out of memory has run out for good. Free Pascal's own answer to
that stands: `ReturnNilIfGrowHeapFails` decides whether the program is handed
a nil or stopped with run-time error 203.

## What `GetFPCHeapStatus` reports, and what it does not

Three figures, answering for two different things. Confusing them is easy and
gives a wrong answer that looks convincing.

- **`CurrHeapUsed` and `MaxHeapUsed` are the program's.** The memory manager
  counts what it hands out and what it takes back. A program that allocates
  and frees in balance returns `CurrHeapUsed` to exactly the value it started
  at, whatever else is happening on the board. **This is the figure to watch
  for a leak**, and it is exact.
- **`CurrHeapFree` is the whole board's.** There is one heap, every core
  allocates from it, and the core that owns the devices keeps allocating from
  it for as long as the board runs - USB plug-and-play and HID polling are on
  its service loop, on every lap. So this figure drifts downward under a
  Pascal program that is behaving perfectly, at a rate set by how long the
  program runs rather than by what it allocates. **It says whether memory is
  being reused; it does not say whether this program is leaking.**

Everything else in both records is a figure Circle's allocator does not keep,
and is reported as zero rather than estimated.

## Two properties of Circle's allocator to build around

Neither is a defect, and neither is this library's to change.

- **A block bigger than the largest bucket is never reused.** Circle returns a
  freed block to a free list only when its size matches one of its bucket
  sizes exactly, and the buckets stop at 512 KB. Anything above that is
  dropped on free and the space is gone for the life of the boot. On a heap
  that never grows, a program that repeatedly allocates and frees something
  very large will exhaust it.
- **A block is rounded up to its bucket, and the bucket sizes are far apart** -
  64 bytes, then 1 KB, 4 KB, 16 KB, 64 KB, 256 KB, 512 KB. An allocation of
  1025 bytes occupies 4 KB. `MemSize` reports the true bucket size rather than
  the size that was asked for, so Free Pascal grows a string inside its own
  block instead of copying it, but a program whose working sizes sit just
  above a bucket boundary pays four times over.

**Exception backtraces are off, deliberately.** Raising an exception in Free
Pascal collects a backtrace first, by walking the frame chain, and the walk is
bounded by a test against `StackTop` that will not hold for a Pascal thread
running on a stack this library allocated. Free Pascal 3.2.2 also returns the
wrong caller from the one routine that walk uses. The system unit sets
`RaiseMaxFrameCount` to zero, so the walk's loop body never runs and neither
problem can be reached. What is given up is backtraces, which carry no symbol
names on this target in any case.

`examples/m1` is a Pascal program that proves all of this on the board, and
reports its own verdict on the console.
