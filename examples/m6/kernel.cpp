//
// kernel.cpp — circle-libfpc M6: the SysUtils file family and TFileStream.
//
// The bring-up is M5's, unchanged and for the same reasons: core 0 on the
// hardware, the EMMC device up, the FAT filesystem mounted and the C
// library's descriptors taken, THEN the runtime armed on every core, the
// shim's core split activated, and only then the application core released.
// The order is CORE-SPLIT.md's and it is not a preference — the other cores
// are about to start asking core 0 for things.
//
// WHAT THIS KERNEL CHECKS THAT THE GUEST CANNOT.
//
// The Pascal program's account of the card came out of the layer it wrote
// with, so a layer wrong in both directions would agree with itself. Three
// answers are therefore taken here instead, with the C library, on the core
// that owns the card, having never gone near the Pascal file layer:
//
//   the witness         a small file the guest left behind, read back here.
//   the search count    this kernel walks the same directory with opendir and
//                       readdir and counts the matching names itself. A
//                       search that reported three files it had invented, or
//                       missed one that is really there, is caught here and
//                       nowhere else.
//   the clock           this kernel reads the same clock on its own core and
//                       compares with the moment the guest wrote down. THE
//                       DATE ON THIS BOARD IS NOT THE REAL DATE — there is no
//                       battery-backed clock, and circle-libsdl2 answers from
//                       its own build time. So the check is agreement, not
//                       truth: two readers, two cores, two languages, one
//                       clock.
//
// THEN THIS KERNEL CLEARS THE CARD: the witness, the four files the search
// ran over, and the directory they sat in. Nothing outside that directory is
// touched, and the working directory is never changed by either side.
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
#include <time.h>
#include <sys/stat.h>
#include <atomic>

static const char From[] = "libfpc-m6";

// Where the Pascal program works, and what it leaves behind. Named here as
// well as in m6.pas because this side has to find it without asking the
// guest.
static const char WorkDir[]     = "/tmp-clf-m6";
static const char WitnessPath[] = "/tmp-clf-m6/witness.txt";

// The names the guest's search ran over: three the mask had to find and one
// it had to miss. This kernel counts the first three itself and checks that
// the fourth is still on the card — a search that had DELETED the name it was
// meant to skip would look identical from inside the guest.
static const char *const SearchFiles[] =
{
    "/tmp-clf-m6/found-a.dat",
    "/tmp-clf-m6/found-b.dat",
    "/tmp-clf-m6/found-c.dat"
};
static const char UnfoundPath[] = "/tmp-clf-m6/other.txt";

// The prefix and suffix the guest's mask, found-*.dat, comes down to. This
// kernel matches by hand rather than by pattern: the pattern matcher is the
// thing being checked.
static const char MatchPrefix[] = "found-";
static const char MatchSuffix[] = ".dat";

// The directory walk itself, in carddir.cpp. It is a file of its own because
// FatFs and the C library both declare a type called DIR and this kernel
// needs FatFs's header for the mount — read that file's own header.
extern "C" int M6CountMatchingNames(const char *pDir, const char *pPrefix,
                                    const char *pSuffix, int *pEntries,
                                    void (*pReport)(const char *pName));

// What that walk reports each matching name through. It prints from core 0,
// where the walk runs.
static void ReportMatch(const char *pName)
{
    CLogger::Get()->Write(From, LogNotice, "  this core also sees: %s", pName);
}

// HOW FAR APART THE TWO CLOCK READINGS MAY BE.
//
// The guest reads the clock in its section 8 and this kernel reads it after
// the program has ended — a second or two later, plus whatever the console
// takes. Sixty seconds is far more than that gap and far less than the gap
// between two clocks that do not share a source, so it separates "both cores
// read the same clock" from "one of them invented a date".
static const long ClockToleranceSeconds = 60;

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

boolean CKernel::ReadTheWitness(TWitness &rWitness)
{
    rWitness.bRead = FALSE;
    rWitness.nFoundCount = -1;
    rWitness.nStreamBytes = -1;
    rWitness.nEpoch = -1;

    FILE *pFile = fopen(WitnessPath, "r");
    if (pFile == nullptr)
    {
        m_Logger.Write(From, LogError,
                       "%s is not on the card. The Pascal program said it "
                       "wrote it, so either the write did not reach the "
                       "filesystem or it reached a different one.",
                       WitnessPath);
        return FALSE;
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

        if (strncmp(Line, "found-count=", 12) == 0)
            rWitness.nFoundCount = (int) strtol(Line + 12, nullptr, 10);
        else if (strncmp(Line, "stream-bytes=", 13) == 0)
            rWitness.nStreamBytes = strtol(Line + 13, nullptr, 10);
        else if (strncmp(Line, "epoch=", 6) == 0)
            rWitness.nEpoch = strtol(Line + 6, nullptr, 10);
    }
    fclose(pFile);

    rWitness.bRead = (nLines > 0) &&
                     (rWitness.nFoundCount >= 0) &&
                     (rWitness.nEpoch >= 0);

    m_Logger.Write(From, rWitness.bRead ? LogNotice : LogError,
                   "read %u line(s) of %s from the card, on core %u, with the "
                   "C library. Pascal wrote them from core 1 through the file "
                   "service and has never touched this reader. Parsed: %s",
                   nLines, WitnessPath, CMultiCoreSupport::ThisCore(),
                   rWitness.bRead ? "yes" : "NO - the file is not what M6 writes");
    return rWitness.bRead;
}

// THE CHECK THE GUEST'S OWN ACCOUNT CANNOT MAKE. The Pascal program said its
// search found three names. That number came out of the layer under test. So
// this walks the same directory here, with the C library's own opendir and
// readdir, matches the names by hand, and compares.
boolean CKernel::CountTheSearchFilesHere(const TWitness &rWitness)
{
    int nEntries = 0;
    const int nHere = M6CountMatchingNames(WorkDir, MatchPrefix, MatchSuffix,
                                           &nEntries, ReportMatch);
    if (nHere < 0)
    {
        m_Logger.Write(From, LogError,
                       "this core cannot open %s, so the guest's search "
                       "cannot be checked against anything.", WorkDir);
        return FALSE;
    }

    // Every name the guest said it found must be a real file, one at a time.
    boolean bAllThere = TRUE;
    for (unsigned i = 0; i < sizeof SearchFiles / sizeof SearchFiles[0]; i++)
    {
        struct stat St;
        if (stat(SearchFiles[i], &St) != 0)
        {
            bAllThere = FALSE;
            m_Logger.Write(From, LogError, "  %s is NOT on the card",
                           SearchFiles[i]);
        }
    }

    // And the name the guest's mask had to MISS must still be on the card. A
    // search that had removed it would look the same from inside the guest.
    struct stat StOther;
    const boolean bOtherStillThere = (stat(UnfoundPath, &StOther) == 0);

    const boolean bAgree = (nHere == rWitness.nFoundCount) &&
                           bAllThere && bOtherStillThere;

    m_Logger.Write(From, bAgree ? LogNotice : LogError,
                   "%s holds %d entries; this core counts %d matching "
                   "found-*.dat and the guest's search reported %d. All three "
                   "named files present: %s. The name the mask had to miss, "
                   "%s, is still on the card: %s. Tolerance: exact - the two "
                   "counts must be equal.",
                   WorkDir, nEntries, nHere, rWitness.nFoundCount,
                   bAllThere ? "yes" : "NO",
                   UnfoundPath, bOtherStillThere ? "yes" : "NO");
    return bAgree;
}

// THE CLOCK, READ HERE, COMPARED WITH THE MOMENT THE GUEST WROTE DOWN.
//
// This says nothing about whether the date is right, and it cannot: there is
// no battery-backed clock on this board, so the date is circle-libsdl2's
// answer rather than the world's. What it does say is that the Pascal
// runtime's calendar time and this kernel's are the same clock — read from
// two cores, through two languages, within a stated tolerance.
boolean CKernel::TheClockAgrees(const TWitness &rWitness)
{
    const time_t nHere = time(nullptr);
    const long nDiff = (long) nHere - rWitness.nEpoch;
    const long nAbs = nDiff < 0 ? -nDiff : nDiff;
    const boolean bAgree = (nAbs <= ClockToleranceSeconds);

    m_Logger.Write(From, bAgree ? LogNotice : LogError,
                   "the clock on core %u reads %ld seconds since the epoch; "
                   "the Pascal program read %ld a moment earlier. They differ "
                   "by %ld s. Tolerance: %ld s. THIS IS NOT A CHECK THAT THE "
                   "DATE IS RIGHT - the board has no battery-backed clock and "
                   "the date is circle-libsdl2's answer. It is a check that "
                   "both sides read the same clock.",
                   CMultiCoreSupport::ThisCore(), (long) nHere,
                   rWitness.nEpoch, nDiff, ClockToleranceSeconds);
    return bAgree;
}

void CKernel::ClearTheDirectory(void)
{
    // Neither side ever changed the working directory, so there is nothing to
    // step out of: the card only refuses to remove the directory it is
    // standing in, and it is not standing in this one.
    int nRemoved = 0;

    if (remove(WitnessPath) == 0) nRemoved++;
    for (unsigned i = 0; i < sizeof SearchFiles / sizeof SearchFiles[0]; i++)
        if (remove(SearchFiles[i]) == 0) nRemoved++;
    if (remove(UnfoundPath) == 0) nRemoved++;

    const int nDir = rmdir(WorkDir);

    struct stat St;
    const boolean bGone = (stat(WorkDir, &St) != 0);

    m_Logger.Write(From, LogNotice,
                   "clearing up: removed %d of the 5 files this run left, "
                   "then %s (%s).",
                   nRemoved, WorkDir, nDir == 0 ? "removed" : "NOT removed");
    m_Logger.Write(From, bGone ? LogNotice : LogError,
                   "the card no longer carries %s: %s",
                   WorkDir, bGone ? "yes" : "NO - IT IS STILL THERE");
}

// ---------------------------------------------------------------------------

TShutdownMode CKernel::Run(void)
{
    m_Logger.Write(From, LogNotice,
                   "circle-libfpc M6: hardware core 0, application core 1");
    m_Logger.Write(From, LogNotice,
                   "the card is mounted on this core and on no other. The "
                   "Pascal program reaches it through circle-libsdl2's file "
                   "service and through nothing else.");
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

            TWitness Witness;
            const boolean bWitness = ReadTheWitness(Witness);
            const boolean bCount   = CountTheSearchFilesHere(Witness);
            const boolean bClock   = bWitness && TheClockAgrees(Witness);
            const boolean bAll     = bWitness && bCount && bClock;

            m_Logger.Write(From, bAll ? LogNotice : LogError,
                           "the host kernel's three checks: witness %s, "
                           "search count %s, clock %s. This side %s.",
                           bWitness ? "PASS" : "FAIL",
                           bCount ? "PASS" : "FAIL",
                           bClock ? "PASS" : "FAIL",
                           bAll ? "PASS" : "FAIL");

            ClearTheDirectory();
            m_Logger.Write(From, LogNotice, "M6: the host kernel has nothing "
                           "further to report.");
        }
    }
}
