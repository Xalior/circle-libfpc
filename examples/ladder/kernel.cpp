//
// kernel.cpp
//
#include "kernel.h"
#include <circle-libfpc/fpc.h>
#include <circle/util.h>
#include <circle/interrupt.h>

// Serial device 0 is TXD on GPIO14 and RXD on GPIO15 on the Raspberry Pi 5 —
// the pins a USB-serial adapter is normally wired to. Circle's own default
// for this board is device 10, the dedicated 3-pin JST connector, which
// nothing here is attached to.
#define LADDER_SERIAL_DEVICE	0

// The core this kernel gives to Pascal.
#define LADDER_PASCAL_CORE	1

static const char FromKernel[] = "ladder";

#ifdef ARM_ALLOW_MULTI_CORE

CCoreDispatch::CCoreDispatch (CMemorySystem *pMemorySystem)
:	CMultiCoreSupport (pMemorySystem)
{
}

void CCoreDispatch::Run (unsigned nCore)
{
	if (nCore == LADDER_PASCAL_CORE)
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
:	m_Serial (0, FALSE, LADDER_SERIAL_DEVICE),	// 0 = polling driver, no IRQ
	m_Timer (CInterruptSystem::Get ()),		// sysinit made the interrupt system
	m_Logger (LogNotice, &m_Timer)
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

	// The logger is the console. circle-libfpc holds no device of its own —
	// the Pascal program is a guest and does not drive hardware — so this
	// is where everything it prints ends up, and it is the host kernel that
	// decides which device that is.
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
			"circle-libfpc ladder: board rpi5, timer and scheduler up");

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
				LADDER_PASCAL_CORE);
	}
#else
	m_Logger.Write (FromKernel, LogError,
			"this is a single-core build: there is no core to lend, so "
			"there will be no Pascal threads");
#endif

	m_Logger.Write (FromKernel, LogNotice, "calling PASCALMAIN");

	PASCALMAIN ();

	// PASCALMAIN is not expected to return: the embedded runtime ends a
	// program by calling _haltproc, which does not return either. Reaching
	// this line is itself a finding.
	m_Logger.Write (FromKernel, LogError, "PASCALMAIN returned, which it must not");

	return ShutdownHalt;
}
