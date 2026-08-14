# Threads

**A Pascal thread is this library's own, on the application core.** It creates
them, holds their stacks, and decides which one is running. Nothing about them
is visible outside that core: no Circle task is created, no other core is
involved, Circle is not told, and to the rest of the board the application
core is still one line of execution.

The guest is a computer with one core, and a computer with one core has always
run threads. So `TThreadManager` is filled in here rather than delegated
anywhere - thread lifecycle, critical sections, thread variables, and both
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
  the new stack in it and the entry point in the link register - `FPC_LONGJMP`
  ends in a return through that register, so restoring such a buffer arrives
  at the entry point on the new stack. There is no assembly in the scheduler.

## Nothing preempts

**A Pascal thread that neither enters the runtime nor calls SDL holds the
application core until it stops.** There is no timer interrupt behind this
scheduler and there is nothing that can take the core away.

The only thing that could preempt a thread here is another core, and another
core is outside the machine the guest can see: reaching for one would make
the guest a multi-core computer.

What follows for a program written against it: **give the core up on purpose.**
Every path that can wait already does - a contended critical section, either
event family, an explicit `ThreadSwitch`, and every timed wait - and each of
them services SDL on the way, because SDL is the only thing the guest speaks
to and the audio callback runs from whatever calls into it. A thread that
computes in a tight loop with none of those in it is a thread that has taken
the machine, and that is visible as the rest of the program stopping.

## Stacks

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

## What the System unit will answer about a thread

`CircleThreadStackSize`, `CircleThreadStackUsed`, `CircleThreadCoreMask`,
`CircleThreadFirstCore`, `CircleThreadSwitches`, `CircleThreadName`,
`CircleThreadCount`, `CircleThreadVarBlockSize`, `CircleCurrentCore` and
`CircleGuestCore`. The core questions are not decoration: the runtime reads
the processor's own core number at every entry to the scheduler and at every
thread's first instruction, compares it with the core recorded before any
thread existed, and stops the program with both numbers if they differ.
