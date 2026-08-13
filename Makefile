#
# circle-libfpc — the Free Pascal runtime, resolved against Circle.
#
#   gmake                build this board's archive and every example image
#   gmake lib            just the archive
#   gmake examples       just the example images
#   gmake BOARD=rpi5     build against another board's world
#   gmake clean-board    drop this board's objects, archive and example builds
#   gmake rebuild        clean-board, then build from nothing
#
# `clean-board` rather than `clean` because Circle's Rules.mk already defines
# a `clean` of its own, and two recipes for one target make GNU make warn on
# every build — which reads like a fault and is not one. The board-scoped name
# is also the honest one: everything here is built per board, and one board's
# tree is not the other's to remove.
#
# The archive is this library's C half: what Free Pascal's runtime needs that
# only C++ can reach, and the seams between the Pascal program and the host
# kernel. The Pascal half is the compiler's own runtime layer for the
# circlesdl2 target, which lives in the Free Pascal tree and is built with the
# compiler.
#
# A Pascal program is compiled into the host kernel by including fpc-app.mk;
# read its header for what a consumer's Makefile does.
#
# WHAT THIS BUILD NEVER DOES: fetch anything, install anything, or build a
# Circle world. The worlds and the cross-compiler exist already; if this
# cannot find one, a variable is wrong.
#

# GNU make 4.0 or later. macOS ships 3.81 as `make` and Homebrew installs a
# current one as `gmake`. 3.81 compares file timestamps to the second, so a
# source rewritten in the same second its object was compiled in is never seen
# as newer and the object carries the older text into the link.
ifeq ($(filter 1.% 2.% 3.%,$(MAKE_VERSION)),$(MAKE_VERSION))
$(error this build needs GNU make 4.0 or later; this is '$(MAKE)' version '$(MAKE_VERSION)'. Homebrew installs one as gmake.)
endif

# Circle's Rules.mk, included below, defines no `all`, so the default goal
# would fall to whichever of its rules make reads first. Stated here instead.
.DEFAULT_GOAL := all

BOARDS = rpi3 rpi4 rpi5
BOARD ?= rpi5

ifeq ($(filter $(BOARD),$(BOARDS)),)
$(error BOARD must be one of: $(BOARDS) — not `$(BOARD)')
endif

# `make -n` executes any recipe line containing $(MAKE), so a dry run of a
# recursive target builds for real. Those recipes refuse instead, from a line
# prefixed `+` so that it too runs under -n.
DRY_RUN     := $(findstring n,$(firstword -$(MAKEFLAGS)))
NOT_DRY_RUN  = $(if $(DRY_RUN),echo "$@: no dry run — this recipe drives sub-makes and make -n executes those for real." >&2; exit 1,:)

# ---------------------------------------------------------------------------
# What this library is built against. Every one of these is a place something
# already built lives; none of them is something this build produces.
# ---------------------------------------------------------------------------

# The configured Circle worlds and circle-libsdl2's per-board archive. A
# parent repository that carries its own editing copy of circle-libsdl2
# overrides both to point at it; on their own they mean this library's own
# submodule, which is what makes a standalone clone buildable.
CIRCLE_WORLDS ?= $(CURDIR)/circle-libsdl2
SHIM          ?= $(CURDIR)/circle-libsdl2

CIRCLESTDLIBHOME = $(CIRCLE_WORLDS)/circle-stdlib-$(BOARD)

# The Free Pascal cross-compiler and its runtime units, used where they were
# built and never installed. `fpc` here is the source tree.
FPC_COMPILER ?= $(CURDIR)/fpc/compiler/ppcrossa64
FPC_UNITS    ?= $(CURDIR)/fpc/rtl/units/aarch64-circlesdl2

# Free Pascal's packages, in that same tree. Every package that builds for
# this target leaves its units under <package>/units/<cpu>-<os>, and
# fpc-app.mk expands this into that list — so a program may be written in
# DateUtils, StrUtils, IniFiles and the rest rather than in the runtime
# library alone.
FPC_PACKAGES ?= $(CURDIR)/fpc/packages

LIBFPC_HOME := $(CURDIR)

export BOARD CIRCLE_WORLDS SHIM FPC_COMPILER FPC_UNITS FPC_PACKAGES LIBFPC_HOME

# ---------------------------------------------------------------------------

EXAMPLES = m0 m1 m2 m3 m4 m5 m6 m7

.PHONY: all lib examples clean-board rebuild help $(EXAMPLES)

all: lib examples

lib: libfpc-$(BOARD).a

examples: lib
	+@$(NOT_DRY_RUN)
	@for e in $(EXAMPLES); do $(MAKE) -C examples/$$e || exit 1; done

$(EXAMPLES): lib
	+@$(NOT_DRY_RUN)
	@$(MAKE) -C examples/$@

clean-board:
	+@$(NOT_DRY_RUN)
	@rm -rf build/$(BOARD) libfpc-$(BOARD).a
	@for e in $(EXAMPLES); do $(MAKE) -C examples/$$e clean-board || exit 1; done

# Any measurement that has to be right is taken off a build from nothing, and
# a tree built under flags that have since changed is exactly what selective
# cleaning leaves behind. So the tree goes, rather than objects one at a time.
rebuild:
	+@$(NOT_DRY_RUN)
	@$(MAKE) clean-board BOARD=$(BOARD)
	@$(MAKE) all BOARD=$(BOARD)

help:
	@sed -n '2,26p' $(firstword $(MAKEFILE_LIST)) | sed 's/^# \{0,1\}//'

# ---------------------------------------------------------------------------
# The archive. It needs the board's world, so guard the rules that use one:
# without the guard the archive rule would not exist at all, make would find
# the archive FILE from a previous build up to date, and report success on a
# build that never ran.
# ---------------------------------------------------------------------------

OBJDIR = build/$(BOARD)

ifneq ($(wildcard $(CIRCLESTDLIBHOME)/Config.mk),)

include $(CIRCLESTDLIBHOME)/Config.mk

SRCS = src/halt.cpp src/heap.cpp src/counter.cpp src/clock.cpp src/core.cpp
OBJS = $(SRCS:src/%.cpp=$(OBJDIR)/%.o)
DEPS = $(OBJS:.o=.d)

# Dependency files are written while compiling rather than by rules of their
# own, and Circle's Rules.mk is told to keep its hands off (CHECK_DEPS) so its
# `-M -MG` rules are not defined for these objects: -MG stops the build on a
# header it has no rule for, and GNU make 3.81 does so with no output at all.
# -MP adds a recipeless rule for every header named, so a header that
# disappears is a rebuild instead of a dead stop.
CHECK_DEPS = 0
DEPFLAGS   = -MD -MP

libfpc-$(BOARD).a: $(OBJS)
	@echo "  AR    $@"
	@rm -f $@
	@$(AR) cr $@ $(OBJS)

STANDARD = -std=c++23 -Wno-volatile

include $(CIRCLEHOME)/Rules.mk

CCACHE := $(shell command -v ccache 2>/dev/null)
ifneq ($(CCACHE),)
CPP := $(CCACHE) $(CPP)
CC  := $(CCACHE) $(CC)
endif

INCLUDE := -I include $(CIRCLE_STDLIB_INCLUDES) $(INCLUDE)

# Per-board compile into $(OBJDIR). Circle's Rules.mk builds objects in place;
# this more specific rule wins for the board-scoped paths. Same recipe as
# Rules.mk, plus $(DEPFLAGS) and a redirected output directory.
$(OBJDIR)/%.o: src/%.cpp | $(OBJDIR)
	@echo "  CPP   $@"
	@$(CPP) $(CPPFLAGS) $(DEPFLAGS) -c -o $@ $<

$(OBJDIR):
	@mkdir -p $(OBJDIR)

-include $(DEPS)

else

.PHONY: libfpc-$(BOARD).a
libfpc-$(BOARD).a:
	@echo "$(CIRCLESTDLIBHOME)/Config.mk is missing: the $(BOARD) world is not configured."
	@echo "The worlds are circle-libsdl2's to build, and CIRCLE_WORLDS says where they are."
	@exit 1

endif
