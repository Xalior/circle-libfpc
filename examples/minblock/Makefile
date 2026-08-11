#
# circle-libfpc minblock example — the smallest bootable image that
# demonstrates Free Pascal's embedded heap manager overrunning a 16-byte block
# with its 24-byte free-list node on a 64-bit target. See minblock.pp.
#
#   make                     kernel-minblock.img, against the stock runtime
#   make FPCRTL=<dir>        the same program against another runtime
#   make clean
#
# TO SHOW THE DEFECT AND ITS ABSENCE, build twice. The second build needs a
# runtime whose MinBlock is at least SizeOf(THeapBlock); make-fixed-rtl.sh
# produces one in the repository scratch area WITHOUT modifying the Free Pascal
# source tree, which is upstream and is never edited:
#
#   ./make-fixed-rtl.sh
#   make clean && make FPCRTL=<the directory it prints> TARGET=kernel-minblock-fixed
#
# The image name matters: the boot server accepts only names matching
# kernel*.img.
#

CIRCLELIBFPCHOME = ../..
CIRCLESTDLIBHOME = $(CIRCLELIBFPCHOME)/circle-stdlib-rpi5
CIRCLEHOME       = $(CIRCLESTDLIBHOME)/libs/circle

# First, before the world and before Rules.mk: Rules.mk asks the C++ compiler a
# question while it is being read.
include $(CIRCLELIBFPCHOME)/toolchain.mk

include $(CIRCLESTDLIBHOME)/Config.mk

TARGET      ?= kernel-minblock
FPC_PROGRAM  = minblock.pp

OBJS = main.o kernel.o

# The world's full library set: this is a circle-stdlib world, so Circle itself
# was compiled with STDLIB_SUPPORT 4 and its own code calls operator new,
# operator delete, abort and strlen.
LIBS = $(CIRCLE_STDLIB_LIBS)

INCLUDE += -I $(CIRCLELIBFPCHOME)/include

# Circle's Rules.mk defines a link rule for $(TARGET).img, and fpc-app.mk
# replaces it. Point TARGET at a name nothing builds while Rules.mk is read so
# that make has nothing to warn about, then restore it.
FPC_APP_IMAGE := $(TARGET)
TARGET := .circle-unused
include $(CIRCLEHOME)/Rules.mk
TARGET := $(FPC_APP_IMAGE)

include $(CIRCLELIBFPCHOME)/fpc-app.mk

EXTRACLEAN = kernel-minblock*.* .circle-unused.*

-include $(DEPS)
