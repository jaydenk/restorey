#!/usr/bin/env bash
# release.sh [--version X.Y.Z]: Developer ID-signed, notarised, stapled DMG in build/release/.
# Adapted from ../scrap/scripts/release.sh: the Xcode account manages the Developer ID
# certificate, profiles and notary upload, so no local certificate or notarytool profile.
# This UPLOADS the app to Apple's notary service.
set -euo pipefail
exec 3>&1 1>&2
cd "$(dirname "$0")/.."

VERSION="0.1.0"
if [[ "${1:-}" == "--version" ]]; then VERSION="${2:?--version needs a value}"; fi
BUILD_DIR="build/release-$VERSION"
ARCHIVE="$BUILD_DIR/RestoreySpike.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/RestoreySpike.app"
NOTARY_TIMEOUT_SECONDS="${NOTARY_TIMEOUT_SECONDS:-3600}"

rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"
scripts/fetch-restic.sh >/dev/null
mkdir -p build/generated
xcodegen generate --quiet
xcodebuild -project RestoreySpike.xcodeproj -scheme RestoreySpike -configuration Release \
  -archivePath "$ARCHIVE" -allowProvisioningUpdates \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION" archive >"$BUILD_DIR/archive.log" 2>&1 \
  || { grep -E "error:" "$BUILD_DIR/archive.log" | head -20; echo "archive failed: $BUILD_DIR/archive.log"; exit 1; }

xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist ExportOptions.plist \
  -exportPath "$EXPORT_DIR" -allowProvisioningUpdates >"$BUILD_DIR/export.log" 2>&1 \
  || { tail -30 "$BUILD_DIR/export.log"; echo "export/upload failed"; exit 1; }

DEADLINE=$(( SECONDS + NOTARY_TIMEOUT_SECONDS ))
until xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" >"$BUILD_DIR/notarized.log" 2>&1; do
  grep -q "is processing and not ready for distribution" "$BUILD_DIR/notarized.log" || { cat "$BUILD_DIR/notarized.log"; echo "notarisation failed"; exit 1; }
  (( SECONDS < DEADLINE )) || { echo "gave up waiting for notarisation"; exit 1; }
  echo "notarisation still processing; checking again in 30 s"; sleep 30
done

xcrun stapler validate "$APP"
SPCTL=$(spctl -a -t exec -vv "$APP" 2>&1 || true); echo "$SPCTL"
[[ "$SPCTL" == *"source=Notarized Developer ID"* ]] || { echo "Gatekeeper did not accept the app as notarised Developer ID"; exit 1; }
scripts/verify-bundle.sh "$APP"
DMG="$BUILD_DIR/RestoreySpike-$VERSION.dmg"
scripts/make-dmg.sh "$APP" "$DMG"
echo "$DMG" >&3
