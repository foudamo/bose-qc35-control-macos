#!/bin/bash
# Builds "QC35 Control.app" with the Xcode Command Line Tools.
#   ./build.sh            build into ./build
#   ./build.sh --install  build, copy to /Applications and launch
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="QC35 Control"
EXEC="QC35Control"
ARCH="$(uname -m)"          # arm64 on Apple silicon, x86_64 on Intel
MIN_OS="14.0"
APP="build/${APP_NAME}.app"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Command Line Tools first:  xcode-select --install"
  exit 1
fi

rm -rf build
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

echo "Compiling for ${ARCH}…"
swiftc -O -swift-version 5 \
  -target "${ARCH}-apple-macos${MIN_OS}" \
  -framework AppKit -framework IOBluetooth -framework ServiceManagement \
  Sources/*.swift \
  -o "${APP}/Contents/MacOS/${EXEC}"

cp Info.plist "${APP}/Contents/Info.plist"

# Ad-hoc signature so macOS will grant the Bluetooth permission.
codesign --force --sign - "${APP}"

echo "Built: ${APP}"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x "${EXEC}" 2>/dev/null || true
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "${APP}" /Applications/
  open "/Applications/${APP_NAME}.app"
  echo "Installed to /Applications and launched — look for the headphones icon in the menu bar."
fi
