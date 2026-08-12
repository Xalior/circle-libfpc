//
// kernel.h — circle-libfpc M0: a Pascal blob in a Circle host kernel.
//
// The core layout is the product's. Core 0 is the hardware core and owns every
// device on the board. Core 1 runs the Pascal program, and that core is the
// whole of the computer the Pascal program can see: it owns no device, drives
// no UART, and reaches nothing across a core boundary itself. Cores 2 and 3
// are parked — this example draws nothing, so there is no presentation worker
// to run.
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
    // No CScreenDevice: nothing here draws.
    CActLED             m_ActLED;
    CKernelOptions      m_Options;
    CDeviceNameService  m_DeviceNameService;
    CSerialDevice       m_Serial;
    CExceptionHandler   m_ExceptionHandler;
    CInterruptSystem    m_Interrupt;
    CTimer              m_Timer;
    CLogger             m_Logger;
    // Core 0 yields on this for as long as the board runs. The shim's servo
    // is a scheduler task, and the servo is what drains the log rings the
    // other cores write into.
    CScheduler          m_Scheduler;
    // THERE IS NO CCPUThrottle HERE AND THERE MUST NOT BE. It belongs to
    // circle-libsdl2, which constructs it the moment a kernel calls
    // SDL2Circle_ArmCoreRuntime() — which this one does, on every core — and
    // drives it from whichever per-frame heartbeat is live. Circle permits
    // exactly one in a system and halts in the constructor of a second —
    // `assertion failed: s_pThis == 0' — so a kernel that declares one of its
    // own stops the board at that call. The library cannot compensate either,
    // because CCPUThrottle::Get() halts rather than reporting an absence, so
    // it can never be asked the question.
    CSplitCores         m_Cores;
};

#endif
