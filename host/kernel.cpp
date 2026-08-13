//
// kernel.cpp - the host kernel for a Pascal program on a bare-metal
// Raspberry Pi.
//
// Initialize() brings up core 0's own devices and mounts the card before any
// other core runs, since a program may open a file as its first act. Run()
// then declares the working directory and the SDL base path, arms the core
// split, releases the application core to call the Pascal program's entry
// point, and services it until it returns.
//
// This kernel declares no display. The size a program needs is a build-time
// fact of the port, stated once in the port's own Makefile and stamped into
// the built image's boot argument block, which circle-libsdl2 reads before
// the program ever calls SDL_CreateWindow.
//
// SDL2Circle_IOChdir sets the filesystem's own current directory, which
// lives on core 0 and is shared by every core, so a program's own relative
// paths work with no change to the program.
//
// SDL_GetBasePath and SDL_GetPrefPath are the same question asked through
// SDL rather than through the runtime, for a program's own settings and
// saved state. SDL2Circle_DeclareBasePath answers it.
//
#include "kernel.h"
#include <libfpc.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_circle.h>
#include <atomic>

static const char From[] = "kernel";

// ---------------------------------------------------------------------------
// The decisions this kernel makes on the program's behalf.
// ---------------------------------------------------------------------------

// Where the program's working directory is on the card. The default is the
// card's root, which is always there, so a program that sets nothing still
// gets a real directory it can read and write.
//
// A build parameter rather than a constant: the card layout is the
// consumer's decision, so a consumer whose card is laid out differently sets
// RAPI_WORK_DIR rather than editing this file.
//
// Both the working directory and the SDL base path derive from this one
// value.
#ifndef RAPI_WORK_DIR
#define RAPI_WORK_DIR "/"
#endif
static const char WorkDir[] = RAPI_WORK_DIR;

// ---------------------------------------------------------------------------
// The gate between core 0 and the application core.
// ---------------------------------------------------------------------------

static std::atomic<int> s_AppGate{0};

// Set by the application core when the Pascal program has ended.
static std::atomic<int> s_AppDone{0};

static inline void PublishToOtherCores(void)
{
    asm volatile("dsb ish; sev" ::: "memory");
}

static void ParkCore(void)
{
    for (;;)
        asm volatile("wfe" ::: "memory");
}

// ---------------------------------------------------------------------------

static void app_main(void)
{
    SDL2Circle_Log(From, SDL2CIRCLE_LOG_NOTICE,
                   "calling the Pascal entry point on core %u",
                   CMultiCoreSupport::ThisCore());

    PASCALMAIN();

    s_AppDone.store(1, std::memory_order_release);
}

void CSplitCores::Run(unsigned nCore)
{
    // Every core may reach code that throws, and a throw reads the thread
    // pointer this arms. It is the first statement on every core.
    SDL2Circle_ArmCoreRuntime();

    switch (nCore)
    {
    case 1:
        while (!s_AppGate.load(std::memory_order_acquire))
            asm volatile("wfe" ::: "memory");
        app_main();
        ParkCore();
        break;

    case 2:
        // The presentation core. It stands in for display hardware the board
        // does not have: a finished frame goes in, a scanout comes out. It
        // never returns, and it is entered before the application core is
        // released so that the first present has somewhere to go.
        SDL2Circle_SplitPresentCore();
        break;

    default:
        ParkCore();
        break;
    }
}

// ---------------------------------------------------------------------------

CKernel::CKernel(void)
    // Serial device 0 is the GPIO14/15 header UART on every board. Named
    // explicitly because Circle's RASPPI >= 5 default (SERIAL_DEVICE_DEFAULT
    // = 10) is the Pi 5's dedicated debug connector, so taking the default
    // sends every log line somewhere nobody is listening.
    : m_Serial(0, FALSE, 0),
      m_Timer(&m_Interrupt),
      m_Logger(m_Options.GetLogLevel(), &m_Timer),
      m_EMMC(&m_Interrupt, &m_Timer, &m_ActLED),
      m_StdioConsole(&m_Serial, &m_Serial)
{
    m_ActLED.Blink(3);
}

// The C library's own stdio, initialised on the descriptors above.
void CGlueStdioInit(CConsole &rConsole);

boolean CKernel::Initialize(void)
{
    boolean bOK = TRUE;
    if (bOK) bOK = m_Serial.Initialize(115200);
    if (bOK) bOK = m_Logger.Initialize(&m_Serial);
    // The serial destination above is not replaced. SDL2Circle_LogAttachScreen
    // adds the screen as a second destination, which the library drops by
    // itself once the program initialises SDL video and takes the display. So
    // the boot lines appear on both and everything after appears on serial
    // alone.
    if (bOK && SDL2Circle_LogAttachScreen() != 0)
        m_Logger.Write(From, LogWarning,
                       "the screen is not a log destination: %s",
                       SDL_GetError());
    if (bOK) bOK = m_Interrupt.Initialize();
    if (bOK) bOK = m_Timer.Initialize();

    // The card, mounted before any other core runs.
    if (bOK)
    {
        bOK = m_EMMC.Initialize();
        if (!bOK)
            m_Logger.Write(From, LogError, "the SD card did not initialise");
    }
    if (bOK)
    {
        bOK = (f_mount(&m_FileSystem, "SD:", 1) == FR_OK);
        if (!bOK)
            m_Logger.Write(From, LogError, "the card did not mount");
    }
    if (bOK) bOK = m_StdioConsole.Initialize();
    // Takes descriptors 0, 1 and 2 before the first file is opened. Without
    // this, the C library would hand the program's first open() the lowest
    // free slot, descriptor 0, which the Pascal runtime reads as the console.
    if (bOK) CGlueStdioInit(m_StdioConsole);

    if (bOK) SDL2Circle_ArmCoreRuntime();
    // Started last: the world the secondary cores work in has to be complete
    // before they run, and they park until Run() arms the split.
    if (bOK) bOK = m_Cores.Initialize();
    return bOK;
}

// ---------------------------------------------------------------------------

TShutdownMode CKernel::Run(void)
{
    // A relative path a program opens is nothing at all here unless the
    // filesystem's own current directory says what it is relative to. One
    // setting for the whole board, shared by every core. A chdir that fails
    // leaves that setting where it was -- the card's root -- so a program
    // that goes on to write a relative path writes it there instead of
    // where it meant to, which can overwrite anything on the card. Refused
    // rather than risked.
    if (SDL2Circle_IOChdir(WorkDir) != 0)
    {
        // Said once, then again for as long as the board is powered, so a
        // console attached after boot still learns why. This runs on core
        // 0 before the split is armed, so it yields to the scheduler
        // between repeats instead of stopping it, keeping the console
        // alive to say it again.
        for (;;)
        {
            m_Logger.Write(From, LogError,
                           "working directory %s not found on the card; "
                           "the program cannot start", WorkDir);

            const u64 nUntil = CTimer::GetClockTicks64()
                               + (u64) 5 * CLOCKHZ;
            while (CTimer::GetClockTicks64() < nUntil)
                m_Scheduler.Yield();
        }
    }

    char CwdNow[256];
    if (SDL2Circle_IOGetCwd(CwdNow, sizeof CwdNow) == 0)
        m_Logger.Write(From, LogNotice, "working directory: %s", CwdNow);

    // The same answer as above, asked through SDL instead of through the
    // runtime: a program reads its settings and writes its saved state under
    // SDL_GetPrefPath, which the library composes below this and creates as
    // it goes.
    if (SDL2Circle_DeclareBasePath(WorkDir) != 0)
    {
        m_Logger.Write(From, LogError, "base path: %s", SDL_GetError());
        return ShutdownHalt;
    }

    // No display is declared here; see the file header.

    // Until this has returned no other core may call into the library.
    SDL2Circle_SplitInit();

    m_Logger.Write(From, LogNotice, "core split armed; releasing core 1");

    s_AppGate.store(1, std::memory_order_release);
    PublishToOtherCores();

    // Core 0 serves the application core until it returns. The scheduler's
    // servo task drains the application core's log ring, pumps USB so the
    // keyboard and the gamepad produce events, performs every file call the
    // application makes, and feeds the presentation core. Waiting here
    // without yielding would deadlock on the first file the application
    // opened.
    while (!s_AppDone.load(std::memory_order_acquire))
        m_Scheduler.Yield();

    return ShutdownReboot;
}
