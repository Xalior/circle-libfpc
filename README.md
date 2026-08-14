# circle-libfpc

Free Pascal's runtime, resolved against [Circle](https://github.com/rsta2/circle):
compile a Free Pascal program and get back a bootable Raspberry Pi image, with
no operating system underneath it.

It is built per board, alongside
[circle-libsdl2](https://github.com/Xalior/circle-libsdl2), which owns the
display, input, sound and I/O a Pascal program uses. That library carries the
newlib and libc++ world; this one does not provide its own.

The Free Pascal target is `circlesdl2`.

## Building

```sh
gmake                 # this board's archive, every example and milestone image
gmake BOARD=rpi5      # build against another board's world
gmake rebuild         # build from nothing
```

See [Building a kernel](docs/BUILDING.md) for the prerequisites, and for
compiling a Pascal program into a bootable image.

## What a Pascal program can use

- **[Building a kernel](docs/BUILDING.md)** - the host kernel, a port's
  Makefile, the display size, the working directory, examples and milestones
- **[Console](docs/CONSOLE.md)** - `writeln`, `Read` and `ReadLn`
- **[Files and directories](docs/FILES.md)** - `Assign`, `Reset`,
  `BlockRead` and the rest, and the working directory
- **[SysUtils, Classes and TFileStream](docs/SYSUTILS.md)** - the file layer
  a real program writes against, and `TThread`
- **[The standard library](docs/STDLIB.md)** - the packages built for this
  target, the wide string manager, the `Dos` unit
- **[Elapsed time](docs/TIME.md)** - the counter, and calendar time
- **[Threads](docs/THREADS.md)** - the scheduler, stacks, what nothing
  preempts means for a program
- **[The heap](docs/HEAP.md)** - `TMemoryManager`, `GetFPCHeapStatus`,
  Circle's allocator
- **[SDL](docs/SDL.md)** - reaching the display and the keyboard from Pascal

## Status

[Status](docs/STATUS.md) says how far each of the above has been proven on a
board.
