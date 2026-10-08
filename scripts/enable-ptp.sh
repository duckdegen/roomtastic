#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
[[ "$EUID" -eq 0 ]] || { echo 'Run explicitly as administrator (sudo) to enable or disable shared PTP.' >&2; exit 1; }
SUPPORT='/Library/Application Support/Roomtastic'
PLIST=/Library/LaunchDaemons/org.roomtastic.ptp.plist
case "${1:-}" in
    enable)
        [[ -x "$SUPPORT/Helpers/cliairplay" ]] || { echo 'Install Roomtastic first.' >&2; exit 1; }
        # Never execute a user-writable binary as root.
        for path in "$SUPPORT" "$SUPPORT/Helpers" "$SUPPORT/Helpers/cliairplay" "$SUPPORT/org.roomtastic.ptp.plist"; do
            [[ ! -L "$path" && "$(stat -f %u "$path")" == 0 ]] || { echo "Unsafe ownership: $path" >&2; exit 1; }
            mode="$(stat -f %Lp "$path")"
            (( (8#$mode & 8#022) == 0 )) || { echo "Unsafe permissions: $path" >&2; exit 1; }
        done
        [[ ! -L "$PLIST" ]] || { echo "Refusing symlink: $PLIST" >&2; exit 1; }
        if [[ -e "$PLIST" ]]; then
            [[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$PLIST")" == org.roomtastic.ptp ]] || exit 1
            if launchctl print system/org.roomtastic.ptp >/dev/null 2>&1; then
                launchctl bootout system/org.roomtastic.ptp
            fi
        fi
        install -o root -g wheel -m 644 "$SUPPORT/org.roomtastic.ptp.plist" "$PLIST"
        launchctl bootstrap system "$PLIST"
        echo 'PTP clock enabled. Only this timing process runs as root (UDP 319/320); audio remains in the user agent.'
        ;;
    disable)
        if launchctl print system/org.roomtastic.ptp >/dev/null 2>&1; then
            launchctl bootout system/org.roomtastic.ptp
        fi
        [[ ! -L "$PLIST" ]] || exit 1
        rm -f "$PLIST"
        ;;
    *) echo 'Usage: enable-ptp.sh enable|disable' >&2; exit 2 ;;
esac
