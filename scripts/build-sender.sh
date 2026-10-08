#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
source "$(dirname "$0")/common.sh"
require_macos
python3 "$ROOT/scripts/vendor.py" --verify
# Pinned upstream provides the pinned dependency static archives and their source.
make -C "$ROOT/Vendor/airplay-cli" -j "$(sysctl -n hw.logicalcpu)" \
    HOST=macos PLATFORM=arm64 STATIC=1 CC="$(xcrun -f clang)" CXX="$(xcrun -f clang++)" \
    VERSION=431c5c582eef9307c4e39c50a0ea65e970bc1128 \
    EXTRA_CFLAGS='-arch arm64 -mmacosx-version-min=14.0' \
    EXTRA_LDFLAGS='-arch arm64 -mmacosx-version-min=14.0'
mkdir -p "$BUILD/helpers"
install -m 755 "$ROOT/Vendor/airplay-cli/bin/cliairplay-macos-arm64" "$BUILD/helpers/cliairplay"
