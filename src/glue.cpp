//
// glue.cpp
//
// How a Pascal program ends. The smallest part of circle-libfpc, and the only
// part a program with no threads and no heap still needs.
//
#include <circle-libfpc/fpc.h>
#include "sched.h"

// The System unit of the aarch64-embedded target calls this to end the
// program, and it must not return. There is nothing to return to: the runtime
// has already run its finalisation and considers the program over.
void _haltproc (void)
{
	clf_log_error ("_haltproc: the Pascal program has ended.");

	// One last pass, so a line still waiting on a ring is not lost to the
	// halt that follows it.
	FPCCircle_LogDrain ();

	for (;;)
	{
		asm volatile ("wfi");
	}
}
