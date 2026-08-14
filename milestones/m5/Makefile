#
# circle-libfpc M5 — Pascal files on the card, through circle-libsdl2's file
# service.
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
# THIS EXAMPLE'S BUILD CARRIES A CHECK THE OTHERS DO NOT. See the bottom of
# this file: the Pascal side is not allowed to reference any of the C
# library's file calls, and the build stops if it does.
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
# here is Free Pascal — it is the board being brought up, the card being
# mounted, and the Pascal entry point being called.
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

# The Pascal program. fpc-app.mk needs PREFIX and AR, which Rules.mk has just
# settled, and its results have to be in hand before LIBS and OBJS are
# finished below.
FPC_APP      = m5.pas
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

# ---------------------------------------------------------------------------
# THE PASCAL SIDE MUST NOT BE ABLE TO REACH THE CARD.
#
# CLF-003 and CLF-006 make a direct device access from this library or from
# Pascal application code a non-conformance rather than an untidiness, and a
# claim in a comment is not a check. This one is.
#
# Every route from Pascal to the card that is not circle-libsdl2's file
# service has to resolve one of the names below: the C library's file
# syscalls, its stdio and directory calls, or FatFs itself. So the Pascal
# program's object, the Free Pascal runtime archive and this library's own C
# half are read for their UNDEFINED symbols, and the build stops if any of
# those names is among them.
#
# It would catch a real violation, because there is no way to call one of
# these without naming it: they are C symbols resolved at link time, and this
# runs before the link.
#
# What it does NOT cover, said plainly: a call made through a function pointer
# handed over from the C++ side, and the C half of this library reaching a
# device by inline assembly. The first is not a shape anything here uses; the
# second is covered by the same read, because libfpc's archive is in the list.
# ---------------------------------------------------------------------------

CARD_SYMBOLS = \
	open close read write lseek fstat stat lstat fsync ftruncate truncate \
	_open _close _read _write _lseek _fstat _stat _fsync \
	unlink _unlink remove rename _rename mkdir rmdir chdir getcwd \
	opendir readdir closedir rewinddir fdopendir scandir \
	fopen fdopen freopen fclose fread fwrite fseek fseeko ftell ftello \
	fgets fputs fgetc fputc fprintf fscanf rewind setvbuf tmpfile \
	f_open f_close f_read f_write f_lseek f_sync f_truncate f_stat \
	f_unlink f_mkdir f_chdir f_getcwd f_rename f_opendir f_readdir \
	f_closedir f_mount f_size f_tell

PASCAL_SIDE = $(FPC_APP_OBJS) $(FPC_APP_LIBS)

$(OBJDIR)/no-card-route.stamp: $(PASCAL_SIDE) | $(OBJDIR)
	@echo "  CHECK $@"
	@$(PREFIX)nm -u --format=posix $(PASCAL_SIDE) \
		| awk '$$2 == "U" { print $$1 }' | sort -u > $(OBJDIR)/pascal-undefined.txt
	@bad=""; \
	for s in $(CARD_SYMBOLS); do \
		if grep -qx "$$s" $(OBJDIR)/pascal-undefined.txt; then bad="$$bad $$s"; fi; \
	done; \
	if [ -n "$$bad" ]; then \
		echo "the Pascal side references the C library's own card route:$$bad" >&2; \
		echo "CLF-003: every crossing goes through circle-libsdl2. See $(OBJDIR)/pascal-undefined.txt." >&2; \
		exit 1; \
	fi
	@echo "  ---   the Pascal side reaches the card only through:"
	@grep '^SDL2Circle_IO' $(OBJDIR)/pascal-undefined.txt | sed 's/^/        /'
	@touch $@

# The image is not built until that has passed.
$(TARGET).img: $(OBJDIR)/no-card-route.stamp

.PHONY: all clean-board

all: $(TARGET).img

clean-board: fpc-app-clean
	@rm -rf $(OBJDIR)
