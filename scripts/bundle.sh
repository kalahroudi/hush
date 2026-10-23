#!/bin/bash
# Builds Hush.app into ./dist (or $DIST_DIR). Usage: scripts/bundle.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
APP="${DIST_DIR:-dist}/Hush.app"
REPO="${APP_REPO:-kalahroudi/hush}"
BRANCH="${APP_BRANCH:-main}"
COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
if [ "$COMMIT" != "unknown" ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then COMMIT="$COMMIT-dirty"; fi

# shellcheck source=scripts/toolchain-check.sh
. "$(dirname "$0")/toolchain-check.sh"

swift build -c release --product Hush
swift build -c release --product hush-mcp
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Hush" "$APP/Contents/MacOS/Hush"
cp "$BIN/hush-mcp" "$APP/Contents/MacOS/hush-mcp"

# App icon, drawn by the app itself so no image tools are needed.
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$BIN/Hush" --write-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Hush</string>
  <key>CFBundleDisplayName</key><string>Hush</string>
  <key>CFBundleIdentifier</key><string>com.kalahroudi.hush</string>
  <key>CFBundleExecutable</key><string>Hush</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSMultipleInstancesProhibited</key><true/>
  <key>HushCommit</key><string>$COMMIT</string>
  <key>HushRepo</key><string>$REPO</string>
  <key>HushBranch</key><string>$BRANCH</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

# Ad-hoc signed by default. With SIGN_IDENTITY set to a "Developer ID Application: ..." identity it is signed
# for distribution with the hardened runtime.
if [ "${SIGN_IDENTITY:--}" = "-" ]; then
  SIGN_FLAGS=(--force --sign -)
else
  SIGN_FLAGS=(--force --timestamp --options runtime --entitlements scripts/Hush.entitlements --sign "$SIGN_IDENTITY")
fi
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/hush-mcp"
codesign "${SIGN_FLAGS[@]}" "$APP"
codesign --verify --strict "$APP"

echo "Built $APP"
