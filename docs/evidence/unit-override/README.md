# Evidence: replacing a runtime unit

[BUILDING.md](../../BUILDING.md) makes a claim strong enough to deserve a proof
that anybody can check: a replacement for a unit the Free Pascal runtime
already ships can compile, link, and pass `make fpc-contract` while its code is
absent from the image.

This directory reproduces that, and reproduces the corrected build beside it so
the two can be compared in one run. It then runs the build's own guard,
`fpc-objlist-check.sh`, over the same object list, which must refuse it — so a
run also answers whether the guard still catches the thing it was written for.

## What is in here

| File | What it is |
|---|---|
| `run.sh` | the whole experiment, start to finish |
| `probe.pas` | the smallest program that reaches the SysUtils file family |
| `sysutils-probe.patch` | the delta that redirects that family to external C symbols |

`run.sh` copies every source it needs into a work directory and patches the
copy. **It never writes into the runtime tree**, and its build spoil goes
outside this repository unless `WORK` says otherwise, so a run leaves the
working tree clean.

The blobs it builds are build products. They are not kept here, and they do not
need to be: the script makes them from nothing each time.

## Running it

```sh
FPC=<path>/ppcrossa64 \
FPCRTL=<runtime units, the directory holding system.ppu> \
FPCRTLSRC=<runtime source tree, the directory holding rtl/> \
FPCBINUTILS=<directory holding aarch64-elf-as and aarch64-elf-ld> \
./run.sh
```

It exits zero only when the trap reproduces, the corrected build works, and the
guard refuses the list. Any of the three coming out the other way is said
outright and exits non-zero, which is the answer worth having if a future
compiler changes this behaviour or the guard stops reaching it.

## What it does

The patch gives the SysUtils file family — `FileOpen`, `FileRead`, `FileWrite`,
`FileSeek`, `FileClose`, `InternalFindFirst`, `DirectoryExists` — bodies that
call external C functions nothing defines. That makes the question a link can
answer: if the overridden code is in the blob, those symbols are undefined in
it; if it is not, they are nowhere.

The blob is then assembled twice from the same compiler output. Once by the
rule `fpc-app.mk` uses — read the object list out of the compiler's link
response file, give bare names the output directory, take anything already
carrying a path as written. Once with any unit whose object the compiler
freshly wrote taken from the output directory instead.

Finally it runs `fpc-objlist-check.sh` over that same list. That is the file
`fpc-app.mk` runs before it links a blob, used here rather than copied, so the
run tests the guard the build actually has.

## What it shows

Overriding SysUtils changes its interface checksum, so four more units are
refused and rebuilt from source with it. The compiler says so, and writes a
fresh object for every one:

```
-- units the compiler reported recompiling --
Compiling probe.pas
Compiling classes.pp
Compiling sysutils.pp
Compiling types.pp
Compiling math.pp
Compiling typinfo.pp

-- objects the compiler actually wrote --
classes.o
math.o
probe.o
sysutils.o
types.o
typinfo.o
```

The link response file names none of them. For every unit that was just
rebuilt it still points at the object in the runtime's own unit directory:

```
-- what the link response file names for those same units --
<runtime units>/classes.o
<runtime units>/sysutils.o
<runtime units>/types.o
<runtime units>/typinfo.o
<runtime units>/math.o
```

And that is the whole failure, visible only in the two blobs:

```
-- blob-as-recipe.o leaves undefined --
   U _haltproc
   U _stack_top
-- blob-corrected.o leaves undefined --
   U _haltproc
   U _stack_top
   U probe_close
   U probe_direxists
   U probe_findfirst
   U probe_open
   U probe_read
   U probe_seek
   U probe_write
```

The first blob is the one the build rule produces. Its undefined symbols are
`_haltproc` and `_stack_top` and nothing else — the two-symbol contract,
exactly the result a correct build gives. The override is not in it. Every
check available says the build is right, and the code that was overridden is
gone.

The second blob differs from the first only in where five objects were taken
from, and it carries the override.

The guard reads the disagreement straight out of the same list and refuses it,
naming each unit and both paths:

```
-- the guard, on the same list --
  the list says   <runtime units>/sysutils.o
  this build wrote <output directory>/sysutils.o
```

Paths above are shown as placeholders; the real ones name whichever runtime the
run was pointed at.

## The limit of this result

This is a trap of **replacing a unit**, not of keeping units in a project's own
source tree — which is how this library ships `circlefpc`, `clfthreads` and the
rest. The trap needs a second object of the same name for the response file to
keep pointing at, and a unit the runtime does not ship has none. That is also
why the guard cannot fire on an addition: with one object of the name, there is
no disagreement to find. See [BUILDING.md](../../BUILDING.md) for the test that
separates the two cases.
