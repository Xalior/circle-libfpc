//
// core.cpp - which core is executing this instruction.
//
// The Pascal program runs on a machine with one core, and the whole of
// circle-libfpc's scheduler depends on that being true rather than merely
// intended. The runtime asks the processor, at every entry to the
// scheduler and at every thread's first instruction, and stops the program
// if the answer is not the core the guest was started on.
//
// There is no device in this file. Circle's own CMultiCoreSupport::ThisCore
// reads MPIDR_EL1, which is a processor system register: no memory-mapped
// register, no lock, no other core. Reading it is an instruction, so the
// application core may ask it about itself, exactly as it reads the
// free-running counter next door in counter.cpp.
//
// This wrapper exists because Circle is C++ and Free Pascal calls C, and
// Circle's answer is a static member of a C++ class. Every decision about
// what to do with the number is on the Pascal side.
//
#include "libfpc.h"

#include <circle/multicore.h>
#include <circle/types.h>

// Circle's own definition of which core this is, rather than a second
// reading of the same register written here, so a Pascal thread carried by
// something that placed it on another core (a Circle task, a std::thread,
// a core the host lent) gets the same answer Circle itself would report.
//
// A single-core build has no CMultiCoreSupport and there is only one answer
// it could give.
extern "C" unsigned LibFPC_CurrentCore(void)
{
#ifdef ARM_ALLOW_MULTI_CORE
    return CMultiCoreSupport::ThisCore();
#else
    return 0;
#endif
}
