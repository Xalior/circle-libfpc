{
  sdl2circle.pas — circle-libsdl2's Circle extensions, declared for Pascal.

  This is circle-libsdl2's SDL2/SDL_circle.h in another language: the calls
  that library adds because a desktop already knows the answers and a
  bare-metal board does not. Read that header for the full reasoning behind
  each one; the notes here say what a caller has to do.

  WHY THIS IS HERE AND NOT IN A PASCAL SDL2 BINDING. A binding translates
  SDL's own headers, and none of these calls is in them — they exist only on
  this platform. A game ported to this board keeps its own binding untouched
  and names this unit beside it, exactly as its C equivalent would add one
  #include.

  IT DEPENDS ON NO BINDING. Every type below is a plain Free Pascal one, so
  this unit compiles beside whichever SDL2 binding an application already
  carries and never argues with it over a type name.

  WHAT IS DECLARED HERE, AND WHAT IS NOT.

  SDL_circle.h serves two readers. A HOST KERNEL uses it to bring the machine
  up: arming a core's runtime, creating the servo, handing a core to
  presentation, marshalling a call onto core 0. An APPLICATION uses the rest.

  Only the application's half is here, and that is not a subset chosen for
  convenience. A Circle host kernel is C++ — it is a Circle kernel, and there
  is no other kind — so the kernel half of that header has no Pascal caller by
  construction, while the application half has no other caller at all in a
  Pascal program.

  EVERY DECLARATION IS `external' WITH NO LIBRARY NAMED, for the reason given
  at the top of sdl2.pas: there is no loader on this machine and nothing to
  open. The host kernel's own build links this library's archive and every
  symbol is resolved there.

  LICENCE: zlib, the same as the rest of this library. See LICENSE.
}
unit sdl2circle;

{$mode objfpc}
{$H+}
{$PACKRECORDS C}

interface

{****************************************************************************
  The virtual display device

  THIS IS REQUIRED AND THERE IS NO FALLBACK OF ANY KIND. Not the boot command
  line, not the panel, nothing. An application that has not declared a virtual
  device has not said what display it is to be given, so SDL_Init refuses to
  start the library rather than invent one, and says why on the console.
****************************************************************************}

{ Declare the display the application is to be given: a depth, and a width and
  height in pixels.

  Every SDL answer about the display — SDL_GetCurrentDisplayMode,
  SDL_GetDesktopDisplayMode, SDL_GetDisplayMode, SDL_GetDisplayBounds — and
  the size of the window SDL_CreateWindow returns come from these numbers,
  whatever resolution the panel is really being scanned at. The library
  carries each frame from the one to the other, and the application is never
  told the real resolution.

  32 is the only depth the library can serve: the framebuffer is allocated at
  32 bits per pixel and streaming ARGB8888 is the only texture format, so any
  other depth is refused rather than quietly rounded to this one. Width and
  height must both be above zero.

  IT IS FIXED once accepted. A second declaration is refused, and so is one
  made after the display size has been settled by the first display query or
  the first window. So call it before SDL_Init.

  WHERE THE NUMBERS COME FROM IS THE CALLER'S BUSINESS ENTIRELY: a build
  constant, a settings file, an option of the host kernel's own, a value off a
  network port. This library is TOLD what the virtual display is. It discovers
  nothing and offers no way to ask what the panel is.

  An application that wants its virtual display to MATCH the panel has to be
  handed the panel's size by its host kernel: the firmware mailbox that knows
  it is a device, and a device belongs to core 0.

  Zero when accepted, -1 when refused, with SDL_GetError saying which rule was
  not met. A refused declaration changes nothing, and an earlier accepted one
  still stands. }
function SDL2Circle_DeclareVirtualDevice(depth: LongWord;
  width, height: LongInt): LongInt; cdecl; external;

{****************************************************************************
  The application's base path
****************************************************************************}

{ Declare the directory the application was installed in — what
  SDL_GetBasePath answers with, and what SDL_GetPrefPath composes its own
  answer below.

  On a desktop SDL asks the operating system where the running program came
  from. There is nothing to ask here: the payload was chain-loaded or started
  from a card, and where its files were put is a decision somebody made when
  they built the card.

  The path must be absolute. A trailing separator is added if it is missing,
  because SDL's contract is that both path functions answer with one.

  Fixed once accepted, on the same terms as the virtual device.

  NOT DECLARING ONE IS NOT AN ERROR: the answer is then `/', with one warning
  on the log. That differs from the virtual device deliberately — a board has
  exactly one filesystem and `/' is a real directory, while there is no sane
  default display size.

  Zero when accepted, -1 when refused. }
function SDL2Circle_DeclareBasePath(const path: PAnsiChar): LongInt;
  cdecl; external;

{****************************************************************************
  Performance reports
****************************************************************************}

{ A report on the log every nSeconds: one line per core that has run
  instrumented code, carrying the presented frame rate and how that core's
  cycles divided between rendering, waiting, audio, input and the application
  itself. Zero turns it off, which is where it starts.

  This call is the only way in — the library reads no boot configuration for
  it — and while it is off the instrument costs one branch per section. }
procedure SDL2Circle_SetPerfInterval(nSeconds: LongWord); cdecl; external;

{****************************************************************************
  Board hardware, as readings
****************************************************************************}

{ The SoC temperature in degrees Celsius, and the CPU clock rate in Hz. Both
  answer zero before hardware management is up, and zero where the board
  cannot report the value. Reading them touches no device on the calling core:
  the library owns the one CCPUThrottle and answers from it. }
function SDL2Circle_SoCTemperature: LongWord; cdecl; external;
function SDL2Circle_CPUClockRate: LongWord; cdecl; external;

{****************************************************************************
  The log, from any core

  The serial console is a device, so only core 0 may write to it. These put a
  line on it from ANY core: the calling core formats into a ring of its own
  and returns, and core 0's servo drains every ring into the logger. The
  caller never touches the hardware and is never blocked by it.

  When a ring is full the line is DROPPED and counted, and the count is
  printed with the next drain — logging never stalls the core that logs, and
  never quietly loses anything without saying so.
****************************************************************************}

const
  SDL2CIRCLE_LOG_ERROR   = LongWord(1);
  SDL2CIRCLE_LOG_WARNING = LongWord(2);
  SDL2CIRCLE_LOG_NOTICE  = LongWord(3);
  SDL2CIRCLE_LOG_DEBUG   = LongWord(4);

{ `from' is the subsystem tag Circle's logger prints. IT IS STORED BY POINTER
  AND PRINTED LATER, so it must outlive the call: a string constant, never a
  buffer that goes out of scope. In Pascal that means a typed constant or a
  literal, not the result of an expression built on the stack. }
procedure SDL2Circle_Log(const from_: PAnsiChar; severity: LongWord;
  const fmt: PAnsiChar); cdecl; varargs; external;

{ Byte-oriented output — an application's own standard output, arriving in
  whatever pieces it was written in. Lines are assembled and published one at
  a time, because a log carries lines and has nowhere to put half of one. }
procedure SDL2Circle_LogBytes(const from_: PAnsiChar;
  const bytes: PAnsiChar; len: LongWord); cdecl; external;

{****************************************************************************
  The I/O service, from any core

  A small blocking file and directory interface that is valid from ANY core.
  Off core 0 the call is marshalled to the hardware core's servo, which is the
  only context that ever touches the filesystem stack.

  AN APPLICATION THAT OPENS FILES THROUGH SDL_RWops DOES NOT NEED THIS. It is
  for an application with a file layer of its own — a language runtime, an
  engine's virtual filesystem — which must not reach the card directly and
  needs somewhere to point its own open, read, write and seek.

  Every call blocks until the servo answers. Results are plain values (zero or
  above) or a negated errno (below zero), never the caller's errno, which is
  not core-safe here.
****************************************************************************}

const
  SDL2CIRCLE_IO_READ   = LongWord($1);
  SDL2CIRCLE_IO_WRITE  = LongWord($2);
  { Create or truncate, with WRITE. }
  SDL2CIRCLE_IO_CREATE = LongWord($4);

type
  PSDL2Circle_IOStat = ^TSDL2Circle_IOStat;
  TSDL2Circle_IOStat = record
    isdir : Byte;
    size  : QWord;
    mtime : Int64;   { seconds since the epoch }
  end;

  PSDL2Circle_IODirEntry = ^TSDL2Circle_IODirEntry;
  TSDL2Circle_IODirEntry = record
    name  : array[0..255] of AnsiChar;
    isdir : Byte;
    size  : QWord;
    mtime : Int64;
  end;

function SDL2Circle_IOOpen(const path: PAnsiChar; flags: LongWord;
  size_out: PQWord): LongInt; cdecl; external;
function SDL2Circle_IORead(handle: LongInt; buf: Pointer; offset: QWord;
  length: LongWord): PtrInt; cdecl; external;
function SDL2Circle_IOWrite(handle: LongInt; const buf: Pointer;
  offset: QWord; length: LongWord): PtrInt; cdecl; external;
function SDL2Circle_IOTruncate(handle: LongInt; size: QWord): LongInt;
  cdecl; external;
function SDL2Circle_IOClose(handle: LongInt): LongInt; cdecl; external;
function SDL2Circle_IOUnlink(const path: PAnsiChar): LongInt; cdecl; external;
function SDL2Circle_IOMkdir(const path: PAnsiChar): LongInt; cdecl; external;
function SDL2Circle_IORmdir(const path: PAnsiChar): LongInt; cdecl; external;
function SDL2Circle_IORename(const oldpath, newpath: PAnsiChar): LongInt;
  cdecl; external;

{ THE WORKING DIRECTORY IS ONE SETTING FOR THE WHOLE BOARD, held on core 0.
  Changing it changes it for every core, this library's own file calls
  included. Relative paths are resolved against it; absolute paths are not
  affected by it. GetCwd fills buf and reports -ERANGE if it is too small. }
function SDL2Circle_IOChdir(const path: PAnsiChar): LongInt; cdecl; external;
function SDL2Circle_IOGetCwd(buf: PAnsiChar; size: LongWord): LongInt;
  cdecl; external;
function SDL2Circle_IOStatPath(const path: PAnsiChar;
  st: PSDL2Circle_IOStat): LongInt; cdecl; external;

{ Zero on failure. }
function SDL2Circle_IOOpenDir(const path: PAnsiChar): PtrInt;
  cdecl; external;
{ 1 for an entry, 0 at the end, below zero for an error. }
function SDL2Circle_IOReadDir(dir: PtrInt;
  e: PSDL2Circle_IODirEntry): LongInt; cdecl; external;
procedure SDL2Circle_IOCloseDir(dir: PtrInt); cdecl; external;

implementation

end.
