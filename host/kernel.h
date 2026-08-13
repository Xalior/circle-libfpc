//
// kernel.h - the host kernel for a Pascal program on a bare-metal Raspberry
// Pi.
//
// THE GAME IS UNCHANGED WINDOWS FREE PASCAL, and everything that makes it run
// here is on this side of the line. It is M7's card bring-up and M8's
// presentation core in one kernel, because this is the first application that
// needs both: it reads its sprites, its backgrounds and its sounds off the
// card, and it puts a picture on the screen sixty times a second.
//
//   core 0   the devices. The card, the USB bus, the serial console, and the
//            firmware mailbox. Everything the guest cannot touch.
//   core 1   the game. This is the whole of the computer the Pascal program
//            can see, and it owns no device.
//   core 2   the presentation core. A finished frame goes in on core 1 and a
//            scanout comes out here, scaled onto whatever panel is attached.
//
// THIS KERNEL MAKES TWO DECLARATIONS ON THE GAME'S BEHALF, both of them
// before SDL_Init, both of them things a desktop SDL would have worked out
// for itself and this one cannot:
//
//   the base path         where the game's files were put on the card. A
//                         desktop derives it from the running image; there is
//                         no image here.
//   the working directory the same answer again, for the RELATIVE paths the
//                         game uses for its sprites and backgrounds. The
//                         filesystem's own current directory lives on core 0
//                         and is shared by every core.
//
// A REAL GAME MAKES NEITHER OF THESE CALLS, which is exactly why the kernel
// must decide them itself.
//
// THE VIRTUAL DISPLAY IS NOT ONE OF THEM. See kernel.cpp: the size the game
// is to be given is a build-time fact of this port, stated once in the
// port's own Makefile and stamped into the image's own boot argument block,
// which circle-libsdl2 reads for itself before the game ever asks for a
// window.
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
    // game initialises SDL video.
    CSerialDevice       m_Serial;
    CExceptionHandler   m_ExceptionHandler;
    CInterruptSystem    m_Interrupt;
    CTimer              m_Timer;
    CLogger             m_Logger;
    // Core 0 yields on this for as long as the board runs. The library's servo
    // is a scheduler task, and the servo is what drains the other cores' log
    // rings, what pumps USB so the keyboard and the gamepad produce events,
    // what performs every file call the game makes, and what feeds the
    // presentation core. A host that stopped yielding would stop all four.
    CScheduler          m_Scheduler;
    // THERE IS NO CCPUThrottle HERE AND THERE MUST NOT BE. The CPU clock and
    // the case fan belong to circle-libsdl2, which constructs that object
    // itself. Circle permits exactly one in a system and halts in the
    // constructor of a second.
    // THE CARD, AND EVERYTHING ON TOP OF IT. All of it is core 0's, and all of
    // it is up before the application core is released - the game's very first
    // act is to read a settings file.
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
