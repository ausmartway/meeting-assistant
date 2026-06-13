#!/usr/bin/env bash
# Build and install Meeting Assistant.app into /Applications in place — quitting
# any running instance and removing the previous copy first, so you never end up
# with duplicate copies. Use this instead of the drag-from-DMG flow for dev
# rebuilds.
#
# Usage:
#   ./Scripts/install.sh            # build, install, leave it
#   ./Scripts/install.sh --run      # build, install, then launch
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Meeting Assistant"
BUNDLE_ID="com.meetingassistant.app"
SRC="build/${APP_NAME}.app"
DEST="/Applications/${APP_NAME}.app"

# 1. Build the fresh signed bundle.
./Scripts/build-app.sh

# 2. Quit any running instance so we can replace it cleanly.
if pgrep -x "MeetingAssistant" >/dev/null 2>&1; then
  echo "▸ Quitting running instance…"
  osascript -e "quit app id \"${BUNDLE_ID}\"" 2>/dev/null || pkill -x "MeetingAssistant" || true
  sleep 1
fi

# 3. Remove the old copy, then install the new one in the same location.
echo "▸ Installing to ${DEST}…"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

# 4. Refresh LaunchServices so the OS uses the /Applications copy, not any stale
#    copy that may have been registered from a mounted DMG.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DEST" >/dev/null 2>&1 || true

echo "✓ Installed ${DEST}"

# 5. Report any OTHER copies LaunchServices knows about, so duplicates can't hide.
echo "▸ Known copies of ${BUNDLE_ID}:"
mdfind "kMDItemCFBundleIdentifier == '${BUNDLE_ID}'" 2>/dev/null | sed 's/^/   /' || true

if [[ "${1:-}" == "--run" ]]; then
  open "$DEST"
fi
