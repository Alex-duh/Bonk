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

echo "==> Signing ($([ "$SIGN_IDENTITY" = "-" ] && echo ad-hoc || echo "$SIGN_IDENTITY"))..."
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "==> Creating $DMG..."
STAGING="$(mktemp -d)/Bonk"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Bonk" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$(dirname "$STAGING")"

echo ""
echo "Done: $DMG"
echo "  • Users open the .dmg and drag Bonk into Applications."
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "  • Ad-hoc signed: first launch requires right-click → Open (see RELEASING.md)."
else
    echo "  • Next: notarize — see RELEASING.md."
fi
