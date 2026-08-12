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
`examples/m0/Makefile` for the whole of a working consumer.

Free Pascal compiles the program to relocatable objects; Circle's own build
does the link. The target refuses to produce an executable, deliberately, and
`fpc-compile.sh` explains what that means for reading the compiler's result.

## Status

The library reaches M0: a Pascal program links into a Circle host kernel, on
the application core, and the host kernel calls its entry point.

Nothing else is implemented. There is no memory manager, no thread manager and
no file, directory or console layer, so a Pascal program that allocates, opens
or prints anything does not work yet — it links cleanly and fails when it
runs.
