#!/bin/bash
set -euo pipefail

# Ventus daemon installer
# Requires: sudo, Swift, /usr/local/libexec (or will create)

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON_NAME="com.formm.ventus.daemon"
DAEMON_BIN="/usr/local/libexec/ventusd"
PLIST_FILE="/Library/LaunchDaemons/${DAEMON_NAME}.plist"
LOG_DIR="/Library/Logs/Ventus"
STARTUP_LOG="${LOG_DIR}/ventusd.log"

cd "$SCRIPT_DIR"
BUILT_BIN="${VENTUSD_BIN:-.build/release/ventusd}"
if [[ ! -f "$BUILT_BIN" ]]; then
    # Prefer a pre-built binary (build as the invoking user, not root);
    # fall back to building only if none exists.
    echo "[Ventus Install] No prebuilt binary; building release..."
    swift build -c release --product ventusd
fi
if [[ ! -f "$BUILT_BIN" ]]; then
    echo "[ERROR] Binary not found at $BUILT_BIN"
    exit 1
fi

echo "[Ventus Install] Creating log directory..."
mkdir -p "$LOG_DIR"

echo "[Ventus Install] Installing daemon binary..."
mkdir -p "/usr/local/libexec"
cp "$BUILT_BIN" "$DAEMON_BIN"
chmod 755 "$DAEMON_BIN"

echo "[Ventus Install] Writing LaunchDaemon plist..."
cat > "$PLIST_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${DAEMON_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${DAEMON_BIN}</string>
    </array>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>MachServices</key>
    <dict>
        <key>${DAEMON_NAME}</key>
        <true/>
    </dict>
    <key>StandardErrorPath</key>
    <string>${STARTUP_LOG}</string>
    <key>StandardOutputPath</key>
    <string>${STARTUP_LOG}</string>
    <key>UserName</key>
    <string>root</string>
    <key>GroupName</key>
    <string>wheel</string>
</dict>
</plist>
EOF

chmod 644 "$PLIST_FILE"

echo "[Ventus Install] Bootstrapping daemon with launchctl..."
launchctl bootstrap system "$PLIST_FILE" || {
    echo "[Ventus Install] launchctl bootstrap failed (daemon may already be running)"
}

echo "[Ventus Install] Verifying daemon is running..."
sleep 2
if launchctl list | grep -q "$DAEMON_NAME"; then
    echo "[Ventus Install] ✓ Daemon installed and running"
    echo "[Ventus Install] Log file: $STARTUP_LOG"
    exit 0
else
    echo "[Ventus Install] ⚠ Daemon may not be running; check logs at $STARTUP_LOG"
    exit 1
fi
