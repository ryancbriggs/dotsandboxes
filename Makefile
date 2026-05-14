# Makefile for the Dots & Boxes Playdate game.
#
# Drives the C extension build + bundles the .pdx via the SDK's common.mk.
# Run `make` to produce build/Dots.pdx (simulator + device binaries).
# `make clean` removes build artifacts.

HEAP_SIZE      = 8388208
STACK_SIZE     = 61800

PRODUCT = Dots.pdx

# Locate the SDK from env, falling back to the user's ~/.Playdate/config.
SDK = ${PLAYDATE_SDK_PATH}
ifeq ($(SDK),)
SDK = $(shell egrep '^\s*SDKRoot' ~/.Playdate/config | head -n 1 | cut -c9-)
endif

ifeq ($(SDK),)
$(error SDK path not found; set ENV value PLAYDATE_SDK_PATH)
endif

# C source files live in Source/ alongside the .lua game code so pdc picks
# up everything in one pass.
VPATH += Source

SRC = Source/main.c

# Unused build slots for now; keep them around for future expansion.
UINCDIR =
UASRC =
UDEFS =
UADEFS =
ULIBDIR =
ULIBS =

include $(SDK)/C_API/buildsupport/common.mk

# Don't bundle main.c (or any other "unknown" file types) into the .pdx.
PDCFLAGS += -k
