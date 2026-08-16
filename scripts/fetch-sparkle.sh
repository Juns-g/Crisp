#!/bin/bash
# Fetches the prebuilt Sparkle updater framework + CLI tools into vendor/Sparkle/
# (gitignored). Pinned by version and sha256 so every build path (release.sh,
# dev.sh, Makefile, CI) links the exact same binary. Idempotent: no-op when the
# pinned version is already in place.
set -euo pipefail

SPARKLE_VERSION="2.9.5"
SPARKLE_SHA256="015336b601493e05c237964954bff6191370003d94edefe663724c88840d73cc"
# Bump the -pN suffix when the post-extract patching below changes, so cached
# vendor/ dirs refresh.
SPARKLE_PATCH_REV="${SPARKLE_VERSION}-p1"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/vendor/Sparkle"

if [ -f "$DEST/.version" ] && [ "$(cat "$DEST/.version")" = "$SPARKLE_PATCH_REV" ]; then
    exit 0
fi

echo "==> Fetching Sparkle ${SPARKLE_VERSION}…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
echo "$SPARKLE_SHA256  $TMP/sparkle.tar.xz" | shasum -a 256 -c - >/dev/null

rm -rf "$DEST"
mkdir -p "$DEST"
# Only the framework and CLI tools; the archive's test app and dSYMs stay out.
tar -xJf "$TMP/sparkle.tar.xz" -C "$DEST" "./Sparkle.framework" "./bin"

# House style: no em-dashes in user-facing text. Sparkle's English update
# alert uses them ("... is now available—you have ..."); swap for the
# semicolon Sparkle already uses elsewhere in the same strings. Editing the
# framework is fine: every build path re-signs it anyway (XPCServices strip).
STRINGS="$DEST/Sparkle.framework/Versions/B/Resources/Base.lproj/Sparkle.strings"
plutil -convert xml1 "$STRINGS"
sed -i '' 's/—/; /g' "$STRINGS"
plutil -convert binary1 "$STRINGS"

echo "$SPARKLE_PATCH_REV" > "$DEST/.version"
echo "==> Sparkle ${SPARKLE_VERSION} ready in vendor/Sparkle"
