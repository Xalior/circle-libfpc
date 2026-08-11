# toolchain.mk — find the cross toolchains circle-libfpc needs.
#
# Include this FIRST, before a Circle world's Config.mk and before Circle's
# Rules.mk. Rules.mk asks the C++ compiler a question at parse time, so a
# toolchain that only reaches PATH later produces a stray "no such file or
# directory" on every build — a message that reads like a broken source tree
# rather than a PATH that was never set.
#
# PATH is honoured first, so a machine that already has these installed is left
# alone. Failing that, each search list is tried in order:
#
#   $RAPI_TOOLCHAIN_DIR / $RAPI_FPC_DIR   name where the trees live
#   toolchains/                           beside this library
#   ../toolchains/                        one level up
#   ../../toolchains/                     two levels up
#
# Get Arm GNU toolchain release 15.2.Rel1 for the aarch64-none-elf target,
# built for the machine you compile ON, from
# https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads

CIRCLE_LIBFPC_DIR := $(dir $(lastword $(MAKEFILE_LIST)))

TOOLCHAIN_SEARCH := $(RAPI_TOOLCHAIN_DIR) $(CIRCLE_LIBFPC_DIR)toolchains \
                    $(CIRCLE_LIBFPC_DIR)../toolchains \
                    $(CIRCLE_LIBFPC_DIR)../../toolchains

ifeq ($(shell command -v aarch64-none-elf-gcc 2>/dev/null),)
TOOLCHAIN_BIN := $(firstword \
	$(wildcard $(addsuffix /arm-gnu-toolchain-*-aarch64-none-elf/bin,$(TOOLCHAIN_SEARCH))) \
	$(wildcard $(addsuffix /bin,$(TOOLCHAIN_SEARCH))))
ifneq ($(TOOLCHAIN_BIN),)
export PATH := $(abspath $(TOOLCHAIN_BIN)):$(PATH)
endif
endif
