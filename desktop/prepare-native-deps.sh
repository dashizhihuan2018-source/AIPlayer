#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DOWNLOADS="$ROOT/downloads"
DEST="$ROOT/desktop/.build/native-deps"
IINA_VERSION="1.5.0"
IINA_DMG="$DOWNLOADS/IINA.v${IINA_VERSION}.dmg"
IINA_SHA256="8fad50479b10e09645053457cec46bd53d054ced2242cfe68f74586735a20dc7"
IINA_LICENSE_SHA256="589ed823e9a84c56feb95ac58e7cf384626b9cbf4fda2a907bc36e103de1bad2"
MPV_VERSION="0.41.0"
MPV_ARCHIVE="$DOWNLOADS/mpv-v${MPV_VERSION}.tar.gz"
MPV_SHA256="ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209"
IINA_SOURCE="$DOWNLOADS/IINA-v${IINA_VERSION}-source.tar.gz"
IINA_SOURCE_SHA256="c60ddcd3074de1548133fcd95df89e724bf34e98688508bfa5db17edd6e70e38"
DEPS_COMMIT="9abe2c1c66efa21a7a199a678d1ab55be72e0301"
DEPS_SOURCE="$DOWNLOADS/IINA-deps-buildscripts-${DEPS_COMMIT}.tar.gz"
DEPS_SOURCE_SHA256="cc78d3c005270f50a7293c78bf192552f78303875efe8e1a5145f77933b78aea"
RUBBERBAND_SOURCE="$DOWNLOADS/rubberband-4.0.0.tar.bz2"
RUBBERBAND_SHA256="af050313ee63bc18b35b2e064e5dce05b276aaf6d1aa2b8a82ced1fe2f8028e9"

mkdir -p "$DOWNLOADS" "$ROOT/desktop/.build"
verify() {
  local expected="$1" file="$2"
  [[ -f "$file" ]] && [[ "$(shasum -a 256 "$file" | awk '{print $1}')" == "$expected" ]]
}

if ! verify "$IINA_SHA256" "$IINA_DMG"; then
  rm -f "$IINA_DMG"
  curl --fail --location --retry 3 \
    "https://github.com/iina/iina/releases/download/v${IINA_VERSION}/IINA.v${IINA_VERSION}.dmg" \
    --output "$IINA_DMG"
  verify "$IINA_SHA256" "$IINA_DMG" || { echo "IINA distribution checksum mismatch" >&2; exit 1; }
fi
if ! verify "$MPV_SHA256" "$MPV_ARCHIVE"; then
  rm -f "$MPV_ARCHIVE"
  curl --fail --location --retry 3 \
    "https://github.com/mpv-player/mpv/archive/refs/tags/v${MPV_VERSION}.tar.gz" \
    --output "$MPV_ARCHIVE"
  verify "$MPV_SHA256" "$MPV_ARCHIVE" || { echo "mpv source checksum mismatch" >&2; exit 1; }
fi
if ! verify "$IINA_SOURCE_SHA256" "$IINA_SOURCE"; then
  curl --fail --location --retry 3 "https://github.com/iina/iina/archive/refs/tags/v${IINA_VERSION}.tar.gz" --output "$IINA_SOURCE"
  verify "$IINA_SOURCE_SHA256" "$IINA_SOURCE" || { echo "IINA source checksum mismatch" >&2; exit 1; }
fi
if ! verify "$DEPS_SOURCE_SHA256" "$DEPS_SOURCE"; then
  curl --fail --location --retry 3 "https://github.com/iina/deps-buildscripts/archive/${DEPS_COMMIT}.tar.gz" --output "$DEPS_SOURCE"
  verify "$DEPS_SOURCE_SHA256" "$DEPS_SOURCE" || { echo "IINA dependency build source checksum mismatch" >&2; exit 1; }
fi
if ! verify "$RUBBERBAND_SHA256" "$RUBBERBAND_SOURCE"; then
  curl --fail --location --retry 3 "https://breakfastquay.com/files/releases/rubberband-4.0.0.tar.bz2" --output "$RUBBERBAND_SOURCE"
  verify "$RUBBERBAND_SHA256" "$RUBBERBAND_SOURCE" || { echo "Rubber Band source checksum mismatch" >&2; exit 1; }
fi

rm -rf "$DEST"
mkdir -p "$DEST/Frameworks" "$DEST/include" "$DEST/licenses" "$DEST/source" "$DEST/mount"
DEVICE="$(hdiutil attach "$IINA_DMG" -nobrowse -readonly -mountpoint "$DEST/mount" | awk '/Apple_HFS/ {print $1; exit}')"
cleanup() {
  if [[ -n "${DEVICE:-}" ]]; then hdiutil detach "$DEVICE" >/dev/null 2>&1 || true; fi
  rmdir "$DEST/mount" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cp -R "$DEST/mount/IINA.app/Contents/Frameworks/"*.dylib "$DEST/Frameworks/"
cp "$DEST/mount/IINA.app/Contents/Resources/Credits.rtf" "$DEST/licenses/IINA-Credits.rtf"
curl --fail --location --retry 3 "https://raw.githubusercontent.com/iina/iina/v${IINA_VERSION}/LICENSE" --output "$DEST/licenses/IINA-LICENSE"
verify "$IINA_LICENSE_SHA256" "$DEST/licenses/IINA-LICENSE" || { echo "IINA license checksum mismatch" >&2; exit 1; }

tar -xzf "$MPV_ARCHIVE" -C "$DEST" \
  "mpv-${MPV_VERSION}/include/mpv/client.h" \
  "mpv-${MPV_VERSION}/include/mpv/render.h" \
  "mpv-${MPV_VERSION}/include/mpv/render_gl.h" \
  "mpv-${MPV_VERSION}/Copyright" \
  "mpv-${MPV_VERSION}/LICENSE.GPL" \
  "mpv-${MPV_VERSION}/LICENSE.LGPL"
mkdir -p "$DEST/include/mpv"
mv "$DEST/mpv-${MPV_VERSION}/include/mpv/"*.h "$DEST/include/mpv/"
mv "$DEST/mpv-${MPV_VERSION}/Copyright" "$DEST/licenses/mpv-Copyright"
mv "$DEST/mpv-${MPV_VERSION}/LICENSE.GPL" "$DEST/licenses/mpv-LICENSE.GPL"
mv "$DEST/mpv-${MPV_VERSION}/LICENSE.LGPL" "$DEST/licenses/mpv-LICENSE.LGPL"
rm -rf "$DEST/mpv-${MPV_VERSION}"
cp "$MPV_ARCHIVE" "$DEST/source/"
cp "$IINA_SOURCE" "$DEST/source/"
cp "$DEPS_SOURCE" "$DEST/source/"
cp "$RUBBERBAND_SOURCE" "$DEST/source/"
node "$ROOT/desktop/collect-native-sources.js" \
  "$DEPS_SOURCE" "$DEST/source" "$DEST/licenses/components" "$DOWNLOADS/native-sources"

test -f "$DEST/Frameworks/libmpv.2.dylib"
if [[ " $(lipo -archs "$DEST/Frameworks/libmpv.2.dylib") " != *" arm64 "* ]]; then
  echo "Prepared libmpv does not contain arm64" >&2
  exit 1
fi
printf '%s\n' \
  "IINA v${IINA_VERSION} release (SHA-256 ${IINA_SHA256})" \
  "IINA v${IINA_VERSION} source (SHA-256 ${IINA_SOURCE_SHA256})" \
  "IINA dependency build scripts ${DEPS_COMMIT} (SHA-256 ${DEPS_SOURCE_SHA256})" \
  "mpv v${MPV_VERSION} source (SHA-256 ${MPV_SHA256})" \
  "Rubber Band 4.0.0 source (SHA-256 ${RUBBERBAND_SHA256})" \
  "$(find "$DEST/source" -maxdepth 1 -type f | wc -l | tr -d ' ') source artifacts; checksums are embedded in versions.env or ADDITIONAL-SOURCE-SHA256SUMS.txt" \
  "$(find "$DEST/licenses/components" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ') component notice groups" > "$DEST/PROVENANCE.txt"
echo "$DEST"
