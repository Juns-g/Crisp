#!/bin/bash
set -euo pipefail

REPO="${1:?Usage: build-embed-sign-crispctl.sh REPO APP SCRATCH SIGNING_ID}"
APP="${2:?Usage: build-embed-sign-crispctl.sh REPO APP SCRATCH SIGNING_ID}"
SCRATCH="${3:?Usage: build-embed-sign-crispctl.sh REPO APP SCRATCH SIGNING_ID}"
SIGNING_ID="${4-}"
DESTINATION="$APP/Contents/MacOS/crispctl"

BUILD_ARGS=(
  swift build --disable-sandbox -c release --product crispctl
  --package-path "$REPO" --scratch-path "$SCRATCH"
  --arch arm64 --arch x86_64
)

xcrun "${BUILD_ARGS[@]}"
BIN_PATH="$(xcrun "${BUILD_ARGS[@]}" --show-bin-path)"
SOURCE="$BIN_PATH/crispctl"

mkdir -p "$(dirname "$DESTINATION")"
cp "$SOURCE" "$DESTINATION"
if [ ! -x "$DESTINATION" ]; then
  echo "ERROR: embedded crispctl is not executable: $DESTINATION" >&2
  exit 1
fi

ARCHITECTURE_OUTPUT="$(lipo -archs "$DESTINATION")"
read -r -a ARCHITECTURES <<< "$ARCHITECTURE_OUTPUT"
HAS_ARM64=false
HAS_X86_64=false
for architecture in "${ARCHITECTURES[@]}"; do
  [ "$architecture" = "arm64" ] && HAS_ARM64=true
  [ "$architecture" = "x86_64" ] && HAS_X86_64=true
done
if [ "${#ARCHITECTURES[@]}" -ne 2 ] || \
   [ "$HAS_ARM64" != true ] || [ "$HAS_X86_64" != true ]; then
  echo "ERROR: embedded crispctl must contain exactly arm64 and x86_64; found: ${ARCHITECTURES[*]:-none}" >&2
  exit 1
fi

if [ -n "$SIGNING_ID" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGNING_ID" "$DESTINATION"
else
  codesign --force --sign - "$DESTINATION"
fi
