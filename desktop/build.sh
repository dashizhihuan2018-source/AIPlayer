#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
APP="$ROOT/dist/万能AI播放器.app"
NATIVE_DEPS="${NATIVE_DEPS:-$ROOT/desktop/.build/native-deps}"
if [[ ! -f "$NATIVE_DEPS/Frameworks/libmpv.2.dylib" ]]; then "$ROOT/desktop/prepare-native-deps.sh" >/dev/null; fi
MPV_INCLUDE="${MPV_INCLUDE:-$NATIVE_DEPS/include}"
MPV_LIB="${MPV_LIB:-$NATIVE_DEPS/Frameworks/libmpv.2.dylib}"
NODE_BINARY="${NODE_BINARY:-$(command -v node)}"
NODE_VERSION="$("$NODE_BINARY" --version)"
if [[ "$NODE_VERSION" != v24.* ]]; then
  echo "Node.js 24 is required (found $NODE_VERSION). Set NODE_BINARY to an official Node 24 executable." >&2
  exit 1
fi
NODE_ARCHS="$(/usr/bin/lipo -archs "$NODE_BINARY")"
if [[ " $NODE_ARCHS " != *" arm64 "* ]]; then
  echo "The selected Node executable must contain arm64: $NODE_ARCHS" >&2
  exit 1
fi
export PATH="$(dirname "$NODE_BINARY"):$PATH"
if [ -e "$APP" ]; then
  echo "Refusing to overwrite existing app: $APP. Move it to an explicit backup before rebuilding." >&2
  exit 1
fi
if [[ ! -f "$MPV_LIB" || ! -f "$MPV_INCLUDE/mpv/client.h" ]]; then
  echo "Prepared arm64 libmpv and source headers are required. Run desktop/prepare-native-deps.sh." >&2
  exit 1
fi
if [[ " $(/usr/bin/lipo -archs "$MPV_LIB") " != *" arm64 "* ]]; then
  echo "libmpv must contain arm64: $MPV_LIB" >&2
  exit 1
fi
cd "$ROOT/upstream"
DOCKER_BUILD=1 NEXT_TELEMETRY_DISABLED=1 npm run build
test -f .next/standalone/server.js
mkdir -p "$APP/Contents/"{MacOS,Frameworks,Resources/runtime,Resources/server,Resources/ThirdPartyLicenses}
clang -O2 -arch arm64 -mmacosx-version-min=13.5 -I"$MPV_INCLUDE" -c "$ROOT/desktop/MPVShim.c" -o "$ROOT/desktop/.build/MPVShim.o"
swiftc -O -target arm64-apple-macosx13.5 -import-objc-header "$ROOT/desktop/MPVShim.h" \
  "$ROOT/desktop/Policy.swift" "$ROOT/desktop/NativeBridgePolicy.swift" "$ROOT/desktop/NativeEngineCommands.swift" \
  "$ROOT/desktop/NativeLoadTracker.swift" "$ROOT/desktop/NativeMediaTools.swift" "$ROOT/desktop/NativeOpenMediaQueue.swift" "$ROOT/desktop/NativeWindowState.swift" "$ROOT/desktop/NativePlayer.swift" "$ROOT/desktop/main.swift" "$ROOT/desktop/.build/MPVShim.o" \
  -o "$APP/Contents/MacOS/LibreTV" "$MPV_LIB" \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -framework AppKit -framework WebKit -framework Security -framework OpenGL -framework Vision -framework ImageIO -framework UniformTypeIdentifiers -framework AVFoundation -framework AVKit
"$ROOT/desktop/bundle-mpv.sh" "$MPV_LIB" "$APP/Contents/Frameworks" "$APP/Contents/MacOS/LibreTV"
cp "$ROOT/desktop/Info.plist" "$APP/Contents/Info.plist"
cp -R .next/standalone/. "$APP/Contents/Resources/server/"
cp -R public "$APP/Contents/Resources/server/"
cp -R .next/static "$APP/Contents/Resources/server/.next/"
cp "$ROOT/desktop/serve.cjs" "$ROOT/desktop/使用说明.html" "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE-LibreTV"
cp "$ROOT/desktop/THIRD_PARTY_NATIVE.md" "$APP/Contents/Resources/ThirdPartyLicenses/README.md"
cp -R "$NATIVE_DEPS/licenses/." "$APP/Contents/Resources/ThirdPartyLicenses/"
cp "$NATIVE_DEPS/PROVENANCE.txt" "$APP/Contents/Resources/ThirdPartyLicenses/"
cp "$ROOT/desktop/NATIVE_DEPENDENCIES.md" "$APP/Contents/Resources/ThirdPartyLicenses/"
mkdir -p "$APP/Contents/Resources/CorrespondingSource"
cp -R "$NATIVE_DEPS/source/." "$APP/Contents/Resources/CorrespondingSource/"
if [[ "$NODE_ARCHS" == arm64 ]]; then
  cp "$NODE_BINARY" "$APP/Contents/Resources/runtime/node"
else
  /usr/bin/lipo "$NODE_BINARY" -thin arm64 -output "$APP/Contents/Resources/runtime/node"
fi
chmod 755 "$APP/Contents/Resources/runtime/node"
ICONSET="$ROOT/desktop/.build/AIplayer.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" public/icons/aiplayer-master.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  twice=$((size * 2))
  sips -z "$twice" "$twice" public/icons/aiplayer-master.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AIplayer.icns"
mkdir -p "$ROOT/downloads"
NODE_LICENSE="$ROOT/downloads/Node-LICENSE-$NODE_VERSION"
if [ ! -s "$NODE_LICENSE" ]; then
  curl --fail --location --max-time 30 -H 'Accept: application/vnd.github.raw+json' "https://api.github.com/repos/nodejs/node/contents/LICENSE?ref=$NODE_VERSION" -o "$NODE_LICENSE"
fi
cp "$NODE_LICENSE" "$APP/Contents/Resources/Node-LICENSE"
COPYFILE_DISABLE=1 tar --no-mac-metadata --exclude=upstream/node_modules --exclude=upstream/.next --exclude=desktop/.build --exclude='*.tsbuildinfo' --exclude='.DS_Store' --exclude='*.log' --exclude='.env' --exclude='.env*.local' -czf "$APP/Contents/Resources/Source.tar.gz" -C "$ROOT" README.md LICENSE NOTICE.md upstream desktop tests docs
find "$APP/Contents/Frameworks" -type f -name '*.dylib' -exec codesign --force --sign - {} \;
codesign --force --sign - "$APP/Contents/Resources/runtime/node"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
du -sh "$APP"
