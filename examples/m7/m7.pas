{
  m7.pas — the Pascal program that proves Free Pascal's standard library on
  this board.

  WHAT THIS ASKS FOR. M0 to M6 proved the runtime: the heap, the console,
  elapsed time, threads, files. None of that is what a program is written in.
  A program is written in DateUtils, StrUtils, IniFiles, the containers, the
  hashes, compression, JSON and XML — units that live in Free Pascal's
  packages and that had never been built for this target. This asks whether
  they run.

  A CLEAN BUILD PROVES NOTHING. CLF-012 says that about the memory manager and
  the thread manager, and the same holds for every unit here: several of them
  install something at run time that the linker never checks. The variant
  manager is one. The wide string manager another. A unit that compiles and
  then faults on its first call looks identical from the host. So every
  section below runs a KNOWN ANSWER through the unit and compares — a hash
  against its published digest, a compression round trip against the bytes
  that went in, a date arithmetic answer against one worked out by hand.
  Nothing here reports success for having called something.

  WHAT THIS PROGRAM PUTS ON THE CARD, AND WHERE. One directory of its own,
  /tmp-clf-m7, with an obviously temporary name and nowhere near the boot
  path. Everything it writes is inside that directory: an INI file, a gzip
  file, an XML file, a PNG file, four small files for the Dos unit's directory
  search to run over, and one short file that section 15 makes and removes
  again itself. IT REMOVES ALL OF THEM AND THE DIRECTORY ITSELF before it
  ends, and the host kernel then checks on its own core that the card no
  longer carries any of it.

  THE WORKING DIRECTORY IS NEVER CHANGED and every name is absolute, so
  nothing this program does depends on where the board is standing.

  EACH SECTION PRINTS ITS OWN TOLERANCE. Where the answer is a published
  constant the tolerance is none, and the section says so. Where it is not,
  the section says what it is judged against instead.
}
program m7;

{$mode objfpc}
{$H+}

uses
  { The runtime this target already had. }
  SysUtils, Classes, Math,
  { The runtime units this parcel added beside it.

    fpwidestring IS NAMED FOR ITS SIDE EFFECT AND NOTHING ELSE. Nothing below
    calls it. Its initialization is what replaces the runtime's own wide
    string manager — which is ASCII and can do nothing with an accented
    letter — and an initialization only runs for a unit something references.
    This is Free Pascal's shape everywhere: a Unix program names cwstring for
    the same reason. Section 11 is what it is here for. }
  fgl, Character, fpwidestring,
  { rtl-objpas: the Delphi compatibility units. }
  StrUtils, DateUtils, Variants,
  { The containers, from three packages that each answer the question
    differently. }
  Generics.Collections, gvector, contnrs,
  { fcl-base. }
  IniFiles,
  { hash. }
  md5, sha1, crc,
  { paszlib. }
  zstream,
  { fcl-json and fcl-xml. }
  fpjson, jsonparser, DOM, XMLRead, XMLWrite,
  { regexpr. }
  RegExpr,
  { fcl-image, which reaches paszlib for the deflate stream inside a PNG. }
  FPImage, FPWritePNG, FPReadPNG,
  { Turbo Pascal's own, which this target gained because paszlib needs it.
    Named last, so FindFirst and FindClose below mean this unit's unless they
    are written with SysUtils in front of them. }
  Dos;

const
  { Where this program works. }
  WorkDir = '/tmp-clf-m7';

  IniName  = WorkDir + '/settings.ini';
  GzName   = WorkDir + '/packed.gz';
  XmlName  = WorkDir + '/document.xml';
  PngName  = WorkDir + '/picture.png';

  { The three names section 12's Dos search must find, and the one it must
    not. }
  DosMask  = 'walk-*.dat';
  DosA     = WorkDir + '/walk-a.dat';
  DosB     = WorkDir + '/walk-b.dat';
  DosC     = WorkDir + '/walk-c.dat';
  DosOther = WorkDir + '/ignored.txt';
  DosCount = 3;

  { Section 15's file, and how far past its end that section reads. The file
    is small and the distance is far larger than it, so a length that grew is
    unmistakable. }
  EofName    = WorkDir + '/short.bin';
  EofBytes   = 256;
  EofBeyond  = 4096;

  { The pause between sections. The log channel never blocks and drops a line
    it has no room for, and the console is far slower than this core, so a
    program that prints a long burst can outrun the wire and lose the middle
    of its own report. }
  PaceMillis = 200;

  { PUBLISHED DIGESTS, NOT DIGESTS THIS PROGRAM WORKED OUT. Every one of these
    is from the algorithm's own specification, so a unit that compiles and
    computes something plausible is still caught.

    MD5 and SHA-1 of "abc" are the second test vector of RFC 1321 and of
    FIPS 180-1. The CRC-32 of "123456789" is the check value every CRC
    catalogue lists for CRC-32/ISO-HDLC. }
  HashInput    = 'abc';
  Md5OfAbc     = '900150983CD24FB0D6963F7D28E17F72';
  Sha1OfAbc    = 'A9993E364706816ABA3E25717850C26C9CD0D89D';
  CrcInput     = '123456789';
  Crc32OfCheck = LongWord($CBF43926);

  { Section 7's payload. Long enough that a compressor has something to find,
    and repetitive enough that a round trip which quietly dropped a block
    would come back the wrong length. }
  PackedRepeats = 400;

  { Section 13's picture. Small enough to fit anywhere and big enough that a
    PNG of it carries more than one filter row. }
  PngWidth  = 48;
  PngHeight = 32;

type
  { Section 5's three containers, one from each package. }
  TIntList = specialize TFPGList<LongInt>;
  TNameMap = specialize TDictionary<string, LongInt>;
  TIntVec  = specialize TVector<LongInt>;

var
  { Every section's verdict, gathered so the last lines can name what failed
    rather than only that something did. }
  Failures : string = '';


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


procedure Pace;
begin
  Sleep(PaceMillis);
end;


{ How many bytes a name takes on the card, asked of the card rather than
  remembered from the write. -1 when the name is not there. }
function SizeOnCard(const Name: string): Int64;
var
  F : TFileStream;
begin
  SizeOnCard := -1;
  try
    F := TFileStream.Create(Name, fmOpenRead or fmShareDenyNone);
    try
      SizeOnCard := F.Size;
    finally
      F.Free;
    end;
  except
    on E: Exception do
      SizeOnCard := -1;
  end;
end;


{ Section 5's ordering, which fgl's own sort is handed. }
function CompareInts(const A, B: LongInt): LongInt;
begin
  if A < B then
    CompareInts := -1
  else if A > B then
    CompareInts := 1
  else
    CompareInts := 0;
end;


{ One section's result, printed and remembered. }
procedure Report(const Title: string; Good: Boolean);
begin
  writeln(Title, ' ', Verdict(Good));
  if not Good then
    Failures := Failures + ' [' + Title + ']';
end;


{ The payload section 7 compresses and section 7 checks came back. Built
  rather than written out so that its length is stated once. }
function PackedPayload: string;
var
  I : LongInt;
  S : string;
begin
  S := '';
  for I := 1 to PackedRepeats do
    S := S + 'line ' + IntToStr(I) + ': the quick brown fox jumps over the lazy dog.'#10;
  PackedPayload := S;
end;


{****************************************************************************
  1. The directory this run works in.
****************************************************************************}

function ProveTheDirectory: Boolean;
var
  There : Boolean;
begin
  writeln;
  writeln('--- 1. the directory this run works in ---');
  writeln('this program runs on core ', CircleCurrentCore,
          ', which owns no device. Every file it opens goes through ',
          'circle-libsdl2''s file service, as M5 and M6 proved, and this ',
          'run adds nothing to that route.');

  There := DirectoryExists(WorkDir);
  if not There then
    begin
      CreateDir(WorkDir);
      There := DirectoryExists(WorkDir);
    end;

  writeln('DirectoryExists(', WorkDir, ') says the directory is there: ',
          YesNo(There), '.');
  writeln('tolerance: the directory must exist after this. An earlier run ',
          'that ended badly may have left it, which is why an existing one ',
          'is not a failure. Sections 7 to 13 write inside it and section 14 ',
          'removes all of it.');

  Report('1. the directory this run works in', There);
  ProveTheDirectory := There;
end;


{****************************************************************************
  2. StrUtils.
****************************************************************************}

function ProveStrUtils: Boolean;
var
  Good : Boolean;
  Replaced, Padded, Reversed, Third, Doubled : string;
  Where, Words : LongInt;
  Starts : Boolean;
begin
  writeln;
  writeln('--- 2. StrUtils ---');
  Good := True;
  Replaced := ''; Padded := ''; Reversed := ''; Third := ''; Doubled := '';
  Where := -1; Words := -1; Starts := False;

  try
    Replaced := StringsReplace('one two one two',
                               ['one', 'two'], ['1', '2'], [rfReplaceAll]);
    Padded   := AddChar('.', 'end', 8);
    Reversed := ReverseString('circlesdl2');
    Where    := PosEx('lo', 'hello hello', 5);
    Words    := WordCount('a,b,c,d', [',']);
    Third    := ExtractWord(3, 'a,b,c,d', [',']);
    Doubled  := DupeString('ab', 3);
    Starts   := AnsiStartsStr('circle', 'circle-libfpc');
  except
    on E: Exception do
      begin
        writeln('  ', E.ClassName, ': ', E.Message);
        Good := False;
      end;
  end;

  writeln('StringsReplace gave "', Replaced, '" (want "1 2 1 2").');
  writeln('AddChar padded to "', Padded, '" (want ".....end"), ',
          'ReverseString gave "', Reversed, '" (want "2ldselcric").');
  writeln('PosEx found "lo" at ', Where, ' (want 10); WordCount counted ',
          Words, ' words (want 4) and the third is "', Third, '" (want c).');
  writeln('DupeString gave "', Doubled, '" (want "ababab"); AnsiStartsStr ',
          'says "circle-libfpc" starts with "circle": ', YesNo(Starts), '.');
  writeln('tolerance: none. Every answer above is fixed by the routine''s ',
          'own definition, and one wrong answer fails this section.');

  Good := Good and (Replaced = '1 2 1 2') and (Padded = '.....end') and
          (Reversed = '2ldselcric') and (Where = 10) and (Words = 4) and
          (Third = 'c') and (Doubled = 'ababab') and Starts;
  Report('2. StrUtils', Good);
  ProveStrUtils := Good;
end;


{****************************************************************************
  3. DateUtils.
****************************************************************************}

function ProveDateUtils: Boolean;
var
  Good : Boolean;
  D, Later, Back : TDateTime;
  Days, Months, ExactMonths : LongInt;
  Unix, UnixBack : Int64;
  Leap, NotLeap : Boolean;
  WeekDay : Word;
  LaterText : string;
begin
  writeln;
  writeln('--- 3. DateUtils ---');
  Good := True;
  Days := -1; Months := -1; Unix := -1; UnixBack := -1; WeekDay := 0;

  try
    { A date this program chose, so nothing here depends on the board's own
      clock — which is not the real date and is section 6 of M6's business. }
    D := EncodeDateTime(2000, 1, 1, 12, 0, 0, 0);
    Later := IncMonth(D, 14);
    LaterText := FormatDateTime('yyyy-mm-dd', Later);
    Days := DaysBetween(D, EncodeDateTime(2000, 3, 1, 12, 0, 0, 0));
    { TWO ANSWERS, AND BOTH ARE RIGHT. MonthsBetween's AExact parameter
      defaults to False, and that form is deliberately approximate: dateutil.inc
      computes Trunc(days / ApproxDaysPerMonth) with ApproxDaysPerMonth =
      30.4375. The 425 days from 2000-01-01 to 2001-03-01 divide to 13.96, so
      the approximate answer is 13 and not 14. Passing True instead walks the
      calendar through PeriodBetween and answers 1 year 2 months, which is 14.
      Both are checked, because a program that read 13 as a defect would be
      wrong and a program that expected 14 from the default would be wrong
      too. }
    Months := MonthsBetween(D, Later);
    ExactMonths := MonthsBetween(D, Later, True);
    Unix := DateTimeToUnix(D);
    Back := UnixToDateTime(Unix);
    UnixBack := DateTimeToUnix(Back);
    Leap := IsLeapYear(2000);
    NotLeap := not IsLeapYear(1900);
    WeekDay := DayOfTheWeek(EncodeDate(2000, 1, 1));
  except
    on E: Exception do
      begin
        writeln('  ', E.ClassName, ': ', E.Message);
        Good := False;
        Leap := False; NotLeap := False; LaterText := '';
      end;
  end;

  writeln('from 2000-01-01, IncMonth by 14 gives ', LaterText,
          ' (want 2001-03-01).');
  writeln('MonthsBetween over those 425 days says ', Months,
          ' (want 13: the default form divides by 30.4375 days and truncates)',
          ' and ', ExactMonths,
          ' when asked for the exact one (want 14: 1 year and 2 months).');
  writeln('DaysBetween 2000-01-01 and 2000-03-01 is ', Days,
          ' (want 60, because 2000 is a leap year).');
  writeln('DateTimeToUnix gives ', Unix,
          ' (want 946728000) and the round trip back gives ', UnixBack, '.');
  writeln('2000 is a leap year: ', YesNo(Leap),
          '; 1900 is not: ', YesNo(NotLeap),
          '; 2000-01-01 is day ', WeekDay, ' of the week (want 6, Saturday).');
  writeln('tolerance: none. Every figure above is a property of the calendar ',
          'and of DateUtils'' own definitions, not of this board. The two ',
          'month counts differ on every Free Pascal target and neither is a ',
          'fault.');

  Good := Good and (LaterText = '2001-03-01') and (Months = 13) and
          (ExactMonths = 14) and
          (Days = 60) and (Unix = 946728000) and (UnixBack = Unix) and
          Leap and NotLeap and (WeekDay = 6);
  Report('3. DateUtils', Good);
  ProveDateUtils := Good;
end;


{****************************************************************************
  4. Variants, and the manager behind them.
****************************************************************************}

function ProveVariants: Boolean;
{
  THE VARIANT MANAGER IS INSTALLED AT RUN TIME, exactly as the memory manager
  and the thread manager are, and a program that links cleanly still has one
  that does nothing until the Variants unit's initialization has run. That is
  CLF-012's shape, so this section is the check: without the manager, the
  first arithmetic on a variant faults rather than reporting anything.

  BOTH CONSTANTS ARE WRITTEN WITH THEIR UNIT IN FRONT OF THEM. Variants
  exports Null and Unassigned as functions, and a local variable of the same
  name hides one without a word from the compiler: the assignment still
  compiles, because anything at all converts to a Variant. Naming the unit
  makes that impossible to do by accident.
}
var
  Good : Boolean;
  A, B, C : Variant;
  Sum : Double;
  Text : string;
  WasEmpty, WasNull, WasUnassigned : Boolean;
  Kind : LongInt;
begin
  writeln;
  writeln('--- 4. Variants ---');
  Good := True;
  Sum := 0; Text := ''; Kind := -1;
  WasEmpty := False; WasNull := False; WasUnassigned := False;

  try
    A := 21;
    B := 1.5;
    C := A * B;
    Sum := Double(C);
    Kind := VarType(C) and varTypeMask;

    A := 'the answer is ';
    B := 42;
    Text := A + VarToStr(B);

    VarClear(A);
    WasEmpty := VarIsEmpty(A);

    A := Variants.Null;
    WasNull := VarIsNull(A) and (VarType(A) = varNull);

    A := Variants.Unassigned;
    WasUnassigned := VarIsEmpty(A) and (VarType(A) = varEmpty);
  except
    on E: Exception do
      begin
        writeln('  ', E.ClassName, ': ', E.Message);
        Good := False;
      end;
  end;

  writeln('21 * 1.5 through variants gives ', Sum:0:3,
          ' (want 31.500), and its type code is ', Kind,
          ' (want ', varDouble, ', varDouble).');
  writeln('a string variant joined to an integer one gives "', Text,
          '" (want "the answer is 42").');
  writeln('VarClear leaves it empty: ', YesNo(WasEmpty),
          '; assigning Variants.Null leaves it null, type code ', varNull,
          ': ', YesNo(WasNull),
          '; assigning Variants.Unassigned leaves it empty, type code ',
          varEmpty, ': ', YesNo(WasUnassigned), '.');
  writeln('tolerance: none, and reaching the end of this section at all is ',
          'half of what it proves: the variant manager is installed at run ',
          'time and a missing one faults on the first line above rather ',
          'than reporting anything.');

  Good := Good and (Abs(Sum - 31.5) < 1E-9) and (Kind = varDouble) and
          (Text = 'the answer is 42') and WasEmpty and WasNull and
          WasUnassigned;
  Report('4. Variants', Good);
  ProveVariants := Good;
end;


{****************************************************************************
  5. The containers, from three packages.
****************************************************************************}

function ProveContainers: Boolean;
var
  Good, FglOk, GenOk, StlOk, HashOk : Boolean;
  L : TIntList;
  M : TNameMap;
  V : TIntVec;
  H : TFPHashList;
  I, Total : LongInt;
  Got : LongInt;
  Name : string;
begin
  writeln;
  writeln('--- 5. containers: fgl, Generics.Collections, fcl-stl, contnrs ---');
  Good := True;
  FglOk := False; GenOk := False; StlOk := False; HashOk := False;

  try
    { fgl, out of the runtime library itself. Filled backwards and sorted, so
      a comparer that is never called is caught. }
    L := TIntList.Create;
    try
      for I := 100 downto 1 do
        L.Add(I);
      L.Sort(@CompareInts);
      FglOk := (L.Count = 100) and (L[0] = 1) and (L[99] = 100);
    finally
      L.Free;
    end;

    { Generics.Collections, out of rtl-generics. A dictionary keyed by string,
      which exercises the default comparer and the hashes under it. }
    M := TNameMap.Create;
    try
      for I := 1 to 100 do
        M.Add('key' + IntToStr(I), I * I);
      GenOk := (M.Count = 100) and M.TryGetValue('key7', Got) and (Got = 49)
               and not M.ContainsKey('key101');
    finally
      M.Free;
    end;

    { fcl-stl, out of fcl-stl. A vector, grown well past its first
      allocation. }
    V := TIntVec.Create;
    try
      for I := 0 to 999 do
        V.PushBack(I * 3);
      Total := 0;
      for I := 0 to V.Size - 1 do
        Total := Total + V[I];
      StlOk := (V.Size = 1000) and (V[999] = 2997) and (Total = 1498500);
    finally
      V.Free;
    end;

    { contnrs, out of fcl-base. A hash list, which is what a real program
      reaches for to look a name up. }
    H := TFPHashList.Create;
    try
      for I := 1 to 50 do
        begin
          Name := 'n' + IntToStr(I);
          H.Add(Name, Pointer(PtrUInt(I * 7)));
        end;
      HashOk := (H.Count = 50) and
                (PtrUInt(H.Find('n33')) = 231) and
                (H.Find('n51') = nil);
    finally
      H.Free;
    end;
  except
    on E: Exception do
      begin
        writeln('  ', E.ClassName, ': ', E.Message);
        Good := False;
      end;
  end;

  writeln('fgl TFPGList of 100, filled backwards then sorted: ', YesNo(FglOk),
          '.');
  writeln('Generics.Collections TDictionary of 100 string keys, looked up ',
          'and asked for one that is not there: ', YesNo(GenOk), '.');
  writeln('fcl-stl TVector grown to 1000 and summed: ', YesNo(StlOk), '.');
  writeln('contnrs TFPHashList of 50 names, found and not found: ',
          YesNo(HashOk), '.');
  writeln('tolerance: none. Each container is filled with values this ',
          'program can work out again, and every count, every lookup and the ',
          'sum are checked against them. A container that allocated and ',
          'stored nothing would answer a count and fail the values.');

  Good := Good and FglOk and GenOk and StlOk and HashOk;
  Report('5. containers', Good);
  ProveContainers := Good;
end;


{****************************************************************************
  6. Hashes, against published digests.
****************************************************************************}

function ProveHashes: Boolean;
var
  Good, Md5Ok, Sha1Ok, CrcOk : Boolean;
  GotMd5, GotSha1, Subject : string;
  GotCrc : LongWord;
begin
  writeln;
  writeln('--- 6. MD5, SHA-1 and CRC-32 ---');
  Good := True;
  GotMd5 := ''; GotSha1 := ''; GotCrc := 0;
  Subject := CrcInput;

  try
    GotMd5  := UpperCase(MD5Print(MD5String(HashInput)));
    GotSha1 := UpperCase(SHA1Print(SHA1String(HashInput)));
    GotCrc  := crc32(0, PByte(PAnsiChar(Subject)), Length(Subject));
  except
    on E: Exception do
      begin
        writeln('  ', E.ClassName, ': ', E.Message);
        Good := False;
      end;
  end;

  Md5Ok := GotMd5 = Md5OfAbc;
  Sha1Ok := GotSha1 = Sha1OfAbc;
  CrcOk := GotCrc = Crc32OfCheck;

  writeln('MD5("', HashInput, '")  = ', GotMd5);
  writeln('             RFC 1321 = ', Md5OfAbc, '  ', Verdict(Md5Ok));
  writeln('SHA1("', HashInput, '") = ', GotSha1);
  writeln('          FIPS 180-1 = ', Sha1OfAbc, '  ', Verdict(Sha1Ok));
  writeln('CRC32("', CrcInput, '") = ', HexStr(GotCrc, 8),
          ', the catalogue check value = ', HexStr(Crc32OfCheck, 8), '  ',
          Verdict(CrcOk));
  writeln('tolerance: none, and these are the strongest lines in the whole ',
          'report: the three answers are published constants, so a unit that ',
          'compiled and then computed anything at all wrong is caught here.');

  Good := Good and Md5Ok and Sha1Ok and CrcOk;
  Report('6. MD5, SHA-1 and CRC-32', Good);
  ProveHashes := Good;
end;


{****************************************************************************
  7. Compression, in memory and on the card.
****************************************************************************}

function ProveCompression: Boolean;
var
  Good, MemOk, GzOk : Boolean;
  Payload, Came : string;
  Packed_ : TMemoryStream;
  Comp : Tcompressionstream;
  Decomp : Tdecompressionstream;
  Gz : TGZFileStream;
  RawLen, PackedLen, GzLen : Int64;
  Got : LongInt;
begin
  writeln;
  writeln('--- 7. compression: paszlib in memory and a gzip file on the card ---');
  Good := True;
  MemOk := False; GzOk := False;
  PackedLen := -1; GzLen := -1;

  Payload := PackedPayload;
  RawLen := Length(Payload);

  try
    { In memory: deflate into a stream and inflate out of it again. }
    Packed_ := TMemoryStream.Create;
    try
      Comp := Tcompressionstream.create(cldefault, Packed_);
      try
        Comp.write(Payload[1], RawLen);
      finally
        Comp.Free;
      end;
      PackedLen := Packed_.Size;

      Packed_.Position := 0;
      SetLength(Came, RawLen);
      Decomp := Tdecompressionstream.create(Packed_);
      try
        Got := Decomp.read(Came[1], RawLen);
      finally
        Decomp.Free;
      end;
      MemOk := (Got = RawLen) and (Came = Payload) and (PackedLen < RawLen);
    finally
      Packed_.Free;
    end;

    { ON THE CARD, THROUGH THE UNIT THAT NEEDED THE DOS UNIT. TGZFileStream is
      gzio underneath, and gzio asks GetFAttr whether the file is there before
      it decides to create or to open — which is the one call that stopped
      paszlib building for this target until Dos existed. }
    Gz := TGZFileStream.create(GzName, gzopenwrite);
    try
      Gz.write(Payload[1], RawLen);
    finally
      Gz.Free;
    end;
    GzLen := SizeOnCard(GzName);

    SetLength(Came, RawLen);
    Gz := TGZFileStream.create(GzName, gzopenread);
    try
      Got := Gz.read(Came[1], RawLen);
    finally
      Gz.Free;
    end;
    GzOk := (Got = RawLen) and (Came = Payload) and (GzLen > 0) and
            (GzLen < RawLen);
  except
    on E: Exception do
      begin
        writeln('  ', E.ClassName, ': ', E.Message);
        Good := False;
      end;
  end;

  writeln(RawLen, ' bytes of text deflated to ', PackedLen,
          ' in memory and inflated back byte for byte: ', YesNo(MemOk), '.');
  writeln('the same text written to ', GzName, ' as gzip is ', GzLen,
          ' bytes on the card and read back byte for byte: ', YesNo(GzOk),
          '.');
  writeln('tolerance: the round trip must be exact — every byte back as it ',
          'went in, and the same length. The packed size is only required to ',
          'be smaller than the text, because how much smaller is the ',
          'compressor''s business and not this board''s.');

  Good := Good and MemOk and GzOk;
  Report('7. compression', Good);
  ProveCompression := Good;
end;


{****************************************************************************
  8. IniFiles on the card.
****************************************************************************}

function ProveIniFiles: Boolean;
var
  Good : Boolean;
  Ini : TIniFile;
  Sections : TStringList;
  GotName : string;
  GotPort, GotMissing : LongInt;
  GotFlag : Boolean;
  SectionOk : Boolean;
begin
  writeln;
  writeln('--- 8. IniFiles ---');
  Good := True;
  GotName := ''; GotPort := -1; GotMissing := -1; GotFlag := False;
  SectionOk := False;

  try
    { Written by one object and read back by another, so nothing of the write
      survives into the read except what is on the card. }
    Ini := TIniFile.Create(IniName);
    try
      Ini.WriteString('board', 'name', 'raspberry pi 5');
      Ini.WriteInteger('board', 'port', 115200);
      Ini.WriteBool('board', 'headless', True);
      Ini.WriteString('paths', 'work', WorkDir);
      Ini.UpdateFile;
    finally
      Ini.Free;
    end;

    Ini := TIniFile.Create(IniName);
    try
      GotName := Ini.ReadString('board', 'name', '');
      GotPort := Ini.ReadInteger('board', 'port', -1);
      GotFlag := Ini.ReadBool('board', 'headless', False);
      GotMissing := Ini.ReadInteger('board', 'nothing-here', -7);
      Sections := TStringList.Create;
      try
        Ini.ReadSections(Sections);
        SectionOk := (Sections.IndexOf('board') >= 0) and
                     (Sections.IndexOf('paths') >= 0) and
                     (Sections.Count = 2);
      finally
        Sections.Free;
      end;
    finally
      Ini.Free;
    end;
  except
    on E: Exception do
      begin
        writeln('  ', E.ClassName, ': ', E.Message);
        Good := False;
      end;
  end;

  writeln('wrote ', IniName, ' and read it back with a second object: ',
          'name "', GotName, '", port ', GotPort, ', headless ',
          YesNo(GotFlag), '.');
  writeln('a key that was never written came back as its default: ',
          GotMissing, ' (want -7).');
  writeln('the two sections written are the two sections found: ',
          YesNo(SectionOk), '.');
  writeln('tolerance: none. Every value must come back exactly as it was ',
          'written, the missing key must give the default rather than an ',
          'invented value, and there must be no third section.');

  Good := Good and (GotName = 'raspberry pi 5') and (GotPort = 115200) and
          GotFlag and (GotMissing = -7) and SectionOk;
  Report('8. IniFiles', Good);
  ProveIniFiles := Good;
end;


{****************************************************************************
  9. JSON.
****************************************************************************}

function ProveJson: Boolean;
var
  Good : Boolean;
  Doc : TJSONData;
  Obj : TJSONObject;
  Arr : TJSONArray;
  Text, Again : string;
  GotName : string;
  GotCores, GotThird : LongInt;
  GotSpeed : Double;
  RoundTrip : Boolean;
begin
  writeln;
  writeln('--- 9. JSON, through fcl-json ---');
  Good := True;
  GotName := ''; GotCores := -1; GotThird := -1; GotSpeed := 0;
  RoundTrip := False;

  try
    Text := '{"board":"rpi5","cores":4,"speed":2.4,"list":[10,20,30]}';
    Doc := GetJSON(Text);
    try
      Obj := Doc as TJSONObject;
      GotName := Obj.Get('board', '');
      GotCores := Obj.Get('cores', -1);
      GotSpeed := Obj.Get('speed', 0.0);
      Arr := Obj.Arrays['list'];
      GotThird := Arr.Integers[2];

      { Formatted out and parsed again, so the writer and the reader are
        checked against each other rather than against a string this program
        typed. }
      Again := Obj.AsJSON;
    finally
      Doc.Free;
    end;

    Doc := GetJSON(Again);
    try
      RoundTrip := (TJSONObject(Doc).Get('cores', -1) = 4) and
                   (TJSONObject(Doc).Get('board', '') = 'rpi5');
    finally
      Doc.Free;
    end;
  except
    on E: Exception do
      begin
        writeln('  ', E.ClassName, ': ', E.Message);
        Good := False;
      end;
  end;

  writeln('parsed board "', GotName, '" (want rpi5), cores ', GotCores,
          ' (want 4), speed ', GotSpeed:0:1, ' (want 2.4).');
  writeln('the third element of the array is ', GotThird, ' (want 30).');
  writeln('formatted back out and parsed again, the same values come out: ',
          YesNo(RoundTrip), '.');
  writeln('tolerance: none. The document is a constant in this program, so ',
          'every value above is known before the parser runs.');

  Good := Good and (GotName = 'rpi5') and (GotCores = 4) and
          (Abs(GotSpeed - 2.4) < 1E-9) and (GotThird = 30) and RoundTrip;
  Report('9. JSON', Good);
  ProveJson := Good;
end;


{****************************************************************************
  10. XML, written to the card and read back.
****************************************************************************}

function ProveXml: Boolean;
var
  Good : Boolean;
  Doc : TXMLDocument;
  Root, Child : TDOMElement;
  I : LongInt;
  GotRoot, GotAttr : string;
  GotChildren : LongInt;
  GotThird : string;
begin
  writeln;
  writeln('--- 10. XML, through fcl-xml ---');
  Good := True;
  GotRoot := ''; GotAttr := ''; GotChildren := -1; GotThird := '';

  try
    Doc := TXMLDocument.Create;
    try
      Root := Doc.CreateElement('milestone');
      Root.SetAttribute('name', 'm7');
      Doc.AppendChild(Root);
      for I := 1 to 5 do
        begin
          Child := Doc.CreateElement('unit');
          Child.SetAttribute('index', UnicodeString(IntToStr(I)));
          Child.AppendChild(Doc.CreateTextNode(
            UnicodeString('unit number ' + IntToStr(I))));
          Root.AppendChild(Child);
        end;
      WriteXMLFile(Doc, XmlName);
    finally
      Doc.Free;
    end;

    { Read back off the card by a different object, so the file is what
      carries the answer. }
    ReadXMLFile(Doc, XmlName);
    try
      GotRoot := AnsiString(Doc.DocumentElement.NodeName);
      GotAttr := AnsiString(Doc.DocumentElement.GetAttribute('name'));
      GotChildren := Doc.DocumentElement.GetElementsByTagName('unit').Count;
      GotThird := AnsiString(Doc.DocumentElement.GetElementsByTagName('unit')
                     .Item[2].TextContent);
    finally
      Doc.Free;
    end;
  except
    on E: Exception do
      begin
        writeln('  ', E.ClassName, ': ', E.Message);
        Good := False;
      end;
  end;

  writeln('wrote ', XmlName, ' and read it back: root element "', GotRoot,
          '" (want milestone), its name attribute "', GotAttr,
          '" (want m7).');
  writeln('it holds ', GotChildren, ' unit elements (want 5), and the third ',
          'one reads "', GotThird, '" (want "unit number 3").');
  writeln('tolerance: none, and the file on the card is what is being ',
          'judged: the document is built by one object, written out, and ',
          'read back by another that never saw the first.');

  Good := Good and (GotRoot = 'milestone') and (GotAttr = 'm7') and
          (GotChildren = 5) and (GotThird = 'unit number 3');
  Report('10. XML', Good);
  ProveXml := Good;
end;


{****************************************************************************
  11. Unicode: the wide string manager, the character tables, UTF-8.
****************************************************************************}

function ProveUnicode: Boolean;
{
  TWO ROUTINES, AND ONLY ONE OF THEM ASKS THE WIDE STRING MANAGER. That is
  the whole of this section, and getting it wrong once is what it now guards
  against.

  SysUtils.UpperCase is ASCII BY DEFINITION, on every Free Pascal target, with
  a manager installed or without one. Its UnicodeString form is
  InternalChangeCase(S,['a'..'z'],-32) in rtl/objpas/sysutils/sysuni.inc, and
  its own comment there says so: it converts the characters from a to z and
  nothing else. Handed an accented letter it returns that letter unchanged.
  That is correct, it is not a fallback, and it is not evidence of anything
  being missing.

  SysUtils.UnicodeUpperCase is the one that asks. It is
  widestringmanager.UpperUnicodeStringProc(s), one line in the same file, and
  the manager behind that pointer is what a program elects.

  WHAT THE RUNTIME PUTS THERE UNTIL A PROGRAM ELECTS ONE IS NOT AN ASCII
  FALLBACK EITHER. initunicodestringmanager, in the generic runtime every
  target shares, points it at StubUnicodeCase, which writes
  "This binary has no string conversion support compiled in." to standard
  error and halts with runtime error 234. So a program that calls
  UnicodeUpperCase without electing a manager stops, loudly, naming its own
  cure — it does not quietly hand back what it was given.

  THIS TARGET HAS NO OPERATING SYSTEM TO ELECT ONE FROM, so the answer is
  fpwidestring: pure Pascal over the same Unicode tables the Character unit
  reads, installing itself in its initialization, which runs only because this
  program names the unit in its uses clause. A Unix program names cwstring for
  exactly the same reason.

  So this section checks BOTH routines against the SAME input. UpperCase must
  leave the two accented letters alone; UnicodeUpperCase must case all three.
  A section that checked only one of them could pass while the other was
  wrong, which is how the first version of this test blamed the target for
  Free Pascal's own definition of UpperCase.
}
var
  Good, AsciiOk, CaseOk, RoundOk, TableOk, Utf8Ok : Boolean;
  Wide, Ascii, Upper, Round_ : UnicodeString;
  Utf8 : string;
begin
  writeln;
  writeln('--- 11. Unicode: fpwidestring, unicodedata and Character ---');
  Good := True;
  AsciiOk := False; CaseOk := False; RoundOk := False;
  TableOk := False; Utf8Ok := False;

  try
    { Latin small letter e with acute, and Greek small alpha. Neither is in
      a..z, so the two routines below must answer differently about them. }
    Wide := UnicodeString(#$00E9) + UnicodeString(#$03B1) + 'z';

    { The ASCII routine. Only the z may move. }
    Ascii := UpperCase(Wide);
    AsciiOk := (Ascii[1] = WideChar($00E9)) and (Ascii[2] = WideChar($03B1))
               and (Ascii[3] = 'Z');

    { The routine that asks the manager. All three must move. }
    Upper := UnicodeUpperCase(Wide);
    CaseOk := (Upper[1] = WideChar($00C9)) and (Upper[2] = WideChar($0391))
              and (Upper[3] = 'Z');

    { And back down again, which catches a table read in one direction only. }
    Round_ := UnicodeLowerCase(Upper);
    RoundOk := Round_ = Wide;

    { The character tables, through the Character unit. }
    TableOk := TCharacter.IsLetter(WideChar($00E9)) and
               TCharacter.IsDigit('7') and
               (not TCharacter.IsLetter('7')) and
               TCharacter.IsUpper(WideChar($0391)) and
               (TCharacter.ToLower(WideChar($0391)) = WideChar($03B1));

    { UTF-8 out and back. The accented letter is two bytes and the Greek
      letter two more, so a conversion that only handled ASCII produces the
      wrong length before it produces the wrong text. }
    Utf8 := UTF8Encode(Wide);
    Utf8Ok := (Length(Utf8) = 5) and (UTF8Decode(Utf8) = Wide);
  except
    on E: Exception do
      begin
        writeln('  ', E.ClassName, ': ', E.Message);
        Good := False;
      end;
  end;

  writeln('UpperCase, which is ASCII by definition, turned U+00E9 U+03B1 z ',
          'into U+', HexStr(Ord(Ascii[1]), 4), ' U+', HexStr(Ord(Ascii[2]), 4),
          ' U+', HexStr(Ord(Ascii[3]), 4),
          ' (want 00E9 03B1 005A - the two accented letters MUST NOT move): ',
          YesNo(AsciiOk), '.');
  writeln('UnicodeUpperCase, which asks the wide string manager, turned the ',
          'same text into U+', HexStr(Ord(Upper[1]), 4), ' U+',
          HexStr(Ord(Upper[2]), 4), ' U+', HexStr(Ord(Upper[3]), 4),
          ' (want 00C9 0391 005A): ', YesNo(CaseOk), '.');
  writeln('UnicodeLowerCase brought all three back to what they were: ',
          YesNo(RoundOk), '.');
  writeln('the Character unit answers about letters, digits and case from ',
          'the Unicode tables: ', YesNo(TableOk), '.');
  writeln('UTF-8 of those three characters is ', Length(Utf8),
          ' bytes (want 5) and decodes back to the same text: ',
          YesNo(Utf8Ok), '.');
  writeln('tolerance: none, and the first two lines must disagree with each ',
          'other. A run where BOTH leave the accented letters alone is a ',
          'program that called the ASCII routine twice, not a target that ',
          'cannot case them. A program that omits fpwidestring from its uses ',
          'clause does not reach this line at all: the runtime''s own stub ',
          'writes "This binary has no string conversion support compiled ',
          'in." to standard error and halts with runtime error 234.');

  Good := Good and AsciiOk and CaseOk and RoundOk and TableOk and Utf8Ok;
  Report('11. Unicode', Good);
  ProveUnicode := Good;
end;


{****************************************************************************
  12. The Dos unit.
****************************************************************************}

function ProveDosUnit: Boolean;
{
  This target gained a Dos unit because Free Pascal's own packages need one:
  paszlib and unzip both call GetFAttr on every target that is not Unix. It is
  written over SysUtils, so what is being checked here is the translation —
  Turbo Pascal's conventions onto calls M5 and M6 already proved.
}
var
  Good, SearchOk, AttrOk, AbsentOk, TicksOk, ExpandOk : Boolean;
  Rec : Dos.SearchRec;
  F : file;
  Attr, AbsentAttr : Word;
  AbsentError : Integer;
  Matches, Wrong : LongInt;
  Before, After : Int64;
  Expanded : string;

  procedure MakeEmpty(const Name: string);
  var
    S : TFileStream;
  begin
    S := TFileStream.Create(Name, fmCreate);
    S.Free;
  end;

begin
  writeln;
  writeln('--- 12. the Dos unit ---');
  Good := True;
  SearchOk := False; AttrOk := False; AbsentOk := False;
  TicksOk := False; ExpandOk := False;
  Matches := 0; Wrong := 0; Attr := $FFFF; AbsentAttr := $FFFF;
  AbsentError := -1;

  try
    MakeEmpty(DosA);
    MakeEmpty(DosB);
    MakeEmpty(DosC);
    MakeEmpty(DosOther);

    { Turbo Pascal's own search loop, written the way a program from that era
      writes it: FindFirst, then FindNext while DosError is zero. }
    Dos.FindFirst(WorkDir + '/' + DosMask, Dos.AnyFile, Rec);
    while DosError = 0 do
      begin
        inc(Matches);
        if not AnsiStartsStr('walk-', Rec.Name) then
          inc(Wrong);
        writeln('  Dos.FindFirst saw "', Rec.Name, '", ', Rec.Size,
                ' bytes, attribute ', Rec.Attr);
        Dos.FindNext(Rec);
      end;
    Dos.FindClose(Rec);
    SearchOk := (Matches = DosCount) and (Wrong = 0);

    { GETFATTR ON A FILE VARIABLE, WHICH IS THE CALL PASZLIB MAKES. Both
      answers are needed. A GetFAttr that reported not-found for every name
      would fail the first; one that reported found for every name would pass
      the first and fail the second. The name is read out of the file record,
      and that record holds it as wide characters on this target — read as
      bytes it comes back as its first character alone, which is a real file
      that answers a plausible wrong attribute rather than an error. }
    Assign(F, DosA);
    Dos.GetFAttr(F, Attr);
    AttrOk := (DosError = 0) and ((Attr and Dos.Directory) = 0);

    Assign(F, WorkDir + '/no-such-name.dat');
    Dos.GetFAttr(F, AbsentAttr);
    AbsentError := DosError;
    AbsentOk := (AbsentError <> 0) and (AbsentAttr = 0);

    { GetMsCount off the free-running counter. }
    Before := Dos.GetMsCount;
    Sleep(120);
    After := Dos.GetMsCount;
    TicksOk := (After - Before) >= 100;

    Expanded := Dos.FExpand('walk-a.dat');
    ExpandOk := Length(Expanded) > Length('walk-a.dat');
  except
    on E: Exception do
      begin
        writeln('  ', E.ClassName, ': ', E.Message);
        Good := False;
      end;
  end;

  writeln('Dos.FindFirst over ', DosMask, ' found ', Matches, ' name(s), ',
          Wrong, ' of them wrong (want ', DosCount, ' and 0); ',
          'the file the mask excludes was not among them.');
  writeln('Dos.GetFAttr on ', DosA, ', which the search above had just ',
          'listed, answered attribute ', Attr, ' with DosError 0: ',
          YesNo(AttrOk), '.');
  writeln('Dos.GetFAttr on a name nothing ever created answered attribute ',
          AbsentAttr, ' with DosError ', AbsentError, ': ', YesNo(AbsentOk),
          '.');
  writeln('Dos.GetMsCount moved by ', After - Before,
          ' ms over a wait of 120 ms: ', YesNo(TicksOk), '.');
  writeln('Dos.FExpand made "walk-a.dat" absolute as "', Expanded, '": ',
          YesNo(ExpandOk), '.');
  writeln('tolerance: the search and both attribute answers are exact, and ',
          'they are exact in opposite directions on purpose. The ',
          'millisecond count is judged at 100 ms or more over a 120 ms wait, ',
          'which is slack for the scheduler and nothing else — it is the ',
          'same free-running counter M3 measured.');

  Good := Good and SearchOk and AttrOk and AbsentOk and TicksOk and ExpandOk;
  Report('12. the Dos unit', Good);
  ProveDosUnit := Good;
end;


{****************************************************************************
  13. A PNG written and read back.
****************************************************************************}

function ProvePng: Boolean;
{
  fcl-image over paszlib: a PNG's pixels live in a deflate stream, so this is
  the compression of section 7 again with a format on top of it, and the
  picture that comes back is compared pixel by pixel with the one that went
  out. A decoder that produced a plausible but wrong image is caught.
}
var
  Good, SizeOk, PixelsOk : Boolean;
  Img, Back : TFPMemoryImage;
  Writer : TFPWriterPNG;
  Reader : TFPReaderPNG;
  X, Y, Wrong : LongInt;
  Bytes : Int64;

  function Wanted(AX, AY: LongInt): TFPColor;
  begin
    { Every channel derived from the position, so no two pixels are alike and
      a picture out by one row matches nothing. }
    Result.Red := Word((AX * 1234 + AY * 61) and $FFFF);
    Result.Green := Word((AX * 61 + AY * 4321) and $FFFF);
    Result.Blue := Word(((AX xor AY) * 2571) and $FFFF);
    Result.Alpha := alphaOpaque;
  end;

begin
  writeln;
  writeln('--- 13. a PNG written and read back ---');
  Good := True;
  SizeOk := False; PixelsOk := False;
  Wrong := 0; Bytes := -1;

  try
    Img := TFPMemoryImage.Create(PngWidth, PngHeight);
    try
      for Y := 0 to PngHeight - 1 do
        for X := 0 to PngWidth - 1 do
          Img.Colors[X, Y] := Wanted(X, Y);
      Writer := TFPWriterPNG.Create;
      try
        Writer.UseAlpha := True;
        Img.SaveToFile(PngName, Writer);
      finally
        Writer.Free;
      end;
    finally
      Img.Free;
    end;

    Bytes := SizeOnCard(PngName);

    Back := TFPMemoryImage.Create(0, 0);
    try
      Reader := TFPReaderPNG.Create;
      try
        Back.LoadFromFile(PngName, Reader);
      finally
        Reader.Free;
      end;
      SizeOk := (Back.Width = PngWidth) and (Back.Height = PngHeight);
      if SizeOk then
        for Y := 0 to PngHeight - 1 do
          for X := 0 to PngWidth - 1 do
            if Back.Colors[X, Y] <> Wanted(X, Y) then
              inc(Wrong);
      PixelsOk := SizeOk and (Wrong = 0);
    finally
      Back.Free;
    end;
  except
    on E: Exception do
      begin
        writeln('  ', E.ClassName, ': ', E.Message);
        Good := False;
      end;
  end;

  writeln('wrote a ', PngWidth, ' by ', PngHeight, ' picture to ', PngName,
          ', ', Bytes, ' bytes on the card.');
  writeln('read back at ', PngWidth * PngHeight, ' pixels: the size is right ',
          YesNo(SizeOk), ' and ', Wrong, ' pixel(s) differ.');
  writeln('tolerance: none. Every channel of every pixel is worked out from ',
          'where it sits, so a picture that came back shifted by one row ',
          'would match nothing at all.');

  Good := Good and SizeOk and PixelsOk;
  Report('13. a PNG written and read back', Good);
  ProvePng := Good;
end;


{****************************************************************************
  14. Regular expressions.
****************************************************************************}

function ProveRegExpr: Boolean;
var
  Good, MatchOk, GroupOk, NoMatchOk, ReplaceOk : Boolean;
  R : TRegExpr;
  Day, Month, Replaced : string;
begin
  writeln;
  writeln('--- 14. regular expressions ---');
  Good := True;
  MatchOk := False; GroupOk := False; NoMatchOk := False; ReplaceOk := False;
  Day := ''; Month := ''; Replaced := '';

  try
    R := TRegExpr.Create;
    try
      R.Expression := '([0-9]{4})-([0-9]{2})-([0-9]{2})';
      MatchOk := R.Exec('booted on 2026-08-12 at noon');
      if MatchOk then
        begin
          Month := R.Match[2];
          Day := R.Match[3];
          GroupOk := (Month = '08') and (Day = '12');
        end;
      NoMatchOk := not R.Exec('no date in this line at all');

      R.Expression := '[aeiou]';
      Replaced := R.Replace('circle libfpc', '.', False);
      ReplaceOk := Replaced = 'c.rcl. l.bfpc';
    finally
      R.Free;
    end;
  except
    on E: Exception do
      begin
        writeln('  ', E.ClassName, ': ', E.Message);
        Good := False;
      end;
  end;

  writeln('a date pattern matched: ', YesNo(MatchOk),
          ', and its groups gave month "', Month, '" and day "', Day,
          '" (want 08 and 12).');
  writeln('the same pattern on a line with no date did not match: ',
          YesNo(NoMatchOk), '.');
  writeln('replacing every vowel in "circle libfpc" gave "', Replaced,
          '" (want "c.rcl. l.bfpc").');
  writeln('tolerance: none. Both subjects are constants in this program.');

  Good := Good and MatchOk and GroupOk and NoMatchOk and ReplaceOk;
  Report('14. regular expressions', Good);
  ProveRegExpr := Good;
end;


{****************************************************************************
  15. A read past the end must not grow the file.
****************************************************************************}

function ProveReadPastEnd: Boolean;
{
  THE DEFECT THIS SECTION EXISTS FOR. The file service seeks to the named
  offset before it reads, and on this filesystem a seek beyond the end of a
  file opened for writing as well as reading EXTENDS THAT FILE. So a read
  starting past the end used to grow the file it was only asked to read, and
  nothing anywhere reported it.

  BOTH FILE LAYERS ARE ASKED, because both had the same shape: SysUtils'
  handle layer through FileRead, and Pascal's own through BlockRead. Each
  seeks well past the end of a file opened for reading and writing, reads, and
  must be told no bytes. Then the length is taken from the card, which is the
  only reader that can say whether the file grew.

  The correct answer needs no crossing at all: this side already knows how
  long the file is, so no bytes is answered here and the card is never asked.
}
var
  Good, HandleOk, PascalOk, LengthOk : Boolean;
  H : THandle;
  P : file;
  Buf : array[0..63] of Byte;
  Where : Int64;
  GotHandle, GotPascal : LongInt;
  LengthAfter : Int64;
  OldMode : Byte;
  S : TFileStream;
  I : LongInt;
begin
  writeln;
  writeln('--- 15. a read past the end must not grow the file ---');
  Good := True;
  HandleOk := False; PascalOk := False; LengthOk := False;
  GotHandle := -1; GotPascal := -1; Where := -1; LengthAfter := -1;

  try
    { A file of a known length. }
    S := TFileStream.Create(EofName, fmCreate);
    try
      for I := 0 to EofBytes - 1 do
        Buf[I mod 64] := Byte(I);
      for I := 0 to (EofBytes div 64) - 1 do
        S.WriteBuffer(Buf, 64);
    finally
      S.Free;
    end;

    { SysUtils' handle layer, opened for reading AND writing, which is the
      only way the file could grow. }
    H := FileOpen(EofName, fmOpenReadWrite);
    if H <> THandle(-1) then
      try
        Where := FileSeek(H, Int64(EofBytes + EofBeyond), fsFromBeginning);
        GotHandle := FileRead(H, Buf, SizeOf(Buf));
      finally
        FileClose(H);
      end;
    HandleOk := (Where = EofBytes + EofBeyond) and (GotHandle = 0);

    { Pascal's own layer, over the same name, also for reading and writing.
      FileMode 2 is read and write; it is put back afterwards so nothing
      later in this program inherits it. }
    OldMode := FileMode;
    FileMode := 2;
    AssignFile(P, EofName);
    Reset(P, 1);
    FileMode := OldMode;
    try
      Seek(P, EofBytes + EofBeyond);
      BlockRead(P, Buf, SizeOf(Buf), GotPascal);
    finally
      CloseFile(P);
    end;
    PascalOk := (GotPascal = 0) and (IOResult = 0);

    { THE ONLY LINE HERE THAT ASKS THE CARD. Everything above came from this
      side's own table of positions, which is exactly the thing that would be
      wrong if the file had grown without this side knowing. }
    LengthAfter := SizeOnCard(EofName);
    LengthOk := LengthAfter = EofBytes;

    DeleteFile(EofName);
  except
    on E: Exception do
      begin
        writeln('  ', E.ClassName, ': ', E.Message);
        Good := False;
      end;
  end;

  writeln('a ', EofBytes, ' byte file, read at byte ', EofBytes + EofBeyond,
          ' through FileRead: the seek answered ', Where, ' and the read ',
          'returned ', GotHandle, ' bytes (want 0): ', YesNo(HandleOk), '.');
  writeln('the same read through Pascal''s own BlockRead returned ',
          GotPascal, ' bytes (want 0) with no I/O error: ', YesNo(PascalOk),
          '.');
  writeln('the file is ', LengthAfter, ' bytes on the card afterwards (want ',
          EofBytes, '): ', YesNo(LengthOk), '.');
  writeln('tolerance: none, and the last line is the whole point. Before ',
          'this was fixed the file would be ', EofBytes + EofBeyond,
          ' bytes or more here, because the seek that the read needed ',
          'extends a writable file on this filesystem. A read that grows a ',
          'file reports nothing and corrupts quietly.');

  Good := Good and HandleOk and PascalOk and LengthOk;
  Report('15. a read past the end', Good);
  ProveReadPastEnd := Good;
end;


{****************************************************************************
  16. Clearing up.
****************************************************************************}

function ClearUp: Boolean;
var
  Good, DirGone : Boolean;
  Removed, Wanted : LongInt;

  procedure Drop(const Name: string);
  begin
    inc(Wanted);
    if DeleteFile(Name) then
      inc(Removed)
    else
      writeln('  could not remove ', Name);
  end;

begin
  writeln;
  writeln('--- 16. clearing up ---');
  Good := True;
  Removed := 0;
  Wanted := 0;

  try
    Drop(IniName);
    Drop(GzName);
    Drop(XmlName);
    Drop(PngName);
    Drop(DosA);
    Drop(DosB);
    Drop(DosC);
    Drop(DosOther);
    DirGone := RemoveDir(WorkDir) and not DirectoryExists(WorkDir);
  except
    on E: Exception do
      begin
        writeln('  ', E.ClassName, ': ', E.Message);
        Good := False;
        DirGone := False;
      end;
  end;

  writeln('removed ', Removed, ' of the ', Wanted,
          ' files this run wrote, and then ', WorkDir, ': ', YesNo(DirGone),
          '.');
  writeln('files open at the end of the run = ', CircleOpenFileCount,
          ', searches open = ', CircleOpenSearchCount, '.');
  writeln('tolerance: every file must go, the directory must go with them, ',
          'and both tables must be back to empty. A table that is not empty ',
          'is a handle one of the units above opened and never gave back. ',
          'The host kernel looks at the card itself afterwards, on the core ',
          'that owns it.');

  Good := Good and (Removed = Wanted) and DirGone and
          (CircleOpenFileCount = 0) and (CircleOpenSearchCount = 0);
  Report('16. clearing up', Good);
  ClearUp := Good;
end;


{****************************************************************************}

var
  Passed : Boolean;

begin
  writeln('M7: Free Pascal''s standard library on this board.');
  writeln('Every section runs a known answer through a unit and compares. A ',
          'section that only called something would prove nothing, so none ',
          'of them does.');

  Passed := ProveTheDirectory;
  Pace;
  if not Passed then
    begin
      writeln;
      writeln('M7: FAILED at section 1. There is nowhere to work, so the ',
              'sections that write to the card would fail with it.');
      writeln('M7: END.');
      Halt(1);
    end;

  Passed := ProveStrUtils     and Passed;  Pace;
  Passed := ProveDateUtils    and Passed;  Pace;
  Passed := ProveVariants     and Passed;  Pace;
  Passed := ProveContainers   and Passed;  Pace;
  Passed := ProveHashes       and Passed;  Pace;
  Passed := ProveCompression  and Passed;  Pace;
  Passed := ProveIniFiles     and Passed;  Pace;
  Passed := ProveJson         and Passed;  Pace;
  Passed := ProveXml          and Passed;  Pace;
  Passed := ProveUnicode      and Passed;  Pace;
  Passed := ProveDosUnit      and Passed;  Pace;
  Passed := ProvePng          and Passed;  Pace;
  Passed := ProveRegExpr      and Passed;  Pace;
  Passed := ProveReadPastEnd  and Passed;  Pace;
  Passed := ClearUp           and Passed;  Pace;

  writeln;
  writeln('--- what this program touched ---');
  writeln('the directory ', WorkDir, ' and nothing outside it, and it ',
          'removed the whole of it before this line. The working directory ',
          'was never changed and every name above is absolute.');
  writeln('this line is on core ', CircleCurrentCore,
          ', which is where the first line was.');

  writeln;
  if Passed then
    writeln('M7: PASS. Every section above agreed.')
  else
    writeln('M7: FAIL, at:', Failures);

  writeln('M7: END.');
end.
