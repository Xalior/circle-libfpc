{
  m6.pas — the Pascal program that proves the SysUtils file family and
  TFileStream.

  WHAT THIS ASKS FOR. M5 proved Pascal's own file statements — Reset, Rewrite,
  BlockRead, Seek. This asks the question a real program actually asks:
  TFileStream opens, reads and writes; FindFirst walks a directory and reports
  what is in it and nothing that is not; FileExists and DirectoryExists answer
  correctly for a file, for a directory, and for a name that is neither.

  IT IS THE SAME SERVICE UNDERNEATH, AND THE SAME POSITION TABLE. SysUtils'
  file routines are the System unit's file layer with a different error
  convention on them, so a file opened by TFileStream and a file opened by
  Reset share one table of positions. That is why section 3 opens the same
  name both ways and reads the same bytes back through each.

  THE CARD IS A DEVICE AND THIS CORE DOES NOT OWN ONE. Nothing below names a
  core, a device or the service. It writes ordinary Pascal; the layer beneath
  it is this target's SysUtils, which calls circle-libsdl2's file service and
  nothing else. The build refuses to link if the Pascal side so much as
  mentions one of the C library's own file calls.

  WHAT THIS PROGRAM PUTS ON THE CARD, AND WHERE. One directory of its own,
  /tmp-clf-m6, with an obviously temporary name and nowhere near the boot
  path. Everything it writes is inside that directory. It removes its own
  working files before it ends and leaves five things behind on purpose — a
  witness the host kernel reads, the three files section 5's search found, and
  the one file that search was meant not to find — so that the host kernel can
  count them for itself on the core that owns the card. The host kernel
  removes those and the directory afterwards.

  THE WORKING DIRECTORY IS NOT TOUCHED HERE. M5 proves ChDir; this program
  names everything absolutely, so nothing it does depends on where the board
  is standing and nothing it does moves the board for anyone else.

  I/O CHECKING IS ON, AND THAT IS THE POINT. SysUtils installs the error
  handler that turns a failed I/O operation into an exception, so a failure
  raises where M5 had to read an I/O result after every statement. Each
  section below runs inside a try/except: an unexpected failure is reported as
  that section's FAIL with the exception's own message, and the run carries
  on. Section 7 is where a failure is the expected answer, and it asks for
  each one on purpose.

  WHAT IS SAID ABOUT THE DATE, AND WHAT IS NOT. There is no battery-backed
  clock on this board. The date the runtime reports is circle-libsdl2's
  answer, which a Pascal program gets exactly as a C program does, and it is
  not the real date. So section 8 PRINTS the date and judges only what can be
  judged without knowing it: that the clock advances, and that the host
  kernel's own reading of the same clock agrees with this one.
}
program m6;

{$mode objfpc}
{$H+}

uses
  SysUtils, Classes;

const
  { Where this program works. One directory of its own, named so that anyone
    finding it on the card knows what it is and that it should not be there. }
  WorkDir = '/tmp-clf-m6';

  { Section 2 and 3's file: a stream of records, each carrying its own index. }
  StreamName = WorkDir + '/stream.bin';

  { Section 4's text file, written and read back through TStringList. }
  LinesName = WorkDir + '/lines.txt';

  { Section 5's directory search. Three names the mask must find and one it
    must not, plus a directory that must only appear when directories were
    asked for. }
  FoundMask  = 'found-*.dat';
  FoundA     = WorkDir + '/found-a.dat';
  FoundB     = WorkDir + '/found-b.dat';
  FoundC     = WorkDir + '/found-c.dat';
  UnfoundName = WorkDir + '/other.txt';
  SubDir     = WorkDir + '/sub';
  FoundCount = 3;

  { How big each of the three search files is made, so that the search's
    report of a size can be checked against a number this program chose. }
  FoundSizeA = 11;
  FoundSizeB = 222;
  FoundSizeC = 3333;

  { A name nothing ever creates. Section 6 and section 7 both need one. }
  AbsentName = WorkDir + '/no-such-file.bin';

  { The witness the host kernel reads back on the core that owns the card. }
  WitnessName = WorkDir + '/witness.txt';

  { The record stream: how many records and how big one is. Sixteen bytes each
    and five hundred and twelve of them is eight kilobytes, which is more than
    one allocation unit on any card this board boots from, so the read-back
    crosses whatever boundaries the filesystem has. }
  RecordSize  = 16;
  RecordCount = 512;

  { The order section 2 asks for records in when it seeks. Coprime with
    RecordCount, so the walk visits every record exactly once and never in the
    order they were written. }
  SeekStride = 181;

  { Section 4's lines. }
  LineCount = 40;

  { The pause between sections. The log channel never blocks and drops a line
    it has no room for, and the console is far slower than this core, so a
    program that prints a long burst can outrun the wire and lose the middle
    of its own report. }
  PaceMillis = 250;

  { Section 8's wait, and what the clock is allowed to disagree by over it.
    The wait is measured on the free-running counter; the calendar clock is
    read to the microsecond and counts from the same counter, so a whole
    second of slack is generous rather than tight. }
  ClockWaitMillis   = 1200;
  ClockToleranceSec = 1;

type
  { ONE RECORD, AND EVERY BYTE OF IT DERIVED FROM WHERE IT LIVES.

    Index is the record's own number, so a record fetched by a seek can be
    asked who it is. Check and Fill are derived from Index by the mixer below,
    so a record that carries the right index but the wrong body — a read that
    landed part-way into the next record, say — is caught too. }
  TStamp = packed record
    Index : LongWord;
    Check : LongWord;
    Fill  : array[0..7] of Byte;
  end;

var
  { What the witness will tell the host kernel. Gathered as the sections run
    and written out by the last one. }
  SearchFound    : LongInt = -1;
  StreamBytes    : Int64 = -1;
  WitnessEpoch   : Int64 = 0;


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


{ A 32 bit mixer. Every bit of the answer depends on every bit of the input,
  so two neighbouring records share no part of their bodies and a read that
  landed one record — or one byte — out matches nothing. }
function Mix(Value: LongWord): LongWord;
begin
  Value := Value xor (Value shr 16);
  Value := Value * LongWord($7FEB352D);
  Value := Value xor (Value shr 15);
  Value := Value * LongWord($846CA68B);
  Value := Value xor (Value shr 16);
  Mix := Value;
end;


{ The record that belongs at index I. }
procedure BuildStamp(I: LongWord; out S: TStamp);
var
  J: LongInt;
begin
  S.Index := I;
  S.Check := Mix(I);
  for J := 0 to 7 do
    S.Fill[J] := Byte(Mix(I * 8 + LongWord(J)) shr 8);
end;


{ Whether S is the record that belongs at index I, body and all. }
function StampIsRight(I: LongWord; const S: TStamp): Boolean;
var
  Want: TStamp;
  J: LongInt;
begin
  BuildStamp(I, Want);
  StampIsRight := False;
  if S.Index <> Want.Index then exit;
  if S.Check <> Want.Check then exit;
  for J := 0 to 7 do
    if S.Fill[J] <> Want.Fill[J] then
      exit;
  StampIsRight := True;
end;


{ A file of exactly this many bytes, so that a search's report of a size can
  be checked against a number this program chose. }
procedure WriteFileOfSize(const Name: string; Size: LongInt);
var
  F : TFileStream;
  B : array[0..255] of Byte;
  I, Chunk, Left : LongInt;
begin
  for I := 0 to 255 do
    B[I] := Byte(I);
  F := TFileStream.Create(Name, fmCreate);
  try
    Left := Size;
    while Left > 0 do
      begin
        Chunk := Left;
        if Chunk > 256 then
          Chunk := 256;
        F.WriteBuffer(B, Chunk);
        dec(Left, Chunk);
      end;
  finally
    F.Free;
  end;
end;


{****************************************************************************
  1. The directory this run works in.
****************************************************************************}

function ProveTheDirectory: Boolean;
var
  Made, There: Boolean;
begin
  writeln;
  writeln('--- 1. the directory this run works in ---');
  writeln('this program runs on core ', CircleCurrentCore,
          ', which owns no device and reaches the card through nothing but ',
          'the file service.');
  writeln('files open at the start of the run = ', CircleOpenFileCount,
          ', searches open = ', CircleOpenSearchCount);

  Made := False;
  There := DirectoryExists(WorkDir);
  if not There then
    begin
      Made := CreateDir(WorkDir);
      There := DirectoryExists(WorkDir);
    end;

  writeln('CreateDir(', WorkDir, ') was ',
          YesNo(Made), '; DirectoryExists says the directory is there: ',
          YesNo(There), '.');
  writeln('tolerance: the directory must exist after this. An earlier run ',
          'that ended badly may have left it, which is why an existing one ',
          'is not a failure. Anything else fails, and every section below ',
          'would fail with it.');

  ProveTheDirectory := There;
  writeln('1. the directory this run works in ', Verdict(There));
end;


{****************************************************************************
  2. TFileStream: write it, free it, reopen it, read it back, and seek in it.
     This is the milestone's own sentence.
****************************************************************************}

function ProveFileStream: Boolean;
var
  F : TFileStream;
  S : TStamp;
  I, Bad, FirstBad, Want : LongInt;
  SizeAfterWrite, SizeOnReopen, PosAfterSeek : Int64;
  Good, Sequential, Sought : Boolean;
begin
  writeln;
  writeln('--- 2. TFileStream: write, free, reopen, read back, seek ---');
  Good := True;
  Sequential := False;
  Sought := False;
  SizeAfterWrite := -1;
  SizeOnReopen := -1;
  PosAfterSeek := -1;
  Bad := 0;
  FirstBad := -1;

  try
    F := TFileStream.Create(StreamName, fmCreate);
    try
      for I := 0 to RecordCount - 1 do
        begin
          BuildStamp(LongWord(I), S);
          F.WriteBuffer(S, RecordSize);
        end;
      SizeAfterWrite := F.Size;
    finally
      F.Free;
    end;

    { Reopened as a different object, so nothing of the write survives into
      the read except what is on the card. }
    F := TFileStream.Create(StreamName, fmOpenRead or fmShareDenyNone);
    try
      SizeOnReopen := F.Size;

      for I := 0 to RecordCount - 1 do
        begin
          F.ReadBuffer(S, RecordSize);
          if not StampIsRight(LongWord(I), S) then
            begin
              inc(Bad);
              if FirstBad < 0 then
                FirstBad := I;
            end;
        end;
      Sequential := (Bad = 0);

      { A SEQUENTIAL READ CANNOT TELL A CORRECT POSITION FROM ONE THAT IS
        WRONG BY A CONSTANT: both read plausible data in order. So the records
        are asked for in an order they were not written in, and each one is
        asked who it is. }
      Sought := True;
      Want := 0;
      for I := 0 to RecordCount - 1 do
        begin
          PosAfterSeek := F.Seek(Int64(Want) * RecordSize, soBeginning);
          if PosAfterSeek <> Int64(Want) * RecordSize then
            begin
              Sought := False;
              writeln('  seek to record ', Want, ' answered byte ',
                      PosAfterSeek, ', not ', Int64(Want) * RecordSize, '.');
              break;
            end;
          F.ReadBuffer(S, RecordSize);
          if not StampIsRight(LongWord(Want), S) then
            begin
              Sought := False;
              writeln('  the record at byte ', Int64(Want) * RecordSize,
                      ' says it is number ', S.Index, ', not ', Want,
                      ' - a position error of ',
                      Int64(S.Index) - Int64(Want), ' records.');
              break;
            end;
          Want := (Want + SeekStride) mod RecordCount;
        end;
    finally
      F.Free;
    end;
  except
    on E: Exception do
      begin
        writeln('  ', E.ClassName, ': ', E.Message);
        Good := False;
      end;
  end;

  StreamBytes := SizeOnReopen;

  writeln('wrote ', RecordCount, ' records of ', RecordSize,
          ' bytes. The stream reported ', SizeAfterWrite,
          ' bytes after writing and ', SizeOnReopen, ' on reopening.');
  writeln('read back in order: ', Bad, ' record(s) wrong',
          ', first at index ', FirstBad, '.');
  writeln('read back by seeking, stepping ', SeekStride,
          ' records at a time: ', YesNo(Sought), '.');
  writeln('tolerance: none. Both sizes must be exactly ',
          RecordCount * RecordSize,
          ', every record must be its own, and every seek must land on the ',
          'record it named. A wrong size, one wrong record, or one seek that ',
          'landed elsewhere fails this section.');

  Good := Good and Sequential and Sought and
          (SizeAfterWrite = RecordCount * RecordSize) and
          (SizeOnReopen = RecordCount * RecordSize);
  ProveFileStream := Good;
  writeln('2. TFileStream ', Verdict(Good));
end;


{****************************************************************************
  3. The handle layer, and that it shares one position with Pascal's own.
****************************************************************************}

function ProveHandleLayer: Boolean;
var
  H : THandle;
  S : TStamp;
  P : file;
  Got : Int64;
  ReadOk, SeekOk, TruncOk, Good : Boolean;
  LengthOnCard : Int64;
  LengthOk, FirstRecordOk : Boolean;
  KeepBytes : Int64;
  Blocks : Int64;
begin
  writeln;
  writeln('--- 3. FileOpen, FileSeek, FileRead, and the one position ---');
  Good := True;
  ReadOk := False;
  SeekOk := False;
  TruncOk := False;
  LengthOk := False;
  FirstRecordOk := False;
  LengthOnCard := -1;
  KeepBytes := Int64(RecordCount div 2) * RecordSize;

  try
    H := FileOpen(StreamName, fmOpenReadWrite);
    if H = THandle(-1) then
      writeln('  FileOpen refused ', StreamName, ' - OS error ',
              GetLastOSError, ': ', SysErrorMessage(GetLastOSError))
    else
      try
        Got := FileSeek(H, Int64(RecordCount - 1) * RecordSize, fsFromBeginning);
        SeekOk := Got = Int64(RecordCount - 1) * RecordSize;
        ReadOk := (FileRead(H, S, RecordSize) = RecordSize) and
                  StampIsRight(LongWord(RecordCount - 1), S);

        { Cut the file in half through the handle, and see the length change
          where the stream layer above will read it. }
        TruncOk := (FileSeek(H, KeepBytes, fsFromBeginning) = KeepBytes) and
                   FileTruncate(H, KeepBytes) and
                   (FileSeek(H, 0, fsFromEnd) = KeepBytes);
      finally
        FileClose(H);
      end;

    { THE SAME NAME, OPENED BY PASCAL'S OWN FILE LAYER. Both layers hand out
      the same descriptors and share one table of positions, so a file that
      reads correctly through each of them in turn is that table being one
      table. }
    AssignFile(P, StreamName);
    Reset(P, RecordSize);
    try
      { TWO SEPARATE FACTS, REPORTED SEPARATELY. One boolean covering both
        says a section failed without saying which half, and the length is
        the half that is about the card. }
      Blocks := FileSize(P);
      LengthOnCard := Int64(Blocks) * RecordSize;
      LengthOk := LengthOnCard = KeepBytes;
      BlockRead(P, S, 1);
      FirstRecordOk := StampIsRight(0, S);
    finally
      CloseFile(P);
    end;
  except
    on E: Exception do
      begin
        writeln('  ', E.ClassName, ': ', E.Message);
        Good := False;
      end;
  end;

  writeln('through the handle: seek to the last record ', YesNo(SeekOk),
          ', the record read back is its own ', YesNo(ReadOk),
          ', truncate to ', KeepBytes, ' bytes ', YesNo(TruncOk), '.');
  writeln('the same name reopened by Pascal''s own Reset, which asks the ',
          'card: it is ', LengthOnCard, ' bytes and this side cut it to ',
          KeepBytes, ' (', YesNo(LengthOk), '); record 0 still reads back ',
          'correctly (', YesNo(FirstRecordOk), ').');
  writeln('tolerance: none, and the length is the one that is about the ',
          'card. Every figure above it comes from this side''s own table; ',
          'the reopen is the only line here that asks the filesystem, so a ',
          'length that disagrees is this layer and the card disagreeing ',
          'about one file.');

  Good := Good and SeekOk and ReadOk and TruncOk and LengthOk and
          FirstRecordOk;
  ProveHandleLayer := Good;
  writeln('3. the handle layer, and the one position ', Verdict(Good));
end;


{****************************************************************************
  4. TStringList over a file, which is the shape a real program writes.
****************************************************************************}

function ExpectedLine(I: LongInt): string;
begin
  ExpectedLine := 'line ' + IntToStr(I) + ' check ' + IntToStr(Mix(LongWord(I)));
end;


function ProveStringList: Boolean;
var
  L : TStringList;
  I, Bad, FirstBad, CountBack : LongInt;
  Good : Boolean;
begin
  writeln;
  writeln('--- 4. TStringList saved to a file and loaded back ---');
  Good := True;
  Bad := 0;
  FirstBad := -1;
  CountBack := -1;

  try
    L := TStringList.Create;
    try
      for I := 0 to LineCount - 1 do
        L.Add(ExpectedLine(I));
      L.SaveToFile(LinesName);
    finally
      L.Free;
    end;

    L := TStringList.Create;
    try
      L.LoadFromFile(LinesName);
      CountBack := L.Count;
      for I := 0 to L.Count - 1 do
        if L[I] <> ExpectedLine(I) then
          begin
            inc(Bad);
            if FirstBad < 0 then
              begin
                FirstBad := I;
                writeln('  line ', I, ' came back as "', L[I],
                        '" and should be "', ExpectedLine(I), '".');
              end;
          end;
    finally
      L.Free;
    end;
  except
    on E: Exception do
      begin
        writeln('  ', E.ClassName, ': ', E.Message);
        Good := False;
      end;
  end;

  writeln('saved ', LineCount, ' lines to ', LinesName, ' and loaded ',
          CountBack, ' back; ', Bad, ' line(s) differ.');
  writeln('tolerance: none. Every line must come back exactly as it was ',
          'written, and there must be ', LineCount, ' of them.');

  Good := Good and (CountBack = LineCount) and (Bad = 0);
  ProveStringList := Good;
  writeln('4. TStringList over a file ', Verdict(Good));
end;


{****************************************************************************
  5. FindFirst, FindNext, FindClose: what is there, and what is not.
****************************************************************************}

function ProveTheSearch: Boolean;
var
  Rec : TSearchRec;
  Res : LongInt;
  SeenA, SeenB, SeenC : Boolean;
  SeenOther, SeenSub : Boolean;
  SizesRight : Boolean;
  Matches, WithDirs, DirsSeen : LongInt;
  SearchesDuring, SearchesAfter : LongWord;
  Good : Boolean;
begin
  writeln;
  writeln('--- 5. FindFirst, FindNext, FindClose ---');
  Good := True;
  SeenA := False; SeenB := False; SeenC := False;
  SeenOther := False; SeenSub := False;
  SizesRight := True;
  Matches := 0;
  WithDirs := 0;
  DirsSeen := 0;
  SearchesDuring := 0;
  SearchesAfter := 0;

  try
    WriteFileOfSize(FoundA, FoundSizeA);
    WriteFileOfSize(FoundB, FoundSizeB);
    WriteFileOfSize(FoundC, FoundSizeC);
    WriteFileOfSize(UnfoundName, 7);
    if not DirectoryExists(SubDir) then
      CreateDir(SubDir);

    { The mask, over files only. }
    Res := FindFirst(WorkDir + '/' + FoundMask, faAnyFile and not faDirectory, Rec);
    try
      if Res = 0 then
        SearchesDuring := CircleOpenSearchCount;
      while Res = 0 do
        begin
          inc(Matches);
          if Rec.Name = 'found-a.dat' then
            begin
              SeenA := True;
              if Rec.Size <> FoundSizeA then SizesRight := False;
            end
          else if Rec.Name = 'found-b.dat' then
            begin
              SeenB := True;
              if Rec.Size <> FoundSizeB then SizesRight := False;
            end
          else if Rec.Name = 'found-c.dat' then
            begin
              SeenC := True;
              if Rec.Size <> FoundSizeC then SizesRight := False;
            end
          else if Rec.Name = 'other.txt' then
            SeenOther := True
          else if Rec.Name = 'sub' then
            SeenSub := True;
          writeln('  found "', Rec.Name, '", ', Rec.Size,
                  ' bytes, attributes ', Rec.Attr, ', time stamp ', Rec.Time);
          Res := FindNext(Rec);
        end;
    finally
      FindClose(Rec);
    end;
    SearchesAfter := CircleOpenSearchCount;

    { Everything, directories included. The subdirectory must appear only in
      this one, and only because it was asked for. }
    Res := FindFirst(WorkDir + '/*', faAnyFile, Rec);
    try
      while Res = 0 do
        begin
          inc(WithDirs);
          if (Rec.Attr and faDirectory) <> 0 then
            inc(DirsSeen);
          Res := FindNext(Rec);
        end;
    finally
      FindClose(Rec);
    end;
  except
    on E: Exception do
      begin
        writeln('  ', E.ClassName, ': ', E.Message);
        Good := False;
      end;
  end;

  writeln('searching ', WorkDir, '/', FoundMask, ' found ', Matches,
          ' name(s): found-a.dat ', YesNo(SeenA), ', found-b.dat ',
          YesNo(SeenB), ', found-c.dat ', YesNo(SeenC), '.');
  writeln('the same search did NOT report other.txt: ', YesNo(not SeenOther),
          '; and did NOT report the sub directory: ', YesNo(not SeenSub), '.');
  writeln('the sizes it reported are the sizes this program wrote: ',
          YesNo(SizesRight), '.');
  writeln('a second search of ', WorkDir, '/* with directories asked for ',
          'reported ', WithDirs, ' name(s), ', DirsSeen, ' of them ',
          'directories.');
  writeln('searches open during the first search = ', SearchesDuring,
          ', after FindClose = ', SearchesAfter, '.');
  writeln('tolerance: exactly ', FoundCount,
          ' matches, all three by name, neither of the two names the mask ',
          'excludes, every size exact, at least one directory in the second ',
          'search, and the search table back to empty after FindClose. ',
          'The time stamp printed above is whatever the card reports and is ',
          'not judged here - see section 8.');

  Good := Good and (Matches = FoundCount) and SeenA and SeenB and SeenC and
          (not SeenOther) and (not SeenSub) and SizesRight and
          (DirsSeen >= 1) and (SearchesDuring = 1) and (SearchesAfter = 0);
  SearchFound := Matches;
  ProveTheSearch := Good;
  writeln('5. FindFirst, FindNext, FindClose ', Verdict(Good));
end;


{****************************************************************************
  6. FileExists and DirectoryExists: a file, a directory, and neither.
****************************************************************************}

function ProveExistence: Boolean;
var
  FileIsFile, FileIsNotDir : Boolean;
  DirIsDir, DirIsNotFile : Boolean;
  AbsentIsNeither : Boolean;
  Good : Boolean;
begin
  writeln;
  writeln('--- 6. FileExists and DirectoryExists ---');
  Good := True;
  FileIsFile := False; FileIsNotDir := False;
  DirIsDir := False; DirIsNotFile := False;
  AbsentIsNeither := False;

  try
    FileIsFile   := FileExists(FoundA);
    FileIsNotDir := not DirectoryExists(FoundA);
    DirIsDir     := DirectoryExists(SubDir);
    DirIsNotFile := not FileExists(SubDir);
    AbsentIsNeither := (not FileExists(AbsentName)) and
                       (not DirectoryExists(AbsentName));
  except
    on E: Exception do
      begin
        writeln('  ', E.ClassName, ': ', E.Message);
        Good := False;
      end;
  end;

  writeln('for the file ', FoundA, ': FileExists ', YesNo(FileIsFile),
          ', DirectoryExists ', YesNo(not FileIsNotDir), '.');
  writeln('for the directory ', SubDir, ': DirectoryExists ', YesNo(DirIsDir),
          ', FileExists ', YesNo(not DirIsNotFile), '.');
  writeln('for ', AbsentName, ', which nothing ever created: neither ',
          'answers yes: ', YesNo(AbsentIsNeither), '.');
  writeln('tolerance: none, and the two crossed answers are the ones that ',
          'matter. FileExists says no to a directory on this target, ',
          'deliberately: a program asking it is about to open the name, and ',
          'a directory cannot be opened.');

  Good := Good and FileIsFile and FileIsNotDir and DirIsDir and
          DirIsNotFile and AbsentIsNeither;
  ProveExistence := Good;
  writeln('6. FileExists and DirectoryExists ', Verdict(Good));
end;


{****************************************************************************
  7. What must fail, and what this board cannot answer.
****************************************************************************}

function ProveFailures: Boolean;
var
  Raised, Refused, NoDate, NoAttr, NoSpace, NoProcess : Boolean;
  H : THandle;
  Good : Boolean;
  SearchRes : LongInt;
  Rec : TSearchRec;
  Stream : TFileStream;
  NothingFound : Boolean;
begin
  writeln;
  writeln('--- 7. what must fail ---');
  Good := True;
  Raised := False; Refused := False; NoDate := False;
  NoAttr := False; NoSpace := False; NoProcess := False;
  NothingFound := False;

  { A stream on a name that is not there must raise rather than hand back an
    object on nothing. This is also the whole exception path over SysUtils. }
  try
    Stream := TFileStream.Create(AbsentName, fmOpenRead);
    Stream.Free;
    writeln('  opening ', AbsentName, ' did not raise, which it must: the ',
            'name is not on the card.');
  except
    on E: EFOpenError do
      begin
        Raised := True;
        writeln('  opening ', AbsentName, ' raised ', E.ClassName,
                ' as it should.');
      end;
    on E: Exception do
      writeln('  opening ', AbsentName, ' raised ', E.ClassName,
              ', which is not the EFOpenError expected: ', E.Message);
  end;

  { DeleteFile names a file, so a directory is refused rather than removed. }
  Refused := not DeleteFile(SubDir);

  { A date this board cannot read, an attribute it cannot set, and a free
    space figure it does not have. All three report failure; none of them
    reports success. }
  H := FileOpen(FoundA, fmOpenRead);
  if H <> THandle(-1) then
    try
      NoDate := FileGetDate(H) < 0;
    finally
      FileClose(H);
    end;
  NoAttr := FileSetAttr(FoundA, faReadOnly) < 0;
  NoSpace := DiskFree(0) < 0;

  { There are no processes here, and ExecuteProcess raises rather than
    reporting a failure a caller might not read. }
  try
    ExecuteProcess(RawByteString('/nothing'), RawByteString(''));
  except
    on E: Exception do
      begin
        NoProcess := True;
        writeln('  ExecuteProcess raised ', E.ClassName, ': ', E.Message);
      end;
  end;

  { A search whose mask matches nothing must report that, and must still give
    its slot back. }
  SearchRes := FindFirst(WorkDir + '/nothing-matches-this-*', faAnyFile, Rec);
  NothingFound := SearchRes <> 0;
  FindClose(Rec);

  writeln('TFileStream on a name that is not there raised EFOpenError: ',
          YesNo(Raised), '.');
  writeln('DeleteFile refused the directory ', SubDir, ': ', YesNo(Refused),
          '.');
  writeln('FileGetDate reported failure (there is no stat by handle here): ',
          YesNo(NoDate), '.');
  writeln('FileSetAttr reported failure (the service sets no attributes): ',
          YesNo(NoAttr), '.');
  writeln('DiskFree reported failure (the service has no free-space figure): ',
          YesNo(NoSpace), '.');
  writeln('ExecuteProcess raised (this machine runs one program): ',
          YesNo(NoProcess), '.');
  writeln('a search matching nothing reported nothing found: ',
          YesNo(NothingFound), ', and searches open afterwards = ',
          CircleOpenSearchCount, '.');
  writeln('tolerance: none. Every line above must say yes. A no here is a ',
          'routine reporting success for something this board cannot do, ',
          'which is worse than the missing feature.');

  Good := Raised and Refused and NoDate and NoAttr and NoSpace and
          NoProcess and NothingFound and (CircleOpenSearchCount = 0);
  ProveFailures := Good;
  writeln('7. what must fail ', Verdict(Good));
end;


{****************************************************************************
  8. The clock: what it says, and the only two things that can be judged.
****************************************************************************}

function ProveTheClock: Boolean;
var
  Before, After : TDateTime;
  TicksBefore, TicksAfter : QWord;
  MovedSeconds, TickMillis : Int64;
  Advanced, TicksAdvanced, Good : Boolean;
begin
  writeln;
  writeln('--- 8. the clock ---');
  Good := True;

  Before := Now;
  TicksBefore := GetTickCount64;
  Sleep(ClockWaitMillis);
  After := Now;
  TicksAfter := GetTickCount64;

  MovedSeconds := Round((After - Before) * 24 * 60 * 60);
  TickMillis := Int64(TicksAfter - TicksBefore);
  WitnessEpoch := Round((After - EncodeDate(1970, 1, 1)) * 24 * 60 * 60);

  writeln('THERE IS NO BATTERY-BACKED CLOCK ON THIS BOARD. The date below is ',
          'what circle-libsdl2 answers, which is what a C program on this ',
          'board reads. It is well defined and it is not the real date, and ',
          'nothing here corrects it.');
  writeln('Now says ', DateTimeToStr(After), ' (UTC; there is no time zone ',
          'here), which is ', WitnessEpoch, ' seconds since 1970-01-01.');
  writeln('a wait of ', ClockWaitMillis, ' ms moved the calendar clock by ',
          MovedSeconds, ' s and the elapsed-time counter by ', TickMillis,
          ' ms.');

  Advanced := MovedSeconds >= 1;
  TicksAdvanced := TickMillis >= ClockWaitMillis;

  writeln('the calendar clock advanced: ', YesNo(Advanced),
          '; the elapsed counter advanced by at least the wait: ',
          YesNo(TicksAdvanced), '.');
  writeln('tolerance: the calendar clock must move by at least 1 s over a ',
          'wait of ', ClockWaitMillis, ' ms, and the elapsed counter by at ',
          'least ', ClockWaitMillis, ' ms. THE VALUE OF THE DATE IS NOT ',
          'JUDGED HERE - it cannot be, on a board with no clock to keep it. ',
          'The host kernel reads the same clock on its own core afterwards ',
          'and compares, within ', ClockToleranceSec,
          ' s, which is the check that this side reads it correctly.');

  Good := Advanced and TicksAdvanced;
  ProveTheClock := Good;
  writeln('8. the clock ', Verdict(Good));
end;


{****************************************************************************
  9. The witness, and clearing up.
****************************************************************************}

function ProveWitnessAndCleanUp: Boolean;
var
  W : TStringList;
  Wrote, RemovedStream, RemovedLines, RemovedSub : Boolean;
  Good : Boolean;
  FilesLeft : LongWord;
begin
  writeln;
  writeln('--- 9. the witness, and clearing up ---');
  Good := True;
  Wrote := False;
  RemovedStream := False;
  RemovedLines := False;
  RemovedSub := False;

  try
    { WHAT THIS FILE IS FOR. Everything this program has said about the card
      it learned through the layer it wrote with, so a layer wrong in both
      directions would agree with itself. The host kernel reads this file on
      the core that owns the card, with the C library, having never been near
      the Pascal file layer - and it counts the search files itself rather
      than believing the number below. }
    W := TStringList.Create;
    try
      W.Add('m6 witness');
      W.Add('found-count=' + IntToStr(SearchFound));
      W.Add('stream-bytes=' + IntToStr(StreamBytes));
      W.Add('epoch=' + IntToStr(WitnessEpoch));
      W.SaveToFile(WitnessName);
    finally
      W.Free;
    end;
    Wrote := FileExists(WitnessName);

    { This program's own working files go. The three search files, the one
      the search had to miss, the sub directory and the witness stay, for the
      host kernel to count and then remove. }
    RemovedStream := DeleteFile(StreamName);
    RemovedLines := DeleteFile(LinesName);
    RemovedSub := RemoveDir(SubDir);
  except
    on E: Exception do
      begin
        writeln('  ', E.ClassName, ': ', E.Message);
        Good := False;
      end;
  end;

  FilesLeft := CircleOpenFileCount;

  writeln('wrote ', WitnessName, ': ', YesNo(Wrote),
          '. It carries the number of names section 5 found, the size of ',
          'section 2''s stream, and the moment section 8 read off the clock.');
  writeln('removed ', StreamName, ' (', YesNo(RemovedStream), '), ',
          LinesName, ' (', YesNo(RemovedLines), '), ', SubDir, ' (',
          YesNo(RemovedSub), ').');
  writeln('files open at the end of the run = ', FilesLeft,
          ', searches open = ', CircleOpenSearchCount, '.');
  writeln('tolerance: the witness must be there, all three removals must ',
          'succeed, and both tables must be back to empty. A table that is ',
          'not empty is a handle this program opened and never gave back.');

  Good := Good and Wrote and RemovedStream and RemovedLines and RemovedSub and
          (FilesLeft = 0) and (CircleOpenSearchCount = 0);
  ProveWitnessAndCleanUp := Good;
  writeln('9. the witness, and clearing up ', Verdict(Good));
end;


{****************************************************************************}

var
  Passed : Boolean;
  Ok     : Boolean;

begin
  writeln('M6: the SysUtils file family and TFileStream, through ',
          'circle-libsdl2''s file service.');
  writeln('Every section prints its own figures, its own tolerance and its ',
          'own verdict.');

  Passed := ProveTheDirectory;
  Pace;
  if not Passed then
    begin
      writeln;
      writeln('M6: FAILED at section 1. There is nowhere to work, so nothing ',
              'below it would mean anything.');
      writeln('M6: END.');
      Halt(1);
    end;

  Ok := ProveFileStream;        Passed := Ok and Passed;   Pace;
  if not Ok then
    begin
      writeln('M6: section 2 is the milestone''s own sentence. Section 3 ',
              'reads the file it wrote, so it will fail with it.');
      Pace;
    end;

  Ok := ProveHandleLayer;       Passed := Ok and Passed;   Pace;
  Ok := ProveStringList;        Passed := Ok and Passed;   Pace;
  Ok := ProveTheSearch;         Passed := Ok and Passed;   Pace;
  Ok := ProveExistence;         Passed := Ok and Passed;   Pace;
  Ok := ProveFailures;          Passed := Ok and Passed;   Pace;
  Ok := ProveTheClock;          Passed := Ok and Passed;   Pace;
  Ok := ProveWitnessAndCleanUp; Passed := Ok and Passed;   Pace;

  writeln;
  writeln('--- what this program touched ---');
  writeln('the directory ', WorkDir, ' and nothing outside it. It leaves ',
          'behind the witness and the four names section 5 searched over, ',
          'for the host kernel to count on the core that owns the card; the ',
          'host kernel removes those and the directory.');
  writeln('the working directory was never changed, and every name above is ',
          'absolute.');
  writeln('this line is on core ', CircleCurrentCore,
          ', which is where the first line was.');

  writeln;
  if Passed then
    writeln('M6: PASS. Every section above agreed.')
  else
    writeln('M6: FAIL. Read back for the section that said so.');

  writeln('M6: every file operation above went through circle-libsdl2''s ',
          'file service. This program named no device and no core.');
  writeln('M6: END.');
end.
