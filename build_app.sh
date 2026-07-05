#!/bin/bash
# Development build: compile → bundle → ad-hoc sign → launch.
# For the distributable .dmg use package_dmg.sh instead.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.0.0"

echo "Building Bonk (debug)..."
swift build

echo "Creating Bonk.app bundle..."
rm -rf Bonk.app
mkdir -p Bonk.app/Contents/MacOS Bonk.app/Contents/Resources
cp .build/debug/Bonk Bonk.app/Contents/MacOS/Bonk
sed "s/__VERSION__/$VERSION/g" Packaging/Info.plist > Bonk.app/Contents/Info.plist

# App icon: drop your logo at Packaging/logo.png (1024×1024) and it's picked up here
if [ -f Packaging/logo.png ]; then
    bash Packaging/make_icns.sh Packaging/logo.png Bonk.app/Contents/Resources/AppIcon.icns
fi
# Menu bar template icons (vector; luminance→alpha conversion happens at runtime)
cp Packaging/*.pdf Bonk.app/Contents/Resources/ 2>/dev/null || true

echo "Signing Bonk.app (ad-hoc)..."
codesign --force --deep --sign - Bonk.app

echo "Done! Launching Bonk.app..."
open Bonk.app

echo ""
echo "⚠️  IMPORTANT: Every rebuild changes the app signature."
echo "   If commands aren't working, re-grant Accessibility NOW:"
echo "   System Settings → Privacy & Security → Accessibility"
echo "   Remove Bonk if listed, click +, add Bonk.app from this folder, toggle ON."
echo "   Do NOT rebuild after granting — that invalidates the permission again."
