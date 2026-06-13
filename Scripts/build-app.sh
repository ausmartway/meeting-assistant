#!/usr/bin/env bash
# Build a runnable, ad-hoc-signed Meeting Assistant.app from the SwiftPM
# executable. Works under Command Line Tools (no full Xcode required).
#
# An ad-hoc signature + the Info.plist usage strings are enough for macOS to
# show the TCC permission prompts; the user grants them on first run (and may
# need to add the app manually under System Settings → Privacy & Security for
# unsigned/dev builds).
#
# Usage:
#   ./Scripts/build-app.sh           # build the .app
#   ./Scripts/build-app.sh --run     # build, then launch it
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="release"
APP_NAME="Meeting Assistant"
BUNDLE_ID="com.meetingassistant.app"
EXE_NAME="MeetingAssistant"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
APP_DIR="build/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RES_DIR="${APP_DIR}/Contents/Resources"

echo "▸ Assembling bundle…"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"
cp "${BIN_PATH}/${EXE_NAME}" "${MACOS_DIR}/${EXE_NAME}"
cp Resources/Info.plist "${APP_DIR}/Contents/Info.plist"

echo "▸ Ad-hoc code signing…"
codesign --force --deep \
  --sign - \
  --entitlements Resources/MeetingAssistant.entitlements \
  "$APP_DIR"

echo "✓ Built ${APP_DIR}"

if [[ "${1:-}" == "--run" ]]; then
  echo "▸ Launching…"
  open "$APP_DIR"
fi
