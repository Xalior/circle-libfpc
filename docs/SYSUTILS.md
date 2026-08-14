# SysUtils, Classes, and TFileStream

**This is the layer a real Pascal program actually writes against**, and it is
built for this target: `SysUtils` carries `FileOpen`, `FileRead`, `FileSeek`,
`FindFirst`, `FileExists` and `DirectoryExists`; `Classes` carries
`TFileStream`, `TStringList`, `TList`, `TComponent` and `TThread`. `sysconst`,
`rtlconsts`, `types` and `typinfo` are built with them because those two are
declared in terms of them.

**Both file layers share one position table**, and that is the whole of what
the target had to add. The file service names an offset on every read and
write, so an open file's position lives on the Pascal side - and Pascal's own
`Reset` and `SysUtils`' `FileOpen` hand out the same descriptors. A second
table would give one descriptor two positions and make the right answer depend
on which layer touched it last. So the System unit exports the six operations
`SysUtils` needs - `CircleFileOpen`, `CircleFileClose`, `CircleFileRead`,
`CircleFileWrite`, `CircleFileSeek` and `CircleFileTruncate` - and there is one
table underneath all of it. `CircleOpenSearchCount` is `CircleOpenFileCount`'s
counterpart for directory searches.

**A search holds one of a fixed number of slots** until `FindClose` is called.
`TSearchRec` carries a single 32 bit handle with no room for the directory
handle, the pattern and the attribute filter beside it, so the handle is a slot
number. The pattern matcher is the target's own: `*` and `?`, case-insensitive,
because the card's filesystem does not tell two names apart by case alone.

**A directory entry on this card carries only its name.** The service reports
no type, size or timestamp with it, so the search asks about each name
separately - which is what Free Pascal's other directory-reading targets do,
for the same reason.

## What this board cannot answer, and how each one says so

None of these reports success. Each reports the failure `SysUtils` reports, and
says why in its own comment.

- `FileGetDate` and `FileSetDate` return -1: **the service answers about a
  name, and an open descriptor cannot be asked.** `FileAge` is the question
  that can be answered here, and it takes a name.
- `FileSetAttr` returns -1, and `FileGetAttr` reports only whether the name is
  a directory. The service carries no attribute bits.
- **A timestamp on this card is the epoch.** The C library's `stat` here fills
  in the size and whether the name is a directory and leaves the modification
  time at zero, so `FileAge` and `TSearchRec.Time` report what that says rather
  than a time invented to look plausible.
- `DiskFree` and `DiskSize` return -1: there is no free-space figure in the
  service.
- `ExecuteProcess` raises. There are no processes here, and a caller that
  ignored a -1 would carry on as though a program had run and failed.
- `GetEnvironmentVariable` returns an empty string, which is the true answer: a
  Circle kernel is loaded and started, not invoked with a set of variables.
- `FileExists` says **no** to a directory, deliberately. A program asking it is
  about to open the name, and a directory cannot be opened. `DirectoryExists`
  is the question for a directory.

`GetLastOSError` answers from what the file service last reported. This machine
has no errno the guest may read - the C library's is one variable shared by
every core, which is why the service returns a negated error number instead of
setting one - so each routine catches the number as it sees it, per Pascal
thread.

## TThread

`TThread` is this library's scheduler with an object on top: `BeginThread`,
`SuspendThread`, `ResumeThread` and `WaitForThreadTerminate`, which are the
portable interface over the scheduler [Threads](THREADS.md) describes.
Nothing preempts, so a thread created unsuspended is on the run list from the
moment `TThread.Create` returns but does not run until the thread that made it
gives the core away. Priorities are one value here, so `TThread.GetPriority`
always answers `tpNormal` and setting one changes nothing.
