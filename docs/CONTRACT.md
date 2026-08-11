# The contract

What a Free Pascal object compiled for `aarch64-embedded` asks of the world it
is linked into, what this library answers, and what is not answered yet.

## The two symbols

A Pascal object compiled for this target leaves exactly two symbols undefined,
whatever the program does. This was measured across plain code, `AnsiString`,
dynamic arrays, classes, `Writeln`, typed files, `SysUtils` and `raise`.

| Symbol | What it is |
|---|---|
| `_haltproc` | a `cdecl` procedure that must not return. The System unit calls it to end the program. |
| `_stack_top` | an **address**, not a value. `System.StackTop` returns the address of this symbol. |

This library defines both. `_haltproc` reports through the log and halts the
core. `_stack_top` is an absolute symbol equal to Circle's `MEM_KERNEL_STACK` —
the top of core 0's kernel stack, which is where a host kernel calls
`PASCALMAIN` from.

`_stack_top` lives in its own archive member on purpose. A host kernel that
runs Pascal on some other stack defines `_stack_top` in one of its own objects
instead, and the linker prefers that: an object linked directly into a kernel
is taken before an archive member of the same name. Nothing has to be removed
and nothing here has to change.

Everything else the runtime needs — the heap block, the stack length, the
initialisation and finalisation tables, the thread-var and resource-string
tables, and `PASCALMAIN` itself — the compiler emits into the program object.

## The two run-time installations

This is the part a link cannot check, and it is where a first boot is lost.

**The memory manager is nil.** `FPC_SYSTEM_MEMORYMANAGER` in this target's
`system.o` is a 0x60-byte `.data` record with no relocations at all: every
function pointer in it is zero. `GetMem` loads its handler out of that record
and branches, so the first allocation in a program that has not installed a
manager is a branch to address 0 — and the first `AnsiString` assignment is an
allocation. Nothing warns: the object links clean and the undefined residue is
still exactly the two symbols above.

`IsMemoryManagerSet` cannot tell you either. On this target it is a stub that
compiles to `mov w0, wzr; ret`, because `rtl/embedded/system.pp` defines both
`HAS_MEMORYMANAGER` and `FPC_NO_DEFAULT_HEAP` and `rtl/inc/heap.inc` returns
false outright when either is set. The question worth asking on this target is
never "was a manager installed" but "does the record hold real addresses",
because the failure mode is a branch through a nil field rather than a flag
being false.

The fix is one unit: `heapmgr`, whose initialization section calls
`SetMemoryManager` and hands the compiler-emitted `__fpc_initialheap` block to
the allocator.

**The thread manager is a set of error handlers.** With the THREADING feature
enabled, `CurrentTM` starts as the runtime's `NoThreadManager`, whose every
handler reports a runtime error. It is a `.data` record, not a set of undefined
symbols, so again the link says nothing. Enabling threading adds **nothing** to
the undefined-symbol contract — measured by compiling one program against both
runtimes and diffing the residue.

The fix is this library's `clfthreads` unit, whose initialization section calls
`SetThreadManager`.

**Use the `circlefpc` unit and both are handled.** It pulls in `heapmgr` and
then `clfthreads`, in that order, so the heap exists before the thread manager
allocates:

```pascal
program myapp;
uses circlefpc;
```

Verify it in the linked image rather than trusting it. `FPC_INIT_FUNC_TABLE`
must call `HEAPMGR_$$_init$` before `CLFTHREADS_$$_init$`:

```sh
awk '/<FPC_INIT_FUNC_TABLE>:/{f=1} f{print} f&&/ret$/{exit}' kernel-myapp.lst
```

## How a Pascal program declares a C function

One form works on this target and one form is fatal, and the difference is not
a style preference.

```pascal
{ Works. The symbol is resolved by the final link against Circle. }
procedure clf_puts(s: PChar); cdecl; external name 'clf_puts';

{ Fatal. }
function SDL_GetTicks: UInt32; cdecl; external 'libSDL2' name 'SDL_GetTicks';
```

Naming a library makes the declaration a dynamic import, and the compiler ends
the unit with `Error: Creation of Dynamic/Shared Libraries not supported`. The
message is attached to the end of the file rather than to the declaration that
caused it, because the compiler runs that check once after the whole unit has
parsed — so a unit with hundreds of such declarations reports one error naming
none of them.

This is why an existing set of Pascal bindings written for a desktop shared
library cannot be reused here as it stands, however the library name is
configured: every declaration has to lose its library name so that the symbol
is resolved by the static link, exactly as `_haltproc` and `_stack_top` are.

## Unit initialisation is not compiled out

`rtl/embedded/system.cfg` leaves `-SfINITFINAL` commented out, which reads like
unit initialisation being absent from this target. It is not. The compiler
emits `bl FPC_INIT_FUNC_TABLE` at the top of `PASCALMAIN` whenever a used unit
has an initialization section, and omits the call when none does. A program
whose `PASCALMAIN` starts straight into the program body is therefore not
evidence of a broken target — it is evidence that nothing it uses needs
initialising.

## Two more traps, both handled by `fpc-app.mk`

**`ppas.sh` runs from the compiler's working directory**, not from the output
directory. Its paths are relative to where the compiler ran, so running it from
inside `-FE` fails with "can't create out/x.o: No such file or directory",
which reads as a permissions or a toolchain fault.

**The compiler emits a global `main`.** It sits at the same address as
`PASCALMAIN` and does nothing extra, but Circle's own `main` has that name and
the two collide at link. `objcopy --localize-symbol=main` on the folded blob
object settles it; a host kernel calls `PASCALMAIN` directly.

## The runtime interfaces this library implements

| Interface | State |
|---|---|
| Startup and halt | implemented |
| `TMemoryManager` — eleven fields | implemented, by `heapmgr` over the compiler-emitted block |
| Console **output** | implemented — `clf_write` and `clf_puts`, out through circle-libsdl2 or, without it, the host's own `CLogger`. This library holds no device. |
| Console **input** | not implemented |
| `Writeln` as a Text file | **not wired.** `circlefpc`'s console routines write bytes; nothing binds the runtime's `Output` to them yet |
| `sysfile.inc` — open, close, read, write, seek, truncate | not implemented |
| `sysdir.inc` | not implemented |
| Time | not implemented |
| `TThreadManager` | implemented — see [Threading](THREADING.md) |
| Synchronous exception vectors | Circle's own; nothing is routed into Pascal |

The heap is fixed at build time by `FPC_HEAP_SIZE` and there is no growth at
run time.
