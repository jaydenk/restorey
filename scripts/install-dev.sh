#!/usr/bin/env bash
# Build the signed Debug app, quit any running copy, and install RestoreyDev.app in /Applications.
# BUILD_NUMBER=n overrides CFBundleVersion (project.yml's CURRENT_PROJECT_VERSION), so an install looks like an
# update to the running agent: the app then restarts the agent even within the hourly repair limit.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="RestoreyDev"
BUNDLE_ID="com.jaydenkerr.restorey.dev"
DEST="/Applications/$APP_NAME.app"
DERIVED="build/DerivedData-signed"

[[ -f Config/Local.xcconfig ]] || { echo "error: copy Config/Local.example.xcconfig to Config/Local.xcconfig and set your team" >&2; exit 1; }

scripts/fetch-binaries.sh >/dev/null
xcodegen generate --quiet
mkdir -p build
if ! xcodebuild -project Restorey.xcodeproj -scheme Restorey -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$DERIVED" -allowProvisioningUpdates \
    ${BUILD_NUMBER:+CURRENT_PROJECT_VERSION="$BUILD_NUMBER"} build >build/install-dev.log 2>&1; then
  tail -40 build/install-dev.log >&2
  echo "error: build failed, full log in build/install-dev.log" >&2
  exit 1
fi

BUILT="$DERIVED/Build/Products/Debug/$APP_NAME.app"
scripts/verify-bundle.sh "$BUILT"

if [[ -e "$DEST" ]]; then
  id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)
  [[ "$id" == "$BUNDLE_ID" ]] || { echo "error: $DEST is not $BUNDLE_ID; refusing to replace it" >&2; exit 1; }
fi
osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
for _ in $(seq 1 40); do pgrep -f "$DEST/Contents/MacOS/$APP_NAME" >/dev/null || break; sleep 0.25; done

rm -rf "${DEST:?}"
ditto "$BUILT" "$DEST"
echo "Installed $DEST"
