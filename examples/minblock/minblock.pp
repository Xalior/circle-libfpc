program minblock;

{ A minimal, self-contained demonstration of a defect in Free Pascal's
  embedded heap manager on 64-bit targets.

  THE DEFECT, in one line: rtl/embedded/heapmgr.pp declares

      const MinBlock = 16;

      type THeapBlock = record
             Size:    ptruint;      { offset 0 }
             Next:    PHeapBlock;   { offset 8 }
             EndAddr: pointer;      { offset 16..23 }
           end;

  MinBlock is the smallest block the allocator will ever create. THeapBlock is
  the free-list node it writes INTO a free block. On a 32-bit target the record
  is 4+4+4 = 12 bytes and a 16-byte minimum is ample. On a 64-bit target the
  record is 24 bytes and the constant was never revisited, so

      InternalFreeMem writes 24 bytes into a block of 16,
      putting EndAddr 8 bytes past the end of it.

  Those 8 bytes land in whatever follows: the next allocation's size header, or
  its data. The heap is then quietly wrong, and the failure appears later,
  somewhere else, as a chain walk through a pointer read out of application
  data.

  Three paths create a block of exactly MinBlock, all of them ordinary:

    SysFreeMem     sz := Align(FindSize(addr)+SizeOf(pointer), 8);
                   if sz < MinBlock then sz := MinBlock;
                   -- any allocation of 8 bytes or fewer.

    SysGetMem      if (p^.Size - AllocSize >= MinBlock) then split
                   -- any split leaving exactly 16 bytes over.

    GetAlignedMem  InternalFreemem(mem, memp - mem)
                   -- the alignment gap, which is >= MinBlock and can be 16.

  This program provokes the first two deliberately, shows the eight bytes
  landing where they must not -- in memory it owns and can print -- and only
  then lets the consequence happen. It uses the System unit and nothing else:
  no packages, no threads, no second core, no image code, no file system.

  Built against a runtime whose MinBlock is at least SizeOf(THeapBlock), every
  test below reports NOT REPRODUCED and the program runs to the end. }

{$mode objfpc}
{$H-}                   { shortstring by default, so this pulls in no more of
                          the runtime than it has to }

uses
  circlefpc;

procedure clf_puts(s: PChar); cdecl; external name 'clf_puts';

var
  SayBuf: array[0..255] of char;

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

function NumStr(v: int64): shortstring;
begin
  Str(v, Result);
end;

function Hex16(v: PtrUInt): shortstring;
begin
  Result := '$' + HexStr(QWord(v), 16);
end;

{ The size heapmgr recorded for an allocation lives in the eight bytes below
  the pointer it handed out. Reading it is how this program sees the damage
  without having to crash to find it. }
function SizeHeaderOf(p: pointer): PtrUInt;
begin
  Result := PPtrUInt(p)[-1];
end;

var
  Failures: longint = 0;
  Reproduced: longint = 0;

{ ---- T1: the SysFreeMem path ------------------------------------------

  A := GetMem(8)   -> AllocSize = 16: eight bytes of header, eight usable.
  B := GetMem(64)  -> carved from the remainder, immediately after A.
  FreeMem(A)       -> Size at A-8, Next at A, EndAddr at A+8.

  A+8 is B's size header. }

procedure T1FreeSmall;
var
  a, b: pointer;
  gap, before, after: PtrUInt;
begin
  Say('');
  Say('T1: freeing an 8-byte allocation');

  a := GetMem(8);
  b := GetMem(64);
  if (a = nil) or (b = nil) then
  begin
    Say('T1 INCONCLUSIVE: an allocation failed');
    Exit;
  end;

  gap := PtrUInt(b) - PtrUInt(a);
  Say('T1   A=' + Hex16(PtrUInt(a)) + '  B=' + Hex16(PtrUInt(b))
      + '  gap=' + NumStr(gap));
  if gap <> 16 then
  begin
    Say('T1 INCONCLUSIVE: B is not immediately after A, so freeing A cannot');
    Say('T1   reach it. Nothing is claimed from this run.');
    Exit;
  end;

  before := SizeHeaderOf(b);
  Say('T1   B size header before freeing A = ' + NumStr(before) + '  (64)');
  FreeMem(a);
  after := SizeHeaderOf(b);
  Say('T1   B size header after  freeing A = ' + NumStr(after));

  if after <> before then
  begin
    Inc(Reproduced);
    Say('T1 REPRODUCED: the free wrote 8 bytes past its own 16-byte block.');
    Say('T1   value written = ' + Hex16(after));
    Say('T1   A+8           = ' + Hex16(PtrUInt(a) + 8)
        + '   <- EndAddr of A''s free node');
  end
  else
    Say('T1 NOT REPRODUCED: B''s header survived.');

  { B is leaked deliberately. A's own free node is correct -- its EndAddr
    really is A+8 -- so the free list is consistent and only B is spoiled.
    Freeing B would hand heapmgr the trampled header as a size. }
  Say('T1   B leaked on purpose; the free list itself is undamaged.');
end;

{ ---- T2: the SysGetMem split path --------------------------------------

  X := GetMem(40)  -> AllocSize = 48.
  Y := GetMem(64)  -> immediately after X.
  FreeMem(X)       -> a 48-byte free block at the head of the list.
  Z := GetMem(24)  -> AllocSize = 32, so the remainder is 48-32 = 16, which
                      is >= MinBlock and is therefore kept and freed.
                      Its EndAddr lands at X+32+16 = X+48 = Y's header. }

procedure T2SplitRemainder;
var
  x, y, z: pointer;
  gap, before, after: PtrUInt;
begin
  Say('');
  Say('T2: a split that leaves exactly 16 bytes over');

  x := GetMem(40);
  y := GetMem(64);
  if (x = nil) or (y = nil) then
  begin
    Say('T2 INCONCLUSIVE: an allocation failed');
    Exit;
  end;

  gap := PtrUInt(y) - PtrUInt(x);
  Say('T2   X=' + Hex16(PtrUInt(x)) + '  Y=' + Hex16(PtrUInt(y))
      + '  gap=' + NumStr(gap) + '  (48)');
  if gap <> 48 then
  begin
    Say('T2 INCONCLUSIVE: Y is not immediately after X. Nothing is claimed.');
    Exit;
  end;

  before := SizeHeaderOf(y);
  Say('T2   Y size header before = ' + NumStr(before) + '  (64)');

  FreeMem(x);
  z := GetMem(24);
  Say('T2   freed X, then took 24 bytes back from it: Z=' + Hex16(PtrUInt(z)));

  after := SizeHeaderOf(y);
  Say('T2   Y size header after  = ' + NumStr(after));

  if after <> before then
  begin
    Inc(Reproduced);
    Say('T2 REPRODUCED: the 16-byte remainder''s node reached 8 bytes past it.');
    Say('T2   value written = ' + Hex16(after));
    Say('T2   X+48          = ' + Hex16(PtrUInt(x) + 48));
  end
  else
    Say('T2 NOT REPRODUCED: Y''s header survived.');

  Say('T2   Y and Z leaked on purpose, for the same reason as T1.');
end;

{ ---- T3: the consequence ------------------------------------------------

  Small mixed allocations, filled with a known byte and checked back. On a
  runtime with the defect this corrupts the free list and the next walk
  dereferences the fill pattern as a chain pointer. On a corrected runtime it
  completes and reports zero.

  The fill byte is $B5 so that a fault address made of it is unmistakable in a
  serial capture: a chain node read out of this data faults at $B5B5B5B5B5B5B5C5,
  which is the pattern plus $10 -- EndAddr's offset within THeapBlock. }

const
  T3Live   = 64;
  T3Rounds = 64;
  T3Fill   = $B5;

var
  T3Seed: longword = 2463534242;

function T3Rand: longword;
begin
  T3Seed := T3Seed xor (T3Seed shl 13);
  T3Seed := T3Seed xor (T3Seed shr 17);
  T3Seed := T3Seed xor (T3Seed shl 5);
  Result := T3Seed;
end;

procedure T3Churn;
var
  p: array[0..T3Live - 1] of PByte;
  sz: array[0..T3Live - 1] of longint;
  i, j, k, r, n, bad, ops: longint;
  q: PByte;
begin
  Say('');
  Say('T3: small mixed allocations, the pattern that meets the damage');
  Say('T3   fill byte is $B5, so a fault at $B5B5B5B5B5B5B5C5 is a chain');
  Say('T3   pointer read out of this data, at EndAddr''s offset of $10.');

  for i := 0 to T3Live - 1 do
  begin
    p[i] := nil;
    sz[i] := 0;
  end;
  bad := 0;
  ops := 0;

  for r := 1 to T3Rounds do
  begin
    for k := 1 to T3Live do
    begin
      i := longint(T3Rand mod T3Live);
      if p[i] <> nil then
      begin
        q := p[i];
        for j := 0 to sz[i] - 1 do
          if q[j] <> T3Fill then
          begin
            Inc(bad);
            Break;
          end;
        FreeMem(p[i]);
        p[i] := nil;
        Continue;
      end;

      { Sizes of 8 and below are the ones SysFreeMem clamps up to MinBlock;
        the rest are there to keep splitting and coalescing busy around them. }
      case T3Rand mod 3 of
        0: n := 1 + longint(T3Rand mod 8);
        1: n := 9 + longint(T3Rand mod 56);
      else
        n := 65 + longint(T3Rand mod 960);
      end;

      p[i] := GetMem(n);
      if p[i] = nil then
      begin
        Say('T3   GetMem(' + NumStr(n) + ') returned nil, round ' + NumStr(r));
        Continue;
      end;
      sz[i] := n;
      FillChar(p[i]^, n, T3Fill);
      Inc(ops);
    end;

    if (r mod 8) = 0 then
      Say('T3   round ' + NumStr(r) + ' of ' + NumStr(T3Rounds)
          + ', ' + NumStr(ops) + ' allocations so far, corrupt=' + NumStr(bad));
  end;

  for i := 0 to T3Live - 1 do
    if p[i] <> nil then
    begin
      FreeMem(p[i]);
      p[i] := nil;
    end;

  if bad <> 0 then
    Inc(Failures);
  Say('T3 finished: ' + NumStr(ops) + ' allocations, corrupted blocks='
      + NumStr(bad));
end;

begin
  Say('');
  Say('=== heapmgr MinBlock demonstration ===');
  Say('MinBlock is 16. SizeOf(THeapBlock) on this target is '
      + NumStr(SizeOf(PtrUInt) * 3) + '.');
  Say('A free-list node written into a 16-byte block overruns it by '
      + NumStr(SizeOf(PtrUInt) * 3 - 16) + ' bytes.');

  T1FreeSmall;
  T2SplitRemainder;
  T3Churn;

  Say('');
  if (Reproduced = 0) and (Failures = 0) then
    Say('=== RESULT: not reproduced. This runtime''s MinBlock is adequate. ===')
  else
    Say('=== RESULT: reproduced in ' + NumStr(Reproduced)
        + ' of 2 targeted tests. ===');
  Say('=== MINBLOCK DEMONSTRATION COMPLETE ===');
end.
