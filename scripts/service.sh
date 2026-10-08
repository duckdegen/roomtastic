#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
[[ "$EUID" -ne 0 ]] || { echo 'Run as the signed-in audio user, not root.' >&2; exit 1; }
PLIST=/Library/LaunchAgents/org.roomtastic.service.plist
DOMAIN="gui/$(id -u)"
case "${1:-}" in
    start) launchctl bootstrap "$DOMAIN" "$PLIST" ;;
    stop) launchctl bootout "$DOMAIN/org.roomtastic.service" ;;
    restart)
        launchctl bootout "$DOMAIN/org.roomtastic.service" 2>/dev/null || true
        launchctl bootstrap "$DOMAIN" "$PLIST"
        ;;
    status) launchctl print "$DOMAIN/org.roomtastic.service" ;;
    *) echo 'Usage: service.sh start|stop|restart|status' >&2; exit 2 ;;
esac
