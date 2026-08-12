#
# fpc-app.mk — compile a Free Pascal program into the objects a Circle kernel
# links.
#
# INCLUDE IT from a host kernel's own Makefile, AFTER Circle's Rules.mk (which
# names the cross toolchain this uses) and BEFORE circle-libsdl2's sdl-app.mk
# (which reads the final OBJS and LIBS):
#
#     FPC_APP = myprogram.pas
#     include $(LIBFPC_HOME)/fpc-app.mk
#
#     OBJS += $(FPC_APP_OBJS)
#     LIBS := $(FPC_APP_LIBS) $(SHIM)/libSDL2-$(BOARD).a $(CIRCLE_STDLIB_LIBS)
#
#     include $(SHIM)/sdl-app.mk
#
# WHAT COMES OUT
#
#   $(FPC_APP_OBJS)   the program's own object. It goes in OBJS, with the
#                     kernel's own C++ objects, because it is the application
#                     rather than the framework — sdl-app-init.ld draws that
#                     line by whether something arrived as an object or as an
#                     archive member.
#   $(FPC_APP_LIBS)   the Free Pascal runtime units, any unit the compiler
#                     built from source beside the program, and this library's
#                     C half, all as archives. They go in LIBS, inside the
#                     link's --start-group, because the program's object and
#                     the runtime refer to each other in both directions: the
#                     runtime calls the program's tables, the program calls
#                     the runtime.
#
# WHAT IT NEEDS
#
#   FPC_APP           the Pascal program module, a `program`, not a `unit`.
#   FPC_COMPILER      the cross-compiler, used where it was built.
#   FPC_UNITS         its runtime units for this target.
#   LIBFPC_HOME       this library's directory.
#   BOARD             which board's archive to link.
#   PREFIX, AR        from Circle's Rules.mk.
#
# WHAT IT TAKES IF IT IS GIVEN
#
#   FPC_PACKAGES      Free Pascal's packages directory. Each package that
#                     builds for this target leaves its units in
#                     <package>/units/<cpu>-<os>, and every one of those
#                     directories is put on the unit search path and into the
#                     runtime archive. Without it a program is limited to the
#                     runtime library itself: DateUtils, StrUtils, IniFiles,
#                     Generics.Collections and the rest live in packages.
#
#   FPC_UNIT_SRC_DIRS directories holding Pascal unit SOURCE the program may
#                     name — a third-party binding, or a unit of this
#                     library's own. Unlike FPC_UNITS and FPC_PACKAGES, which
#                     hold units already compiled for this target, these are
#                     compiled on demand into the blob directory when a
#                     program names them, and every object that appears there
#                     beside the program's own is archived and linked.
#
#                     THAT ARCHIVE IS WHY THIS SETTING IS MORE THAN A SEARCH
#                     PATH. A unit compiled from source leaves its object in
#                     the blob directory, and until this was here nothing
#                     collected it: the compile succeeded, the program's own
#                     object linked, and the link then failed on every routine
#                     the unit implements — or, for a unit that is only
#                     declarations, succeeded while leaving its initialisation
#                     section out of the image.
#

ifeq ($(strip $(FPC_APP)),)
$(error fpc-app.mk: set FPC_APP to the Pascal program module before including it)
endif
ifeq ($(strip $(LIBFPC_HOME)),)
$(error fpc-app.mk: set LIBFPC_HOME to circle-libfpc's directory)
endif
ifeq ($(wildcard $(FPC_COMPILER)),)
$(error fpc-app.mk: no Free Pascal cross-compiler at `$(FPC_COMPILER)'. Build it with `gmake fpc' in the parent repository; never fetch or install one)
endif
ifeq ($(wildcard $(FPC_UNITS)/system.ppu),)
$(error fpc-app.mk: no runtime units at `$(FPC_UNITS)'. That directory is what `gmake fpc' leaves behind; a missing one is a wrong variable, not a build to start)
endif

FPC_CPU ?= aarch64
FPC_OS  ?= circlesdl2

# EVERY UNIT DIRECTORY THE PROGRAM MAY REACH, THE RUNTIME'S FIRST.
#
# Free Pascal builds each package into a unit directory of its own rather than
# into one place, so the list is expanded from the packages directory rather
# than written down: a package that does not build for this target leaves no
# such directory and simply is not on the list. Naming them individually would
# be a second copy of a decision that already lives in each package's
# fpmake.pp.
FPC_PACKAGE_UNITS = $(if $(FPC_PACKAGES),\
	$(wildcard $(FPC_PACKAGES)/*/units/$(FPC_CPU)-$(FPC_OS)))
FPC_UNIT_DIRS     = $(FPC_UNITS) $(FPC_PACKAGE_UNITS)

# Unit SOURCE directories come after the compiled ones, so a unit that exists
# in both is taken already built.
ifneq ($(strip $(FPC_UNIT_SRC_DIRS)),)
FPC_MISSING_SRC_DIRS := $(filter-out $(wildcard $(FPC_UNIT_SRC_DIRS)),$(FPC_UNIT_SRC_DIRS))
ifneq ($(strip $(FPC_MISSING_SRC_DIRS)),)
$(error fpc-app.mk: FPC_UNIT_SRC_DIRS names a directory that is not there: $(FPC_MISSING_SRC_DIRS))
endif
endif

# Where the blob is built, and where the record of what built it sits beside
# it. Both are gitignored.
FPC_BLOB_DIR  ?= fpcblob
FPC_RTL_STAMP ?= $(FPC_BLOB_DIR).rtl-stamp

# THE COMPILER MUST BE TOLD WHERE THE ASSEMBLER IS, ON EVERY INVOCATION.
#
# Without -XP and -FD it looks for an assembler named after the target, does
# not find one, and stops. Circle's Rules.mk has already settled which cross
# toolchain this build uses, so the same one is handed to Free Pascal — the
# objects have to link into Circle's build, and one assembler in the picture
# is how that stays true.
FPC_BINUTILS_DIR ?= $(patsubst %/,%,$(dir $(shell command -v $(PREFIX)as 2>/dev/null)))
ifeq ($(strip $(FPC_BINUTILS_DIR)),)
$(error fpc-app.mk: $(PREFIX)as is not on PATH, so Free Pascal has no assembler to be pointed at)
endif

# FREE PASCAL NAMES THE PROGRAM'S C ENTRY `main`, AND SO DOES CIRCLE.
#
# The compiler emits one routine with two names: `main`, for a C runtime that
# starts a program by calling it, and PASCALMAIN. Circle's own start-up calls
# main() to construct the kernel, so leaving the Pascal one called `main`
# collides with the host kernel's. -XM renames it; PASCALMAIN is untouched and
# is what a host kernel calls.
FPC_MAIN_ALIAS ?= fpc_program_main

FPC_FLAGS = -T$(FPC_OS) -P$(FPC_CPU) -vq -XM$(FPC_MAIN_ALIAS) \
	$(addprefix -Fu,$(FPC_UNIT_DIRS) $(FPC_UNIT_SRC_DIRS)) \
	-FU$(FPC_BLOB_DIR) -FE$(FPC_BLOB_DIR) \
	-XP$(PREFIX) -FD$(FPC_BINUTILS_DIR)

FPC_APP_OBJ  = $(FPC_BLOB_DIR)/$(basename $(notdir $(FPC_APP))).o
FPC_RTL_LIB  = $(FPC_BLOB_DIR)/libfpcrtl.a
FPC_RTL_OBJS := $(wildcard $(addsuffix /*.o,$(FPC_UNIT_DIRS)))
FPC_UNIT_LIB = $(FPC_BLOB_DIR)/libfpcunits.a

FPC_APP_OBJS = $(FPC_APP_OBJ)
FPC_APP_LIBS = $(FPC_RTL_LIB) $(FPC_UNIT_LIB) $(LIBFPC_HOME)/libfpc-$(BOARD).a

# WHICH RUNTIME THE BLOB WAS BUILT AGAINST, AND WHY IT IS A FILE.
#
# Nothing in the obvious dependency graph ties the image to the compiler and
# the runtime units that produced it. Point FPC_UNITS at a different runtime,
# or rebuild the compiler, and every source file is still older than every
# object: make finds the whole tree up to date and the previous runtime's blob
# is left sitting inside a new image. Two builds against two different
# runtimes then produce byte-identical images, and nothing says so.
#
# So the compiler and every runtime unit are hashed, the answer is recorded
# here, and when it does not match the recorded one the BLOB TREE IS DELETED —
# at parse time, before make decides anything. A missing object has to be
# rebuilt, and a rebuilt object relinks the image; there is no timestamp
# comparison left to get wrong.
#
# The record is rewritten only when the answer changes, so a repeat build
# against the same runtime stays fully incremental.
#
# Skipped under `make -n`, which expands this the same as a real run and would
# otherwise have a dry run delete build artifacts.
FPC_RTL_ID := $(shell shasum -a 256 $(FPC_COMPILER) \
	$(wildcard $(addsuffix /*,$(FPC_UNIT_DIRS))) 2>/dev/null \
	| shasum -a 256 | cut -d' ' -f1)

ifeq (,$(findstring n,$(firstword -$(MAKEFLAGS))))
$(shell mkdir -p $(dir $(FPC_RTL_STAMP)); \
	[ "$$(cat $(FPC_RTL_STAMP) 2>/dev/null)" = "$(FPC_RTL_ID)" ] \
	|| { echo $(FPC_RTL_ID) > $(FPC_RTL_STAMP); rm -rf $(FPC_BLOB_DIR); })
endif

# The refusal to link, and the check that the objects are real, are in
# fpc-compile.sh; read its header for what the compiler does here and why the
# exit code alone cannot be the test.
FPC_UNIT_SRCS := $(wildcard $(addsuffix /*.pas,$(FPC_UNIT_SRC_DIRS)) \
	$(addsuffix /*.pp,$(FPC_UNIT_SRC_DIRS)) \
	$(addsuffix /*.inc,$(FPC_UNIT_SRC_DIRS)))

$(FPC_APP_OBJ): $(FPC_APP) $(FPC_UNIT_SRCS) | $(FPC_BLOB_DIR)
	@echo "  FPC   $@"
	@$(LIBFPC_HOME)/fpc-compile.sh $(FPC_BLOB_DIR)/fpc-compile.log \
		$(PREFIX)nm $@ $(FPC_COMPILER) $(FPC_FLAGS) $(FPC_EXTRA_FLAGS) $(FPC_APP)

# The runtime units and the package units as one archive, so the link takes
# the ones the program actually reaches and leaves the rest out. Free Pascal
# builds every unit of every package that names this target, which is far more
# than any one program uses; a program that reads an INI file should not carry
# the JPEG decoder.
$(FPC_RTL_LIB): $(FPC_RTL_OBJS) | $(FPC_BLOB_DIR)
	@echo "  AR    $@"
	@rm -f $@
	@$(AR) cr $@ $(FPC_RTL_OBJS)

# EVERY OBJECT THE COMPILER LEFT IN THE BLOB BESIDE THE PROGRAM'S OWN.
#
# That is one object per unit the compiler had to build from source — a
# third-party binding named in FPC_UNIT_SRC_DIRS, or a unit of this library's.
# A unit that came ready-built out of FPC_UNITS or FPC_PACKAGES is not here;
# its object is in the runtime archive above.
#
# The list is read when the recipe runs rather than when this file is parsed,
# because it does not exist until the compile above has happened. It is a
# shell listing rather than $(wildcard) for the same reason: make reads a
# directory once and answers from that reading for the rest of the run, so a
# $(wildcard) over the blob would report what was there before the compiler
# wrote to it.
#
# An archive, not a list of objects, so the link takes only the units the
# program reaches — a binding that declares the whole of a library leaves the
# parts nobody calls out of the image.
#
# WITH NOTHING TO PUT IN IT the file is written as an empty archive by hand.
# `ar' refuses to create one with no members named, and the link needs the
# file to exist either way; `!<arch>' with nothing after it is what an empty
# archive is.
$(FPC_UNIT_LIB): $(FPC_APP_OBJ)
	@echo "  AR    $@"
	@rm -f $@
	@objs=`ls $(FPC_BLOB_DIR)/*.o 2>/dev/null | grep -vx '$(FPC_APP_OBJ)'`; \
	if [ -n "$$objs" ]; then $(AR) cr $@ $$objs; else printf '!<arch>\n' > $@; fi

$(FPC_BLOB_DIR):
	@mkdir -p $(FPC_BLOB_DIR)

.PHONY: fpc-app-clean
fpc-app-clean:
	@rm -rf $(FPC_BLOB_DIR) $(FPC_RTL_STAMP)
