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

`FPC_PACKAGES` says where Free Pascal's packages tree is, and a program that
names a unit from it needs those packages built. Without it a program is
limited to the runtime library alone.

GNU make 4.0 or later. macOS ships 3.81 as `make`, which compares file
timestamps to the second; Homebrew installs a current one as `gmake`.

## Compiling a Pascal program into a kernel

A host kernel builds the Pascal application by including `fpc-app.mk` after
Circle's `Rules.mk` and before `circle-libsdl2`'s `sdl-app.mk`. Read that
file's header for what it needs and what it hands back, and
`examples/m0/Makefile` for the whole of a working consumer. The rest are the
same kernel with a different Pascal program inside it: `examples/m2` prints,
`examples/m1` allocates, `examples/m3` measures time, `examples/m4` runs
threads, `examples/m5` reads and writes files, `examples/m6` does the same
through `SysUtils` and `TFileStream`, `examples/m7` exercises the standard
library, and `examples/m8` drives SDL. The host kernels of `m5`, `m6` and `m7`
are the ones that bring up the SD card, because a program that opens a file
needs one mounted before its core is released; `m8`'s is the one that runs a
presentation core, because it is the only one that draws.

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

There is no console input. A `readln` from the keyboard reports that it did
nothing.

## Files and directories

`Assign`, `Reset`, `Rewrite`, `Append`, `BlockRead`, `BlockWrite`, `Seek`,
`FilePos`, `FileSize`, `Truncate`, `Close`, `Erase` and `MkDir` work, on text
files and on typed and untyped files alike. Every one of them reaches the card
through `circle-libsdl2`'s file service and through nothing else. The card is a
device, a device belongs to the core that owns it, and the guest is not on that
core.

**The file service is not a second filesystem.** It is the C library's own file
call, carried to the core that owns the card and performed there. So a Pascal
program gets the C library's semantics, and the error translation in
`sysfile.inc` is the same one every libc-backed Free Pascal target does.

**The file position lives on this side.** The service names an offset on every
read and write and remembers nothing between calls, while Free Pascal expects
an open file to know where it is. So the target holds one entry per open file —
where it is, and how long it is — advanced on each read and write, set on each
seek, and taken from the open so that a seek from the end has an answer. There
is no lock on that table and none is needed: Pascal threads run on one core,
nothing preempts them, and no routine in the file layer gives the core away.
`CircleOpenFileCount` reports how many entries are taken, which is what a
program asks to see that closing a file gave its entry back.

**A truncate puts the descriptor where the cut needs it first, and that is not
tidiness.** The truncate underneath the file service remembers where the
descriptor was, seeks to the new length, cuts the file, and seeks back to where
it was — and on this filesystem a seek past the end of a file that is open for
writing extends the file to that offset rather than stopping at the end. The
service seeks before every transfer and leaves the descriptor where the
transfer ended, so a program that reads near the end of a file and then cuts it
short would have the file re-grown to exactly its old length, with success
reported and the card unchanged. The layer therefore writes no bytes at the new
length before asking for the cut — the service has no seek of its own, so a
transfer is the only lever on the descriptor, and a write cannot be refused by a
handle that is open for writing. This is a defect in the layers below and it is
theirs to fix; both calls here are the service's own, in the order this board
needs them.

**`Erase` refuses a directory.** Unlink on this board is the card's own, which
removes an empty directory as readily as a file, and a Pascal program that
writes `Erase` means a file. So the layer asks about the name first and reports
"file not found" for a directory rather than removing it. That is the guard
Free Pascal's unix target makes, for the same reason and with the same number.
`RmDir` is how a directory goes.

**The working directory is one setting for the whole board.** It belongs to the
filesystem, which lives on the core that owns the card, so it is not per Pascal
thread and not per core: `ChDir` from any thread moves every thread, and the
host kernel's own file calls stand in the same directory afterwards. That is
the reach a working directory has in a Pascal program anywhere — it belongs to
the process rather than to a thread — with the host kernel inside the same
process here.

Nothing inside the guest can come between a change and the name that depends on
it. Nothing preempts a Pascal thread, and a service call blocks inside
`circle-libsdl2` without entering this library's scheduler, so no second Pascal
thread runs between one thread's `ChDir` and its next open. The host kernel is
the one thing outside that, and it shares the setting if it uses relative
names. A program that will not rely on either agreement gives absolute names,
which the setting does not affect.

**A host kernel has to bring the card up itself**, on core 0, before it
releases the application core — the EMMC device, the FAT mount, and the C
library's standard descriptors. Read `examples/m5/kernel.cpp` for the order and
why it is that order. The descriptors matter as much as the mount: the C
library hands out the lowest free one, and the Free Pascal runtime reads 0, 1
and 2 as the console, so a kernel that skips `CGlueStdioInit` gets a file whose
every write goes to the log with nothing saying so.

Nothing here uses the linker's `--wrap`. That is the pattern for an application
with no file layer of its own; this library is the file layer, so it points
itself at the file service directly.

## SysUtils, Classes, and TFileStream

**This is the layer a real Pascal program actually writes against**, and it is
built for this target: `SysUtils` carries `FileOpen`, `FileRead`, `FileSeek`,
`FindFirst`, `FileExists` and `DirectoryExists`; `Classes` carries
`TFileStream`, `TStringList`, `TList`, `TComponent` and `TThread`. `sysconst`,
`rtlconsts`, `types` and `typinfo` are built with them because those two are
declared in terms of them.

**Both file layers share one position table**, and that is the whole of what
the target had to add. The file service names an offset on every read and
write, so an open file's position lives on the Pascal side — and Pascal's own
`Reset` and `SysUtils`' `FileOpen` hand out the same descriptors. A second
table would give one descriptor two positions and make the right answer depend
on which layer touched it last. So the System unit exports the six operations
`SysUtils` needs — `CircleFileOpen`, `CircleFileClose`, `CircleFileRead`,
`CircleFileWrite`, `CircleFileSeek` and `CircleFileTruncate` — and there is one
table underneath all of it. `CircleOpenSearchCount` is `CircleOpenFileCount`'s
counterpart for directory searches.

**A search holds one of a fixed number of slots** until `FindClose` is called.
`TSearchRec` carries a single 32 bit handle with no room for the directory
handle, the pattern and the attribute filter beside it, so the handle is a slot
number. The pattern matcher is the target's own: `*` and `?`, case-insensitive,
because the card's filesystem does not tell two names apart by case alone.

**A directory entry on this card carries only its name.** The service reports
no type, size or timestamp with it, so the search asks about each name
separately — which is what Free Pascal's other directory-reading targets do,
for the same reason.

### What this board cannot answer, and how each one says so

None of these reports success. Each reports the failure `SysUtils` reports, and
says why in its own comment.

- `FileGetDate` and `FileSetDate` return -1: **the service answers about a
  name, and an open descriptor cannot be asked.** `FileAge` is the question
  that can be answered here, and it takes a name.
- `FileSetAttr` returns -1, and `FileGetAttr` reports only whether the name is
  a directory. The service carries no attribute bits.
- **A timestamp on this card is the epoch.** The C library's `stat` here fills
  in the size and whether the name is a directory and leaves the modification
  time at zero, so `FileAge` and `TSearchRec.Time` report what that says rather
  than a time invented to look plausible.
- `DiskFree` and `DiskSize` return -1: there is no free-space figure in the
  service.
- `ExecuteProcess` raises. There are no processes here, and a caller that
  ignored a -1 would carry on as though a program had run and failed.
- `GetEnvironmentVariable` returns an empty string, which is the true answer: a
  Circle kernel is loaded and started, not invoked with a set of variables.
- `FileExists` says **no** to a directory, deliberately. A program asking it is
  about to open the name, and a directory cannot be opened. `DirectoryExists`
  is the question for a directory.

`GetLastOSError` answers from what the file service last reported. This machine
has no errno the guest may read — the C library's is one variable shared by
every core, which is why the service returns a negated error number instead of
setting one — so each routine catches the number as it sees it, per Pascal
thread.

`TThread` is this library's scheduler with an object on top: `BeginThread`,
`SuspendThread`, `ResumeThread` and `WaitForThreadTerminate`, which are the
portable interface over the scheduler `examples/m4` proves. Nothing preempts,
so a thread created unsuspended is on the run list from the moment
`TThread.Create` returns but does not run until the thread that made it gives
the core away. Priorities are one value here, so `TThread.GetPriority` always
answers `tpNormal` and setting one changes nothing.

`examples/m6` is a Pascal program that proves all of this on the board, and its
host kernel walks the same directory from the core that owns the card to check
the guest's search against a count it made itself.

## The standard library

**A program is written in more than the runtime library**, and Free Pascal
keeps most of that in its packages. Those are built for this target: the whole
of `rtl-objpas` (`DateUtils`, `StrUtils`, `Variants`, `RTTI`, `FmtBCD` and the
rest), `fcl-base` (`IniFiles`, `contnrs`, `SyncObjs`, `CustApp`, `URIParser`,
the CSV and expression parsers), `rtl-generics` (`Generics.Collections`),
`fcl-stl`, `hash`, `paszlib`, `bzip2`, `fcl-json`, `fcl-xml`, `fcl-image` with
`pasjpeg` under it, `regexpr`, `libtar`, `unzip`, `symbolic`, `tplylib`, and
the machine-independent part of `rtl-extra` (`objects`, `matrix`, `ucomplex`,
`real48utils`).

Which packages build for a target is each package's own `fpmake.pp` to say,
and that is where this target is named. A package not named there is not built,
and a program that reaches for one of its units is told the unit cannot be
found — at compile time, on the development host, which is where a missing unit
should be found.

**What is not built is not built for a reason.** `rtl-console` has no `crt`,
`keyboard`, `video` or `mouse` for this machine, and the console belongs to
SDL here in any case; `fcl-process` needs processes and this machine runs one
program; `fcl-net` needs sockets; `fcl-registry` needs a registry; `fcl-res`
reads and writes the resource containers of executable formats, which this
target does not produce. Every binding to a shared library — `zlib`, `libpng`,
`sqlite`, `openssl`, `x11`, `gtk2` and the rest of that class — needs a library
this world does not carry and cannot load one at run time. The host tools
(`fppkg`, `fpmkunit`, `ide`, `fv`, `pastojs`, `webidl`, `fcl-passrc`) run on a
development machine rather than on a board.

**The runtime library gained units of its own** to carry those packages:
`math`, `fgl`, `charset`, `cpall` with the code page tables, `character`,
`unicodedata`, `unicodenumtable`, `fpwidestring` — and `Dos`.

### A program chooses its own wide string manager

**`uses fpwidestring` if the program cases a `UnicodeString`.** `UpperCase`
and `LowerCase` never needed it and never will: their `UnicodeString` forms are
`InternalChangeCase(S,['a'..'z'],±32)` in
`rtl/objpas/sysutils/sysuni.inc` — ASCII by definition, on every Free Pascal
target, and an accented letter comes back unchanged because that is what the
routine is for. `UnicodeUpperCase` and `UnicodeLowerCase` are the ones that
ask, through `widestringmanager.UpperUnicodeStringProc`.

Until a program elects a manager, that pointer is `StubUnicodeCase`, which
writes

```
This binary has no string conversion support compiled in.
Recompile the application with a unit that installs a unicodestring manager in the program uses clause.
```

to standard error and halts with runtime error 234. **So the failure is loud
and names its own cure** — nothing here silently returns the text it was
given.

A target with an operating system behind it elects a manager from the system.
This board has none to ask, so the answer is `fpwidestring`: pure Pascal over
the same Unicode tables the `Character` unit reads, installing itself in its
`initialization`, which runs only because the program named the unit. This is
Free Pascal's shape everywhere; a Unix program names `cwstring` for the same
reason.

It is not installed for every program on purpose. It pulls `unicodedata`'s
tables into the image, and a program that never touches a `UnicodeString`
should not carry them — and because the failure is a halt with a message
rather than a wrong answer, a program that needs it finds out.

### The Dos unit

Turbo Pascal's `Dos` unit is built for this target because Free Pascal's own
packages need it: `paszlib`'s `gzio` and the `unzip` package both call
`GetFAttr` on every target that is not Unix, and neither builds without it.

It is written over `SysUtils` rather than over the file service. Every routine
it offers already exists there, reaching the card through `circle-libsdl2` and
nothing else, so `Dos` here is a translation of Turbo Pascal's conventions — a
byte of attribute bits, a packed timestamp, `DosError` instead of an exception
— onto calls that were already made. It adds no crossing of its own.

Its `SearchRec` carries the `SysUtils` search that drives it, which is why the
record's layout is this target's own; every target declares its own for the
same reason. The name inside a file variable is **not** bytes here:
`TFileTextRecChar` is `UnicodeChar` on any target with wide strings, so
`GetFAttr`, `SetFAttr`, `GetFTime` and `SetFTime` convert it the way
`rtl/unix/dos.pp` does. Read as bytes a name yields its first character alone,
which is a real name that answers a plausible wrong attribute rather than an
error. What this board cannot answer, it refuses: `SetDate` and
`SetTime` report failure because nothing keeps a date here, `Exec` reports
failure because this machine runs one program, and `GetEnv` answers with
nothing because there is no environment.

## Elapsed time

**Time splits in two here, and the two halves are answered in different
places.** Elapsed time — how long something took, and how long to wait — is
the Arm generic timer's free-running counter, read directly. On this build
that counter is a processor system register, one per core, so the application
core reads it with an instruction: no device, no lock, no other core, and
therefore nothing to cross. Calendar time is the other half, and it goes through
`circle-libsdl2`: `SysUtils`' `Now`, `Date`, `Time` and `GetLocalTime` read it
through one call in `src/clock.cpp`, which is that library's replacement for
the C library's `_gettimeofday` and nothing else.

The System unit carries four routines for the first half.

- `CircleCounterFrequency` — how many ticks the counter counts in a second, as
  the firmware recorded it at boot. It is also the resolution: one tick is one
  part in this many of a second. Zero is a real answer and means the firmware
  left the register unset.
- `CircleCounter` — the counter itself, in its own ticks. It starts at zero
  when the board comes up and only goes forwards, and there are at least 56
  bits behind it, which at this rate is decades from wrapping.
- `CircleElapsedMicroseconds` — the same thing in microseconds.
- `CircleWaitMicroseconds` — wait for a stated length of time. The deadline is
  worked out once in ticks and the counter is read until it arrives; ticks are
  rounded up, so the wait is never short.

The counter reads themselves are three instructions in `src/counter.cpp`, and
all the arithmetic is on the Pascal side. A read is bracketed by an
instruction barrier, without which a timestamp can be taken before the work it
is meant to bracket has finished — so a read costs more than an unsynchronised
one would, and that cost sits inside every interval measured with it.

**A wait gives the core away.** The waiting loop's one non-arithmetic
statement services SDL and then hands the core to another Pascal thread, and
falls back on the processor's yield hint only when there is no other thread to
hand it to. The deadline is worked out before the loop and the counter read is
unchanged, so a wait that yields is exactly as long as one that did not, and
is never short.

`examples/m3` is a Pascal program that measures all of this on the board and
reports its own verdict, tolerance by tolerance, on the console.

## Threads

**A Pascal thread is this library's own, on the application core.** It creates
them, holds their stacks, and decides which one is running. Nothing about them
is visible outside that core: no Circle task is created, no other core is
involved, Circle is not told, and to the rest of the board the application
core is still one line of execution.

The guest is a computer with one core, and a computer with one core has always
run threads. So `TThreadManager` is filled in here rather than delegated
anywhere — thread lifecycle, critical sections, thread variables, and both
event families. `BeginThread`, `ThreadSwitch`, `EnterCriticalSection`,
`RTLEventWaitFor` and the rest are reached the way a program reaches them on
any other target.

Three things in Free Pascal's own runtime do most of the work.

- **Thread variables are already indirected.** Every access compiles to a call
  through one global function pointer, and this target's function answers from
  the running thread's own block. Switching threads is, in the main, changing
  the block it answers from. It is not built on the hardware thread pointer:
  that register belongs to `circle-libsdl2`, which sizes the block behind it
  from the C and C++ thread-local sections and arms it once per core, so it
  describes a core rather than a Pascal thread.
- **Per-thread exception state follows from that and needed nothing.** The
  exception address stack, the exception object stack and the try level are
  thread variables in the generic runtime, and `ThreadID`, `InOutRes` and the
  standard text files are in the same block. A thread with its own block has
  its own exception state, its own I/O result and its own standard files.
- **The context switch already existed.** `FPC_SETJMP` and `FPC_LONGJMP` save
  and restore the callee-saved registers and the stack pointer. A thread that
  has never run gets a jump buffer written out by hand instead of saved, with
  the new stack in it and the entry point in the link register — `FPC_LONGJMP`
  ends in a return through that register, so restoring such a buffer arrives
  at the entry point on the new stack. There is no assembly in the scheduler.

### Nothing preempts

**A Pascal thread that neither enters the runtime nor calls SDL holds the
application core until it stops.** There is no timer interrupt behind this
scheduler and there is nothing that can take the core away.

That is a property of the design, not a defect waiting for a fix. The only
thing that could preempt a thread here is another core, and another core is
outside the machine the guest can see — reaching for one would make the guest
a multi-core computer, which is the one thing it must not become.

What follows for a program written against it: **give the core up on purpose.**
Every path that can wait already does — a contended critical section, either
event family, an explicit `ThreadSwitch`, and every timed wait — and each of
them services SDL on the way, because SDL is the only thing the guest speaks
to and the audio callback runs from whatever calls into it. A thread that
computes in a tight loop with none of those in it is a thread that has taken
the machine, and that is visible as the rest of the program stopping.

### Stacks

A thread's stack is fixed when the thread is made, out of the heap, with
nothing between one stack and the next. `BeginThread` takes the size; the
short overloads pass Free Pascal's own `DefaultStackSize`, which is four
megabytes and is the generic runtime's constant rather than this target's.

**A stack that is too small does not announce itself**, so this runtime makes
it. Every stack is written with a pattern when the thread is made, the lowest
bytes of it are checked on every switch away from the thread and again when it
ends, and an overflow stops the program with the thread and its stack size
named. The same pattern is what `CircleThreadStackUsed` reads: it reports the
deepest the thread has ever been, which is the figure a stack size has to be
chosen against. A request below the runtime's own minimum is refused by
`BeginThread`, with a line on the console, rather than started.

### What the System unit will answer about a thread

`CircleThreadStackSize`, `CircleThreadStackUsed`, `CircleThreadCoreMask`,
`CircleThreadFirstCore`, `CircleThreadSwitches`, `CircleThreadName`,
`CircleThreadCount`, `CircleThreadVarBlockSize`, `CircleCurrentCore` and
`CircleGuestCore`. The core questions are not decoration: the runtime reads
the processor's own core number at every entry to the scheduler and at every
thread's first instruction, compares it with the core recorded before any
thread existed, and stops the program with both numbers if they differ.

`examples/m4` is a Pascal program that proves all of this on the board, and
its host kernel counts Circle's task list from the core that owns it,
throughout the run, to answer the half of the question the guest cannot.

## The heap

`TMemoryManager` is Circle's allocator. `AnsiString`, `UnicodeString`,
dynamic arrays, classes and `GetMem` all work, and so does raising an
exception, which builds an object and could not be done before there was
somewhere to build it.

**Memory is the one thing the application core reaches without crossing to
another core.** Every device on the board belongs to the core that owns it,
and a Pascal program reaches one only through `circle-libsdl2`. Circle's
allocator is different: it guards itself with a spin lock that holds across
cores, so an allocation made on the application core is safe as it stands.
The memory manager therefore calls `malloc` and its family directly. There is
no mailbox and no second core anywhere in the path a string takes.

Circle's own allocator is the whole of it. This library adds no allocator, no
pool and no arena, and it wraps only the two questions Free Pascal's memory
manager asks that C has no call for: the usable size of a block, and how much
of the heap has never been handed out. Both are in `src/heap.cpp`; read
`include/libfpc.h` for what each answers.

**The heap is fixed when the board comes up.** Circle sizes it from the
world's configuration and nothing grows it at run time, so a Pascal program
that runs out of memory has run out for good. Free Pascal's own answer to
that stands: `ReturnNilIfGrowHeapFails` decides whether the program is handed
a nil or stopped with run-time error 203.

### What `GetFPCHeapStatus` reports, and what it does not

Three figures, answering for two different things. Confusing them is easy and
gives a wrong answer that looks convincing.

- **`CurrHeapUsed` and `MaxHeapUsed` are the program's.** The memory manager
  counts what it hands out and what it takes back. A program that allocates
  and frees in balance returns `CurrHeapUsed` to exactly the value it started
  at, whatever else is happening on the board. **This is the figure to watch
  for a leak**, and it is exact.
- **`CurrHeapFree` is the whole board's.** There is one heap, every core
  allocates from it, and the core that owns the devices keeps allocating from
  it for as long as the board runs — USB plug-and-play and HID polling are on
  its service loop, on every lap. So this figure drifts downward under a
  Pascal program that is behaving perfectly, at a rate set by how long the
  program runs rather than by what it allocates. **It says whether memory is
  being reused; it does not say whether this program is leaking.**

Everything else in both records is a figure Circle's allocator does not keep,
and is reported as zero rather than estimated.

### Two properties of Circle's allocator to build around

Neither is a defect, and neither is this library's to change.

- **A block bigger than the largest bucket is never reused.** Circle returns a
  freed block to a free list only when its size matches one of its bucket
  sizes exactly, and the buckets stop at 512 KB. Anything above that is
  dropped on free and the space is gone for the life of the boot. On a heap
  that never grows, a program that repeatedly allocates and frees something
  very large will exhaust it.
- **A block is rounded up to its bucket, and the bucket sizes are far apart** —
  64 bytes, then 1 KB, 4 KB, 16 KB, 64 KB, 256 KB, 512 KB. An allocation of
  1025 bytes occupies 4 KB. `MemSize` reports the true bucket size rather than
  the size that was asked for, so Free Pascal grows a string inside its own
  block instead of copying it, but a program whose working sizes sit just
  above a bucket boundary pays four times over.

**Exception backtraces are off, deliberately.** Raising an exception in Free
Pascal collects a backtrace first, by walking the frame chain, and the walk is
bounded by a test against `StackTop` that will not hold for a Pascal thread
running on a stack this library allocated. Free Pascal 3.2.2 also returns the
wrong caller from the one routine that walk uses. The system unit sets
`RaiseMaxFrameCount` to zero, so the walk's loop body never runs and neither
problem can be reached. What is given up is backtraces, which carry no symbol
names on this target in any case.

`examples/m1` is a Pascal program that proves all of this on the board, and
reports its own verdict on the console.

## SDL from a Pascal program

A Pascal program reaches the display and the keyboard the same way a C one
does: through `circle-libsdl2`, calling SDL. Nothing in this library sits in
that path, and there is no Pascal graphics layer here to learn.

**The binding is not this project's.** A Pascal SDL program already carries
one — the SDL2-for-Pascal unit set, in one generation or another — and that is
the one to use, unchanged. A port to this board is then a relink rather than a
rewrite, which is the only arrangement in which porting an existing game means
anything. `patches/` carries the one hunk that binding needs to know this
target exists, and its README says what the hunk does and why the alternatives
do not work.

**Point `FPC_UNIT_SRC_DIRS` at the binding's source.** `fpc-app.mk` compiles
every unit it finds there beside the program and links their objects; read its
header for the whole of that. `examples/m8/Makefile` takes the binding's
directory as `SDL2_PASCAL_UNITS` and refuses to build without one.

**`units/sdl2circle.pas` is this library's own, and it is one unit.** It
declares the calls in `circle-libsdl2`'s `SDL_circle.h` that no SDL binding
carries, because they are not in SDL's headers — chiefly the virtual display
every application must declare before `SDL_Init`. An application names it
beside its binding, exactly as a C application adds one `#include`. It depends
on no binding and uses plain Free Pascal types, so it never argues with one
over a type name.

Only the application's half of that header is declared. A Circle host kernel
is C++ — there is no other kind — so the calls that arm a core, create the
servo or hand a core to presentation have no Pascal caller, and CLF-005 makes
giving the guest a way to reach them a non-conformance rather than a
convenience.

### The event record is shorter in Pascal than in C

SDL's `SDL_Event` is a union with a `padding` member that fixes it at 56 bytes
on a 64-bit machine, and a compile-time assertion in `SDL_events.h` holds it
there. Every entry point that fills an event writes that many bytes.

**The Pascal translations of that header carry the variants and not the
padding**, so `TSDL_Event` is as large as its largest declared variant and no
larger — which is smaller. Passing the address of a bare one to
`SDL_PollEvent` hands SDL a buffer shorter than the one it will fill. On a
desktop the overrun lands in another local; here it lands on a stack this
library allocated, and Circle lays the core stacks out with no guard page
between them.

So an event is passed through a variant record whose other arm is a byte array
past 56. `examples/m8` carries one and prints both sizes — its own and the C
one, which its host kernel prints from the compiler that built the library —
so the difference is on the log rather than in a comment.

## Status

The library reaches M1 and M2 on the board: a Pascal program links into a
Circle host kernel on the application core, the host kernel calls its entry
point, the program allocates out of Circle's heap, and what it writes reaches
the console through `circle-libsdl2`.

Elapsed time and timed waits are written and built, and `examples/m3` is the
image that puts them to the board. That image has not run there, so the
interface is implemented rather than proven — and a memory manager or a clock
that is merely linked proves nothing, which is the whole reason each example
reports its own verdict off the console.

The thread manager is written and built, and `examples/m4` is the image that
puts it to the board. That image has not run there either, and a thread
manager is the interface a clean link says least about: both records install
at run time and start as pointers that go nowhere, so a program that never
calls `BeginThread` links exactly as cleanly as one that does.

`KillThread` is not implemented and reports that it did nothing: stopping a
cooperative thread from outside means abandoning it wherever it happens to
be, and there is no unwinding here that could put that right. Thread
priorities are one value, so setting one reports that it was not set.

The file and directory layer is written and built, and `examples/m5` is the
image that puts it to the board. That image has not run there either. It works
under two directories of its own making, `/tmp-clf-m5` and `/tmp-clf-m5-gone`,
and touches nothing outside them: it removes the second itself, erases its own
files out of the first, and leaves one witness in it for the host kernel to
read back from the core that owns the card and then remove. It also leaves the
working directory inside `/tmp-clf-m5`, so the host kernel can read that on the
same core and see for itself where `ChDir` put it.

The `SysUtils` file family, `Classes` and `TFileStream` are written and built,
and `examples/m6` is the image that puts them to the board. That image has not
run there either. It works under one directory of its own making,
`/tmp-clf-m6`, and touches nothing outside it: it removes its own working files
and leaves a witness and the four files its directory search ran over, for the
host kernel to count on the core that owns the card and then remove.

Free Pascal's packages are built for the target, and `examples/m7` is the image
that puts them to the board. That image has not run there. It works under one
directory of its own making, `/tmp-clf-m7`, removes everything it wrote
including the directory, and the host kernel then looks at the card itself, on
the core that owns it, to see whether that is true. Every section of it runs a
known answer through a unit and compares — a published digest, a round trip
through its own bytes, a date the calendar fixes — because a unit that compiles
and then faults looks identical from the development host.

SDL is written and built, and `examples/m8` is the image that puts it to the
board. That image has not run there. It declares a virtual display of its own
that matches nothing on the board, makes a window, a renderer and textures in
three formats, draws through every path the library offers, and then reads its
own frames back with `SDL_RenderReadPixels` — which returns SDL's framebuffer
in the coordinates the caller drew in — and compares them against what it drew,
pixel by pixel, printing the tolerance beside each verdict. It opens no file
and leaves nothing on the card.

The event queue is proved as far as it can be with nobody at the bench: that
the subsystem comes up, that a poll with nothing pending answers so, that an
event pushed in comes back out with every field intact, and that scancode and
keycode remain each other's inverse across the whole table. A key press cannot
be manufactured, so the program watches for one for ten seconds, reports
whatever arrived, and treats an empty watch as the expected answer.

There is no console input through the Free Pascal runtime, so `ReadLn` does not
work yet. That is a separate question from SDL's keyboard, which does.
