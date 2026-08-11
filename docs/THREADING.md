# Threading

Free Pascal's runtime does not call Circle. It calls `CurrentTM`, a record of
function pointers, and this library fills that record with routines forwarding
to C wrappers in `src/sched.cpp`. The Pascal side is `rtl/clfthreads.pp`.
Circle is C++ and Free Pascal calls C, so nothing C++ reaches Pascal.

## The runtime has to be built for it

The `aarch64-embedded` runtime's THREADING feature is **off** in its stock build
configuration: `rtl/embedded/system.cfg` comments it out for AArch64. On a
runtime built that way a single `threadvar` declaration is a fatal compile
error, never mind `BeginThread`.

Turning it on cannot be done from outside the vendored tree.
`rtl/embedded/Makefile` appends `@system.cfg` to the compiler's options and
`system.cfg`'s first directive is `-Sf-`, which turns every feature off again;
a response file supplied on the command line lands before that and is undone by
it, and there is no hook after it. A separate runtime tree carrying that
one-line difference is the nearest thing that works, and that tree is what
`FPCRTL` must point at.

## A Pascal thread runs on a core of its own

**It is not a Circle task.** Circle's cooperative scheduler is specified as
belonging to core 0 alone, and a `CTask` registers itself with that scheduler
while it is being constructed, so a task can only ever run where the scheduler
is. Everything hung off a task went with it: the thread's identity, the
runtime's threadvar block, and the stack an exception frame walk is bounded by.

So a thread here is a record this library owns, and a core a host kernel has
**lent** runs it directly. One thread at a time on that core, for as long as
that thread lives.

A host kernel starts its own secondary cores and decides what each one is for.
This library never starts a core and never chooses one:

```c
void CMyCores::Run (unsigned nCore)
{
    switch (nCore)
    {
    case 1:  FPCCircle_ThreadCoreOffer (); break;   // never returns
    default: for (;;) asm volatile ("wfe"); break;  // parked
    }
}
```

A core that is given no role must be parked. Returning from a dispatch function
lets the core run on into whatever code follows it.

**Without a lent core there are no Pascal threads at all.** `BeginThread`
returns 0 and says why. There is no fallback onto core 0, because that fallback
was the task.

### Where a particular thread goes

`FPCCircle_ThreadPinNext` — `CLFPinNextThread` on the Pascal side — places the
next thread the calling core creates on a named core. It is a one-shot request,
consumed by the next creation.

A creation with no request pending takes the lowest free lent core. That is not
a convenience: a thread is created several frames below any code that could
have asked for a core — `TThread.Create` reaches `BeginThread` through the
runtime — so a model that only placed threads on request would place almost
none of them.

`FPCCircle_ThreadCoresFree` answers with the cores available right now, as a
bitmask. A core that was never lent is not in it, and neither is one already
running a thread.

## What follows from having no scheduler

**One wait, everywhere.** Every blocking loop in this library is one call in a
loop and nothing else: on core 0 it yields to Circle's scheduler, so whatever
holds the thing being waited for can run; on any other core it is the
processor's yield hint, because there is no scheduler there to hand the time
to.

**Locks and events are not Circle's.** `CMutex` and `CSynchronizationEvent` are
scheduler objects — acquiring one off core 0 blocks a task the calling core is
not running. Both are rebuilt from processor atomics and the wait above, so
they exclude between cores. The lock is recursive and owned by an identity
rather than by a task, so the owner does not move under a holder that is simply
getting on with its work. Events are manual reset, which is what the object
they replace did: a wait on an event that is already set returns at once, and a
set stays set until something clears it.

**A wait occupies the core it waits on.** Off core 0 there is nothing to sleep
on, so a blocked thread is a spinning core.

**A timed wait is untimed.** `RTLEventWaitForTimeout` and `BasicEventWaitFor`
ignore their timeout and wait without limit, so `TEvent.WaitFor(n)` can never
return `wrTimeout`. Code that uses a timeout as a watchdog against a signal that
never arrives does not recover here.

## Thread-local storage

The runtime keeps every `threadvar` of every unit in one flat block per thread.
`InitThreadVar` hands out offsets into it, `AllocateThreadVars` makes the block,
and `RelocateThreadVar` turns an offset into an address.

The block is kept in the thread's own record, found through the core that is
running it. A core running no thread of ours — the one a host kernel called
`PASCALMAIN` on — keeps its block in a record of its own, so the main thread
needs no special case and nothing asks a scheduler which task is current.

Allocating that block calls `GetMem`, and that is only safe because neither
`heapmgr` nor the lock around it declares a `threadvar` of its own. A heap that
did would recurse forever on the first threadvar access.

## The heap has a lock

`heapmgr` walks a free list with no lock. That was safe only while every line of
Pascal in the image ran on one core: Circle's scheduler is cooperative, no
`heapmgr` path yields, so the free list was walked atomically by construction.

Two cores allocating at once is exactly what this model makes ordinary, so
`clfthreads` wraps the memory manager. The six handlers that touch the free list
take a recursive lock; the rest of the record is the one `heapmgr` installed.
The lock lives in C in static storage, so taking it allocates nothing — it is
the one lock in the system that must never need the heap it protects.

## Ending a thread

A thread that returns from its body hands its result to whoever joins it. A
thread that ends itself through `EndThread` has no frame to return through — it
is a plain call on the lent core's stack, with no task to terminate — so it
returns to the core's own loop with `longjmp`. That is where `setjmp` and
`longjmp` appear in this library's undefined-symbol residue.

`WaitForThreadTerminate` ignores its timeout and waits without limit. Circle can
wait with a timeout, but a join that silently returned early would be worse than
one that is honest about having a single behaviour.

## A thread owns no hardware

A thread must not touch a device. A console is a device, a device belongs to
core 0, and a Pascal thread runs on a core that is not core 0 — so a write to
one from a thread is a cross-core hardware access with nothing serialising it
against core 0 doing the same.

Nothing in this library gives a thread the means to. Everything a Pascal program
prints goes out through circle-libsdl2, which carries a line from whatever core
produced it; and in an image that does not link circle-libsdl2, a thread's line
goes into a ring for core 0 to carry to the host's own logger. See
`src/log.cpp`.

## What Circle's scheduler had and this does not

Suspend, resume, kill and thread priorities. A thread here is a line of
execution on a core of its own with nothing above it to stop, restart or rank
it. The record's fields are filled with routines that do nothing and say so by
their return value, because the runtime calls those fields without checking
them for nil.

## The limits, plainly

- **One thread per lent core.** The number of Pascal threads that can run at
  once is the number of cores a host kernel gave away — on a four-core board, at
  most three, and fewer if the host wants a core for anything else.
- **A blocked thread spins.** See the wait, above.
- **No timed wait is timed.** See the events, above.

## The host kernel owes the scheduler nothing

A `CScheduler` is no longer required. Nothing in this model is a task, and the
only use this library makes of one is to hand core 0's waiting time back to a
host that has other work to do. A kernel without one still runs Pascal threads;
core 0 spins instead of yielding while it waits.

`CTimer` is likewise the host's own business now, rather than something the
scheduler forced on it — though the fallback log drain reads the free-running
counter, which needs no timer instance.

## `StackTop` and the exception frame walk

This is a residual risk worth understanding before writing a program that
raises on a thread.

The frame walk in the generic runtime's `rtl/inc/except.inc` bounds itself by
checking that each frame address is greater than the last and below
`System.StackTop`. On `aarch64-embedded`, `StackTop` resolves to the address of
`_stack_top` — one link-time symbol, not a per-thread value. Enabling threading
does not change that: disassembling `SYSTEM_$$_STACKTOP$$POINTER` in both
runtimes gives the same GOT load of `_stack_top` in each. There is no
per-thread `StackTop` to be had.

So what a raise on a thread's stack does depends on which side of `_stack_top`
that stack lies. A thread runs on the lent core's own kernel stack, and Circle
lays the core stacks one after another **above** the address `_stack_top` names
— core *n*'s top is `MEM_KERNEL_STACK + n * KERNEL_STACK_SIZE`. So a thread
stack lies above `_stack_top`, `frame < StackTop` is false on the very first
iteration, and the walk stops immediately. It collects no frames and it cannot
run away.

That is the opposite of the feared failure. The danger was always a thread stack
*below* `_stack_top`, where the upper bound would be useless; here the wrong
`StackTop` makes the bound too tight rather than too loose, and the cost is
exception backtraces that nobody can read without a symbol table anyway.

**It is a property of the memory map, not a guarantee.** Verify it rather than
assume it. `clfthreads` exports the two functions that let a program check its
own geometry:

```pascal
function CLFRealStackTop: PtrUInt;
function CLFRealStackSize: PtrUInt;
```

Where the arithmetic does not come out that way, `RaiseMaxFrameCount` — a
writable typed constant in the System unit, not a runtime edit — set to zero
disables the frame walk for the cost of backtraces.
