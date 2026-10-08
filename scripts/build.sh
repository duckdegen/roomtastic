#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
source "$(dirname "$0")/common.sh"
require_macos
"$ROOT/scripts/build-driver.sh"
"$ROOT/scripts/build-sender.sh"
cd "$ROOT"
xcrun swift build -c release --arch arm64
BIN="$(xcrun swift build -c release --arch arm64 --show-bin-path)"
APP="$BUILD/Roomtastic.app"
# Only this script's staging bundle is replaced.
rm -rf "$APP"
mkdir -p "$APP/Contents/"{MacOS,Helpers,Resources/Licenses}
install -m 755 "$BIN/RoomtasticMac" "$APP/Contents/MacOS/RoomtasticMac"
install -m 755 "$BIN/RoomtasticService" "$APP/Contents/MacOS/RoomtasticService"
install -m 755 "$BUILD/helpers/cliairplay" "$APP/Contents/Helpers/cliairplay"
cp "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
cp -R "$ROOT/LICENSES/." "$APP/Contents/Resources/Licenses/"
cp "$ROOT/Vendor/dependencies.lock.json" "$APP/Contents/Resources/"
if [[ -n "${APPLICATION_IDENTITY:-}" ]]; then
    [[ -n "${DEVELOPMENT_TEAM:-}" ]] || fail 'DEVELOPMENT_TEAM is required with APPLICATION_IDENTITY.'
    codesign --force --options runtime --timestamp --sign "$APPLICATION_IDENTITY" "$APP/Contents/Helpers/cliairplay"
    codesign --force --options runtime --timestamp --entitlements "$ROOT/packaging/Roomtastic.entitlements.plist" \
        --sign "$APPLICATION_IDENTITY" "$APP/Contents/MacOS/RoomtasticService"
    codesign --force --options runtime --timestamp --entitlements "$ROOT/packaging/Roomtastic.entitlements.plist" \
        --sign "$APPLICATION_IDENTITY" "$APP"
    codesign --force --options runtime --timestamp --sign "$APPLICATION_IDENTITY" "$BUILD/driver/Release/Roomtastic.driver"
else
    # Apple Silicon requires ad-hoc Mach-O signatures; this is not a signed release.
    codesign --force --sign - "$APP/Contents/Helpers/cliairplay"
    codesign --force --sign - "$APP/Contents/MacOS/RoomtasticService"
    codesign --force --sign - "$APP"
    codesign --force --sign - "$BUILD/driver/Release/Roomtastic.driver"
fi
printf 'Built %s (release distribution requires Developer ID signing/notarization).\n' "$APP"
