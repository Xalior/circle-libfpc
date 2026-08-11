//
// kernel.h
//
// Host kernel for circle-libfpc's packages example. Serial only: no screen, no
// USB, no filesystem. The serial device is the whole output channel, because
// watching a boot over a UART shows a rung that stops even when the picture
// never comes up.
//
// It is a MULTICORE host, because that is what a Pascal thread needs. A thread
// here is not a Circle task; it runs on a core this kernel has lent to the
// library. Core 1 is the one lent, cores 2 and 3 are parked, and core 0 keeps
// Circle and runs the Pascal program itself. A kernel that lends no core gets
// no Pascal threads at all — BeginThread refuses — which is a rung failure
// here rather than something to discover on the board.
//
#ifndef _kernel_h
#define _kernel_h

#include <circle/devicenameservice.h>
#include <circle/serial.h>
#include <circle/logger.h>
#include <circle/exceptionhandler.h>
#include <circle/timer.h>
#include <circle/memory.h>
#include <circle/multicore.h>
#include <circle/sched/scheduler.h>
#include <circle/types.h>

enum TShutdownMode
{
	ShutdownNone,
	ShutdownHalt,
	ShutdownReboot
};

#ifdef ARM_ALLOW_MULTI_CORE

// What each secondary core is for. The library never starts a core and never
// chooses one: this class is the whole of the decision, and it belongs to the
// host kernel.
class CCoreDispatch : public CMultiCoreSupport
{
public:
	CCoreDispatch (CMemorySystem *pMemorySystem);

	void Run (unsigned nCore) override;
};

#endif

class CKernel
{
public:
	CKernel (void);
	~CKernel (void);

	boolean Initialize (void);

	TShutdownMode Run (void);

private:
	// Do not change this order. CSerialDevice::Initialize registers itself
	// with the device name service, so that must exist first.
	CDeviceNameService	m_DeviceNameService;

	// Polling driver: the serial output itself needs no IRQ.
	CSerialDevice		m_Serial;

	CTimer			m_Timer;

	// The console, and the only place anything this image prints ends up.
	// circle-libfpc holds no device of its own, and a kernel with no CLogger
	// gets Circle's default one: no target, a severity floor of LogPanic, and
	// every line dropped in silence.
	CLogger			m_Logger;

	// A FAULT WITH NOWHERE TO REPORT ITSELF LOOKS EXACTLY LIKE A HANG.
	//
	// Circle's AArch64 exception stub calls CExceptionHandler::Get(), which
	// asserts its singleton exists and, with asserts compiled out, returns
	// null and is immediately dereferenced. So a kernel with no
	// CExceptionHandler answers a data abort with a second fault inside the
	// fault handler and stops dead, silently — which reads on a serial
	// capture as the program simply stopping between two lines. With this
	// here, a fault prints its name, ELR, ESR and SPSR through the logger
	// above before the board halts.
	CExceptionHandler	m_ExceptionHandler;

	// Not required by the thread model — a Pascal thread is not a task — but
	// a host kernel is free to have one, and this example keeps it so that
	// the path where core 0 hands its waiting time to Circle while a lent
	// core works is the path that gets exercised.
	CScheduler		m_Scheduler;

#ifdef ARM_ALLOW_MULTI_CORE
	CCoreDispatch		m_Cores;
#endif
};

#endif
