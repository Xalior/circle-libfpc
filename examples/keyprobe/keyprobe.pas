{
  keyprobe.pas -- proves whether a keypress reaches a Pascal program that
  never initialises SDL.

  On this target the keyboard is normally brought up by circle-libsdl2,
  inside SDL2Circle_ArmCoreRuntime, and read through SDL's event queue. This
  program never calls that: no SDL unit, no SDL_Init, no window. It reads
  the standard input the C library binds on descriptors 0, 1 and 2 -- the
  same descriptors the host kernel arms before this program's entry point
  is ever called -- through nothing but Pascal's own Read.

  It prints one line at start, then loops: each character it manages to
  read from Input is echoed back with its ordinal value, and a heartbeat
  line marks the passage of a few seconds so a run that is receiving
  nothing can be told apart from one that has stopped.
}
program keyprobe;

{$mode objfpc}
{$H+}

const
  { How often the heartbeat is due, and how long the loop rests between
    read attempts. Read does not block on this target -- see the report
    this program's build produced -- so the rest is what keeps the loop
    from spinning the core flat out on a channel that is not coming. }
  HeartbeatMicros = 3000000;
  RestMicros      = 100000;

var
  HeartbeatTicks: QWord;
  Due: QWord;
  C: Char;
  Status: LongInt;

begin
  writeln('KEYPROBE: running, no SDL, reading standard input directly.');

  HeartbeatTicks := (CircleCounterFrequency * HeartbeatMicros) div 1000000;
  Due := CircleCounter + HeartbeatTicks;

  while true do
    begin
      {$I-}
      Read(C);
      {$I+}
      Status := IOResult;
      if Status = 0 then
        writeln('KEYPROBE: read one character, ordinal ', Ord(C))
      else
        CircleWaitMicroseconds(RestMicros);

      if CircleCounter >= Due then
        begin
          writeln('KEYPROBE: heartbeat, still running, last Read IOResult=',
                  Status);
          Due := CircleCounter + HeartbeatTicks;
        end;
    end;
end.
