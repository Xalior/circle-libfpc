# SDL from a Pascal program

A Pascal program reaches the display and the keyboard the same way a C one
does: through `circle-libsdl2`, calling SDL. Nothing in this library sits in
that path, and there is no Pascal graphics layer here to learn.

A Pascal SDL program already carries its own binding - the SDL2-for-Pascal
unit set, in one generation or another - and that is the one to use,
unchanged. `patches/` carries the one hunk that binding needs to know this
target exists, and its README says what the hunk does and why the
alternatives do not work.

**Point `FPC_UNIT_SRC_DIRS` at the binding's source.** `fpc-app.mk` compiles
every unit it finds there beside the program and links their objects; read its
header for the whole of that. `milestones/m8/Makefile` takes the binding's
directory as `SDL2_PASCAL_UNITS` and refuses to build without one.

**`units/sdl2circle.pas` is this library's own, and it is one unit.** It
declares the calls in `circle-libsdl2`'s `SDL_circle.h` that no SDL binding
carries, because they are not in SDL's headers - chiefly the virtual display.
An application names the unit beside its binding, exactly as a C application
adds one `#include`. It depends on no binding and uses plain Free Pascal
types, so it never argues with one over a type name.

Only the application's half of that header is declared. A Circle host kernel
is C++ - there is no other kind - so the calls that arm a core, create the
servo or hand a core to presentation have no Pascal caller.

## The display size

A program that creates a window with a real size needs to do nothing at all:
`circle-libsdl2` settles the canvas from, in order, the first of these that is
present -

1. the `--rapi-vdisplay=WxH` boot switch,
2. an explicit call to `SDL2Circle_DeclareVirtualDevice` before `SDL_Init`,
3. the size the program's first `SDL_CreateWindow` asks for,
4. the physical panel's own size, read from the firmware, as a last resort.

Once settled, the canvas does not change for the rest of the run. Read
`circle-libsdl2/docs/DISPLAY.md` for the whole of this, including how a
program whose canvas came from the switch reads its true drawing size once
the switch and the window disagree on purpose.

A port that wants a fixed size baked into the image rather than declared by
the program stamps it into the boot argument block after linking - see
[Building a kernel](BUILDING.md).

## The event record is shorter in Pascal than in C

SDL's `SDL_Event` is a union with a `padding` member that fixes it at 56 bytes
on a 64-bit machine, and a compile-time assertion in `SDL_events.h` holds it
there. Every entry point that fills an event writes that many bytes.

**The Pascal translations of that header carry the variants and not the
padding**, so `TSDL_Event` is as large as its largest declared variant and no
larger - which is smaller. Passing the address of a bare one to
`SDL_PollEvent` hands SDL a buffer shorter than the one it will fill. On a
desktop the overrun lands in another local; here it lands on a stack this
library allocated, and Circle lays the core stacks out with no guard page
between them.

So an event is passed through a variant record whose other arm is a byte array
past 56. `milestones/m8` carries one and prints both sizes - its own and the C
one, which its host kernel prints from the compiler that built the library -
so the difference is on the log rather than in a comment.
