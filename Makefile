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

# ── Build-time C/Lua parity gate ───────────────────────────────────────────
# Compile + run the differential test that pins Source/solver.h (the shipped
# C kernels) against an independent reference of the audited Lua algorithms.
# Any divergence aborts the build before pdc runs. Skipped for `make clean`.
# ~0.5s; zero cost to the game itself.
ifeq ($(filter clean,$(MAKECMDGOALS)),)
PARITY_OUT := $(shell cc -O2 -std=c11 -o /tmp/dots_parity_test tests/parity_test.c 2>&1 && /tmp/dots_parity_test 2>&1)
ifeq ($(findstring PARITY_OK,$(PARITY_OUT)),)
$(error C/Lua parity test FAILED — build aborted:$(PARITY_OUT))
endif
$(info [parity] $(PARITY_OUT))
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
