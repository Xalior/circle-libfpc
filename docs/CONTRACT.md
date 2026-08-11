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

`GetHeapStatus` and `GetFPCHeapStatus` cannot tell you anything either, and for
the same family of reason. `rtl/embedded/heapmgr.pp` implements both as
`FillChar(Result, SizeOf(Result), 0)`, with the comment "avoid that programs
crash due to a heap status request". So a program asking how much heap it has
used is answered with zeros, and those zeros are correct behaviour rather than
a symptom of anything. **There is no heap accounting on this target.** Code
that logs heap usage, or decides anything from it, silently decides from zero.

The fix is one unit: `heapmgr`, whose initialization section calls
`SetMemoryManager` and hands the compiler-emitted `__fpc_initialheap` block to
the allocator.

### The allocator overruns a smallest-size block on 64-bit

**This is a defect in the runtime this library builds against, not in this
library, and it is not patched here.** It is stated because a program on this
target will hit it and the symptom points nowhere near the cause.

`rtl/embedded/heapmgr.pp` sets `MinBlock = 16`, while its own free-list node is
24 bytes on a 64-bit target:

```pascal
THeapBlock = record
  Size: ptruint;      // offset 0
  Next: PHeapBlock;   // offset 8
  EndAddr: pointer;   // offset 16..23
end;
```

`InternalFreeMem` writes all three fields whatever size it was handed, so
returning a 16-byte block writes eight bytes past the end of it, into whatever
is next — normally a live allocation. Three paths reach it with exactly 16:
`SysFreeMem`, which clamps its size up to `MinBlock`; `SysGetMem`'s split,
which accepts a remainder of exactly `MinBlock`; and `GetAlignedMem`, which
frees its alignment gap. On a 32-bit target the node is 12 bytes and 16 is
safe, which is where the constant came from.

**The damage is silent and it surfaces somewhere else.** The eight bytes are
traded with a neighbouring allocation, so either the neighbour is spoiled or
the free block's own `Next` is overwritten by the neighbour's data. Nothing
fails at the moment of the overrun. The next walk of the free list loads
whatever the neighbour happened to hold and follows it as a pointer, so the
fault lands in `SysGetMem` or `InternalFreeMem` at an address made of the
neighbour's data — and the offending code is long gone.

**A uniform-size allocation test cannot find this, by construction.** Allocate
and free the same few sizes and the splits come out even, no 16-byte remainder
is ever produced, and the heap looks perfect for as long as you care to run it.
It takes MIXED sizes. A test that allocates 64 bytes ten thousand times proves
nothing about it.

**No wrapper around `heapmgr` can help**, because `MinBlock` governs splits
inside it and a wrapper sits outside. The one-line correction — `MinBlock` at
least `SizeOf(THeapBlock)` — belongs in the runtime source, which is upstream's.

**Replacing `heapmgr` is a different matter, and it is available.** The memory
manager is an installable interface on this target — that is the whole premise
of the two-symbol contract above — so a library may install handlers of its
own over the world's allocator rather than wrap the runtime's. That would end
this defect, and the need for a lock around the runtime's allocator, in one
move. It is a decision with costs of its own, and it has not been taken. Do not
read this section as the project waiting on upstream.

`examples/minblock/` demonstrates both paths in a single-core program with no
threads and no scheduler.

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

## `DynLibs` exists here, and it always says no

Loading a library at run time is the same absent facility seen from the other
side, and Free Pascal's `DynLibs` unit does not exist for this target at all.
`rtl/inc/dynlibs.pas` forwards every routine to the identically named routine in
the System unit, each operating system fills those in from its own
`rtl/<os>/dynlibs.inc`, and there is no `rtl/embedded/dynlibs.inc` — so the
`aarch64-embedded` System unit declares neither `TLibHandle` nor `NilHandle` nor
`LoadLibrary`, and a program that names `DynLibs` fails to compile.

That is not a missing build. There is no loader, no search path and no run-time
relocation on bare metal, so there is nothing to implement.

What there is, is a common shape of application code that asks for an optional
library and does without it when the answer is no:

```pascal
SoundEnabled := LoadLibrary(libname) <> NilHandle;
```

Code written that way needs an answer rather than an absence: with the unit
missing it does not compile, and with the unit present it takes its own
no-library path and carries on. So `rtl/dynlibs.pp` supplies the whole `DynLibs`
interface — the two `LoadLibrary` overloads and the two `SafeLoadLibrary` ones,
`GetProcedureAddress`, `UnloadLibrary`, `GetLoadErrorStr`, the Kylix and Delphi
spellings `FreeLibrary` and `GetProcAddress`, `TLibHandle`, `HModule`,
`NilHandle` and `SharedSuffix` — and answers no to all of it. `LoadLibrary`
returns `NilHandle`, every address lookup returns nil, unloading fails because
nothing was loaded, and `SharedSuffix` is empty because no file extension here
names anything.

This is final rather than provisional. Anything that needs code from a library
on this target links that code into the image.

Nothing pulls the unit in — `circlefpc` does not, because it installs run-time
interfaces and this installs none. It sits on the unit path `fpc-app.mk` already
sets up, and is compiled only when a program says `uses DynLibs`.

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
| `DynLibs` | supplied by `rtl/dynlibs.pp`, and every routine in it fails. There is no loader on this target to implement |
| Synchronous exception vectors | Circle's own; nothing is routed into Pascal |

The heap is fixed at build time by `FPC_HEAP_SIZE` and there is no growth at
run time.
