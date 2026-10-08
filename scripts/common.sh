#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export MACOSX_DEPLOYMENT_TARGET=14.0
BUILD="$ROOT/build"
DIST="$ROOT/dist"
fail() { printf '%s\n' "$*" >&2; exit 1; }
require_macos() {
    [[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || fail 'Requires an Apple Silicon Mac.'
    [[ -d "$DEVELOPER_DIR" ]] || fail 'Install Xcode and set DEVELOPER_DIR.'
    export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
}
