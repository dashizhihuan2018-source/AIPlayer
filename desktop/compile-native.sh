#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
NATIVE_DEPS="${NATIVE_DEPS:-$ROOT/desktop/.build/native-deps}"
if [[ ! -f "$NATIVE_DEPS/Frameworks/libmpv.2.dylib" ]]; then "$ROOT/desktop/prepare-native-deps.sh" >/dev/null; fi
MPV_INCLUDE="${MPV_INCLUDE:-$NATIVE_DEPS/include}"
MPV_LIB="${MPV_LIB:-$NATIVE_DEPS/Frameworks/libmpv.2.dylib}"
OUT="${1:-/tmp/aiplayer-native-host}"
mkdir -p "$ROOT/desktop/.build"
clang -O2 -arch arm64 -mmacosx-version-min=13.5 -I"$MPV_INCLUDE" -c "$ROOT/desktop/MPVShim.c" -o "$ROOT/desktop/.build/MPVShim.o"
swiftc -O -target arm64-apple-macosx13.5 -import-objc-header "$ROOT/desktop/MPVShim.h" \
  "$ROOT/desktop/Policy.swift" "$ROOT/desktop/NativeBridgePolicy.swift" "$ROOT/desktop/NativeEngineCommands.swift" \
  "$ROOT/desktop/NativeLoadTracker.swift" "$ROOT/desktop/NativeMediaTools.swift" "$ROOT/desktop/NativeOpenMediaQueue.swift" "$ROOT/desktop/NativeWindowState.swift" "$ROOT/desktop/NativePlayer.swift" "$ROOT/desktop/main.swift" "$ROOT/desktop/.build/MPVShim.o" \
  -o "$OUT" "$MPV_LIB" \
  -Xlinker -rpath -Xlinker "$NATIVE_DEPS/Frameworks" \
  -framework AppKit -framework WebKit -framework Security -framework OpenGL -framework Vision -framework ImageIO -framework UniformTypeIdentifiers -framework AVFoundation -framework AVKit
file "$OUT"
