{
  m8.pas — the Pascal program that proves SDL on this board.

  WHAT THIS ASKS FOR. M0 to M7 proved the language: the heap, the console,
  elapsed time, threads, files and Free Pascal's own packages. None of it went
  near SDL. The console that appears on a screen is the host kernel's library
  writing into the framebuffer itself; no Pascal had ever made a window, a
  renderer or a texture, and the whole of that surface was untested from this
  language. This is the part between a runtime and an application.

  A CLEAN BUILD PROVES NOTHING, and it proves less here than anywhere. Every
  entry point below is a C symbol resolved at link time, so a link that
  succeeds says only that the names matched. Whether the calling convention
  carries the arguments, whether the records this language lays out are the
  records the library reads, and whether a pixel written in Pascal arrives
  where it was aimed — none of that is a link question.

  SO EVERY SECTION DRAWS A KNOWN THING AND THEN READS IT BACK.
  SDL_RenderReadPixels returns SDL's own framebuffer in the coordinates the
  caller drew in, so a program can check its own picture and print a verdict.
  Nothing here needs a human to look at a screen, and nothing here reports
  success for having called something.

  EACH SECTION PRINTS ITS OWN TOLERANCE. Where the answer is exact the section
  says so. Where the path quantises — a texture in a format narrower than the
  framebuffer, a blend that rounds — the section says by how much and judges
  against that.

  THE CONSOLE LEAVES THE SCREEN AT SECTION 2, and that is correct. The host
  kernel attached the screen as a second log destination at boot; the library
  drops it the moment an application initialises SDL video, because that is
  the moment this program takes the display. From there the report is on the
  serial port alone, which is what settles the milestone in any case.

  WHAT THIS PROGRAM PUTS ON THE CARD: nothing. It opens no file and writes no
  file. The only state it leaves anywhere is the display, and it hands that
  back at the end.
}
program m8;

{$mode objfpc}
{$H+}

uses
  { THE SDL2 BINDING, EXACTLY AS A PASCAL GAME ALREADY CARRIES IT. Nothing in
    this program is written against a binding of this project's own: the point
    of the exercise is that a port is a relink, so the declarations here are
    the ones every other Pascal SDL program is written against. }
  sdl2,
  { circle-libsdl2's own extensions, which no SDL binding carries because they
    are not in SDL's headers. This is where the application says what display
    it is to be given. }
  sdl2circle,
  SysUtils;

const
  { THE DISPLAY THIS PROGRAM DECLARES FOR ITSELF, and it is deliberately not
    the panel's. The library scales the canvas onto whatever the screen is
    really doing, and an application never learns the real resolution — so a
    canvas that matches nothing on the board exercises the placement instead
    of accidentally avoiding it. Every rectangle below is in these
    coordinates, and so is every pixel read back. }
  CanvasW = 640;
  CanvasH = 480;

  { Section 7's texture, and section 9's. Small enough to compare in full,
    large enough that a pitch that was wrong shows as a shear rather than as
    one bad pixel. }
  TexW = 64;
  TexH = 48;

  { Where the texture is copied. An offset that is not the origin, so a
    destination rectangle that was ignored lands somewhere this can see. }
  DstX = 100;
  DstY = 80;

  { Section 10's alpha, and the rounding the blend is judged to. }
  BlendAlpha  = 128;
  BlendSlack  = 2;

  { Section 8's texture is 5 bits of red, 6 of green and 5 of blue, so the
    round trip through it cannot return more than those. The step of the
    coarsest channel is what a value may move by. }
  R565Step = 8;
  G565Step = 4;

  { Section 12 presents this many frames. }
  PresentFrames = 60;

  { Section 15's wait, and the slack it is judged to. The clock is the
    board's free-running counter and the wait services SDL while it runs, so
    the wait is a floor rather than an exact duration. }
  DelayMillis = 200;
  DelaySlack  = 60;

  { Section 17 watches for this long, for a person who is probably not there. }
  WatchSeconds = 10;

  { The pause between sections. The log channel never blocks and drops a line
    it has no room for, and the console is far slower than this core, so a
    program that prints a long burst can outrun the wire and lose the middle
    of its own report. }
  PaceMillis = 200;

type
  { SDL2 PADS ITS EVENT UNION AND THIS BINDING DOES NOT.

    In C, SDL_Event carries a `padding' member sized to fix the union at 56
    bytes on a 64-bit machine, and SDL_COMPILE_TIME_ASSERT holds it there
    (SDL_events.h). Every entry point that fills an event writes that many
    bytes. The Pascal TSDL_Event has no such member, so it is as large as its
    largest declared variant and no larger — which is smaller.

    Passing the address of a bare TSDL_Event to SDL_PollEvent therefore hands
    SDL a buffer shorter than the one it is documented to fill. On a desktop
    the bytes past the end land in another local; here they land on a stack
    this library allocated.

    So an event is passed as this instead: a variant record whose other arm is
    a byte array comfortably past 56, which costs nothing and cannot be short.
    Section 16 prints both sizes so the difference is on the record rather
    than in a comment. }
  TEventBuffer = record
    case Integer of
      0 : (ev    : TSDL_Event);
      1 : (bytes : array[0..127] of Byte);
  end;

  { A canvas readback. ARGB8888 is what the framebuffer holds and what
    SDL_RenderReadPixels converts from, so asking for it is asking for no
    conversion at all; one pixel is one LongWord, 0xAARRGGBB. }
  TPixels = array of LongWord;

var
  { Every section's verdict, gathered so the last lines can name what failed
    rather than only that something did. }
  Failures : string = '';

  { A check that fails because a component BELOW this program does not do what
    its own documentation says. Kept apart from the failures above, because
    the two ask for different work: a failure here is this parcel's to fix,
    and a divergence is a defect to report to whoever owns the component.
    Neither is hidden and neither is weakened — a divergent check runs exactly
    as it was written and reports exactly what it found. }
  Divergences : string = '';

  Win  : PSDL_Window   = nil;
  Ren  : PSDL_Renderer = nil;
  Pix  : TPixels       = nil;


{****************************************************************************
                          Formatting and verdicts
****************************************************************************}

function Verdict(Yes: Boolean): ShortString;
begin
  if Yes then
    Verdict := 'PASS'
  else
    Verdict := 'FAIL';
end;


function YesNo(Yes: Boolean): ShortString;
begin
  if Yes then
    YesNo := 'yes'
  else
    YesNo := 'no';
end;


{ One section's result. The name is what appears in the closing summary, so it
  is what a reader searches the log for. }
procedure Judge(const Name: string; Yes: Boolean);
begin
  WriteLn('  ', Name, ': ', Verdict(Yes));
  if not Yes then
    Failures := Failures + ' ' + Name;
end;


{ The same, for a check whose answer is settled by a component below this one.
  The citation is what makes it usable: a claim that something else is at
  fault is worth nothing without the line that proves it, and costs somebody a
  day if it is wrong. }
procedure Divergence(const Name: string; Yes: Boolean; const Cite: string);
begin
  WriteLn('  ', Name, ': ', Verdict(Yes));
  if not Yes then
  begin
    WriteLn('    ^ NOT this program''s to fix. ', Cite);
    Divergences := Divergences + ' ' + Name;
  end;
end;


procedure Pace;
begin
  SDL_Delay(PaceMillis);
end;


procedure Section(const Number, Title: string);
begin
  Pace;
  WriteLn;
  WriteLn('--- ', Number, '. ', Title, ' ---');
end;


{ SDL's last error, as a Pascal string. Empty when there is none. }
function LastError: string;
var
  P : PAnsiChar;
begin
  P := SDL_GetError;
  if P = nil then
    LastError := ''
  else
    LastError := string(AnsiString(P));
end;


function Hex8(V: LongWord): string;
begin
  Hex8 := '$' + IntToHex(V, 8);
end;


{****************************************************************************
                        Pixels: writing and reading
****************************************************************************}

{ ARGB8888, the one format the framebuffer holds. }
function ARGB(A, R, G, B: Byte): LongWord;
begin
  ARGB := (LongWord(A) shl 24) or (LongWord(R) shl 16)
       or (LongWord(G) shl 8) or LongWord(B);
end;


function AlphaOf(V: LongWord): Byte; begin AlphaOf := (V shr 24) and $FF; end;
function RedOf  (V: LongWord): Byte; begin RedOf   := (V shr 16) and $FF; end;
function GreenOf(V: LongWord): Byte; begin GreenOf := (V shr  8) and $FF; end;
function BlueOf (V: LongWord): Byte; begin BlueOf  :=  V         and $FF; end;


{ The whole canvas, out of SDL's own framebuffer, in the coordinates this
  program drew in. Everything drawn since the frame began is in it, whether or
  not the frame has been presented. }
function ReadCanvas: Boolean;
begin
  ReadCanvas := SDL_RenderReadPixels(Ren, nil, SDL_PIXELFORMAT_ARGB8888,
                                     @Pix[0], CanvasW * SizeOf(LongWord)) = 0;
  if not ReadCanvas then
    WriteLn('  SDL_RenderReadPixels refused: ', LastError);
end;


function At(X, Y: LongInt): LongWord;
begin
  At := Pix[Y * CanvasW + X];
end;


{ Two colours the same to within a per-channel distance. Alpha is not compared:
  the framebuffer is opaque and what it holds in that byte is the library's
  business, not this program's. }
function Near(Got, Want: LongWord; Slack: LongInt): Boolean;

  function Close(A, B: Byte): Boolean;
  begin
    Close := Abs(LongInt(A) - LongInt(B)) <= Slack;
  end;

begin
  Near := Close(RedOf(Got), RedOf(Want))
      and Close(GreenOf(Got), GreenOf(Want))
      and Close(BlueOf(Got), BlueOf(Want));
end;


function Same(Got, Want: LongWord): Boolean;
begin
  Same := Near(Got, Want, 0);
end;


{ What the texture sections draw: a pattern with no symmetry in either axis, so
  a copy that mirrored, transposed or shifted it cannot come back looking
  right. The row and the column are both in the colour. }
function Pattern(X, Y: LongInt): LongWord;
begin
  Pattern := ARGB($FF, Byte(16 + X * 3), Byte(32 + Y * 5), Byte(200 - X * 2));
end;


{****************************************************************************
                                 Sections
****************************************************************************}

{ 1. What this program is talking to. Nothing is judged here: these are
     readings, and a reading that surprised somebody is worth having on the
     log whatever it says. }
procedure ReportTheLibrary;
var
  Ver : TSDL_Version;
begin
  Section('1', 'the library this program is bound to');
  SDL_GetVersion(@Ver);
  WriteLn('  SDL version   : ', Ver.major, '.', Ver.minor, '.', Ver.patch);
  WriteLn('  SDL revision  : ', string(AnsiString(SDL_GetRevision)));
  WriteLn('  SDL platform  : ', string(AnsiString(SDL_GetPlatform)));
  WriteLn('  the console leaves the screen at the next section, and that is');
  WriteLn('  correct: the library drops the screen destination when an');
  WriteLn('  application initialises SDL video. Serial carries the rest.');
end;


{ 2. The display this program is to be given, and the library started on it. }
function DeclareAndInit: Boolean;
var
  OK : Boolean;
begin
  Section('2', 'the virtual display, declared from Pascal, and SDL_Init');

  OK := SDL2Circle_DeclareVirtualDevice(32, CanvasW, CanvasH) = 0;
  WriteLn('  declared ', CanvasW, 'x', CanvasH, ' at 32bpp: ', YesNo(OK));
  if not OK then
    WriteLn('  refused: ', LastError);
  Judge('2a declare virtual device', OK);

  if OK then
  begin
    OK := SDL_Init(SDL_INIT_VIDEO) = 0;
    if not OK then
      WriteLn('  SDL_Init refused: ', LastError);
  end;
  Judge('2b SDL_Init(SDL_INIT_VIDEO)', OK);

  if OK then
  begin
    WriteLn('  SDL_WasInit(VIDEO)  : ', Hex8(SDL_WasInit(SDL_INIT_VIDEO)));
    WriteLn('  SDL_WasInit(EVENTS) : ', Hex8(SDL_WasInit(SDL_INIT_EVENTS)),
            '  (video implies events)');
    { THE EVENTS SUBSYSTEM REALLY IS UP — section 13 takes events off the
      queue and section 18 reads the keyboard, and neither could if it were
      not. What is wrong is the bookkeeping SDL_WasInit answers from, and an
      application branches on that: `if (!SDL_WasInit(SDL_INIT_EVENTS))' is
      how a great many of them decide whether to bring it up. }
    Divergence('2c events came up with video',
          SDL_WasInit(SDL_INIT_EVENTS) <> 0,
          'circle-libsdl2 ships the genuine SDL2 header, which states the ' +
          'implication twice - include/SDL2/SDL.h:85 "SDL_INIT_VIDEO ' +
          'implies SDL_INIT_EVENTS" and :118 "automatically initializes ' +
          'the events subsystem" - and src/init.cpp records only the flags ' +
          'it was passed ("s_initialized |= flags"), applying no ' +
          'implication. Upstream SDL2 ORs SDL_INIT_EVENTS into flags first.');
  end;

  DeclareAndInit := OK;
end;


{ 3. Every SDL answer about the display must be the declaration and nothing
     else. Tolerance: exact. These are numbers this program handed in. }
procedure CheckDisplayAnswers;
var
  Mode   : TSDL_DisplayMode;
  R      : TSDL_Rect;
  OK     : Boolean;
begin
  Section('3', 'every display answer against the declaration');
  WriteLn('  tolerance: exact. The library was told these numbers.');

  WriteLn('  SDL_GetNumVideoDisplays: ', SDL_GetNumVideoDisplays);
  Judge('3a one display', SDL_GetNumVideoDisplays = 1);

  FillChar(Mode, SizeOf(Mode), 0);
  OK := SDL_GetCurrentDisplayMode(0, @Mode) = 0;
  WriteLn('  current display mode   : ', Mode.w, 'x', Mode.h,
          ' @ ', Mode.refresh_rate, 'Hz, format ', Hex8(Mode.format));
  Judge('3b current mode is the canvas',
        OK and (Mode.w = CanvasW) and (Mode.h = CanvasH));

  FillChar(Mode, SizeOf(Mode), 0);
  OK := SDL_GetDesktopDisplayMode(0, @Mode) = 0;
  WriteLn('  desktop display mode   : ', Mode.w, 'x', Mode.h);
  Judge('3c desktop mode is the canvas',
        OK and (Mode.w = CanvasW) and (Mode.h = CanvasH));

  FillChar(R, SizeOf(R), 0);
  OK := SDL_GetDisplayBounds(0, @R) = 0;
  WriteLn('  display bounds         : ', R.w, 'x', R.h, ' at ', R.x, ',', R.y);
  Judge('3d bounds are the canvas',
        OK and (R.x = 0) and (R.y = 0) and (R.w = CanvasW) and (R.h = CanvasH));
end;


{ 4. A window, and what it reports about itself. DISPLAY.md is explicit that
     the flags describe the machine rather than the request, so the three that
     matter are checked against that and not against what was asked for. }
procedure MakeWindow;
var
  W, H  : SInt32;
  Flags : LongWord;
begin
  Section('4', 'the window');

  Win := SDL_CreateWindow('circle-libfpc m8',
                          SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                          CanvasW, CanvasH, SDL_WINDOW_SHOWN);
  if Win = nil then
    WriteLn('  SDL_CreateWindow refused: ', LastError);
  Judge('4a a window exists', Win <> nil);
  if Win = nil then
    Exit;

  W := 0; H := 0;
  SDL_GetWindowSize(Win, @W, @H);
  WriteLn('  window size : ', W, 'x', H, '  (asked for ', CanvasW, 'x',
          CanvasH, ')');
  Judge('4b the window is the canvas', (W = CanvasW) and (H = CanvasH));

  Flags := SDL_GetWindowFlags(Win);
  WriteLn('  window flags: ', Hex8(Flags));
  WriteLn('    SHOWN       : ', YesNo((Flags and SDL_WINDOW_SHOWN) <> 0),
          '   (always set: the surface cannot leave the glass)');
  WriteLn('    INPUT_FOCUS : ', YesNo((Flags and SDL_WINDOW_INPUT_FOCUS) <> 0),
          '   (always set: there is no window manager to take it away)');
  WriteLn('    OPENGL      : ', YesNo((Flags and SDL_WINDOW_OPENGL) <> 0),
          '   (never set: there is no accelerated renderer to report)');
  Judge('4c flags describe the machine',
        ((Flags and SDL_WINDOW_SHOWN) <> 0) and
        ((Flags and SDL_WINDOW_INPUT_FOCUS) <> 0) and
        ((Flags and SDL_WINDOW_OPENGL) = 0));
end;


{ 5. A renderer, and what it says it can do. }
procedure MakeRenderer;
var
  Info : TSDL_RendererInfo;
begin
  Section('5', 'the renderer');

  Ren := SDL_CreateRenderer(Win, -1, SDL_RENDERER_SOFTWARE);
  if Ren = nil then
    WriteLn('  SDL_CreateRenderer refused: ', LastError);
  Judge('5a a renderer exists', Ren <> nil);
  if Ren = nil then
    Exit;

  FillChar(Info, SizeOf(Info), 0);
  if SDL_GetRendererInfo(Ren, @Info) = 0 then
  begin
    WriteLn('  renderer name    : ', string(AnsiString(Info.name)));
    WriteLn('  renderer flags   : ', Hex8(Info.flags));
    WriteLn('  texture formats  : ', Info.num_texture_formats,
            ', first ', Hex8(Info.texture_formats[0]));
    WriteLn('  max texture size : ', Info.max_texture_width, 'x',
            Info.max_texture_height);
    Judge('5b software renderer, ARGB8888 textures',
          ((Info.flags and SDL_RENDERER_SOFTWARE) <> 0) and
          (Info.num_texture_formats >= 1) and
          (Info.texture_formats[0] = SDL_PIXELFORMAT_ARGB8888));
  end
  else
  begin
    WriteLn('  SDL_GetRendererInfo refused: ', LastError);
    Judge('5b software renderer, ARGB8888 textures', False);
  end;

  SetLength(Pix, CanvasW * CanvasH);
end;


{ 6. The simplest thing that can be checked: a colour put on the whole canvas
     and three rectangles on top of it, read back. Tolerance: exact. Nothing
     is scaled and nothing is blended, so every byte is the byte that was
     asked for. }
procedure DrawAndReadBack;
const
  Back   = $FF203040;
  BoxA   = $FFFF0000;
  BoxB   = $FF00FF00;
  BoxC   = $FF0000FF;
var
  R  : TSDL_Rect;
  OK : Boolean;
begin
  Section('6', 'flat colour and rectangles, read back');
  WriteLn('  tolerance: exact. No scaling and no blending is in this path.');

  SDL_SetRenderDrawColor(Ren, RedOf(Back), GreenOf(Back), BlueOf(Back), 255);
  SDL_RenderClear(Ren);

  R.x := 10;  R.y := 10;  R.w := 40; R.h := 30;
  SDL_SetRenderDrawColor(Ren, RedOf(BoxA), GreenOf(BoxA), BlueOf(BoxA), 255);
  SDL_RenderFillRect(Ren, @R);

  R.x := 300; R.y := 200; R.w := 50; R.h := 50;
  SDL_SetRenderDrawColor(Ren, RedOf(BoxB), GreenOf(BoxB), BlueOf(BoxB), 255);
  SDL_RenderFillRect(Ren, @R);

  R.x := CanvasW - 20; R.y := CanvasH - 20; R.w := 20; R.h := 20;
  SDL_SetRenderDrawColor(Ren, RedOf(BoxC), GreenOf(BoxC), BlueOf(BoxC), 255);
  SDL_RenderFillRect(Ren, @R);

  OK := ReadCanvas;
  Judge('6a the canvas can be read back', OK);
  if not OK then
    Exit;

  WriteLn('  background at 200,300      : ', Hex8(At(200, 300)),
          '  want ', Hex8(Back));
  WriteLn('  red box at 30,20           : ', Hex8(At(30, 20)),
          '  want ', Hex8(BoxA));
  WriteLn('  green box at 320,220       : ', Hex8(At(320, 220)),
          '  want ', Hex8(BoxB));
  WriteLn('  blue box at bottom right   : ',
          Hex8(At(CanvasW - 1, CanvasH - 1)), '  want ', Hex8(BoxC));
  WriteLn('  just outside the red box   : ', Hex8(At(50, 20)),
          '  want ', Hex8(Back), ' (the rectangle is half open)');

  Judge('6b flat fill', Same(At(200, 300), Back));
  Judge('6c rectangles land where they were aimed',
        Same(At(30, 20), BoxA) and Same(At(320, 220), BoxB) and
        Same(At(CanvasW - 1, CanvasH - 1), BoxC));
  Judge('6d a rectangle stops at its own edge', Same(At(50, 20), Back));
end;


{ 7. A streaming texture in the framebuffer's own format, filled through
     SDL_UpdateTexture and copied at its own size. DISPLAY.md: a destination
     the same size as the source is an unscaled blit, so every pixel of the
     pattern must arrive unchanged. Tolerance: exact, over the whole area
     rather than at sample points. }
procedure TextureUpdateAndCopy;
var
  Tex     : PSDL_Texture;
  Src     : array of LongWord;
  Dst     : TSDL_Rect;
  X, Y    : LongInt;
  Bad     : LongInt;
  Fmt     : UInt32;
  Acc, W, H : SInt32;
begin
  Section('7', 'a streaming ARGB8888 texture, updated and copied');
  WriteLn('  tolerance: exact, over all ', TexW * TexH,
          ' pixels. Source and destination are the same size.');

  Tex := SDL_CreateTexture(Ren, SDL_PIXELFORMAT_ARGB8888,
                           SDL_TEXTUREACCESS_STREAMING, TexW, TexH);
  if Tex = nil then
    WriteLn('  SDL_CreateTexture refused: ', LastError);
  Judge('7a a texture exists', Tex <> nil);
  if Tex = nil then
    Exit;

  Fmt := 0; Acc := 0; W := 0; H := 0;
  SDL_QueryTexture(Tex, @Fmt, @Acc, @W, @H);
  WriteLn('  queried back     : ', W, 'x', H, ' format ', Hex8(Fmt),
          ' access ', Acc);
  Judge('7b the texture is what was asked for',
        (W = TexW) and (H = TexH) and (Fmt = SDL_PIXELFORMAT_ARGB8888));

  SetLength(Src, TexW * TexH);
  for Y := 0 to TexH - 1 do
    for X := 0 to TexW - 1 do
      Src[Y * TexW + X] := Pattern(X, Y);

  if SDL_UpdateTexture(Tex, nil, @Src[0], TexW * SizeOf(LongWord)) <> 0 then
    WriteLn('  SDL_UpdateTexture refused: ', LastError);

  SDL_SetRenderDrawColor(Ren, 0, 0, 0, 255);
  SDL_RenderClear(Ren);

  Dst.x := DstX; Dst.y := DstY; Dst.w := TexW; Dst.h := TexH;
  if SDL_RenderCopy(Ren, Tex, nil, @Dst) <> 0 then
    WriteLn('  SDL_RenderCopy refused: ', LastError);

  if ReadCanvas then
  begin
    Bad := 0;
    for Y := 0 to TexH - 1 do
      for X := 0 to TexW - 1 do
        if not Same(At(DstX + X, DstY + Y), Pattern(X, Y)) then
          Inc(Bad);
    WriteLn('  pixels that differ: ', Bad, ' of ', TexW * TexH);
    WriteLn('  sample at 0,0    : ', Hex8(At(DstX, DstY)),
            '  want ', Hex8(Pattern(0, 0)));
    WriteLn('  sample at w-1,h-1: ',
            Hex8(At(DstX + TexW - 1, DstY + TexH - 1)),
            '  want ', Hex8(Pattern(TexW - 1, TexH - 1)));
    Judge('7c every pixel arrived unchanged', Bad = 0);
    Judge('7d nothing was drawn outside the destination',
          Same(At(DstX - 1, DstY), $FF000000) and
          Same(At(DstX + TexW, DstY), $FF000000));
  end
  else
    Judge('7c every pixel arrived unchanged', False);

  SDL_DestroyTexture(Tex);
end;


{ 8. The same, in a format narrower than the framebuffer. FEATURES.md says a
     texture is always STORED as ARGB8888 and the application's format is
     honoured at the edge: pixels handed in are converted on the way in. So
     what comes back is the pattern as 5:6:5 can carry it, and the tolerance
     is that quantisation and nothing else. }
procedure NarrowTexture;
var
  Tex   : PSDL_Texture;
  Src   : array of Word;
  Dst   : TSDL_Rect;
  X, Y  : LongInt;
  Bad   : LongInt;
  Want  : LongWord;
  Got   : LongWord;
  Slack : LongInt;
begin
  Section('8', 'a texture in RGB565, converted at the edge');
  Slack := R565Step;
  if G565Step > Slack then
    Slack := G565Step;
  WriteLn('  tolerance: ', Slack, ' per channel. 5 bits of red and blue is a',
          ' step of ', R565Step, ',');
  WriteLn('  6 bits of green a step of ', G565Step,
          '. Nothing here can be exact and nothing pretends to be.');

  Tex := SDL_CreateTexture(Ren, SDL_PIXELFORMAT_RGB565,
                           SDL_TEXTUREACCESS_STREAMING, TexW, TexH);
  if Tex = nil then
  begin
    WriteLn('  SDL_CreateTexture(RGB565) refused: ', LastError);
    Judge('8a a 16-bit texture exists', False);
    Exit;
  end;
  Judge('8a a 16-bit texture exists', True);

  SetLength(Src, TexW * TexH);
  for Y := 0 to TexH - 1 do
    for X := 0 to TexW - 1 do
    begin
      Want := Pattern(X, Y);
      Src[Y * TexW + X] :=
        Word(((LongWord(RedOf(Want))   shr 3) shl 11) or
             ((LongWord(GreenOf(Want)) shr 2) shl  5) or
              (LongWord(BlueOf(Want))  shr 3));
    end;

  if SDL_UpdateTexture(Tex, nil, @Src[0], TexW * SizeOf(Word)) <> 0 then
    WriteLn('  SDL_UpdateTexture refused: ', LastError);

  SDL_SetRenderDrawColor(Ren, 0, 0, 0, 255);
  SDL_RenderClear(Ren);
  Dst.x := DstX; Dst.y := DstY; Dst.w := TexW; Dst.h := TexH;
  SDL_RenderCopy(Ren, Tex, nil, @Dst);

  if ReadCanvas then
  begin
    Bad := 0;
    for Y := 0 to TexH - 1 do
      for X := 0 to TexW - 1 do
        if not Near(At(DstX + X, DstY + Y), Pattern(X, Y), Slack) then
          Inc(Bad);
    Got  := At(DstX + 3, DstY + 3);
    Want := Pattern(3, 3);
    WriteLn('  pixels outside tolerance: ', Bad, ' of ', TexW * TexH);
    WriteLn('  sample at 3,3           : ', Hex8(Got), '  from ', Hex8(Want));
    Judge('8b the pattern survived the narrow format', Bad = 0);
  end
  else
    Judge('8b the pattern survived the narrow format', False);

  SDL_DestroyTexture(Tex);
end;


{ 9. The other way of filling a texture: lock it, write into the buffer SDL
     hands back at the pitch it names, unlock. Tolerance: exact — this texture
     is ARGB8888, so FEATURES.md says there is no staging buffer and no
     conversion at all. }
procedure LockAndWrite;
var
  Tex    : PSDL_Texture;
  P      : Pointer;
  Pitch  : SInt32;
  Row    : PLongWord;
  X, Y   : LongInt;
  Bad    : LongInt;
  Dst    : TSDL_Rect;
begin
  Section('9', 'a texture filled through SDL_LockTexture');
  WriteLn('  tolerance: exact. ARGB8888 is the stored format, so this path',
          ' converts nothing.');

  Tex := SDL_CreateTexture(Ren, SDL_PIXELFORMAT_ARGB8888,
                           SDL_TEXTUREACCESS_STREAMING, TexW, TexH);
  if Tex = nil then
  begin
    WriteLn('  SDL_CreateTexture refused: ', LastError);
    Judge('9a the texture locked', False);
    Exit;
  end;

  P := nil; Pitch := 0;
  if SDL_LockTexture(Tex, nil, @P, @Pitch) <> 0 then
  begin
    WriteLn('  SDL_LockTexture refused: ', LastError);
    Judge('9a the texture locked', False);
    SDL_DestroyTexture(Tex);
    Exit;
  end;
  WriteLn('  locked: buffer at ', Hex8(LongWord(PtrUInt(P) and $FFFFFFFF)),
          ', pitch ', Pitch, ' bytes for ', TexW, ' pixels');
  Judge('9a the texture locked', (P <> nil) and
        (Pitch >= LongInt(TexW * SizeOf(LongWord))));

  for Y := 0 to TexH - 1 do
  begin
    Row := PLongWord(PtrUInt(P) + PtrUInt(Y * Pitch));
    for X := 0 to TexW - 1 do
      Row[X] := Pattern(X, Y);
  end;
  SDL_UnlockTexture(Tex);

  SDL_SetRenderDrawColor(Ren, 0, 0, 0, 255);
  SDL_RenderClear(Ren);
  Dst.x := DstX; Dst.y := DstY; Dst.w := TexW; Dst.h := TexH;
  SDL_RenderCopy(Ren, Tex, nil, @Dst);

  if ReadCanvas then
  begin
    Bad := 0;
    for Y := 0 to TexH - 1 do
      for X := 0 to TexW - 1 do
        if not Same(At(DstX + X, DstY + Y), Pattern(X, Y)) then
          Inc(Bad);
    WriteLn('  pixels that differ: ', Bad, ' of ', TexW * TexH);
    Judge('9b what was written through the lock is what arrived', Bad = 0);
  end
  else
    Judge('9b what was written through the lock is what arrived', False);

  SDL_DestroyTexture(Tex);
end;


{ 10. Alpha blending. A flat background, then the same texture over it at half
      alpha. SDL's blend is dst = (src*a + dst*(255-a)) / 255, so the answer is
      arithmetic this program can work out for itself; the tolerance is the
      rounding of that division. }
procedure BlendOverBackground;
const
  Back = $FF102030;
var
  Tex    : PSDL_Texture;
  Src    : array of LongWord;
  Dst    : TSDL_Rect;
  X, Y   : LongInt;
  Bad    : LongInt;
  Want   : LongWord;
  S      : LongWord;

  function Mix(SrcC, DstC: Byte): Byte;
  begin
    Mix := Byte((LongInt(SrcC) * BlendAlpha +
                 LongInt(DstC) * (255 - BlendAlpha)) div 255);
  end;

begin
  Section('10', 'alpha blending over a known background');
  WriteLn('  tolerance: ', BlendSlack, ' per channel, which is the rounding',
          ' of SDL''s own blend.');

  Tex := SDL_CreateTexture(Ren, SDL_PIXELFORMAT_ARGB8888,
                           SDL_TEXTUREACCESS_STREAMING, TexW, TexH);
  if Tex = nil then
  begin
    WriteLn('  SDL_CreateTexture refused: ', LastError);
    Judge('10a the blend is the arithmetic', False);
    Exit;
  end;

  SetLength(Src, TexW * TexH);
  for Y := 0 to TexH - 1 do
    for X := 0 to TexW - 1 do
      Src[Y * TexW + X] := Pattern(X, Y);
  SDL_UpdateTexture(Tex, nil, @Src[0], TexW * SizeOf(LongWord));

  SDL_SetTextureBlendMode(Tex, SDL_BLENDMODE_BLEND);
  SDL_SetTextureAlphaMod(Tex, BlendAlpha);

  SDL_SetRenderDrawColor(Ren, RedOf(Back), GreenOf(Back), BlueOf(Back), 255);
  SDL_RenderClear(Ren);
  Dst.x := DstX; Dst.y := DstY; Dst.w := TexW; Dst.h := TexH;
  SDL_RenderCopy(Ren, Tex, nil, @Dst);

  if ReadCanvas then
  begin
    Bad := 0;
    for Y := 0 to TexH - 1 do
      for X := 0 to TexW - 1 do
      begin
        S := Pattern(X, Y);
        Want := ARGB(255, Mix(RedOf(S), RedOf(Back)),
                          Mix(GreenOf(S), GreenOf(Back)),
                          Mix(BlueOf(S), BlueOf(Back)));
        if not Near(At(DstX + X, DstY + Y), Want, BlendSlack) then
          Inc(Bad);
      end;
    S := Pattern(5, 5);
    Want := ARGB(255, Mix(RedOf(S), RedOf(Back)),
                      Mix(GreenOf(S), GreenOf(Back)),
                      Mix(BlueOf(S), BlueOf(Back)));
    WriteLn('  alpha              : ', BlendAlpha, ' of 255');
    WriteLn('  sample at 5,5      : ', Hex8(At(DstX + 5, DstY + 5)),
            '  want ', Hex8(Want));
    WriteLn('  pixels outside tolerance: ', Bad, ' of ', TexW * TexH);
    Judge('10a the blend is the arithmetic', Bad = 0);
  end
  else
    Judge('10a the blend is the arithmetic', False);

  SDL_DestroyTexture(Tex);
end;


{ 11. SDL_RenderCopyEx. FEATURES.md: mirroring works in all three
      combinations, and an angle is refused rather than quietly ignored. Both
      halves of that are checked, because a refusal that did not happen is a
      picture silently drawn wrong. }
procedure MirrorAndRefuseAngle;
var
  Tex   : PSDL_Texture;
  Src   : array of LongWord;
  Dst   : TSDL_Rect;
  X, Y  : LongInt;
  Bad   : LongInt;
  Rc    : SInt32;
begin
  Section('11', 'SDL_RenderCopyEx: mirrored, and an angle refused');
  WriteLn('  tolerance: exact for the mirror. The refusal is a return value.');

  Tex := SDL_CreateTexture(Ren, SDL_PIXELFORMAT_ARGB8888,
                           SDL_TEXTUREACCESS_STREAMING, TexW, TexH);
  if Tex = nil then
  begin
    WriteLn('  SDL_CreateTexture refused: ', LastError);
    Judge('11a a horizontal mirror', False);
    Exit;
  end;

  SetLength(Src, TexW * TexH);
  for Y := 0 to TexH - 1 do
    for X := 0 to TexW - 1 do
      Src[Y * TexW + X] := Pattern(X, Y);
  SDL_UpdateTexture(Tex, nil, @Src[0], TexW * SizeOf(LongWord));

  SDL_SetRenderDrawColor(Ren, 0, 0, 0, 255);
  SDL_RenderClear(Ren);
  Dst.x := DstX; Dst.y := DstY; Dst.w := TexW; Dst.h := TexH;
  Rc := SDL_RenderCopyEx(Ren, Tex, nil, @Dst, 0.0, nil, SDL_FLIP_HORIZONTAL);
  if Rc <> 0 then
    WriteLn('  SDL_RenderCopyEx(flip) refused: ', LastError);

  if ReadCanvas then
  begin
    Bad := 0;
    for Y := 0 to TexH - 1 do
      for X := 0 to TexW - 1 do
        if not Same(At(DstX + X, DstY + Y), Pattern(TexW - 1 - X, Y)) then
          Inc(Bad);
    WriteLn('  pixels that differ from the mirror: ', Bad, ' of ',
            TexW * TexH);
    Judge('11a a horizontal mirror', (Rc = 0) and (Bad = 0));
  end
  else
    Judge('11a a horizontal mirror', False);

  SDL_ClearError;
  Rc := SDL_RenderCopyEx(Ren, Tex, nil, @Dst, 45.0, nil, SDL_FLIP_NONE);
  WriteLn('  an angle of 45 degrees returns ', Rc, ': ', LastError);
  Judge('11b an angle is refused rather than ignored', Rc <> 0);

  SDL_DestroyTexture(Tex);
end;


{ 12. Frames actually presented. The rate is the display's business, so this
      reports rather than judges it; what is judged is that the calls return
      and that time passed. }
procedure PresentFramesLoop;
var
  Tex    : PSDL_Texture;
  Src    : array of LongWord;
  Dst    : TSDL_Rect;
  I      : LongInt;
  X, Y   : LongInt;
  T0, T1 : UInt32;
  Elapsed: UInt32;
begin
  Section('12', 'presenting frames');

  Tex := SDL_CreateTexture(Ren, SDL_PIXELFORMAT_ARGB8888,
                           SDL_TEXTUREACCESS_STREAMING, TexW, TexH);
  if Tex = nil then
  begin
    WriteLn('  SDL_CreateTexture refused: ', LastError);
    Judge('12a frames presented', False);
    Exit;
  end;

  SetLength(Src, TexW * TexH);
  for Y := 0 to TexH - 1 do
    for X := 0 to TexW - 1 do
      Src[Y * TexW + X] := Pattern(X, Y);
  SDL_UpdateTexture(Tex, nil, @Src[0], TexW * SizeOf(LongWord));

  T0 := SDL_GetTicks;
  for I := 0 to PresentFrames - 1 do
  begin
    SDL_SetRenderDrawColor(Ren, Byte(I * 4), 32, 64, 255);
    SDL_RenderClear(Ren);
    Dst.x := DstX + (I mod 32); Dst.y := DstY;
    Dst.w := TexW; Dst.h := TexH;
    SDL_RenderCopy(Ren, Tex, nil, @Dst);
    SDL_RenderPresent(Ren);
  end;
  T1 := SDL_GetTicks;
  Elapsed := T1 - T0;

  WriteLn('  frames presented : ', PresentFrames);
  WriteLn('  elapsed          : ', Elapsed, ' ms');
  if Elapsed > 0 then
    WriteLn('  rate             : ',
            (LongWord(PresentFrames) * 1000) div LongWord(Elapsed), ' fps')
  else
    WriteLn('  rate             : immeasurable');
  WriteLn('  tolerance: none is applied to the rate. Presenting waits for the');
  WriteLn('  raster, so the number is the panel''s and not this program''s.');
  Judge('12a frames presented and time passed', Elapsed > 0);

  SDL_DestroyTexture(Tex);
end;


{ 13. The event queue, with nobody at the bench.

      What can be settled without a key press: that the subsystem is up, that
      a poll with nothing pending answers so rather than blocking or inventing
      an event, and that an event this program puts in comes back out
      unchanged. The last of those is the real test — it is the queue carrying
      a structure this language laid out. }
procedure EventQueueWithoutAHand;
var
  Buf     : TEventBuffer;
  Pushed  : TEventBuffer;
  Drained : LongInt;
  Got     : LongInt;
  OK      : Boolean;
begin
  Section('13', 'the event queue, with nobody at the bench');

  SDL_PumpEvents;
  Drained := 0;
  FillChar(Buf, SizeOf(Buf), 0);
  while SDL_PollEvent(@Buf.ev) = 1 do
  begin
    Inc(Drained);
    if Drained > 1000 then
      Break;
  end;
  WriteLn('  events waiting at the start: ', Drained,
          ' (drained before anything is judged)');

  Judge('13a a poll with nothing pending answers 0',
        SDL_PollEvent(@Buf.ev) = 0);
  Judge('13b SDL_HasEvents agrees',
        SDL_HasEvents(SDL_FIRSTEVENT, SDL_LASTEVENT) = SDL_FALSE);

  { A user event, out and back. Every field is checked, because a queue that
    copied the wrong number of bytes would return the type and lose the rest. }
  FillChar(Pushed, SizeOf(Pushed), 0);
  Pushed.ev.type_      := SDL_USEREVENT;
  Pushed.ev.user.type_ := SDL_USEREVENT;
  Pushed.ev.user.code  := 12345;
  Pushed.ev.user.data1 := Pointer(PtrUInt($5A5A5A5A));
  Pushed.ev.user.data2 := Pointer(PtrUInt($A5A5A5A5));

  Got := SDL_PushEvent(@Pushed.ev);
  WriteLn('  SDL_PushEvent returned  : ', Got, ' (1 means queued)');

  FillChar(Buf, SizeOf(Buf), 0);
  OK := (Got = 1) and (SDL_PollEvent(@Buf.ev) = 1);
  if OK then
  begin
    WriteLn('  came back: type ', Hex8(Buf.ev.type_),
            ' code ', Buf.ev.user.code);
    WriteLn('             data1 ', Hex8(LongWord(PtrUInt(Buf.ev.user.data1))),
            ' data2 ', Hex8(LongWord(PtrUInt(Buf.ev.user.data2))));
    OK := (Buf.ev.type_ = SDL_USEREVENT) and
          (Buf.ev.user.code = 12345) and
          (PtrUInt(Buf.ev.user.data1) = PtrUInt($5A5A5A5A)) and
          (PtrUInt(Buf.ev.user.data2) = PtrUInt($A5A5A5A5));
  end
  else
    WriteLn('  nothing came back');
  Judge('13c an event goes in and comes out unchanged', OK);

  Judge('13d the queue is empty again', SDL_PollEvent(@Buf.ev) = 0);
end;


{ 14. The keyboard, as far as it can be read with nothing held down. INPUT.md
      makes two promises that hold without a hand on the bench: the state array
      is a scancode per entry, and the scancode/keycode mapping is its own
      inverse. }
procedure KeyboardWithoutAHand;
var
  State   : PUInt8;
  NumKeys : SInt32;
  Held    : LongInt;
  I       : LongInt;
  Bad     : LongInt;
  Sc      : TSDL_ScanCode;
  Sym     : TSDL_KeyCode;
begin
  Section('14', 'the keyboard, with nothing held down');

  NumKeys := 0;
  State := SDL_GetKeyboardState(@NumKeys);
  WriteLn('  state array      : ', YesNo(State <> nil),
          ', ', NumKeys, ' entries (SDL_NUM_SCANCODES is ',
          LongInt(SDL_NUM_SCANCODES), ')');
  Judge('14a a scancode per entry',
        (State <> nil) and (NumKeys = LongInt(SDL_NUM_SCANCODES)));

  Held := 0;
  if State <> nil then
    for I := 0 to NumKeys - 1 do
      if PUInt8(PtrUInt(State) + PtrUInt(I))^ <> 0 then
        Inc(Held);
  WriteLn('  keys held        : ', Held, ' (nobody is at the bench)');
  Judge('14b nothing is held', Held = 0);

  WriteLn('  modifier state   : ', Hex8(LongWord(SDL_GetModState)));
  Judge('14c no modifier is held', SDL_GetModState = KMOD_NONE);

  { Every scancode that maps to a keycode must map back to itself. INPUT.md
    states this as a property of the pair rather than of either one. }
  Bad := 0;
  for I := 1 to LongInt(SDL_NUM_SCANCODES) - 1 do
  begin
    Sc  := TSDL_ScanCode(I);
    Sym := SDL_GetKeyFromScancode(Sc);
    if Sym <> 0 then
      if SDL_GetScancodeFromKey(Sym) <> Sc then
        Inc(Bad);
  end;
  WriteLn('  scancodes whose keycode does not map back: ', Bad);
  Judge('14d scancode and keycode are each other''s inverse', Bad = 0);

  WriteLn('  a few names      : ',
          string(AnsiString(SDL_GetScancodeName(SDL_SCANCODE_A))), ', ',
          string(AnsiString(SDL_GetScancodeName(SDL_SCANCODE_ESCAPE))), ', ',
          string(AnsiString(SDL_GetKeyName(SDLK_RETURN))));
  Judge('14e the names are there',
        (SDL_GetScancodeName(SDL_SCANCODE_A) <> nil) and
        (SDL_GetScancodeName(SDL_SCANCODE_A)^ <> #0));
end;


{ 15. The mouse and the pads, as readings. Nothing is judged: what is plugged
      into the bench is not this program's business, and a board with no mouse
      is not a failing board. }
procedure PointersAndPads;
var
  X, Y  : SInt32;
  Btn   : UInt32;
  N     : SInt32;
  I     : LongInt;
begin
  Section('15', 'the mouse and the pads, as readings');
  WriteLn('  nothing here is judged. What is plugged in is the bench''s',
          ' business.');

  X := 0; Y := 0;
  Btn := SDL_GetMouseState(@X, @Y);
  WriteLn('  mouse at         : ', X, ',', Y, ' buttons ', Hex8(Btn));

  N := SDL_NumJoysticks;
  WriteLn('  joysticks        : ', N);
  for I := 0 to N - 1 do
    WriteLn('    ', I, ': ',
            string(AnsiString(SDL_JoystickNameForIndex(I))),
            '  game controller: ',
            YesNo(SDL_IsGameController(I) = SDL_TRUE));
end;


{ 16. The two sizes that have to agree, and the error channel.

      The event size is here rather than beside the queue because it is a
      property of this binding rather than of the library: the host kernel
      prints the C number on its own line and the two are read together. }
procedure SizesAndErrors;
var
  Redeclared : SInt32;
begin
  Section('16', 'record sizes, and the error channel');

  WriteLn('  SizeOf(TSDL_Event) in Pascal : ', SizeOf(TSDL_Event));
  WriteLn('  SizeOf(TSDL_Rect)            : ', SizeOf(TSDL_Rect), ' (want 16)');
  WriteLn('  SizeOf(TSDL_DisplayMode)     : ', SizeOf(TSDL_DisplayMode),
          ' (want 24)');
  WriteLn('  the host kernel prints sizeof(SDL_Event) from C. If the Pascal');
  WriteLn('  number is smaller, this binding''s event record is short of the');
  WriteLn('  union SDL fills, and every event is passed through a padded');
  WriteLn('  buffer here for exactly that reason.');
  Judge('16a the fixed records are the C records',
        (SizeOf(TSDL_Rect) = 16) and (SizeOf(TSDL_DisplayMode) = 24));

  SDL_ClearError;
  WriteLn('  after SDL_ClearError, the error is "', LastError, '"');
  Judge('16b the error clears', LastError = '');

  { PROVOKE A REAL REFUSAL rather than setting the error by hand: a refusal
    has to write the channel for the channel to be worth reading.

    A SECOND VIRTUAL DEVICE DECLARATION IS THE ONE TO USE, because it is
    refused by documented rule rather than by accident. SDL_circle.h fixes the
    declaration once accepted, and refuses one made after the display size has
    been settled - which it was, at section 3 - returning -1 with SDL_GetError
    saying which rule was not met, and changing nothing. So this asks for
    something the library is required to say no to, and checks that it said
    why as well as no.

    IT WAS A BAD DISPLAY INDEX HERE, AND THAT WAS WRONG TWICE OVER. There is
    one display and SDL_GetDisplayBounds does not take the index at all - the
    parameter is unnamed in src/video.cpp, which is that library saying it is
    ignored on purpose - so a nonsense index is not an error and nothing was
    ever going to be reported. Worse, it was called with a nil rectangle,
    which that function writes through before doing anything else. A nil there
    is a write to address zero, which is mapped on this board, so it did not
    fault - it corrupted low memory quietly and the test still ran. SDL's
    contract requires a real rectangle; passing nil was this program's fault
    and not something to report. }
  Redeclared := SDL2Circle_DeclareVirtualDevice(32, CanvasW, CanvasH);
  WriteLn('  a second display declaration : returns ', Redeclared,
          ', error "', LastError, '"');
  Judge('16c a refusal returns failure', Redeclared = -1);
  Judge('16d a refusal says why', LastError <> '');
  SDL_ClearError;
end;


{ 17. Timing. The clock is the board's free-running counter, and every wait in
      this library services SDL while it runs, so a wait is a floor. }
procedure Timing;
var
  T0, T1   : UInt64;
  P0, P1   : UInt64;
  Freq     : UInt64;
  Millis   : UInt32;
  ByCounter: UInt64;
begin
  Section('17', 'the clocks');

  Freq := SDL_GetPerformanceFrequency;
  WriteLn('  performance frequency: ', Freq, ' Hz');

  T0 := SDL_GetTicks;
  P0 := SDL_GetPerformanceCounter;
  SDL_Delay(DelayMillis);
  T1 := SDL_GetTicks;
  P1 := SDL_GetPerformanceCounter;

  Millis := T1 - T0;
  if Freq > 0 then
    ByCounter := ((P1 - P0) * 1000) div Freq
  else
    ByCounter := 0;

  WriteLn('  asked for            : ', DelayMillis, ' ms');
  WriteLn('  by SDL_GetTicks    : ', Millis, ' ms');
  WriteLn('  by the counter       : ', ByCounter, ' ms');
  WriteLn('  tolerance: not below the wait at all, and not more than ',
          DelaySlack, ' ms above it.');
  WriteLn('  A wait here services SDL while it runs, so it is a floor.');

  Judge('17a the wait is at least what was asked for',
        Millis >= UInt32(DelayMillis));
  Judge('17b the wait did not overrun',
        Millis <= UInt32(DelayMillis + DelaySlack));
  Judge('17c the two clocks agree',
        (Freq > 0) and
        (Abs(LongInt(Millis) - LongInt(ByCounter)) <= DelaySlack));
end;


{ 18. The one thing that needs a person, bounded so that it does not need one.

      Everything above settles itself. A key press cannot be manufactured, so
      this watches for a while and reports whatever arrives. An empty watch is
      the expected result on an unattended bench and is NOT a failure. }
procedure WatchForAHand;
var
  Buf      : TEventBuffer;
  Deadline : UInt32;
  Keys     : LongInt;
  Texts    : LongInt;
  Mice     : LongInt;
  Pads     : LongInt;
  Others   : LongInt;
begin
  Section('18', 'watching for a person, for ' + IntToStr(WatchSeconds) +
          ' seconds');
  WriteLn('  NOT JUDGED. Nothing arriving is the expected answer on a bench');
  WriteLn('  with nobody at it. If somebody IS there: press A, then Escape,');
  WriteLn('  then move the mouse. Each one should print a line below.');

  SDL_StartTextInput;

  Keys := 0; Texts := 0; Mice := 0; Pads := 0; Others := 0;
  Deadline := SDL_GetTicks + UInt32(WatchSeconds) * 1000;

  while SDL_GetTicks < Deadline do
  begin
    FillChar(Buf, SizeOf(Buf), 0);
    if SDL_PollEvent(@Buf.ev) = 1 then
    begin
      case Buf.ev.type_ of
        SDL_KEYDOWN, SDL_KEYUP:
          begin
            Inc(Keys);
            WriteLn('    key ',
                    Buf.ev.type_ - SDL_KEYDOWN, ' scancode ',
                    LongInt(Buf.ev.key.keysym.scancode), ' (',
                    string(AnsiString(SDL_GetScancodeName(
                      Buf.ev.key.keysym.scancode))),
                    ') keycode ', LongInt(Buf.ev.key.keysym.sym),
                    ' mod ', Hex8(Buf.ev.key.keysym._mod));
          end;
        SDL_TEXTINPUT:
          begin
            Inc(Texts);
            WriteLn('    text "', string(PAnsiChar(@Buf.ev.text.text[0])), '"');
          end;
        SDL_MOUSEMOTION, SDL_MOUSEBUTTONDOWN, SDL_MOUSEBUTTONUP,
        SDL_MOUSEWHEEL:
          Inc(Mice);
        SDL_JOYAXISMOTION, SDL_JOYBUTTONDOWN, SDL_JOYBUTTONUP,
        SDL_JOYHATMOTION, SDL_JOYDEVICEADDED, SDL_JOYDEVICEREMOVED:
          Inc(Pads);
      else
        Inc(Others);
      end;
    end
    else
      SDL_Delay(5);
  end;

  SDL_StopTextInput;

  WriteLn('  keyboard events : ', Keys);
  WriteLn('  text events     : ', Texts);
  WriteLn('  mouse events    : ', Mice);
  WriteLn('  pad events      : ', Pads);
  WriteLn('  other events    : ', Others);
  WriteLn('  the queue survived the watch: ',
          YesNo(SDL_PollEvent(@Buf.ev) = 0), ' (empty at the end)');
end;


{ 19. Give the display back. An application is entitled to destroy all of this
      and make it again, and a settings menu does exactly that on every
      change, so the teardown is part of what is being proved. }
procedure Teardown;
begin
  Section('19', 'giving the display back');

  if Ren <> nil then
  begin
    SDL_DestroyRenderer(Ren);
    Ren := nil;
  end;
  if Win <> nil then
  begin
    SDL_DestroyWindow(Win);
    Win := nil;
  end;
  WriteLn('  renderer and window destroyed');

  SDL_Quit;
  WriteLn('  SDL_WasInit after SDL_Quit: ', Hex8(SDL_WasInit(0)));
  Judge('19a SDL shut down', SDL_WasInit(0) = 0);
end;


{****************************************************************************
                                  The run
****************************************************************************}

begin
  WriteLn;
  WriteLn('=== circle-libfpc M8: SDL from Free Pascal ===');
  WriteLn('Every section draws or asks something with a known answer and');
  WriteLn('checks it here. Nothing below needs anybody to look at a screen.');

  ReportTheLibrary;

  if not DeclareAndInit then
  begin
    WriteLn;
    WriteLn('SDL did not start, so nothing further can be asked of it.');
    WriteLn('M8: FAIL2b');
    Halt(1);
  end;

  CheckDisplayAnswers;
  MakeWindow;
  if Win = nil then
  begin
    WriteLn;
    WriteLn('There is no window, so nothing further can be drawn.');
    WriteLn('M8: FAIL4a');
    Halt(1);
  end;

  MakeRenderer;
  if Ren = nil then
  begin
    WriteLn;
    WriteLn('There is no renderer, so nothing further can be drawn.');
    WriteLn('M8: FAIL5a');
    Halt(1);
  end;

  DrawAndReadBack;
  TextureUpdateAndCopy;
  NarrowTexture;
  LockAndWrite;
  BlendOverBackground;
  MirrorAndRefuseAngle;
  PresentFramesLoop;
  EventQueueWithoutAHand;
  KeyboardWithoutAHand;
  PointersAndPads;
  SizesAndErrors;
  Timing;
  WatchForAHand;
  Teardown;

  Pace;
  WriteLn;
  WriteLn('=== M8 verdict ===');
  if Failures = '' then
    WriteLn('M8: PASS - every section that judges itself agreed with what it',
            ' drew or asked.')
  else
    WriteLn('M8: FAIL -', Failures);

  { Reported separately and never folded into the verdict above, in either
    direction. A divergence is not this program failing, so it must not read
    as one; and it is not nothing, so it must not disappear. The citation
    printed beside each is what makes it actionable. }
  if Divergences <> '' then
  begin
    WriteLn('M8: and', Divergences,
            ' disagreed with what a component below this program documents.');
    WriteLn('    Each printed the line that proves it, where it failed above.');
  end;
  WriteLn('=== end of the Pascal program ===');
end.
