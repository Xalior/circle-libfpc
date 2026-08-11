//
// fpc.h
//
// circle-libfpc — the Free Pascal runtime on the Circle bare-metal framework.
//
// This is the whole surface a host kernel uses. Everything else in this
// library exists to be called by Free Pascal's runtime, never by the kernel.
//
// THIS LIBRARY OWNS NO HARDWARE. It supplies the Free Pascal runtime — the
// memory manager, the thread manager, start-up and halt — and nothing that
// reaches the outside world. A Pascal program here is an application, not a
// kernel: it runs on a core the way a guest runs on a virtual machine. Its I/O
// is circle-libsdl2's, and its console output leaves through that library's
// own log entry rather than through any device this one holds. See
// src/log.cpp.
//
// A host kernel does two things:
//
//   1. starts its secondary cores and lends one to Pascal, if the application
//      uses threads — see the core-lending section below;
//   2. calls PASCALMAIN.
//
// It also owes the image two Circle objects it might not otherwise have
// bothered with. Neither is this library's to create, and a kernel missing
// either one fails in a way that reads as something else entirely.
//
//   A CLogger, because that is where output goes. An image that does not link
//   circle-libsdl2 has no I/O surface, and this library then falls back to the
//   host's own logger — which is Circle's and the host's, never this
//   library's. A kernel with no CLogger at all sees nothing: Circle answers
//   CLogger::Get with a logger that has no target and a severity floor of
//   LogPanic, and every line is dropped in silence.
//
//   A CExceptionHandler, because A FAULT WITH NOWHERE TO REPORT ITSELF LOOKS
//   EXACTLY LIKE A HANG. Circle's AArch64 exception stub calls
//   CExceptionHandler::Get, which asserts its singleton exists and, with
//   asserts compiled out, returns null and is dereferenced immediately. So a
//   kernel without one answers a data abort with a second fault inside the
//   fault handler and stops dead — which on a serial capture is
//   indistinguishable from a Pascal program that simply stopped between two
//   lines. With one, a fault prints its name, ELR, ESR and FAR through the
//   logger above and the other cores halt cleanly. Both examples carry one.
//
// PASCALMAIN does not return. The Free Pascal runtime ends a program by
// calling _haltproc, which this library defines and which never returns
// either.
//
#ifndef _circle_libfpc_fpc_h
#define _circle_libfpc_fpc_h

#ifdef __cplusplus
extern "C" {
#endif

// The entry point of the application blob, emitted by the Free Pascal
// compiler into the program object. Declared here so a host kernel can call
// it without declaring it for itself.
void PASCALMAIN (void);

// Half of the two-symbol contract the aarch64-embedded target leaves for the
// linker: a cdecl procedure that must not return. The System unit calls it to
// end the program. This library defines it; it reports and then halts the
// core.
void _haltproc (void);

// Console output, as the Pascal side sees it. Neither of these touches a
// device: a line is handed to circle-libsdl2, or — in an image without it —
// put in the calling core's ring for core 0 to carry to the host's logger.
void clf_write (const char *pBuffer, unsigned nLength);
void clf_puts (const char *pString);

// Carry whatever the other cores have written to the host's logger. Core 0
// only, and bounded: it prints for a couple of milliseconds and returns.
//
// A host kernel need not call this. Every wait this library makes on core 0 —
// a join, a lock, an event — calls it already, and so does every line core 0
// prints. A kernel with a long idle loop of its own may call it there as well,
// and one that links circle-libsdl2 need not care: that library carries its
// own lines and this call then does nothing.
void FPCCircle_LogDrain (void);

// CORE LENDING. A Pascal thread is not a Circle task: it runs on a core a host
// kernel has given away, one thread at a time on that core. Without a lent
// core there are no Pascal threads at all — BeginThread refuses and says so.
//
// A host kernel starts its own secondary cores (CMultiCoreSupport) and calls
// FPCCircle_ThreadCoreOffer on the ones it can spare:
//
//   void CMyCores::Run (unsigned nCore)
//   {
//       switch (nCore)
//       {
//       case 1:  FPCCircle_ThreadCoreOffer (); break;   // never returns
//       default: for (;;) asm volatile ("wfe"); break;  // parked
//       }
//   }
//
// A core that is given no role must be parked. Returning from a dispatch
// function lets the core run on into whatever code follows it.
//
// FPCCircle_ThreadCoreOffer parks the calling core and lends it. It never
// returns and must not be called on core 0, which is Circle's own.
void FPCCircle_ThreadCoreOffer (void);

// Place the NEXT thread this core creates on a named core, as a one-shot
// request. Returns 0 when the request is accepted, and -1 when that core is
// not one this board can run a thread on or is not free. A creation with no
// request pending takes the lowest free lent core, which is what a thread
// created inside the Pascal runtime — several frames below any code that could
// have asked — gets.
int FPCCircle_ThreadPinNext (unsigned nCore);

// The cores that are free right now, as a bitmask. A core that was never lent,
// and one already running a thread, are not in it.
unsigned FPCCircle_ThreadCoresFree (void);

// The core the caller is running on.
unsigned FPCCircle_ThisCore (void);

#ifdef __cplusplus
}
#endif

// The other half of the contract, _stack_top, is an ADDRESS rather than a
// value and is defined in this library's stacktop object as an absolute
// symbol equal to Circle's MEM_KERNEL_STACK — the top of core 0's kernel
// stack, which is where a host kernel calls PASCALMAIN from.
//
// A host kernel that runs Pascal on some other stack defines its own
// _stack_top in one of its own objects. An object linked into the kernel
// takes precedence over an archive member of the same name, so no change is
// needed here and nothing has to be removed.

#endif
