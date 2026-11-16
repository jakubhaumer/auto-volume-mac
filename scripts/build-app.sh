#!/bin/sh
# Builds "dist/Auto Volume.app" (menu bar app). Usage: scripts/build-app.sh
set -e
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
APP_NAME="Auto Volume"
BUNDLE_ID="com.jakubhaumer.autovolume"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "▸ Building (release)…"
if swift build -c release --product AutoVolume --arch arm64 --arch x86_64 >/dev/null 2>&1; then
    BIN="$(swift build -c release --product AutoVolume --arch arm64 --arch x86_64 --show-bin-path)/AutoVolume"
    echo "  universal binary (Apple Silicon + Intel)"
else
    swift build -c release --product AutoVolume
    BIN="$(swift build -c release --product AutoVolume --show-bin-path)/AutoVolume"
fi

echo "▸ Creating icon…"
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$DIST"
swift scripts/make-assets.swift icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$DIST/AppIcon.icns"
rm -rf "$ICONSET"

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AutoVolume"
cp "$DIST/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>AutoVolume</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.2</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Auto Volume listens to your Mac's audio so it can even out loud and quiet parts. Nothing is recorded or stored.</string>
</dict>
</plist>
PLIST

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP" 2>&1 | grep -v "replacing existing signature" || true
codesign --verify --deep --strict "$APP" && echo "  signature OK"

echo "✓ Built $APP"
