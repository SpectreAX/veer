# Veer Go core build targets.
#
# Prerequisites: gomobile installed and initialized.
#   go install golang.org/x/mobile/cmd/gomobile@latest
#   gomobile init
#
# On Windows: run these targets inside WSL or Git Bash.
# On CI (Linux/macOS): run directly.
#
# Output files land in ../app/libs/ and are gitignored except the committed
# release .aar. The debug .aar is never committed to version control.

AAR_DIR  := ../app/libs
GOMOBILE := $(shell which gomobile || echo gomobile)
GOFLAGS  := -target=android -androidapi 29
# Match Mihomo's official build feature set. with_gvisor is required for the
# Android fd-backed TUN to process TCP fully in userspace; cmfa supplies the
# Android integration patches.
MOBILE_TAGS := cmfa,with_gvisor

.PHONY: all aar-release aar-debug clean

all: aar-release

# Production .aar — no fault injection symbols compiled in.
# Replace the committed app/libs/libveer_core.aar with this output.
aar-release:
	$(GOMOBILE) bind $(GOFLAGS) -tags=$(MOBILE_TAGS) -o $(AAR_DIR)/libveer_core.aar .

# Debug .aar — includes full fault injection, goroutine snapshots, and call
# counters. Used exclusively by debug builds; never shipped to users.
# The Gradle debug variant prefers this file when it exists in app/libs/.
aar-debug:
	$(GOMOBILE) bind $(GOFLAGS) -tags=$(MOBILE_TAGS),veer_fault_inject -o $(AAR_DIR)/libveer_core_debug.aar .

clean:
	rm -f $(AAR_DIR)/libveer_core_debug.aar
	rm -f $(AAR_DIR)/libveer_core-sources.jar
