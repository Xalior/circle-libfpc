//
// kernel.cpp
//
#include "kernel.h"
#include <circle-libfpc/fpc.h>
#include <circle/interrupt.h>
#include <circle/memorymap.h>

// Serial device 0 is TXD on GPIO14 and RXD on GPIO15 on the Raspberry Pi 5 —
// the pins a USB-serial adapter is normally wired to. Circle's own default for
// this board is device 10, the dedicated 3-pin JST connector, which nothing
// here is attached to.
#define MINBLOCK_SERIAL_DEVICE	0

static const char FromKernel[] = "minblock";

// The Pascal heap, as the C side can see it: a BSS block and its size, both
// emitted into the program object by the compiler. Printed before PASCALMAIN
// so a fault during Pascal's own unit initialization — which runs before the
// program body, and therefore before anything Pascal could print for itself —
// still says which heap it happened in.
extern "C" unsigned char __fpc_initialheap[];
extern "C" unsigned long __heapsize;

CKernel::CKernel (void)
:	m_Serial (0, FALSE, MINBLOCK_SERIAL_DEVICE),	// 0 = polling driver, no IRQ
	m_Timer (CInterruptSystem::Get ()),		// sysinit made the interrupt system
	m_Logger (LogDebug, &m_Timer)
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
			"circle-libfpc minblock: board rpi5, single core, no threads");

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
	// program by calling _haltproc, which does not return either.
	m_Logger.Write (FromKernel, LogError, "PASCALMAIN returned, which it must not");

	return ShutdownHalt;
}
