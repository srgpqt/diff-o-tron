#!/bin/bash

set -eo pipefail``

APP_VERSION="0.1"
WINDOWS_SDK="${WINDOWS_SDK:-missing_windows_sdk}"

export PATH="`brew --prefix llvm@21`/bin:$PATH"
export PATH="`brew --prefix lld@21`/bin:$PATH"

CFLAGS="
	-Os
	-std=c99
	-pedantic
	-Wall
	-Wextra
	-Werror
	-Wfloat-equal
	-Winit-self
	-Wshadow
	-Wsign-conversion
	-Wstrict-overflow=5
	-Wstrict-prototypes
	-Wundef
	-Wwrite-strings
	-Wno-gnu-auto-type
	-Wno-missing-braces
	-Wno-unused-function
	-Wno-unused-parameter
	-Wno-unused-variable
	-fno-rtti"

build_macos() {
	CFLAGS="$CFLAGS -mmacosx-version-min=10.10"

	mkdir -p Diff-o-tron.app/Contents/MacOS

	clang -o Diff-o-tron.app/Contents/MacOS/Diff-o-tron \
		$CFLAGS \
		-framework Cocoa \
		system/macos.m $SRC

	rm -rf _build/*.dSYM
	mv Diff-o-tron.app/Contents/MacOS/*.dSYM _build/ || true
	find Diff-o-tron.app -name .DS_Store -delete
	touch Diff-o-tron.app

	codesign --force --sign - --entitlements entitlements/macos-debug.xml --timestamp=none Diff-o-tron.app
	# codesign --force --sign - --entitlements entitlements/macos-dist.xml --timestamp Diff-o-tron.app
}

build_windows() {
	CFLAGS="
		-target x86_64-pc-windows-msvc
		-nostdinc
		-D_WIN64 -DUNICODE -D_UNICODE -D_USE_MATH_DEFINES
		--sysroot=$WINDOWS_SDK
		-isystem $WINDOWS_SDK/clang/include
		-isystem $WINDOWS_SDK/msvc/include
		-isystem $WINDOWS_SDK/10/include/ucrt
		-isystem $WINDOWS_SDK/10/include/shared
		-isystem $WINDOWS_SDK/10/include/um
		 $CFLAGS"

	LDFLAGS="
		-fuse-ld=lld-link -nostdlib -Wno-msvc-not-found
		-Xlinker /release
		-Xlinker /version:$APP_VERSION
		-Xlinker -subsystem:WINDOWS
		-Xlinker /NOIMPLIB
		-Xlinker -libpath:$WINDOWS_SDK/clang/lib/amd64
		-Xlinker -libpath:$WINDOWS_SDK/msvc/lib/amd64
		-Xlinker -libpath:$WINDOWS_SDK/10/lib/amd64
		-Xlinker -defaultlib:msvcrt
		-Xlinker -defaultlib:User32
		-Xlinker -defaultlib:Gdi32"

	if [ _build/resources.c -nt _build/resources.win.o ]; then
		clang -o _build/resources.win.o -c $CFLAGS _build/resources.c
	fi

	llvm-rc /FO _build/windows.rc.res system/windows.rc
	llvm-cvtres /OUT:_build/windows.rc.o /MACHINE:X64 _build/windows.rc.res
	clang -o _build/Diff-o-tron.exe $CFLAGS $LDFLAGS _build/windows.rc.o system/windows.c $SRC _build/resources.win.o
}

(cd `dirname "${BASH_SOURCE[0]}"` && build_macos)
