unit circlefpc;

{ The one unit a circle-libfpc application uses.

  It exists because two of this target's runtime interfaces are installed at
  RUN time and are invisible to the linker, so a program that forgets either
  one links perfectly and then fails on the board.

    The memory manager. The aarch64-embedded System unit ships
    FPC_SYSTEM_MEMORYMANAGER as an all-zero record. Until something calls
    SetMemoryManager, every GetMem branches through a nil pointer -- and the
    first AnsiString assignment is a GetMem. heapmgr's initialization section
    fills the record in and hands the compiler-emitted heap block to the
    allocator.

    The thread manager. With the THREADING feature enabled the runtime links
    whether or not a thread manager exists, and until one is installed every
    threading call goes to a handler that reports a runtime error.

    The widestring manager. Nothing in this target's runtime installs it --
    rtl/embedded/system.pp has initunicodestringmanager commented out and
    rtl/embedded/sysutils.pp never calls InitInternationalGeneric -- so
    AnsiUpperCase, AnsiCompareText and every relative of theirs branch through
    a nil pointer, silently. clfstrings fills it. See docs/PACKAGES.md.

  All three are pulled in here, in that order, so the heap exists before
  anything that allocates and before anything that installs. Verify it in the
  linked image rather than trusting it: FPC_INIT_FUNC_TABLE must call
  HEAPMGR_$$_init$ before CLFTHREADS_$$_init$ and CLFSTRINGS_$$_init$.

  The rest of this unit is the console. It is deliberately small: the routines
  hand bytes to the library, which carries them off this core rather than
  writing a device -- a Pascal program here owns no hardware. Nothing here is a
  Text file; Writeln is not wired to the console yet -- see docs/CONTRACT.md. }

{$mode objfpc}

interface

uses
  heapmgr,
  clfthreads,
  clfstrings;

{ Console output. Where it comes out is the image's business, not this unit's:
  see docs/DESIGN.md. }
procedure CLFWrite(const s: shortstring);
procedure CLFWriteLn(const s: shortstring);
procedure CLFWriteLn;

{ The same for a null-terminated string, which costs no copy. }
procedure CLFWriteC(s: PChar);

{ Unsigned hexadecimal, for addresses. Sixteen digits, no prefix. }
function CLFHex(v: QWord): shortstring;

{ Signed decimal. }
function CLFInt(v: PtrInt): shortstring;

implementation

procedure clf_write(p: PChar; n: cardinal); cdecl; external name 'clf_write';
procedure clf_puts(s: PChar); cdecl; external name 'clf_puts';

const
  HexDigits: array[0..15] of char = '0123456789ABCDEF';

const
  { Written from every core, and never modified, so it needs no protection of
    any kind. }
  NewLineChar: char = #10;

{ No buffer of any sort here. A shortstring's characters are already
  contiguous, so they are handed over where they lie -- which costs no copy and,
  more to the point, leaves nothing shared for two cores to be inside at once.
  A line arrives at the log in as many pieces as it takes; the log is what
  assembles it, per core. }

procedure CLFWrite(const s: shortstring);
begin
  if Length(s) > 0 then
    clf_write(@s[1], Length(s));
end;

procedure CLFWriteLn(const s: shortstring);
begin
  if Length(s) > 0 then
    clf_write(@s[1], Length(s));
  clf_write(@NewLineChar, 1);
end;

procedure CLFWriteLn;
begin
  clf_write(@NewLineChar, 1);
end;

procedure CLFWriteC(s: PChar);
begin
  clf_puts(s);
end;

function CLFHex(v: QWord): shortstring;
var
  i: longint;
begin
  SetLength(Result, 16);
  for i := 16 downto 1 do
  begin
    Result[i] := HexDigits[v and 15];
    v := v shr 4;
  end;
end;

function CLFInt(v: PtrInt): shortstring;
var
  neg: boolean;
  u: QWord;
  buf: array[0..31] of char;
  n, i: longint;
begin
  neg := v < 0;
  if neg then
    u := QWord(-v)
  else
    u := QWord(v);

  n := 0;
  repeat
    buf[n] := HexDigits[u mod 10];
    u := u div 10;
    Inc(n);
  until u = 0;

  if neg then
  begin
    buf[n] := '-';
    Inc(n);
  end;

  SetLength(Result, n);
  for i := 1 to n do
    Result[i] := buf[n - i];
end;

end.
