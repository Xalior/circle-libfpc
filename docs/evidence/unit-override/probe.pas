program probe;

{ The smallest program that reaches the SysUtils file family through the two
  routes an application normally uses: a TFileStream, and a FindFirst walk.
  Neither call has to succeed. The program is never run — it exists so that
  the compiler pulls Classes and SysUtils into a link, and so that the file
  functions the patched unit redirects are genuinely referenced. }

{$mode objfpc}{$H+}

uses
  Classes, SysUtils;

var
  s: TFileStream;
  buf: array[0..15] of byte;
  n: LongInt;
  sr: TSearchRec;
  found: LongInt;
  d: Boolean;

begin
  s := TFileStream.Create('/x', fmOpenRead);
  n := s.Read(buf, SizeOf(buf));
  s.Free;

  found := FindFirst('/*', faAnyFile, sr);
  while found = 0 do
    found := FindNext(sr);
  FindClose(sr);

  d := DirectoryExists('/x');
end.
