#!/bin/bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: bundle-mpv.sh <libmpv-dylib> <frameworks-dir> <executable>" >&2
  exit 2
fi

ROOT_LIB="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
FRAMEWORKS="$2"
EXECUTABLE="$3"
mkdir -p "$FRAMEWORKS"

declare -a queue=("$ROOT_LIB")
declare -a copied_names=()

already_copied() {
  local wanted="$1" existing
  for existing in "${copied_names[@]:-}"; do [[ "$existing" == "$wanted" ]] && return 0; done
  return 1
}

resolve_dependency() {
  local dependency="$1" owner="$2"
  case "$dependency" in
    /opt/homebrew/*|/usr/local/*) printf '%s\n' "$dependency" ;;
    @loader_path/*) printf '%s/%s\n' "$(dirname "$owner")" "${dependency#@loader_path/}" ;;
    @rpath/*)
      local name="${dependency#@rpath/}"
      local candidate
      for candidate in "$(dirname "$owner")/$name"; do
        [[ -e "$candidate" ]] && { printf '%s\n' "$candidate"; return; }
      done
      return 1
      ;;
    *) return 1 ;;
  esac
}

while ((${#queue[@]})); do
  source_lib="${queue[0]}"
  queue=("${queue[@]:1}")
  source_lib="$(cd "$(dirname "$source_lib")" && pwd -P)/$(basename "$source_lib")"
  name="$(basename "$source_lib")"
  already_copied "$name" && continue
  destination="$FRAMEWORKS/$name"
  archs="$(lipo -archs "$source_lib")"
  if [[ " $archs " != *" arm64 "* ]]; then
    echo "Native dependency lacks arm64: $source_lib ($archs)" >&2
    exit 1
  elif [[ "$archs" == "arm64" ]]; then
    cp -L "$source_lib" "$destination"
  else
    lipo "$source_lib" -thin arm64 -output "$destination"
  fi
  chmod u+w "$destination"
  copied_names+=("$name")

  install_id="$(otool -arch arm64 -D "$source_lib" 2>/dev/null | sed -n '2p' | xargs || true)"
  [[ -n "$install_id" ]] && install_name_tool -id "@rpath/$name" "$destination"

  while IFS= read -r dependency; do
    case "$dependency" in
      /System/*|/usr/lib/*) continue ;;
    esac
    resolved="$(resolve_dependency "$dependency" "$source_lib" || true)"
    if [[ -z "$resolved" || ! -e "$resolved" ]]; then
      echo "Unable to resolve non-system dependency $dependency from $source_lib" >&2
      exit 1
    fi
    dependency_name="$(basename "$resolved")"
    install_name_tool -change "$dependency" "@rpath/$dependency_name" "$destination"
    already_copied "$dependency_name" || queue+=("$resolved")
  done < <(otool -arch arm64 -L "$source_lib" | tail -n +2 | sed -E 's/^[[:space:]]*([^[:space:]]+).*/\1/')
done

while IFS= read -r dependency; do
  case "$dependency" in
    /opt/homebrew/*|/usr/local/*)
      install_name_tool -change "$dependency" "@rpath/$(basename "$dependency")" "$EXECUTABLE"
      ;;
  esac
done < <(otool -L "$EXECUTABLE" | tail -n +2 | sed -E 's/^[[:space:]]*([^[:space:]]+).*/\1/')

if otool -L "$EXECUTABLE" "$FRAMEWORKS"/*.dylib | /usr/bin/grep -Eq '/opt/homebrew/|/usr/local/'; then
  echo "Bundled native binaries retain a package-manager path" >&2
  exit 1
fi

echo "Bundled ${#copied_names[@]} independently sourced native libraries"
