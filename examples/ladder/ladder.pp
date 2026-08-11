program ladder;

{ The application blob of circle-libfpc's ladder example.

  It uses the System unit and circle-libfpc, and nothing else, so that every
  rung tests the aarch64-embedded runtime itself rather than a package layered
  on it. Its only outside call is clf_puts, which hands bytes to the library;
  where they come out is the image's business and no line here touches a
  device.

  It climbs from the plainest arithmetic to two cores inside one critical
  section. The rungs from R10 on need a core: a Pascal thread is not a Circle
  task, it runs on a core the host kernel lent to the library, and without one
  BeginThread refuses. Those rungs report which core they ran on, so a pass
  says the thread was somewhere else rather than merely that it ran.

  The rungs run in order of increasing dependence on the runtime, and each one
  prints a line before it starts and a line when it succeeds. A rung that
  stops the board therefore names itself. The two that walk exception frames
  are deliberately last. }

{$mode objfpc}
{$H-}                   { string means shortstring; AnsiString is asked for by name }

uses
  { circlefpc pulls in heapmgr and clfthreads, in that order, so the memory
    manager exists before the thread manager is installed. Both of those are
    run-time installations the linker cannot check: this target ships an
    all-zero FPC_SYSTEM_MEMORYMANAGER, and the RTL's NoThreadManager reports a
    runtime error from every handler until something calls SetThreadManager. A
    program that omits either links perfectly and fails on the board. }
  circlefpc,
  { Named as well as reached through circlefpc, because the rungs below call
    CLFRealStackTop and CLFRealStackSize by name. }
  clfthreads;

const
  CLF_HEAP_PROBE = 4096;

type
  EClf = class(TObject)
  public
    Code: longint;
    constructor Create(ACode: longint);
  end;

  TThing = class(TObject)
  private
    FValue: longint;
  public
    constructor Create(AValue: longint);
    destructor Destroy; override;
    function Scaled: longint; virtual;
    property Value: longint read FValue;
  end;

  TBigger = class(TThing)
  public
    function Scaled: longint; override;
  end;

procedure clf_puts(s: PChar); cdecl; external name 'clf_puts';

{ The heap block the compiler emits, named exactly as heapmgr names it. }
var
  InitialHeapBlock: record end; external name '__fpc_initialheap';
  InitialHeapSize: PtrInt; external name '__heapsize';

var
  { One line buffer, and only the main program ever writes through it. No
    worker in this example prints: two cores inside this array at once would
    corrupt the output rather than report anything, and a rung that cannot say
    what it found is not a rung. }
  SayBuf: array[0..1023] of char;
  NewLine: array[0..1] of char;
  DestructorCount: longint;

  { Proof that threadvars are per-thread and not shared. }
  ThreadResult: longint;
  ThreadStackTop: PtrUInt;
  ThreadSptr: PtrUInt;
  ThreadCaught: longint;
  ThreadTVSeen: longint;

  { Where the thread ran, as the thread itself sees it. The main program reads
    its own core separately; if the two agree, no core was lent. }
  ThreadCore: longint;
  MainCore: longint;

  { The contended rung's shared state. Shared is stepped by both cores under
    one critical section and must come out exact. }
  Shared: longint;
  ShareLock: TRTLCriticalSection;
  GoEvent: PRTLEvent;
  DoneEvent: PRTLEvent;
  WorkerSteps: longint;
  HeapWorkerOK: longint;

  { Set by a worker as its VERY LAST act, after everything the main program
    will read. Nothing in the thread manager can bound a wait -- every timed
    wait here is untimed -- so a rung that simply waited would stop the board
    with no diagnosis at all. Watching this flag with a yield count instead
    turns "the worker never finished" into something the board says. }
  WorkerDone: longint;

threadvar
  TVWitness: longint;

{ ---- waiting for a worker without risking the board ------------------- }

const
  { Yields, not seconds. Each one is a scheduler yield on core 0 and costs
    about a microsecond, so this is a couple of seconds -- far longer than any
    rung here needs and far shorter than a boot nobody can interpret. }
  WATCH_LIMIT = 2000000;

function WorkerFinished: boolean;
var
  spins: longint;
begin
  spins := 0;
  { ThreadSwitch is an external call the compiler cannot see through, so the
    flag is reloaded every time round without needing to be volatile. }
  while (WorkerDone = 0) and (spins < WATCH_LIMIT) do
  begin
    ThreadSwitch;
    Inc(spins);
  end;
  Result := WorkerDone <> 0;
end;

{ ---- output ---------------------------------------------------------- }

procedure Say(const s: shortstring);
var
  i, n: longint;
begin
  n := Length(s);
  if n > High(SayBuf) - 2 then
    n := High(SayBuf) - 2;
  for i := 1 to n do
    SayBuf[i - 1] := s[i];
  SayBuf[n] := #10;
  SayBuf[n + 1] := #0;
  clf_puts(@SayBuf[0]);
end;

procedure SayAnsi(const s: AnsiString);
begin
  if Length(s) > 0 then
    clf_puts(PChar(s));
  clf_puts(@NewLine[0]);
end;

function NumStr(v: int64): shortstring;
begin
  Str(v, Result);
end;

function Hex16(v: PtrUInt): shortstring;
begin
  Result := '$' + HexStr(QWord(v), 16);
end;

function YesNo(b: boolean): shortstring;
begin
  if b then Result := 'yes' else Result := 'no';
end;

{ ---- the classes ------------------------------------------------------ }

constructor EClf.Create(ACode: longint);
begin
  inherited Create;
  Code := ACode;
end;

constructor TThing.Create(AValue: longint);
begin
  inherited Create;
  FValue := AValue;
end;

destructor TThing.Destroy;
begin
  Inc(DestructorCount);
  inherited Destroy;
end;

function TThing.Scaled: longint;
begin
  Result := FValue * 2;
end;

function TBigger.Scaled: longint;
begin
  Result := FValue * 10;
end;

{ ---- rungs ------------------------------------------------------------ }

procedure Rung1Alive;
var
  mm: TMemoryManager;
  base, size: PtrUInt;
  p: pointer;
begin
  Say('R1 pascal alive: PASCALMAIN entered, clf_puts reaches the UART');
  Say('R1 sizeof(ptr)=' + NumStr(SizeOf(Pointer)) + ' endian-check=' + NumStr(Ord(High(longint) = 2147483647)));
  Say('R1 System.StackTop      = ' + Hex16(PtrUInt(StackTop)));
  Say('R1 Circle stack top     = ' + Hex16(CLFRealStackTop) + '  size=' + NumStr(CLFRealStackSize));

  { Last boot printed "memory manager set = 0" while the heap plainly worked.
    IsMemoryManagerSet is not the flag it looks like: rtl/embedded/system.pp
    defines both HAS_MEMORYMANAGER and FPC_NO_DEFAULT_HEAP, and under either
    of those rtl/inc/heap.inc compiles the function to a bare "Result:=false".
    It is two instructions, mov w0,wzr and ret, and it cannot report anything
    -- there is no default manager for it to compare the installed one
    against. What follows is the question it was asked to answer, asked in a
    way that can actually be wrong. }
  Say('R1 IsMemoryManagerSet   = ' + NumStr(Ord(IsMemoryManagerSet)) + '  (a stub on this target: always false)');
  GetMemoryManager(mm);
  Say('R1 MemoryManager.GetMem = ' + Hex16(PtrUInt(mm.GetMem)));
  Say('R1 MemoryManager.FreeMem= ' + Hex16(PtrUInt(mm.FreeMem)));
  Say('R1 handlers non-nil     = ' + YesNo((mm.GetMem <> nil) and (mm.FreeMem <> nil)));

  base := PtrUInt(@InitialHeapBlock);
  size := PtrUInt(InitialHeapSize);
  Say('R1 __fpc_initialheap    = ' + Hex16(base) + ' .. ' + Hex16(base + size) + '  (' + NumStr(size) + ' bytes)');

  p := GetMem(64);
  Say('R1 first allocation at  = ' + Hex16(PtrUInt(p)));
  Say('R1 inside that block    = ' + YesNo((PtrUInt(p) >= base) and (PtrUInt(p) < base + size)));
  FreeMem(p, 64);
end;

procedure Rung2Arithmetic;
var
  a, b: longint;
  big: int64;
  ok: boolean;
begin
  Say('R2 start: arithmetic, no managed types');
  a := 6;
  b := 7;
  big := int64(a) * b * 1000000000;
  ok := (a * b = 42) and (big = 42000000000) and ((a shl 4) = 96) and ((b mod 4) = 3);
  if ok then
    Say('R2 OK 6*7=' + NumStr(a * b) + ' int64=' + NumStr(big))
  else
    Say('R2 FAIL');
end;

procedure Rung3AnsiStrings;
var
  s1, s2, s3: AnsiString;
  i: longint;
  ok: boolean;
begin
  Say('R3 start: AnsiString assign, concat, compare, reference counting');
  s1 := 'hello';
  s2 := ' world';
  s3 := s1 + s2;
  ok := (s3 = 'hello world') and (Length(s3) = 11) and (s3[1] = 'h');

  for i := 1 to 500 do
  begin
    s1 := s3;
    s2 := s1 + NumStr(i);
    s1 := '';
  end;
  ok := ok and (Length(s2) = 11 + Length(NumStr(500)));

  if ok then
  begin
    Say('R3 OK  concat len=' + NumStr(Length(s3)) + ' churn len=' + NumStr(Length(s2)));
    SayAnsi('R3 the string itself: "' + s3 + '"');
  end
  else
    Say('R3 FAIL');

  s1 := '';
  s2 := '';
  s3 := '';
end;

procedure Rung4Heap;
var
  p, q: PByte;
  i: longint;
  ok: boolean;
begin
  Say('R4 start: GetMem / FreeMem against the compiler-emitted heap block');

  { The heap's geometry, said out loud. It is a BSS block the compiler emits
    and heapmgr registers, sized at link time and never grown, so a program
    that runs out has to be given a bigger one rather than wait. Printing it
    costs a line and turns "an allocation returned nil" into something a
    reader can size up on the spot. }
  Say('R4 heap block  = ' + Hex16(PtrUInt(@InitialHeapBlock)) +
      ' .. ' + Hex16(PtrUInt(@InitialHeapBlock) + PtrUInt(InitialHeapSize)));
  Say('R4 heap size   = ' + NumStr(InitialHeapSize) + ' bytes');

  p := GetMem(CLF_HEAP_PROBE);
  ok := p <> nil;
  if ok then
  begin
    FillChar(p^, CLF_HEAP_PROBE, $5A);
    ok := (p[0] = $5A) and (p[CLF_HEAP_PROBE - 1] = $5A);
    FreeMem(p, CLF_HEAP_PROBE);
  end;

  for i := 1 to 2000 do
  begin
    q := GetMem(1024);
    if q = nil then
    begin
      ok := false;
      break;
    end;
    q[0] := 1;
    q[1023] := 2;
    FreeMem(q, 1024);
  end;

  if ok then
    Say('R4 OK  ' + NumStr(CLF_HEAP_PROBE) + ' bytes written and read back, 2000 alloc/free pairs survived')
  else
    Say('R4 FAIL');
end;

procedure Rung5DynArrays;
var
  d: array of longint;
  i: longint;
  sum: int64;
  ok: boolean;
begin
  Say('R5 start: dynamic array SetLength, grow, index, free');
  SetLength(d, 1000);
  ok := Length(d) = 1000;
  for i := 0 to 999 do
    d[i] := i * 3;

  SetLength(d, 2000);
  ok := ok and (Length(d) = 2000) and (d[999] = 2997) and (d[1500] = 0);

  sum := 0;
  for i := 0 to High(d) do
    sum := sum + d[i];
  ok := ok and (sum = 1498500);

  SetLength(d, 0);
  ok := ok and (Length(d) = 0);

  if ok then
    Say('R5 OK  grown to 2000, sum=' + NumStr(sum) + ', freed')
  else
    Say('R5 FAIL');
end;

procedure Rung6Classes;
var
  t, b: TThing;
  ok: boolean;
begin
  Say('R6 start: class instance, virtual dispatch, inheritance, destructor');
  DestructorCount := 0;
  t := TThing.Create(21);
  b := TBigger.Create(21);
  ok := (t.Scaled = 42) and (b.Scaled = 210) and (t.Value = 21)
        and (b is TThing) and (b is TBigger) and not (t is TBigger)
        and (t.ClassName = 'TThing') and (b.ClassName = 'TBigger');
  t.Free;
  b.Free;
  ok := ok and (DestructorCount = 2);

  if ok then
    Say('R6 OK  virtual dispatch 42/210, is-tests pass, ' + NumStr(DestructorCount) + ' destructors ran')
  else
    Say('R6 FAIL  destructors=' + NumStr(DestructorCount));
end;

procedure RaiseDeep(depth: longint);
begin
  if depth <= 0 then
    raise EClf.Create(4242);
  RaiseDeep(depth - 1);
  Inc(DestructorCount, 0);
end;

procedure Rung7ExceptNoWalk;
var
  caught: longint;
begin
  Say('R7 start: try..except with RaiseMaxFrameCount := 0 (frame walk disabled)');
  RaiseMaxFrameCount := 0;
  caught := 0;
  try
    RaiseDeep(8);
  except
    on E: EClf do
      caught := E.Code;
  end;
  if caught = 4242 then
    Say('R7 OK  raise from 8 frames deep caught, code=' + NumStr(caught))
  else
    Say('R7 FAIL  caught=' + NumStr(caught));
end;

procedure Rung8Finally;
var
  order: shortstring;
begin
  Say('R8 start: try..finally, and finally running as an exception passes through');
  order := '';
  try
    try
      order := order + 'a';
      RaiseDeep(3);
      order := order + 'X';
    finally
      order := order + 'b';
    end;
  except
    order := order + 'c';
  end;
  if order = 'abc' then
    Say('R8 OK  order=' + order)
  else
    Say('R8 FAIL order=' + order);
end;

procedure Rung9ExceptWithWalk;
var
  caught: longint;
begin
  Say('R9 start: the same raise with RaiseMaxFrameCount at its default 16');
  RaiseMaxFrameCount := 16;
  caught := 0;
  try
    RaiseDeep(8);
  except
    on E: EClf do
      caught := E.Code;
  end;
  if caught = 4242 then
    Say('R9 OK  frame walk survived on the main stack, code=' + NumStr(caught))
  else
    Say('R9 FAIL caught=' + NumStr(caught));
end;

{ ---- threading -------------------------------------------------------- }

function ThreadBody(p: pointer): PtrInt;
begin
  { Threadvar, written only here. The main thread writes a different value
    into the same name; if the two are one variable the check below fails. }
  TVWitness := 777;

  ThreadStackTop := CLFRealStackTop;
  ThreadSptr := PtrUInt(Sptr);
  ThreadTVSeen := TVWitness;
  ThreadCore := CLFThisCore;
  ThreadResult := longint(PtrUInt(p)) * 2;

  Result := ThreadResult;
  WorkerDone := 1;
end;

procedure Rung10Thread;
var
  tid: TThreadID;
  ok: boolean;
begin
  Say('R10 start: BeginThread on a lent core, then join it');
  Say('R10 IsMultiThread before = ' + YesNo(IsMultiThread));
  Say('R10 main is running on core ' + NumStr(MainCore));
  Say('R10 cores free for a thread = ' + Hex16(PtrUInt(CLFCoresFree)));
  ThreadResult := 0;
  ThreadCore := -1;
  TVWitness := 111;
  WorkerDone := 0;

  tid := BeginThread(@ThreadBody, pointer(PtrUInt(21)));
  Say('R10 BeginThread returned handle ' + NumStr(int64(tid)));
  if tid = 0 then
  begin
    Say('R10 FAIL  no thread was started');
    exit;
  end;

  if not WorkerFinished then
  begin
    Say('R10 FAIL  the thread never finished');
    exit;
  end;
  WaitForThreadTerminate(tid, 0);

  Say('R10 the thread ran on core ' + NumStr(ThreadCore));
  ok := (ThreadResult = 42) and IsMultiThread and (ThreadCore <> MainCore)
        and (ThreadCore > 0);
  if ok then
    Say('R10 OK  thread returned ' + NumStr(ThreadResult) +
        ' from core ' + NumStr(ThreadCore) + ', not from core ' + NumStr(MainCore))
  else
    Say('R10 FAIL result=' + NumStr(ThreadResult) + ' thread core=' + NumStr(ThreadCore) +
        ' main core=' + NumStr(MainCore));
end;

procedure Rung11ThreadVars;
begin
  Say('R11 start: threadvar storage is per-thread');
  Say('R11 main wrote 111, thread wrote 777 into the same threadvar');
  Say('R11 thread read back      = ' + NumStr(ThreadTVSeen));
  Say('R11 main still reads      = ' + NumStr(TVWitness));
  if (ThreadTVSeen = 777) and (TVWitness = 111) then
    Say('R11 OK  the two threads have separate storage')
  else
    Say('R11 FAIL  the threadvar is shared');
end;

procedure Rung12Sync;
var
  cs: TRTLCriticalSection;
  ev: PRTLEvent;
  ok: boolean;
begin
  Say('R12 start: critical section and RTL event, on one core');
  InitCriticalSection(cs);
  EnterCriticalSection(cs);
  LeaveCriticalSection(cs);
  ok := TryEnterCriticalSection(cs) <> 0;
  if ok then
    LeaveCriticalSection(cs);
  DoneCriticalSection(cs);

  ev := RTLEventCreate;
  ok := ok and (ev <> nil);
  if ok then
  begin
    RTLEventSetEvent(ev);
    RTLEventWaitFor(ev);      { already set, so this must not block }
    RTLEventDestroy(ev);
  end;

  if ok then
    Say('R12 OK  lock acquired, tried and released; event set and waited without blocking')
  else
    Say('R12 FAIL');
end;

{ The rung this whole example was really about. The main stack survived a
  frame walk in R9, but StackTop on this target is the address of _stack_top,
  one link-time symbol, and a thread on a lent core runs on that core's own
  stack rather than on the one that symbol names. The walk in
  rtl/inc/except.inc stops when a frame is not below StackTop, so what happens
  here depends on which side of _stack_top the lent core's stack lies. }

procedure ThreadRaiseDeep(depth: longint);
begin
  if depth <= 0 then
    raise EClf.Create(9999);
  ThreadRaiseDeep(depth - 1);
  Inc(DestructorCount, 0);
end;

function ThreadRaiseBody(p: pointer): PtrInt;
begin
  ThreadStackTop := CLFRealStackTop;
  ThreadSptr := PtrUInt(Sptr);
  ThreadCore := CLFThisCore;
  ThreadCaught := 0;
  try
    ThreadRaiseDeep(8);
  except
    on E: EClf do
      ThreadCaught := E.Code;
  end;
  Result := 0;
  WorkerDone := 1;
end;

procedure Rung13ThreadRaise;
var
  tid: TThreadID;
begin
  Say('R13 start: raise and catch on a lent core''s stack, RaiseMaxFrameCount = 16');
  RaiseMaxFrameCount := 16;
  ThreadCaught := 0;
  ThreadStackTop := 0;
  ThreadSptr := 0;
  ThreadCore := -1;
  WorkerDone := 0;

  tid := BeginThread(@ThreadRaiseBody, nil);
  if tid = 0 then
  begin
    Say('R13 FAIL  no thread was started');
    exit;
  end;
  if not WorkerFinished then
  begin
    Say('R13 FAIL  the thread never finished — a raise on the lent core''s stack ran away');
    exit;
  end;
  WaitForThreadTerminate(tid, 0);

  Say('R13 System.StackTop         = ' + Hex16(PtrUInt(StackTop)) + '  (the one link-time symbol)');
  Say('R13 core ' + NumStr(ThreadCore) + ' stack top          = ' + Hex16(ThreadStackTop));
  Say('R13 stack pointer in thread = ' + Hex16(ThreadSptr));
  Say('R13 thread stack above StackTop = ' + YesNo(ThreadSptr > PtrUInt(StackTop)));
  if ThreadCaught = 9999 then
    Say('R13 OK  raise from 8 frames deep on core ' + NumStr(ThreadCore) +
        '''s stack was caught, code=' + NumStr(ThreadCaught))
  else
    Say('R13 FAIL  caught=' + NumStr(ThreadCaught));
end;

{ ---- what the new model is for ---------------------------------------

  R14 is the rung the whole change was made for: two cores inside one critical
  section at the same time, and an event set on each core and seen on the
  other. Neither of those could be asked of the primitives this model
  replaces, because both were scheduler objects and a lent core has no
  scheduler.

  The worker prints nothing. The line buffer Say writes through is a single
  shared array, and two cores in it at once would corrupt the output rather
  than report anything. }

const
  SHARE_STEPS = 20000;

function ContendBody(p: pointer): PtrInt;
var
  i: longint;
begin
  ThreadCore := CLFThisCore;

  { Set by the main program once it is ready. On a lent core this wait is a
    genuine cross-core wait: nothing on this core can set it. }
  RTLEventWaitFor(GoEvent);

  for i := 1 to SHARE_STEPS do
  begin
    EnterCriticalSection(ShareLock);
    Inc(Shared);
    LeaveCriticalSection(ShareLock);
  end;

  WorkerSteps := SHARE_STEPS;
  RTLEventSetEvent(DoneEvent);
  Result := 0;
  WorkerDone := 1;
end;

procedure Rung14Contend;
var
  tid: TThreadID;
  i: longint;
begin
  Say('R14 start: two cores inside one critical section, and events both ways');
  Shared := 0;
  WorkerSteps := 0;
  ThreadCore := -1;
  WorkerDone := 0;
  InitCriticalSection(ShareLock);
  GoEvent := RTLEventCreate;
  DoneEvent := RTLEventCreate;

  tid := BeginThread(@ContendBody, nil);
  if tid = 0 then
  begin
    Say('R14 FAIL  no thread was started');
    DoneCriticalSection(ShareLock);
    exit;
  end;

  RTLEventSetEvent(GoEvent);

  for i := 1 to SHARE_STEPS do
  begin
    EnterCriticalSection(ShareLock);
    Inc(Shared);
    LeaveCriticalSection(ShareLock);
  end;

  { Watch the worker's own flag first, bounded. The event wait below is the
    real test of a cross-core RTL event, and it is entered only once the flag
    says the event has already been set -- at which point it is guaranteed to
    return. A wait that could not return would otherwise stop the board here
    with nothing said. }
  if not WorkerFinished then
  begin
    Say('R14 FAIL  the worker never finished; shared so far = ' + NumStr(Shared));
    RTLEventDestroy(GoEvent);
    RTLEventDestroy(DoneEvent);
    DoneCriticalSection(ShareLock);
    exit;
  end;

  { Set by the worker from the other core. }
  RTLEventWaitFor(DoneEvent);
  WaitForThreadTerminate(tid, 0);

  Say('R14 worker ran on core     = ' + NumStr(ThreadCore));
  Say('R14 steps per core         = ' + NumStr(SHARE_STEPS));
  Say('R14 shared counter         = ' + NumStr(Shared) +
      ' (exact answer ' + NumStr(2 * SHARE_STEPS) + ')');

  if (Shared = 2 * SHARE_STEPS) and (WorkerSteps = SHARE_STEPS)
     and (ThreadCore <> MainCore) then
    Say('R14 OK  the lock excluded across cores and both events crossed')
  else
    Say('R14 FAIL  counter=' + NumStr(Shared) + ' workersteps=' + NumStr(WorkerSteps) +
        ' worker core=' + NumStr(ThreadCore));

  RTLEventDestroy(GoEvent);
  RTLEventDestroy(DoneEvent);
  DoneCriticalSection(ShareLock);
end;

{ Two cores in the Free Pascal heap at once. heapmgr walks a free list with no
  lock of its own, so this rung is here to exercise the lock the library wraps
  it in. It is a smoke test and says so: passing means nothing came apart in
  this many allocations, not that no ordering can. }

const
  HEAP_STEPS = 4000;

function HeapBody(p: pointer): PtrInt;
var
  i: longint;
  q: pointer;
  bad: longint;
begin
  ThreadCore := CLFThisCore;
  bad := 0;
  for i := 1 to HEAP_STEPS do
  begin
    q := GetMem(64);
    if q = nil then
      Inc(bad)
    else
    begin
      FillChar(q^, 64, byte(i));
      if PByte(q)^ <> byte(i) then
        Inc(bad);
      FreeMem(q);
    end;
  end;
  if bad = 0 then
    HeapWorkerOK := 1
  else
    HeapWorkerOK := 0;
  Result := 0;
  WorkerDone := 1;
end;

procedure Rung15HeapTwoCores;
var
  tid: TThreadID;
  i, bad: longint;
  q: pointer;
begin
  Say('R15 start: both cores allocating from the Free Pascal heap at once');
  HeapWorkerOK := 0;
  ThreadCore := -1;
  WorkerDone := 0;
  bad := 0;

  tid := BeginThread(@HeapBody, nil);
  if tid = 0 then
  begin
    Say('R15 FAIL  no thread was started');
    exit;
  end;

  for i := 1 to HEAP_STEPS do
  begin
    q := GetMem(96);
    if q = nil then
      Inc(bad)
    else
    begin
      FillChar(q^, 96, byte(i));
      if PByte(q)^ <> byte(i) then
        Inc(bad);
      FreeMem(q);
    end;
  end;

  if not WorkerFinished then
  begin
    Say('R15 FAIL  the worker never finished; the heap lock did not hold');
    exit;
  end;
  WaitForThreadTerminate(tid, 0);

  Say('R15 allocations per core   = ' + NumStr(HEAP_STEPS));
  Say('R15 bad blocks on core ' + NumStr(MainCore) + '   = ' + NumStr(bad));
  Say('R15 worker on core ' + NumStr(ThreadCore) + ' clean  = ' + YesNo(HeapWorkerOK = 1));

  { The heap has to still serve after all that. }
  q := GetMem(4096);
  if (q = nil) or (bad <> 0) or (HeapWorkerOK <> 1) then
    Say('R15 FAIL  the heap did not survive two cores')
  else
  begin
    FreeMem(q);
    Say('R15 OK  both cores allocated and freed, and the heap still serves');
  end;
end;

{ Placement asked for by name rather than taken. }

function PlacedBody(p: pointer): PtrInt;
begin
  ThreadCore := CLFThisCore;
  Result := 0;
  WorkerDone := 1;
end;

procedure Rung16Placement;
var
  tid: TThreadID;
  free, want, i: longint;
begin
  Say('R16 start: placing a thread on a named core');
  free := CLFCoresFree;
  Say('R16 cores free = ' + Hex16(PtrUInt(free)));

  want := 0;
  for i := 1 to 31 do
    if (free and (1 shl i)) <> 0 then
    begin
      want := i;
      break;
    end;

  if want = 0 then
  begin
    Say('R16 FAIL  no core is free to place a thread on');
    exit;
  end;

  Say('R16 asking for core ' + NumStr(want));
  if not CLFPinNextThread(want) then
  begin
    Say('R16 FAIL  the placement request was refused');
    exit;
  end;

  ThreadCore := -1;
  WorkerDone := 0;
  tid := BeginThread(@PlacedBody, nil);
  if tid = 0 then
  begin
    Say('R16 FAIL  no thread was started');
    exit;
  end;
  if not WorkerFinished then
  begin
    Say('R16 FAIL  the thread never finished');
    exit;
  end;
  WaitForThreadTerminate(tid, 0);

  Say('R16 the thread ran on core ' + NumStr(ThreadCore));
  if ThreadCore = want then
    Say('R16 OK  the thread went where it was told')
  else
    Say('R16 FAIL  asked for core ' + NumStr(want) + ', got core ' + NumStr(ThreadCore));
end;

begin
  NewLine[0] := #10;
  NewLine[1] := #0;

  MainCore := CLFThisCore;

  Say('');
  Say('=== CLF Pascal blob: aarch64-embedded on Circle, Raspberry Pi 5 ===');
  Say('main core = ' + NumStr(MainCore) + ', cores lent for threads = ' +
      Hex16(PtrUInt(CLFCoresFree)));

  Rung1Alive;
  Rung2Arithmetic;
  Rung3AnsiStrings;
  Rung4Heap;
  Rung5DynArrays;
  Rung6Classes;
  Rung7ExceptNoWalk;
  Rung8Finally;
  Rung9ExceptWithWalk;
  Rung10Thread;
  Rung11ThreadVars;
  Rung12Sync;
  Rung13ThreadRaise;
  Rung14Contend;
  Rung15HeapTwoCores;
  Rung16Placement;

  Say('=== CLF LADDER COMPLETE: every rung reported ===');
end.
