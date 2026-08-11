//
// kernel.cpp
//
#include "kernel.h"
#include <circle-libfpc/fpc.h>
#include <circle/util.h>
#include <circle/interrupt.h>
#include <circle/memorymap.h>

// Serial device 0 is TXD on GPIO14 and RXD on GPIO15 on the Raspberry Pi 5 —
// the pins a USB-serial adapter is normally wired to. Circle's own default for
// this board is device 10, the dedicated 3-pin JST connector, which nothing
// here is attached to.
#define PKG_SERIAL_DEVICE	0

// The core this kernel gives to Pascal.
#define PKG_PASCAL_CORE		1

static const char FromKernel[] = "packages";

// THE PASCAL HEAP, AS THE C SIDE CAN SEE IT.
//
// The compiler emits both of these into the program object: a BSS block and
// its size. Printing them from here is the only report that survives a fault
// during Pascal's own unit initialization, which runs before the program body
// and therefore before anything the Pascal side could print for itself. A boot
// that dies before its first rung otherwise says nothing about the heap it
// died in.
extern "C" unsigned char __fpc_initialheap[];
extern "C" unsigned long __heapsize;

#ifdef ARM_ALLOW_MULTI_CORE

CCoreDispatch::CCoreDispatch (CMemorySystem *pMemorySystem)
:	CMultiCoreSupport (pMemorySystem)
{
}

void CCoreDispatch::Run (unsigned nCore)
{
	if (nCore == PKG_PASCAL_CORE)
	{
		// Never returns. From here this core belongs to the library: it
		// sleeps until a Pascal thread is created for it, runs that
		// thread to its end, and sleeps again.
		FPCCircle_ThreadCoreOffer ();
	}

	// A core with no role must be parked. Returning from this function lets
	// the core run on into whatever follows it.
	for (;;)
	{
		asm volatile ("wfe");
	}
}

#endif

CKernel::CKernel (void)
:	m_Serial (0, FALSE, PKG_SERIAL_DEVICE),		// 0 = polling driver, no IRQ
	m_Timer (CInterruptSystem::Get ()),		// sysinit made the interrupt system
	m_Logger (LogDebug, &m_Timer)
#ifdef ARM_ALLOW_MULTI_CORE
	, m_Cores (CMemorySystem::Get ())
#endif
{
}

CKernel::~CKernel (void)
{
}

boolean CKernel::Initialize (void)
{
	if (!m_Serial.Initialize (115200))
	{
		return FALSE;
	}

	if (!m_Logger.Initialize (&m_Serial))
	{
		return FALSE;
	}

	if (!m_Timer.Initialize ())
	{
		m_Logger.Write (FromKernel, LogError, "the timer would not initialize");
		return FALSE;
	}

	return TRUE;
}

TShutdownMode CKernel::Run (void)
{
	m_Logger.Write (FromKernel, LogNotice,
			"circle-libfpc packages: board rpi5, image kernel-clf-pkg.img");
	m_Logger.Write (FromKernel, LogNotice,
			"exception handler and logger are on the UART: a fault will say so");

#ifdef ARM_ALLOW_MULTI_CORE
	m_Logger.Write (FromKernel, LogNotice, "starting the secondary cores");
	if (!m_Cores.Initialize ())
	{
		m_Logger.Write (FromKernel, LogError,
				"the secondary cores would not start, so no core can "
				"be lent and there will be no Pascal threads");
	}
	else
	{
		m_Logger.Write (FromKernel, LogNotice,
				"core %u lent to Pascal, cores 2 and 3 parked",
				PKG_PASCAL_CORE);
	}
#else
	m_Logger.Write (FromKernel, LogError,
			"this is a single-core build: there is no core to lend, so "
			"there will be no Pascal threads");
#endif

	// Printed before PASCALMAIN because Pascal's unit initialization runs
	// before the program body: a fault in there produces no Pascal output at
	// all, and this is then the only thing said about the heap it faulted in.
	// The block must lie below MEM_KERNEL_END, which is where Circle's own
	// stacks begin.
	unsigned long nHeapStart = (unsigned long) __fpc_initialheap;
	m_Logger.Write (FromKernel, LogNotice,
			"pascal heap %lx..%lx (%lu bytes), MEM_KERNEL_END %lx, %s",
			nHeapStart, nHeapStart + __heapsize, __heapsize,
			(unsigned long) MEM_KERNEL_END,
			nHeapStart + __heapsize <= MEM_KERNEL_END
				? "fits" : "DOES NOT FIT");

	m_Logger.Write (FromKernel, LogNotice, "calling PASCALMAIN");

	PASCALMAIN ();

	// PASCALMAIN is not expected to return: the embedded runtime ends a
	// program by calling _haltproc, which does not return either. Reaching
	// this line is itself a finding.
	m_Logger.Write (FromKernel, LogError, "PASCALMAIN returned, which it must not");

	return ShutdownHalt;
}
