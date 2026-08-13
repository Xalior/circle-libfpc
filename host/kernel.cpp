//
// kernel.cpp - the host kernel for a Pascal program on a bare-metal
// Raspberry Pi.
//
// THE BRING-UP ORDER IS CORE-SPLIT.MD'S AND IT IS NOT A PREFERENCE. Core 0 on
// the hardware and the card mounted, the runtime armed on every core, the
// secondary cores started, the game's card declarations made, the split
// armed, and only then the application core released. The game's first act is
// to read a settings file and its second is to ask SDL for a display, so the
// card has to be ready before it runs at all.
//
// THE DISPLAY THIS KERNEL DOES NOT DECLARE.
//
// circle-libsdl2 sizes the virtual framebuffer from the first SDL_CreateWindow
// when nothing overrides it -- but Fairtris 2's own call asks for 0x0. It
// means to size itself afterwards, through SDL_SetWindowSize, once its
// Fairtris.Placement unit has worked out a presentation size, the way it
// would on a desktop window manager. There is no window manager here and
// SDL_SetWindowSize is a no-op, so a 0x0 request stays 0x0 forever -- but
// that is not this kernel's problem to solve. The size the game wants is a
// build-time fact of THIS PORT, not of the board, so it is stated once in
// the port's own Makefile and stamped into the built image's boot argument
// block (bootargs.cpp reads it before the game ever calls SDL_CreateWindow).
// This kernel names no size at all.
//
// THE CARD IS WHERE THE GAME'S FILES ARE, AND THE GAME NAMES THEM RELATIVELY.
// Its files are named relative to the working directory, which on a desktop
// is wherever the program was started. There is no such thing here, so this
// kernel sets it: SDL2Circle_IOChdir reaches the filesystem's own current
// directory, which lives on core 0 and is shared by every core. That is what
// makes the game's own paths work with no change to the game.
//
// SDL_GetBasePath and SDL_GetPrefPath are the same question asked through SDL
// rather than through the runtime, and the game asks it for its settings file
// and its high-score tables. SDL2Circle_DeclareBasePath answers it.
//
// NOTHING HERE TOUCHES THE PICTURE OR THE SOUND. The game makes its own
// window, its own renderer and its own textures, opens its own audio device
// and loads its own sounds, exactly as it does on a desktop.
//
#include "kernel.h"
#include <libfpc.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_circle.h>
#include <atomic>

static const char From[] = "kernel";

// ---------------------------------------------------------------------------
// The decisions this kernel makes for the game.
// ---------------------------------------------------------------------------

// Where the game's directory was put on the card. One directory of the game's
// own, because the card is shared with everything else this project boots.
//
// It is a build parameter rather than a constant, because the card layout is
// the consumer's decision and not this kernel's: a consumer whose card is laid
// out differently sets RAPI_GAME_DIR and does not edit this file. The default
// is the convention every game in this family follows - one directory per game
// under /games, so the root of the card stays clear.
//
// BOTH ANSWERS THIS KERNEL GIVES ABOUT THE CARD COME FROM IT. The working
// directory, which is what makes the game's own relative paths resolve; and
// the base path SDL_GetPrefPath is derived from, which is where the game
// writes its settings file and its high-score tables. Two paths, one value -
// a card where they disagreed would have the game reading its sprites from
// one place and its scores from another.
#ifndef RAPI_GAME_DIR
#define RAPI_GAME_DIR "/games/fairtris2"
#endif
static const char GameDir[] = RAPI_GAME_DIR;

// ---------------------------------------------------------------------------
// The gate between core 0 and the application core.
// ---------------------------------------------------------------------------

static std::atomic<int> s_AppGate{0};

// Set by the application core when the Pascal program has ended. A game does
// not normally end, so this only fires when the player quits.
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

// The C library's own stdio, initialised on the descriptors above. Declared
// here the way circle-stdlib's own examples declare it.
void CGlueStdioInit(CConsole &rConsole);

boolean CKernel::Initialize(void)
{
    boolean bOK = TRUE;
    if (bOK) bOK = m_Serial.Initialize(115200);
    if (bOK) bOK = m_Logger.Initialize(&m_Serial);
    // THE SECOND DESTINATION, AND THE ONLY MOMENT ANYTHING IS ATTACHED. The
    // serial destination above is not replaced, and the library drops this one
    // by itself when the game initialises SDL video - which is the moment the
    // game takes the display. So the boot lines appear on both and everything
    // after appears on serial alone.
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
    // Takes descriptors 0, 1 and 2. WITHOUT THIS the first file the game opens
    // would be handed descriptor 0, which the Pascal runtime reads as the
    // console - and every write to that file would go to the log instead of to
    // the card, with nothing saying so.
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
    // THE WORKING DIRECTORY, FOR THE GAME'S OWN RELATIVE PATHS.
    //
    // The game's own files are named with no prefix, which is a working
    // directory on every desktop and nothing at all here. This is one
    // setting for the whole board, shared by every core.
    if (SDL2Circle_IOChdir(GameDir) != 0)
    {
        m_Logger.Write(From, LogError,
                       "the game directory %s is not on the card. Every "
                       "file the game loads is named relative to it, so it "
                       "cannot start.", GameDir);
        return ShutdownHalt;
    }

    char CwdNow[256];
    if (SDL2Circle_IOGetCwd(CwdNow, sizeof CwdNow) == 0)
        m_Logger.Write(From, LogNotice, "working directory: %s", CwdNow);

    // WHERE SDL SAYS THE GAME'S FILES ARE. The same answer as above, asked
    // through SDL instead of through the runtime: the game reads its settings
    // and writes its high scores under SDL_GetPrefPath, which the library
    // composes below this and creates as it goes.
    if (SDL2Circle_DeclareBasePath(GameDir) != 0)
    {
        m_Logger.Write(From, LogError, "base path: %s", SDL_GetError());
        return ShutdownHalt;
    }

    // NO DISPLAY IS DECLARED HERE. See the header comment: the size the game
    // needs is stated once in the port's own Makefile and stamped into this
    // image's boot argument block, which the library reads for itself.

    // Until this has returned no other core may call into the library.
    SDL2Circle_SplitInit();

    m_Logger.Write(From, LogNotice, "core split armed; releasing core 1");

    s_AppGate.store(1, std::memory_order_release);
    PublishToOtherCores();

    // Core 0 serves the application core until it returns.
    //
    // YIELDING IS NOT HOUSEKEEPING HERE. The servo is a scheduler task, and
    // the servo is what drains the application core's log ring, what pumps USB
    // so that the keyboard and the gamepad produce events, what performs every
    // file call the application makes, and what feeds the presentation core. A
    // host that waited without yielding would deadlock on the first file the
    // application opened, with a black screen and a dead keyboard.
    while (!s_AppDone.load(std::memory_order_acquire))
        m_Scheduler.Yield();

    return ShutdownReboot;
}
