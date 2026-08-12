{
  m3.pas — the Pascal program that proves time.

  What this milestone asks for is a loop running at a measured, known rate.
  That is a short sentence with three separate claims inside it, and this
  program takes them one at a time, because they fail in different ways and
  a program that ran them together could not say which had gone wrong.

    - that there is a clock at all, and that it only ever goes forwards;
    - that what it reports is PROPORTIONAL to the work done, so the number
      tracks the loop rather than merely growing while the loop runs;
    - that the SCALE of that number is right, so a stated interval is the
      interval a second opinion would also report;
    - and that a wait asked for a length of time waits that length.

  WHERE THE CLOCK COMES FROM. Elapsed time on this board is the Arm generic
  timer's free-running counter, read directly. It is a processor system
  register here, one per core, so the application core reads it with an
  instruction: no device, no lock, no other core. That is what makes it the
  one part of time this library answers for itself. The other part is calendar
  time — the date a saved file is stamped with — which is Circle's timer
  object, and an object is a device, so it goes through circle-libsdl2. This
  program does not touch calendar time and does not need it.

  IT ALL HAS TO BE READ OFF THE SERIAL CONSOLE, and every section ends in a
  verdict word — PASS or FAIL — worked out by the program, with the tolerance
  it was judged against printed beside it. A section that faults instead of
  printing its verdict is a failure of that section, and the sections are
  ordered so that the last line printed says how far it got.

  THE MEASUREMENT HAS A CONTROL, and it is the same trap M1's example fell
  into. Time passes whether or not a Pascal program does anything, so an
  elapsed figure is not by itself evidence that Pascal caused it. The loop
  section therefore measures the identical bracket around a loop of NO
  iterations, first, and reports it. Everything else in that section is read
  as the difference from it, and a control that is not far smaller than the
  measurements fails the section outright.

  THE INSTRUMENT IS INSIDE THE THING BEING MEASURED, twice over. Reading the
  counter costs time, and it is the counter read that brackets every interval
  here — so the read cost is measured and printed. Printing costs time as
  well, and printing is how this program says anything — so no timed region
  below contains a writeln, and what a writeln costs is measured on its own
  and printed as a figure in its own right.

  NOTHING HERE IS FLOATING POINT. Every figure is worked out in 64 bit
  integers and formatted by hand, so that no result depends on how this target
  treats a real number.
}
program m3;

{$mode objfpc}
{$H+}

const
  { The base amount of work one timed loop does. Chosen so that the shortest
    measurement is still tens of thousands of times the cost of reading the
    counter, and the longest is under a fifth of a second. }
  BaseIterations = 4000000;

  { What each verdict allows, in hundredths of a percent, and why.

    The application core runs one line of execution with nothing to preempt
    it, and the host kernel pins the processor clock at its maximum before the
    core is released, so a loop over registers has nothing left to vary except
    the counter reads that bracket it. Two percent is a hundred times that and
    still far below any real failure, which would be a factor rather than a
    few percent. }
  RateTolerance   = 200;   { 2.00% — one loop against another }
  RepeatTolerance = 200;   { 2.00% — the same loop measured again }

  { The cross-check against circle-libsdl2 is tighter, because the two answers
    come from the same two registers and differ only in the arithmetic done
    to them. What is allowed is the bracket — this program's two counter reads
    sit outside the library's two — plus the microsecond the library truncates
    to at each end. }
  ScaleToleranceHundredths = 1;    { 0.01% }
  ScaleToleranceMicros     = 10;

  { How far past its deadline a wait may return. The waiting loop's grain is
    one counter read and one yield hint, which is tens of nanoseconds, so
    fifty microseconds is a thousandfold margin — and it is still small enough
    that a wait which overshot by anything a scheduler would recognise as a
    tick could not pass. A wait is never allowed to be short by any amount:
    a wait that returns early is the failure nothing downstream can see. }
  WaitOvershootMicros = 50;

  { What one writeln may cost the application core. At the console's 115200
    baud a line of sixty characters takes about five milliseconds on the wire.
    The log channel exists so that the application core does not pay that: it
    formats into a ring and returns, and the core that owns the serial device
    drains it. So a millisecond a line is the line between the two designs —
    below it the core is paying for memory, at or above it the core is paying
    for the wire, and every figure in this program would be contaminated. }
  PrintCostMicros = 1000;

  { The pause between sections. The log channel never blocks and drops a line
    it has no room for, and the console is far slower than this core, so a
    program that prints a long burst can outrun the wire and lose the middle
    of its own report. Pausing lets the drain catch up. It also puts the wait
    under test in front of every section that follows it. }
  PaceMicros = 250000;

  { The off-board mark. Ten seconds is long enough that a clock on the other
    side of the serial line can measure it to a percent. }
  OffBoardMicros = 10000000;

var
  { Read once, checked, and used by every conversion below. }
  CounterHz: QWord;

  { The counter at the first line of the program, so that the last line can
    say the whole run went forwards. }
  RunStart: QWord;


{ circle-libsdl2's own answer to the same question, declared here rather than
  in the runtime because it is not what this target's elapsed time is built
  on — it is the second opinion this program checks that answer against.

  It is SDL_GetPerformanceCounter, and on this platform the library serves it
  from Circle's CTimer::GetClockTicks64, which reads the same two registers
  this runtime reads and scales them to microseconds as it goes. So it is an
  independent implementation and an independent piece of arithmetic, over the
  same hardware. What it can catch is a wrong scale on this side. What it
  cannot catch is the counter itself running at a rate other than the one the
  firmware recorded, because both answers would be wrong together. Section 8
  is where that question is asked. }
function SDL_GetPerformanceCounter: QWord;
  cdecl; external name 'SDL_GetPerformanceCounter';
function SDL_GetPerformanceFrequency: QWord;
  cdecl; external name 'SDL_GetPerformanceFrequency';


{****************************************************************************
                        Arithmetic and formatting
****************************************************************************}

{ Ticks to nanoseconds, exactly, for any span this program measures.

  The direct form, ticks * 1000000000 / frequency, overflows a 64 bit register
  at about eighteen seconds of counted time and says nothing when it does.
  Taking the whole seconds out first leaves a remainder below one second, and
  one second of ticks multiplied by a thousand million cannot overflow at any
  frequency this counter could be running at. }
function TicksToNs(Ticks: QWord): QWord;
begin
  if CounterHz = 0 then
    begin
      Result := 0;
      exit;
    end;
  Result := (Ticks div CounterHz) * 1000000000 +
            ((Ticks mod CounterHz) * 1000000000) div CounterHz;
end;


{ The same span in microseconds, to three decimal places, as text. One unit is
  used for every duration this program prints, from a counter read to ten
  seconds, so that no line has to be converted before it can be compared with
  another. }
function UsText(Ticks: QWord): ShortString;
var
  Ns: QWord;
  Digits: ShortString;
begin
  Ns := TicksToNs(Ticks);
  Str(Ns div 1000, Result);
  Str(Ns mod 1000, Digits);
  while Length(Digits) < 3 do
    Digits := '0' + Digits;
  Result := Result + '.' + Digits + ' us';
end;


{ How far one figure is from another, signed, as a percentage to two decimal
  places. }
function DeviationText(Value, Reference: QWord): ShortString;
var
  Difference, Hundredths: QWord;
  Sign, Digits: ShortString;
begin
  if Reference = 0 then
    begin
      Result := 'n/a';
      exit;
    end;
  if Value >= Reference then
    begin
      Difference := Value - Reference;
      Sign := '+';
    end
  else
    begin
      Difference := Reference - Value;
      Sign := '-';
    end;
  Hundredths := (Difference * 10000) div Reference;
  Str(Hundredths div 100, Result);
  Str(Hundredths mod 100, Digits);
  while Length(Digits) < 2 do
    Digits := '0' + Digits;
  Result := Sign + Result + '.' + Digits + '%';
end;


{ The same comparison as a test, in the same hundredths of a percent the
  tolerances above are written in. }
function WithinTolerance(Value, Reference, Hundredths: QWord): Boolean;
var
  Difference: QWord;
begin
  if Reference = 0 then
    begin
      Result := False;
      exit;
    end;
  if Value >= Reference then
    Difference := Value - Reference
  else
    Difference := Reference - Value;
  Result := (Difference * 10000) div Reference <= Hundredths;
end;


{ Picoseconds per iteration. Nanoseconds per iteration would be a single digit
  on this processor, which cannot be compared to two percent; picoseconds keep
  three. }
function PsPerIteration(Ticks, Iterations: QWord): QWord;
begin
  if Iterations = 0 then
    Result := 0
  else
    Result := (TicksToNs(Ticks) * 1000) div Iterations;
end;


{ The deadline a wait of this length should reach, in ticks, worked out here
  rather than taken from the runtime. Doing the arithmetic a second time is
  the point: a wait judged only by the routine that computed its own deadline
  would agree with itself whatever it did. }
function RequestedTicks(Microseconds: QWord): QWord;
var
  Seconds, Fraction: QWord;
begin
  Seconds  := Microseconds div 1000000;
  Fraction := Microseconds mod 1000000;
  Result   := Seconds * CounterHz + (Fraction * CounterHz) div 1000000;
  if (Fraction * CounterHz) mod 1000000 <> 0 then
    Inc(Result);
end;


function Verdict(Passed: Boolean): ShortString;
begin
  if Passed then
    Result := 'PASS'
  else
    Result := 'FAIL';
end;


{ Give the console time to catch up with the last section. Never called from
  inside anything being measured. }
procedure Pace;
begin
  CircleWaitMicroseconds(PaceMicros);
end;


{****************************************************************************
                              The work
****************************************************************************}

{ THE LOOP WHOSE RATE IS BEING MEASURED.

  It touches no memory beyond its own two registers, calls nothing, and
  allocates nothing, so what it costs is the processor executing instructions
  and nothing else on the board can lend it a hand or get in its way.

  WHAT MAKES THE WORK KNOWN. The sum of the first N whole numbers has a closed
  form, so the caller can say what the answer must be without doing the work
  again. A loop that ran the wrong number of times, or that a compiler turned
  into something other than what is written here, is caught by the checksum
  rather than by the clock — which matters, because a loop that did no work at
  all would report a very good rate. }
function WorkLoop(Iterations: LongWord): QWord;
var
  I: LongWord;
  Accumulator: QWord;
begin
  Accumulator := 0;
  for I := 1 to Iterations do
    Accumulator := Accumulator + QWord(I);
  Result := Accumulator;
end;


function ExpectedSum(Iterations: QWord): QWord;
begin
  Result := (Iterations * (Iterations + 1)) div 2;
end;


{ One timed run of the loop, bracketed exactly the way every other one is.
  The checksum is handed back rather than checked here, so that the bracket
  contains the loop and nothing else. }
function TimeWorkLoop(Iterations: LongWord; out Checksum: QWord): QWord;
var
  Started, Stopped: QWord;
begin
  Started  := CircleCounter;
  Checksum := WorkLoop(Iterations);
  Stopped  := CircleCounter;
  Result   := Stopped - Started;
end;


{****************************************************************************
   1. There is a clock, and this is how finely it counts
****************************************************************************}

function ProveTheCounterExists: Boolean;
var
  Again: QWord;
  Sane, Stable: Boolean;
  PicosecondsPerTick: QWord;
begin
  writeln;
  writeln('--- 1. the counter, and its resolution ---');

  CounterHz := CircleCounterFrequency;
  Again     := CircleCounterFrequency;

  { The register records the frequency the counter was wired to run at; it is
    written by the firmware at boot and cannot change afterwards. A second
    read that disagrees means this is not that register. }
  Stable := CounterHz = Again;

  { Anything outside this range is not a generic timer frequency. The boards
    this library is built for run the counter at 19.2 MHz or 54 MHz, and the
    failure being caught is a register left at zero, which would make every
    figure below meaningless while looking like an answer. }
  Sane := (CounterHz >= 1000000) and (CounterHz <= 1000000000);

  writeln('counter frequency : ', CounterHz, ' ticks per second');
  if CounterHz > 0 then
    begin
      PicosecondsPerTick := 1000000000000 div CounterHz;
      writeln('resolution        : one tick = ', PicosecondsPerTick,
              ' ps; nothing below this can be measured');
    end;
  writeln('read twice, same  : ', Stable);
  writeln('wrap              : the counter is at least 56 bits wide, so at ',
          'this rate it is decades from wrapping');
  writeln('1. counter ', Verdict(Sane and Stable),
          '  (tolerance: none - the frequency is a constant, not a ',
          'measurement)');
  Result := Sane and Stable;
end;


{****************************************************************************
   2. It only goes forwards, and this is what reading it costs
****************************************************************************}

function ProveItAdvances: Boolean;
const
  Samples = 200000;
var
  I: LongInt;
  First, Previous, Current, Last: QWord;
  Step, Smallest, Largest: QWord;
  Backwards, Stalled: LongInt;
  Advanced, NeverBack: Boolean;
begin
  writeln;
  writeln('--- 2. it advances, and never backwards ---');

  Backwards := 0;
  Stalled   := 0;
  Smallest  := High(QWord);
  Largest   := 0;

  First    := CircleCounter;
  Previous := First;
  for I := 1 to Samples do
    begin
      Current := CircleCounter;
      if Current < Previous then
        Inc(Backwards)
      else
        begin
          Step := Current - Previous;
          if Step = 0 then
            Inc(Stalled);
          if Step < Smallest then
            Smallest := Step;
          if Step > Largest then
            Largest := Step;
        end;
      Previous := Current;
    end;
  Last := Previous;

  Advanced  := Last > First;
  NeverBack := Backwards = 0;

  writeln('samples           : ', Samples, ' consecutive reads');
  writeln('went backwards    : ', Backwards, ' times');
  writeln('did not move      : ', Stalled, ' times');
  writeln('step between two  : smallest ', Smallest, ', largest ', Largest,
          ' ticks');
  { Reading the counter is the whole of the work between two samples, so the
    span divided by the count is what one read costs — barrier, register read,
    loop and all. It is the weight of the instrument, and it is charged to
    every interval this program reports. }
  writeln('so one read costs : ', UsText((Last - First) div Samples),
          ' on average');
  writeln('2. advances ', Verdict(Advanced and NeverBack),
          '  (tolerance: none - a counter that goes backwards is not a clock)');
  Result := Advanced and NeverBack;
end;


{****************************************************************************
   3. The measured time is proportional to the work, and the control
      says the work is what caused it
****************************************************************************}

function ProveTheRate: Boolean;
var
  Idle, T1, T2, T4, T8: QWord;
  C0, C1, C2, C4, C8: QWord;
  R1, R2, R4, R8: QWord;
  Sums, Attributable, Proportional: Boolean;
begin
  writeln;
  writeln('--- 3. the rate: time in proportion to work ---');

  { Warm first, and throw the figure away. The first pass through any loop on
    this processor also fills the instruction cache, and that cost belongs to
    the first pass rather than to the loop. }
  WorkLoop(BaseIterations);

  { THE CONTROL, AND THE REASON THE ROWS BELOW CAN BE READ AT ALL. The same
    bracket, the same call, the same return — and no iterations inside it. Time
    passes on this board whether Pascal runs or not, so whatever this row
    reports is what the measurement costs rather than what the loop costs. }
  Idle := TimeWorkLoop(0, C0);

  T1 := TimeWorkLoop(BaseIterations,     C1);
  T2 := TimeWorkLoop(BaseIterations * 2, C2);
  T4 := TimeWorkLoop(BaseIterations * 4, C4);
  T8 := TimeWorkLoop(BaseIterations * 8, C8);

  { The work is known, so it is checked rather than assumed. }
  Sums := (C0 = 0) and
          (C1 = ExpectedSum(BaseIterations)) and
          (C2 = ExpectedSum(BaseIterations * 2)) and
          (C4 = ExpectedSum(BaseIterations * 4)) and
          (C8 = ExpectedSum(BaseIterations * 8));

  R1 := PsPerIteration(T1 - Idle, BaseIterations);
  R2 := PsPerIteration(T2 - Idle, BaseIterations * 2);
  R4 := PsPerIteration(T4 - Idle, BaseIterations * 4);
  R8 := PsPerIteration(T8 - Idle, BaseIterations * 8);

  writeln('control, 0 iters  : ', UsText(Idle),
          '   <- the bracket with no loop in it');
  writeln(BaseIterations,     ' iters : ', UsText(T1), '  ', R1, ' ps each');
  writeln(BaseIterations * 2, ' iters : ', UsText(T2), '  ', R2, ' ps each');
  writeln(BaseIterations * 4, ' iters : ', UsText(T4), '  ', R4, ' ps each');
  writeln(BaseIterations * 8, ' iters : ', UsText(T8), '  ', R8, ' ps each');
  writeln('checksums match the closed form = ', Sums);
  writeln('deviation from the longest run : ',
          DeviationText(R1, R8), ' ', DeviationText(R2, R8), ' ',
          DeviationText(R4, R8));

  { The control has to be negligible, not merely smaller. A thousandth of the
    longest run is the line: above it, some part of what is being reported is
    the measurement rather than the loop. }
  Attributable := Idle * 1000 < T8;
  writeln('control is under a thousandth of the longest run = ', Attributable);

  Proportional := WithinTolerance(R1, R8, RateTolerance) and
                  WithinTolerance(R2, R8, RateTolerance) and
                  WithinTolerance(R4, R8, RateTolerance);

  writeln('3. rate ', Verdict(Sums and Attributable and Proportional),
          '  (tolerance: 2.00% per iteration across an eightfold change in ',
          'work)');
  Result := Sums and Attributable and Proportional;
end;


{****************************************************************************
   4. Measuring it again gives the same answer
****************************************************************************}

function ProveItRepeats: Boolean;
const
  Runs       = 5;
  Iterations = BaseIterations * 4;
var
  Rate: array[1..Runs] of QWord;
  Checksum: QWord;
  I: LongInt;
  Smallest, Largest: QWord;
  Steady, Sums: Boolean;
begin
  writeln;
  writeln('--- 4. the same loop, measured five times ---');

  Sums     := True;
  Smallest := High(QWord);
  Largest  := 0;
  for I := 1 to Runs do
    begin
      Rate[I] := PsPerIteration(TimeWorkLoop(Iterations, Checksum),
                                Iterations);
      if Checksum <> ExpectedSum(Iterations) then
        Sums := False;
      if Rate[I] < Smallest then
        Smallest := Rate[I];
      if Rate[I] > Largest then
        Largest := Rate[I];
    end;

  writeln(Iterations, ' iterations, picoseconds each:');
  writeln('  ', Rate[1], '  ', Rate[2], '  ', Rate[3], '  ', Rate[4],
          '  ', Rate[5]);
  writeln('spread            : ', Largest - Smallest, ' ps, which is ',
          DeviationText(Largest, Smallest), ' of the fastest run');
  writeln('same work each time = ', Sums);

  Steady := WithinTolerance(Largest, Smallest, RepeatTolerance);
  writeln('4. repeatable ', Verdict(Steady and Sums),
          '  (tolerance: 2.00% between the fastest and slowest of five)');
  Result := Steady and Sums;
end;


{****************************************************************************
   5. The scale is right, against a second opinion
****************************************************************************}

function ProveTheScale: Boolean;
const
  Iterations = BaseIterations * 8;
var
  OurStart, OurStop, ShimStart, ShimStop: QWord;
  Checksum, OurMicros, ShimMicros, Allowed: QWord;
  Agrees, ShimFrequency: Boolean;
begin
  writeln;
  writeln('--- 5. the scale, against circle-libsdl2''s own answer ---');

  { The library's reads sit inside this program's, so its span is the shorter
    one by two counter reads. }
  OurStart  := CircleCounter;
  ShimStart := SDL_GetPerformanceCounter;
  Checksum  := WorkLoop(Iterations);
  ShimStop  := SDL_GetPerformanceCounter;
  OurStop   := CircleCounter;

  OurMicros  := TicksToNs(OurStop - OurStart) div 1000;
  ShimMicros := ShimStop - ShimStart;

  { The library states its own unit, and this program checks that statement
    rather than assuming it: an answer in the wrong unit would agree to a
    factor of a thousand and nothing here would say so. }
  ShimFrequency := SDL_GetPerformanceFrequency = 1000000;

  Allowed := (ShimMicros * ScaleToleranceHundredths) div 10000 +
             ScaleToleranceMicros;

  writeln('this runtime      : ', OurMicros, ' us');
  writeln('circle-libsdl2    : ', ShimMicros, ' us  (its counter runs at ',
          SDL_GetPerformanceFrequency, ' per second)');
  writeln('difference        : ', DeviationText(OurMicros, ShimMicros),
          ', allowed ', Allowed, ' us');
  writeln('checksum          : ', Checksum = ExpectedSum(Iterations));
  writeln('BOTH READ THE SAME TWO REGISTERS. This catches wrong arithmetic ',
          'on this side.');
  writeln('It cannot catch the counter itself running at another rate - ',
          'section 8 asks that.');

  if OurMicros >= ShimMicros then
    Agrees := (OurMicros - ShimMicros) <= Allowed
  else
    Agrees := (ShimMicros - OurMicros) <= Allowed;
  Agrees := Agrees and ShimFrequency and
            (Checksum = ExpectedSum(Iterations));

  writeln('5. scale ', Verdict(Agrees),
          '  (tolerance: 0.01% of the interval, plus 10 us for the bracket ',
          'and the rounding at each end)');
  Result := Agrees;
end;


{****************************************************************************
   6. A wait waits the length it was asked for
****************************************************************************}

function ProveOneWait(Microseconds: QWord): Boolean;
var
  Started, Stopped, ShimStart, ShimStop: QWord;
  Measured, Wanted, Overshoot: QWord;
  NotShort, NotLong: Boolean;
begin
  Started   := CircleCounter;
  ShimStart := SDL_GetPerformanceCounter;
  CircleWaitMicroseconds(Microseconds);
  ShimStop  := SDL_GetPerformanceCounter;
  Stopped   := CircleCounter;

  Measured  := Stopped - Started;
  Wanted    := RequestedTicks(Microseconds);
  Overshoot := RequestedTicks(WaitOvershootMicros);

  NotShort := Measured >= Wanted;
  NotLong  := Measured <= Wanted + Overshoot;

  writeln('  asked ', Microseconds, ' us : measured ', UsText(Measured),
          ', circle-libsdl2 saw ', ShimStop - ShimStart, ' us, ',
          DeviationText(Measured, Wanted));
  Result := NotShort and NotLong;
end;


function ProveTheWait: Boolean;
var
  Ok: Boolean;
begin
  writeln;
  writeln('--- 6. a timed wait ---');
  writeln('the deadline is recomputed here from the frequency, so the wait ',
          'is not judged by its own arithmetic');

  Ok := ProveOneWait(1000);
  Ok := ProveOneWait(10000) and Ok;
  Ok := ProveOneWait(100000) and Ok;
  Ok := ProveOneWait(1000000) and Ok;

  writeln('6. wait ', Verdict(Ok),
          '  (tolerance: never short by any amount; never more than 50 us ',
          'long)');
  Result := Ok;
end;


{****************************************************************************
   7. What the instrument costs when it speaks
****************************************************************************}

function ProveWhatPrintingCosts: Boolean;
const
  Lines = 8;
var
  Started, Stopped, Spent, PerLine: QWord;
  I: LongInt;
  CheapEnough: Boolean;
begin
  writeln;
  writeln('--- 7. what a writeln costs this core ---');

  Started := CircleCounter;
  for I := 1 to Lines do
    writeln('  timed line ', I, ' of ', Lines,
            ' - a missing number here is the console being outrun');
  Stopped := CircleCounter;

  Spent   := Stopped - Started;
  PerLine := Spent div Lines;

  writeln('total             : ', UsText(Spent), ' for ', Lines, ' lines');
  writeln('per line          : ', UsText(PerLine));
  writeln('at 115200 baud a line of that length takes about 5000 us on the ',
          'wire, so this core is not paying for the wire');

  CheapEnough := TicksToNs(PerLine) < PrintCostMicros * 1000;
  writeln('7. print cost ', Verdict(CheapEnough),
          '  (tolerance: under 1000 us a line, which is where the core ',
          'would start paying for the console)');
  Result := CheapEnough;
end;


{****************************************************************************
   8. The one reference that is not this board's own oscillator
****************************************************************************}

procedure TheOffBoardMark;
var
  Started, Stopped: QWord;
begin
  writeln;
  writeln('--- 8. ten seconds, for a clock on the other side of the wire ---');
  writeln('EVERY FIGURE ABOVE COMES FROM ONE OSCILLATOR. The counter and ',
          'circle-libsdl2 read the');
  writeln('same registers, so neither can say whether that oscillator runs ',
          'at the rate the firmware');
  writeln('recorded. Nothing on this board can. The two marks below are ten ',
          'seconds apart by this');
  writeln('runtime''s reckoning, and whoever is capturing this line has the ',
          'only independent clock.');

  writeln('OFFBOARD MARK A');
  Started := CircleCounter;
  CircleWaitMicroseconds(OffBoardMicros);
  Stopped := CircleCounter;
  writeln('OFFBOARD MARK B');

  writeln('this runtime made that ', UsText(Stopped - Started),
          ', asked for ', OffBoardMicros, ' us');
  writeln('8. offboard NO VERDICT - the capture''s own timestamps decide ',
          'this one, allow a few tenths of a second for the console');
end;


{****************************************************************************}

var
  Passed: Boolean;
  RunEnd: QWord;

begin
  RunStart := CircleCounter;

  writeln('M3: elapsed time, on the free-running counter, read directly.');
  writeln('Every section prints its own figures, its own tolerance and its ',
          'own verdict.');

  { Section 1 settles whether there is a clock at all, and everything after it
    converts ticks with what it found. A program that carried on past a
    frequency of zero would print a page of confident nonsense. }
  Passed := ProveTheCounterExists;
  Pace;

  if not Passed then
    begin
      writeln;
      writeln('M3: FAILED at section 1. There is no clock to measure with, ',
              'so nothing below it would mean anything. END.');
      Halt(1);
    end;

  Passed := ProveItAdvances and Passed;             Pace;
  Passed := ProveTheRate and Passed;                Pace;
  Passed := ProveItRepeats and Passed;              Pace;
  Passed := ProveTheScale and Passed;               Pace;
  Passed := ProveTheWait and Passed;                Pace;
  Passed := ProveWhatPrintingCosts and Passed;      Pace;
  TheOffBoardMark;

  RunEnd := CircleCounter;

  writeln;
  writeln('the whole run took ', UsText(RunEnd - RunStart),
          ', and the counter went forwards throughout = ', RunEnd > RunStart);
  if Passed and (RunEnd > RunStart) then
    writeln('M3: every section above passed. END.')
  else
    writeln('M3: AT LEAST ONE SECTION ABOVE FAILED - read back for the ',
            'FAIL. END.');
end.
