#
# circle-libfpc lineprobe -- a Free Pascal program that never touches SDL,
# linked into circle-libfpc's own generic host kernel (host/host-kernel.mk)
# rather than a kernel of its own, the way examples/m0 through m8 each carry
# one. Beside keyprobe, which proves a single character arrives the instant
# its key is pressed; this one proves a line arrives edited.
#
#   gmake                build the kernel image for BOARD
#   gmake BOARD=rpi5      build against another board's world
#   gmake clean-board     drop this example's objects, blob and image
#
# Everything is built under build/$(BOARD), so one board's build never answers
# for another's -- and `clean-board` rather than `clean` because Circle's
# Rules.mk already defines a `clean`, and two recipes for one target make GNU
# make warn on every build.
#

ifeq ($(filter 1.% 2.% 3.%,$(MAKE_VERSION)),$(MAKE_VERSION))
$(error this build needs GNU make 4.0 or later; this is '$(MAKE)' version '$(MAKE_VERSION)'. Homebrew installs one as gmake.)
endif

BOARDS = rpi3 rpi4 rpi5
BOARD ?= rpi5

ifeq ($(filter $(BOARD),$(BOARDS)),)
$(error BOARD must be one of: $(BOARDS) -- not `$(BOARD)')
endif

# The image name is the one Circle gives each board, and the boot server
# refuses any name that is not kernel*.img.
IMAGE_rpi3 = kernel8
IMAGE_rpi4 = kernel8-rpi4
IMAGE_rpi5 = kernel_2712
IMAGE      = $(IMAGE_$(BOARD))

LIBFPC_HOME   ?= $(CURDIR)/../..
CIRCLE_WORLDS ?= $(LIBFPC_HOME)/circle-libsdl2
SHIM          ?= $(LIBFPC_HOME)/circle-libsdl2

FPC_COMPILER ?= $(LIBFPC_HOME)/fpc/compiler/ppcrossa64
FPC_UNITS    ?= $(LIBFPC_HOME)/fpc/rtl/units/aarch64-circlesdl2

# The board's configured world. A missing one is a wrong variable, never a
# world build to start -- they are circle-libsdl2's to build. Named here so it
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

STANDARD   = -std=c++23 -Wno-volatile
CHECK_DEPS = 0

# sdl-app.mk replaces Circle's own $(TARGET).img rule. Two recipes for one
# target make GNU make warn on every board of every build, which reads like a
# fault and is not one. Pointing TARGET at a name nothing builds while
# Rules.mk is read attaches its rule there instead.
SDL_APP_IMAGE := $(TARGET)
TARGET := $(OBJDIR)/.circle-unused
include $(CIRCLEHOME)/Rules.mk
TARGET := $(SDL_APP_IMAGE)

# circle-libfpc's own host kernel: the board bring-up, the core split, the
# card mount and the C library's standard descriptors, none of it written
# here. It sets INCLUDE for both this library's and circle-libsdl2's headers.
include $(LIBFPC_HOME)/host/host-kernel.mk
OBJS = $(HOST_KERNEL_OBJS)

# The Pascal program. fpc-app.mk needs PREFIX and AR, which Rules.mk has just
# settled, and its results have to be in hand before LIBS and OBJS are
# finished below.
FPC_APP      = lineprobe.pas
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

include $(SHIM)/sdl-app.mk

.PHONY: all clean-board

all: $(TARGET).img

clean-board: fpc-app-clean
	@rm -rf $(OBJDIR)
