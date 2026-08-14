{
  lineprobe.pas -- proves that a line typed at standard input arrives
  edited: backspace removes the character behind it, on screen and in what
  the program receives, and what is on screen when Enter is pressed is
  exactly what this program prints back.

  Like keyprobe beside it, this program never initialises SDL and reads
  nothing but standard input. Where keyprobe proves a single character
  arrives the instant its key is pressed, this one proves a LINE arrives
  edited: it calls CircleReadLine, which is built on the same instant,
  one-character-at-a-time primitive keyprobe reads through, and does its own
  echo and its own backspace handling on top of it (fpc/rtl/circlesdl2/
  sysfile.inc says why that has to be a separate routine rather than plain
  ReadLn: a single character read and a line read share the same low-level
  read on this target, with nothing that tells them apart, so only a routine
  built to assemble a line -- never handed a character it has already given
  away -- can let backspace undo one).

  It prints one line at start, then loops: each line CircleReadLine hands
  back is echoed with its length, so a line with mistakes typed and then
  corrected before Enter shows the CORRECTED text, not the keys pressed.
}
program lineprobe;

{$mode objfpc}
{$H+}

var
  Line: String;

begin
  writeln('LINEPROBE: running, no SDL, reading an edited line from standard input.');

  while true do
    begin
      Line := CircleReadLine;
      writeln('LINEPROBE: received "', Line, '" (', Length(Line), ' chars)');
    end;
end.
