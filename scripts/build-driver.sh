#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
source "$(dirname "$0")/common.sh"
require_macos
python3 "$ROOT/scripts/vendor.py" --verify
DRIVER="$BUILD/driver/Release/Roomtastic.driver"
mkdir -p "$DRIVER/Contents/MacOS" "$DRIVER/Contents/Resources"
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=14.0 -O2 -bundle \
    -include "$ROOT/packaging/RoomtasticDriver.h" \
    "$ROOT/Vendor/BlackHole/BlackHole/BlackHole.c" \
    -framework CoreAudio -framework CoreFoundation -framework Accelerate \
    -o "$DRIVER/Contents/MacOS/Roomtastic"
cp "$ROOT/Vendor/BlackHole/BlackHole/BlackHole.plist" "$DRIVER/Contents/Info.plist"
plutil -replace CFBundleExecutable -string Roomtastic "$DRIVER/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string org.roomtastic.driver "$DRIVER/Contents/Info.plist"
plutil -replace CFBundleName -string Roomtastic "$DRIVER/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string 1.0.0 "$DRIVER/Contents/Info.plist"
plutil -replace CFBundleVersion -string 1 "$DRIVER/Contents/Info.plist"
plutil -insert LSMinimumSystemVersion -string 14.0 "$DRIVER/Contents/Info.plist"
# A distinct factory UUID allows Roomtastic and stock BlackHole to coexist.
plutil -replace CFPlugInFactories -json '{"FA54D735-EC1E-4F6F-96DC-A186D7F2CF9B":"BlackHole_Create"}' "$DRIVER/Contents/Info.plist"
plutil -replace CFPlugInTypes -json '{"443ABAB8-E7B3-491A-B985-BEB9187030DB":["FA54D735-EC1E-4F6F-96DC-A186D7F2CF9B"]}' "$DRIVER/Contents/Info.plist"
cp "$ROOT/Vendor/BlackHole/LICENSE" "$DRIVER/Contents/Resources/LICENSE"
cp "$ROOT/Vendor/BlackHole/BlackHole/BlackHole.icns" "$DRIVER/Contents/Resources/BlackHole.icns"
codesign --force --sign - "$DRIVER"
printf 'Built %s (not installed).\n' "$DRIVER"
