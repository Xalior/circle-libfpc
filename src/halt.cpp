//
// halt.cpp — the Free Pascal halt path.
//
// The system unit for the circlesdl2 target declares
//
//     procedure haltproc(e:longint); cdecl; external name '_haltproc';
//
// and calls it from System_exit, which Free Pascal's own fpc_do_exit calls
// at the end of every program. Nothing else in the runtime defines it, so a
// Pascal object does not link until this library is beside it.
//
// It RETURNS. The host kernel brings the board up and calls the Pascal entry
// point; halting hands control back to it. fpc_do_exit returns to PASCALMAIN,
// PASCALMAIN returns to the host kernel's call site, and the host kernel
// decides what happens next — which is where that decision belongs, because
// the host kernel owns the cores and every device on the board.
//
// The exit code is kept here rather than passed back through PASCALMAIN,
// which the compiler gives no return value.
//
#include "libfpc.h"

static int s_nExitCode = 0;
static int s_bHalted = 0;

extern "C" void _haltproc(int nExitCode)
{
    s_nExitCode = nExitCode;
    s_bHalted = 1;
}

extern "C" int LibFPC_ExitCode(void)
{
    return s_nExitCode;
}

extern "C" int LibFPC_Halted(void)
{
    return s_bHalted;
}
