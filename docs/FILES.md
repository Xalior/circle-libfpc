# Files and directories

`Assign`, `Reset`, `Rewrite`, `Append`, `BlockRead`, `BlockWrite`, `Seek`,
`FilePos`, `FileSize`, `Truncate`, `Close`, `Erase` and `MkDir` work, on text
files and on typed and untyped files alike. Every one of them reaches the card
through `circle-libsdl2`'s file service and through nothing else. The card is a
device, a device belongs to the core that owns it, and the guest is not on that
core.

**The file service is not a second filesystem.** It is the C library's own file
call, carried to the core that owns the card and performed there. So a Pascal
program gets the C library's semantics, and the error translation in
`sysfile.inc` is the same one every libc-backed Free Pascal target does.

**The file position lives on this side.** The service names an offset on every
read and write and remembers nothing between calls, while Free Pascal expects
an open file to know where it is. So the target holds one entry per open file -
where it is, and how long it is - advanced on each read and write, set on each
seek, and taken from the open so that a seek from the end has an answer. There
is no lock on that table and none is needed: Pascal threads run on one core,
nothing preempts them, and no routine in the file layer gives the core away.
`CircleOpenFileCount` reports how many entries are taken, which is what a
program asks to see that closing a file gave its entry back.

**A truncate puts the descriptor where the cut needs it first, and that is not
tidiness.** The truncate underneath the file service remembers where the
descriptor was, seeks to the new length, cuts the file, and seeks back to where
it was - and on this filesystem a seek past the end of a file that is open for
writing extends the file to that offset rather than stopping at the end. The
service seeks before every transfer and leaves the descriptor where the
transfer ended, so a program that reads near the end of a file and then cuts it
short would have the file re-grown to exactly its old length, with success
reported and the card unchanged. The layer therefore writes no bytes at the new
length before asking for the cut - the service has no seek of its own, so a
transfer is the only lever on the descriptor, and a write cannot be refused by a
handle that is open for writing. Both calls here are the service's own, in the
order this board needs them.

**`Erase` refuses a directory.** Unlink on this board is the card's own, which
removes an empty directory as readily as a file, and a Pascal program that
writes `Erase` means a file. So the layer asks about the name first and reports
"file not found" for a directory rather than removing it. `RmDir` is how a
directory goes.

## The working directory

**It is one setting for the whole board.** It belongs to the filesystem,
which lives on the core that owns the card, so it is not per Pascal thread and
not per core: `ChDir` from any thread moves every thread, and the host
kernel's own file calls stand in the same directory afterwards. That is the
reach a working directory has in a Pascal program anywhere - it belongs to
the process rather than to a thread - with the host kernel inside the same
process here.

Nothing inside the guest can come between a change and the name that depends on
it. Nothing preempts a Pascal thread, and a service call blocks inside
`circle-libsdl2` without entering this library's scheduler, so no second Pascal
thread runs between one thread's `ChDir` and its next open. The host kernel is
the one thing outside that, and it shares the setting if it uses relative
names. A program that will not rely on either agreement gives absolute names,
which the setting does not affect.

**It defaults to the card's root, and a port may set its own.** The host
kernel sets it once, from `RAPI_WORK_DIR`, a build-time value a port's own
Makefile may set beside its display size - see
[Building a kernel](BUILDING.md). Left unset, it falls back to `/`, which is
always there, so a program that names nothing still gets a real directory it
can read and write.

**A missing one stops the board with a message rather than running from the
wrong place.** If `RAPI_WORK_DIR` names a directory that is not on the card,
the host kernel does not start the Pascal program: it repeats the failure on
the console, forever, rather than let the program go on and write a relative
path somewhere it was never meant to be.

**A host kernel that wants file access has to bring the card up itself**, on
core 0, before it releases the application core - the EMMC device and the FAT
mount. Read `host/kernel.cpp` for the order and why it is that order.

Nothing here uses the linker's `--wrap`. That is the pattern for an application
with no file layer of its own; this library is the file layer, so it points
itself at the file service directly.
