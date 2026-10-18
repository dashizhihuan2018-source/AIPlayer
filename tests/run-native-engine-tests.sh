#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
FIXTURE="${1:?Provide an owned, seekable MP4 with burned-in 00:00:10 timecode}"
DEPS="${NATIVE_DEPS:-$ROOT/desktop/.build/native-deps}"
test -f "$FIXTURE"
test -f "$DEPS/Frameworks/libmpv.2.dylib"
mkdir -p "$ROOT/desktop/.build"
clang -O2 -arch arm64 -mmacosx-version-min=13.5 -I"$DEPS/include" -c "$ROOT/desktop/MPVShim.c" -o "$ROOT/desktop/.build/MPVShim.o"
SOURCES=(Policy NativeBridgePolicy NativeEngineCommands NativeLoadTracker NativeMediaTools NativeOpenMediaQueue NativeWindowState NativePlayer)
ARGS=()
for source in "${SOURCES[@]}"; do ARGS+=("$ROOT/desktop/$source.swift"); done
for test in NativeEngineRouteTests NativeToolFlowTests NativePosterEngineTests NativeGIFFlowTests NativeGIFCadenceTests; do
  swiftc -O -target arm64-apple-macosx13.5 -import-objc-header "$ROOT/desktop/MPVShim.h" \
    "${ARGS[@]}" "$ROOT/tests/$test.swift" "$ROOT/desktop/.build/MPVShim.o" \
    -o "$ROOT/desktop/.build/$test" "$DEPS/Frameworks/libmpv.2.dylib" \
    -Xlinker -rpath -Xlinker "$DEPS/Frameworks" \
    -framework AppKit -framework WebKit -framework Security -framework OpenGL \
    -framework Vision -framework ImageIO -framework UniformTypeIdentifiers \
    -framework AVFoundation -framework AVKit
  if [[ "$test" == NativeGIFCadenceTests && -n "${2:-}" ]]; then
    "$ROOT/desktop/.build/$test" "$2"
    "$ROOT/desktop/.build/$test" "$FIXTURE"
  elif [[ "$test" == NativeGIFFlowTests && -n "${2:-}" ]]; then
    "$ROOT/desktop/.build/$test" "$FIXTURE" "$2"
  else
    "$ROOT/desktop/.build/$test" "$FIXTURE"
  fi
done
