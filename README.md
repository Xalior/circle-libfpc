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

## Status

Empty. Nothing here is implemented yet.
