#
# circle-libfpc ladder example — a bootable Raspberry Pi 5 kernel that climbs
# the Free Pascal runtime one rung at a time and reports each over the UART.
#
#   make            build kernel-clf.img
#   make clean      remove everything this makefile made
#   make fpc-contract
#                   list the symbols the application blob leaves for the
#                   host kernel. On a conforming build: _haltproc, _stack_top
#                   and clf_* only.
#
# The image name matters only if you already have a kernel8.img on the card
# for something else — this example builds kernel-clf.img so it never
# collides with one.
#

CIRCLELIBFPCHOME = ../..
CIRCLESTDLIBHOME = $(CIRCLELIBFPCHOME)/circle-stdlib-rpi5
CIRCLEHOME       = $(CIRCLESTDLIBHOME)/libs/circle

# First, before the world and before Rules.mk: Rules.mk asks the C++ compiler a
# question while it is being read.
include $(CIRCLELIBFPCHOME)/toolchain.mk

include $(CIRCLESTDLIBHOME)/Config.mk

TARGET      = kernel-clf
FPC_PROGRAM = ladder.pp

OBJS = main.o kernel.o

# THE WORLD'S FULL LIBRARY SET, INCLUDING NEWLIB AND libc++.
#
# The Free Pascal runtime asks for no C library, and a Pascal blob linked
# against plain Circle needs none. This world is not plain Circle: it is a
# circle-stdlib world, so Circle itself was compiled with STDLIB_SUPPORT 4 and
# its own code calls operator new, operator delete, abort and strlen, which
# newlib and libc++ supply. Leaving them out fails the link inside Circle,
# naming Circle's source files — which reads as a broken world rather than a
# short library list.
#
# It is the right world all the same: a kernel that links circle-libsdl2
# beside this library needs a circle-stdlib world too, and two libraries in
# one image must agree about the world they were compiled for.
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

EXTRACLEAN = kernel-clf.* .circle-unused.*

-include $(DEPS)
