unit clfstrings;

{ The third run-time installation this target needs, and the one nothing
  installs.

  Free Pascal's aarch64-embedded runtime has three records whose fields are
  function pointers filled in at RUN time, all three of which the linker is
  perfectly happy to leave empty. Two are already known: the memory manager,
  filled by heapmgr, and the thread manager, filled by clfthreads. This is the
  third.

  `widestringmanager` (rtl/inc/ustringh.inc) is what every case-folding and
  locale-aware comparison routine in SysUtils calls through. On this target it
  is a BSS record with no relocations and nothing ever writes to it:

    - rtl/embedded/system.pp ends with `initunicodestringmanager` COMMENTED
      OUT, under the very $ifdef FPC_HAS_FEATURE_WIDESTRINGS that is on for
      aarch64;
    - rtl/embedded/sysutils.pp's initialization section calls InitExceptions
      and nothing else. Ten other targets' sysutils.pp call
      InitInternationalGeneric, which is what fills the ansistring half of the
      record. This one does not.

  So every field stays nil, and each of these is a branch through address zero:

    AnsiUpperCase   AnsiLowerCase    AnsiCompareStr   AnsiCompareText
    AnsiStrComp     AnsiStrIComp     AnsiStrLComp     AnsiStrLIComp
    AnsiStrLower    AnsiStrUpper     StrCharLength

  and every WideString and UnicodeString equivalent, and Generics.Defaults'
  string comparers, and Variants' comparison. StrUtils' AnsiContainsText,
  AnsiProperCase, IsWild and StringsReplace reach them too.

  There is no fault message when it happens. It is a jump to address zero
  inside whatever called it, and a Circle kernel with no CExceptionHandler
  instance says nothing at all.

  WHAT THIS UNIT INSTALLS, said plainly: ASCII. 'a'..'z' and 'A'..'Z' fold into
  each other and every other byte is left alone. Bytes above 127 are not
  case-folded and are compared by value. Ansi and Unicode conversion widens and
  narrows a byte at a time, which is right for a single-byte code page and
  wrong for a multi-byte one.

  That is not a choice this library invented. It is what Free Pascal itself
  installs on a target with no operating system collation to ask -- the
  `Generic*` routines in rtl/objpas/sysutils/sysstr.inc, reached through
  InitInternationalGeneric. Those cannot simply be called from here: they are
  not exported, and they read UpperCaseTable and LowerCaseTable, which are
  themselves zero-filled on every target except go32v2. So the routines here
  are written out rather than forwarded, and they depend on nothing but the
  System unit.

  WHAT THIS UNIT DOES NOT GIVE YOU: a locale, a code page other than
  single-byte, or correct case folding for anything outside ASCII. If an
  application needs those, it needs a real widestring manager, and installing
  one over this one is a documented, supported thing to do -- SetWideStringManager
  is public, and a later call wins. }

{$mode objfpc}
{$H+}

interface

{ Install the manager. Called from this unit's initialization section, so
  `uses clfstrings` is the whole of the job. Calling it again is harmless. }
procedure CLFInstallStringManager;

{ What UpperAnsiStringProc held BEFORE this unit installed anything.

  Nil is the expected answer and it is the finding: it says the runtime reached
  its initialization with the record still empty. A program can print this to
  prove the trap exists on its own board rather than taking this comment's word
  for it. }
var
  CLFPriorUpperAnsiProc: pointer = nil;
  CLFPriorCompareTextProc: pointer = nil;

implementation

{ ---- the ASCII primitives ---------------------------------------------- }

function CLFUpByte(b: byte): byte; inline;
begin
  if (b >= Ord('a')) and (b <= Ord('z')) then
    Result := b - 32
  else
    Result := b;
end;

function CLFLoByte(b: byte): byte; inline;
begin
  if (b >= Ord('A')) and (b <= Ord('Z')) then
    Result := b + 32
  else
    Result := b;
end;

{ ---- ansistring case ---------------------------------------------------- }

function CLFUpperAnsi(const s: ansistring): ansistring;
var
  i, n: SizeInt;
begin
  n := Length(s);
  SetLength(Result, n);
  for i := 1 to n do
    Result[i] := AnsiChar(CLFUpByte(Byte(s[i])));
end;

function CLFLowerAnsi(const s: ansistring): ansistring;
var
  i, n: SizeInt;
begin
  n := Length(s);
  SetLength(Result, n);
  for i := 1 to n do
    Result[i] := AnsiChar(CLFLoByte(Byte(s[i])));
end;

{ ---- ansistring comparison ---------------------------------------------

  Compare by byte value, shortest-first on a common prefix, which is what
  CompareStr and CompareText do everywhere else. The result is a difference,
  not a normalised -1/0/1: callers only test its sign. }

function CLFCompareStrAnsi(const S1, S2: ansistring): PtrInt;
var
  i, l1, l2, n: SizeInt;
begin
  l1 := Length(S1);
  l2 := Length(S2);
  if l1 < l2 then n := l1 else n := l2;
  for i := 1 to n do
  begin
    Result := PtrInt(Byte(S1[i])) - PtrInt(Byte(S2[i]));
    if Result <> 0 then
      Exit;
  end;
  Result := l1 - l2;
end;

function CLFCompareTextAnsi(const S1, S2: ansistring): PtrInt;
var
  i, l1, l2, n: SizeInt;
begin
  l1 := Length(S1);
  l2 := Length(S2);
  if l1 < l2 then n := l1 else n := l2;
  for i := 1 to n do
  begin
    Result := PtrInt(CLFLoByte(Byte(S1[i]))) - PtrInt(CLFLoByte(Byte(S2[i])));
    if Result <> 0 then
      Exit;
  end;
  Result := l1 - l2;
end;

{ ---- PAnsiChar comparison -----------------------------------------------

  A nil pointer is not an error here: the runtime's own generic versions treat
  nil as ordering before anything and equal to another nil, and callers rely on
  that. }

function CLFStrCompAnsi(S1, S2: PAnsiChar): PtrInt;
begin
  if S1 = nil then
  begin
    if S2 = nil then Result := 0 else Result := -1;
    Exit;
  end;
  if S2 = nil then
  begin
    Result := 1;
    Exit;
  end;
  repeat
    Result := PtrInt(Byte(S1^)) - PtrInt(Byte(S2^));
    if (Result <> 0) or (S1^ = #0) then
      Exit;
    Inc(S1);
    Inc(S2);
  until False;
end;

function CLFStrICompAnsi(S1, S2: PAnsiChar): PtrInt;
begin
  if S1 = nil then
  begin
    if S2 = nil then Result := 0 else Result := -1;
    Exit;
  end;
  if S2 = nil then
  begin
    Result := 1;
    Exit;
  end;
  repeat
    Result := PtrInt(CLFLoByte(Byte(S1^))) - PtrInt(CLFLoByte(Byte(S2^)));
    if (Result <> 0) or (S1^ = #0) then
      Exit;
    Inc(S1);
    Inc(S2);
  until False;
end;

function CLFStrLCompAnsi(S1, S2: PAnsiChar; MaxLen: PtrUInt): PtrInt;
var
  i: PtrUInt;
begin
  Result := 0;
  if (S1 = nil) or (S2 = nil) then
  begin
    Result := CLFStrCompAnsi(S1, S2);
    Exit;
  end;
  i := 0;
  while i < MaxLen do
  begin
    Result := PtrInt(Byte(S1^)) - PtrInt(Byte(S2^));
    if (Result <> 0) or (S1^ = #0) then
      Exit;
    Inc(S1);
    Inc(S2);
    Inc(i);
  end;
end;

function CLFStrLICompAnsi(S1, S2: PAnsiChar; MaxLen: PtrUInt): PtrInt;
var
  i: PtrUInt;
begin
  Result := 0;
  if (S1 = nil) or (S2 = nil) then
  begin
    Result := CLFStrCompAnsi(S1, S2);
    Exit;
  end;
  i := 0;
  while i < MaxLen do
  begin
    Result := PtrInt(CLFLoByte(Byte(S1^))) - PtrInt(CLFLoByte(Byte(S2^)));
    if (Result <> 0) or (S1^ = #0) then
      Exit;
    Inc(S1);
    Inc(S2);
    Inc(i);
  end;
end;

{ These two case a buffer IN PLACE and return the pointer they were given,
  which is the contract StrUpper and StrLower have everywhere. }

function CLFStrUpperAnsi(Str: PAnsiChar): PAnsiChar;
var
  p: PAnsiChar;
begin
  Result := Str;
  p := Str;
  if p = nil then
    Exit;
  while p^ <> #0 do
  begin
    p^ := AnsiChar(CLFUpByte(Byte(p^)));
    Inc(p);
  end;
end;

function CLFStrLowerAnsi(Str: PAnsiChar): PAnsiChar;
var
  p: PAnsiChar;
begin
  Result := Str;
  p := Str;
  if p = nil then
    Exit;
  while p^ <> #0 do
  begin
    p^ := AnsiChar(CLFLoByte(Byte(p^)));
    Inc(p);
  end;
end;

{ ---- code point length --------------------------------------------------

  Single byte per code point. Both of these mean "this encoding is not
  multi-byte", which is the same answer DefaultCharLengthPChar gives for a
  single-byte code page. }

function CLFCharLengthPChar(const Str: PAnsiChar): PtrInt;
begin
  Result := 1;
end;

function CLFCodePointLength(const Str: PAnsiChar; MaxLookAhead: PtrInt): PtrInt;
begin
  if (MaxLookAhead <= 0) or (Str = nil) then
    Result := -1
  else if Str^ = #0 then
    Result := 0
  else
    Result := 1;
end;

{ ---- widening and narrowing ---------------------------------------------

  A byte becomes a code unit of the same value and back again; anything that
  will not fit in a byte narrows to '?'. Correct for a single-byte code page,
  and wrong for a multi-byte one -- which is why the code page argument is
  ignored rather than pretended about. }

procedure CLFAnsi2Wide(source: PAnsiChar; cp: TSystemCodePage;
  var dest: WideString; len: SizeInt);
var
  i: SizeInt;
begin
  SetLength(dest, len);
  for i := 0 to len - 1 do
    dest[i + 1] := WideChar(Byte(source[i]));
end;

procedure CLFWide2Ansi(source: PWideChar; var dest: RawByteString;
  cp: TSystemCodePage; len: SizeInt);
var
  i: SizeInt;
  w: word;
begin
  SetLength(dest, len);
  for i := 0 to len - 1 do
  begin
    w := Word(source[i]);
    if w > 255 then
      dest[i + 1] := '?'
    else
      dest[i + 1] := AnsiChar(Byte(w));
  end;
  SetCodePage(dest, cp, False);
end;

procedure CLFAnsi2Unicode(source: PAnsiChar; cp: TSystemCodePage;
  var dest: UnicodeString; len: SizeInt);
var
  i: SizeInt;
begin
  SetLength(dest, len);
  for i := 0 to len - 1 do
    dest[i + 1] := UnicodeChar(Byte(source[i]));
end;

procedure CLFUnicode2Ansi(source: PUnicodeChar; var dest: RawByteString;
  cp: TSystemCodePage; len: SizeInt);
var
  i: SizeInt;
  w: word;
begin
  SetLength(dest, len);
  for i := 0 to len - 1 do
  begin
    w := Word(source[i]);
    if w > 255 then
      dest[i + 1] := '?'
    else
      dest[i + 1] := AnsiChar(Byte(w));
  end;
  SetCodePage(dest, cp, False);
end;

{ ---- wide and unicode case and comparison -------------------------------

  ASCII again, on the low byte. Free Pascal's own initunicodestringmanager
  installs routines here that raise "unimplemented" instead; these do the
  ASCII thing rather than raise, because a raise on this target is just a
  slower way to stop, and ASCII is what the ansistring half above already
  does. }

function CLFUpperWide(const S: WideString): WideString;
var
  i: SizeInt;
begin
  Result := S;
  UniqueString(Result);
  for i := 1 to Length(Result) do
    if Word(Result[i]) < 128 then
      Result[i] := WideChar(CLFUpByte(Byte(Word(Result[i]))));
end;

function CLFLowerWide(const S: WideString): WideString;
var
  i: SizeInt;
begin
  Result := S;
  UniqueString(Result);
  for i := 1 to Length(Result) do
    if Word(Result[i]) < 128 then
      Result[i] := WideChar(CLFLoByte(Byte(Word(Result[i]))));
end;

function CLFUpperUnicode(const S: UnicodeString): UnicodeString;
var
  i: SizeInt;
begin
  Result := S;
  UniqueString(Result);
  for i := 1 to Length(Result) do
    if Word(Result[i]) < 128 then
      Result[i] := UnicodeChar(CLFUpByte(Byte(Word(Result[i]))));
end;

function CLFLowerUnicode(const S: UnicodeString): UnicodeString;
var
  i: SizeInt;
begin
  Result := S;
  UniqueString(Result);
  for i := 1 to Length(Result) do
    if Word(Result[i]) < 128 then
      Result[i] := UnicodeChar(CLFLoByte(Byte(Word(Result[i]))));
end;

function CLFFoldWord(w: word; IgnoreCase: boolean): word; inline;
begin
  if IgnoreCase and (w < 128) then
    Result := CLFLoByte(Byte(w))
  else
    Result := w;
end;

function CLFCompareWide(const s1, s2: WideString;
  Options: TCompareOptions): PtrInt;
var
  i, l1, l2, n: SizeInt;
  ic: boolean;
begin
  ic := coIgnoreCase in Options;
  l1 := Length(s1);
  l2 := Length(s2);
  if l1 < l2 then n := l1 else n := l2;
  for i := 1 to n do
  begin
    Result := PtrInt(CLFFoldWord(Word(s1[i]), ic))
            - PtrInt(CLFFoldWord(Word(s2[i]), ic));
    if Result <> 0 then
      Exit;
  end;
  Result := l1 - l2;
end;

function CLFCompareUnicode(const s1, s2: UnicodeString;
  Options: TCompareOptions): PtrInt;
var
  i, l1, l2, n: SizeInt;
  ic: boolean;
begin
  ic := coIgnoreCase in Options;
  l1 := Length(s1);
  l2 := Length(s2);
  if l1 < l2 then n := l1 else n := l2;
  for i := 1 to n do
  begin
    Result := PtrInt(CLFFoldWord(Word(s1[i]), ic))
            - PtrInt(CLFFoldWord(Word(s2[i]), ic));
    if Result <> 0 then
      Exit;
  end;
  Result := l1 - l2;
end;

function CLFGetStandardCodePage(const stdcp: TStandardCodePageEnum): TSystemCodePage;
begin
  Result := DefaultSystemCodePage;
end;

{ ---- installation ------------------------------------------------------- }

procedure CLFInstallStringManager;
var
  m: TUnicodeStringManager;
begin
  { Read what is there before overwriting it, so a program can report the trap
    rather than assert it, and so a manager somebody else installed first is
    visible in the record this one is built from. }
  GetWideStringManager(m);
  CLFPriorUpperAnsiProc := pointer(m.UpperAnsiStringProc);
  CLFPriorCompareTextProc := pointer(m.CompareTextAnsiStringProc);

  m.UpperAnsiStringProc       := @CLFUpperAnsi;
  m.LowerAnsiStringProc       := @CLFLowerAnsi;
  m.CompareStrAnsiStringProc  := @CLFCompareStrAnsi;
  m.CompareTextAnsiStringProc := @CLFCompareTextAnsi;
  m.StrCompAnsiStringProc     := @CLFStrCompAnsi;
  m.StrICompAnsiStringProc    := @CLFStrICompAnsi;
  m.StrLCompAnsiStringProc    := @CLFStrLCompAnsi;
  m.StrLICompAnsiStringProc   := @CLFStrLICompAnsi;
  m.StrUpperAnsiStringProc    := @CLFStrUpperAnsi;
  m.StrLowerAnsiStringProc    := @CLFStrLowerAnsi;

  m.CharLengthPCharProc       := @CLFCharLengthPChar;
  m.CodePointLengthProc       := @CLFCodePointLength;

  m.Ansi2WideMoveProc         := @CLFAnsi2Wide;
  m.Wide2AnsiMoveProc         := @CLFWide2Ansi;
  m.Ansi2UnicodeMoveProc      := @CLFAnsi2Unicode;
  m.Unicode2AnsiMoveProc      := @CLFUnicode2Ansi;

  m.UpperWideStringProc       := @CLFUpperWide;
  m.LowerWideStringProc       := @CLFLowerWide;
  m.UpperUnicodeStringProc    := @CLFUpperUnicode;
  m.LowerUnicodeStringProc    := @CLFLowerUnicode;
  m.CompareWideStringProc     := @CLFCompareWide;
  m.CompareUnicodeStringProc  := @CLFCompareUnicode;

  m.GetStandardCodePageProc   := @CLFGetStandardCodePage;

  { ThreadInitProc and ThreadFiniProc stay nil on purpose. rtl/inc/thread.inc
    calls both under `if assigned`, and there is no per-thread string state
    here to set up. }

  SetWideStringManager(m);
end;

initialization
  CLFInstallStringManager;

end.
