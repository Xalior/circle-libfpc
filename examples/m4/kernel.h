//
// kernel.h — circle-libfpc M4: Pascal threads on the application core.
//
// The core layout is the product's. Core 0 is the hardware core and owns every
// device on the board, the serial console and the screen included. Core 1 runs
// the Pascal program, and that core is the whole of the computer the Pascal
// program can see: it owns no device, drives no UART, and reaches nothing
// across a core boundary itself. Cores 2 and 3 are parked — this example draws
// nothing, so there is no presentation worker to run.
//
// THE PASCAL THREADS THIS EXAMPLE MAKES ARE INVISIBLE FROM HERE, and that is
// the point of it. They are circle-libfpc's own, scheduled inside core 1, and
// nothing about them reaches this side: no core is started for one, no Circle
// task is created for one, and Circle is not told. This kernel's job is to
// stand outside and check that from the only place the check is worth
// anything — the core that owns Circle's task list.
//
// WHERE THE CONSOLE LANDS IS THIS KERNEL'S DECISION, NEVER PASCAL'S. The
// Pascal program writes into one channel and knows of no other; the drain runs
// here, on the core that owns the devices, and this kernel chooses what it
// drains to. Here that is the serial port and the screen. Serial is always a
// destination and is what settles the milestone.
//
// THE SCREEN IS CIRCLE-LIBSDL2'S TO DRAW, and this kernel asks for it with one
// call — SDL2Circle_LogAttachScreen in Initialize below. That library owns the
// framebuffer and reads the mode the firmware granted back out of it, so its
// console is right on a board whatever depth the firmware decided to hand out.
// Circle's own screen device is sized by a compile-time depth macro that no
// reply ever corrects, which is why nothing here builds one.
//
#ifndef _kernel_h
#define _kernel_h

#include <circle/actled.h>
#include <circle/koptions.h>
#include <circle/devicenameservice.h>
#include <circle/serial.h>
#include <circle/exceptionhandler.h>
#include <circle/interrupt.h>
#include <circle/timer.h>
#include <circle/logger.h>
#include <circle/sched/scheduler.h>
#include <circle/cputhrottle.h>
#include <circle/multicore.h>
#include <circle/memory.h>
#include <circle/types.h>

enum TShutdownMode
{
    ShutdownNone,
    ShutdownHalt,
    ShutdownReboot
};

// Secondary-core dispatch. A core handed no role parks: returning from Run()
// would leave it executing whatever follows.
class CSplitCores : public CMultiCoreSupport
{
public:
    CSplitCores(void) : CMultiCoreSupport(CMemorySystem::Get()) {}
    void Run(unsigned nCore) override;
};

class CKernel
{
public:
    CKernel(void);

    boolean Initialize(void);
    TShutdownMode Run(void);

private:
    CActLED             m_ActLED;
    CKernelOptions      m_Options;
    CDeviceNameService  m_DeviceNameService;
    // The only console device this kernel owns. The screen is a second
    // destination for the same log, and it belongs to circle-libsdl2 — there
    // is no screen object here to hold.
    CSerialDevice       m_Serial;
    CExceptionHandler   m_ExceptionHandler;
    CInterruptSystem    m_Interrupt;
    CTimer              m_Timer;
    CLogger             m_Logger;
    // Core 0 yields on this for as long as the board runs. The shim's servo
    // is a scheduler task, and the servo is what drains the log rings the
    // other cores write into — including the one the Pascal program's own
    // output arrives in. It is also the task list this kernel counts.
    CScheduler          m_Scheduler;
    // Circle boots at idle clock and the shim reaches this object through
    // CCPUThrottle::Get(), which asserts rather than returning null.
    CCPUThrottle        m_CPUThrottle;
    CSplitCores         m_Cores;
};

#endif
