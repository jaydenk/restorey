#!/usr/bin/env bash
# make-dmg.sh <app> <dmg>: a compressed DMG holding the app and an /Applications link.
set -euo pipefail
APP="$1"; DMG="$2"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Restorey Spike" -srcfolder "$STAGE" -format UDZO "$DMG"
