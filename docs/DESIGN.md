# Design decisions and ownership rules

- **This library owns the translation. Circle owns the hardware.** Nothing here
  drives a device, reads a register or claims a pin. Accumulating hardware
  support inside the runtime would be a conformance failure, and it is the way
  a thin library stops being thin.

- **This library does not modify the generic Free Pascal runtime.** Reference
  counting for `AnsiString`, `UnicodeString` and dynamic arrays, and the
  exception mechanism, are shared by every Free Pascal target and contain no
  operating-system conditionals. They are used as they are.

- **The host kernel owns the entry, and calls `PASCALMAIN` itself.** This
  library provides no `main`. A Circle kernel is an ordinary Circle kernel: it
  brings up the devices it wants and calls `PASCALMAIN` from wherever it likes.
  What it must not do is expect `PASCALMAIN` to return — the runtime ends a
  program by calling `_haltproc`, which does not return either.

- **All Circle access is through C wrappers.** Circle is C++; Free Pascal calls
  C. The wrappers deal in a thread entry point, a handle, a mutex and an event,
  and know nothing about Free Pascal.

- **The C++ side ships as an archive; the Pascal side ships as source.** A
  precompiled Pascal unit binds every consumer to one runtime build and one set
  of compiler switches, and the switches are not the same for every
  application. `rtl/*.pp` is compiled by the consumer's own cross-compiler into
  the consumer's blob, and `fpc-app.mk` puts `rtl/` on the unit path so that
  costs the consumer nothing.

- **This library owns no hardware, and a Pascal program is a guest.** It
  supplies the runtime — memory manager, thread manager, start-up, halt — and
  nothing that reaches the outside world. A Pascal program runs on a core the
  way a guest runs on a virtual machine: it runs code, and every crossing to
  the outside is somebody else's.

  The somebody else is circle-libsdl2, which is the I/O surface a Pascal
  program on this platform has. Console output goes out through that library's
  own byte-oriented log entry, which takes output in whatever pieces it was
  written in and carries each finished line off the core that produced it.

  This is not tidiness. A console is a device, a device belongs to core 0, and
  a Pascal thread runs on a core that is not core 0 — so writing a device from
  a thread is a cross-core hardware access with nothing serialising it against
  core 0 doing the same. Holding a `CDevice` here was what made that possible,
  so nothing here holds one.

  **In an image that does not link circle-libsdl2** the reference to it is
  weak and resolves to nothing, and there is then no I/O surface. Output falls
  back on the one console every Circle kernel already owns — the host's own
  `CLogger` — under the same rule: core 0 writes through it, and any other core
  puts its line in a ring of its own for core 0 to drain. A host kernel with no
  `CLogger` sees nothing at all, because Circle answers `CLogger::Get` with a
  logger that has no target and a severity floor of `LogPanic`.

- **The two run-time installations are a unit, not documentation.** The memory
  manager and the thread manager are both installed at run time and are both
  invisible to a link, so a program that forgets either one links perfectly and
  fails on the board. `circlefpc` pulls in both, in the order that works. It is
  one line in a program's `uses` clause because that is the smallest thing that
  cannot be got wrong.

- **`_stack_top` is an archive member so a host kernel can replace it.** The
  default describes core 0's kernel stack, which is where a host kernel calls
  `PASCALMAIN` from. A kernel that runs Pascal elsewhere defines the symbol in
  one of its own objects and the linker prefers that, with nothing removed from
  here.

- **A Pascal thread is a core, not a task.** A Circle `CTask` belongs to the
  scheduler on core 0 and runs nowhere else, so everything hung off a task —
  identity, thread-local storage, the stack an exception frame walk is bounded
  by — was core 0's too. Here a thread is a record this library owns, and a
  core a host kernel has lent runs it directly. The locks and events that go
  with it are built from processor atomics rather than from Circle's scheduler
  primitives, because a lent core has no scheduler to block on. See
  [Threading](THREADING.md).

- **No `std::thread`, and no C++ runtime dependency of our own.** The
  `aarch64-embedded` Free Pascal runtime makes no C library call, so a Pascal
  blob needs neither newlib nor libc++ beyond `setjmp`, which is how a thread
  that ends itself returns to the core that was running it. That a *world* may
  drag both in is the world's business, not this library's.

- **One world and one archive per board.** Each is compiled for its own
  processor and its own `RASPPI` value, and an object built for one board is not
  usable on another. This library does not build worlds: `circle-libsdl2` does,
  and a kernel that links both libraries must have been compiled against the
  one world they agree on.
