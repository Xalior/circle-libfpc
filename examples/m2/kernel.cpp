//
// kernel.cpp — circle-libfpc M2: writeln reaches the console through
// circle-libsdl2, and through nothing this library touches.
//
// The host kernel is the same shape as M0's and does the same work: bring the
// board up on core 0, arm the runtime on every core, activate the shim's core
// split, then let the application core go. What is new is on the other side
// of PASCALMAIN, in the Free Pascal runtime, so there is nothing here that
// prints on the Pascal program's behalf.
//
// WHAT REACHES THE SERIAL CONSOLE, AND FROM WHERE
//
// The serial console is a device, so only core 0 may write to it. Core 0's
// own bring-up lines go through CLogger directly, which is correct because
// that is core 0 writing. Everything from core 1 — this file's own lines and
// every byte the Pascal program writes — goes into that core's log ring, and
// core 0's servo drains it. Core 1 never touches the hardware.
//
#include "kernel.h"
#include <libfpc.h>
#include <SDL2/SDL_circle.h>
#include <atomic>

static const char From[] = "libfpc-m2";

// ---------------------------------------------------------------------------
// The gate between core 0 and the application core: the application must not
// begin until the shim's split is armed. Until then a log line from core 1
// would be written straight to the serial device, from a core that may not
// touch one — and the Pascal program's first writeln is a log line.
// ---------------------------------------------------------------------------

static std::atomic<int> s_AppGate{0};

static inline void PublishToOtherCores(void)
{
    asm volatile("dsb ish; sev" ::: "memory");
}

static void ParkCore(void)
{
    for (;;)
        asm volatile("wfe" ::: "memory");
}

static void app_main(void)
{
    SDL2Circle_Log(From, SDL2CIRCLE_LOG_NOTICE,
                   "calling the Pascal entry point on core %u",
                   CMultiCoreSupport::ThisCore());

    PASCALMAIN();

    // PASCALMAIN returns when the Pascal program has ended: its body ran off
    // its end, Free Pascal's fpc_do_exit flushed the standard text files and
    // called this library's _haltproc, and that returned rather than stopping
    // the core. So the halt is the host kernel's to act on, and here it is
    // only reported.
    SDL2Circle_Log(From, SDL2CIRCLE_LOG_NOTICE,
                   "the Pascal entry point returned: halted=%d, exit code %d",
                   LibFPC_Halted(), LibFPC_ExitCode());
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
      m_CPUThrottle(CPUSpeedMaximum)
{
    m_ActLED.Blink(3);
}

boolean CKernel::Initialize(void)
{
    boolean bOK = TRUE;
    if (bOK) bOK = m_Serial.Initialize(115200);
    if (bOK) bOK = m_Logger.Initialize(&m_Serial);
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
                   "circle-libfpc M2: hardware core 0, application core 1");

    // Until this has returned no other core may call into the shim: the
    // mailboxes are not armed, and a log line from core 1 would be written
    // straight to the serial device from a core that may not touch one.
    SDL2Circle_SplitInit();

    m_Logger.Write(From, LogNotice, "core split armed; releasing core 1");

    s_AppGate.store(1, std::memory_order_release);
    PublishToOtherCores();

    // Core 0's idle loop. Yielding is what gives the servo the core, and the
    // servo is what drains core 1's log ring onto the console.
    for (;;)
        m_Scheduler.Yield();
}
