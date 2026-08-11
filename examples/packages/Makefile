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

# THE HEAP IS BIGGER THAN THE LADDER'S, AND ON PURPOSE.
#
# The PNG writer runs paszlib's deflate, which takes a window, a hash table and
# an output buffer of its own, and the JPEG decoder builds its own component
# and coefficient buffers. 4 MB is the library default and it is sized for a
# program that only allocates strings and objects. The heap is a BSS block
# fixed at build time with no growth at run time, so it is set here rather than
# discovered on the board.
FPC_HEAP_SIZE = 16777216

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
