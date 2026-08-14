# Status

The library reaches M1 and M2 on the board: a Pascal program links into a
Circle host kernel on the application core, the host kernel calls its entry
point, the program allocates out of Circle's heap, and what it writes reaches
the console through `circle-libsdl2`.

Elapsed time and timed waits are written and built, and `examples/m3` is the
image that puts them to the board. That image has not run there, so the
interface is implemented rather than proven - and a memory manager or a clock
that is merely linked proves nothing, which is the whole reason each example
reports its own verdict off the console.

The thread manager is written and built, and `milestones/m4` is the image that
puts it to the board. That image has not run there either, and a thread
manager is the interface a clean link says least about: both records install
at run time and start as pointers that go nowhere, so a program that never
calls `BeginThread` links exactly as cleanly as one that does.

`KillThread` is not implemented and reports that it did nothing: stopping a
cooperative thread from outside means abandoning it wherever it happens to
be, and there is no unwinding here that could put that right. Thread
priorities are one value, so setting one reports that it was not set.

The file and directory layer is written and built, and `milestones/m5` is the
image that puts it to the board. That image has not run there either. It works
under two directories of its own making, `/tmp-clf-m5` and `/tmp-clf-m5-gone`,
and touches nothing outside them: it removes the second itself, erases its own
files out of the first, and leaves one witness in it for the host kernel to
read back from the core that owns the card and then remove. It also leaves the
working directory inside `/tmp-clf-m5`, so the host kernel can read that on the
same core and see for itself where `ChDir` put it.

The `SysUtils` file family, `Classes` and `TFileStream` are written and built,
and `milestones/m6` is the image that puts them to the board. That image has not
run there either. It works under one directory of its own making,
`/tmp-clf-m6`, and touches nothing outside it: it removes its own working files
and leaves a witness and the four files its directory search ran over, for the
host kernel to count on the core that owns the card and then remove.

Free Pascal's packages are built for the target, and `milestones/m7` is the image
that puts them to the board. That image has not run there. It works under one
directory of its own making, `/tmp-clf-m7`, removes everything it wrote
including the directory, and the host kernel then looks at the card itself, on
the core that owns it, to see whether that is true. Every section of it runs a
known answer through a unit and compares - a published digest, a round trip
through its own bytes, a date the calendar fixes - because a unit that compiles
and then faults looks identical from the development host.

**SDL runs on the board from Pascal, and `milestones/m8` has drawn a picture
there.** It declares a virtual display of its own that matches nothing on the
board, makes a window, a renderer and textures in three formats, draws through
every path the library offers, and then reads its own frames back with
`SDL_RenderReadPixels` - which returns SDL's framebuffer in the coordinates the
caller drew in - and compares them against what it drew, pixel by pixel,
printing the tolerance beside each verdict. Every one of those comparisons
agrees. It opens no file and leaves nothing on the card.

The event queue is proved as far as it can be with nobody at the bench: that a
poll with nothing pending answers so, that an event pushed in comes back out
with every field intact, and that scancode and keycode remain each other's
inverse across the whole table. A key press cannot be manufactured, so the
program watches for one for ten seconds, reports whatever arrived, and treats
an empty watch as the expected answer.

One check disagrees with `circle-libsdl2` rather than failing, and the program
says which and prints the line that proves it. `SDL_WasInit(SDL_INIT_EVENTS)`
answers zero after `SDL_Init(SDL_INIT_VIDEO)`, although the SDL2 header that
library ships states the implication twice. The events subsystem is genuinely
up - nothing later in the program could work otherwise - so this is the
bookkeeping and not the machine, but it is bookkeeping applications branch on.
It is recorded there to be raised, never worked around here.

Console input through the Free Pascal runtime works: `examples/keyprobe` and
`examples/readlnprobe` prove `Read` and `ReadLn` reach a real keyboard, with
no SDL unit and no window - see [Console](CONSOLE.md) for what each one
proves. That is a separate question from SDL's own keyboard reading, which
`milestones/m8` proves.
