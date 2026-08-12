//
// kernel.h — circle-libfpc M8: SDL, driven from Free Pascal.
//
// THE HOST KERNEL IS M4'S WITH ONE CORE MORE. Core 0 is the hardware core and
// owns every device on the board; core 1 runs the Pascal program and is the
// whole of the computer that program can see; CORE 2 IS THE PRESENTATION
// CORE, which is new here and is the reason this example exists — the earlier
// milestones drew nothing, so there was nothing for it to do.
//
// A presentation core is not an optimisation. The board has no display
// hardware an application can hand a frame to, so this library stands in for
// it: a finished frame goes into a mailbox on the application's core and comes
// out as a scanout on this one, scaled onto whatever the panel is really
// doing. No part of SDL runs there and nothing this kernel writes runs there;
// SDL2Circle_SplitPresentCore is entered once and never returns.
//
// THERE IS NO CARD IN THIS EXAMPLE. The Pascal program opens no file and
// writes none, so the EMMC device, the filesystem and the C library's standard
// descriptors are all absent — M5, M6 and M7 are where the card is proved, and
// bringing it up here would only add something to go wrong between the board
// and the thing under test.
//
// WHERE THE CONSOLE LANDS IS THIS KERNEL'S DECISION, NEVER PASCAL'S, and this
// example is where that decision becomes visible. The kernel attaches the
// screen as a second log destination at boot, alongside the serial port. The
// library DROPS the screen the moment the application initialises SDL video,
// because that is the moment the guest takes the display. So the boot lines
// appear on both and the Pascal program's report appears on serial alone.
// That is correct and expected: serial is what settles the milestone.
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
    CActLED             m_ActLED;
    CKernelOptions      m_Options;
    CDeviceNameService  m_DeviceNameService;
    // The only console device this kernel owns. The screen is a second
    // destination for the same log and it belongs to circle-libsdl2 — there is
    // no screen object here to hold.
    CSerialDevice       m_Serial;
    CExceptionHandler   m_ExceptionHandler;
    CInterruptSystem    m_Interrupt;
    CTimer              m_Timer;
    CLogger             m_Logger;
    // Core 0 yields on this for as long as the board runs. The shim's servo is
    // a scheduler task, and the servo is what drains the other cores' log rings
    // onto the console and what feeds the presentation core. A host that
    // stopped yielding would stop both.
    CScheduler          m_Scheduler;
    // THERE IS NO CCPUThrottle HERE AND THERE MUST NOT BE. The CPU clock and
    // the case fan belong to circle-libsdl2: it creates that object inside
    // SDL_Init and drives it from whichever per-frame heartbeat is live. Circle
    // permits exactly one in a system and halts in the constructor of a second
    // — `assertion failed: s_pThis == 0' — so a kernel that declares one of its
    // own stops the board the moment the application initialises SDL. The
    // library cannot compensate either, because CCPUThrottle::Get() halts
    // rather than reporting an absence, so it can never be asked the question.
    //
    // m_Options above is what makes the library's throttle possible: Circle
    // reads the fan pin through CKernelOptions::Get() and dereferences the
    // answer without checking it, so a kernel that declares no options gives
    // that constructor a null to follow.
    //
    // This kernel configures no I2C, no SPI and no mini UART — the console is a
    // PL011 UART, whose baud rate does not come from the core clock — so it
    // needs no CSDL2CircleHardware member either, and hardware management
    // starts at SDL_Init where the library puts it.
    CSplitCores         m_Cores;
};

#endif
