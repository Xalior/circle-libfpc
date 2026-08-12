//
// kernel.cpp — circle-libfpc M7: Free Pascal's standard library on this board.
//
// The bring-up is M6's, unchanged and for the same reasons: core 0 on the
// hardware, the EMMC device up, the FAT filesystem mounted and the C
// library's descriptors taken, THEN the runtime armed on every core, the
// shim's core split activated, and only then the application core released.
// The order is CORE-SPLIT.md's and it is not a preference — the other cores
// are about to start asking core 0 for things.
//
// WHAT THIS KERNEL CHECKS THAT THE GUEST CANNOT.
//
// One thing, and it is the only one the guest's own report cannot settle. The
// Pascal program's last section says it removed every file it wrote and then
// the directory they sat in. That claim came out of the file layer under
// test, so a layer that reported a removal it never performed would agree
// with itself. This kernel therefore looks at the card here, on the core that
// owns it, with the C library, having never gone near the Pascal file layer:
// the directory must be gone, and so must every name the program wrote inside
// it.
//
// Everything else M7 proves it proves against published constants — RFC 1321's
// MD5 digest, FIPS 180-1's SHA-1 digest, the CRC-32 catalogue check value, the
// calendar — or against a round trip through its own bytes. Those need no
// second reader, so this kernel does not pretend to be one.
//
// IF ANYTHING IS STILL THERE, THIS KERNEL SAYS WHICH AND THEN REMOVES IT, so
// a failed run leaves the card as it was found rather than leaving spoil for
// the next one to trip over.
//
// NOTHING HERE WRAPS THE C LIBRARY. circle-libfpc is the file layer and
// points itself at the file service; the link-time `--wrap` in pi-games is
// for an application that has no file layer of its own.
//
#include "kernel.h"
#include <libfpc.h>
#include <SDL2/SDL_circle.h>
#include <SDL2/SDL_error.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <atomic>

static const char From[] = "libfpc-m7";

// Where the Pascal program works, and every name it writes inside it. Named
// here as well as in m7.pas because this side has to find them without asking
// the guest — that is the whole point of the check.
static const char WorkDir[] = "/tmp-clf-m7";

static const char *const WrittenNames[] =
{
    "/tmp-clf-m7/settings.ini",
    "/tmp-clf-m7/packed.gz",
    "/tmp-clf-m7/document.xml",
    "/tmp-clf-m7/picture.png",
    "/tmp-clf-m7/walk-a.dat",
    "/tmp-clf-m7/walk-b.dat",
    "/tmp-clf-m7/walk-c.dat",
    "/tmp-clf-m7/ignored.txt",
    "/tmp-clf-m7/short.bin"
};

static const unsigned WrittenCount =
    sizeof WrittenNames / sizeof WrittenNames[0];

// ---------------------------------------------------------------------------
// The gate between core 0 and the application core: the application must not
// begin until the card is mounted and the shim's split is armed. Until then a
// log line from core 1 would be written straight to the serial device, from a
// core that may not touch one — and the Pascal program's first writeln is a
// log line.
// ---------------------------------------------------------------------------

static std::atomic<int> s_AppGate{0};

// Set by the application core when the Pascal program has ended, so that core
// 0's idle loop knows when to take its own look at the card.
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

    SDL2Circle_Log(From, SDL2CIRCLE_LOG_NOTICE,
                   "the Pascal entry point returned: halted=%d, exit code %d",
                   LibFPC_Halted(), LibFPC_ExitCode());

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
      // The C library's standard descriptors, over the UART. Nothing writes
      // through it; it exists so the three lowest descriptors are taken.
      m_StdioConsole(&m_Serial, &m_Serial)
{
    m_ActLED.Blink(3);
}

// The C library's own stdio, initialised on the descriptors above. Declared
// here the way circle-stdlib's own examples declare it.
void CGlueStdioInit(CConsole &rConsole);

boolean CKernel::Initialize(void)
{
    boolean bOK = TRUE;
    if (bOK) bOK = m_Serial.Initialize(115200);
    if (bOK) bOK = m_Logger.Initialize(&m_Serial);
    // THE SECOND DESTINATION, AND THE ONLY MOMENT ANYTHING IS ATTACHED. From
    // here every line the logger carries — this kernel's own and every byte
    // the Pascal program produces — is drawn on the screen as well as sent
    // down the wire. The serial destination above is not replaced.
    //
    // Not fatal if it is refused: a board with no display still has the
    // console that settles the milestone, and circle-libsdl2 has already said
    // on it why the screen could not be had.
    if (bOK && SDL2Circle_LogAttachScreen() != 0)
        m_Logger.Write(From, LogWarning,
                       "the screen is not a log destination: %s",
                       SDL_GetError());
    if (bOK) bOK = m_Interrupt.Initialize();
    if (bOK) bOK = m_Timer.Initialize();

    // THE CARD, AND EVERYTHING ON IT, BEFORE ANY OTHER CORE RUNS.
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
    // Takes descriptors 0, 1 and 2. WITHOUT THIS the first file the Pascal
    // program opens would be handed descriptor 0, which the Pascal runtime
    // reads as the console — and every write to that file would go to the
    // log instead of to the card, with nothing saying so.
    if (bOK) CGlueStdioInit(m_StdioConsole);

    if (bOK) SDL2Circle_ArmCoreRuntime();
    // Started last: the world the secondary cores work in has to be complete
    // before they run, and they park until Run() arms the split.
    if (bOK) bOK = m_Cores.Initialize();
    return bOK;
}

// ---------------------------------------------------------------------------
// This kernel's own look at the card. Core 0 only, through the C library,
// having never been near the Pascal file layer.
// ---------------------------------------------------------------------------

boolean CKernel::TheCardIsClear(void)
{
    unsigned nLeft = 0;

    for (unsigned i = 0; i < WrittenCount; i++)
    {
        struct stat St;
        if (stat(WrittenNames[i], &St) == 0)
        {
            nLeft++;
            m_Logger.Write(From, LogError,
                           "  %s is STILL on the card, %ld bytes. The Pascal "
                           "program said it removed it.",
                           WrittenNames[i], (long) St.st_size);
            remove(WrittenNames[i]);
        }
    }

    struct stat StDir;
    const boolean bDirGone = (stat(WorkDir, &StDir) != 0);
    if (!bDirGone)
    {
        m_Logger.Write(From, LogError,
                       "  %s is STILL on the card. The Pascal program said it "
                       "removed it.", WorkDir);
        rmdir(WorkDir);
    }

    const boolean bClear = (nLeft == 0) && bDirGone;

    m_Logger.Write(From, bClear ? LogNotice : LogError,
                   "this core walked the %u names the Pascal program writes, "
                   "and %s. The directory %s is gone: %s. Tolerance: exact - "
                   "nothing the program wrote may still be on the card, and "
                   "this reader is the C library on the core that owns it, "
                   "which has never been through the Pascal file layer.",
                   WrittenCount,
                   nLeft == 0 ? "none of them is there" : "some are still there",
                   WorkDir, bDirGone ? "yes" : "NO");

    if (!bClear)
        m_Logger.Write(From, LogNotice,
                       "this core has removed what was left, so the card is "
                       "as it was found.");

    return bClear;
}

// ---------------------------------------------------------------------------

TShutdownMode CKernel::Run(void)
{
    m_Logger.Write(From, LogNotice,
                   "circle-libfpc M7: hardware core 0, application core 1");
    m_Logger.Write(From, LogNotice,
                   "the Pascal program below is written in Free Pascal's own "
                   "packages - DateUtils, StrUtils, IniFiles, the containers, "
                   "the hashes, compression, JSON, XML and PNG. None of them "
                   "had ever been built for this target.");
    m_Logger.Write(From, LogNotice,
                   "console: serial and screen. Pascal writes to one channel "
                   "and this kernel chose both destinations.");

    // Until this has returned no other core may call into the shim: the
    // mailboxes are not armed, and a log line from core 1 would be written
    // straight to the serial device from a core that may not touch one.
    SDL2Circle_SplitInit();

    m_Logger.Write(From, LogNotice, "core split armed; releasing core 1");

    s_AppGate.store(1, std::memory_order_release);
    PublishToOtherCores();

    // Core 0's idle loop.
    //
    // YIELDING IS NOT HOUSEKEEPING HERE. The servo is a scheduler task, and
    // the servo is what drains core 1's log ring AND what performs every file
    // call the Pascal program makes. A host that waited without yielding
    // would deadlock: the application core would wait for answers this core
    // was never free to give.
    boolean bReported = FALSE;

    for (;;)
    {
        m_Scheduler.Yield();

        if (!bReported && s_AppDone.load(std::memory_order_acquire))
        {
            bReported = TRUE;

            m_Logger.Write(From, LogNotice,
                           "--- the host kernel's own look at the card ---");

            const boolean bClear = TheCardIsClear();

            m_Logger.Write(From, bClear ? LogNotice : LogError,
                           "the host kernel's one check: the card is clear %s.",
                           bClear ? "PASS" : "FAIL");
            m_Logger.Write(From, LogNotice, "M7: the host kernel has nothing "
                           "further to report.");
        }
    }
}
