#!/usr/bin/env bash
# install.sh <dmg> [--quarantine]: quit the spike app, replace /Applications/RestoreySpike.app
# from the DMG (the agent keeps running, as with a real drag-install), then launch it.
set -euo pipefail
DMG="${1:?usage: install.sh <dmg> [--quarantine]}"
DEST="/Applications/RestoreySpike.app"
BUNDLE_ID="com.jaydenkerr.restorey.spike"

if [[ -e "$DEST" ]]; then
  id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)
  [[ "$id" == "$BUNDLE_ID" ]] || { echo "error: $DEST is not $BUNDLE_ID; refusing to replace it" >&2; exit 1; }
fi
osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
for _ in $(seq 1 40); do pgrep -f "$DEST/Contents/MacOS/RestoreySpike" >/dev/null || break; sleep 0.25; done

MNT=$(diskutil image attach --mountOptions nobrowse --readOnly "$DMG" 2>/dev/null | awk '/\/Volumes\//{sub(/.*\/Volumes\//,"/Volumes/"); print; exit}')
[[ -d "$MNT" ]] || MNT=$(hdiutil attach -nobrowse -readonly "$DMG" 2>/dev/null | awk -F'\t' '/\/Volumes\//{print $NF}')
trap 'hdiutil detach -quiet "$MNT" || true' EXIT
rm -rf "$DEST"
ditto "$MNT/RestoreySpike.app" "$DEST"
if [[ "${2:-}" == "--quarantine" ]]; then
  xattr -w com.apple.quarantine "0081;$(printf %x "$(date +%s)");Safari;" "$DEST"
fi
open "$DEST"
