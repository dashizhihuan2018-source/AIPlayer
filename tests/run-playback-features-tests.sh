#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
FIXTURE="${1:?Provide an owned seekable video of at least 24 seconds}"
DEPS="${NATIVE_DEPS:-$ROOT/desktop/.build/native-deps}"
test -f "$FIXTURE"
mkdir -p "$ROOT/desktop/.build"
swiftc "$ROOT/desktop/NativeWindowState.swift" "$ROOT/tests/NativeWindowStateTests.swift" -o "$ROOT/desktop/.build/NativeWindowStateTests"
"$ROOT/desktop/.build/NativeWindowStateTests"
swiftc -O "$ROOT/desktop/NativeMediaTools.swift" "$ROOT/tests/NativePosterCaptureTests.swift" -o "$ROOT/desktop/.build/NativePosterCaptureTests"
"$ROOT/desktop/.build/NativePosterCaptureTests"
clang -O2 -arch arm64 -mmacosx-version-min=13.5 -I"$DEPS/include" -c "$ROOT/desktop/MPVShim.c" -o "$ROOT/desktop/.build/MPVShim.o"
ARGS=()
for source in Policy NativeBridgePolicy NativeEngineCommands NativeLoadTracker NativeMediaTools NativeOpenMediaQueue NativeWindowState NativePlayer; do ARGS+=("$ROOT/desktop/$source.swift"); done
for test in NativePlaybackPowerTests NativeMoviePosterTests; do
  swiftc -O -target arm64-apple-macosx13.5 -import-objc-header "$ROOT/desktop/MPVShim.h" \
    "${ARGS[@]}" "$ROOT/tests/$test.swift" "$ROOT/desktop/.build/MPVShim.o" \
    -o "$ROOT/desktop/.build/$test" "$DEPS/Frameworks/libmpv.2.dylib" \
    -Xlinker -rpath -Xlinker "$DEPS/Frameworks" \
    -framework AppKit -framework WebKit -framework Security -framework OpenGL \
    -framework Vision -framework ImageIO -framework UniformTypeIdentifiers -framework AVFoundation -framework AVKit
  "$ROOT/desktop/.build/$test" "$FIXTURE"
done
node --test "$ROOT/tests/playback-features.test.cjs"
