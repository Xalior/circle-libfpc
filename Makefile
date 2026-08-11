#
# circle-libfpc — the Free Pascal runtime on the Circle bare-metal framework.
#
# RASPPI is baked into a Circle world at configure time, so each Pi board needs
# its OWN world, and this library its own per-board archive built against it:
#
#   circle-stdlib-rpi3 (RASPPI 3) -> libfpc-rpi3.a
#   circle-stdlib-rpi4 (RASPPI 4) -> libfpc-rpi4.a
#   circle-stdlib-rpi5 (RASPPI 5) -> libfpc-rpi5.a
#
# The board here is the Raspberry Pi 5, so that is the default.
#
#   make                 build the default board's archive (BOARD=rpi5)
#   make BOARD=rpi4      build one board's archive against its world
#   make rebuild         drop one board's objects and archive, build both from
#                        nothing
#
# THIS LIBRARY DOES NOT BUILD WORLDS. circle-libsdl2 does, and a consumer that
# has one already should point this at it rather than keep a second copy:
#
#   make CIRCLE_WORLDS=/path/to/worlds        one directory holding
#                                             circle-stdlib-rpi<n>
#   make CIRCLESTDLIBHOME=/path/to/world      one world, named outright
#
# A world for this library must be configured as circle-libsdl2/docs/BUILDING.md
# specifies, because a kernel built on this library links that one beside it and
# two libraries in one image must agree about the world they were compiled for.
#

# GNU make 4.0 or later. macOS ships 3.81 as `make`, and Homebrew installs a
# current one as `gmake`.
#
# 3.81 compares file timestamps to the SECOND. A source rewritten within the
# same second its object was compiled in is never seen as newer, so the object
# stays in the archive carrying the older text and any reading taken off that
# archive is a reading of the previous build. 4.x compares to the nanosecond,
# which APFS records.
ifeq ($(filter 1.% 2.% 3.%,$(MAKE_VERSION)),$(MAKE_VERSION))
$(error this build needs GNU make 4.0 or later; this is '$(MAKE)' version '$(MAKE_VERSION)'. Homebrew installs one as gmake.)
endif

BOARDS      = rpi3 rpi4 rpi5
BOARD      ?= rpi5

# An unknown board name otherwise reaches every rule below as a world
# directory that does not exist, and surfaces as make reporting no rule for an
# archive it was never going to be able to name.
ifeq ($(filter $(BOARD),$(BOARDS)),)
$(error BOARD must be one of: $(BOARDS) — not `$(BOARD)`)
endif

# `make -n` EXECUTES any recipe line containing $(MAKE): make marks such a line
# always-run so a dry run can descend into the sub-make. The recursive targets
# here refuse instead, from a line prefixed `+` so that it too runs under -n.
DRY_RUN     := $(findstring n,$(firstword -$(MAKEFLAGS)))
NOT_DRY_RUN  = $(if $(DRY_RUN),echo "$@: no dry run — this recipe drives sub-makes and make -n executes those for real." >&2; exit 1,:)

# The Arm GNU aarch64-none-elf cross toolchain, found the same way every
# consumer of this library finds it.
include toolchain.mk

# WHERE THE PER-BOARD WORLDS LIVE. The default is this directory. Point
# several consumers at one directory and each board's world is built once and
# shared; a world outside this directory is not this makefile's to create.
CIRCLE_WORLDS    ?= $(CURDIR)
CIRCLE_STDLIB     = $(CIRCLE_WORLDS)/circle-stdlib-$(BOARD)
CIRCLESTDLIBHOME ?= $(abspath $(CIRCLE_STDLIB))

# Per-board object tree, so all three archives coexist without one board's
# objects clobbering another's. No `make clean` between boards.
OBJDIR = build/$(BOARD)

.DEFAULT_GOAL := libfpc-$(BOARD).a

# One BOARD is configured per invocation, so the other boards' archives have no
# rule here. Asking for one by name would otherwise get "Nothing to be done"
# and an exit status of zero: a build that never happened, reported as success.
OTHER_ARCHIVES := $(filter-out libfpc-$(BOARD).a,$(BOARDS:%=libfpc-%.a))
.PHONY: $(OTHER_ARCHIVES)
$(OTHER_ARCHIVES):
	@echo "$@ is not built by BOARD=$(BOARD)."
	@echo "Run: $(MAKE) BOARD=$(patsubst libfpc-%.a,%,$@)"
	@exit 1

# One board from nothing: its objects and its archive are removed before the
# build, so nothing on disk can answer for a source make did not read. Any
# measurement taken off an archive — a symbol list, a size, a member listing —
# has to be taken off one of these.
.PHONY: rebuild
rebuild:
	+@$(NOT_DRY_RUN)
	@rm -rf $(OBJDIR) libfpc-$(BOARD).a
	@$(MAKE) libfpc-$(BOARD).a BOARD=$(BOARD)

# WHAT THE ARCHIVE REFERENCES BUT DOES NOT DEFINE.
#
# An archive member is pulled in only to resolve something still undefined, so
# a symbol this library refers to and never defines can sit unnoticed until a
# consumer happens to link the member that needs it. The list is not required
# to be empty — Circle's own symbols are resolved by Circle — but it is
# required to be KNOWN.
.PHONY: audit
audit: rebuild
	@echo "== referenced by libfpc-$(BOARD).a, defined nowhere in it =="
	@$(PREFIX)nm --defined-only libfpc-$(BOARD).a | awk '{print $$3}' | sort -u > .audit-def
	@$(PREFIX)nm -u libfpc-$(BOARD).a | awk '$$1=="U"{print $$2}' | sort -u > .audit-und
	@comm -23 .audit-und .audit-def | sed 's/^/  /'
	@rm -f .audit-def .audit-und

# The library targets need the selected board's Config.mk + Rules.mk; guard
# them so this makefile parses before that world exists.
ifneq ($(wildcard $(CIRCLESTDLIBHOME)/Config.mk),)

include $(CIRCLESTDLIBHOME)/Config.mk

SRCS  = src/glue.cpp src/log.cpp src/sched.cpp
ASRCS = src/stacktop.S
OBJS  = $(SRCS:src/%.cpp=$(OBJDIR)/%.o) $(ASRCS:src/%.S=$(OBJDIR)/%.o)
DEPS  = $(OBJS:.o=.d)

# Dependency files are written as a side effect of compiling rather than by
# rules of their own, and Circle's Rules.mk is told to keep its hands off
# (CHECK_DEPS) so its `-M -MG` .d rules are not defined for these objects. -MG
# lists a header make has no rule for as a prerequisite of the object, which
# stops the build, and 3.81 stops with exit 2 and not one line saying why.
CHECK_DEPS = 0
DEPFLAGS   = -MD -MP

libfpc-$(BOARD).a: $(OBJS)
	@echo "  AR    $@"
	@rm -f $@
	@$(AR) cr $@ $(OBJS)

include $(CIRCLEHOME)/Rules.mk

# The cross compiler goes through ccache when there is one. Circle's Rules.mk
# names the compiler directly, so nothing here would be cached otherwise. AS is
# left alone: Rules.mk sets it from CC before this point.
CCACHE := $(shell command -v ccache 2>/dev/null)
ifneq ($(CCACHE),)
CPP := $(CCACHE) $(CPP)
CC  := $(CCACHE) $(CC)
endif

# This library's own public header, ahead of anything the world contributes.
INCLUDE := -I include $(CIRCLE_STDLIB_INCLUDES) $(INCLUDE)

# Per-board compile into $(OBJDIR). Circle's Rules.mk %.o rule builds in place;
# these more-specific rules win for the board-scoped object paths. Same recipe
# as Rules.mk, plus $(DEPFLAGS) and a redirected output directory.
$(OBJDIR)/%.o: src/%.cpp | $(OBJDIR)
	@echo "  CPP   $@"
	@$(CPP) $(CPPFLAGS) $(DEPFLAGS) -c -o $@ $<

$(OBJDIR)/%.o: src/%.S | $(OBJDIR)
	@echo "  AS    $@"
	@$(CC) $(AFLAGS) $(DEPFLAGS) -c -o $@ $<

$(OBJDIR):
	@mkdir -p $(OBJDIR)

-include $(DEPS)

else

# The board's world is not configured, so not one of the rules above exists —
# including the rule for this board's archive. The archive FILE may still be on
# disk from whenever it was last built, and make would then report the target
# up to date and exit zero: a build that never ran, reported as a success.
# Phony so the file cannot answer for it.
.PHONY: libfpc-$(BOARD).a
libfpc-$(BOARD).a:
	@echo "$(CIRCLESTDLIBHOME)/Config.mk is missing: the $(BOARD) world is not configured."
	@echo "circle-libfpc does not build worlds. See docs/BUILDING.md."
	@exit 1

endif
