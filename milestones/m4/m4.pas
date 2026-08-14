{
  m4.pas — the Pascal program that proves threads.

  WHAT THIS MILESTONE ASKS FOR, in one sentence with five separate claims
  inside it: two Pascal threads run, each with its own ThreadVar state and its
  own exception state, and each takes its turn without stopping the other;
  both run on the application core, no Pascal executes on any other core, and
  no Circle task is created for either.

  Each of those fails differently, so each has a section of its own below and
  each section prints its own figures, its own tolerance and its own verdict.

  THE MACHINE THESE THREADS RUN ON HAS ONE CORE. That is not a limitation
  being worked around here: it is what the guest machine is. A computer with
  one core has always run threads, and these are those. circle-libfpc creates
  them, holds their stacks, and decides which one is running; the core is
  handed from one to the next by saving one register set and restoring
  another. Nothing about them is visible outside this core, and to the rest of
  the board the application core is still one line of execution.

  NOTHING PREEMPTS. There is no timer interrupt behind the scheduler and
  nothing takes the core away. A thread that neither enters the runtime nor
  calls SDL holds the core until it stops. Every thread below therefore gives
  the core up on purpose — by an explicit switch, by waiting on something, or
  by sleeping — and a section that hung would be a section where one of them
  did not.

  WHAT WOULD CATCH A THREAD THAT LEFT THE CORE. Section 5 does not print the
  core the design intended. It prints the core the processor says each thread
  was executing on, sampled thousands of times while the threads ran, as a set
  of bits — and the runtime itself stops the program the moment a sample
  disagrees with the core the guest was started on. A thread carried by
  anything that placed it elsewhere fails that at its first instruction. The
  other half of the same question is Circle's task list, and that is the host
  kernel's to report because the list belongs to the core that owns the
  devices: it is sampled continuously on that core, including while these
  threads are alive, and printed there.

  NOTHING HERE IS FLOATING POINT, and no timed region contains a writeln.
}
program m4;

{$mode objfpc}
{$H+}

const
  { How many turns each of the two workers takes in the interleaving section.
    Enough that a thread which ran ahead could not be mistaken for one that
    took its turn, and few enough that the trace fits in memory. }
  Rounds = 64;

  { The trace of who ran when. One byte per turn. }
  MaxTrace = 4 * Rounds;

  { THE TOLERANCE FOR "EACH TAKES ITS TURN".

    Both workers are runnable, each notes itself and then hands the core on,
    and the scheduler walks the run list round. So the expected trace is
    strict alternation and the longest run of one thread's own marks is one.
    Two is allowed, for the single lap at each end where the other worker has
    not started yet or has already finished. Three or more means one thread
    was allowed to stop the other, which is the failure this section exists to
    catch. }
  LongestRunAllowed = 2;

  { How many times the exception worker raises and catches inside its own
    handler while the other thread is sitting inside a try block of its own.
    Each of them is a chance for a shared exception chain to be caught. }
  RaiseRounds = 32;

  { How many times each worker enters and leaves the critical section, giving
    the core away while holding it. }
  SectionRounds = 32;

  { The stacks handed to the threads in this program.

    THE MEASURING THREAD IS GIVEN FAR MORE THAN IT COULD NEED, on purpose: it
    is the thread whose high-water mark answers what a stack should be, and a
    measurement taken against a stack that was nearly full would be a
    measurement of the ceiling rather than of the thread.

    The workers are given the candidate below, so that the same run says
    whether the candidate holds for ordinary work. }
  ProbeStack  = 256 * 1024;
  WorkerStack = 64 * 1024;

  { THE CANDIDATE DEFAULT, WHICH IS WHAT THIS PROGRAM IS ASKED TO TEST RATHER
    THAN TO ASSUME. What a Pascal thread's stack should be is not settled, and
    a stack that is too small does not announce itself. Section 6 prints what
    each thread actually used and how much of this candidate was left over.

    Free Pascal's own DefaultStackSize, which the short BeginThread overloads
    pass, is four megabytes. That is the generic runtime's constant and is not
    this target's to change, so a program that wants this instead passes it. }
  CandidateDefaultStack = 64 * 1024;

  { What a wait may overshoot by. The scheduler's grain here is one lap of the
    run list, which is a handful of microseconds with two threads on it, so
    five milliseconds is a large multiple of it and still far below anything
    that would look like a scheduler tick. A wait is never allowed to be
    short by any amount. }
  WaitOvershootMs = 5;

  { How long the main thread sleeps while a worker counts its turns. Long
    enough that a worker getting no turns at all is unmistakable. }
  YieldProofMs = 200;

  { The pause between sections. The log channel never blocks and drops a line
    it has no room for, and the console is far slower than this core, so a
    program that prints a long burst can outrun the wire and lose the middle
    of its own report. }
  PaceMicros = 250000;

  { What a wait reports. These are the Free Pascal runtime's own values, named
    here because this target's system unit keeps them to itself. }
  wrSignaled = 0;
  wrTimeout  = 1;

type
  { The exception every raise below builds. A class, so the raise is an object
    the heap had to make, and the marker is what says whose exception was
    caught. }
  EM4 = class(TObject)
  public
    Marker: LongInt;
    constructor Create(AMarker: LongInt);
  end;

constructor EM4.Create(AMarker: LongInt);
begin
  inherited Create;
  Marker := AMarker;
end;


{ THE STATE EACH THREAD HAS OF ITS OWN, and the whole point of section 3.

  Every access to one of these compiles to a call through the runtime's
  relocation hook, and this target's hook answers from the running thread's
  own block. So the same name below reads and writes a different word
  depending on which thread is asking, and nothing in the source says which. }
threadvar
  TVCount : LongInt;
  TVTag   : ShortString;


{ THE HOST KERNEL'S HALF OF THE "NO CIRCLE TASK" QUESTION.

  Circle's task list belongs to the core that owns the devices, and the guest
  is not on that core, so this program cannot read it and must not try. What
  it can do is say when its own threads are alive, so that the host kernel
  samples the list at the moment a violation would be visible rather than only
  before and after. The kernel prints what it saw. }
procedure M4_ThreadsAlive(Count: LongInt); cdecl; external name 'M4_ThreadsAlive';


{****************************************************************************
                          Formatting and verdicts
****************************************************************************}

function Verdict(Passed: Boolean): ShortString;
begin
  if Passed then
    Verdict := 'PASS'
  else
    Verdict := 'FAIL';
end;


{ A core mask printed as the set of cores it names, because a bit pattern is
  not what the reader is checking. }
function CoreSetText(Mask: LongWord): ShortString;
var
  I: LongInt;
  Piece: ShortString;
begin
  CoreSetText := '';
  for I := 0 to 31 do
    if (Mask and (LongWord(1) shl I)) <> 0 then
      begin
        Str(I, Piece);
        if CoreSetText = '' then
          CoreSetText := Piece
        else
          CoreSetText := CoreSetText + ',' + Piece;
      end;
  if CoreSetText = '' then
    CoreSetText := 'none'
  else
    CoreSetText := '{' + CoreSetText + '}';
end;


{ Milliseconds, to three places, from a count of microseconds. }
function MsText(Micros: QWord): ShortString;
var
  Digits: ShortString;
begin
  Str(Micros div 1000, MsText);
  Str(Micros mod 1000, Digits);
  while Length(Digits) < 3 do
    Digits := '0' + Digits;
  MsText := MsText + '.' + Digits + ' ms';
end;


procedure Pace;
begin
  CircleWaitMicroseconds(PaceMicros);
end;


{****************************************************************************
                        What the threads share
****************************************************************************}

var
  { Section 2. Who ran, in the order they ran. }
  Trace     : array[0..MaxTrace - 1] of Byte;
  TraceLen  : LongInt = 0;

  { Section 3. Where each worker leaves its own thread-variable readings, so
    the main thread can print all three side by side. }
  SeenCountA, SeenCountB : LongInt;
  SeenTagA, SeenTagB     : ShortString;

  { Section 4. }
  ARaiseDone   : Boolean = False;
  ACaught      : LongInt = 0;
  ALastMarker  : LongInt = 0;
  AMarkerHeldAcrossSwitch : Boolean = True;
  GuardHandlerRuns : LongInt = 0;
  GuardCaught      : LongInt = 0;
  GuardEnteredTry  : Boolean = False;

  { Section 5. Sampled by the workers themselves, in their own loops, as well
    as by the runtime at every scheduler entry. }
  SampledCoresA, SampledCoresB : LongWord;
  SamplesA, SamplesB           : LongWord;

  { Section 6. The measuring thread's high-water mark after each stage. }
  ProbeStage     : array[0..5] of PtrUInt;
  ProbeStageName : array[0..5] of ShortString;

  { Section 7. }
  Section     : TRTLCriticalSection;
  Occupant    : LongInt = 0;
  Overlaps    : LongInt = 0;
  GuardedCount: LongInt = 0;

  { Section 8. }
  RTLSignal          : PRTLEvent = nil;
  RTLWorkerWokeAt    : QWord = 0;
  RTLSetAt           : QWord = 0;

  { Section 9. }
  SpinnerTurns : QWord = 0;
  SpinnerStop  : Boolean = False;

  { Every thread this program makes. }
  IdA, IdB, IdProbe, IdBlocked, IdSpinner : TThreadID;


procedure Note(Who: Byte);
begin
  if TraceLen < MaxTrace then
    begin
      Trace[TraceLen] := Who;
      Inc(TraceLen);
    end;
end;


{****************************************************************************
   1. The machine, before any thread exists
****************************************************************************}

var
  GuestCoreAtStart : LongWord;

function ProveTheMachine: Boolean;
var
  Live: LongWord;
begin
  writeln;
  writeln('--- 1. the machine the Pascal program runs on ---');

  GuestCoreAtStart := CircleGuestCore;
  Live := CircleCurrentCore;

  writeln('the guest core, recorded before any thread existed = ',
          GuestCoreAtStart);
  writeln('the core the processor says this line is on        = ', Live);
  writeln('the main thread, as the scheduler knows it         = ',
          PtrUInt(GetCurrentThreadId));
  writeln('threads on the run list                            = ',
          CircleThreadCount);
  writeln('the thread-variable block, per thread              = ',
          CircleThreadVarBlockSize, ' bytes');
  writeln('IsMultiThread                                      = ', IsMultiThread);

  writeln('tolerance: none. these two core numbers are the same register ',
          'read twice and must agree exactly.');
  ProveTheMachine := (Live = GuestCoreAtStart) and
                     (CircleThreadCount = 1) and
                     (CircleThreadVarBlockSize > 0);
  writeln('1. the machine ', Verdict(ProveTheMachine));
end;


{****************************************************************************
   2. Two threads run, and each takes its turn
****************************************************************************}

function TurnTakerA(P: Pointer): PtrInt;
var
  I: LongInt;
begin
  TVCount := 1;
  TVTag := 'worker-a';
  SampledCoresA := 0;
  SamplesA := 0;
  for I := 1 to Rounds do
    begin
      Note(1);
      SampledCoresA := SampledCoresA or (LongWord(1) shl (CircleCurrentCore and 31));
      Inc(SamplesA);
      Inc(TVCount);
      ThreadSwitch;
    end;
  SeenCountA := TVCount;
  SeenTagA := TVTag;
  TurnTakerA := 0;
end;


function TurnTakerB(P: Pointer): PtrInt;
var
  I: LongInt;
begin
  TVCount := 2000000;
  TVTag := 'worker-b';
  SampledCoresB := 0;
  SamplesB := 0;
  for I := 1 to Rounds do
    begin
      Note(2);
      SampledCoresB := SampledCoresB or (LongWord(1) shl (CircleCurrentCore and 31));
      Inc(SamplesB);
      Inc(TVCount, 1000);
      ThreadSwitch;
    end;
  SeenCountB := TVCount;
  SeenTagB := TVTag;
  TurnTakerB := 0;
end;


{ The longest number of consecutive marks made by one thread anywhere in the
  trace. One means the two threads alternated perfectly. }
function LongestRun: LongInt;
var
  I, Run: LongInt;
begin
  LongestRun := 0;
  if TraceLen = 0 then
    exit;
  Run := 1;
  LongestRun := 1;
  for I := 1 to TraceLen - 1 do
    begin
      if Trace[I] = Trace[I - 1] then
        Inc(Run)
      else
        Run := 1;
      if Run > LongestRun then
        LongestRun := Run;
    end;
end;


function CountIn(Who: Byte): LongInt;
var
  I: LongInt;
begin
  CountIn := 0;
  for I := 0 to TraceLen - 1 do
    if Trace[I] = Who then
      Inc(CountIn);
end;


function ProveTheyTakeTurns: Boolean;
var
  Run, NA, NB: LongInt;
begin
  writeln;
  writeln('--- 2. two threads run, and each takes its turn ---');

  TraceLen := 0;
  TVCount := 1000;
  TVTag := 'main';

  IdA := BeginThread(@TurnTakerA, nil, IdA, WorkerStack);
  IdB := BeginThread(@TurnTakerB, nil, IdB, WorkerStack);
  if (IdA = 0) or (IdB = 0) then
    begin
      writeln('BeginThread refused: a=', PtrUInt(IdA), ' b=', PtrUInt(IdB));
      writeln('2. turns FAIL');
      ProveTheyTakeTurns := False;
      exit;
    end;
  SetThreadDebugName(IdA, 'worker-a');
  SetThreadDebugName(IdB, 'worker-b');

  { Two Pascal threads are alive from here until the joins below. The host
    kernel samples Circle's task list on its own core throughout. }
  M4_ThreadsAlive(2);

  WaitForThreadTerminate(IdA, 0);
  WaitForThreadTerminate(IdB, 0);

  M4_ThreadsAlive(0);

  Run := LongestRun;
  NA := CountIn(1);
  NB := CountIn(2);

  writeln('turns recorded: worker-a ', NA, ', worker-b ', NB,
          ', in a trace of ', TraceLen);
  writeln('switches taken: worker-a ', CircleThreadSwitches(IdA),
          ', worker-b ', CircleThreadSwitches(IdB));
  writeln('the longest run of one thread''s own marks = ', Run);
  writeln('tolerance: at most ', LongestRunAllowed,
          ' - the scheduler walks the run list round and both threads hand ',
          'the core on after every mark, so one is expected and two is the ',
          'lap where the other has not started or has already finished.');

  ProveTheyTakeTurns := (NA = Rounds) and (NB = Rounds) and
                        (Run <= LongestRunAllowed);
  writeln('2. turns ', Verdict(ProveTheyTakeTurns));
end;


{****************************************************************************
   3. Each thread has its own ThreadVar state
****************************************************************************}

function ProveThreadVars: Boolean;
var
  MainOK, AOK, BOK: Boolean;
begin
  writeln;
  writeln('--- 3. each thread has its own ThreadVar state ---');
  writeln('ONE NAME, THREE VALUES. TVCount and TVTag are declared once. Each ',
          'thread wrote its own and read its own back, across ', Rounds,
          ' switches each.');

  MainOK := (TVCount = 1000) and (TVTag = 'main');
  AOK := (SeenCountA = 1 + Rounds) and (SeenTagA = 'worker-a');
  BOK := (SeenCountB = 2000000 + Rounds * 1000) and (SeenTagB = 'worker-b');

  writeln('main     TVCount = ', TVCount, ' (expected 1000), TVTag = ''',
          TVTag, '''');
  writeln('worker-a TVCount = ', SeenCountA, ' (expected ', 1 + Rounds,
          '), TVTag = ''', SeenTagA, '''');
  writeln('worker-b TVCount = ', SeenCountB, ' (expected ',
          2000000 + Rounds * 1000, '), TVTag = ''', SeenTagB, '''');
  writeln('tolerance: none. every value is an exact arithmetic result and a ',
          'shared variable would have produced one number, not three.');

  ProveThreadVars := MainOK and AOK and BOK;
  writeln('3. threadvars ', Verdict(ProveThreadVars));
end;


{****************************************************************************
   4. Each thread has its own exception state
****************************************************************************}

{ THE RAISER. It raises, catches its own exception, and then GIVES THE CORE
  AWAY WHILE STILL INSIDE ITS OWN HANDLER — which is the moment its exception
  object is on its exception object stack and its try level is raised. If
  either of those were shared, the thread that runs next would be running with
  this thread's exception in flight. }
function ExceptionRaiser(P: Pointer): PtrInt;
var
  I, Marker: LongInt;
begin
  for I := 1 to RaiseRounds do
    begin
      Marker := 70000 + I;
      try
        raise EM4.Create(Marker);
      except
        on E: EM4 do
          begin
            Inc(ACaught);
            { Away, and back, with this exception still being handled. }
            ThreadSwitch;
            if E.Marker <> Marker then
              AMarkerHeldAcrossSwitch := False;
            ALastMarker := E.Marker;
          end;
      end;
      ThreadSwitch;
    end;
  ARaiseDone := True;
  ExceptionRaiser := 0;
end;


{ THE GUARD. It sits inside a try block of its own for the whole time the
  raiser is raising, handing the core over and over, and only then raises one
  exception of its own. Its handler must run exactly once, for its own
  exception, with its own marker. A shared exception chain would have caught
  one of the raiser's here instead. }
function ExceptionGuard(P: Pointer): PtrInt;
begin
  try
    GuardEnteredTry := True;
    while not ARaiseDone do
      ThreadSwitch;
    raise EM4.Create(31337);
  except
    on E: EM4 do
      begin
        Inc(GuardHandlerRuns);
        GuardCaught := E.Marker;
      end;
  end;
  ExceptionGuard := 0;
end;


function ProveExceptionState: Boolean;
var
  IdRaiser, IdGuard: TThreadID;
  MainCaught: LongInt;
begin
  writeln;
  writeln('--- 4. each thread has its own exception state ---');
  writeln('NOTHING WAS WRITTEN FOR THIS. The exception address stack, the ',
          'exception object stack and the try level are thread variables in ',
          'Free Pascal''s own runtime, so a thread with its own block has ',
          'its own exception state.');

  ACaught := 0;
  ALastMarker := 0;
  ARaiseDone := False;
  AMarkerHeldAcrossSwitch := True;
  GuardHandlerRuns := 0;
  GuardCaught := 0;
  GuardEnteredTry := False;

  IdGuard := BeginThread(@ExceptionGuard, nil, IdGuard, WorkerStack);
  IdRaiser := BeginThread(@ExceptionRaiser, nil, IdRaiser, WorkerStack);
  M4_ThreadsAlive(2);
  WaitForThreadTerminate(IdRaiser, 0);
  WaitForThreadTerminate(IdGuard, 0);
  M4_ThreadsAlive(0);
  CloseThread(IdRaiser);
  CloseThread(IdGuard);

  { And the main thread's own, after all of that, to show the thread that
    started them still has an exception state of its own. }
  MainCaught := 0;
  try
    raise EM4.Create(4242);
  except
    on E: EM4 do
      MainCaught := E.Marker;
  end;

  writeln('the raiser raised and caught its own      = ', ACaught,
          ' of ', RaiseRounds, ', last marker ', ALastMarker);
  writeln('its exception survived a switch inside its own handler = ',
          AMarkerHeldAcrossSwitch);
  writeln('the guard sat inside its try block        = ', GuardEnteredTry);
  writeln('the guard''s handler ran                   = ', GuardHandlerRuns,
          ' time(s), catching marker ', GuardCaught, ' (its own is 31337)');
  writeln('the main thread caught its own            = ', MainCaught,
          ' (its own is 4242)');
  writeln('tolerance: none. the guard''s handler running for anything other ',
          'than its own marker, or more than once, is a shared chain.');

  ProveExceptionState := (ACaught = RaiseRounds) and
                         AMarkerHeldAcrossSwitch and
                         (ALastMarker = 70000 + RaiseRounds) and
                         GuardEnteredTry and
                         (GuardHandlerRuns = 1) and
                         (GuardCaught = 31337) and
                         (MainCaught = 4242);
  writeln('4. exception state ', Verdict(ProveExceptionState));
end;


{****************************************************************************
   5. Both threads ran on the application core, and nowhere else
****************************************************************************}

function ProveTheCore: Boolean;
var
  Expected: LongWord;
  MaskA, MaskB, MaskMain: LongWord;
begin
  writeln;
  writeln('--- 5. both threads ran on the application core ---');
  writeln('THE RUNTIME ALREADY STOPPED THE PROGRAM IF THIS WAS EVER FALSE. ',
          'Every entry to the scheduler reads the processor''s own core ',
          'number and compares it with the core recorded before any thread ',
          'existed. What is below is the record of what those reads saw.');

  Expected := LongWord(1) shl (GuestCoreAtStart and 31);
  MaskMain := CircleThreadCoreMask(GetCurrentThreadId);
  MaskA := CircleThreadCoreMask(IdA);
  MaskB := CircleThreadCoreMask(IdB);

  writeln('the guest core                    = ', GuestCoreAtStart);
  writeln('cores the runtime saw, main       = ', CoreSetText(MaskMain));
  writeln('cores the runtime saw, worker-a   = ', CoreSetText(MaskA),
          ', first instruction on core ', CircleThreadFirstCore(IdA));
  writeln('cores the runtime saw, worker-b   = ', CoreSetText(MaskB),
          ', first instruction on core ', CircleThreadFirstCore(IdB));
  writeln('cores the workers sampled themselves, a = ',
          CoreSetText(SampledCoresA), ' over ', SamplesA, ' samples');
  writeln('cores the workers sampled themselves, b = ',
          CoreSetText(SampledCoresB), ' over ', SamplesB, ' samples');
  writeln('tolerance: none. every one of these is a set with exactly one ',
          'member and it is the same member.');

  ProveTheCore := (MaskMain = Expected) and (MaskA = Expected) and
                  (MaskB = Expected) and
                  (SampledCoresA = Expected) and (SampledCoresB = Expected) and
                  (SamplesA = Rounds) and (SamplesB = Rounds) and
                  (CircleThreadFirstCore(IdA) = GuestCoreAtStart) and
                  (CircleThreadFirstCore(IdB) = GuestCoreAtStart);
  writeln('5. the core ', Verdict(ProveTheCore));
end;


{****************************************************************************
   6. What a Pascal thread's stack actually costs
****************************************************************************}

{ A call chain with something in every frame, so that a depth costs what a
  depth costs rather than being turned into a loop. }
function Descend(Depth: LongInt): LongInt;
var
  Pad: array[0..7] of QWord;
  I: LongInt;
begin
  for I := 0 to 7 do
    Pad[I] := QWord(Depth) * QWord(I + 1);
  if Depth > 0 then
    Descend := Pad[Depth and 7] + Descend(Depth - 1)
  else
    Descend := Pad[0];
end;


function StackProbe(P: Pointer): PtrInt;
var
  Me: TThreadID;
  Junk: LongInt;
  Caught: LongInt;
begin
  Me := GetCurrentThreadId;

  { Stage 0. The first statement of the thread's own code. Everything below
    this mark is the runtime's own entry: the trampoline, InitThread, the
    thread's standard files being opened and its exception stacks being set
    up. }
  ProbeStage[0] := CircleThreadStackUsed(Me);

  writeln('   (the measuring thread is speaking)');
  ProbeStage[1] := CircleThreadStackUsed(Me);

  writeln('   (and printing numbers: ', 1234567890, ' ', PtrUInt(Me), ')');
  ProbeStage[2] := CircleThreadStackUsed(Me);

  Junk := Descend(32);
  if Junk = -1 then
    writeln('   (unreachable)');
  ProbeStage[3] := CircleThreadStackUsed(Me);

  Caught := 0;
  try
    raise EM4.Create(99);
  except
    on E: EM4 do
      Caught := E.Marker;
  end;
  if Caught <> 99 then
    writeln('   (the measuring thread did not catch its own exception)');
  ProbeStage[4] := CircleThreadStackUsed(Me);

  { A wait, which is where SDL is serviced — and SDL is serviced on whatever
    stack called into it, which here is this thread's. }
  CircleWaitMicroseconds(20000);
  ProbeStage[5] := CircleThreadStackUsed(Me);

  StackProbe := 0;
end;


function ProveTheStack: Boolean;
var
  I: LongInt;
  Worst, HeadRoom: PtrUInt;
  UsedA, UsedB: PtrUInt;
begin
  writeln;
  writeln('--- 6. what a Pascal thread''s stack costs ---');
  writeln('A STACK THAT IS TOO SMALL DOES NOT ANNOUNCE ITSELF, so this ',
          'runtime writes a pattern over every stack it hands out and reads ',
          'back where the pattern stops. What follows is the deepest each ',
          'thread ever went, not how deep it is now.');

  ProbeStageName[0] := 'the runtime''s own entry, before the thread''s first statement';
  ProbeStageName[1] := 'after one writeln of text';
  ProbeStageName[2] := 'after one writeln with numbers in it';
  ProbeStageName[3] := 'after a call chain 32 deep';
  ProbeStageName[4] := 'after raising and catching one exception';
  ProbeStageName[5] := 'after a timed wait, which services SDL on this stack';

  for I := 0 to 5 do
    ProbeStage[I] := 0;

  IdProbe := BeginThread(@StackProbe, nil, IdProbe, ProbeStack);
  if IdProbe = 0 then
    begin
      writeln('BeginThread refused the measuring thread.');
      writeln('6. the stack FAIL');
      ProveTheStack := False;
      exit;
    end;
  SetThreadDebugName(IdProbe, 'stack-probe');
  M4_ThreadsAlive(1);
  WaitForThreadTerminate(IdProbe, 0);
  M4_ThreadsAlive(0);

  writeln('measured on a stack of ', CircleThreadStackSize(IdProbe),
          ' bytes, so nothing below is near its ceiling:');
  Worst := 0;
  for I := 0 to 5 do
    begin
      writeln('  ', ProbeStage[I]:6, ' bytes  ', ProbeStageName[I]);
      if ProbeStage[I] > Worst then
        Worst := ProbeStage[I];
    end;

  UsedA := CircleThreadStackUsed(IdA);
  UsedB := CircleThreadStackUsed(IdB);
  writeln('the two workers of section 2, on ', WorkerStack,
          ' byte stacks, used ', UsedA, ' and ', UsedB, ' bytes.');

  writeln('tolerance: every figure must be more than nothing and less than ',
          'the stack it was measured on. A zero would mean the pattern was ',
          'never written, and a figure at the ceiling would mean the ',
          'measurement had run out of room to be right.');

  ProveTheStack := (Worst > 0) and (UsedA > 0) and (UsedB > 0) and
                   (Worst < ProbeStack) and
                   (UsedA < WorkerStack) and (UsedB < WorkerStack);
  writeln('6. the stack ', Verdict(ProveTheStack));

  { WHAT THE STACK SIZE SHOULD BE IS AN OPEN DECISION AND NOT PART OF THIS
    MILESTONE'S VERDICT. The measurement above is what it needs; the lines
    below only say what that measurement implies for one candidate, so that
    the decision is made against a number rather than a guess. }
  writeln;
  writeln('--- 6a. what the measurement implies, for a decision not yet made ---');
  writeln('the candidate default is ', CandidateDefaultStack, ' bytes.');
  if Worst = 0 then
    writeln('there is no measurement to judge it against.')
  else if Worst >= CandidateDefaultStack then
    writeln('the deepest measurement, ', Worst,
            ' bytes, does not fit inside it, so the candidate is too small.')
  else
    begin
      HeadRoom := CandidateDefaultStack - Worst;
      writeln('the deepest measurement is ', Worst, ' bytes, so ', HeadRoom,
              ' bytes are left - ', CandidateDefaultStack div Worst,
              ' times the measurement - for the program''s own call depth ',
              'on top of the runtime''s and SDL''s.');
    end;
  writeln('for comparison, Free Pascal''s own DefaultStackSize, which the ',
          'short BeginThread overloads pass, is ', DefaultStackSize,
          ' bytes on a heap that is fixed when the board comes up.');
end;


{****************************************************************************
   7. Critical sections
****************************************************************************}

function SectionWorker(P: Pointer): PtrInt;
var
  I, Me: LongInt;
begin
  Me := LongInt(PtrUInt(P));
  for I := 1 to SectionRounds do
    begin
      EnterCriticalSection(Section);
      if Occupant <> 0 then
        Inc(Overlaps);
      Occupant := Me;

      { GIVING THE CORE AWAY WHILE HOLDING THE SECTION is what makes this a
        test. The other worker gets a turn, tries to enter, and must be held
        out until this one leaves. }
      ThreadSwitch;

      if Occupant <> Me then
        Inc(Overlaps);
      Inc(GuardedCount);
      Occupant := 0;
      LeaveCriticalSection(Section);
      ThreadSwitch;
    end;
  SectionWorker := 0;
end;


function ProveCriticalSections: Boolean;
var
  Id1, Id2: TThreadID;
begin
  writeln;
  writeln('--- 7. critical sections ---');
  writeln('AN OWNER AND A DEPTH, WITH NO ATOMIC ANYWHERE. Two Pascal threads ',
          'never run at the same instant here, so what a critical section ',
          'still has to do is hold one thread out while another is inside — ',
          'and each worker below gives the core away while holding it.');

  Occupant := 0;
  Overlaps := 0;
  GuardedCount := 0;
  InitCriticalSection(Section);

  Id1 := BeginThread(@SectionWorker, Pointer(PtrUInt(1)), Id1, WorkerStack);
  Id2 := BeginThread(@SectionWorker, Pointer(PtrUInt(2)), Id2, WorkerStack);
  M4_ThreadsAlive(2);
  WaitForThreadTerminate(Id1, 0);
  WaitForThreadTerminate(Id2, 0);
  M4_ThreadsAlive(0);
  CloseThread(Id1);
  CloseThread(Id2);
  DoneCriticalSection(Section);

  writeln('guarded increments = ', GuardedCount, ' (expected ',
          2 * SectionRounds, ')');
  writeln('times a worker found another inside = ', Overlaps);
  writeln('tolerance: none. one overlap is a critical section that does not ',
          'hold, and a count short of the expected one is a worker that ',
          'never got in.');

  ProveCriticalSections := (Overlaps = 0) and
                           (GuardedCount = 2 * SectionRounds);
  writeln('7. critical sections ', Verdict(ProveCriticalSections));
end;


{****************************************************************************
   8. Both event families
****************************************************************************}

function BlockedWaiter(P: Pointer): PtrInt;
begin
  RTLEventWaitFor(RTLSignal);
  RTLWorkerWokeAt := CircleElapsedMicroseconds;
  BlockedWaiter := 0;
end;


function ProveEvents: Boolean;
var
  Ev: PEventState;
  Started, Stopped: QWord;
  TimedOut, Signalled: LongInt;
  TurnsBefore, TurnsAfter: QWord;
  RTLOK, TimeoutOK, SetOK: Boolean;
  WaitedMs: QWord;
begin
  writeln;
  writeln('--- 8. both event families ---');
  writeln('AN EVENT IS A FLAG AND A QUEUE. A thread waiting with no deadline ',
          'comes off the runnable list entirely, so it costs the scheduler ',
          'nothing while it waits; a thread waiting with a deadline stays ',
          'runnable, because only the waiter knows when its deadline has come.');

  { The RTL event: a thread blocks on it with no deadline, and must take no
    turns at all until it is set. }
  RTLSignal := RTLEventCreate;
  RTLWorkerWokeAt := 0;
  IdBlocked := BeginThread(@BlockedWaiter, nil, IdBlocked, WorkerStack);
  SetThreadDebugName(IdBlocked, 'rtl-waiter');
  M4_ThreadsAlive(1);

  { Let it reach the wait, then leave it there while this thread sleeps. }
  CircleWaitMicroseconds(20000);
  TurnsBefore := CircleThreadSwitches(IdBlocked);
  CircleWaitMicroseconds(100000);
  TurnsAfter := CircleThreadSwitches(IdBlocked);

  RTLSetAt := CircleElapsedMicroseconds;
  RTLEventSetEvent(RTLSignal);
  WaitForThreadTerminate(IdBlocked, 0);
  M4_ThreadsAlive(0);
  CloseThread(IdBlocked);
  RTLEventDestroy(RTLSignal);
  RTLSignal := nil;

  RTLOK := (TurnsAfter = TurnsBefore) and (RTLWorkerWokeAt >= RTLSetAt);
  writeln('a thread blocked on an RTLEvent took ', TurnsAfter - TurnsBefore,
          ' turns during 100 ms of nothing happening (expected 0), and woke ',
          MsText(RTLWorkerWokeAt - RTLSetAt), ' after it was set.');

  { The basic event, with a deadline that runs out. }
  Ev := BasicEventCreate(nil, True, False, '');
  Started := CircleElapsedMicroseconds;
  TimedOut := BasicEventWaitFor(50, Ev);
  Stopped := CircleElapsedMicroseconds;
  WaitedMs := Stopped - Started;
  TimeoutOK := (TimedOut = wrTimeout) and (WaitedMs >= 50000) and
               (WaitedMs <= 50000 + QWord(WaitOvershootMs) * 1000);
  writeln('a 50 ms wait on an unsignalled event reported ', TimedOut,
          ' (', wrTimeout, ' is timeout) after ', MsText(WaitedMs), '.');

  { And the same event, set. }
  BasicEventSetEvent(Ev);
  Signalled := BasicEventWaitFor(50, Ev);
  SetOK := Signalled = wrSignaled;
  writeln('the same event, once set, reported ', Signalled, ' (',
          wrSignaled, ' is signalled).');
  BasicEventDestroy(Ev);

  writeln('tolerance: a wait is never short by any amount, and may overshoot ',
          'its deadline by at most ', WaitOvershootMs,
          ' ms - the scheduler''s grain is one lap of the run list, which is ',
          'microseconds.');

  ProveEvents := RTLOK and TimeoutOK and SetOK;
  writeln('8. events ', Verdict(ProveEvents));
end;


{****************************************************************************
   9. Every wait gives the core away, and is still as long as it was asked for
****************************************************************************}

function Spinner(P: Pointer): PtrInt;
begin
  while not SpinnerStop do
    begin
      Inc(SpinnerTurns);
      ThreadSwitch;
    end;
  Spinner := 0;
end;


function ProveWaitsYield: Boolean;
var
  Started, Stopped, Elapsed: QWord;
  Before, After: QWord;
  Slept: Boolean;
begin
  writeln;
  writeln('--- 9. a wait gives the core away while it waits ---');
  writeln('A WAIT THAT ONLY COUNTED TIME WOULD STOP THE GUEST MACHINE. SDL ',
          'is the only thing this machine speaks to and its audio callback ',
          'runs from whatever calls into it, so every wait in this runtime ',
          'services SDL and hands the core to another Pascal thread.');

  SpinnerTurns := 0;
  SpinnerStop := False;
  IdSpinner := BeginThread(@Spinner, nil, IdSpinner, WorkerStack);
  SetThreadDebugName(IdSpinner, 'spinner');
  M4_ThreadsAlive(1);

  { Let it get going, then measure what it does while this thread sleeps. }
  ThreadSwitch;
  Before := SpinnerTurns;
  Started := CircleElapsedMicroseconds;
  CircleWaitMicroseconds(QWord(YieldProofMs) * 1000);
  Stopped := CircleElapsedMicroseconds;
  After := SpinnerTurns;

  SpinnerStop := True;
  WaitForThreadTerminate(IdSpinner, 0);
  M4_ThreadsAlive(0);
  CloseThread(IdSpinner);

  Elapsed := Stopped - Started;
  Slept := (Elapsed >= QWord(YieldProofMs) * 1000) and
           (Elapsed <= QWord(YieldProofMs + WaitOvershootMs) * 1000);

  writeln('the main thread asked for ', YieldProofMs, ' ms and waited ',
          MsText(Elapsed), '.');
  writeln('the other thread took ', After - Before,
          ' turns during that wait.');
  writeln('tolerance: the wait is never short, may overshoot by at most ',
          WaitOvershootMs, ' ms, and the other thread must have taken turns ',
          '- one would do, and a wait that did not yield would give zero.');

  ProveWaitsYield := Slept and (After > Before);
  writeln('9. waits yield ', Verdict(ProveWaitsYield));
end;


{****************************************************************************}

var
  Passed: Boolean;
  Ok: Boolean;

begin
  writeln('M4: Pascal threads, scheduled by circle-libfpc, on the ',
          'application core.');
  writeln('Every section prints its own figures, its own tolerance and its ',
          'own verdict.');

  Passed := ProveTheMachine;
  Pace;
  if not Passed then
    begin
      writeln;
      writeln('M4: FAILED at section 1. The machine is not what the rest of ',
              'this program assumes, so nothing below it would mean ',
              'anything. END.');
      Halt(1);
    end;

  Ok := ProveTheyTakeTurns;    Passed := Ok and Passed;   Pace;
  Ok := ProveThreadVars;       Passed := Ok and Passed;   Pace;
  Ok := ProveExceptionState;   Passed := Ok and Passed;   Pace;
  Ok := ProveTheCore;          Passed := Ok and Passed;   Pace;
  Ok := ProveTheStack;         Passed := Ok and Passed;   Pace;
  Ok := ProveCriticalSections; Passed := Ok and Passed;   Pace;
  Ok := ProveEvents;           Passed := Ok and Passed;   Pace;
  Ok := ProveWaitsYield;       Passed := Ok and Passed;   Pace;

  { The threads of section 2 were joined but not closed, so that sections 5
    and 6 could still ask about them. }
  CloseThread(IdA);
  CloseThread(IdB);
  CloseThread(IdProbe);

  writeln;
  writeln('--- what this program made ---');
  writeln('threads still on the run list = ', CircleThreadCount,
          ' (the main thread, and nothing else)');
  writeln('this line is on core ', CircleCurrentCore,
          ', which is where the first line was.');

  writeln;
  if Passed then
    writeln('M4: PASS. Every section above agreed.')
  else
    writeln('M4: FAIL. Read back for the section that said so.');

  { The last thing anyone reads, wherever they are reading it. The Pascal
    program writes into one channel and knows of no other; which destinations
    that channel has was the host kernel's decision and this program cannot
    see it. }
  writeln('M4: these lines were written by Pascal on the application core, ',
          'into the one channel it has.');
  writeln('M4: END.');
end.
