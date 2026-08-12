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
// THE ONE THING THIS KERNEL READS FROM THE CARD IS THE WITNESS. The Pascal
// program leaves one small file behind on purpose. This kernel opens it with
// the C library, here on the core that owns the card, and prints what it
// finds — a different reader, on a different core, that has never been
// through the Pascal file layer. Then it removes the witness and the
// directory, because the file service carries no rmdir and the Pascal program
// therefore cannot remove a directory at all.
//
// WHERE THE CONSOLE LANDS IS THIS KERNEL'S DECISION, NEVER PASCAL'S. The
// Pascal program writes into one channel and knows of no other; the drain
// runs here, on the core that owns the devices, and this kernel chooses what
// it drains to. Here that is the serial port and the screen, through the tee
// below. Serial is always a destination and is what settles the milestone.
//
#ifndef _kernel_h
#define _kernel_h

#include <circle/actled.h>
#include <circle/koptions.h>
#include <circle/devicenameservice.h>
#include <circle/screen.h>
#include <circle/serial.h>
#include <circle/device.h>
#include <circle/exceptionhandler.h>
#include <circle/interrupt.h>
#include <circle/timer.h>
#include <circle/logger.h>
#include <circle/sched/scheduler.h>
#include <circle/cputhrottle.h>
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

// TWO DESTINATIONS FOR ONE LOG.
//
// Circle's logger writes to a single device. This is that device, and it
// forwards every write to two: the serial port first, because that is the one
// that settles the milestone and must not be delayed by the other, and the
// screen after it.
//
// It is a device that reaches devices, so it is core 0's, exactly like the
// two it forwards to. Everything that arrives here has already crossed from
// whatever core wrote it, through the log ring the servo drains.
class CTeeDevice : public CDevice
{
public:
    CTeeDevice(CDevice *pFirst, CDevice *pSecond)
        : m_pFirst(pFirst), m_pSecond(pSecond) {}

    int Write(const void *pBuffer, size_t nCount) override
    {
        int nResult = m_pFirst != nullptr
                          ? m_pFirst->Write(pBuffer, nCount)
                          : (int)nCount;
        if (m_pSecond != nullptr)
            m_pSecond->Write(pBuffer, nCount);
        return nResult;
    }

private:
    CDevice *m_pFirst;
    CDevice *m_pSecond;
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
    // after the Pascal program has ended.
    void ReadTheWitness(void);
    void ClearTheDirectory(void);

    CActLED             m_ActLED;
    CKernelOptions      m_Options;
    CDeviceNameService  m_DeviceNameService;
    // The screen is a console here and nothing more. Nothing in this example
    // initialises SDL video, so the framebuffer this takes is not one anything
    // else wants.
    CScreenDevice       m_Screen;
    CSerialDevice       m_Serial;
    CTeeDevice          m_Console;
    CExceptionHandler   m_ExceptionHandler;
    CInterruptSystem    m_Interrupt;
    CTimer              m_Timer;
    CLogger             m_Logger;
    // Core 0 yields on this for as long as the board runs. The shim's servo
    // is a scheduler task, and the servo is what drains core 1's log ring
    // onto the console AND what performs every file call the Pascal program
    // makes. A host that stopped yielding would stop both.
    CScheduler          m_Scheduler;
    // Circle boots at idle clock and the shim reaches this object through
    // CCPUThrottle::Get(), which asserts rather than returning null.
    CCPUThrottle        m_CPUThrottle;
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
