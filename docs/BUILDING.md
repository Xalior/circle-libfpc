# Building a kernel

## Prerequisites

```sh
gmake                 # this board's archive, every example and milestone image
gmake BOARD=rpi5      # build against another board's world
gmake rebuild         # build from nothing
```

The build needs three things it never produces: a configured Circle world, the
`circle-libsdl2` archive for the same board, and the Free Pascal
cross-compiler with its runtime units. `CIRCLE_WORLDS`, `SHIM`, `FPC_COMPILER`
and `FPC_UNITS` say where each of them is. A missing one is a wrong variable,
not something for this build to fetch or build.

`FPC_PACKAGES` says where Free Pascal's packages tree is, and a program that
names a unit from it needs those packages built. Without it a program is
limited to the runtime library alone - see [The standard library](STDLIB.md).

GNU make 4.0 or later. macOS ships 3.81 as `make`, which compares file
timestamps to the second; Homebrew installs a current one as `gmake`.

Free Pascal compiles a program to relocatable objects; Circle's own build
does the link. The target refuses to produce an executable, deliberately, and
`fpc-compile.sh` explains what that means for reading the compiler's result.

## The host kernel

A host kernel builds the Pascal application by including `fpc-app.mk` after
Circle's `Rules.mk` and before `circle-libsdl2`'s `sdl-app.mk`. Read that
file's header for what it needs and what it hands back.

**There is one host kernel, in `host/`, and a port carries no C++ of its
own.** `host/kernel.cpp` and `host/kernel.h` are brought in by
`host/host-kernel.mk`, included the same way as `fpc-app.mk`; read its header
for what a port's Makefile sets and includes, and `examples/m2/Makefile` for
the whole of a working consumer. This kernel brings up core 0's own devices -
the serial console, the SD card and its FAT filesystem - starts the secondary
cores, sets the working directory, arms the core split, and releases the
application core to call the Pascal program's entry point. `fairtris2` in the
parent repository is a consumer of the same kernel.

## The working directory

A port names its working directory as `RAPI_WORK_DIR`, a build-time value the
kernel turns into its own compiled-in default. Left unset, it falls back to
`/`, the card's root, which is always there. See
[the working directory](FILES.md#the-working-directory) for what happens when
the name it gives is not on the card.

## The display size

The kernel declares no display size of its own - `circle-libsdl2` settles the
canvas at run time, and a program that creates a window with a real size needs
nothing further. See [The display size](SDL.md#the-display-size) for the
order it settles in.

A port that wants a size to ride every boot with nothing passed at boot time
stamps it into the built image instead, after linking:

```sh
circle-libsdl2/tools/stamp-bootargs kernel_2712.img --rapi-vdisplay=800x450
```

The image carries a fixed-offset block - a magic number, a capacity, a length
and the argument text - that `circle-libsdl2` reads before `SDL_Init` runs.
`stamp-bootargs` writes into that block on a built image, checking the magic
first and refusing an image that was not linked with room for it. **A loader
can overwrite the same block over the wire, at boot, with no rebuild** - the
library reads whichever bytes are in the block when the image runs, so a
switch a loader writes at boot still wins over one a port stamped in at build
time. No example or milestone in this repository stamps a display size today;
each settles its canvas from its window's own size or the physical panel.

## Examples and milestones

`examples/` holds Pascal source and a Makefile apiece, each linked against the
one host kernel in `host/`: `examples/keyprobe` and `examples/readlnprobe`
read standard input, `examples/m1` allocates, `examples/m2` prints, and
`examples/m3` measures time.

`milestones/` holds the programs that proved this library's own capabilities
as it gained them, each keeping a kernel of its own rather than `host/`'s:
`milestones/m0` is the first Pascal entry point reached; `milestones/m4` runs
threads; `milestones/m5` reads and writes files; `milestones/m6` does the
same through `SysUtils` and `TFileStream`; `milestones/m7` exercises the
standard library; `milestones/m8` drives SDL. Each keeps its own kernel
because part of what it proves can only be checked from the core that owns
the devices, independently of the Pascal side under test - read
`milestones/README.md`. They are verification programs, not a pattern to
copy: a program on this target is written the way an example is.
