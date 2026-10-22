#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DEPS="${NATIVE_DEPS:-$ROOT/desktop/.build/native-deps}"
mkdir -p "$ROOT/desktop/.build" "$ROOT/qa/network"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=12 -t 48 -c:v libx264 -g 72 -sc_threshold 0 -hls_time 6 -hls_playlist_type vod "$ROOT/qa/network/index.m3u8"
node "$ROOT/tests/owned-network-fixture.cjs" "$ROOT/qa/network" > "$ROOT/desktop/.build/owned-network.log" 2>&1 &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null || true; wait "$SERVER" 2>/dev/null || true' EXIT
sleep 0.2
kill -0 "$SERVER" # Do not use somebody else's server if the port was occupied.
clang -O2 -arch arm64 -mmacosx-version-min=13.5 -I"$DEPS/include" -c "$ROOT/desktop/MPVShim.c" -o "$ROOT/desktop/.build/MPVShim-watched.o"
SOURCES=(Policy NativeBridgePolicy NativeEngineCommands NativeLoadTracker NativeMediaTools NativeOpenMediaQueue NativeWindowState NativePlayer)
ARGS=()
for source in "${SOURCES[@]}"; do ARGS+=("$ROOT/desktop/$source.swift"); done
for test in NativeMoviePosterTests NativeWatchedNetworkTests; do
  swiftc -suppress-warnings -O -target arm64-apple-macosx13.5 -import-objc-header "$ROOT/desktop/MPVShim.h" \
    "${ARGS[@]}" "$ROOT/tests/$test.swift" "$ROOT/desktop/.build/MPVShim-watched.o" -o "$ROOT/desktop/.build/$test" \
    "$DEPS/Frameworks/libmpv.2.dylib" -Xlinker -rpath -Xlinker "$DEPS/Frameworks" \
    -framework AppKit -framework WebKit -framework Security -framework OpenGL -framework Vision \
    -framework ImageIO -framework UniformTypeIdentifiers -framework AVFoundation -framework AVKit
  if [[ "$test" == NativeMoviePosterTests ]]; then
    "$ROOT/desktop/.build/$test" http://127.0.0.1:19785/index.m3u8 "$ROOT/qa/current-online-poster.png"
  else
    "$ROOT/desktop/.build/$test" "$ROOT/qa/watched-online-poster.png"
  fi
done
