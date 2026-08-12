# circle-libfpc

The layer between Free Pascal's runtime and [Circle](https://github.com/rsta2/circle),
so that a Free Pascal program is a Circle application: it links Circle's
drivers, and it reaches the hardware only through them.

It is built per board, alongside
[circle-libsdl2](https://github.com/Xalior/circle-libsdl2), which owns the
display, input, sound and I/O a Pascal program uses. That library carries the
newlib and libc++ world; this one does not provide its own.

## The Free Pascal target

The target is `circlesdl2`. Free Pascal names a target for the library its
runtime layer binds to wherever one machine carries more than one binding, as
`netwlibc` sits beside `netware`. This runtime layer calls `circle-libsdl2`
rather than Circle, and the single-core machine a Pascal program runs on is
that library's shape rather than Circle's. The name `circle` belongs to a
target that binds Circle directly.

## Building

```sh
gmake                 # this board's archive and every example image
gmake BOARD=rpi5      # build against another board's world
gmake rebuild         # build from nothing
```

The build needs three things it never produces: a configured Circle world, the
`circle-libsdl2` archive for the same board, and the Free Pascal
cross-compiler with its runtime units. `CIRCLE_WORLDS`, `SHIM`, `FPC_COMPILER`
and `FPC_UNITS` say where each of them is. A missing one is a wrong variable,
not something for this build to fetch or build.

GNU make 4.0 or later. macOS ships 3.81 as `make`, which compares file
timestamps to the second; Homebrew installs a current one as `gmake`.

## Compiling a Pascal program into a kernel

A host kernel builds the Pascal application by including `fpc-app.mk` after
Circle's `Rules.mk` and before `circle-libsdl2`'s `sdl-app.mk`. Read that
file's header for what it needs and what it hands back, and
`examples/m0/Makefile` for the whole of a working consumer. `examples/m2` is
the same kernel with a Pascal program that prints, and `examples/m1` the same
kernel again with a Pascal program that allocates.

Free Pascal compiles the program to relocatable objects; Circle's own build
does the link. The target refuses to produce an executable, deliberately, and
`fpc-compile.sh` explains what that means for reading the compiler's result.

## Console output

`writeln` works, and it reaches the console the only way anything on the
application core may: `circle-libsdl2`'s log channel. The Free Pascal runtime
opens the standard text files on the C library's descriptor numbers, and the
target's `do_write` recognises those three handles and hands the bytes to the
log channel, which assembles them into lines and lets the core that owns the
serial device print them. Nothing in this library, and nothing in a Pascal
program, touches that device.

Standard output and standard error arrive under separate tags, `pascal` and
`pascal-err`, so the console tells them apart. The standard handles answer
yes to Free Pascal's "is this a device" question, so a text file on one is
emptied at the end of every `writeln` rather than when its buffer fills — a
program that never ends still prints as it goes.

The log channel cannot refuse a line, and it never blocks the core that
writes: when its ring is full the line is dropped and counted, and the drain
reports the loss on the console. `writeln` therefore always reports success.
Read `circle-libsdl2/docs/LOGGING.md` for what that costs and how fast the
console really is.

## The heap

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

### What `GetFPCHeapStatus` reports, and what it does not

Three figures, answering for two different things. Confusing them is easy and
gives a wrong answer that looks convincing.

- **`CurrHeapUsed` and `MaxHeapUsed` are the program's.** The memory manager
  counts what it hands out and what it takes back. A program that allocates
  and frees in balance returns `CurrHeapUsed` to exactly the value it started
  at, whatever else is happening on the board. **This is the figure to watch
  for a leak**, and it is exact.
- **`CurrHeapFree` is the whole board's.** There is one heap, every core
  allocates from it, and the core that owns the devices keeps allocating from
  it for as long as the board runs — USB plug-and-play and HID polling are on
  its service loop, on every lap. So this figure drifts downward under a
  Pascal program that is behaving perfectly, at a rate set by how long the
  program runs rather than by what it allocates. **It says whether memory is
  being reused; it does not say whether this program is leaking.**

Everything else in both records is a figure Circle's allocator does not keep,
and is reported as zero rather than estimated.

### Two properties of Circle's allocator to build around

Neither is a defect, and neither is this library's to change.

- **A block bigger than the largest bucket is never reused.** Circle returns a
  freed block to a free list only when its size matches one of its bucket
  sizes exactly, and the buckets stop at 512 KB. Anything above that is
  dropped on free and the space is gone for the life of the boot. On a heap
  that never grows, a program that repeatedly allocates and frees something
  very large will exhaust it.
- **A block is rounded up to its bucket, and the bucket sizes are far apart** —
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

## Status

The library reaches M1 and M2: a Pascal program links into a Circle host
kernel on the application core, the host kernel calls its entry point, the
program allocates out of Circle's heap, and what it writes reaches the
console through `circle-libsdl2`.

There is no thread manager and no file or directory layer, and console input
is not implemented, so a Pascal program that starts a thread, reads or opens
anything does not work yet — it links cleanly and fails when it runs.
