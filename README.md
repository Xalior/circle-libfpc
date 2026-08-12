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
the same kernel with a Pascal program that prints.

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

### What writing can and cannot do without a heap

**There is no heap yet.** `TMemoryManager` is a later milestone, so its
function pointers are still nil and an allocation is a call through one of
them. Writing stays on the right side of that line for:

- string literals and `ShortString` values;
- `Char`, and every integer type;
- `Boolean` and `Real`;
- field widths — the blanks go straight into the text file's buffer.

Each of those becomes characters in the text file's own buffer, which lives
inside the text record and never came from a heap. So does the line ending,
and so does opening the standard files at start-up, because they are opened
under an empty name and an empty name builds no string.

`AnsiString` and `UnicodeString` are on the other side of it. Building one
allocates before `writeln` is ever reached, a `UnicodeString` is converted to
bytes through the widestring manager on every write, and an `AnsiString`
whose code page differs from the text file's is converted the same way. None
of that works until the memory manager is installed.

An I/O error is on that side too. A non-zero `InOutRes` sends the runtime
into its error path, which builds an exception object, so the failure that
follows a failed write is an allocation fault rather than the error message.

## Status

The library reaches M2: a Pascal program links into a Circle host kernel on
the application core, the host kernel calls its entry point, and what the
program writes reaches the console through `circle-libsdl2`.

There is no memory manager, no thread manager, and no file or directory
layer, and console input is not implemented, so a Pascal program that
allocates, reads or opens anything does not work yet — it links cleanly and
fails when it runs.
