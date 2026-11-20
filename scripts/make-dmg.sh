#!/bin/sh
# Builds the app and packages it into dist/AutoVolume-<version>.dmg with a drag-to-Applications window.
set -e
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
export VERSION
APP_NAME="Auto Volume"
VOL="$APP_NAME"
DIST="dist"
DMG="$DIST/AutoVolume-$VERSION.dmg"
RW="$DIST/rw.dmg"
STAGE="$DIST/dmg-stage"

scripts/build-app.sh

echo "▸ Preparing DMG contents…"
rm -rf "$STAGE" "$RW" "$DMG"
mkdir -p "$STAGE/.background"
cp -R "$DIST/$APP_NAME.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
swift scripts/make-assets.swift dmgbg "$STAGE/.background/background.png"

# Make sure no stale volume with the same name is mounted.
hdiutil detach "/Volumes/$VOL" >/dev/null 2>&1 || true

echo "▸ Creating disk image…"
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
MOUNT_INFO="$(hdiutil attach -readwrite -noverify -noautoopen "$RW")"
DEV="$(echo "$MOUNT_INFO" | grep -E '^/dev/' | head -1 | awk '{print $1}')"

echo "▸ Styling the installer window (Finder)…"
# Bounded run: if Finder automation isn't permitted, we still ship a working (plainer) DMG.
perl -e 'alarm 20; exec @ARGV' osascript <<APPLESCRIPT || echo "  (window styling skipped — DMG still works)"
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 520}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 112
        set text size of theViewOptions to 13
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "$APP_NAME.app" of container window to {170, 200}
        set position of item "Applications" of container window to {490, 200}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$DEV" >/dev/null 2>&1 || { sleep 2; hdiutil detach "$DEV" -force >/dev/null; }

echo "▸ Compressing…"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -rf "$RW" "$STAGE"
codesign --force --sign - "$DMG" >/dev/null 2>&1 || true

echo "✓ Built $DMG ($(du -h "$DMG" | cut -f1))"
