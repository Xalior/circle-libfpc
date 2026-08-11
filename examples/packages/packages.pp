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
  { The four packages under test, and the fcl-image readers and writers an
    application is most likely to want. }
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

{ GetFPCHeapStatus IS A STUB ON THIS TARGET AND ALWAYS RETURNS ZEROS.

  rtl/embedded/heapmgr.pp implements it as FillChar(Result, SizeOf(Result), 0),
  with the comment "avoid that programs crash due to a heap status request".
  So is GetHeapStatus. There is no heap accounting on this target to ask for --
  the same shape as IsMemoryManagerSet, which is compiled to `mov w0, wzr; ret`
  and reports nothing either.

  The figures are printed anyway, once, because a reader who does not know that
  will otherwise go looking for the heap numbers and find none. }
procedure SayHeapStatusIsAStub;
var
  h: TFPCHeapStatus;
begin
  h := GetFPCHeapStatus;
  Say('HEAP GetFPCHeapStatus: used=' + NumStr(h.CurrHeapUsed)
      + ' free=' + NumStr(h.CurrHeapFree)
      + ' size=' + NumStr(h.CurrHeapSize)
      + ' maxused=' + NumStr(h.MaxHeapUsed));
  Say('HEAP all zeros is CORRECT: heapmgr.pp implements it as FillChar(0) on');
  Say('HEAP this target. There is no heap accounting here to ask for.');
end;

{ ---- the heap chain probe ----------------------------------------------

  heapmgr keeps its free list INSIDE the free memory: a free block's first
  twenty-four bytes are Size, Next and EndAddr, and an allocated block carries
  its size in the eight bytes below the pointer you were given. So a write one
  byte past an allocation lands in a neighbour's header, and the damage is not
  found until something walks the chain -- which can be thousands of
  allocations later, in a rung that did nothing wrong.

  This probe walks the chain deliberately, at a named moment. The large request
  is the point of it: SysGetMem walks the free list until it finds a block big
  enough, so asking for something big walks a long way through it. A chain that
  has already been damaged faults HERE, after a line naming the last rung that
  ran, instead of somewhere later that says nothing about the cause. }
procedure HeapProbe(const After: AnsiString);
var
  a, b, c: pointer;
begin
  Say('HEAP probing the free chain after ' + After + ' ...');
  a := GetMem(64);
  b := GetMem(4096);
  c := GetMem(262144);          { big enough to walk deep into the chain }
  FreeMem(b);
  FreeMem(a);
  FreeMem(c);
  { And once more, so the coalescing path runs on the blocks just returned. }
  a := GetMem(131072);
  FreeMem(a);
  Say('HEAP chain intact after ' + After);
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

{ ---- P4b: the heap on its own, with no image code anywhere near it ------

  The question this answers: does heapmgr's free list break under ordinary
  mixed-size churn on this target, or is something writing where it should not?
  Those need separating, because the fault looks identical either way -- a
  chain walk into a wild address, thousands of allocations after the damage.

  So this rung is deliberately harder than anything the rest of the program
  does, and contains no image code, no strings and no library calls: allocate
  blocks of many different sizes, fill every one with a pattern derived from
  its own index, free them in an order that is not the order they were taken
  in, and check every byte back before each free. Sizes straddle heapmgr's
  MinBlock of 16 and its split threshold, because splitting a block and
  coalescing it back is the code the fault appears in.

  A guard failure names an overrun by this rung itself, which would mean the
  allocator handed out overlapping memory. Silence here plus a fault later
  means the allocator is sound under load and something else is doing the
  writing. }

const
  ChurnLive   = 192;
  ChurnRounds = 24;

var
  ChurnSeed: longword = 2463534242;

function ChurnRand: longword;
begin
  { xorshift32 -- no library call, and the same sequence on every board. }
  ChurnSeed := ChurnSeed xor (ChurnSeed shl 13);
  ChurnSeed := ChurnSeed xor (ChurnSeed shr 17);
  ChurnSeed := ChurnSeed xor (ChurnSeed shl 5);
  Result := ChurnSeed;
end;

procedure P4bHeapChurn;
var
  p: array[0..ChurnLive - 1] of PByte;
  sz: array[0..ChurnLive - 1] of longint;
  tag: array[0..ChurnLive - 1] of byte;
  i, j, k, r, n: longint;
  bad, total, peak, live: longint;
  q: PByte;
begin
  Say('P4b start: heap churn, mixed sizes, no image code, guard bytes checked');

  for i := 0 to ChurnLive - 1 do
  begin
    p[i] := nil;
    sz[i] := 0;
  end;
  bad := 0; total := 0; peak := 0; live := 0;

  for r := 1 to ChurnRounds do
  begin
    for k := 1 to ChurnLive do
    begin
      i := longint(ChurnRand mod ChurnLive);

      if p[i] <> nil then
      begin
        { Check every byte back before letting it go. }
        q := p[i];
        for j := 0 to sz[i] - 1 do
          if q[j] <> tag[i] then
          begin
            Inc(bad);
            Break;
          end;
        FreeMem(p[i]);
        p[i] := nil;
        Dec(live);
        Continue;
      end;

      { Sizes that straddle MinBlock (16) and run up past a page, so the
        split-and-coalesce path is exercised at both ends. }
      case ChurnRand mod 5 of
        0: n := 1 + longint(ChurnRand mod 24);
        1: n := 25 + longint(ChurnRand mod 200);
        2: n := 256 + longint(ChurnRand mod 2048);
        3: n := 4096 + longint(ChurnRand mod 8192);
      else
        n := 1 + longint(ChurnRand mod 65536);
      end;

      p[i] := GetMem(n);
      if p[i] = nil then
      begin
        Say('P4b GetMem(' + NumStr(n) + ') returned nil at round ' + NumStr(r));
        Continue;
      end;

      sz[i] := n;
      tag[i] := byte(i) xor $A5;
      FillChar(p[i]^, n, tag[i]);
      Inc(live);
      Inc(total);
      if live > peak then
        peak := live;
    end;
  end;

  for i := 0 to ChurnLive - 1 do
    if p[i] <> nil then
    begin
      q := p[i];
      for j := 0 to sz[i] - 1 do
        if q[j] <> tag[i] then
        begin
          Inc(bad);
          Break;
        end;
      FreeMem(p[i]);
      p[i] := nil;
    end;

  Say('P4b OK ' + NumStr(total) + ' allocations, peak ' + NumStr(peak)
      + ' live, corrupted blocks=' + NumStr(bad) + ' (expect 0)');
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
  { Announced step by step. The previous boot printed "P6 start" and then
    faulted, which narrows it to somewhere in the next six statements and no
    further. These lines cost nothing and turn that into a name. }
  Say('P6 start: fcl-image, PNG round trip (deflate and inflate, paszlib)');
  Say('P6   building a 16x16 checker ...');
  src := MakeChecker(16, 16);
  Say('P6   creating the destination image ...');
  dst := TFPMemoryImage.Create(0, 0);
  Say('P6   creating the stream ...');
  ms := TMemoryStream.Create;
  Say('P6   creating TFPWriterPNG ...');
  w := TFPWriterPNG.Create;
  Say('P6   creating TFPReaderPNG ...');
  r := TFPReaderPNG.Create;
  try
    Say('P6   SaveToStream: this is where deflate runs ...');
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

  SayHeapStatusIsAStub;

  { A probe after EVERY rung. heapmgr's free list lives inside the free memory,
    so a stray write is silent until something walks far enough to meet it --
    which is why the last boot died entering P6 having been damaged who knows
    where. Each probe walks the chain on purpose, so the fault lands
    immediately after a line naming the rung that ran, and the rung that broke
    it is the one before the last "chain intact". }
  HeapProbe('startup');
  Run('P0', @P0StringManager);   HeapProbe('P0');
  Run('P1', @P1CriticalSection); HeapProbe('P1');
  Run('P2', @P2EventHandshake);  HeapProbe('P2');
  Run('P3', @P3Generics);        HeapProbe('P3');
  Run('P4', @P4StrUtils);        HeapProbe('P4');
  Run('P4b', @P4bHeapChurn);     HeapProbe('P4b');
  Run('P5', @P5BMP);             HeapProbe('P5');
  Run('P6', @P6PNG);             HeapProbe('P6');
  Run('P7', @P7JPEG);            HeapProbe('P7');
  Run('P8', @P8GIF);             HeapProbe('P8');
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
