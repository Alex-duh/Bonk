#!/bin/bash
# Release packaging: release build → Bonk.app → Bonk-<version>.dmg with a
# drag-to-Applications layout. Output lands in dist/.
#
# Signing:
#   Default              — ad-hoc signature (users must right-click → Open once)
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./package_dmg.sh
#                        — proper signature, ready for notarization (see RELEASING.md)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.0.0"
APP="dist/Bonk.app"
DMG="dist/Bonk-$VERSION.dmg"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "==> Building Bonk $VERSION (release)..."
swift build -c release

echo "==> Bundling $APP..."
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Bonk "$APP/Contents/MacOS/Bonk"
sed "s/__VERSION__/$VERSION/g" Packaging/Info.plist > "$APP/Contents/Info.plist"

if [ -f Packaging/logo.png ]; then
    bash Packaging/make_icns.sh Packaging/logo.png "$APP/Contents/Resources/AppIcon.icns"
else
    echo "    (no Packaging/logo.png — shipping without a custom icon)"
fi
# Menu bar template icons (vector; luminance→alpha conversion happens at runtime)
cp Packaging/*.pdf "$APP/Contents/Resources/" 2>/dev/null \
    || echo "    (no Packaging/*.pdf — menu bar falls back to ✊ emoji)"

echo "==> Signing ($([ "$SIGN_IDENTITY" = "-" ] && echo ad-hoc || echo "$SIGN_IDENTITY"))..."
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "==> Creating $DMG..."
STAGING="$(mktemp -d)/Bonk"
mkdir -p "$STAGING/.background"
# Pre-create .fseventsd with a no_log marker so macOS doesn't fill it with
# event logs at unmount, and so we can hide/park it below
mkdir -p "$STAGING/.fseventsd"
touch "$STAGING/.fseventsd/no_log"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
swift Packaging/make_dmg_background.swift "$STAGING/.background/bg.png" >/dev/null \
    || echo "    (background generation failed — plain DMG)"

# Build read-write, style the Finder window, then compress to the final image
RW="dist/Bonk-rw.dmg"
rm -f "$DMG" "$RW"
hdiutil create -volname "Bonk" -srcfolder "$STAGING" -ov -format UDRW "$RW" >/dev/null
MOUNT=$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | grep -o "/Volumes/.*")
# The volume mounts as "Bonk 1" etc. if another Bonk image is already mounted —
# always address the disk by the name Finder actually gave this mount
VOLNAME=$(basename "$MOUNT")

# Icon layout + background (best effort — needs Finder automation permission)
osascript >/dev/null <<OSA || echo "    (Finder styling skipped — grant Terminal → Automation → Finder and re-run)"
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 560}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 104
        set text size of viewOptions to 13
        set background picture of viewOptions to (POSIX file "$MOUNT/.background/bg.png" as alias)
        set position of item "Bonk.app" of container window to {165, 205}
        set position of item "Applications" of container window to {495, 205}
        -- park housekeeping folders far outside the window for anyone
        -- browsing with hidden files visible
        try
            set position of item ".background" of container window to {1400, 600}
        end try
        try
            set position of item ".fseventsd" of container window to {1500, 600}
        end try
        close
        open
        delay 1
        close
    end tell
end tell
OSA
# Finder-hidden flag on top of the dotfile convention
chflags hidden "$MOUNT/.background" "$MOUNT/.fseventsd" 2>/dev/null || true
sync
hdiutil detach "$MOUNT" -quiet
hdiutil convert "$RW" -format UDZO -o "$DMG" >/dev/null
rm -f "$RW"
rm -rf "$(dirname "$STAGING")"

# Stable-named copy — release uploads use this so the landing page's
# /releases/latest/download/Bonk.dmg URL never changes (version lives in the tag)
cp "$DMG" dist/Bonk.dmg

echo ""
echo "Done: $DMG  (+ dist/Bonk.dmg for release uploads)"
echo "  • Users open the .dmg and drag Bonk into Applications."
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "  • Ad-hoc signed: first launch requires right-click → Open (see RELEASING.md)."
else
    echo "  • Next: notarize — see RELEASING.md."
fi
