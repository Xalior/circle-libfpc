//
// kernel.h — circle-libfpc M5: Pascal files on the card.
//
// The core layout is the product's. Core 0 is the hardware core and owns every
// device on the board — the serial console, the screen, and THE CARD. Core 1
// runs the Pascal program, and that core is the whole of the computer the
// Pascal program can see: it owns no device, drives no UART, touches no card,
// and reaches nothing across a core boundary itself. Cores 2 and 3 are parked;
// this example draws nothing, so there is no presentation worker to run.
//
// WHAT IS NEW HERE AGAINST M4 IS THE CARD, AND IT IS ALL ON THIS SIDE. The
// EMMC device, the FAT filesystem and the C library's file table are brought
// up here, on core 0, before the application core is released — exactly as
// circle-libsdl2's CORE-SPLIT.md requires, because the other cores are about
// to start asking core 0 for things and those services have to exist first.
// The Pascal program is never told any of it happened. It calls Rewrite and
// Reset, and circle-libsdl2's file service carries each call to this core.
//
// NOTHING HERE WRAPS THE C LIBRARY ON PASCAL'S BEHALF. The link-time `--wrap`
// every game in pi-games uses exists for an application with no file layer of
// its own. circle-libfpc IS the file layer, so it points itself at the file
// service directly and this kernel wraps nothing.
//
// WHAT THIS KERNEL CHECKS FOR ITSELF, ON THE CORE THAT OWNS THE CARD. Three
// things, all with the C library and none of them through the Pascal file
// layer: the witness the Pascal program left behind reads back; a directory
// the Pascal program says it removed is really absent; and the working
// directory really is where the Pascal program says it left it. The last is
// the one that could not be checked from inside the guest at all — the
// setting lives here, on this core, and asking for it here is asking the
// filesystem rather than asking the layer that changed it.
//
// Then this kernel clears up: it steps out of the working directory and
// removes the witness and the directory it sat in. Those outlive the Pascal
// program because the witness has to, not because the guest could not remove
// them.
//
// WHERE THE CONSOLE LANDS IS THIS KERNEL'S DECISION, NEVER PASCAL'S. The
// Pascal program writes into one channel and knows of no other; the drain
// runs here, on the core that owns the devices, and this kernel chooses what
// it drains to. Here that is the serial port and the screen. Serial is always
// a destination and is what settles the milestone.
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
    // What this kernel checks for itself, on the core that owns the card,
    // after the Pascal program has ended. Each answers yes or no, and the
    // caller reports the three together.
    boolean ReadTheWitness(void);
    boolean TheRemovedDirectoryIsGone(void);
    boolean TheWorkingDirectoryIsWhereTheGuestLeftIt(void);
    void    ClearTheDirectory(void);

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
    // is a scheduler task, and the servo is what drains core 1's log ring
    // onto the console AND what performs every file call the Pascal program
    // makes. A host that stopped yielding would stop both.
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
    // THE CARD, AND EVERYTHING ON TOP OF IT. All of it is core 0's, and all
    // of it is up before the application core is released.
    CEMMCDevice         m_EMMC;
    FATFS               m_FileSystem;
    // The C library's standard descriptors. Nothing writes to it: it exists
    // so that descriptors 0, 1 and 2 are taken before the first file is
    // opened, because the C library hands out the lowest free slot and the
    // Pascal runtime reads 0, 1 and 2 as the console.
    CConsole            m_StdioConsole;
    CSplitCores         m_Cores;
};

#endif
