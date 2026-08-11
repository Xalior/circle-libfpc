# The Free Pascal packages

Free Pascal is the compiler, the runtime library, and then a large collection of
**packages** — units that are not part of the RTL and are shipped as source
alongside it. `SyncObjs`, `Generics.Collections`, `StrUtils` and `fcl-image` are
four of them, and a program for `aarch64-embedded` is told none of them exist.

## Why they are missing, and why that is not a target limitation

The cross-compiler for this target is installed with `make buildbase` followed
by `make installbase`. Those two targets build the compiler and the RTL and
**never enter `packages/`**. So the packages were never rejected by this target;
they were never offered to it. Nothing in any of the four is target-specific:
they are algorithm and container code over `SysUtils` and `Classes`, which the
embedded RTL already has.

All four build for `aarch64-embedded` from unmodified Free Pascal source, and a
program that uses all four at once still leaves exactly `_haltproc` and
`_stack_top` for the linker. The full closure is sixty-nine units, because the
four pull in `DateUtils`, `system.timespan`, `Rtti`, `Variants`, `VarUtils`,
`paszlib` and `pasjpeg` behind them.

## Building them

```sh
./build-packages.sh
```

from the top of this library. It writes one flat unit directory beside the
compiler's own trees, at
`<fpc trees>/fpc-packages-embedded/units/aarch64-embedded`, and it writes
nothing into the Free Pascal source tree. The packages' own makefiles are not
used: they build a package at a time into the source tree, and the compiler
resolves dependencies from source paths on its own, so naming the ten units an
application asks for by name is enough to bring the other fifty-nine with them.

`fpc-app.mk` finds that directory the same way it finds the RTL, through
`RAPI_FPC_DIR` or a `toolchains/` directory beside, above, or two above the
library. A program that uses none of the packages needs none of this, so a
missing directory is not an error — it becomes "Can't find unit SyncObjs" at
the point a program asks for one.

## What each one costs at run time

Nothing in any of the four calls the operating system in its own right. What
they do call is the runtime's installable interfaces, which is to say this
library. The consequences are all in the same place: the thread manager.

### SyncObjs

`TCriticalSection` resolves to `System.InitCriticalSection` and friends;
`TEvent` resolves to `BasicEventCreate`/`BasicEventWaitFor`. Both are thread
manager entries, and this library fills both. Neither is a Circle scheduler
object: a Pascal thread runs on a core of its own, which has no scheduler to
block on, so both are built from processor atomics. Two limits come with that,
and neither is visible at compile time:

- **A timed wait is not timed.** `BasicEventWaitFor` ignores its timeout and
  waits without limit, so `TEvent.WaitFor(n)` never returns `wrTimeout`. Code
  that uses a timeout as a watchdog against a signal that never arrives does not
  recover here — it blocks. Waiting on an event nothing is going to signal is a
  hang, not a slow return.
- **Auto-reset is not honoured.** `TEvent.Create` takes `AManualReset`, and
  every event this library makes is manual reset: a wait does not clear the
  event's state. An auto-reset `TEvent` therefore behaves as a manual-reset
  one, and the second waiter through an event that nobody cleared is let
  straight past. Code that relies on auto-reset to hand a signal to exactly one
  waiter does not get that here.

Both limits have the same practical consequence, and it is worth stating on its
own: **a wait on this target cannot be bounded through the API**. Code that
waits on another thread should watch a plain flag the worker sets last, spinning
a counted number of `ThreadSwitch` yields, and call `WaitFor` only once that
flag says the event is already signalled. `examples/packages` does that in every
rung that waits, and it is why a refused `BeginThread` there is a printed
failure rather than a board that stops with no diagnosis.

`TSemaphore` and `TMutex` are a different case: `SyncObjs` itself has no
implementation for a target that is neither Windows, Unix nor WebAssembly, and
its constructors raise `ESyncObjectException` by design. That is upstream's
decision, not this library's, and it is honest — it fails at construction rather
than silently doing nothing.

### Generics.Collections

Containers over `SysUtils` and `Classes`, plus `Generics.Defaults`, which builds
its default comparers out of `Rtti` — so this package brings the whole of
`Rtti`, `Variants` and `VarUtils` into an image with it. No thread manager
dependency and no run-time surprises.

### StrUtils

Pure string algorithms — but a handful of them reach `SysUtils`' case-folding
routines, and those go through a record this target never fills. See **The
widestring manager** below. `AnsiContainsText`, `AnsiProperCase`, `IsWild` and
`StringsReplace` are the ones in this package that do.

## The widestring manager — the third empty record

This target has three records whose fields are function pointers installed at
run time, all three of which the linker is content to leave empty. Two are
already documented: the memory manager, filled by `heapmgr`, and the thread
manager, filled by `clfthreads`. The third is `widestringmanager`
(`rtl/inc/ustringh.inc`), and **nothing in Free Pascal's own runtime fills it
for this target**:

- `rtl/embedded/system.pp` ends with `initunicodestringmanager` commented out,
  under the very `$ifdef FPC_HAS_FEATURE_WIDESTRINGS` that is enabled for
  aarch64;
- `rtl/embedded/sysutils.pp`'s initialization section calls `InitExceptions`
  and nothing else. Ten other targets' `sysutils.pp` call
  `InitInternationalGeneric`, which is what fills the ansistring half of the
  record. This one does not.

So every field stays nil, and each of these is a branch through address zero:

    AnsiUpperCase   AnsiLowerCase    AnsiCompareStr   AnsiCompareText
    AnsiStrComp     AnsiStrIComp     AnsiStrLComp     AnsiStrLIComp
    AnsiStrLower    AnsiStrUpper     StrCharLength

together with every `WideString` and `UnicodeString` equivalent,
`Generics.Defaults`' string comparers, and `Variants`' comparison.

There is no warning and there is no fault message. A Circle kernel with no
`CExceptionHandler` instance answers the resulting abort with a second fault
inside the fault handler, so on a serial capture the program simply stops
between two lines.

`clfstrings` fills the record, and `circlefpc` pulls it in after `heapmgr` and
`clfthreads`. What it installs is ASCII: `a`..`z` and `A`..`Z` fold into each
other, every other byte is left alone and compared by value, and conversion
between narrow and wide widens and narrows one byte at a time. That is not an
invention — it is what Free Pascal installs on any target with no operating
system collation to ask. It is also not a locale, and it is wrong for a
multi-byte code page. An application that needs more can install its own
manager over it: `SetWideStringManager` is public and the later call wins.

A host kernel that wants a fault to say so rather than stop silently needs a
`CExceptionHandler` and a `CLogger` pointed at its serial device.
`examples/packages/kernel.h` shows both, and the example ends with a
deliberate fault to prove they work.

### fcl-image

`FPImage` plus its readers and writers. The PNG pair pulls in `paszlib` for
deflate and inflate; the JPEG reader pulls in `pasjpeg`. `paszlib`'s one
OS-conditional file, `gzio.pas`, takes its non-Unix branch and uses `Dos`, which
this target's RTL has.

Two practical limits:

- **Every image goes through a stream, and on this target that stream must be a
  memory stream.** `TFileStream` has nothing underneath it: it calls
  `SysUtils`'s `FileOpen`, `FileCreate`, `FileRead`, `FileWrite`, `FileSeek`
  and `FileClose`, and `rtl/embedded/sysutils.pp` hard-codes that whole family
  to report failure, with no installable hook of any kind on it. The twelve
  `rtl_do_*` file hooks are unassigned too, but that is a different gap —
  they serve only the System unit's typed and untyped `File` I/O, which
  `TFileStream` never goes near.
- **The decoders want heap.** Deflate takes a window, a hash table and an output
  buffer; the JPEG decoder builds component and coefficient buffers. The heap is
  a fixed BSS block sized at build time with `FPC_HEAP_SIZE` and it does not
  grow, so an image size that works has to be paid for at link time.

And one that is not this package's fault but which this package is the most
likely thing to expose. `fcl-image`'s decoders are the heaviest mixed-size
allocator anything here runs, and mixed sizes are exactly what the allocator
defect in [the contract](CONTRACT.md) needs — a PNG round trip was the first
thing to meet it. Nothing about that is specific to images; it is simply the
workload that finds it first.

**It is not true that the only remedy is upstream's.** No wrapper *around*
heapmgr can help, because `MinBlock` governs splits inside it. But the memory
manager is an installable interface on this target, so a library may **replace**
heapmgr rather than wrap it — `SetMemoryManager` with handlers over the
circle-stdlib world's own allocator, which is already linked into every image
here and is spinlock-guarded across cores. That would end both this defect and
the need for a separate heap lock. It is a real route and a real decision, and
it has not been taken: recorded here so that the next person weighing it knows
the option exists rather than assuming the project is blocked on upstream.

## Proving it on the board

`examples/packages/` is a bootable kernel that runs all four, one rung at a
time, and reports each: a critical section under contention from a thread on a
lent core, an event handshake between core 0 and that thread, a dictionary of
two hundred entries enumerated and searched by a key built at run time, the
`StrUtils` functions, a BMP and a PNG written and read straight back through a
`TMemoryStream`, and a JPEG and a GIF decoded from pictures made off the board
and carried in the image as byte arrays.

Its host kernel lends core 1 with `FPCCircle_ThreadCoreOffer` and parks cores 2
and 3. It also carries a `CExceptionHandler`, which a host kernel needs if a
fault is to say so: Circle's AArch64 stub calls `CExceptionHandler::Get()` and
dereferences the null it returns when no handler exists, so a kernel without one
answers a fault with a second fault and stops in silence.

The first rung is the widestring-manager probe, made before the program has
created any thread. The last is the auto-reset probe, which runs on the lent
core while core 0 watches a counted flag — so an auto-reset that turns out to be
honoured is a result the board prints rather than a wait it never comes back
from. After that, and after the program has said it is complete, it stores to
address zero on purpose, to prove the fault path reports.
