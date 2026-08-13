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
  read from Input is echoed back with its ordinal value. Read blocks, like
  any other target's console read, so the loop otherwise sits inside it --
  a run with nothing typed is silent rather than spinning, and the
  heartbeat below is what a serial console still sees while it waits.
}
program keyprobe;

{$mode objfpc}
{$H+}

const
  { How often the heartbeat is due. Read blocks until a key arrives, so the
    heartbeat is only checked between read returns -- it marks time passing
    across keypresses, not while none has come. }
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
