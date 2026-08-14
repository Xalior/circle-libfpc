# Console

## Output

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
emptied at the end of every `writeln` rather than when its buffer fills - a
program that never ends still prints as it goes.

The log channel cannot refuse a line, and it never blocks the core that
writes: when its ring is full the line is dropped and counted, and the drain
reports the loss on the console. `writeln` therefore always reports success.
Read `circle-libsdl2/docs/LOGGING.md` for what that costs and how fast the
console really is.

## Input

Standard input works, and a program that never touches SDL can read it.
`circle-libsdl2` binds all three of the C library's standard descriptors to a
real console, keyboard included, inside `SDL2Circle_ArmCoreRuntime` - the
call every host kernel makes, on core 0, before it releases the application
core. No kernel builds a `CConsole` or calls `CGlueStdioInit` itself: the
library's own `SDL2Circle_StdioInit` does both, the moment `ArmCoreRuntime`
runs, and it runs whether or not the program ever calls `SDL_Init`.
`milestones/m5`, `m6` and `m7` still build a `CConsole` and call
`CGlueStdioInit` by hand, from before that was true - kept as they were
written, which is one of the reasons they are milestones rather than
examples to copy.

A read blocks until a key arrives, and it is answered from `Do_Read`
(`fpc/rtl/circlesdl2/sysfile.inc`), the routine every target's runtime reads
its console through. Every key is delivered the moment it is typed, one
character at a time, echoed as it arrives - never held back until a line
ends. That is why a plain `Read` of a single character returns on the very
keystroke: it does not wait for a line to be finished and Enter pressed.
`ReadLn`'s own wait for the line ending is Free Pascal's own, built out of
repeated calls to `Read`, and each character in it still arrives only once
its key is pressed.

Because a read is never held back for a line, there is no line discipline
underneath it to edit one: backspace is delivered and echoed like any other
character, not as an erase. A line typed with a mistake and then backspaced
over is not corrected before Enter is pressed - what `ReadLn` reads back is
every key that was pressed, backspace included, not the intended text.

`examples/keyprobe` proves a character arrives on typing rather than at
Enter, reading nothing but standard input with no SDL unit and no window.
`examples/readlnprobe` proves plain `ReadLn` - the stock keyword, not a
routine of this project's - reads back the keys pressed up to the line
ending, on a target that never initialises SDL either.
