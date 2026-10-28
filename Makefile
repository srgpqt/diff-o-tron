# Diff-o-tron build.
#
#   make                     build the app for this platform (debug)
#   make CONFIG=release      build it optimized
#   make run [ARGS="a b"]    build and launch it, optionally comparing a and b
#   make test                run the Rust tests and the C interface test
#   make icon                regenerate macOS/AppIcon.icns from Assets/AppIcon.svg (on macOS)
#   make clean
#
# PLATFORM=macos|windows|linux overrides the host platform, and RUST_TARGET the target triple,
# such as aarch64-unknown-linux-gnu; its Rust standard library must be installed
# (`rustup target add <triple>`). macOS builds are for Apple silicon (aarch64-apple-darwin) only.
# Windows builds cross-compile with clang and lld against the SDK
# in WINDOWS_SDK; macOS builds from other hosts use clang and lld against the SDK in MACOS_SDK.
# CARGO_FLAGS passes extra arguments to `cargo build`. BUILD_STD=1 builds the Rust standard library
# from source for the target, for toolchains without a suitable prebuilt one: Homebrew's has none
# for other targets, and its macOS one requires the macOS it was built on.
#
# Everything is built in _build/: the Rust core in _build/cargo, and the rest of each target and
# configuration in _build/$(RUST_TARGET)-$(CONFIG).
# Keep this file working with the GNU Make 3.81 that ships with macOS.

APP_NAME    := Diff-o-tron
APP_VERSION := 0.3
APP_BUILD   := 3

CONFIG ?= debug

HOST_OS := $(shell uname -s)
ifeq ($(HOST_OS),Darwin)
  HOST_PLATFORM := macos
else ifneq (,$(findstring MINGW,$(HOST_OS))$(findstring MSYS,$(HOST_OS)))
  HOST_PLATFORM := windows
else
  HOST_PLATFORM := linux
endif
PLATFORM ?= $(HOST_PLATFORM)

RUSTC       ?= rustc
HOST_TARGET := $(shell $(RUSTC) -vV | sed -n 's/^host: //p')
ifeq ($(PLATFORM),macos)
  RUST_TARGET ?= aarch64-apple-darwin
  ifneq ($(RUST_TARGET),aarch64-apple-darwin)
    $(error macOS builds are aarch64-apple-darwin only, not $(RUST_TARGET))
  endif
else ifeq ($(PLATFORM),$(HOST_PLATFORM))
  RUST_TARGET ?= $(HOST_TARGET)
else ifeq ($(PLATFORM),windows)
  RUST_TARGET ?= x86_64-pc-windows-msvc
else
  RUST_TARGET ?= $(HOST_TARGET)
endif

BUILD      := _build/$(RUST_TARGET)-$(CONFIG)
HOST_BUILD := _build/$(HOST_TARGET)-$(CONFIG)

ifeq ($(CONFIG),release)
  OPTFLAGS      := -Os -DNDEBUG
  CARGO_PROFILE := release
else ifeq ($(CONFIG),debug)
  OPTFLAGS      := -O0 -g
  CARGO_PROFILE := debug
else
  $(error CONFIG must be debug or release, not $(CONFIG))
endif

CFLAGS := $(OPTFLAGS) \
	-std=c99 \
	-pedantic \
	-Wall \
	-Wextra \
	-Werror \
	-Wfloat-equal \
	-Winit-self \
	-Wshadow \
	-Wsign-conversion \
	-Wstrict-overflow=5 \
	-Wstrict-prototypes \
	-Wundef \
	-Wwrite-strings \
	-Wno-gnu-auto-type \
	-Wno-missing-braces \
	-Wno-unused-function \
	-Wno-unused-parameter \
	-Wno-unused-variable \
	-Iinclude

# --- Rust core ---------------------------------------------------------------

CARGO       ?= cargo
CARGO_FLAGS ?=
CARGO_ENV   :=
ifeq ($(BUILD_STD),1)
  CARGO_ENV   += RUSTC_BOOTSTRAP=1
  CARGO_FLAGS += -Zbuild-std=std,panic_abort
endif
CARGO_DIR   := _build/cargo
CARGO_ARGS  := --lib --target-dir $(CARGO_DIR) $(if $(filter release,$(CONFIG)),--release) $(CARGO_FLAGS)

ifeq ($(PLATFORM),windows)
  RUST_LIB := $(CARGO_DIR)/$(RUST_TARGET)/$(CARGO_PROFILE)/diffotron.lib
else
  RUST_LIB := $(CARGO_DIR)/$(RUST_TARGET)/$(CARGO_PROFILE)/libdiffotron.a
endif
HOST_RUST_LIB := $(CARGO_DIR)/$(HOST_TARGET)/$(CARGO_PROFILE)/libdiffotron.a

# The libraries the Rust standard library needs, from
# `cargo rustc --lib --crate-type staticlib -- --print native-static-libs`.
# On macOS that's -lSystem -lc -lm, which clang links already.
RUST_LIBS_macos   :=
RUST_LIBS_linux   := -lgcc_s -lutil -lrt -lpthread -lm -ldl -lc
RUST_LIBS_windows := \
	-Xlinker -defaultlib:kernel32 \
	-Xlinker -defaultlib:advapi32 \
	-Xlinker -defaultlib:ntdll \
	-Xlinker -defaultlib:userenv \
	-Xlinker -defaultlib:ws2_32 \
	-Xlinker -defaultlib:dbghelp

# Cargo decides what's stale: it always runs, but leaves the library alone when it's up to date,
# so the app only relinks when the library changed.
$(RUST_LIB): FORCE
	$(CARGO_ENV) $(CARGO) build $(CARGO_ARGS) --target $(RUST_TARGET)

# --- macOS -------------------------------------------------------------------

MACOS_MIN  := 11.0

MACOS_SIGN ?= -
# Registers the app's file types with Launch Services, which otherwise can go on using stale ones.
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

ifeq ($(PLATFORM),macos)
  # Build the Rust objects for the same macOS as the app.
  CARGO_ENV += MACOSX_DEPLOYMENT_TARGET=$(MACOS_MIN)
  ifeq ($(HOST_PLATFORM),macos)
    MACOS_CC ?= xcrun clang
    ifndef MACOS_SDK
      MACOS_SDK := $(shell xcrun --show-sdk-path)
    endif
  else
    MACOS_CC      ?= clang
    MACOS_SDK     ?= /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
    MACOS_LDFLAGS := -fuse-ld=lld
  endif
endif
MACOS_FLAGS := -target arm64-apple-macos$(MACOS_MIN) -isysroot $(MACOS_SDK)

APP                := $(BUILD)/$(APP_NAME).app
MACOS_BIN          := $(APP)/Contents/MacOS/$(APP_NAME)
# The diffotron command, for git difftool. Not sandboxed: it only hands files to the app.
MACOS_CLI          := $(APP)/Contents/Helpers/diffotron
MACOS_ENTITLEMENTS := entitlements/macos-$(if $(filter release,$(CONFIG)),dist,debug).xml
ifeq ($(CONFIG),release)
  MACOS_SIGN_ARGS := --options runtime --timestamp
else
  MACOS_SIGN_ARGS := --timestamp=none
endif

macos: $(BUILD)/macos.signed

# Every macOS/*.m goes into the app, except the diffotron command's.
MACOS_APP_OBJECTS := $(patsubst macOS/%.m,$(BUILD)/macOS/%.o,$(filter-out macOS/cli.m,$(wildcard macOS/*.m)))

$(BUILD)/macOS/%.o: macOS/%.m
	@mkdir -p $(@D)
	$(MACOS_CC) $(MACOS_FLAGS) $(CFLAGS) -fobjc-arc -MMD -MP -c -o $@ $<

$(MACOS_BIN): $(MACOS_APP_OBJECTS) $(RUST_LIB)
	@mkdir -p $(@D)
	$(MACOS_CC) $(MACOS_FLAGS) $(MACOS_LDFLAGS) -o $@ $^ -framework Cocoa -framework CoreServices -framework CoreText $(RUST_LIBS_macos)

$(MACOS_CLI): $(BUILD)/macOS/cli.o
	@mkdir -p $(@D)
	$(MACOS_CC) $(MACOS_FLAGS) $(MACOS_LDFLAGS) -o $@ $^ -framework Cocoa

$(APP)/Contents/Info.plist: macOS/Info.plist Makefile
	@mkdir -p $(@D)
	sed -e 's/@APP_VERSION@/$(APP_VERSION)/' -e 's/@APP_BUILD@/$(APP_BUILD)/' -e 's/@MACOS_MIN@/$(MACOS_MIN)/' $< > $@

$(APP)/Contents/Resources/Credits.html: macOS/credits.html
	@mkdir -p $(@D)
	cp $< $@

$(APP)/Contents/Resources/AppIcon.icns: macOS/AppIcon.icns
	@mkdir -p $(@D)
	cp $< $@

$(APP)/Contents/PkgInfo:
	@mkdir -p $(@D)
	printf 'APPL????' > $@

# Nested code first: signing the app seals in the helper's signature.
$(BUILD)/macos.signed: $(MACOS_BIN) $(MACOS_CLI) $(APP)/Contents/Info.plist $(APP)/Contents/PkgInfo \
		$(APP)/Contents/Resources/Credits.html $(APP)/Contents/Resources/AppIcon.icns $(MACOS_ENTITLEMENTS)
ifeq ($(HOST_PLATFORM),macos)
	codesign --force --sign "$(MACOS_SIGN)" $(MACOS_SIGN_ARGS) $(MACOS_CLI)
	codesign --force --sign "$(MACOS_SIGN)" --entitlements $(MACOS_ENTITLEMENTS) $(MACOS_SIGN_ARGS) $(APP)
	$(LSREGISTER) -f $(APP)
else
	@echo "Not signing $(APP): codesign needs macOS"
endif
	@touch $@

run-macos: macos
	open -W -a "$(abspath $(APP))" $(ARGS)

# Regenerate macOS/AppIcon.icns from Assets/AppIcon.svg, which is drawn on the macOS icon grid.
# Needs macOS for iconutil, and rsvg-convert (`brew install librsvg`).
ICONSET := _build/AppIcon.iconset

icon:
	rm -rf $(ICONSET) && mkdir -p $(ICONSET)
	for size in 16 32 128 256 512; do \
		rsvg-convert -w $$size -h $$size Assets/AppIcon.svg -o $(ICONSET)/icon_$${size}x$${size}.png && \
		rsvg-convert -w $$((size * 2)) -h $$((size * 2)) Assets/AppIcon.svg -o $(ICONSET)/icon_$${size}x$${size}@2x.png || exit 1; \
	done
	iconutil -c icns -o macOS/AppIcon.icns $(ICONSET)

# --- Windows -----------------------------------------------------------------

WINDOWS_SDK ?= missing_windows_sdk
WINDOWS_EXE := $(BUILD)/$(APP_NAME).exe
WINDOWS_RC  := $(wildcard Windows/main.rc)

ifeq ($(PLATFORM),windows)
  ifneq ($(HOST_PLATFORM),windows)
    export PATH := $(shell brew --prefix llvm@21)/bin:$(shell brew --prefix lld@21)/bin:$(PATH)
  endif
endif

WINDOWS_CFLAGS := \
	-target x86_64-pc-windows-msvc \
	-nostdinc \
	-D_WIN64 -DUNICODE -D_UNICODE -D_USE_MATH_DEFINES \
	--sysroot=$(WINDOWS_SDK) \
	-isystem $(WINDOWS_SDK)/clang/include \
	-isystem $(WINDOWS_SDK)/msvc/include \
	-isystem $(WINDOWS_SDK)/10/include/ucrt \
	-isystem $(WINDOWS_SDK)/10/include/shared \
	-isystem $(WINDOWS_SDK)/10/include/um \
	$(CFLAGS)

WINDOWS_LDFLAGS := \
	-target x86_64-pc-windows-msvc \
	-fuse-ld=lld-link -nostdlib -Wno-msvc-not-found \
	-Xlinker /release \
	-Xlinker /version:$(APP_VERSION) \
	-Xlinker -subsystem:WINDOWS \
	-Xlinker /NOIMPLIB \
	-Xlinker -libpath:$(WINDOWS_SDK)/clang/lib/amd64 \
	-Xlinker -libpath:$(WINDOWS_SDK)/msvc/lib/amd64 \
	-Xlinker -libpath:$(WINDOWS_SDK)/10/lib/amd64 \
	-Xlinker -defaultlib:msvcrt \
	-Xlinker -defaultlib:User32 \
	-Xlinker -defaultlib:Gdi32 \
	$(RUST_LIBS_windows)

windows: $(WINDOWS_EXE)

$(BUILD)/Windows/main.o: Windows/main.c
	@mkdir -p $(@D)
	clang $(WINDOWS_CFLAGS) -MMD -MP -c -o $@ $<

$(BUILD)/Windows/main.rc.o: $(WINDOWS_RC) entitlements/windows.xml
	@mkdir -p $(@D)
	llvm-rc /FO $(BUILD)/Windows/main.rc.res $<
	llvm-cvtres /OUT:$@ /MACHINE:X64 $(BUILD)/Windows/main.rc.res

$(WINDOWS_EXE): $(BUILD)/Windows/main.o $(if $(WINDOWS_RC),$(BUILD)/Windows/main.rc.o) $(RUST_LIB)
	clang -o $@ $^ $(WINDOWS_LDFLAGS)

run-windows: windows
	$(WINDOWS_EXE) $(ARGS)

# --- Linux -------------------------------------------------------------------

# The pkg-config packages the Linux front end uses, such as gtk4.
LINUX_PKGS ?=
LINUX_CC   ?= clang
LINUX_BIN  := $(BUILD)/$(APP_NAME)
LINUX_PKG_CFLAGS := $(if $(LINUX_PKGS),$(shell pkg-config --cflags $(LINUX_PKGS)))
LINUX_PKG_LIBS   := $(if $(LINUX_PKGS),$(shell pkg-config --libs $(LINUX_PKGS)))

linux: $(LINUX_BIN)

$(BUILD)/Linux/main.o: Linux/main.c
	@mkdir -p $(@D)
	$(LINUX_CC) $(CFLAGS) $(LINUX_PKG_CFLAGS) -MMD -MP -c -o $@ $<

$(LINUX_BIN): $(BUILD)/Linux/main.o $(RUST_LIB)
	$(LINUX_CC) -o $@ $^ $(LINUX_PKG_LIBS) $(RUST_LIBS_linux)

run-linux: linux
	$(LINUX_BIN) $(ARGS)

# --- Tests -------------------------------------------------------------------

HOST_CC_macos := xcrun clang
HOST_CC_linux := clang
FFI_TEST      := $(HOST_BUILD)/ffi-test

test: check-credits $(FFI_TEST)
	$(CARGO) test --target-dir $(CARGO_DIR) --target $(HOST_TARGET)
	@rm -rf $(HOST_BUILD)/ffi-scratch && mkdir -p $(HOST_BUILD)/ffi-scratch
	$(FFI_TEST) $(HOST_BUILD)/ffi-scratch

# Every crate linked into the app must be credited in its About panel.
check-credits:
	@status=0; \
	for crate in $$($(CARGO) tree -e normal --prefix none --target all | awk '{ print $$1 }' | sort -u); do \
		[ "$$crate" = diffotron ] && continue; \
		grep -q "<h3>$$crate</h3>" macOS/credits.html || { echo "macOS/credits.html doesn't credit $$crate"; status=1; }; \
	done; \
	exit $$status

# Always built for the host, whatever PLATFORM is.
$(FFI_TEST): tests/ffi.c FORCE
	@mkdir -p $(@D)
	$(CARGO_ENV) $(CARGO) build $(CARGO_ARGS) --target $(HOST_TARGET)
	$(HOST_CC_$(HOST_PLATFORM)) $(CFLAGS) -MMD -MP -o $@ $< $(HOST_RUST_LIB) $(RUST_LIBS_$(HOST_PLATFORM))

# --- General -----------------------------------------------------------------

all: $(PLATFORM)
run: run-$(PLATFORM)

clean:
	rm -rf _build

.DEFAULT_GOAL := all
.PHONY: all run test check-credits clean icon macos run-macos windows run-windows linux run-linux FORCE
FORCE:

-include $(wildcard $(BUILD)/*.d $(BUILD)/*/*.d $(HOST_BUILD)/*.d)
