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

# Choose the signing identity. Preference order:
#   1. $CODESIGN_IDENTITY override (used by CI, with optional $CODESIGN_KEYCHAIN)
#   2. our stable self-signed cert in the dedicated keychain, if set up (so TCC
#      permission grants persist across rebuilds — run ./Scripts/setup-signing.sh)
#   3. ad-hoc (works, but Screen Recording / Accessibility grants reset each build)
SIGN_KEYCHAIN="$HOME/Library/Keychains/meeting-assistant-signing.keychain-db"
SIGN_PW_FILE="$HOME/.config/meeting-assistant/signing-keychain-password"
IDENTITY="-"        # ad-hoc fallback
KEYCHAIN_ARGS=()

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  IDENTITY="$CODESIGN_IDENTITY"
  [[ -n "${CODESIGN_KEYCHAIN:-}" ]] && KEYCHAIN_ARGS=(--keychain "$CODESIGN_KEYCHAIN")
elif [[ -f "$SIGN_KEYCHAIN" && -f "$SIGN_PW_FILE" ]]; then
  security unlock-keychain -p "$(cat "$SIGN_PW_FILE")" "$SIGN_KEYCHAIN" 2>/dev/null || true
  # Resolve the cert's SHA-1 hash; signing by hash works even though a self-signed
  # cert is "untrusted" (and thus hidden from the default identity search).
  HASH="$(security find-identity -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null \
            | awk '/Meeting Assistant Self-Signed/ {print $2; exit}')"
  if [[ -n "$HASH" ]]; then
    IDENTITY="$HASH"
    KEYCHAIN_ARGS=(--keychain "$SIGN_KEYCHAIN")
  fi
fi

if [[ "$IDENTITY" == "-" ]]; then
  echo "▸ Ad-hoc code signing (no stable identity — Screen Recording / Accessibility"
  echo "  grants reset on each build; run ./Scripts/setup-signing.sh once to fix)…"
else
  echo "▸ Code signing with stable self-signed identity ($IDENTITY)…"
fi
codesign --force --deep \
  --sign "$IDENTITY" \
  "${KEYCHAIN_ARGS[@]}" \
  --entitlements Resources/MeetingAssistant.entitlements \
  "$APP_DIR"

echo "✓ Built ${APP_DIR}"

if [[ "${1:-}" == "--run" ]]; then
  echo "▸ Launching…"
  open "$APP_DIR"
fi
