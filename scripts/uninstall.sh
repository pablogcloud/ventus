#!/bin/bash
set -euo pipefail

# Ventus daemon uninstaller
# Requires: sudo
# FIX #8: Correct order — bootout daemon FIRST, then restore and verify

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo)"
    exit 1
fi

DAEMON_NAME="com.formm.ventus.daemon"
DAEMON_BIN="/usr/local/libexec/ventusd"
PLIST_FILE="/Library/LaunchDaemons/${DAEMON_NAME}.plist"
LOG_DIR="/Library/Logs/Ventus"
CONFIG_DIR="/Library/Application Support/Ventus"

echo "[Ventus Uninstall] Stopping daemon..."
launchctl bootout system "$PLIST_FILE" 2>/dev/null || true

# Verify the daemon is actually gone before touching anything else. A masked
# bootout failure that left the control loop running could re-force fans right
# after we restore them, then we'd delete the only recovery binary.
if launchctl print system/"$DAEMON_NAME" >/dev/null 2>&1; then
    echo "[Ventus Uninstall] ERROR: daemon still registered after bootout — aborting."
    echo "  Fans have NOT been touched and the binary is preserved. Investigate:"
    echo "    sudo launchctl print system/$DAEMON_NAME"
    exit 1
fi
if pgrep -xf "$DAEMON_BIN" >/dev/null 2>&1; then
    echo "[Ventus Uninstall] ERROR: ventusd process still alive after bootout — aborting."
    exit 1
fi

echo "[Ventus Uninstall] Restoring fans to auto mode..."
# FIX #8: --restore-auto must exit nonzero on failure, so check its exit code
if ! "$DAEMON_BIN" --restore-auto 2>/dev/null; then
    echo "[Ventus Uninstall] ERROR: Failed to restore fans to auto mode — verify SMC access and try again"
    exit 1
fi

echo "[Ventus Uninstall] Removing LaunchDaemon plist..."
rm -f "$PLIST_FILE"

echo "[Ventus Uninstall] Removing daemon binary..."
rm -f "$DAEMON_BIN"

echo "[Ventus Uninstall] Removing log directory..."
rm -rf "$LOG_DIR"

echo "[Ventus Uninstall] Note: Configuration directory preserved at $CONFIG_DIR"
echo "[Ventus Uninstall] To remove it manually: rm -rf '$CONFIG_DIR'"

echo "[Ventus Uninstall] ✓ Daemon uninstalled successfully"
