# circle-libfpc

The layer between Free Pascal's runtime and [Circle](https://github.com/rsta2/circle),
so that a Free Pascal program is a Circle application: it links Circle's
drivers, and it reaches the hardware only through them.

It is built per board, alongside
[circle-libsdl2](https://github.com/Xalior/circle-libsdl2), which owns the
display, input, sound and I/O a Pascal program uses. That library carries the
newlib and libc++ world; this one does not provide its own.

## Status

Empty. Nothing here is implemented yet.

The first attempt targeted `aarch64-embedded`, a Free Pascal target with no
Circle beneath it. Nothing built that way can link Circle's drivers, so all of
it was removed rather than kept as a starting point. The work begins again with
Circle as the target.
