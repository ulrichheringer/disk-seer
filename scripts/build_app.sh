#!/bin/zsh
# Builds DiskSeer.app (release) into ./dist and signs it ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
CONFIG=${CONFIG:-release}
APP="$ROOT/dist/DiskSeer.app"

swift build -c "$CONFIG" --product DiskSeer
BIN="$(swift build -c "$CONFIG" --show-bin-path)/DiskSeer"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DiskSeer"

# Icon
ICONSET="$ROOT/.build/AppIcon.iconset"
if [[ ! -f "$ROOT/Resources/AppIcon.icns" || scripts/make_icon.swift -nt "$ROOT/Resources/AppIcon.icns" ]]; then
  rm -rf "$ICONSET"
  swift scripts/make_icon.swift "$ICONSET"
  iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
fi
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

VERSION=$(cat VERSION 2>/dev/null || echo "1.0.0")
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DiskSeer</string>
  <key>CFBundleDisplayName</key><string>DiskSeer</string>
  <key>CFBundleIdentifier</key><string>dev.heringer.diskseer</string>
  <key>CFBundleExecutable</key><string>DiskSeer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>DiskSeer asks Finder to empty the Trash when you choose “Empty Trash”.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Folder</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.folder</string><string>public.volume</string></array>
    </dict>
  </array>
  <key>NSHumanReadableCopyright</key><string>© 2026 DiskSeer</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"
