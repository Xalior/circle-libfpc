{
  readlnprobe.pas -- proves that plain ReadLn, the stock Pascal keyword every
  author already knows, reads an edited line from standard input on this
  target: backspace removes the character behind it, on screen and in what
  the program receives, and what is on screen when Enter is pressed is
  exactly what this program reads back.

  There is no routine of this project's own here, and none to learn: this is
  System.ReadLn, unchanged, on a String variable, exactly as it is written in
  any Pascal program on any other platform. The editing that makes backspace
  work is inside Do_Read (fpc/rtl/circlesdl2/sysfile.inc), the routine every
  target's runtime reads its console through -- ReadLn never knows it is
  there.

  Like keyprobe beside it, this program never initialises SDL and reads
  nothing but standard input.

  It prints one line at start, then loops: each line ReadLn hands back is
  echoed with its length, so a line with mistakes typed and then corrected
  before Enter shows the CORRECTED text, not the keys pressed.
}
program readlnprobe;

{$mode objfpc}
{$H+}

var
  Line: String;

begin
  writeln('READLNPROBE: running, no SDL, reading a line with ReadLn.');

  while true do
    begin
      ReadLn(Line);
      writeln('READLNPROBE: received "', Line, '" (', Length(Line), ' chars)');
    end;
end.
