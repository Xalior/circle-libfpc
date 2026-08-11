#
# circle-libfpc packages example — a bootable Raspberry Pi 5 kernel that
# exercises the four Free Pascal packages that are not built for
# aarch64-embedded by the compiler install: SyncObjs, Generics.Collections,
# StrUtils and fcl-image.
#
#   make            build kernel-clf-pkg.img
#   make clean      remove everything this makefile made
#   make fpc-contract
#                   list the symbols the application blob leaves for the
#                   host kernel. On a conforming build: _haltproc, _stack_top
#                   and clf_* only.
#
# Build the packages first, once, from the top of this library:
#
#   ./build-packages.sh
#
# fpc-app.mk finds their unit directory the same way it finds the RTL. Without
# it the compile stops at "Can't find unit SyncObjs", which is the gap this
# example exists to close.
#
# The image name matters only if you already have a kernel8.img on the card
# for something else — this example builds kernel-clf-pkg.img so it never
# collides with one.
#

CIRCLELIBFPCHOME = ../..
CIRCLESTDLIBHOME = $(CIRCLELIBFPCHOME)/circle-stdlib-rpi5
CIRCLEHOME       = $(CIRCLESTDLIBHOME)/libs/circle

# First, before the world and before Rules.mk: Rules.mk asks the C++ compiler a
# question while it is being read.
include $(CIRCLELIBFPCHOME)/toolchain.mk

include $(CIRCLESTDLIBHOME)/Config.mk

TARGET      = kernel-clf-pkg
FPC_PROGRAM = packages.pp

# THE HEAP IS THE LIBRARY DEFAULT, 4 MB, AND THAT IS MEASURED RATHER THAN
# GUESSED.
#
# It was 16 MB, on the assumption that deflate's window and hash table and the
# JPEG decoder's component buffers would want room. They do not: running every
# rung reports a peak of 301,536 bytes through GetFPCHeapStatus, so 4 MB leaves
# a factor of thirteen. The rungs print that figure on every boot, so the
# margin is checkable rather than asserted.
#
# It is back at the default for a second reason. The heap is a BSS block fixed
# at build time, and its size was the one structural difference between this
# image and the ladder, which boots and passes on the same library. A
# difference that is not earning anything is a difference worth not having.

OBJS = main.o kernel.o

# The world's full library set. This is a circle-stdlib world, so Circle itself
# was compiled with STDLIB_SUPPORT 4 and its own code calls operator new,
# operator delete, abort and strlen. Leaving newlib and libc++ out fails the
# link inside Circle, naming Circle's source files.
LIBS = $(CIRCLE_STDLIB_LIBS)

# This library's public header.
INCLUDE += -I $(CIRCLELIBFPCHOME)/include

# Circle's Rules.mk defines a link rule for $(TARGET).img, and fpc-app.mk
# replaces it. Point TARGET at a name nothing builds while Rules.mk is read so
# that make has nothing to warn about, then restore it.
FPC_APP_IMAGE := $(TARGET)
TARGET := .circle-unused
include $(CIRCLEHOME)/Rules.mk
TARGET := $(FPC_APP_IMAGE)

include $(CIRCLELIBFPCHOME)/fpc-app.mk

# samples.inc is included by the program, so a regenerated sample rebuilds the
# blob. make does not read a Pascal $I directive.
$(FPC_BLOB): samples.inc

EXTRACLEAN = kernel-clf-pkg.* .circle-unused.*

-include $(DEPS)
