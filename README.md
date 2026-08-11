# circle-libfpc

**The Free Pascal runtime on bare-metal Raspberry Pi.** A library that resolves
what the Free Pascal compiler's `aarch64-embedded` target leaves for the
linker, and backs the runtime's installable interfaces with
[Circle](https://github.com/rsta2/circle). Compile an ordinary Pascal program
as a blob, link it against this library and a Circle world, and it boots from
the card with no operating system underneath.

It is the companion of
[circle-libsdl2](https://github.com/Xalior/circle-libsdl2), and it is built the
same way: one Circle world and one archive per board, an application makefile
fragment included after Circle's `Rules.mk`, and a set of examples that are
complete bootable kernels.

`circle-libsdl2` resolves an application's SDL2 calls. `circle-libfpc` resolves
its Free Pascal runtime calls. A kernel may link both, and that is the shape
this library is built for: **a Pascal program is a guest, not a kernel.** It
runs on a core the way a guest runs on a virtual machine — it runs code, and
every crossing to the outside world is somebody else's. This library owns no
hardware at all, not even a console, because a Pascal thread can run on a core
that is not core 0, and a device belongs to core 0. The somebody else is
`circle-libsdl2`: console output goes out through its byte-oriented log entry
when an image links it. Without it, output falls back to the host kernel's own
`CLogger`. See [Design](docs/DESIGN.md).

**This repository carries no `circle-libsdl2` checkout**, so its two examples
only exercise the `CLogger` fallback — that is what has booted on hardware.
The `circle-libsdl2` output path is implemented and its call is real, but a
consumer that links both libraries is exercising a path this repository's own
examples do not.

## What the compiler actually asks for

A Pascal object compiled for `aarch64-embedded` leaves exactly two symbols
undefined: `_haltproc`, a procedure that must not return, and `_stack_top`, an
address. Everything else the runtime needs — the heap block, the initialisation
tables, the thread-var tables, `PASCALMAIN` itself — the compiler emits into the
program object.

That makes the link look easy, and it is the trap. Three of this target's
interfaces are installed at **run** time and are invisible to a link:

- the memory manager is an all-zero record until something calls
  `SetMemoryManager`, so the first string assignment branches through a nil
  pointer;
- the thread manager reports a runtime error from every handler until something
  calls `SetThreadManager`;
- the widestring manager is another all-nil record — nothing in this target's
  own runtime ever fills it — so `AnsiUpperCase`, `AnsiCompareText` and every
  relative of theirs branch through a nil pointer just as silently.

A program that omits any of the three links perfectly and fails on the board.
Using this library's `circlefpc` unit installs all three, in the order that
works. See [The contract](docs/CONTRACT.md).

## Quick start

```sh
make BOARD=rpi5                 # libfpc-rpi5.a, against circle-stdlib-rpi5
make -C examples/ladder         # a bootable kernel image

./build-packages.sh             # SyncObjs, Generics.Collections, StrUtils,
make -C examples/packages       # fcl-image -- and a kernel that runs them
```

This library does not build Circle worlds. See [Building](docs/BUILDING.md) for
where a world comes from and how it must be configured.

## Key topics

- **[The contract](docs/CONTRACT.md)** — the two symbols, the two run-time
  installations, and what is not implemented yet
- **[Threading](docs/THREADING.md)** — a Pascal thread runs on a core a host
  kernel lends it, not as a Circle task: placement, thread-local storage, the
  heap lock, and the exception frame walk
- **[Packages](docs/PACKAGES.md)** — `SyncObjs`, `Generics.Collections`,
  `StrUtils` and `fcl-image`: why the compiler install leaves them out, how to
  build them, and what they cost at run time
- **[Design](docs/DESIGN.md)** — ownership rules and what a host kernel does
- **[Building](docs/BUILDING.md)** — worlds, boards, toolchains, invocation

## Licence

GPLv3, following Circle.
