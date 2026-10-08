#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
[[ "$EUID" -eq 0 ]] || { echo 'Run explicitly with sudo scripts/install.sh /path/to/Roomtastic.pkg' >&2; exit 1; }
[[ "$#" -eq 1 && -f "$1" ]] || { echo 'Specify one built Roomtastic installer package.' >&2; exit 2; }
/usr/sbin/installer -pkg "$1" -target /
echo 'Restart macOS to load the HAL driver. No CoreAudio process has been restarted by this script.'
echo 'After login, open /Applications/Roomtastic.app. The audio service is a separate user LaunchAgent.'
echo 'For AirPlay 2 shared timing explicitly run: sudo "/Library/Application Support/Roomtastic/enable-ptp.sh" enable'
