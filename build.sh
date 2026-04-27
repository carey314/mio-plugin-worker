#!/bin/bash
# Build the 摸鱼侠 plugin as a .bundle for Mio Island.
#
# Usage:
#   ./build.sh             # produce build/worker.bundle + build/worker.zip
#   ./build.sh install     # also copy bundle to ~/.config/codeisland/plugins/

set -e
set -o pipefail

PLUGIN_NAME="worker"
MODULE_NAME="WorkerPlugin"
BUNDLE_NAME="${PLUGIN_NAME}.bundle"
BUILD_DIR="build"

SOURCES=$(find Sources -name "*.swift" -type f)
SOURCE_COUNT=$(echo "$SOURCES" | wc -l | tr -d ' ')

echo "Building ${PLUGIN_NAME} plugin (${SOURCE_COUNT} swift files)..."

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS"

# arm64-only is fine for v0.1 — Mio Island host requires macOS 15+
# which means Apple Silicon dominant.
swiftc \
    -emit-library \
    -module-name "${MODULE_NAME}" \
    -target arm64-apple-macos15.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    -O \
    -o "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS/${MODULE_NAME}" \
    ${SOURCES}

cp Info.plist "${BUILD_DIR}/${BUNDLE_NAME}/Contents/"

if [ -d "Resources" ] && [ "$(ls -A Resources 2>/dev/null)" ]; then
  mkdir -p "${BUILD_DIR}/${BUNDLE_NAME}/Contents/Resources"
  cp -R Resources/* "${BUILD_DIR}/${BUNDLE_NAME}/Contents/Resources/"
fi

# Ad-hoc sign the whole bundle.
codesign --force --deep --sign - "${BUILD_DIR}/${BUNDLE_NAME}"

echo "Built ${BUILD_DIR}/${BUNDLE_NAME}"

# zip for marketplace upload.
cd "${BUILD_DIR}"
rm -f "${PLUGIN_NAME}.zip"
zip -rq "${PLUGIN_NAME}.zip" "${BUNDLE_NAME}"
cd ..
echo "Created ${BUILD_DIR}/${PLUGIN_NAME}.zip"

if [ "${1:-}" = "install" ]; then
    PLUGIN_DIR="${HOME}/.config/codeisland/plugins"
    mkdir -p "${PLUGIN_DIR}"
    rm -rf "${PLUGIN_DIR}/${BUNDLE_NAME}"
    cp -R "${BUILD_DIR}/${BUNDLE_NAME}" "${PLUGIN_DIR}/"
    echo "Installed to ${PLUGIN_DIR}/${BUNDLE_NAME}"
    echo "  Restart Mio Island (Cmd+Q + reopen) to load the new build."
else
    echo ""
    echo "Install locally:"
    echo "  ./build.sh install"
fi
