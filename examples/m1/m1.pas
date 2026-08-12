{
  m1.pas — the Pascal program that proves the heap.

  Nothing in this program calls out of the language. It builds strings and
  dynamic arrays, copies them, lets them go, and prints what happened. Where
  the memory comes from is the runtime's business, and on this target the
  runtime's TMemoryManager is Circle's allocator: a direct call, because
  memory is the one thing on this board that is not a device and Circle's own
  lock on the allocator holds across cores.

  IT ALL HAS TO BE READ OFF THE SERIAL CONSOLE. A memory manager is installed
  at run time, and a program that installs none still links cleanly, so a
  build that succeeded says nothing at all about whether this works. Every
  section below therefore ends in a verdict word — PASS or FAIL — worked out
  by the program itself. A section that faults instead of printing its verdict
  is a failure of that section, and the sections are ordered so that the last
  line printed says how far it got.

  THE REUSE SECTION IS THE ONE THAT MATTERS MOST. A heap that hands memory
  out and never takes it back looks exactly like a working one for a single
  pass, and only starts to differ when the program has been running a while.
  So that section allocates and frees hundreds of thousands of times, and asks
  two separate questions about the result.

  It asks them separately because the two available figures answer for two
  different things, and reading one for the other is a trap this example fell
  into once already. What the PROGRAM holds is counted by the memory manager
  and is exact. What the BOARD has never handed out is Circle's, shared by
  every core, and drifts under a program that is behaving perfectly. So the
  program's own balance is the leak test, with no tolerance at all, and the
  board's figure is the reuse test, read against a control stage that does the
  same work without allocating.
}
program m1;

{$mode objfpc}
{$H+}

type
  { A class, so that the exception at the end is an object the heap had to
    build. The field is there to be checked after the raise, which proves the
    object survived the trip rather than merely being caught. }
  EHeapProof = class(TObject)
  public
    Marker: LongInt;
    constructor Create(AMarker: LongInt);
  end;

  TIntArray = array of LongInt;

constructor EHeapProof.Create(AMarker: LongInt);
begin
  inherited Create;
  Marker := AMarker;
end;


{ How much of Circle's heap has never been handed out. Free Pascal asks the
  memory manager for this through GetFPCHeapStatus, and this target's manager
  answers it out of Circle's allocator.

  It is the heap's TAIL, not its free memory. Circle carves a new block off
  the tail only when its free list for that size is empty, and a freed block
  goes back on the list rather than back to the tail. So repeatedly asking for
  a size that is already on a free list does not move this at all, which is
  what makes it the measure of whether memory is REUSED.

  IT IS THE WHOLE BOARD'S, NOT THIS PROGRAM'S. There is one heap and every
  core allocates from it, and the core that owns the devices is allocating
  from it for as long as the board runs. So this number drifts down under a
  program that is doing nothing wrong, at a rate set by how long the program
  runs rather than by what it allocates. Reading it as a leak detector is a
  mistake, and the reuse section below is built so that it cannot be read that
  way: it puts a control beside it that does the same work without allocating.

  What THIS program holds is a different figure, CurrHeapUsed, counted by the
  memory manager itself. That one is exact. }
function HeapTail: PtrUInt;
begin
  HeapTail := GetFPCHeapStatus.CurrHeapFree;
end;


function Verdict(Passed: Boolean): ShortString;
begin
  if Passed then
    Verdict := 'PASS'
  else
    Verdict := 'FAIL';
end;


{****************************************************************************}

procedure ProveStrings;
var
  A, B, C: AnsiString;
  Shared, Distinct, Grew: Boolean;
  PtrA, PtrB: Pointer;
begin
  writeln;
  writeln('--- AnsiString: allocate, copy, free ---');

  { ALLOCATE. A literal assigned to an AnsiString is copied into a block from
    the heap, with a length and a reference count in front of it. Before this
    milestone this line was a call through a nil pointer. }
  A := 'the quick brown fox';
  writeln('allocated : length ', Length(A), ' = "', A, '"');

  { SHARE. Assigning one AnsiString to another does not copy: it takes a
    reference to the same block and counts it. Two variables, one block. }
  B := A;
  PtrA := Pointer(A);
  PtrB := Pointer(B);
  Shared := PtrA = PtrB;
  writeln('shared    : two variables, one block = ', Shared);

  { COPY ON WRITE. Changing one of them has to break that sharing, or the
    other would change with it. This is the generic runtime's own reference
    counting, driven by the memory manager underneath it. }
  B[5] := 'Q';
  Distinct := (Pointer(A) <> Pointer(B)) and
              (A = 'the quick brown fox') and
              (B = 'the Quick brown fox');
  writeln('copied    : A = "', A, '"');
  writeln('            B = "', B, '"');
  writeln('            copy on write kept them apart = ', Distinct);

  { GROW. Concatenation allocates a third block and copies both halves in. }
  C := A + ' jumps over ' + B;
  Grew := Length(C) = Length(A) + 12 + Length(B);
  writeln('grown     : length ', Length(C), ' = "', C, '"');

  { FREE. An empty string holds no block, and the runtime gives the block back
    when the last reference to it goes. }
  A := '';
  B := '';
  C := '';
  writeln('freed     : all three empty, pointers nil = ',
          (Pointer(A) = nil) and (Pointer(B) = nil) and (Pointer(C) = nil));

  writeln('AnsiString ', Verdict(Shared and Distinct and Grew and
                                 (Pointer(A) = nil)));
end;


{****************************************************************************}

procedure ProveDynamicArrays;
const
  N = 400;
var
  A, B: TIntArray;
  I: LongInt;
  Filled, Copied, Independent, Preserved: Boolean;
begin
  writeln;
  writeln('--- dynamic array: allocate, copy, free ---');

  { ALLOCATE. SetLength asks the memory manager for the elements plus the
    header that carries the length and the reference count. }
  SetLength(A, N);
  for I := 0 to N - 1 do
    A[I] := I * 3;
  Filled := (Length(A) = N) and (A[0] = 0) and (A[N - 1] = (N - 1) * 3);
  writeln('allocated : ', Length(A), ' elements, first ', A[0],
          ', last ', A[N - 1]);

  { COPY. Copy() builds a second array and moves the elements into it, so the
    two are separate blocks from the start. }
  B := Copy(A, 0, N);
  Copied := Length(B) = N;
  B[0] := -1;
  Independent := (A[0] = 0) and (B[0] = -1);
  writeln('copied    : ', Length(B), ' elements, independent of the first = ',
          Independent);

  { GROW. Making it longer reallocates, and everything already in it has to
    still be there afterwards. }
  SetLength(A, N * 2);
  Preserved := (Length(A) = N * 2) and (A[N - 1] = (N - 1) * 3) and
               (A[N * 2 - 1] = 0);
  writeln('grown     : ', Length(A), ' elements, old contents kept = ',
          Preserved, ', new elements zeroed = ', A[N * 2 - 1] = 0);

  { FREE. }
  SetLength(A, 0);
  SetLength(B, 0);
  writeln('freed     : lengths ', Length(A), ' and ', Length(B),
          ', pointers nil = ', (Pointer(A) = nil) and (Pointer(B) = nil));

  writeln('dynamic array ', Verdict(Filled and Copied and Independent and
                                    Preserved and (Pointer(A) = nil)));
end;


{****************************************************************************}

{ 20000 allocate-and-free cycles over 970 string sizes. }
procedure StringCycles(Count: LongInt);
var
  S: AnsiString;
  I: LongInt;
begin
  for I := 1 to Count do
    begin
      SetLength(S, 32 + (I mod 970));
      S[1] := 'x';
      S := '';
    end;
end;


{ The same, over 4000 dynamic array sizes, which reach further up Circle's
  block sizes: 64, 1024, 4096 and 16384 bytes. }
procedure ArrayCycles(Count: LongInt);
var
  A: TIntArray;
  I: LongInt;
begin
  for I := 1 to Count do
    begin
      SetLength(A, 1 + (I mod 4000));
      A[0] := I;
      SetLength(A, 0);
    end;
end;


{ THE CONTROL, and the whole reason the numbers below can be read at all.

  Identical arithmetic and identical memory traffic to ArrayCycles — the same
  count, the same sizes, the same bytes cleared — out of a single block that
  is allocated once, at the start. So it takes about as long, and it makes
  exactly one allocation instead of Count of them.

  Anything the board's heap figure does during this, it did without the Pascal
  program allocating. }
procedure ArrayTouchOnly(Count: LongInt);
var
  A: TIntArray;
  I, N: LongInt;
begin
  SetLength(A, 4000);
  for I := 1 to Count do
    begin
      N := 1 + (I mod 4000);
      FillChar(A[0], N * SizeOf(LongInt), 0);
      A[0] := I;
    end;
  SetLength(A, 0);
end;


procedure ProveReuse;
const
  Cycles = 20000;
  Runs   = 4;

  { THE BUDGET, AND WHERE THE NUMBER COMES FROM. It is not chosen to make the
    test pass.

    Circle carves a 64 byte header plus its smallest block size for anything
    it cannot serve from a free list, so the very cheapest leak possible here
    costs 128 bytes every iteration: Cycles * Runs * 128 bytes in all. The
    budget below is Cycles * Runs bytes — one hundred and twenty-eight times
    smaller than the cheapest leak that could exist, so it still catches a
    leak that happens as rarely as once in a hundred iterations, and it is
    far above the handful of blocks the core that owns the devices carves
    while this runs.

    The budget is the loose half of this test. The exact half is the balance
    below it, which has no tolerance at all. }
  TailBudget = Cycles * Runs;
var
  S: AnsiString;
  P1, P2: Pointer;
  R: LongInt;
  SameBlock, Balanced, WithinBudget: Boolean;
  Held0, Held1: PtrUInt;
  TailStart, TailNow, IdleCost, StringCost, ArrayCost: PtrUInt;
begin
  writeln;
  writeln('--- reuse: the same memory, over and over ---');

  { (1) THE SAME BLOCK COMES BACK. Allocate, free, allocate again — with
    nothing in between that could take the block first — and the second
    allocation must land on the address the first one had. That is the freed
    block coming back off Circle's free list rather than fresh memory being
    carved. }
  SetLength(S, 300);
  P1 := Pointer(S);
  S := '';
  SetLength(S, 300);
  P2 := Pointer(S);
  S := '';
  SameBlock := P1 = P2;
  writeln('same block came back = ', SameBlock,
          '  (', PtrUInt(P1), ' then ', PtrUInt(P2), ')');

  { (2) THE PROGRAM GIVES BACK EVERYTHING IT TAKES.

    This is the leak test, and it is exact. The memory manager counts what it
    hands out and what it takes back, so this figure is the program's own and
    nothing else on the board can touch it. Warm the loops once first, so that
    anything the runtime allocates on its first pass and keeps is already
    held; after that, every cycle must balance to the byte. }
  StringCycles(Cycles);
  ArrayCycles(Cycles);
  Held0 := GetFPCHeapStatus.CurrHeapUsed;

  { (3) THE BOARD'S HEAP TAIL, WITH A CONTROL BESIDE IT.

    The tail is the whole board's, not this program's: every core allocates
    from the one heap, and the core that owns the devices is allocating from
    it the entire time this runs. So the idle stage goes first and does the
    same work for the same time WITHOUT allocating. Whatever it costs is what
    the board costs, and it is the yardstick the two allocating stages are
    read against. }
  TailStart := HeapTail;
  for R := 1 to Runs do
    ArrayTouchOnly(Cycles);
  TailNow  := HeapTail;
  IdleCost := TailStart - TailNow;

  TailStart := TailNow;
  for R := 1 to Runs do
    StringCycles(Cycles);
  TailNow    := HeapTail;
  StringCost := TailStart - TailNow;

  TailStart := TailNow;
  for R := 1 to Runs do
    ArrayCycles(Cycles);
  TailNow   := HeapTail;
  ArrayCost := TailStart - TailNow;

  Held1 := GetFPCHeapStatus.CurrHeapUsed;

  writeln('bytes this program holds, before : ', Held0);
  writeln('bytes this program holds, after   : ', Held1);
  writeln('  after ', Runs * Cycles * 2, ' more cycles, balanced to the byte = ',
          Held0 = Held1);
  writeln('most it ever held at once : ',
          GetFPCHeapStatus.MaxHeapUsed, ' bytes');
  writeln('board heap tail cost, ', Runs * Cycles,
          ' cycles with NO allocation : ', IdleCost, ' bytes');
  writeln('board heap tail cost, ', Runs * Cycles,
          ' string allocate and free : ', StringCost, ' bytes');
  writeln('board heap tail cost, ', Runs * Cycles,
          ' array  allocate and free : ', ArrayCost, ' bytes');
  writeln('  budget ', TailBudget,
          ' bytes; the cheapest possible leak would cost ',
          Runs * Cycles * 128);

  Balanced     := Held0 = Held1;
  WithinBudget := (StringCost <= TailBudget) and (ArrayCost <= TailBudget);

  writeln('reuse ', Verdict(SameBlock and Balanced and WithinBudget));
end;


{****************************************************************************}

procedure ProveExceptions;
var
  Caught: Boolean;
  Marker: LongInt;
begin
  writeln;
  writeln('--- raise and catch (CLF-040) ---');

  { An exception could not be raised before there was a heap: raising one
    builds an object, and the runtime builds a record for it as well. So the
    frame walk in PushExceptObject goes live at exactly this milestone, and
    CLF-040 turns it off in the same one — the walk is bounded by a test
    against StackTop that does not hold for a stack this library allocated,
    and Free Pascal 3.2.2 returns the wrong caller from the routine the walk
    uses.

    RaiseMaxFrameCount is zero, so the walk's loop body never runs. If it had
    run, this raise is where the board would have stopped. }
  Caught := False;
  Marker := 0;
  try
    raise EHeapProof.Create(31337);
  except
    on E: EHeapProof do
      begin
        Caught := True;
        Marker := E.Marker;
      end;
  end;

  writeln('raised and caught = ', Caught, ', marker read back = ', Marker);
  writeln('exceptions ', Verdict(Caught and (Marker = 31337)));
end;


{****************************************************************************}

begin
  writeln('M1: TMemoryManager is installed, on Circle''s allocator.');
  writeln('heap tail at start: ', HeapTail, ' bytes');

  ProveStrings;
  ProveDynamicArrays;
  ProveReuse;
  ProveExceptions;

  writeln;
  writeln('heap tail at end  : ', HeapTail, ' bytes');
  writeln('M1: every section above reported its own verdict. END.');
end.
