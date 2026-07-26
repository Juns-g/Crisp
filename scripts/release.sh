#!/bin/bash
set -euo pipefail

# Crisp release script: builds a signed universal DMG with the Command Line
# Tools only (no Xcode), and optionally publishes the GitHub release and bumps
# the Homebrew tap. Default is a dry run: it builds and verifies the DMG but
# publishes nothing. Pass --publish to actually release.
#
# Usage:
#   ./scripts/release.sh v1.0.4 notes.md            # dry run: build DMG only
#   ./scripts/release.sh v1.0.4 notes.md --publish  # build + release + tap
#
# notes.md is the release body (required for --publish; optional for dry run).

TAG="${1:?Usage: ./scripts/release.sh vX.Y.Z [notes.md] [--publish]}"
NOTES="${2:-}"
PUBLISH=false
for arg in "$@"; do [ "$arg" = "--publish" ] && PUBLISH=true; done
[ "${NOTES:-}" = "--publish" ] && NOTES=""

VERSION="${TAG#v}"                       # strip leading v for Info.plist
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD="$ROOT/build"
APP="$BUILD/Crisp.app"
DMG="$ROOT/Crisp.dmg"
TAP_REPO="didriksg/homebrew-tap"
TAP_CASK="Casks/crisp.rb"

rm -rf "$BUILD"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling universal binary (arm64 + x86_64)…"
SRC=$(find Crisp -name '*.swift')
for a in arm64 x86_64; do
  swiftc -O -parse-as-library -target "$a-apple-macos15.0" \
    -import-objc-header Crisp/Crisp-Bridging-Header.h \
    -Xlinker -U -Xlinker _SLSConfigureDisplayEnabled \
    -Xlinker -U -Xlinker _SLSGetDisplayList \
    $SRC -o "$BUILD/Crisp-$a"
done
lipo -create "$BUILD/Crisp-arm64" "$BUILD/Crisp-x86_64" -output "$APP/Contents/MacOS/Crisp"

echo "==> Building app icon from asset catalog…"
ICONSET="$BUILD/AppIcon.iconset"; mkdir -p "$ICONSET"
ICONS="Crisp/Assets.xcassets/AppIcon.appiconset"
cp "$ICONS/icon_16.png"   "$ICONSET/icon_16x16.png"
cp "$ICONS/icon_32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$ICONS/icon_32.png"   "$ICONSET/icon_32x32.png"
cp "$ICONS/icon_64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$ICONS/icon_128.png"  "$ICONSET/icon_128x128.png"
cp "$ICONS/icon_256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$ICONS/icon_256.png"  "$ICONSET/icon_256x256.png"
cp "$ICONS/icon_512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$ICONS/icon_512.png"  "$ICONSET/icon_512x512.png"
cp "$ICONS/icon_1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Writing Info.plist / PkgInfo…"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Crisp</string>
	<key>CFBundleDisplayName</key><string>Crisp</string>
	<key>CFBundleIdentifier</key><string>com.crisp.app</string>
	<key>CFBundleExecutable</key><string>Crisp</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleVersion</key><string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key><string>15.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHumanReadableCopyright</key><string>Crisp - Free &amp; Open Source</string>
	<key>NSAppleEventsUsageDescription</key><string>Crisp uses System Events to switch Dark Mode with the system's animated transition.</string>
	<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)…"
xattr -cr "$APP"
codesign --force --deep --sign - --entitlements Crisp/Crisp.entitlements "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Building DMG…"
STAGE="$BUILD/dmg"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname Crisp -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
echo "==> Built $DMG"
echo "    version $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist"), archs $(lipo -archs "$APP/Contents/MacOS/Crisp"), sha256 $SHA"

if [ "$PUBLISH" != true ]; then
  echo "==> Dry run. Pass --publish to create the release and bump the tap."
  exit 0
fi

[ -n "$NOTES" ] && [ -f "$NOTES" ] || { echo "ERROR: --publish needs a notes file: ./scripts/release.sh $TAG notes.md --publish"; exit 1; }

# Keep project.yml (the Xcode build path) in sync with the version we shipped.
sed -i '' "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"${VERSION}\"/" project.yml

echo "==> Creating GitHub release ${TAG}…"
gh release create "$TAG" --title "Crisp ${TAG}" --notes-file "$NOTES" "$DMG"

echo "==> Bumping Homebrew tap…"
SHA_FILE=$(gh api "repos/$TAP_REPO/contents/$TAP_CASK" --jq '.sha')
gh api "repos/$TAP_REPO/contents/$TAP_CASK" --jq '.content' | base64 -d \
  | sed -e "s/version \"[^\"]*\"/version \"${VERSION}\"/" \
        -e "s/sha256 \"[^\"]*\"/sha256 \"${SHA}\"/" > "$BUILD/crisp.rb"
gh api -X PUT "repos/$TAP_REPO/contents/$TAP_CASK" \
  -f message="crisp ${VERSION}" \
  -f content="$(base64 -i "$BUILD/crisp.rb")" \
  -f sha="$SHA_FILE" --jq '.commit.sha' >/dev/null

echo "==> Released ${TAG} and updated the tap."
