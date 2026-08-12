//
// counter.cpp — the free-running counter, which is where elapsed time comes
// from on this board.
//
// TIME SPLITS IN TWO, AND ONLY ONE HALF IS HERE. Calendar time — the date and
// time a saved file is stamped with — is Circle's timer object, and a Circle
// object is a device, so it belongs to the core that owns the devices and the
// guest reaches it through circle-libsdl2. Elapsed time is different: the
// counter it is read from is a processor system register on this build, one
// per core, and reading it is an instruction rather than a crossing. So this
// is the one part of time the application core answers for itself.
//
// THERE IS NO DEVICE IN THIS FILE. CNTPCT_EL0 and CNTFRQ_EL0 are read with
// `mrs`, which reaches no memory-mapped register, takes no lock and involves
// no other core. That is what makes it correct for the application core to
// read them, and it is also why this is the whole of the file: there is
// nothing else to do.
//
// WHY IT IS HERE AND NOT ON THE PASCAL SIDE. Free Pascal calls C, and a system
// register is reached with an instruction the Pascal source has no way to
// name. So the three routines below are the instructions, and every decision
// about what to do with them — how a tick becomes a microsecond, how a wait
// reaches its deadline — is on the Pascal side, in the runtime's own layer.
//
#include "libfpc.h"

#include <circle/types.h>

// THE COUNTER.
//
// CNTPCT_EL0 is the physical count of the Arm generic timer: a single counter
// on the board, shared by every core, that starts at zero when the board comes
// up and only ever counts forwards. It is at least 56 bits wide, which at this
// board's counter frequency is more than forty years before it could wrap, so
// nothing here handles a wrap and nothing has to.
//
// The barrier in front of it is what makes a measurement mean anything. `mrs`
// is a register read like any other and the processor is free to complete it
// out of order with respect to the code being measured, so without the barrier
// a timestamp can be taken before the work it is supposed to bracket has
// finished. The barrier costs time, and that cost is inside every interval
// measured with this — which is why the Pascal side measures an interval
// containing no work at all and reports it as the floor everything else is
// read against.
extern "C" u64 LibFPC_CounterRead(void)
{
    u64 nCount;

    asm volatile("isb" ::: "memory");
    asm volatile("mrs %0, CNTPCT_EL0" : "=r"(nCount));

    return nCount;
}

// HOW FAST THAT COUNTER COUNTS, in ticks per second.
//
// CNTFRQ_EL0 does not measure anything: it is a register the firmware writes
// at boot to record the frequency the counter was wired to run at, so that
// software can turn ticks into seconds. It is the same value on every core.
//
// It is read on every call rather than cached. The read is a handful of cycles
// and the value cannot change while the board is running, so caching it would
// buy nothing and would add a piece of state that has to be initialised before
// anything asks the time.
//
// A board whose firmware left this at zero has no usable counter, and the
// Pascal side is where that is noticed: this reports what the register says
// and invents nothing.
extern "C" u64 LibFPC_CounterFrequency(void)
{
    u64 nFrequency;

    asm volatile("mrs %0, CNTFRQ_EL0" : "=r"(nFrequency));

    return nFrequency;
}

// THE POINT INSIDE A WAIT WHERE THE CORE HAS NOTHING TO DO.
//
// A timed wait on this target reaches its deadline by reading the counter
// until it arrives. `yield` tells the processor that the code doing so is
// waiting rather than working, which lets it give its own resources to
// whatever else the processor is running. It changes nothing about the
// program's behaviour and it is not a delay.
//
// This is deliberately the only thing in the waiting loop that is not counter
// arithmetic, because it is the point that grows later: when this library has
// a scheduler of its own, a wait must give the core to another Pascal thread
// and must service SDL while it waits. That is a body added to this seam, not
// a wait rewritten around it.
extern "C" void LibFPC_CounterWaitHint(void)
{
    asm volatile("yield" ::: "memory");
}
