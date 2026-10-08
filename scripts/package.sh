#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
source "$(dirname "$0")/common.sh"
require_macos
[[ -d "$BUILD/Roomtastic.app" && -d "$BUILD/driver/Release/Roomtastic.driver" ]] || fail 'Run scripts/build.sh first.'
python3 "$ROOT/scripts/vendor.py" --verify
VERSION="${VERSION:-1.0.0}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'VERSION must be numeric major.minor.patch.'
STAGE="$BUILD/package-root"
rm -rf "$STAGE"
mkdir -p "$STAGE/Applications" "$STAGE/Library/Audio/Plug-Ins/HAL" "$STAGE/Library/LaunchAgents" \
    "$STAGE/Library/Application Support/Roomtastic/Helpers" "$DIST"
ditto --noextattr --noacl --norsrc "$BUILD/Roomtastic.app" "$STAGE/Applications/Roomtastic.app"
ditto --noextattr --noacl --norsrc "$BUILD/driver/Release/Roomtastic.driver" "$STAGE/Library/Audio/Plug-Ins/HAL/Roomtastic.driver"
install -m 644 "$ROOT/packaging/org.roomtastic.service.plist" "$STAGE/Library/LaunchAgents/"
SUPPORT="$STAGE/Library/Application Support/Roomtastic"
install -m 644 "$ROOT/packaging/org.roomtastic.ptp.plist" "$SUPPORT/"
for script in uninstall.sh enable-ptp.sh service.sh; do
    install -m 755 "$ROOT/scripts/$script" "$SUPPORT/"
done
install -m 755 "$BUILD/Roomtastic.app/Contents/Helpers/cliairplay" "$SUPPORT/Helpers/cliairplay"
ARGS=(--root "$STAGE" --identifier org.roomtastic.pkg --version "$VERSION" --install-location / \
    --ownership recommended --scripts "$ROOT/packaging/installer-scripts")
if [[ -n "${INSTALLER_IDENTITY:-}" ]]; then
    [[ -n "${APPLICATION_IDENTITY:-}" && -n "${DEVELOPMENT_TEAM:-}" ]] || fail 'Signed package needs APPLICATION_IDENTITY, INSTALLER_IDENTITY and DEVELOPMENT_TEAM.'
    # A caller must rebuild with these identities; do not mistake an ad-hoc build for Developer ID.
    codesign --verify --deep --strict "$STAGE/Applications/Roomtastic.app"
    codesign --verify --strict "$STAGE/Library/Audio/Plug-Ins/HAL/Roomtastic.driver"
    for bundle in "$STAGE/Applications/Roomtastic.app" "$STAGE/Library/Audio/Plug-Ins/HAL/Roomtastic.driver"; do
        info="$(codesign -dvv "$bundle" 2>&1)"
        [[ "$info" == *"TeamIdentifier=$DEVELOPMENT_TEAM"* && "$info" == *'Authority=Developer ID Application:'* ]] || fail 'Build must be signed with the requested Developer ID team.'
    done
    ARGS+=(--sign "$INSTALLER_IDENTITY" --timestamp)
fi
PKG="$DIST/Roomtastic-$VERSION.pkg"
pkgbuild "${ARGS[@]}" "$PKG"
# This archive includes all recursive vendor source, build scripts, and license notices.
# Keep vendor Git metadata: vendor.py verifies every pinned checkout and submodule.
# Root repository metadata is not among the explicit input paths below.
tar --exclude=.build --exclude=build --exclude=dist --exclude=DerivedData \
    --exclude='Vendor/airplay-cli/bin' --exclude='libcodecs_patched.a' --exclude=.DS_Store \
    --exclude=xcuserdata --exclude='*.xcuserstate' \
    -czf "$DIST/Roomtastic-$VERSION-source.tar.gz" -C "$ROOT" \
    Package.swift Sources Tests Vendor scripts packaging LICENSES iOS .gitignore
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    [[ -n "${INSTALLER_IDENTITY:-}" ]] || fail 'Notarization requires Developer ID signing.'
    xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$PKG"
    xcrun stapler validate "$PKG"
fi
printf 'Package: %s\nCorresponding source: %s\n' "$PKG" "$DIST/Roomtastic-$VERSION-source.tar.gz"
echo 'Review LICENSES/license-map.json upstream permission ambiguities before public redistribution.'
