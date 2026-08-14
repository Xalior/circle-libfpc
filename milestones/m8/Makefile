#
# circle-libfpc M8 — SDL, driven from Free Pascal.
#
#   gmake                build the kernel image for BOARD
#   gmake BOARD=rpi5     build against another board's world
#   gmake clean-board    drop this milestone's objects, blob and image
#
# Everything is built under build/$(BOARD), so one board's build never answers
# for another's — and `clean-board` rather than `clean` because Circle's
# Rules.mk already defines a `clean`, and two recipes for one target make GNU
# make warn on every build.
#

ifeq ($(filter 1.% 2.% 3.%,$(MAKE_VERSION)),$(MAKE_VERSION))
$(error this build needs GNU make 4.0 or later; this is '$(MAKE)' version '$(MAKE_VERSION)'. Homebrew installs one as gmake.)
endif

BOARDS = rpi3 rpi4 rpi5
BOARD ?= rpi5

ifeq ($(filter $(BOARD),$(BOARDS)),)
$(error BOARD must be one of: $(BOARDS) — not `$(BOARD)')
endif

# The image name is the one Circle gives each board, and the boot server
# refuses any name that is not kernel*.img.
IMAGE_rpi3 = kernel8
IMAGE_rpi4 = kernel8-rpi4
IMAGE_rpi5 = kernel_2712
IMAGE      = $(IMAGE_$(BOARD))

LIBFPC_HOME   ?= $(CURDIR)/../..
CIRCLE_WORLDS ?= $(LIBFPC_HOME)
SHIM          ?= $(LIBFPC_HOME)

FPC_COMPILER ?= $(LIBFPC_HOME)/fpc/compiler/ppcrossa64
FPC_UNITS    ?= $(LIBFPC_HOME)/fpc/rtl/units/aarch64-circlesdl2

# The board's configured world. A missing one is a wrong variable, never a
# world build to start — they are circle-libsdl2's to build. Named here so it
# arrives as that rather than as make having no rule for a Config.mk.
WORLD = $(CIRCLE_WORLDS)/circle-stdlib-$(BOARD)
ifeq ($(wildcard $(WORLD)/Config.mk),)
$(error the $(BOARD) world is not configured ($(WORLD)/Config.mk is missing). CIRCLE_WORLDS says where the worlds are.)
endif

include $(WORLD)/Config.mk

OBJDIR = build/$(BOARD)
TARGET = $(OBJDIR)/$(IMAGE)

# Stated explicitly: the first rule this file sees comes from an included
# makefile, and that would otherwise decide the default goal.
.DEFAULT_GOAL := all

# The host kernel's own translation units. Nothing here is SDL, and nothing
# here is Free Pascal — it is the board being brought up and the Pascal entry
# point being called.
HOST_OBJS = $(OBJDIR)/main.o $(OBJDIR)/kernel.o
OBJS      = $(HOST_OBJS)

STANDARD = -std=c++23 -Wno-volatile

# Dependency files are written while compiling rather than by rules of their
# own, and Circle's Rules.mk is told to keep its hands off (CHECK_DEPS) so its
# `-M -MG` rules are not defined for these objects: -MG stops the build on a
# header it has no rule for, and GNU make 3.81 does so with no output at all.
# -MP adds a recipeless rule for every header named, so a header that
# disappears is a rebuild instead of a dead stop.
CHECK_DEPS = 0
DEPFLAGS   = -MD -MP
DEPS       = $(HOST_OBJS:.o=.d)

# sdl-app.mk replaces Circle's own $(TARGET).img rule. Two recipes for one
# target make GNU make warn on every board of every build, which reads like a
# fault and is not one. Pointing TARGET at a name nothing builds while
# Rules.mk is read attaches its rule there instead.
SDL_APP_IMAGE := $(TARGET)
TARGET := $(OBJDIR)/.circle-unused
include $(CIRCLEHOME)/Rules.mk
TARGET := $(SDL_APP_IMAGE)

INCLUDE := -I $(LIBFPC_HOME)/include -I $(SHIM)/include \
	   $(CIRCLE_STDLIB_INCLUDES) $(INCLUDE)

# THE SDL2 BINDING THE PROGRAM IS WRITTEN AGAINST, AS PASCAL SOURCE.
#
# It is not this project's, and it is not built into the runtime: it is the
# ordinary Pascal SDL2 binding that Pascal SDL programs already carry, named
# here as a source directory so that the compiler builds it beside the program
# the way it does for the game that shipped it. A port is then a relink.
#
# SDL2_PASCAL_UNITS says where that binding is. It defaults to this
# library's own vendored copy — third-party/sdl2-for-pascal, which already
# carries the CIRCLESDL2 patch described in patches/README.md — so this
# milestone builds with nothing pointing outside the repository. A program
# porting a different copy of the binding overrides it.
#
# THE SECOND DIRECTORY IS THIS LIBRARY'S OWN, and it holds one unit:
# circle-libsdl2's Circle extensions, which no SDL binding carries because
# they are not in SDL's headers. An application names it beside its binding,
# exactly as a C application adds one #include.
SDL2_PASCAL_UNITS ?= $(LIBFPC_HOME)/third-party/sdl2-for-pascal
ifeq ($(strip $(SDL2_PASCAL_UNITS)),)
$(error set SDL2_PASCAL_UNITS to the directory holding the Pascal SDL2 binding (sdl2.pas and its .inc files))
endif

FPC_UNIT_SRC_DIRS = $(SDL2_PASCAL_UNITS) $(LIBFPC_HOME)/units

# The Pascal program. fpc-app.mk needs PREFIX and AR, which Rules.mk has just
# settled, and its results have to be in hand before LIBS and OBJS are
# finished below.
FPC_APP      = m8.pas
FPC_BLOB_DIR = $(OBJDIR)/fpcblob
include $(LIBFPC_HOME)/fpc-app.mk

# The program's own object joins the kernel's. sdl-app-init.ld defers the
# constructors of everything arriving as an OBJECT until the kernel exists,
# and runs everything arriving as an ARCHIVE member early; the Pascal blob is
# the application, so it belongs on the object side of that line.
OBJS += $(FPC_APP_OBJS)

# The Free Pascal runtime units and this library's C half go inside the link's
# --start-group with everything else: the program's object and the runtime
# refer to each other in both directions, so neither can simply come first.
LIBS := $(FPC_APP_LIBS) $(SHIM)/libSDL2-$(BOARD).a $(CIRCLE_STDLIB_LIBS)

# Per-board compile into $(OBJDIR). Circle's Rules.mk builds objects beside
# their source; this more specific rule wins for the board-scoped paths. Same
# recipe as Rules.mk, plus $(DEPFLAGS) and a redirected output directory.
$(OBJDIR)/%.o: %.cpp | $(OBJDIR)
	@echo "  CPP   $@"
	@$(CPP) $(CPPFLAGS) $(DEPFLAGS) -c -o $@ $<

$(OBJDIR):
	@mkdir -p $(OBJDIR)

-include $(DEPS)

include $(SHIM)/sdl-app.mk

.PHONY: all clean-board

all: $(TARGET).img

clean-board: fpc-app-clean
	@rm -rf $(OBJDIR)
