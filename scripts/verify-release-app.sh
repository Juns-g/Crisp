#!/bin/bash
set -euo pipefail

APP="${1:?Usage: ./scripts/verify-release-app.sh /path/to/Crisp.app}"
CRISPCTL="$APP/Contents/MacOS/crispctl"

if [ ! -x "$CRISPCTL" ]; then
  echo "ERROR: embedded crispctl is missing or not executable: $CRISPCTL" >&2
  exit 1
fi

ARCHITECTURE_OUTPUT="$(lipo -archs "$CRISPCTL")"
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

codesign --verify --deep --strict "$APP"
echo "Verified Crisp.app: executable universal crispctl and strict app signature"
