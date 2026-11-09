#!/usr/bin/env bash
# build.sh [--version X.Y.Z]: development-signed build, bundle checks, DMG in build/.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.0.1"
if [[ "${1:-}" == "--version" ]]; then VERSION="${2:?--version needs a value}"; fi
[[ -f Config/Local.xcconfig ]] || { echo "error: copy Config/Local.example.xcconfig to Config/Local.xcconfig" >&2; exit 1; }

scripts/fetch-restic.sh >/dev/null
mkdir -p build/generated
xcodegen generate --quiet
LOG="build/xcodebuild-$VERSION.log"
if ! xcodebuild -project RestoreySpike.xcodeproj -scheme RestoreySpike -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath build/DerivedData -allowProvisioningUpdates \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION" build >"$LOG" 2>&1; then
  { grep -E "error:|warning: .*(sign|profile)|^(cp|codesign): " "$LOG" || tail -20 "$LOG"; } | head -30 >&2
  echo "error: build failed; full log in $LOG" >&2
  exit 1
fi
APP="build/DerivedData/Build/Products/Debug/RestoreySpike.app"
scripts/verify-bundle.sh "$APP"
DMG="build/RestoreySpike-$VERSION.dmg"
scripts/make-dmg.sh "$APP" "$DMG"
echo "$DMG"
