{
  m5.pas — the Pascal program that proves files.

  WHAT THIS MILESTONE ASKS FOR: open, read, write and seek succeed on the
  card, through circle-libsdl2's file service; a Pascal program that reopens
  what it wrote reads back what it wrote; and nothing in the library reached
  the card itself.

  THE CARD IS A DEVICE AND THIS CORE DOES NOT OWN ONE. Every file operation
  below is an ordinary Pascal file statement — Rewrite, BlockWrite, Seek,
  Reset, readln. What is underneath them is this target's sysfile.inc, which
  calls circle-libsdl2's file service and nothing else. That service is not a
  second filesystem: it is the C library's own file call, performed on the
  core that owns the card. So this program says nothing about cores and knows
  nothing about the service; it writes Pascal, and the layer beneath it is
  what the milestone is about.

  WHAT PROVES THE SEEK ARITHMETIC RATHER THAN ASSUMING IT. A sequential
  read-back cannot tell a correct position from one that is wrong by a
  constant: both read plausible data in order. So every record written here
  CARRIES ITS OWN INDEX, and section 3 asks for records in an order that is
  not the order they were written in. A record fetched by a seek to N either
  says N or says something else, and if it says something else this program
  prints the difference — which is the size of the position error rather than
  merely the fact of one.

  WHAT THIS PROGRAM PUTS ON THE CARD, AND WHERE. One directory of its own
  making, /tmp-clf-m5, with an obviously temporary name and nowhere near the
  boot path. Inside it: records.bin and lines.txt, both erased by this
  program before it ends, and witness.txt, which is left on purpose for the
  host kernel to read back from the core that owns the card. The kernel
  removes the witness and the directory afterwards, because the file service
  carries no rmdir and this program therefore cannot.

  I/O CHECKING IS OFF THROUGHOUT AND THAT IS DELIBERATE. This target builds
  the System unit alone, and nothing has replaced the runtime's default error
  handler, so a failed file operation with checking on is a run-time error
  that halts the program — which would end the run at the first section meant
  to fail. Every file statement below is followed by a read of the I/O result,
  which is the answer itself rather than a way of ignoring it.
}
program m5;

{$mode objfpc}
{$H+}
{$I-}

const
  { Where this program works. One directory of its own, named so that anyone
    finding it on the card knows what it is and that it should not be there. }
  WorkDir     = '/tmp-clf-m5';
  RecordsName = WorkDir + '/records.bin';
  LinesName   = WorkDir + '/lines.txt';
  WitnessName = WorkDir + '/witness.txt';
  AbsentName  = WorkDir + '/no-such-file.bin';
  RenamedName = WorkDir + '/no-such-file-renamed.bin';

  { The binary file: how many records, and how big one is. Sixteen bytes each
    and five hundred and twelve of them is eight kilobytes, which is more
    than one allocation unit on any card this board boots from, so the
    read-back crosses whatever boundaries the filesystem has. }
  RecordSize  = 16;
  RecordCount = 512;

  { THE ORDER SECTION 3 ASKS FOR RECORDS IN. Step by this many records each
    time, wrapping. It is coprime with RecordCount, so the walk visits every
    record exactly once and never in the order they were written. }
  SeekStride  = 181;

  { The text file. }
  LineCount   = 40;

  { How much of the file section 5 keeps when it cuts. }
  KeepRecords = 200;

  { The pause between sections. The log channel never blocks and drops a line
    it has no room for, and the console is far slower than this core, so a
    program that prints a long burst can outrun the wire and lose the middle
    of its own report. }
  PaceMicros  = 250000;

  { Free Pascal's own I/O result numbers, named where this program expects
    one, because a bare number in a verdict says nothing to the reader.
    IOR_NO_CHANNEL is what this target reports for an operation the file
    service carries no channel for. }
  IOR_OK         = 0;
  IOR_NO_CHANNEL = 1;
  IOR_NOT_FOUND  = 2;
  IOR_EXISTS     = 5;

type
  { ONE RECORD, AND EVERY BYTE OF IT DERIVED FROM WHERE IT LIVES.

    Index is the record's own number, so a record fetched by a seek can be
    asked who it is. Check and Fill are derived from Index by the mixer
    below, so a record that carries the right index but the wrong body — a
    read that landed part-way into the next record, say — is caught too. }
  TStamp = packed record
    Index : LongWord;
    Check : LongWord;
    Fill  : array[0..7] of Byte;
  end;


{****************************************************************************
                     Reading the I/O result, and why always
****************************************************************************}

{ EVERY FREE PASCAL I/O ROUTINE RETURNS AT ONCE IF THE LAST ONE LEFT AN ERROR
  BEHIND, AND WRITELN IS ONE OF THEM. So an unread I/O result does not merely
  go unnoticed with checking off: it silences the rest of this program's
  report, including the verdict that would have said something was wrong.

  Hence the rule this whole program follows. Every file statement is followed
  immediately by one of these, and no file statement ever appears inside a
  writeln's argument list — where a failure would swallow the remainder of
  the line it was being printed on. }
function IOR: Word;
begin
  IOR := IOResult;
end;


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
  CircleWaitMicroseconds(PaceMicros);
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


{****************************************************************************
  1. The machine, and the directory this run works in.
****************************************************************************}

function ProveTheDirectory: Boolean;
var
  Res: Word;
  Good: Boolean;
begin
  writeln;
  writeln('--- 1. the working directory ---');
  writeln('this program runs on core ', CircleCurrentCore,
          ', which owns no device and reaches the card through nothing but ',
          'the file service.');
  writeln('files open at the start of the run = ', CircleOpenFileCount);

  MkDir(WorkDir);
  Res := IOR;

  { An earlier run that ended badly could have left the directory behind.
    That is the one failure this section forgives, and it says so rather
    than hiding it. }
  if Res = IOR_OK then
    writeln('made ', WorkDir, ' on the card.')
  else if Res = IOR_EXISTS then
    writeln('did not make ', WorkDir, ' - I/O result ', Res,
            ', which is what an existing directory reports. ',
            'Carrying on inside it.')
  else
    writeln('could not make ', WorkDir, ' - I/O result ', Res, '.');

  writeln('tolerance: the directory must exist after this. A card that did ',
          'not carry it reports ', IOR_OK, ' and a card left over from an ',
          'earlier run reports ', IOR_EXISTS,
          '. Anything else fails, and every section below would fail with it.');

  Good := (Res = IOR_OK) or (Res = IOR_EXISTS);
  ProveTheDirectory := Good;
  writeln('1. the working directory ', Verdict(Good));
end;


{****************************************************************************
  2. Write it, close it, reopen it, read it back. This is the milestone's own
     sentence, and the only section whose failure makes the rest meaningless.
****************************************************************************}

function ProveWriteThenReopen: Boolean;
var
  F: file;
  S: TStamp;
  I: LongInt;
  Res: Word;
  WroteOk, ClosedOk, ReadOk, EofAtEnd, Good: Boolean;
  Bad, FirstBad: LongInt;
  OpenSize, OpenPos, ReopenedSize, EndPos: Int64;
  OpenAfterCreate, OpenAfterClose: LongWord;
begin
  writeln;
  writeln('--- 2. write, close, reopen, read back ---');

  WroteOk := True;
  ClosedOk := True;
  ReadOk := True;
  EofAtEnd := False;
  OpenSize := -1;
  OpenPos := -1;
  ReopenedSize := -1;
  EndPos := -1;
  Bad := 0;
  FirstBad := -1;

  Assign(F, RecordsName);
  Rewrite(F, RecordSize);
  Res := IOR;
  if Res <> IOR_OK then
    begin
      writeln('could not create ', RecordsName, ' - I/O result ', Res, '.');
      writeln('2. write, close, reopen, read back ', Verdict(False));
      ProveWriteThenReopen := False;
      exit;
    end;
  OpenAfterCreate := CircleOpenFileCount;

  for I := 0 to RecordCount - 1 do
    begin
      BuildStamp(LongWord(I), S);
      BlockWrite(F, S, 1);
      Res := IOR;
      if Res <> IOR_OK then
        begin
          writeln('write of record ', I, ' failed - I/O result ', Res, '.');
          WroteOk := False;
          break;
        end;
    end;

  { Asked while the file is still open, so both come from the position this
    layer holds rather than from anything the card was asked. }
  OpenPos := FilePos(F);
  if IOR <> IOR_OK then OpenPos := -1;
  OpenSize := FileSize(F);
  if IOR <> IOR_OK then OpenSize := -1;

  Close(F);
  Res := IOR;
  if Res <> IOR_OK then
    begin
      writeln('close failed - I/O result ', Res, '.');
      ClosedOk := False;
    end;
  OpenAfterClose := CircleOpenFileCount;

  writeln('created ', RecordsName, ' and wrote ', RecordCount,
          ' records of ', RecordSize, ' bytes.');
  writeln('while it was open: position ', OpenPos, ', length ', OpenSize,
          ' records. files this layer had open: ', OpenAfterCreate,
          ' with it open, ', OpenAfterClose, ' after closing it.');

  { THE REOPEN. Its length comes off the card, from the service's own look at
    the file, and not from anything this side remembered - the entry that
    held it was given back when the file was closed. So a length that agrees
    here is the card agreeing. }
  Assign(F, RecordsName);
  Reset(F, RecordSize);
  Res := IOR;
  if Res <> IOR_OK then
    begin
      writeln('could not reopen ', RecordsName, ' - I/O result ', Res, '.');
      writeln('2. write, close, reopen, read back ', Verdict(False));
      ProveWriteThenReopen := False;
      exit;
    end;

  ReopenedSize := FileSize(F);
  if IOR <> IOR_OK then ReopenedSize := -1;

  for I := 0 to RecordCount - 1 do
    begin
      BlockRead(F, S, 1);
      Res := IOR;
      if Res <> IOR_OK then
        begin
          writeln('read of record ', I, ' failed - I/O result ', Res, '.');
          ReadOk := False;
          break;
        end;
      if not StampIsRight(LongWord(I), S) then
        begin
          inc(Bad);
          if FirstBad < 0 then
            begin
              FirstBad := I;
              writeln('record ', I, ' read back wrong: it says it is record ',
                      S.Index, '.');
            end;
        end;
    end;

  EndPos := FilePos(F);
  if IOR <> IOR_OK then EndPos := -1;
  EofAtEnd := Eof(F);
  if IOR <> IOR_OK then EofAtEnd := False;

  Close(F);
  if IOR <> IOR_OK then ClosedOk := False;

  writeln('reopened it: the card says it is ', ReopenedSize,
          ' records long, and ', RecordCount, ' were written.');
  writeln(RecordCount - Bad, ' of ', RecordCount,
          ' records read back exactly as written.');
  writeln('after the last record: position ', EndPos,
          ', end of file ', YesNo(EofAtEnd), '.');
  writeln('tolerance: none. Every record carries its own index and a body ',
          'derived from it, so one wrong byte anywhere is one wrong record ',
          'here.');

  Good := WroteOk and ClosedOk and ReadOk and (Bad = 0) and
          (ReopenedSize = RecordCount) and (OpenSize = RecordCount) and
          (OpenPos = RecordCount) and (EndPos = RecordCount) and EofAtEnd;
  ProveWriteThenReopen := Good;
  writeln('2. write, close, reopen, read back ', Verdict(Good));
end;


{****************************************************************************
  3. The seek arithmetic, proved rather than assumed.
****************************************************************************}

function ProveSeek: Boolean;
var
  F: file;
  S: TStamp;
  I, N: LongInt;
  Res: Word;
  Bad, WorstDelta, Delta: LongInt;
  PosBefore, PosAfter, PosAtEnd: Int64;
  PosOk, EndOk, EofAtEnd, Good: Boolean;
begin
  writeln;
  writeln('--- 3. seek ---');

  Assign(F, RecordsName);
  Reset(F, RecordSize);
  Res := IOR;
  if Res <> IOR_OK then
    begin
      writeln('could not open ', RecordsName, ' - I/O result ', Res, '.');
      writeln('3. seek ', Verdict(False));
      ProveSeek := False;
      exit;
    end;

  Bad := 0;
  WorstDelta := 0;
  PosOk := True;
  N := 0;
  for I := 0 to RecordCount - 1 do
    begin
      Seek(F, N);
      Res := IOR;
      if Res <> IOR_OK then
        begin
          writeln('seek to record ', N, ' failed - I/O result ', Res, '.');
          inc(Bad);
          break;
        end;

      PosBefore := FilePos(F);
      if IOR <> IOR_OK then PosBefore := -1;
      if PosBefore <> N then
        PosOk := False;

      BlockRead(F, S, 1);
      Res := IOR;
      if Res <> IOR_OK then
        begin
          writeln('read at record ', N, ' failed - I/O result ', Res, '.');
          inc(Bad);
          break;
        end;

      PosAfter := FilePos(F);
      if IOR <> IOR_OK then PosAfter := -1;
      if PosAfter <> N + 1 then
        PosOk := False;

      if not StampIsRight(LongWord(N), S) then
        begin
          inc(Bad);
          { THE SIZE OF THE ERROR, NOT JUST ITS PRESENCE. A record fetched by
            a seek to N that says it is record M was read at M rather than at
            N, so M-N is the position error, in records. }
          Delta := LongInt(S.Index) - N;
          if Bad = 1 then
            writeln('seek to record ', N, ' fetched record ', S.Index,
                    ': out by ', Delta, ' records, ', Delta * RecordSize,
                    ' bytes.');
          if Delta < 0 then Delta := -Delta;
          if Delta > WorstDelta then WorstDelta := Delta;
        end;

      N := (N + SeekStride) mod RecordCount;
    end;

  { A seek to the end. There is nothing there to read, and the position must
    be the length. }
  Seek(F, RecordCount);
  EndOk := (IOR = IOR_OK);
  PosAtEnd := -1;
  EofAtEnd := False;
  if EndOk then
    begin
      PosAtEnd := FilePos(F);
      if IOR <> IOR_OK then PosAtEnd := -1;
      EofAtEnd := Eof(F);
      if IOR <> IOR_OK then EofAtEnd := False;
      EndOk := (PosAtEnd = RecordCount) and EofAtEnd;
    end;

  Close(F);
  if IOR <> IOR_OK then EndOk := False;

  writeln(RecordCount - Bad, ' of ', RecordCount,
          ' records fetched by a seek were the record asked for.');
  writeln('the walk stepped ', SeekStride,
          ' records at a time and wrapped, so it visited every record and ',
          'never two neighbours in a row.');
  writeln('position before and after each read was right every time: ',
          YesNo(PosOk), '. worst position error seen: ', WorstDelta,
          ' records.');
  writeln('after a seek to the end: position ', PosAtEnd, ' of ',
          RecordCount, ', end of file ', YesNo(EofAtEnd), '.');
  writeln('tolerance: none, and the walk is what makes that mean something. ',
          'A position wrong by a constant reads back plausible data in a ',
          'sequential test and fails every line of this one.');

  Good := (Bad = 0) and PosOk and EndOk;
  ProveSeek := Good;
  writeln('3. seek ', Verdict(Good));
end;


{****************************************************************************
  4. Text files: written, reopened, read back, and appended to.
****************************************************************************}

function ExpectedLine(I: LongInt): ShortString;
var
  Num, Body: ShortString;
begin
  Str(I, Num);
  Str(Mix(LongWord(I)), Body);
  ExpectedLine := 'line ' + Num + ' body ' + Body;
end;


function ProveTextFiles: Boolean;
var
  T: Text;
  I, Bad, Lines: LongInt;
  Res: Word;
  Got: ShortString;
  WroteOk, AppendOk, ReadOk, Good: Boolean;
begin
  writeln;
  writeln('--- 4. text files, and appending ---');

  Bad := 0;
  Lines := 0;
  WroteOk := True;
  ReadOk := True;

  Assign(T, LinesName);
  Rewrite(T);
  Res := IOR;
  if Res <> IOR_OK then
    begin
      writeln('could not create ', LinesName, ' - I/O result ', Res, '.');
      writeln('4. text files, and appending ', Verdict(False));
      ProveTextFiles := False;
      exit;
    end;
  for I := 0 to LineCount - 1 do
    begin
      writeln(T, ExpectedLine(I));
      Res := IOR;
      if Res <> IOR_OK then
        begin
          WroteOk := False;
          break;
        end;
    end;
  Close(T);
  if IOR <> IOR_OK then WroteOk := False;

  { THE APPEND IS A SECOND OPEN, and this target answers it from the length
    the open reported rather than from the beginning of the file. A file that
    came back one line long would be an append that truncated; a file with
    the new line anywhere but at the end would be an append that started at
    the wrong place. }
  Assign(T, LinesName);
  Append(T);
  Res := IOR;
  AppendOk := (Res = IOR_OK);
  if AppendOk then
    begin
      writeln(T, ExpectedLine(LineCount));
      if IOR <> IOR_OK then AppendOk := False;
      Close(T);
      if IOR <> IOR_OK then AppendOk := False;
    end
  else
    writeln('could not open ', LinesName, ' to append - I/O result ',
            Res, '.');

  Assign(T, LinesName);
  Reset(T);
  Res := IOR;
  if Res <> IOR_OK then
    begin
      writeln('could not reopen ', LinesName, ' - I/O result ', Res, '.');
      writeln('4. text files, and appending ', Verdict(False));
      ProveTextFiles := False;
      exit;
    end;

  while (Lines <= LineCount + 8) and (not Eof(T)) do
    begin
      if IOR <> IOR_OK then
        begin
          ReadOk := False;
          break;
        end;
      readln(T, Got);
      Res := IOR;
      if Res <> IOR_OK then
        begin
          ReadOk := False;
          break;
        end;
      if (Lines > LineCount) or (Got <> ExpectedLine(Lines)) then
        begin
          inc(Bad);
          if Bad = 1 then
            writeln('line ', Lines, ' came back as "', Got,
                    '" and should have been "', ExpectedLine(Lines), '".');
        end;
      inc(Lines);
    end;
  if IOR <> IOR_OK then ReadOk := False;
  Close(T);
  if IOR <> IOR_OK then ReadOk := False;

  writeln(Lines, ' lines read back. ', LineCount,
          ' were written and one more was appended, so ', LineCount + 1,
          ' were expected.');
  writeln(Lines - Bad, ' of them were the line that belongs at that place.');
  writeln('tolerance: none. Every line carries its own number and a body ',
          'derived from it, so a line in the wrong place is caught as ',
          'surely as a line with the wrong text.');

  Good := WroteOk and AppendOk and ReadOk and (Bad = 0) and
          (Lines = LineCount + 1);
  ProveTextFiles := Good;
  writeln('4. text files, and appending ', Verdict(Good));
end;


{****************************************************************************
  5. Truncate, and the length the card reports afterwards.
****************************************************************************}

function ProveTruncate: Boolean;
var
  F: file;
  S: TStamp;
  Res: Word;
  SizeAfterCut, SizeOnReopen: Int64;
  CutOk, LastOk, Good: Boolean;
begin
  writeln;
  writeln('--- 5. truncate ---');

  SizeAfterCut := -1;
  SizeOnReopen := -1;
  LastOk := False;

  Assign(F, RecordsName);
  Reset(F, RecordSize);
  Res := IOR;
  if Res <> IOR_OK then
    begin
      writeln('could not open ', RecordsName, ' - I/O result ', Res, '.');
      writeln('5. truncate ', Verdict(False));
      ProveTruncate := False;
      exit;
    end;

  Seek(F, KeepRecords);
  Res := IOR;
  CutOk := (Res = IOR_OK);
  if CutOk then
    begin
      Truncate(F);
      Res := IOR;
      CutOk := (Res = IOR_OK);
    end;
  if not CutOk then
    writeln('the cut failed - I/O result ', Res, '.')
  else
    begin
      SizeAfterCut := FileSize(F);
      if IOR <> IOR_OK then SizeAfterCut := -1;
    end;
  Close(F);
  if IOR <> IOR_OK then CutOk := False;

  { Reopened, so this length comes off the card rather than out of this
    layer's own bookkeeping. }
  Assign(F, RecordsName);
  Reset(F, RecordSize);
  if IOR = IOR_OK then
    begin
      SizeOnReopen := FileSize(F);
      if IOR <> IOR_OK then SizeOnReopen := -1;
      { The record before the cut must still be itself. A cut in the wrong
        place would leave a different one there. }
      Seek(F, KeepRecords - 1);
      if IOR = IOR_OK then
        begin
          BlockRead(F, S, 1);
          if IOR = IOR_OK then
            LastOk := StampIsRight(LongWord(KeepRecords - 1), S);
        end;
      Close(F);
      if IOR <> IOR_OK then LastOk := False;
    end;

  writeln('cut at record ', KeepRecords, ' of ', RecordCount, '.');
  writeln('while open the length was ', SizeAfterCut,
          ' records; reopened, the card says ', SizeOnReopen, '.');
  writeln('the last surviving record read back as itself: ', YesNo(LastOk),
          '.');
  writeln('tolerance: none. Both lengths must be ', KeepRecords,
          ', and the second is the card''s own answer rather than this ',
          'layer''s memory of it.');

  Good := CutOk and (SizeAfterCut = KeepRecords) and
          (SizeOnReopen = KeepRecords) and LastOk;
  ProveTruncate := Good;
  writeln('5. truncate ', Verdict(Good));
end;


{****************************************************************************
  6. What fails, and how loudly. An error is as much a part of this layer as
     a success, and an operation the file service carries no channel for has
     to say so rather than quietly do nothing.
****************************************************************************}

function ProveFailures: Boolean;
var
  F: file;
  Dir: ShortString;
  ResMissing, ResErase, ResRename: Word;
  ResRmDir, ResChDir, ResGetDir: Word;
  Good: Boolean;
begin
  writeln;
  writeln('--- 6. failures, and the operations with no channel ---');

  { A name that is not there. This is the error translation working: the
    service reports the C library's own "no such file", and this target turns
    it into Free Pascal's number for the same thing. }
  Assign(F, AbsentName);
  Reset(F, RecordSize);
  ResMissing := IOR;

  Assign(F, AbsentName);
  Erase(F);
  ResErase := IOR;

  { RENAME HAS NO CHANNEL IN THE FILE SERVICE. The C library on this board
    has one; reaching for it from here would run it on the core that does not
    own the card. So this target reports that it did nothing, and the missing
    channel is recorded against circle-libsdl2. The names are a file that
    does not exist and one that will not either. }
  Assign(F, AbsentName);
  Rename(F, RenamedName);
  ResRename := IOR;

  RmDir(WorkDir + '/no-such-dir');
  ResRmDir := IOR;

  ChDir(WorkDir);
  ResChDir := IOR;

  Dir := 'unset';
  GetDir(0, Dir);
  ResGetDir := IOR;

  writeln('open a file that is not there  -> I/O result ', ResMissing,
          ', expected ', IOR_NOT_FOUND, ' (file not found)');
  writeln('erase a file that is not there -> I/O result ', ResErase,
          ', expected ', IOR_NOT_FOUND, ' (file not found)');
  writeln('rename                         -> I/O result ', ResRename,
          ', expected ', IOR_NO_CHANNEL, ' (the service carries no rename)');
  writeln('rmdir                          -> I/O result ', ResRmDir,
          ', expected ', IOR_NO_CHANNEL, ' (the service carries no rmdir)');
  writeln('chdir                          -> I/O result ', ResChDir,
          ', expected ', IOR_NO_CHANNEL, ' (the service carries no chdir)');
  writeln('getdir                         -> I/O result ', ResGetDir,
          ', expected ', IOR_NO_CHANNEL, ' (the service carries no getcwd)');
  writeln('the directory getdir wrote back: "', Dir, '", expected empty.');
  writeln('tolerance: none, and the four with no channel matter most. ',
          'Reporting 0 for one of them would be this layer claiming a ',
          'success it did not have; reporting a card error would be it ',
          'blaming the card for a channel that was never there.');

  Good := (ResMissing = IOR_NOT_FOUND) and (ResErase = IOR_NOT_FOUND) and
          (ResRename = IOR_NO_CHANNEL) and (ResRmDir = IOR_NO_CHANNEL) and
          (ResChDir = IOR_NO_CHANNEL) and (ResGetDir = IOR_NO_CHANNEL) and
          (Dir = '');
  ProveFailures := Good;
  writeln('6. failures, and the operations with no channel ', Verdict(Good));
end;


{****************************************************************************
  7. The witness the host kernel reads, and the clearing up.
****************************************************************************}

function ProveWitnessAndCleanUp: Boolean;
var
  T: Text;
  F: file;
  Res: Word;
  WitnessOk, ErasedRecords, ErasedLines, Good: Boolean;
  StillOpen: LongWord;
begin
  writeln;
  writeln('--- 7. the witness, and clearing up ---');

  { ONE FILE IS LEFT ON THE CARD ON PURPOSE. Everything above is this program
    checking its own work through the same layer it wrote with, so a layer
    that was wrong in both directions would agree with itself. The host
    kernel reads this file afterwards, on the core that owns the card,
    through the C library directly: a different reader, on a different core,
    that has never touched this layer. What it prints is the independent half
    of the milestone. }
  Assign(T, WitnessName);
  Rewrite(T);
  Res := IOR;
  WitnessOk := (Res = IOR_OK);
  if WitnessOk then
    begin
      writeln(T, 'M5 witness written by Pascal on core ', CircleCurrentCore);
      if IOR <> IOR_OK then WitnessOk := False;
      writeln(T, 'records written ', RecordCount, ', kept ', KeepRecords);
      if IOR <> IOR_OK then WitnessOk := False;
      writeln(T, 'text lines written ', LineCount + 1);
      if IOR <> IOR_OK then WitnessOk := False;
      Close(T);
      if IOR <> IOR_OK then WitnessOk := False;
    end
  else
    writeln('could not write ', WitnessName, ' - I/O result ', Res, '.');

  Assign(F, RecordsName);
  Erase(F);
  Res := IOR;
  ErasedRecords := (Res = IOR_OK);
  if not ErasedRecords then
    writeln('could not erase ', RecordsName, ' - I/O result ', Res, '.');

  Assign(F, LinesName);
  Erase(F);
  Res := IOR;
  ErasedLines := (Res = IOR_OK);
  if not ErasedLines then
    writeln('could not erase ', LinesName, ' - I/O result ', Res, '.');

  StillOpen := CircleOpenFileCount;

  writeln('wrote ', WitnessName, ' and left it for the host kernel: ',
          YesNo(WitnessOk), '.');
  writeln('erased ', RecordsName, ': ', YesNo(ErasedRecords),
          '. erased ', LinesName, ': ', YesNo(ErasedLines), '.');
  writeln('files this layer still has open: ', StillOpen,
          '. Every file above was closed, so anything but 0 is a leaked ',
          'entry.');
  writeln(WorkDir, ' itself is left behind. The file service carries no ',
          'rmdir, so this program cannot remove a directory and does not ',
          'pretend to; the host kernel removes it on the core that owns ',
          'the card.');
  writeln('tolerance: none.');

  Good := WitnessOk and ErasedRecords and ErasedLines and (StillOpen = 0);
  ProveWitnessAndCleanUp := Good;
  writeln('7. the witness, and clearing up ', Verdict(Good));
end;


{****************************************************************************}

var
  Passed : Boolean;
  Ok     : Boolean;

begin
  writeln('M5: Pascal files on the card, through circle-libsdl2''s file ',
          'service.');
  writeln('Every section prints its own figures, its own tolerance and its ',
          'own verdict.');

  Passed := ProveTheDirectory;
  Pace;
  if not Passed then
    begin
      writeln;
      writeln('M5: FAILED at section 1. There is nowhere to work, so ',
              'nothing below it would mean anything.');
      writeln('M5: END.');
      Halt(1);
    end;

  Ok := ProveWriteThenReopen;   Passed := Ok and Passed;   Pace;
  if not Ok then
    begin
      writeln('M5: section 2 is the milestone''s own sentence. The sections ',
              'below read a file that is not what it should be.');
      Pace;
    end;

  Ok := ProveSeek;              Passed := Ok and Passed;   Pace;
  Ok := ProveTextFiles;         Passed := Ok and Passed;   Pace;
  Ok := ProveTruncate;          Passed := Ok and Passed;   Pace;
  Ok := ProveFailures;          Passed := Ok and Passed;   Pace;
  Ok := ProveWitnessAndCleanUp; Passed := Ok and Passed;   Pace;

  writeln;
  writeln('--- what this program touched ---');
  writeln('the directory ', WorkDir, ', and nothing outside it.');
  writeln('this line is on core ', CircleCurrentCore,
          ', which is where the first line was.');

  writeln;
  if Passed then
    writeln('M5: PASS. Every section above agreed.')
  else
    writeln('M5: FAIL. Read back for the section that said so.');

  writeln('M5: every file operation above went through circle-libsdl2''s ',
          'file service. This program named no device and no core.');
  writeln('M5: END.');
end.
