#!/usr/bin/env bash
# Download the pinned upstream restic release and verify it against the release's SHA256SUMS.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.19.1"
ASSET="restic_${VERSION}_darwin_arm64.bz2"
BASE_URL="https://github.com/restic/restic/releases/download/v${VERSION}"
VENDOR="vendor"

mkdir -p "$VENDOR"
# Icon for the notification/Login Items naming checks; copied from macOS, never committed.
cp -f "/System/Applications/Utilities/Disk Utility.app/Contents/Resources/AppIcon.icns" "$VENDOR/SpikeIcon.icns"
if [[ -x "$VENDOR/restic" ]] && [[ "$("$VENDOR/restic" version)" == "restic ${VERSION} "* ]]; then
  exit 0
fi

curl -fsSL -o "$VENDOR/$ASSET" "$BASE_URL/$ASSET"
curl -fsSL -o "$VENDOR/SHA256SUMS" "$BASE_URL/SHA256SUMS"
expected=$(awk -v a="$ASSET" '$2 == a {print $1}' "$VENDOR/SHA256SUMS")
actual=$(shasum -a 256 "$VENDOR/$ASSET" | awk '{print $1}')
if [[ -z "$expected" || "$expected" != "$actual" ]]; then
  echo "error: checksum mismatch for $ASSET (expected '$expected', got '$actual')" >&2
  rm -f "$VENDOR/$ASSET"
  exit 1
fi
bunzip2 -c "$VENDOR/$ASSET" > "$VENDOR/restic"
chmod +x "$VENDOR/restic"
"$VENDOR/restic" version
