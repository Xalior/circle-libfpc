{
  m2.pas — the smallest Pascal program that proves its output arrived.

  Everything it writes is written the way a Pascal program writes: writeln,
  the standard text files, and no call out of the language at all. Where that
  output goes is the runtime's business, and on this target the runtime hands
  each line to circle-libsdl2's log channel. The program is not aware of that,
  which is the point — it is a program on a single-core machine with SDL
  underneath, exactly as a desktop build is.

  NOTHING HERE ALLOCATES. Every value below is written through a path that
  asks the heap for nothing: a string literal reaches the runtime as a short
  string, and an integer, a character and a boolean are each turned into one
  before they are written. That was a requirement when this example was
  written, because the memory manager was a later milestone; it is now simply
  what this example is, which is writing and nothing else. Allocation has an
  example of its own in m1.
}
program m2;

begin
  writeln('M2: this line was written by Pascal.');

  { A short string, an integer, a character and a boolean in one statement.
    The runtime turns each into characters in the text file's own buffer,
    which lives inside the text record and never came from a heap. }
  writeln('integer ', 42, ', character ', 'x', ', boolean ', true);

  { Field widths are the same path with blanks in front. }
  writeln('right aligned: [', 7:4, ']');

  { write leaves a line unfinished. The log channel takes output in whatever
    pieces it was given and publishes a line only when the line completes, so
    these two statements arrive on the console as one line. }
  write('two halves of ');
  writeln('one line');

  { The standard error file is opened on its own handle and the log prints it
    under its own tag, so the two are told apart on the console. }
  writeln(StdErr, 'and this one went to standard error.');
end.
