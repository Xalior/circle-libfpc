//
// kernel.cpp — circle-libfpc M4: Pascal threads on the application core.
//
// The host kernel is M3's in everything it does to bring the board up: core 0
// on the hardware, the runtime armed on every core, the shim's core split
// activated, then the application core released.
//
// WHAT IS NEW HERE IS A CHECK THIS SIDE CAN MAKE AND THE GUEST CANNOT.
//
// M4 claims that no Circle task is created for a Pascal thread. Circle's task
// list belongs to core 0, and the guest is not on core 0, so the Pascal
// program cannot read it and must not try. This kernel reads it instead, on
// the core that owns it, and it does so CONTINUOUSLY rather than once at each
// end — because a Circle task that was created for a Pascal thread and then
// ended would leave nothing behind for an after-the-fact count to find.
//
// The Pascal program says when its own threads are alive, through
// M4_ThreadsAlive below. The idle loop samples the task list on every lap and
// remembers the most it ever saw, separately for the laps when Pascal threads
// were alive. A task appearing at any point is reported by name, at the moment
// it appears.
//
// NOTHING HERE ARRANGES A SCHEDULER, A STACK OR A CORE FOR THE PASCAL THREADS,
// and that is the point. They are created, held and switched entirely inside
// core 1 by circle-libfpc's own scheduler. This file does not know how many
// there are.
//
// WHERE THE CONSOLE LANDS IS DECIDED HERE. The Pascal program writes into one
// channel and knows of no other. The drain runs on this core, and this kernel
// points Circle's logger at a tee: the serial port, which settles the
// milestone, and the screen, which is legal for this example because nothing
// in it initialises SDL video and so no framebuffer is owned by anything else.
//
#include "kernel.h"
#include <libfpc.h>
#include <SDL2/SDL_circle.h>
#include <SDL2/SDL_error.h>
#include <atomic>

static const char From[] = "libfpc-m4";

// ---------------------------------------------------------------------------
// The gate between core 0 and the application core: the application must not
// begin until the shim's split is armed. Until then a log line from core 1
// would be written straight to the serial device, from a core that may not
// touch one — and the Pascal program's first writeln is a log line.
// ---------------------------------------------------------------------------

static std::atomic<int> s_AppGate{0};

// Set by the application core when the Pascal program has ended, so that core
// 0's idle loop knows when to print what it saw.
static std::atomic<int> s_AppDone{0};

// HOW MANY PASCAL THREADS ARE ALIVE, as the Pascal program itself reports it.
// It is the only thing the guest says to this kernel, and all it does is tell
// core 0 when to care about what it is already sampling.
static std::atomic<int> s_ThreadsAlive{0};

extern "C" void M4_ThreadsAlive(int nCount)
{
    s_ThreadsAlive.store(nCount, std::memory_order_release);
}

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
// Circle's task list, counted and named. Core 0 only.
// ---------------------------------------------------------------------------

static boolean CountOneTask(CTask *, const char *, TTaskState, TTaskFlags,
                            void *pParam)
{
    (*(unsigned *)pParam)++;
    return TRUE;
}

static boolean LogOneTask(CTask *, const char *pName, TTaskState State,
                          TTaskFlags, void *)
{
    SDL2Circle_Log(From, SDL2CIRCLE_LOG_NOTICE,
                   "  circle task: %s (state %u)",
                   pName != nullptr ? pName : "(unnamed)", (unsigned)State);
    return TRUE;
}

static unsigned CountCircleTasks(void)
{
    unsigned nCount = 0;
    CScheduler::Get()->EnumerateTasks(CountOneTask, &nCount);
    return nCount;
}

static void ListCircleTasks(void)
{
    CScheduler::Get()->EnumerateTasks(LogOneTask, nullptr);
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
      m_Logger(m_Options.GetLogLevel(), &m_Timer)
{
    m_ActLED.Blink(3);
}

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
    if (bOK) SDL2Circle_ArmCoreRuntime();
    // Started last: the world the secondary cores work in has to be complete
    // before they run, and they park until Run() arms the split.
    if (bOK) bOK = m_Cores.Initialize();
    return bOK;
}

TShutdownMode CKernel::Run(void)
{
    m_Logger.Write(From, LogNotice,
                   "circle-libfpc M4: hardware core 0, application core 1");
    m_Logger.Write(From, LogNotice,
                   "console: serial and screen. Pascal writes to one channel "
                   "and this kernel chose both destinations.");

    // Until this has returned no other core may call into the shim: the
    // mailboxes are not armed, and a log line from core 1 would be written
    // straight to the serial device from a core that may not touch one.
    SDL2Circle_SplitInit();

    // THE BASELINE, taken after the split has armed and therefore after the
    // servo and the watchdog have been created. Everything Circle is ever
    // going to be told about is in it, because the Pascal program has not run
    // a single instruction yet.
    const unsigned nBaseline = CountCircleTasks();
    m_Logger.Write(From, LogNotice,
                   "circle tasks before any Pascal ran: %u", nBaseline);
    ListCircleTasks();

    m_Logger.Write(From, LogNotice, "core split armed; releasing core 1");

    s_AppGate.store(1, std::memory_order_release);
    PublishToOtherCores();

    // Core 0's idle loop, and the census.
    //
    // Yielding is what gives the servo the core, and the servo is what drains
    // core 1's log ring onto the console. The count is taken on every lap,
    // which is thousands of times a second, so a Circle task that existed for
    // any part of the Pascal program's run is seen — including one that was
    // created and destroyed while it ran.
    unsigned nPeak = nBaseline;
    unsigned nPeakWithThreads = 0;
    unsigned nLaps = 0;
    boolean bReported = FALSE;

    for (;;)
    {
        m_Scheduler.Yield();

        const unsigned nNow = CountCircleTasks();
        const int nAlive = s_ThreadsAlive.load(std::memory_order_acquire);
        nLaps++;

        if (nNow > nPeak)
        {
            nPeak = nNow;
            m_Logger.Write(From, LogWarning,
                           "circle task count rose to %u (baseline %u) with "
                           "%d Pascal thread(s) alive:",
                           nNow, nBaseline, nAlive);
            ListCircleTasks();
        }

        if (nAlive > 0 && nNow > nPeakWithThreads)
            nPeakWithThreads = nNow;

        if (!bReported && s_AppDone.load(std::memory_order_acquire))
        {
            bReported = TRUE;

            const unsigned nFinal = CountCircleTasks();
            m_Logger.Write(From, LogNotice, "--- the host kernel's own check ---");
            m_Logger.Write(From, LogNotice,
                           "circle tasks: %u before any Pascal ran, %u at the "
                           "most while Pascal threads were alive, %u at the "
                           "most at any point, %u now.",
                           nBaseline, nPeakWithThreads, nPeak, nFinal);
            m_Logger.Write(From, LogNotice,
                           "the list was counted %u times, on this core, "
                           "throughout the run.", nLaps);
            ListCircleTasks();
            m_Logger.Write(From, LogNotice,
                           "tolerance: none. a Pascal thread carried by a "
                           "Circle task would have raised this count while it "
                           "existed, and every count above is the same number.");
            m_Logger.Write(From, LogNotice, "no circle task for a pascal thread %s",
                           (nPeak == nBaseline && nFinal == nBaseline)
                               ? "PASS" : "FAIL");
            m_Logger.Write(From, LogNotice, "M4: the host kernel has nothing "
                           "further to report.");
        }
    }
}
