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

A read is answered from `Do_Read` (`fpc/rtl/circlesdl2/sysfile.inc`), the
routine every target's runtime reads its console through. It assembles a
whole line before it returns anything: it takes characters as they are
typed, echoes what it keeps, and hands back the finished line when the line
ending arrives. Free Pascal's own text buffer then holds that line and gives
characters out of it as the program asks, so `ReadLn` receives the line and
a `Read` of a single character receives the first character of it.

The line is edited as it is typed. Backspace, and the Delete a USB keyboard
sends in its place, remove the last character from the line and erase it on
screen. At the start of an empty line backspace does nothing and draws
nothing, so it can never erase a prompt printed before the read began.

`examples/readlnprobe` proves this with the stock `ReadLn` keyword and no
routine of this project's, on a target that never initialises SDL: a line
typed with a mistake and corrected before Enter is read back as the intended
text. `examples/keyprobe` reads standard input a character at a time, with
no SDL unit and no window.
