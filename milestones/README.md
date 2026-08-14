# Milestone verification programs

Each directory here is a Pascal program that proved one capability of this
library on the board, in the order the library gained them: an entry point
reached, threads, files, the standard packages, SDL. Read
[docs/STATUS.md](../docs/STATUS.md) for what each one proves in full.

These are not examples to copy. An example shows the platform used the way a
real program uses it: Pascal source and a Makefile that sets what it needs,
against the shared host kernel in `host/`. A milestone here instead keeps a
host kernel of its own, because part of what it proves can only be checked
from the core that owns the devices, independently of the Pascal side under
test - a file the Pascal program wrote, read back with the C library rather
than through the layer being tested; a witness compared against a directory
walk made here; Circle's own task list, watched from the core that owns it,
because the guest cannot read a list that belongs to a core it does not run
on. A kernel written to check its own program's homework is not a pattern a
new program should copy; it is why these programs are kept apart from
`examples/`.

Every program here still builds and still proves what it was written to
prove. Nothing about the check each kernel makes has changed.

- `m0` - a Pascal program's entry point is reached, before any runtime
  service exists, proved by a call into a kernel-defined C function.
- `m4` - Pascal threads run correctly on the application core, and raise no
  Circle task while they do.
- `m5` - Pascal's own file statements reach the real card.
- `m6` - the `SysUtils` file family and `TFileStream` reach the real card,
  and the calendar clock the runtime reads is the clock this board's C
  library reads.
- `m7` - Free Pascal's standard packages work on this target.
- `m8` - SDL runs, driven from Pascal: a window, a renderer, textures, and
  the event queue.
