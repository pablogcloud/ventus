#!/bin/bash
set -euo pipefail

# Ventus.app Build Script
# Builds swift build -c release, assembles the bundle, ad-hoc signs, outputs to build/Ventus.app

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
APP_DIR="${BUILD_DIR}/Ventus.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
FONTS_DIR="${RESOURCES_DIR}/Fonts"
SWIFT_CACHE_DIR="${BUILD_DIR}/swift-cache"

mkdir -p "${SWIFT_CACHE_DIR}/clang"
mkdir -p "${SWIFT_CACHE_DIR}/swiftpm"
export CLANG_MODULE_CACHE_PATH="${SWIFT_CACHE_DIR}/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFT_CACHE_DIR}/swiftpm"

# Clean up old app if it exists
rm -rf "${APP_DIR}"

echo "[make-app.sh] Building VentusApp binary..."
cd "${PROJECT_DIR}"
swift build -c release --disable-sandbox

# Locate the built binary
BINARY_PATH="${PROJECT_DIR}/.build/release/VentusApp"
if [ ! -f "${BINARY_PATH}" ]; then
    echo "Error: Binary not found at ${BINARY_PATH}"
    exit 1
fi

echo "[make-app.sh] Creating app bundle structure..."
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"
mkdir -p "${FONTS_DIR}"

# Copy binary
cp "${BINARY_PATH}" "${MACOS_DIR}/VentusApp"
chmod +x "${MACOS_DIR}/VentusApp"

# Bundle the brand fonts for both ATS registration and VentusTheme's launch-time
# CoreText registration. Keeping a plain Fonts directory also makes the final
# app bundle easy to inspect.
cp "${PROJECT_DIR}/Sources/VentusApp/Resources/Fonts/Sora.ttf" "${FONTS_DIR}/"
cp "${PROJECT_DIR}/Sources/VentusApp/Resources/Fonts/InstrumentSans.ttf" "${FONTS_DIR}/"

# Create Info.plist
cat > "${CONTENTS_DIR}/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>VentusApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.formm.ventus.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Ventus</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>ATSApplicationFontsPath</key>
    <string>Fonts</string>
    <key>NSRequiresIPhoneOS</key>
    <false/>
</dict>
</plist>
EOF

echo "[make-app.sh] Ad-hoc code signing..."
codesign --force --deep -s - "${APP_DIR}"

echo "[make-app.sh] Created ${APP_DIR}"
ls -lh "${APP_DIR}"

echo "[make-app.sh] Done."
