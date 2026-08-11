unit dynlibs;

{ DynLibs for a target that has no dynamic loader.

  Free Pascal's own DynLibs (rtl/inc/dynlibs.pas) is a thin forwarder: every
  routine in it calls the identically named routine in the System unit, which
  each operating system fills in from its own rtl/<os>/dynlibs.inc. There is no
  rtl/embedded/dynlibs.inc, and the aarch64-embedded System unit therefore
  declares none of TLibHandle, NilHandle, SharedSuffix or LoadLibrary at all.
  So DynLibs does not exist for this target, and a program that names it fails
  to compile.

  That is not a gap in the compiler install. Loading a shared library is an
  operating-system service -- a loader, a search path, relocation at run time --
  and this target has no operating system to ask. There is nothing to build.

  What there is, is a common shape of application code that asks for an
  optional library and does without it when the answer is no:

      SoundEnabled := LoadLibrary(libname) <> NilHandle;

  Code written that way needs an answer, not an absence: with the unit missing
  it will not compile, and with the unit present it takes its own no-library
  path and carries on. So this unit supplies the whole DynLibs interface and
  answers no to all of it. LoadLibrary returns NilHandle, every address lookup
  returns nil, and unloading fails because nothing was ever loaded.

  This is deliberately final rather than provisional. It is not a stub waiting
  for an implementation: there is no implementation to wait for. Anything that
  needs code from a library on this target links that code into the image.

  Nothing pulls this unit in -- circlefpc does not, because it installs run-time
  interfaces and this installs nothing. It sits on the unit path that
  fpc-app.mk already sets up, and it is compiled only if a program says
  `uses DynLibs`. }

{$mode objfpc}
{$H+}

interface

type
  TLibHandle = PtrUInt;
  HModule = TLibHandle;
  TOrdinalEntry = SizeUInt;

const
  NilHandle = TLibHandle(0);

  { Every other target names the extension its shared libraries carry -- 'so',
    'dll', 'dylib'. There is no such file here, so this names none, and a name
    built by appending it is a name nothing will find either way. }
  SharedSuffix = '';

function SafeLoadLibrary(const Name: RawByteString): TLibHandle;
function LoadLibrary(const Name: RawByteString): TLibHandle;
function SafeLoadLibrary(const Name: UnicodeString): TLibHandle;
function LoadLibrary(const Name: UnicodeString): TLibHandle;

function GetProcedureAddress(Lib: TLibHandle; const ProcName: AnsiString): Pointer;
function GetProcedureAddress(Lib: TLibHandle; Ordinal: TOrdinalEntry): Pointer;
function UnloadLibrary(Lib: TLibHandle): Boolean;
function GetLoadErrorStr: AnsiString;

{ Kylix and Delphi spell two of them differently, and the real unit carries
  both spellings. }
function FreeLibrary(Lib: TLibHandle): Boolean;
function GetProcAddress(Lib: TLibHandle; const ProcName: AnsiString): Pointer;

implementation

function SafeLoadLibrary(const Name: RawByteString): TLibHandle;
begin
  Result := NilHandle;
end;

function LoadLibrary(const Name: RawByteString): TLibHandle;
begin
  Result := NilHandle;
end;

function SafeLoadLibrary(const Name: UnicodeString): TLibHandle;
begin
  Result := NilHandle;
end;

function LoadLibrary(const Name: UnicodeString): TLibHandle;
begin
  Result := NilHandle;
end;

function GetProcedureAddress(Lib: TLibHandle; const ProcName: AnsiString): Pointer;
begin
  Result := nil;
end;

function GetProcedureAddress(Lib: TLibHandle; Ordinal: TOrdinalEntry): Pointer;
begin
  Result := nil;
end;

function UnloadLibrary(Lib: TLibHandle): Boolean;
begin
  Result := False;
end;

function GetLoadErrorStr: AnsiString;
begin
  Result := 'this target has no dynamic loader';
end;

function FreeLibrary(Lib: TLibHandle): Boolean;
begin
  Result := False;
end;

function GetProcAddress(Lib: TLibHandle; const ProcName: AnsiString): Pointer;
begin
  Result := nil;
end;

end.
