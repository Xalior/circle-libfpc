//
// kernel.cpp — circle-libfpc M8: SDL, driven from Free Pascal.
//
// THE BRING-UP ORDER IS CORE-SPLIT.MD'S AND IT IS NOT A PREFERENCE. Core 0 on
// the hardware, the runtime armed on every core, the secondary cores started,
// the split armed, and only then the application core released. Steps 2 and 4
// happen in that order, so the application core has to wait for a flag rather
// than beginning the moment it starts — until SDL2Circle_SplitInit has
// returned, no other core may call into the library at all, and the Pascal
// program's first WriteLn is a call into the library.
//
// WHAT THIS KERNEL CHECKS THAT THE GUEST CANNOT, AND IT IS ONE NUMBER.
//
// The Pascal program prints SizeOf(TSDL_Event) as its binding lays that record
// out. Only C can say what the library thinks that union is, because the C
// header is where the padding member that fixes it lives. So this kernel
// prints sizeof(SDL_Event) from the compiler that built the library, and the
// two numbers are read together on the log. Nothing else about the picture
// needs a second reader: the Pascal program reads its own frames back out of
// SDL's framebuffer and judges them against what it drew.
//
// NOTHING HERE DECLARES THE VIRTUAL DISPLAY. The library's own examples do it
// from the kernel because they want the panel's own size and the firmware
// mailbox that knows it belongs to core 0. This program wants a display that
// matches nothing on the board — that is what exercises the placement — so it
// declares its own, in Pascal, and needs nothing from this side to do it.
//
// NOTHING HERE LENDS A SERIAL DEVICE FOR KEY INJECTION EITHER. The library
// finds the console UART for itself and decides from --rapi-debug-uart in the
// boot argument block whether to type its bytes into the machine as key
// events. A kernel that does nothing gets that working, which is the whole
// reason it was moved there.
//
#include "kernel.h"
#include <libfpc.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_circle.h>
#include <atomic>

static const char From[] = "libfpc-m8";

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
      m_Logger(m_Options.GetLogLevel(), &m_Timer)
{
    m_ActLED.Blink(3);
}

boolean CKernel::Initialize(void)
{
    boolean bOK = TRUE;
    if (bOK) bOK = m_Serial.Initialize(115200);
    if (bOK) bOK = m_Logger.Initialize(&m_Serial);
    // THE SECOND DESTINATION, AND THE ONLY MOMENT ANYTHING IS ATTACHED. The
    // serial destination above is not replaced, and the library drops this one
    // by itself when the Pascal program initialises SDL video.
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

// ---------------------------------------------------------------------------

TShutdownMode CKernel::Run(void)
{
    m_Logger.Write(From, LogNotice,
                   "circle-libfpc M8: hardware core 0, application core 1, "
                   "presentation core 2");
    m_Logger.Write(From, LogNotice,
                   "the Pascal program below makes a window, a renderer and "
                   "textures, draws into them, reads its own frames back out "
                   "of SDL's framebuffer, and checks them against what it "
                   "drew.");
    m_Logger.Write(From, LogNotice,
                   "console: serial and screen. The screen destination is "
                   "dropped when the program initialises SDL video, which is "
                   "the moment it takes the display. Serial carries the whole "
                   "report.");

    // THE ONE NUMBER THIS SIDE KNOWS AND THE GUEST CANNOT. The C header fixes
    // the event union's size with a padding member; a Pascal translation of
    // that header carries the variants and not the padding, so the two can
    // disagree and nothing in either language would say so. Both are printed.
    m_Logger.Write(From, LogNotice,
                   "sizeof(SDL_Event) in C is %u bytes, sizeof(SDL_Rect) %u, "
                   "sizeof(SDL_DisplayMode) %u. The Pascal program prints its "
                   "own for each.",
                   (unsigned) sizeof(SDL_Event), (unsigned) sizeof(SDL_Rect),
                   (unsigned) sizeof(SDL_DisplayMode));

    // Until this has returned no other core may call into the shim.
    SDL2Circle_SplitInit();

    m_Logger.Write(From, LogNotice, "core split armed; releasing core 1");

    s_AppGate.store(1, std::memory_order_release);
    PublishToOtherCores();

    // Core 0's idle loop.
    //
    // YIELDING IS NOT HOUSEKEEPING HERE. The servo is a scheduler task, and
    // the servo is what drains the application core's log ring, what pumps
    // USB so that the event queue has anything to carry, and what feeds the
    // presentation core. A host that waited without yielding would have a
    // silent console and a dead keyboard.
    boolean bReported = FALSE;

    for (;;)
    {
        m_Scheduler.Yield();

        if (!bReported && s_AppDone.load(std::memory_order_acquire))
        {
            bReported = TRUE;
            m_Logger.Write(From, LogNotice,
                           "M8: the host kernel has nothing further to "
                           "report. The verdict above is the Pascal "
                           "program's own.");
        }
    }
}
