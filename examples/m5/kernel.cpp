//
// kernel.cpp — circle-libfpc M5: Pascal files on the card.
//
// The host kernel is M4's in everything it does to bring the board up, plus
// the card: core 0 on the hardware, the EMMC device up, the FAT filesystem
// mounted and the C library's descriptors taken, THEN the runtime armed on
// every core, the shim's core split activated, and only then the application
// core released. The order is CORE-SPLIT.md's and it is not a preference —
// the other cores are about to start asking core 0 for things.
//
// WHAT THIS KERNEL CHECKS THAT THE GUEST CANNOT.
//
// Everything the Pascal program says about the card it learned through the
// same layer it wrote with, so a layer wrong in both directions would agree
// with itself. The Pascal program therefore leaves one small file behind, and
// this kernel reads it here — with the C library, on the core that owns the
// card, having never gone through the Pascal file layer at all. A witness
// that reads back is the writes having reached the real filesystem.
//
// THEN THIS KERNEL CLEARS THE CARD, and it has to, because the file service
// carries no rmdir: the Pascal program can erase its files and cannot remove
// the directory it made. That gap is circle-libsdl2's to record. It is not a
// reason for the Pascal side to reach past the service, and it is not
// something this kernel hides — it says so on the console.
//
// NOTHING HERE WRAPS THE C LIBRARY. circle-libfpc is the file layer and
// points itself at the file service; the link-time `--wrap` in pi-games is
// for an application that has no file layer of its own.
//
#include "kernel.h"
#include <libfpc.h>
#include <SDL2/SDL_circle.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <atomic>

static const char From[] = "libfpc-m5";

// What the Pascal program leaves behind, and where. Named here as well as in
// m5.pas because this side has to find it without asking the guest.
static const char WorkDir[]     = "/tmp-clf-m5";
static const char WitnessPath[] = "/tmp-clf-m5/witness.txt";

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
    // The screen at whatever resolution the firmware has already set. It is a
    // text console and nothing else; this example creates no SDL window, so
    // the framebuffer behind it is not one anything else is going to want.
    : m_Screen(0, 0),
      // Serial device 0 is the GPIO14/15 header UART on every board. Named
      // explicitly because Circle's RASPPI >= 5 default (SERIAL_DEVICE_DEFAULT
      // = 10) is the Pi 5's dedicated debug connector, so taking the default
      // sends every log line somewhere nobody is listening.
      m_Serial(0, FALSE, 0),
      // Serial first: it is the destination that settles the milestone.
      m_Console(&m_Serial, &m_Screen),
      m_Timer(&m_Interrupt),
      m_Logger(m_Options.GetLogLevel(), &m_Timer),
      m_CPUThrottle(CPUSpeedMaximum),
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
    if (bOK) bOK = m_Screen.Initialize();
    if (bOK) bOK = m_Serial.Initialize(115200);
    // The logger writes to the tee, so every line below — this kernel's own
    // and every byte the Pascal program produces — reaches both destinations.
    if (bOK) bOK = m_Logger.Initialize(&m_Console);
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

void CKernel::ReadTheWitness(void)
{
    FILE *pFile = fopen(WitnessPath, "r");
    if (pFile == nullptr)
    {
        m_Logger.Write(From, LogError,
                       "%s is not on the card. The Pascal program said it "
                       "wrote it, so either the write did not reach the "
                       "filesystem or it reached a different one.",
                       WitnessPath);
        return;
    }

    char Line[256];
    unsigned nLines = 0;
    while (fgets(Line, sizeof Line, pFile) != nullptr)
    {
        size_t nLen = strlen(Line);
        while (nLen > 0 && (Line[nLen-1] == '\n' || Line[nLen-1] == '\r'))
            Line[--nLen] = '\0';
        m_Logger.Write(From, LogNotice, "  witness: %s", Line);
        nLines++;
    }
    fclose(pFile);

    m_Logger.Write(From, LogNotice,
                   "read %u line(s) of %s from the card, on core %u, with the "
                   "C library. Pascal wrote them from core 1 through the file "
                   "service and has never touched this reader.",
                   nLines, WitnessPath, CMultiCoreSupport::ThisCore());
}

void CKernel::ClearTheDirectory(void)
{
    // The witness first, then the directory it sat in. rmdir here is the C
    // library's, on the core that owns the card; the Pascal program has no
    // rmdir at all because the file service carries none.
    const int nWitness = remove(WitnessPath);
    const int nDir     = rmdir(WorkDir);

    struct stat St;
    const boolean bGone = (stat(WorkDir, &St) != 0);

    m_Logger.Write(From, LogNotice,
                   "clearing up: removed %s (%s), removed %s (%s).",
                   WitnessPath, nWitness == 0 ? "yes" : "no",
                   WorkDir, nDir == 0 ? "yes" : "no");
    m_Logger.Write(From, bGone ? LogNotice : LogError,
                   "the card no longer carries %s: %s",
                   WorkDir, bGone ? "yes" : "NO - IT IS STILL THERE");
    m_Logger.Write(From, LogNotice,
                   "the directory is this side's to remove because the file "
                   "service carries no rmdir. That is a gap in "
                   "circle-libsdl2, recorded there, and never a reason for "
                   "the guest to reach the card itself.");
}

// ---------------------------------------------------------------------------

TShutdownMode CKernel::Run(void)
{
    m_Logger.Write(From, LogNotice,
                   "circle-libfpc M5: hardware core 0, application core 1");
    m_Logger.Write(From, LogNotice,
                   "the card is mounted on this core and on no other. The "
                   "Pascal program reaches it through circle-libsdl2's file "
                   "service and through nothing else.");
    m_Logger.Write(From, LogNotice,
                   "console: serial and screen (%u x %u). Pascal writes to "
                   "one channel and this kernel chose both destinations.",
                   m_Screen.GetWidth(), m_Screen.GetHeight());

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
            ReadTheWitness();
            ClearTheDirectory();
            m_Logger.Write(From, LogNotice, "M5: the host kernel has nothing "
                           "further to report.");
        }
    }
}
