//
// kernel.h - the host kernel for a Pascal program on a bare-metal Raspberry
// Pi.
//
//   core 0   the devices. The card, the USB bus, the serial console, and the
//            firmware mailbox. Everything the guest cannot touch.
//   core 1   the application. This is the whole of the computer the Pascal
//            program can see, and it owns no device.
//   core 2   the presentation core. A finished frame goes in on core 1 and a
//            scanout comes out here, scaled onto whatever panel is attached.
//
// This kernel makes two declarations before SDL_Init, both things a desktop
// SDL would otherwise work out for itself:
//
//   the base path         where the program's own files are on the card.
//   the working directory the same answer again, for a program whose own
//                         paths are relative. The filesystem's own current
//                         directory lives on core 0 and is shared by every
//                         core.
//
// The virtual display is not one of them; see kernel.cpp.
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
#include <circle/input/console.h>
#include <circle/types.h>
#include <SDCard/emmc.h>
#include <fatfs/ff.h>

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
    // destination for the same log and it belongs to circle-libsdl2 - there is
    // no screen object here to hold, and the library drops it the moment the
    // program initialises SDL video.
    CSerialDevice       m_Serial;
    CExceptionHandler   m_ExceptionHandler;
    CInterruptSystem    m_Interrupt;
    CTimer              m_Timer;
    CLogger             m_Logger;
    // Core 0 yields on this for as long as the board runs. The library's servo
    // is a scheduler task, and the servo is what drains the other cores' log
    // rings, what pumps USB so the keyboard and the gamepad produce events,
    // what performs every file call the program makes, and what feeds the
    // presentation core. A host that stopped yielding would stop all four.
    CScheduler          m_Scheduler;
    // No CCPUThrottle is declared here: the CPU clock and the case fan
    // belong to circle-libsdl2, which constructs that object itself, and
    // Circle halts in the constructor of a second one in the same system.
    // The card and everything on top of it, all of it core 0's and all of
    // it up before the application core is released, since a program may
    // open a file as its first act.
    CEMMCDevice         m_EMMC;
    FATFS               m_FileSystem;
    // The C library's standard descriptors. Nothing writes to it: it exists so
    // that descriptors 0, 1 and 2 are taken before the first file is opened,
    // because the C library hands out the lowest free slot and the Pascal
    // runtime reads 0, 1 and 2 as the console.
    CConsole            m_StdioConsole;
    CSplitCores         m_Cores;
};

#endif
