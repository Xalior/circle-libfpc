#
# host-kernel.mk -- the generic Circle host kernel a Free Pascal program runs
# inside.
#
# INCLUDE IT from a port's own Makefile, AFTER Circle's Rules.mk and BEFORE
# fpc-app.mk. Before Rules.mk, set the two things it reads at include time
# that this kernel's own objects need, the same way fpc-app.mk needs PREFIX
# and AR from it:
#
#     STANDARD   = -std=c++23 -Wno-volatile
#     CHECK_DEPS = 0
#     include $(CIRCLEHOME)/Rules.mk
#
#     include $(LIBFPC_HOME)/host/host-kernel.mk
#     OBJS = $(HOST_KERNEL_OBJS)
#
#     FPC_APP = myprogram.pas
#     include $(LIBFPC_HOME)/fpc-app.mk
#     OBJS += $(FPC_APP_OBJS)
#     LIBS := $(FPC_APP_LIBS) $(SHIM)/libSDL2-$(BOARD).a $(CIRCLE_STDLIB_LIBS)
#
#     include $(SHIM)/sdl-app.mk
#
# WHAT THIS KERNEL DOES: brings up core 0's own devices (the serial console,
# the SD card and its FAT filesystem, the C library's standard descriptors),
# starts the secondary cores, declares the working directory and the SDL base
# path, arms the core split, releases the application core to call the Pascal
# program's entry point, and serves it -- draining its log, pumping USB,
# performing its file calls, feeding the presentation core -- until it
# returns, at which point Circle reboots the board. Read host/kernel.h for the
# full shape and host/kernel.cpp for why each step is where it is.
#
# THE VIRTUAL DISPLAY IS NOT DECLARED HERE. circle-libsdl2 reads it out of the
# image's own boot argument block. A port states the size once, in its own
# Makefile, beside the RAPI_WORK_DIR porter value below.
#
# WHAT COMES OUT
#
#   $(HOST_KERNEL_OBJS)   main.o and kernel.o, built under $(OBJDIR). Put them
#                         in OBJS with the Pascal program's own object --
#                         sdl-app-init.ld defers the constructors of anything
#                         arriving as an ARCHIVE member until the kernel
#                         exists, and runs anything arriving as an OBJECT
#                         early.
#
# WHAT IT NEEDS
#
#   LIBFPC_HOME       this library's directory (also where this file is).
#   SHIM              circle-libsdl2's directory, for its headers.
#   OBJDIR            where to put the objects.
#   CIRCLE_STDLIB_INCLUDES, CPP, CPPFLAGS   set by Circle's Rules.mk, already
#                     included by the time this file is.
#
# WHAT IT TAKES IF IT IS GIVEN
#
#   RAPI_WORK_DIR     the working directory this kernel sets, and the base
#                     path it declares to SDL. A build parameter because the
#                     card layout is the consumer's decision, never this
#                     kernel's: a port whose card is laid out differently
#                     sets it rather than editing kernel.cpp. Left unset, the
#                     kernel falls back to the card's root (see kernel.cpp).
#

ifeq ($(strip $(LIBFPC_HOME)),)
$(error host-kernel.mk: set LIBFPC_HOME to circle-libfpc's directory)
endif
ifeq ($(strip $(SHIM)),)
$(error host-kernel.mk: set SHIM to circle-libsdl2's directory)
endif
ifeq ($(strip $(OBJDIR)),)
$(error host-kernel.mk: set OBJDIR before including this file)
endif

# This directory, captured before anything else can change MAKEFILE_LIST --
# the same self-locating trick sdl-app.mk uses, so a port names nothing about
# where this kernel's own sources live.
HOST_KERNEL_DIR := $(patsubst %/,%,$(dir $(lastword $(MAKEFILE_LIST))))

HOST_KERNEL_OBJS = $(OBJDIR)/main.o $(OBJDIR)/kernel.o
HOST_KERNEL_DEPS = $(HOST_KERNEL_OBJS:.o=.d)

INCLUDE := -I $(LIBFPC_HOME)/include -I $(SHIM)/include \
	   $(CIRCLE_STDLIB_INCLUDES) $(INCLUDE)

ifneq ($(strip $(RAPI_WORK_DIR)),)
DEFINE += -DRAPI_WORK_DIR='"$(RAPI_WORK_DIR)"'
endif

# Per-board compile into $(OBJDIR), reading this kernel's own sources rather
# than anything in the port. Circle's Rules.mk builds objects beside their
# source; this more specific rule wins for the board-scoped paths.
$(OBJDIR)/%.o: $(HOST_KERNEL_DIR)/%.cpp | $(OBJDIR)
	@echo "  CPP   $@"
	@$(CPP) $(CPPFLAGS) -MD -MP -c -o $@ $<

$(OBJDIR):
	@mkdir -p $(OBJDIR)

-include $(HOST_KERNEL_DEPS)
