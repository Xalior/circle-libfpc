//
// kernel.h — circle-libfpc M7: Free Pascal's standard library on this board.
//
// THE HOST KERNEL IS M6'S. Same core layout, same bring-up, same reason for
// the order: core 0 is the hardware core and owns every device on the board
// including THE CARD; core 1 runs the Pascal program and is the whole of the
// computer that program can see. Cores 2 and 3 are parked; this example draws
// nothing, so there is no presentation worker to run.
//
// WHAT IS DIFFERENT IS WHAT THIS KERNEL CHECKS AFTERWARDS, AND IT IS SHORTER
// THAN M6'S ON PURPOSE. M6 had to check a directory search's report against
// the card, because the report came out of the layer being tested. M7's
// sections judge themselves against published constants and round trips
// instead, so the one thing left for this side is the card: the Pascal
// program says it removed everything it wrote, and only a reader that never
// went near the Pascal file layer can say whether that is true.
//
// So this kernel makes one check, on the core that owns the card, with the C
// library: THE WORK DIRECTORY AND EVERY NAME THE PROGRAM WROTE INSIDE IT ARE
// GONE. A file layer that reported a removal it did not perform, or that
// removed the directory entry while leaving the files, is caught here and
// nowhere else. If anything is still there this kernel says which name, and
// removes it, so the card is left as it was found.
//
// NOTHING HERE WRAPS THE C LIBRARY ON PASCAL'S BEHALF. The link-time `--wrap`
// every game in pi-games uses exists for an application with no file layer of
// its own. circle-libfpc IS the file layer, so it points itself at the file
// service directly and this kernel wraps nothing.
//
// WHERE THE CONSOLE LANDS IS THIS KERNEL'S DECISION, NEVER PASCAL'S. The
// Pascal program writes into one channel and knows of no other; the drain
// runs here, on the core that owns the devices, and this kernel chooses what
// it drains to. Here that is the serial port and the screen. Serial is always
// a destination and is what settles the milestone.
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
    // This kernel's own look at the card, on the core that owns it. True when
    // the card carries nothing the Pascal program wrote.
    boolean TheCardIsClear(void);

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
