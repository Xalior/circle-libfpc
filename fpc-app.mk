# fpc-app.mk — application blob rules and kernel image link rule for
# circle-libfpc applications.
#
# Include AFTER Circle's Rules.mk. A consumer names its Pascal program and gets
# a bootable image:
#
#   FPC_PROGRAM = myprog.pp
#   OBJS        = main.o kernel.o
#   LIBS        = $(CIRCLEHOME)/lib/sched/libsched.a $(CIRCLEHOME)/lib/libcircle.a
#
#   FPC_APP_IMAGE := $(TARGET)
#   TARGET := $(OBJDIR)/.circle-unused
#   include $(CIRCLEHOME)/Rules.mk
#   TARGET := $(FPC_APP_IMAGE)
#   include /path/to/circle-libfpc/fpc-app.mk
#
# Circle's Rules.mk defines a link rule for $(TARGET).img as well, and the rule
# here replaces it. Make warns when a recipe is overridden — twice, once for
# each side — which reads like something going wrong to anyone who has not been
# told it is expected. Pointing TARGET at a name nothing builds while Rules.mk
# is read, and restoring it afterwards, avoids that: Circle's rule attaches to
# the throwaway name, this one is the only recipe for the image, and nothing
# warns.
#
# WHY THE BLOB RULES LIVE HERE rather than in each consumer's makefile: they
# are four steps, and three of them are traps that cost a hardware boot each to
# find. See docs/CONTRACT.md.

# This directory, captured before anything else can change MAKEFILE_LIST.
FPC_APP_DIR := $(dir $(lastword $(MAKEFILE_LIST)))

ifeq ($(strip $(FPC_PROGRAM)),)
$(error FPC_PROGRAM must name the Pascal program this kernel runs)
endif

# The board follows from the world the consumer already included, so a
# consumer cannot link one board's archive into another board's kernel by
# forgetting to say which board it is building for.
FPC_BOARD ?= rpi$(RASPPI)
FPCLIB    ?= $(FPC_APP_DIR)libfpc-$(FPC_BOARD).a

# THE FREE PASCAL CROSS COMPILER AND ITS RUNTIME.
#
# Not the system `fpc`: this is a cross-compiler for the aarch64-embedded
# target, built for the machine you compile ON, and its runtime library must be
# the one with the THREADING feature enabled. The stock aarch64-embedded RTL
# has that feature compiled out, and on it a single `threadvar` declaration is
# a fatal compile error.
#
# Searched for in the same shape as the Arm toolchain, and for the same reason:
#
#   $RAPI_FPC_DIR       names where the Free Pascal trees live
#   toolchains/         beside this library
#   ../toolchains/      one level up
#   ../../toolchains/   two levels up
FPC_SEARCH := $(RAPI_FPC_DIR) $(FPC_APP_DIR)toolchains \
              $(FPC_APP_DIR)../toolchains $(FPC_APP_DIR)../../toolchains

FPC    ?= $(firstword $(wildcard $(addsuffix /fpc-embedded/lib/fpc/*/ppcrossa64,$(FPC_SEARCH))))
FPCRTL ?= $(firstword $(wildcard $(addsuffix /fpc-trunk-threads/rtl/units/aarch64-embedded,$(FPC_SEARCH))))

# THE FREE PASCAL PACKAGES, IF THEY HAVE BEEN BUILT.
#
# SyncObjs, Generics.Collections, StrUtils and fcl-image are not part of the
# RTL and are not built by the buildbase/installbase pair that installs this
# target's compiler. build-packages.sh builds them; a program that uses none of
# them needs none of this, so an empty result is not an error.
FPCPKG ?= $(firstword $(wildcard $(addsuffix /fpc-packages-embedded/units/aarch64-embedded,$(FPC_SEARCH))))
FPC_UNITPATHS = $(abspath $(FPCRTL)) $(abspath $(FPC_APP_DIR)rtl) $(abspath $(FPCPKG))

# The assembler and linker Free Pascal drives for this target. It writes
# `aarch64-elf-` tool names, which is not the Arm GNU toolchain's
# `aarch64-none-elf-` prefix, so this is its own setting rather than the one
# the C++ side uses.
FPCBINUTILS ?= $(firstword $(wildcard /opt/homebrew/opt/aarch64-elf-binutils/bin \
                                      /usr/local/opt/aarch64-elf-binutils/bin))

# THE HEAP IS FIXED AT BUILD TIME AND THERE IS NO GROWTH AT RUN TIME.
#
# The compiler emits a block of this size into the program's BSS and heapmgr
# hands it to the allocator. It must fit under Circle's MEM_KERNEL_END, which
# the world sets with its kernel-max-size; a block that does not fit fails
# sysinit's kernel size check at boot rather than at link.
FPC_HEAP_SIZE ?= 4194304

# Extra options for the blob compile — a consumer's unit search paths, its
# mode switch, its optimisation level.
FPCFLAGS ?=

FPC_OBJDIR  ?= fpcblob
FPC_PROGDIR  = $(dir $(abspath $(FPC_PROGRAM)))
FPC_PROGNAME = $(basename $(notdir $(FPC_PROGRAM)))
FPC_BLOB     = $(FPC_OBJDIR)/$(FPC_PROGNAME)-all.o

# WHICH RUNTIME THE BLOB WAS COMPILED AGAINST, AS A FILE.
#
# The blob's prerequisites are files: the program and this library's own rtl/.
# FPCRTL is a setting rather than a file, so pointing it at a different runtime
# leaves every prerequisite untouched and make finds nothing to do — the second
# build keeps the first build's blob and produces an image identical to it,
# byte for byte, and reports success. Comparing two runtimes is precisely when
# someone changes this setting, so the null result arrives looking like an
# answer.
#
# This stamp file holds the runtime the blob was last compiled against. It is a
# prerequisite of the blob, and it is rewritten ONLY when the value it holds
# differs from the current FPCRTL — so a changed runtime makes it newer than
# the blob and forces the compile, and an unchanged runtime leaves its
# timestamp alone and rebuilds nothing.
#
# It sits beside the blob directory rather than inside it, because the blob
# recipe empties that directory before it compiles. `make clean` removes it.
FPC_RTL_STAMP = $(FPC_OBJDIR).rtl-stamp

.PHONY: fpc-rtl-force
fpc-rtl-force:

$(FPC_RTL_STAMP): fpc-rtl-force
	@printf '%s\n' '$(abspath $(FPCRTL))' | cmp -s - $@ || \
		{ printf '%s\n' '$(abspath $(FPCRTL))' > $@; \
		  echo "  FPCRTL $(abspath $(FPCRTL))"; }

ifeq ($(strip $(FPC)),)
$(error no aarch64-embedded Free Pascal cross compiler found. Set FPC, or RAPI_FPC_DIR)
endif
ifeq ($(strip $(FPCRTL)),)
$(error no threading-enabled aarch64-embedded RTL found. Set FPCRTL, or RAPI_FPC_DIR)
endif

# THE APPLICATION BLOB, in four steps.
#
# 1. Compile. -s stops after the assembly files are written, so ppas.sh does
#    the assembling. rtl/ is on the unit path so the program can `uses
#    circlefpc` and get the heap and the thread manager installed.
#
# 2. Run ppas.sh FROM THE DIRECTORY THE COMPILER RAN IN. Its paths are relative
#    to that, so running it from inside the output directory fails with "can't
#    create out/x.o: No such file or directory", which reads as a permissions
#    or a toolchain fault. Its own link step is useless here — --gc-sections
#    with no entry point empties the image — so it is expected to fail and the
#    failure is ignored; the object files it produced are what matter.
#
# 3. Fold the program object and the runtime units it used into ONE
#    relocatable object. The compiler writes the list into link*.res, naming
#    objects it built itself relative to the compile directory and RTL units
#    with absolute paths.
#
#    That list is checked before it is used. It can name a unit's object on a
#    search path while this compile has just written its own object of that
#    name, which happens when a source replaces a unit that is already built
#    somewhere on the unit path — and a blob assembled from that list is built
#    from the copy the recompile was meant to replace, with nothing else
#    reporting it. fpc-objlist-check.sh explains the case and stops the build.
#
# 4. Localise `main`. The compiler emits a global `main` at the same address as
#    PASCALMAIN. Circle's own main() has that name, so the two collide at link.
#    Nothing calls the Pascal one: a host kernel calls PASCALMAIN directly.
.PHONY: fpc-blob
fpc-blob: $(FPC_BLOB)

$(FPC_BLOB): $(FPC_PROGRAM) $(wildcard $(FPC_APP_DIR)rtl/*.pp) $(FPC_RTL_STAMP)
	@echo "  FPC   $(FPC_PROGRAM) -> $@"
	@rm -rf $(FPC_OBJDIR)
	@mkdir -p $(FPC_OBJDIR)
	@cd $(FPC_PROGDIR) && $(abspath $(FPC)) -Tembedded -Paarch64 \
		-XPaarch64-elf- -FD$(FPCBINUTILS) \
		$(addprefix -Fu,$(FPC_UNITPATHS)) \
		-FU$(abspath $(FPC_OBJDIR)) -FE$(abspath $(FPC_OBJDIR)) \
		-Ch$(FPC_HEAP_SIZE) $(FPCFLAGS) -s -B $(notdir $(FPC_PROGRAM))
	@cd $(FPC_PROGDIR) && sh $(abspath $(FPC_OBJDIR))/ppas.sh \
		> $(abspath $(FPC_OBJDIR))/ppas.log 2>&1 || true
	@test -f $(FPC_OBJDIR)/$(FPC_PROGNAME).o || \
		{ echo "$(FPC_PROGNAME): assembly produced no object; see $(FPC_OBJDIR)/ppas.log"; exit 1; }
	@set -e; res=$$(ls $(FPC_OBJDIR)/link*.res); \
		sh $(FPC_APP_DIR)fpc-objlist-check.sh "$$res" $(FPC_OBJDIR)
	@echo "  LD -r $@"
	@set -e; res=$$(ls $(FPC_OBJDIR)/link*.res); \
		objs=$$(sed -n '/^INPUT (/,/^)/p' "$$res" | grep -v '^INPUT (' | grep -v '^)'); \
		objs=$$(echo "$$objs" | sed "s|^\([^/]*\)$$|$(FPC_OBJDIR)/\1|"); \
		$(FPCBINUTILS)/aarch64-elf-ld -r -o $@ $$objs
	@$(FPCBINUTILS)/aarch64-elf-objcopy --localize-symbol=main $@

# Circle's Rules.mk clean removes files by wildcard and the blob tree is a
# directory, so it gets its own target and clean is given it as a prerequisite.
.PHONY: fpc-clean
fpc-clean:
	@rm -rf $(FPC_OBJDIR) $(FPC_RTL_STAMP)

clean: fpc-clean

# WHAT THE BLOB LEAVES FOR THE HOST KERNEL. On a conforming build this is
# _haltproc, _stack_top and whatever C functions the application declared for
# itself — nothing else. Anything more is a finding.
.PHONY: fpc-contract
fpc-contract: $(FPC_BLOB)
	@echo "== undefined symbols left by $(FPC_BLOB) =="
	@$(FPCBINUTILS)/aarch64-elf-nm -u $(FPC_BLOB) | sed 's/^/  /'

# This library's archive goes in after the application's own objects and before
# Circle, so the blob's _haltproc and _stack_top are resolved from it and a
# host kernel that defines either for itself still wins.
LIBS := $(FPCLIB) $(LIBS)

# LIBS is passed to the linker as it stands, so a consumer may put linker flags
# in it. A flag is not a file, so the prerequisite list takes the file subset;
# left in, make would try to build the flag and stop.
FPC_LIBS_FILES = $(filter-out -%,$(LIBS))

# A missing archive is otherwise "No rule to make target 'libfpc-rpi5.a'",
# which names a file and not the thing to do about it. This library is not
# built from a consumer's tree — the board it is built for is a choice, and
# making it silently here would hide a consumer building against the wrong one.
$(FPCLIB):
	@echo "$(FPCLIB) does not exist."
	@echo "Build it: $(MAKE) -C $(FPC_APP_DIR) BOARD=$(FPC_BOARD)"
	@exit 1

FPC_APP_LDSCRIPT ?= $(CIRCLEHOME)/circle.ld

# THE DEFAULT GOAL IS THE IMAGE, said outright.
#
# Circle's Rules.mk has no `all` target: the first target it defines is
# $(TARGET).img, and that becoming the default goal is how a Circle kernel
# builds by typing `make`. Under the TARGET dance above, the name Rules.mk
# defines begins with a dot, and GNU make skips a target beginning with a dot
# when it chooses the default goal — so the default goal silently became
# `clean`, and a plain `make` deleted the build instead of producing it.
.DEFAULT_GOAL := $(TARGET).img

$(TARGET).img: $(OBJS) $(FPC_BLOB) $(FPC_LIBS_FILES) $(FPC_APP_LDSCRIPT)
	@echo "  LD    $(TARGET).elf"
	@$(LD) -o $(TARGET).elf -Map $(TARGET).map $(LDFLAGS) \
		-T $(FPC_APP_LDSCRIPT) $(CRTBEGIN) $(OBJS) $(FPC_BLOB) \
		--start-group $(LIBS) $(EXTRALIBS) --end-group $(CRTEND)
	@echo "  DUMP  $(TARGET).lst"
	@$(OBJDUMP) -d $(TARGET).elf | $(CPPFILT) > $(TARGET).lst
	@echo "  COPY  $(TARGET).img"
	@$(OBJCOPY) $(TARGET).elf -O binary $(TARGET).img
	@echo -n "  WC    $(TARGET).img => "
	@wc -c < $(TARGET).img
