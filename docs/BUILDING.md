# Building circle-libfpc

## Prerequisites

- The **Arm GNU toolchain** for `aarch64-none-elf` (bare-metal AArch64), for
  the C++ side and the link. Release 15.2.Rel1, built for the machine you
  compile on, from the
  [Arm GNU Toolchain downloads](https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads).
- A **Free Pascal cross-compiler for `aarch64-embedded`**, built from
  development trunk. The target is absent from release 3.2.2 and from
  `release_3_2_4_rc1`.
- That compiler's **runtime library rebuilt with the THREADING feature
  enabled**. The stock `aarch64-embedded` runtime has it compiled out, and on
  it a single `threadvar` declaration is a fatal compile error.
- **`aarch64-elf-binutils`** — the assembler and linker Free Pascal drives for
  this target. Free Pascal writes `aarch64-elf-` tool names, which is not the
  Arm GNU toolchain's `aarch64-none-elf-` prefix, so this is a second binutils
  and not the one the C++ side uses.
- **GNU make 4.0 or later** for the archive. macOS ships 3.81 as `make`, which
  compares file timestamps to the second; a source rewritten in the same second
  its object was compiled in is never seen as newer, so a symbol audit run
  against the archive reports functions as missing that the source plainly
  defines. Homebrew installs a current one as `gmake`.

`toolchain.mk` finds the Arm toolchain and `fpc-app.mk` finds the Free Pascal
one. Both honour `PATH` first, then `$RAPI_TOOLCHAIN_DIR` and `$RAPI_FPC_DIR`,
then `toolchains/` beside this library and one and two levels above it.

## The world

**This library does not build Circle worlds and does not carry one.**
`circle-libsdl2` builds them, and a consumer that has one already should point
this library at it rather than keep a second copy:

```sh
make CIRCLE_WORLDS=/path/to/worlds      # a directory holding circle-stdlib-rpi<n>
make CIRCLESTDLIBHOME=/path/to/world    # one world, named outright
```

With neither set, the world is expected at `circle-stdlib-<board>` beside this
file.

**The world must be configured as
`circle-libsdl2/docs/BUILDING.md` specifies**, and that document is normative
here:

```
-r <board> -p aarch64-none-elf- --libcxx-repo --kernel-max-size 256 \
  -o ARM_ALLOW_MULTI_CORE -o KERNEL_STACK_SIZE=0x200000
```

Two of those settings are not preferences.

- **`KERNEL_STACK_SIZE=0x200000`.** Circle's own default is 128 KB a core, and
  it lays the four core stacks out one after another with no guard page
  between them: a core that runs past the bottom of its stack writes into the
  stack of the core below, and what is seen is a fault somewhere else entirely.
  Free Pascal's exception frame walk runs on that stack.
- **`USE_PHYSICAL_COUNTER`.** Circle's `sysconfig.h` defines it unless
  `NO_PHYSICAL_COUNTER` is set, so it needs no configuration — but a world that
  has had it turned off does not satisfy `circle-libsdl2`'s requirements, and a
  kernel linking both libraries inherits that.

**A circle-stdlib world rather than plain Circle.** The `aarch64-embedded`
runtime makes no C library call, so a Pascal blob will link against
`libcircle.a` alone. A circle-stdlib world is used all the same, because a
kernel that links `circle-libsdl2` beside this library needs one too, and two
libraries in one image must agree about the world they were compiled for. The consequence to know about: Circle in such a world is compiled with
`STDLIB_SUPPORT 4` and its own code then calls `operator new`, `operator
delete`, `abort` and `strlen`. A kernel must link `$(CIRCLE_STDLIB_LIBS)`, not
just `libcircle.a`, or the link fails inside Circle naming Circle's own source
files — which reads as a broken world rather than a short library list.

## The archive

There is one world and one archive per board, because each is compiled for its
own processor and its own `RASPPI` value, and an object built for one board is
not usable on another.

| Board | World | Archive |
|---|---|---|
| Pi 3 | `circle-stdlib-rpi3` | `libfpc-rpi3.a` |
| Pi 4 | `circle-stdlib-rpi4` | `libfpc-rpi4.a` |
| Pi 5 | `circle-stdlib-rpi5` | `libfpc-rpi5.a` |

```sh
make                  # libfpc-rpi5.a — the Pi 5 is the default board here
make BOARD=rpi4       # libfpc-rpi4.a
make rebuild          # drop one board's objects and archive, build from nothing
make audit            # what the archive references and does not define
```

Objects live in per-board trees, so the archives coexist and switching boards
needs no `make clean`.

Take any measurement off a `rebuild`, never off an incremental build: an
incremental build is a decision made from timestamps, and a timestamp is
evidence about when a file was written rather than about what is in it.

## Building an application

An application is a Pascal program compiled as a blob, plus a small Circle host
kernel that calls it. Include `fpc-app.mk` after Circle's `Rules.mk`:

```make
CIRCLELIBFPCHOME = ../..
CIRCLESTDLIBHOME = $(CIRCLELIBFPCHOME)/circle-stdlib-rpi5
CIRCLEHOME       = $(CIRCLESTDLIBHOME)/libs/circle

include $(CIRCLELIBFPCHOME)/toolchain.mk
include $(CIRCLESTDLIBHOME)/Config.mk

TARGET      = kernel-myapp
FPC_PROGRAM = myapp.pp
OBJS        = main.o kernel.o
LIBS        = $(CIRCLE_STDLIB_LIBS)
INCLUDE    += -I $(CIRCLELIBFPCHOME)/include

FPC_APP_IMAGE := $(TARGET)
TARGET := .circle-unused
include $(CIRCLEHOME)/Rules.mk
TARGET := $(FPC_APP_IMAGE)

include $(CIRCLELIBFPCHOME)/fpc-app.mk
```

`toolchain.mk` is included **first**, before the world and before `Rules.mk`,
because `Rules.mk` asks the C++ compiler a question while it is being read; a
toolchain that only reaches `PATH` later produces a stray "no such file or
directory" on every build, which reads like a broken source tree.

The `TARGET` dance stops make warning that a recipe has been overridden.
`Rules.mk` defines a link rule for `$(TARGET).img` and `fpc-app.mk` replaces
it; pointing `TARGET` at a name nothing builds while `Rules.mk` is read, then
restoring it, leaves `fpc-app.mk`'s rule as the only recipe for the image.

`fpc-app.mk` sets the default goal to the image itself. It has to: the name
`Rules.mk` attaches its rule to begins with a dot, and GNU make skips a target
beginning with a dot when it chooses the default goal — so without that line, a
plain `make` runs `clean`.

Settings a consumer is likely to want:

| Variable | What it does |
|---|---|
| `FPC_PROGRAM` | the Pascal program. Required. |
| `FPCFLAGS` | extra compiler options — unit search paths, mode switch, optimisation |
| `FPC_HEAP_SIZE` | the heap block the compiler emits into BSS. Default 4 MB |
| `FPC_OBJDIR` | where the blob is built. Default `fpcblob` |
| `FPC`, `FPCRTL`, `FPCBINUTILS` | override the Free Pascal toolchain search |
| `FPCLIB` | override the archive this kernel links |

**Changing `FPCRTL` does not rebuild the blob, and that can hand you a false
result.** The blob rule depends on the program source and on `rtl/*.pp`, not on
which runtime those are compiled against, so pointing `FPCRTL` at a different
runtime and building again produces the SAME object — and an image identical to
the one before it, byte for byte, reported as a successful build. Comparing two
runtimes is exactly when someone does this, and a null result then reads as a
finding.

So when the runtime is the variable, `make clean` between the builds, and
compare the image hashes before believing either of them. Two identical hashes
mean the second build did not happen, not that the runtime made no difference.

Two targets are worth knowing:

```sh
make fpc-blob        # build the application blob and stop
make fpc-contract    # list what the blob leaves for the host kernel
```

`fpc-contract` is the check that matters after any change to an application's
units. On a conforming build the list is `_haltproc`, `_stack_top` and whatever
C functions the application declared for itself. Anything else is a finding.
