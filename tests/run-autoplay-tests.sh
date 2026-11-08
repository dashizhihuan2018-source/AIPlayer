#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
FIXTURE="${1:?Provide an owned seekable video at least three seconds long}"
DEPS="${NATIVE_DEPS:-$ROOT/desktop/.build/native-deps}"
mkdir -p "$ROOT/desktop/.build"
clang -O2 -arch arm64 -mmacosx-version-min=13.5 -I"$DEPS/include" -c "$ROOT/desktop/MPVShim.c" -o "$ROOT/desktop/.build/MPVShim-autoplay.o"
ARGS=()
for source in Policy NativeBridgePolicy NativeEngineCommands NativeLoadTracker NativeMediaTools NativeOpenMediaQueue NativeWindowState NativePlayer; do ARGS+=("$ROOT/desktop/$source.swift"); done
swiftc -O -target arm64-apple-macosx13.5 -import-objc-header "$ROOT/desktop/MPVShim.h" \
  "${ARGS[@]}" "$ROOT/tests/NativeAutoplayTests.swift" "$ROOT/desktop/.build/MPVShim-autoplay.o" \
  -o "$ROOT/desktop/.build/NativeAutoplayTests" "$DEPS/Frameworks/libmpv.2.dylib" \
  -Xlinker -rpath -Xlinker "$DEPS/Frameworks" \
  -framework AppKit -framework WebKit -framework Security -framework OpenGL \
  -framework Vision -framework ImageIO -framework UniformTypeIdentifiers -framework AVFoundation -framework AVKit
"$ROOT/desktop/.build/NativeAutoplayTests" "$FIXTURE"
