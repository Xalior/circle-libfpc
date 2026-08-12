//
// libfpc.h — the C half of circle-libfpc, as a host kernel sees it.
//
// Free Pascal calls C, and Circle is C++, so everything this library reaches
// Circle with is declared here as C. A host kernel needs two things from it:
// the Pascal entry point the compiler emits, and the halt path the Pascal
// runtime takes when the program ends.
//
#ifndef LIBFPC_H
#define LIBFPC_H

#ifdef __cplusplus
extern "C" {
#endif

// THE PASCAL ENTRY POINT.
//
// Free Pascal emits this symbol in the object it compiles a `program` module
// to. It initialises the units, runs the program body, and finishes through
// the halt path below.
//
// The host kernel calls it on the application core, and on no other: the
// Pascal program runs on a machine with one core and never leaves it.
//
// It returns when the program has ended — see LibFPC_ExitCode below.
void PASCALMAIN(void);

// THE HALT PATH.
//
// `_haltproc` is the symbol Free Pascal's system unit for this target calls
// when the program ends, whether by falling off the end of its body or by
// Halt. This library defines it. It records the exit code and returns, which
// hands control back to whoever called PASCALMAIN — the host kernel.
//
// A host kernel does not call it. It reads the code afterwards.
int LibFPC_ExitCode(void);

// Non-zero once the Pascal program has ended, so that a host kernel can tell
// an exit code of zero from a program that never got there.
int LibFPC_Halted(void);

#ifdef __cplusplus
}
#endif

#endif
