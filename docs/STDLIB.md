# The standard library

**A program is written in more than the runtime library**, and Free Pascal
keeps most of that in its packages. Those are built for this target: the whole
of `rtl-objpas` (`DateUtils`, `StrUtils`, `Variants`, `RTTI`, `FmtBCD` and the
rest), `fcl-base` (`IniFiles`, `contnrs`, `SyncObjs`, `CustApp`, `URIParser`,
the CSV and expression parsers), `rtl-generics` (`Generics.Collections`),
`fcl-stl`, `hash`, `paszlib`, `bzip2`, `fcl-json`, `fcl-xml`, `fcl-image` with
`pasjpeg` under it, `regexpr`, `libtar`, `unzip`, `symbolic`, `tplylib`, and
the machine-independent part of `rtl-extra` (`objects`, `matrix`, `ucomplex`,
`real48utils`).

Which packages build for a target is each package's own `fpmake.pp` to say,
and that is where this target is named. A package not named there is not built,
and a program that reaches for one of its units is told the unit cannot be
found - at compile time, on the development host, which is where a missing unit
should be found.

**What is not built is not built for a reason.** `rtl-console` has no `crt`,
`keyboard`, `video` or `mouse` for this machine, and the console belongs to
SDL here in any case; `fcl-process` needs processes and this machine runs one
program; `fcl-net` needs sockets; `fcl-registry` needs a registry; `fcl-res`
reads and writes the resource containers of executable formats, which this
target does not produce. Every binding to a shared library - `zlib`, `libpng`,
`sqlite`, `openssl`, `x11`, `gtk2` and the rest of that class - needs a library
this world does not carry and cannot load one at run time. The host tools
(`fppkg`, `fpmkunit`, `ide`, `fv`, `pastojs`, `webidl`, `fcl-passrc`) run on a
development machine rather than on a board.

**The runtime library gained units of its own** to carry those packages:
`math`, `fgl`, `charset`, `cpall` with the code page tables, `character`,
`unicodedata`, `unicodenumtable`, `fpwidestring` - and `Dos`.

## A program chooses its own wide string manager

**`uses fpwidestring` if the program cases a `UnicodeString`.** `UpperCase`
and `LowerCase` never needed it and never will: their `UnicodeString` forms are
`InternalChangeCase(S,['a'..'z'],±32)` in
`rtl/objpas/sysutils/sysuni.inc` - ASCII by definition, on every Free Pascal
target, and an accented letter comes back unchanged because that is what the
routine is for. `UnicodeUpperCase` and `UnicodeLowerCase` are the ones that
ask, through `widestringmanager.UpperUnicodeStringProc`.

Until a program elects a manager, that pointer is `StubUnicodeCase`, which
writes

```
This binary has no string conversion support compiled in.
Recompile the application with a unit that installs a unicodestring manager in the program uses clause.
```

to standard error and halts with runtime error 234. **So the failure is loud
and names its own cure** - nothing here silently returns the text it was
given.

A target with an operating system behind it elects a manager from the system.
This board has none to ask, so the answer is `fpwidestring`: pure Pascal over
the same Unicode tables the `Character` unit reads, installing itself in its
`initialization`, which runs only because the program named the unit. This is
Free Pascal's shape everywhere; a Unix program names `cwstring` for the same
reason.

It is not installed for every program on purpose. It pulls `unicodedata`'s
tables into the image, and a program that never touches a `UnicodeString`
should not carry them - and because the failure is a halt with a message
rather than a wrong answer, a program that needs it finds out.

## The Dos unit

Turbo Pascal's `Dos` unit is built for this target because Free Pascal's own
packages need it: `paszlib`'s `gzio` and the `unzip` package both call
`GetFAttr` on every target that is not Unix, and neither builds without it.

It is written over `SysUtils` rather than over the file service. Every routine
it offers already exists there, reaching the card through `circle-libsdl2` and
nothing else, so `Dos` here is a translation of Turbo Pascal's conventions - a
byte of attribute bits, a packed timestamp, `DosError` instead of an exception
- onto calls that were already made. It adds no crossing of its own.

Its `SearchRec` carries the `SysUtils` search that drives it, which is why the
record's layout is this target's own; every target declares its own for the
same reason. The name inside a file variable is **not** bytes here:
`TFileTextRecChar` is `UnicodeChar` on any target with wide strings, so
`GetFAttr`, `SetFAttr`, `GetFTime` and `SetFTime` convert it the way
`rtl/unix/dos.pp` does. Read as bytes a name yields its first character alone,
which is a real name that answers a plausible wrong attribute rather than an
error. What this board cannot answer, it refuses: `SetDate` and
`SetTime` report failure because nothing keeps a date here, `Exec` reports
failure because this machine runs one program, and `GetEnv` answers with
nothing because there is no environment.
