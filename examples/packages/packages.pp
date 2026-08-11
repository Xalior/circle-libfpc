program packages;

{ The application blob of circle-libfpc's packages example.

  Free Pascal ships SyncObjs, Generics.Collections, StrUtils and fcl-image as
  source but does not build them for aarch64-embedded, because the compiler for
  this target is installed with buildbase/installbase, which never enter
  packages/. build-packages.sh builds them. This program is how we find out
  whether "it compiles and links" means anything: on this target the memory
  manager and the thread manager are both installed at run time and are
  invisible to the linker, so a clean link proves nothing at all.

  Every rung prints a line before it starts and a line when it succeeds, so a
  rung that stops the board names itself.

  Two things this program will not do, both because of what the library
  underneath it is:

  - It touches no file. The twelve rtl_do_* file hooks are unassigned on this
    target, so every image goes through a TMemoryStream.
  - It never waits on an event nothing is going to signal. circle-libfpc's
    BasicEventWaitFor ignores its timeout and waits without limit, so a
    WaitFor(0) on a clear event is a hang, not a wrTimeout. }

{$mode objfpc}
{$H+}

uses
  { circlefpc pulls in heapmgr, clfthreads and clfstrings, in that order, so
    the memory manager exists before anything that allocates. All three are
    run-time installations the linker cannot check. }
  circlefpc,
  { Named as well as reached through circlefpc, because P0 below prints what
    the widestring manager held before clfstrings filled it in. }
  clfstrings,
  SysUtils, Classes,
  { The four packages under test, and the fcl-image readers and writers
    SpecBAS names. }
  SyncObjs,
  Generics.Collections,
  StrUtils,
  FPImage, FPReadBMP, FPWriteBMP, FPReadPNG, FPWritePNG, FPReadJPEG,
  FPReadGIF;

{$I samples.inc}

procedure clf_puts(s: PChar); cdecl; external name 'clf_puts';

{ The cores a host kernel has lent and that are free right now, as a bitmask.
  Printed rather than assumed: a zero here is the whole explanation for a
  BeginThread that refuses. }
function FPCCircle_ThreadCoresFree: cardinal; cdecl;
  external name 'FPCCircle_ThreadCoresFree';

var
  NewLine: array[0..1] of char;

{ ---- output ---------------------------------------------------------- }

procedure Say(const s: AnsiString);
begin
  if Length(s) > 0 then
    clf_puts(PChar(s));
  clf_puts(@NewLine[0]);
end;

function NumStr(v: int64): AnsiString;
var
  t: shortstring;
begin
  Str(v, t);
  Result := t;
end;

function HexStr4(v: word): AnsiString;
begin
  Result := '$' + HexStr(QWord(v), 4);
end;

function Hex16(v: PtrUInt): AnsiString;
begin
  Result := '$' + HexStr(QWord(v), 16);
end;

function YesNo(b: boolean): AnsiString;
begin
  if b then Result := 'yes' else Result := 'no';
end;

{ ---- shared state for the threaded rung ------------------------------- }

var
  HandshakeEvent: TEvent;
  HandshakeLock: TCriticalSection;
  HandshakeCounter: longint;
  HandshakeThreadSaw: longint;

  { Set last by the worker, and the ONLY thing the main thread waits on.

    A wait on this target cannot be bounded through the API: circle-libfpc's
    BasicEventWaitFor ignores its timeout and waits without limit, so
    TEvent.WaitFor(n) can never come back as wrTimeout. Two boots have now been
    lost to a wait for something that was never going to arrive, and neither
    left any diagnosis behind. So the rung below spins on this flag with a
    bound it can count, and only calls WaitFor once the flag says the event has
    already been signalled — at which point WaitFor is guaranteed to return.

    Written by a lent core and read by core 0, and written last -- after
    everything the reader will go on to look at. The reader cannot cache it in
    a register across the wait, because the loop calls ThreadSwitch, which is
    an external call the compiler cannot see through. }
  HandshakeDone: longint = 0;

function HandshakeThread(p: pointer): ptrint;
var
  i: longint;
begin
  { Take the same critical section the main thread uses, so this rung tests
    the lock under real contention rather than a lock nobody contests. }
  for i := 1 to 1000 do
  begin
    HandshakeLock.Enter;
    Inc(HandshakeCounter);
    HandshakeLock.Leave;
  end;
  HandshakeLock.Enter;
  HandshakeThreadSaw := HandshakeCounter;
  HandshakeLock.Leave;
  HandshakeEvent.SetEvent;
  HandshakeDone := 1;
  Result := 0;
end;

{ ---- P0: the record that stopped the last boot -------------------------

  The previous image died silently between "P4 ReverseString" and the line
  after it. The line after it calls AnsiContainsText, which calls
  AnsiUppercase, which calls widestringmanager.UpperAnsiStringProc -- a field
  in a record that this target's runtime never fills, because
  rtl/embedded/system.pp has initunicodestringmanager commented out and
  rtl/embedded/sysutils.pp never calls InitInternationalGeneric. Nil, and a
  branch straight to address zero.

  This rung prints what was in that record before clfstrings installed a
  manager, so the board says whether that is true rather than this comment
  claiming it. Nil is the finding. }

procedure P0StringManager;
var
  m: TUnicodeStringManager;
begin
  Say('P0 start: the widestring manager, which nothing in this target fills');
  Say('P0 UpperAnsiStringProc BEFORE clfstrings  = '
      + Hex16(PtrUInt(CLFPriorUpperAnsiProc)));
  Say('P0 CompareTextAnsiStringProc BEFORE       = '
      + Hex16(PtrUInt(CLFPriorCompareTextProc)));
  Say('P0 (nil above is the whole finding: last boot branched through it)');
  GetWideStringManager(m);
  Say('P0 UpperAnsiStringProc AFTER  clfstrings  = '
      + Hex16(PtrUInt(m.UpperAnsiStringProc)));
  Say('P0 CompareTextAnsiStringProc AFTER        = '
      + Hex16(PtrUInt(m.CompareTextAnsiStringProc)));
  Say('P0 OK installed=' + YesNo((m.UpperAnsiStringProc <> nil)
      and (m.CompareTextAnsiStringProc <> nil)));

  { Exercised here, before anything else can, so the very first use of the
    installed manager is one whose answer is known. }
  Say('P0 AnsiUpperCase(SpecBAS 42) = ' + AnsiUpperCase('SpecBAS 42'));
  Say('P0 AnsiLowerCase(SpecBAS 42) = ' + AnsiLowerCase('SpecBAS 42'));
  Say('P0 AnsiCompareText(abc,ABC)  = ' + NumStr(AnsiCompareText('abc', 'ABC'))
      + ' (expect 0)');
  Say('P0 AnsiCompareStr(abc,ABC)   = ' + NumStr(AnsiCompareStr('abc', 'ABC'))
      + ' (expect positive)');

  { THE DISCRIMINATOR.

    This is the exact call the previous image died on, made HERE -- first rung,
    before this program has ever created a thread, so only the one core and the
    one task have ever touched the UART. Two explanations were open for that
    silent stop: an uninstalled widestring manager, or the output path itself
    breaking under cross-core use. This call separates them without needing
    either to be proved first.

      - It prints its answer: the manager was the cause, and no thread was ever
        needed to trigger it.
      - It stops the board here: the manager was not the cause, and the failure
        reproduces with no thread in the picture at all.
      - P0 passes and P4's identical call stops the board later: the difference
        is what happened in between, which is where the threads are. }
  Say('P0 calling AnsiContainsText -- the call the last image died on,');
  Say('P0 made before this program has created any thread ...');
  Say('P0 OK AnsiContainsText(abababab,AB)='
      + YesNo(AnsiContainsText('abababab', 'AB')) + ' (expect yes)');
end;

{ ---- heap, before and after the image rungs ---------------------------- }

procedure SayHeap(const When: AnsiString);
var
  h: TFPCHeapStatus;
begin
  h := GetFPCHeapStatus;
  Say('HEAP ' + When + ': used=' + NumStr(h.CurrHeapUsed)
      + ' free=' + NumStr(h.CurrHeapFree)
      + ' size=' + NumStr(h.CurrHeapSize)
      + ' maxused=' + NumStr(h.MaxHeapUsed));
end;

{ ---- P1: SyncObjs, TCriticalSection ------------------------------------ }

procedure P1CriticalSection;
var
  cs: TCriticalSection;
  got: boolean;
begin
  Say('P1 start: SyncObjs TCriticalSection, built from processor atomics');
  cs := TCriticalSection.Create;
  cs.Enter;
  cs.Leave;
  cs.Acquire;
  cs.Release;
  got := cs.TryEnter;
  if got then
    cs.Leave;
  Say('P1 OK enter/leave, acquire/release, TryEnter=' + YesNo(got));
  cs.Free;
end;

{ ---- P2: SyncObjs, TEvent across a thread on a lent core ---------------- }

const
  { Yields, not milliseconds — there is no clock in this rung and a count is
    something the board can print. A worker that runs a thousand locked
    increments needs a handful; this is four orders of magnitude of headroom
    and still finite. }
  MaxHandshakeSpins = 2000000;

procedure P2EventHandshake;
var
  tid: TThreadID;
  r: TWaitResult;
  spins: longint;
begin
  Say('P2 start: SyncObjs TEvent, manual reset, signalled by a second thread');
  HandshakeCounter := 0;
  HandshakeThreadSaw := -1;
  HandshakeLock := TCriticalSection.Create;
  HandshakeEvent := TEvent.Create(nil, True, False, '');

  { Signalled before anything waits: this must come straight back. }
  HandshakeEvent.SetEvent;
  r := HandshakeEvent.WaitFor(INFINITE);
  Say('P2 pre-signalled WaitFor returned ' + NumStr(Ord(r))
      + ' (0 = wrSignaled)');
  HandshakeEvent.ResetEvent;

  { A Pascal thread is not a Circle task any more: it runs on a core the host
    kernel has lent, and with no core lent BeginThread refuses and returns
    zero. Report that and leave — the old code went straight on to wait for a
    signal from a thread that did not exist. }
  HandshakeDone := 0;
  tid := BeginThread(@HandshakeThread, nil);
  Say('P2 thread started, handle=' + NumStr(int64(tid))
      + ' IsMultiThread=' + YesNo(IsMultiThread)
      + ' cores free=' + Hex16(FPCCircle_ThreadCoresFree));

  if PtrUInt(tid) = 0 then
  begin
    Say('P2 FAILED BeginThread refused: the host kernel lent no core.');
    Say('P2 Nothing waited on. The critical section still passed in P1.');
    HandshakeEvent.Free;
    HandshakeLock.Free;
    Exit;
  end;

  { Bounded, and countable. ThreadSwitch hands core 0's time to Circle, which
    is also what drains anything a lent core has printed. }
  spins := 0;
  while (HandshakeDone = 0) and (spins < MaxHandshakeSpins) do
  begin
    ThreadSwitch;
    Inc(spins);
  end;

  if HandshakeDone = 0 then
  begin
    Say('P2 FAILED the worker never finished after ' + NumStr(spins)
        + ' yields. Not waiting on the event: on this target that wait');
    Say('P2 has no timeout and would stop the board with no diagnosis.');
    Exit;
  end;

  { Safe now: the event is already signalled, so this returns rather than
    blocks, and it is still a real test of BasicEventWaitFor. }
  r := HandshakeEvent.WaitFor(INFINITE);
  WaitForThreadTerminate(tid, 0);

  Say('P2 OK WaitFor=' + NumStr(Ord(r))
      + ' counter=' + NumStr(HandshakeCounter)
      + ' thread saw=' + NumStr(HandshakeThreadSaw)
      + ' yields=' + NumStr(spins));

  HandshakeEvent.Free;
  HandshakeLock.Free;
end;

{ ---- P3: Generics.Collections ------------------------------------------ }

type
  TStrIntDict = specialize TDictionary<AnsiString, Integer>;
  TIntList = specialize TList<Integer>;

procedure P3Generics;
var
  d: TStrIntDict;
  l: TIntList;
  i, v, total: Integer;
  pair: TStrIntDict.TDictionaryPair;
  key: AnsiString;
begin
  Say('P3 start: Generics.Collections TDictionary and TList');
  d := TStrIntDict.Create;
  for i := 1 to 200 do
    d.Add('key' + NumStr(i), i * 3);

  v := 0;
  if not d.TryGetValue('key77', v) then
    Say('P3 FAIL TryGetValue(key77) missed');
  Say('P3 count=' + NumStr(d.Count) + ' key77=' + NumStr(v)
      + ' (expect 231)');

  { Enumeration, which is where the comparer and the hash actually get used. }
  total := 0;
  for pair in d do
    Inc(total, pair.Value);
  Say('P3 sum over enumeration=' + NumStr(total) + ' (expect 60300)');

  d.Remove('key77');
  Say('P3 after remove: contains key77=' + YesNo(d.ContainsKey('key77'))
      + ' count=' + NumStr(d.Count));

  { A key built at run time rather than a literal, so the comparer is
    comparing string contents and not two pointers to the same constant. }
  key := 'key' + NumStr(100 + 1);
  Say('P3 built key ' + key + ' found=' + YesNo(d.ContainsKey(key)));
  d.Free;

  l := TIntList.Create;
  for i := 20 downto 1 do
    l.Add(i * i);
  l.Sort;
  Say('P3 OK TList count=' + NumStr(l.Count) + ' first=' + NumStr(l[0])
      + ' last=' + NumStr(l[l.Count - 1]));
  l.Free;
end;

{ ---- P4: StrUtils ------------------------------------------------------ }

{ Every call announces itself before it is made, because the last boot stopped
  between two of these and there was no way to tell which side of the line it
  had reached. A rung that prints "calling X" and never prints X's answer names
  the call that killed it. }
procedure P4StrUtils;
var
  s: AnsiString;
  n: Integer;
begin
  Say('P4 start: StrUtils');
  s := DupeString('ab', 4);
  n := PosEx('ba', s, 3);
  Say('P4 DupeString=' + s + ' PosEx(ba,3)=' + NumStr(n) + ' (expect 4)');
  Say('P4 AnsiReplaceStr=' + AnsiReplaceStr(s, 'a', 'Z'));
  Say('P4 ReverseString=' + ReverseString('SpecBAS'));

  Say('P4 calling IfThen ...');
  Say('P4   IfThen=' + IfThen(n = 4, 'right', 'wrong'));

  { THIS is the call that stopped the previous image. It reaches
    AnsiUppercase and so the widestring manager P0 installed. }
  Say('P4 calling AnsiContainsText (the call that stopped the last boot) ...');
  Say('P4   AnsiContainsText(abababab,AB)=' + YesNo(AnsiContainsText(s, 'AB'))
      + ' (expect yes)');

  Say('P4 calling AnsiProperCase ...');
  Say('P4   AnsiProperCase=' + AnsiProperCase('spec bas basic', [' ']));

  Say('P4 calling IsWild ...');
  Say('P4   IsWild(SpecBAS,Spec*,ignorecase)='
      + YesNo(IsWild('SpecBAS', 'spec*', True)));

  Say('P4   AddChar=[' + AddChar('.', '42', 6) + ']'
      + ' RightStr=' + RightStr(s, 3));

  { An unambiguous boundary. The previous capture ended inside this rung and
    there was no line that meant "P4 finished", so the stop could be read as
    either the end of P4 or the start of P5. This line means P4 and only P4. }
  Say('P4 OK all StrUtils calls returned');
end;

{ ---- image helpers ------------------------------------------------------ }

function MakeChecker(w, h: Integer): TFPMemoryImage;
var
  x, y: Integer;
  c: TFPColor;
begin
  Result := TFPMemoryImage.Create(w, h);
  c.alpha := alphaOpaque;
  for y := 0 to h - 1 do
    for x := 0 to w - 1 do
    begin
      if ((x + y) and 1) = 0 then
      begin
        c.red := $FFFF; c.green := 0; c.blue := 0;
      end
      else
      begin
        c.red := 0; c.green := $FFFF; c.blue := 0;
      end;
      Result.Colors[x, y] := c;
    end;
end;

function SameImage(a, b: TFPCustomImage): boolean;
var
  x, y: Integer;
  ca, cb: TFPColor;
begin
  Result := (a.Width = b.Width) and (a.Height = b.Height);
  if not Result then Exit;
  for y := 0 to a.Height - 1 do
    for x := 0 to a.Width - 1 do
    begin
      ca := a.Colors[x, y];
      cb := b.Colors[x, y];
      if (ca.red <> cb.red) or (ca.green <> cb.green) or (ca.blue <> cb.blue) then
      begin
        Result := False;
        Exit;
      end;
    end;
end;

function DescribePixel(img: TFPCustomImage; x, y: Integer): AnsiString;
var
  c: TFPColor;
begin
  c := img.Colors[x, y];
  Result := 'r=' + HexStr4(c.red) + ' g=' + HexStr4(c.green)
          + ' b=' + HexStr4(c.blue);
end;

{ ---- P5: fcl-image, BMP round trip in memory --------------------------- }

procedure P5BMP;
var
  src, dst: TFPMemoryImage;
  ms: TMemoryStream;
  w: TFPWriterBMP;
  r: TFPReaderBMP;
begin
  Say('P5 start: fcl-image, BMP written and read back through a TMemoryStream');
  src := MakeChecker(8, 8);
  dst := TFPMemoryImage.Create(0, 0);
  ms := TMemoryStream.Create;
  w := TFPWriterBMP.Create;
  r := TFPReaderBMP.Create;
  try
    src.SaveToStream(ms, w);
    Say('P5 written, ' + NumStr(ms.Size) + ' bytes');
    ms.Position := 0;
    dst.LoadFromStream(ms, r);
    Say('P5 read back ' + NumStr(dst.Width) + 'x' + NumStr(dst.Height)
        + ' px(0,0) ' + DescribePixel(dst, 0, 0));
    Say('P5 OK identical=' + YesNo(SameImage(src, dst)));
  finally
    r.Free; w.Free; ms.Free; dst.Free; src.Free;
  end;
end;

{ ---- P6: fcl-image, PNG round trip — this is the paszlib rung ----------- }

procedure P6PNG;
var
  src, dst: TFPMemoryImage;
  ms: TMemoryStream;
  w: TFPWriterPNG;
  r: TFPReaderPNG;
begin
  Say('P6 start: fcl-image, PNG round trip (deflate and inflate, paszlib)');
  src := MakeChecker(16, 16);
  dst := TFPMemoryImage.Create(0, 0);
  ms := TMemoryStream.Create;
  w := TFPWriterPNG.Create;
  r := TFPReaderPNG.Create;
  try
    src.SaveToStream(ms, w);
    Say('P6 deflated to ' + NumStr(ms.Size) + ' bytes');
    ms.Position := 0;
    dst.LoadFromStream(ms, r);
    Say('P6 inflated ' + NumStr(dst.Width) + 'x' + NumStr(dst.Height)
        + ' px(0,0) ' + DescribePixel(dst, 0, 0));
    Say('P6 OK identical=' + YesNo(SameImage(src, dst)));
  finally
    r.Free; w.Free; ms.Free; dst.Free; src.Free;
  end;
end;

{ ---- P7: fcl-image, JPEG decode of a picture made off the board --------- }

procedure P7JPEG;
var
  img: TFPMemoryImage;
  ms: TMemoryStream;
  r: TFPReaderJPEG;
  c: TFPColor;
begin
  Say('P7 start: fcl-image, JPEG decode (pasjpeg), '
      + NumStr(Length(SampleJPEG)) + ' bytes of solid red');
  img := TFPMemoryImage.Create(0, 0);
  ms := TMemoryStream.Create;
  r := TFPReaderJPEG.Create;
  try
    ms.Write(SampleJPEG[0], Length(SampleJPEG));
    ms.Position := 0;
    img.LoadFromStream(ms, r);
    c := img.Colors[8, 8];
    Say('P7 decoded ' + NumStr(img.Width) + 'x' + NumStr(img.Height)
        + ' px(8,8) ' + DescribePixel(img, 8, 8));
    Say('P7 OK red dominates=' + YesNo((c.red > $E000) and (c.green < $2000)
        and (c.blue < $2000)));
  finally
    r.Free; ms.Free; img.Free;
  end;
end;

{ ---- P8: fcl-image, GIF decode ----------------------------------------- }

procedure P8GIF;
var
  img, ref: TFPMemoryImage;
  ms: TMemoryStream;
  r: TFPReaderGIF;
begin
  Say('P8 start: fcl-image, GIF decode, ' + NumStr(Length(SampleGIF))
      + ' bytes of 8x8 checker');
  img := TFPMemoryImage.Create(0, 0);
  ref := MakeChecker(8, 8);
  ms := TMemoryStream.Create;
  r := TFPReaderGIF.Create;
  try
    ms.Write(SampleGIF[0], Length(SampleGIF));
    ms.Position := 0;
    img.LoadFromStream(ms, r);
    Say('P8 decoded ' + NumStr(img.Width) + 'x' + NumStr(img.Height)
        + ' px(0,0) ' + DescribePixel(img, 0, 0));
    Say('P8 OK matches the checker=' + YesNo(SameImage(ref, img)));
  finally
    r.Free; ms.Free; ref.Free; img.Free;
  end;
end;

{ ---- P9: what an auto-reset TEvent does here --------------------------- }

{ SyncObjs' TEvent takes AManualReset. circle-libfpc's events do not clear
  their state when a wait passes through them, so both kinds should behave as
  manual reset: a second WaitFor on an event nobody cleared should return
  straight away.

  Testing that on core 0 would mean risking a wait that cannot time out, and
  two boots have already been lost to exactly that. So the probe runs on the
  lent core instead and core 0 watches a flag with a bound it can count. If
  auto-reset turns out to be honoured, the probe blocks on its second wait and
  the flag never arrives — and that is a reported result rather than a stopped
  board. The lent core stays occupied afterwards, which is why this rung is
  last of the ones that use a thread. }

var
  AutoResetEvent: TEvent;
  AutoResetR1: longint = -1;
  AutoResetR2: longint = -1;
  AutoResetPastFirst: longint = 0;
  AutoResetDone: longint = 0;

function AutoResetProbeThread(p: pointer): ptrint;
begin
  AutoResetEvent.SetEvent;
  AutoResetR1 := Ord(AutoResetEvent.WaitFor(INFINITE));
  AutoResetPastFirst := 1;
  { If auto-reset is honoured, this one never comes back. }
  AutoResetR2 := Ord(AutoResetEvent.WaitFor(INFINITE));
  AutoResetDone := 1;
  Result := 0;
end;

procedure P9AutoResetProbe;
var
  tid: TThreadID;
  spins: longint;
begin
  Say('P9 start: does an auto-reset TEvent auto-reset here?');
  Say('P9 The probe runs on the lent core, so a wait that never returns is');
  Say('P9 a result this rung can print rather than a board that stops.');

  AutoResetPastFirst := 0;
  AutoResetDone := 0;
  AutoResetEvent := TEvent.Create(nil, False, False, '');

  tid := BeginThread(@AutoResetProbeThread, nil);
  if PtrUInt(tid) = 0 then
  begin
    Say('P9 SKIPPED BeginThread refused: no lent core, so no probe.');
    AutoResetEvent.Free;
    Exit;
  end;

  spins := 0;
  while (AutoResetDone = 0) and (spins < MaxHandshakeSpins) do
  begin
    ThreadSwitch;
    Inc(spins);
  end;

  if AutoResetDone = 1 then
  begin
    Say('P9 OK first WaitFor=' + NumStr(AutoResetR1)
        + ' second WaitFor=' + NumStr(AutoResetR2)
        + ' yields=' + NumStr(spins));
    Say('P9 auto-reset is NOT honoured: an auto-reset TEvent behaves as');
    Say('P9 manual reset, and a second waiter is let straight through.');
  end
  else if AutoResetPastFirst = 1 then
  begin
    Say('P9 RESULT auto-reset IS honoured: the first wait returned and the');
    Say('P9 second is still blocked after ' + NumStr(spins) + ' yields.');
    Say('P9 The lent core stays in it. Nothing after this uses a thread.');
  end
  else
    Say('P9 RESULT neither wait returned after ' + NumStr(spins)
        + ' yields, which is a different fault from the one being probed.');

  { The event is deliberately not freed: a thread may still be inside a wait
    on it. }
end;

{ ---- the deliberate fault ---------------------------------------------- }

{ A store to address zero. Written through a variable so the compiler cannot
  see the constant and turn the whole thing into something else. }
procedure FaultOnPurpose;
var
  p: PLongWord;
begin
  p := nil;
  p^ := $DEADBEEF;
end;

{ ---- main -------------------------------------------------------------- }

{ Each rung runs inside a try..except, so one that raises reports the class and
  the message and the next one still runs. A boot costs real time, so one
  image should answer as many questions as it can. This cannot catch a rung
  that hangs or faults — that is what the start line before every rung is
  for. }
procedure Run(const Name: AnsiString; Proc: TProcedure);
begin
  try
    Proc();
  except
    on E: Exception do
      Say(Name + ' RAISED ' + E.ClassName + ': ' + E.Message);
    else
      Say(Name + ' RAISED a non-Exception object');
  end;
end;

begin
  NewLine[0] := #10;
  NewLine[1] := #0;

  Say('');
  Say('=== circle-libfpc packages: the four Free Pascal packages on hardware ===');
  Say('SyncObjs, Generics.Collections, StrUtils, fcl-image');
  Say('');

  Run('P0', @P0StringManager);
  SayHeap('at start');
  Run('P1', @P1CriticalSection);
  Run('P2', @P2EventHandshake);
  Run('P3', @P3Generics);
  Run('P4', @P4StrUtils);
  SayHeap('before the image rungs');
  Run('P5', @P5BMP);
  Run('P6', @P6PNG);
  Run('P7', @P7JPEG);
  Run('P8', @P8GIF);
  SayHeap('after the image rungs');
  Run('P9', @P9AutoResetProbe);

  Say('');
  Say('=== CLF PACKAGES COMPLETE ===');
  Say('');

  { AFTER "COMPLETE", so it can cost nothing.

    The last boot went silent with no fault message, and there were two
    explanations: a fault that Circle could not report, or something that was
    not a fault at all. This host kernel now carries a CExceptionHandler and a
    CLogger pointed at the same UART, so a fault should announce itself. This
    proves that, by causing one on purpose.

    Expected: Circle prints a panic naming the exception, ELR, ESR and SPSR,
    and the board halts. Nothing printed at all means Circle cannot report a
    fault in this configuration either, and every silent stop from here on has
    to be read that way. }
  Say('=== deliberate fault: everything above has already reported ===');
  Say('Circle should now print a panic. Silence means it cannot report faults.');
  FaultOnPurpose;
  Say('NO FAULT RAISED -- the write to address zero was not trapped');
end.
