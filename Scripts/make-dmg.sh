#!/usr/bin/env bash
# Build "Meeting Assistant.app" and package it into a drag-to-install DMG using
# built-in hdiutil (no extra tooling required).
#
# The app is ad-hoc signed (no Developer ID), so on first launch macOS Gatekeeper
# will warn it's from an unidentified developer. Right-click the app → Open (once)
# to allow it; subsequent launches open normally.
#
# Usage: ./Scripts/make-dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Meeting Assistant"
VOL_NAME="Meeting Assistant"
APP_PATH="build/${APP_NAME}.app"
DMG_PATH="build/MeetingAssistant.dmg"

# 0. Eject any previously-mounted copy of this volume so a stale DMG copy can't
#    linger in /Volumes and get launched instead of the installed app.
if [[ -d "/Volumes/${VOL_NAME}" ]]; then
  echo "▸ Ejecting previously-mounted /Volumes/${VOL_NAME}…"
  hdiutil detach "/Volumes/${VOL_NAME}" >/dev/null 2>&1 || true
fi

# 1. Build the signed .app (release).
./Scripts/build-app.sh

# 2. Stage the bundle plus an /Applications symlink for drag-install.
echo "▸ Staging DMG contents…"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# 3. Build a compressed DMG.
echo "▸ Creating DMG…"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG_PATH" >/dev/null

SIZE="$(du -h "$DMG_PATH" | cut -f1)"
echo "✓ Built ${DMG_PATH} (${SIZE})"
echo "  Install: open the DMG and drag “${APP_NAME}” into Applications."
echo "  First launch (macOS 15/26): System Settings → Privacy & Security → Open Anyway."
echo "  First launch (macOS 14): right-click the app → Open."
