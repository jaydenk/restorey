#!/usr/bin/env bash
# The CI checks. GitHub runs this too, but without Config/Local.xcconfig, so the signed
# steps run only on a Mac that has a development team configured.
# Needs Xcode 27 and XcodeGen.
set -euo pipefail
cd "$(dirname "$0")/.."

step() { printf '\n==> %s\n' "$1"; }
log=build/xcodebuild.log
mkdir -p build

# Run xcodebuild quietly, keep the full log, and print the tail so failures stay readable.
build() {
  local derived="$1"; shift
  if ! xcodebuild -project Restorey.xcodeproj -scheme Restorey -configuration Debug \
      -destination 'platform=macOS' -derivedDataPath "$derived" "$@" build >"$log" 2>&1; then
    tail -40 "$log" >&2
    echo "error: build failed, full log in $log" >&2
    exit 1
  fi
  grep -E "BUILD SUCCEEDED" "$log"
}

step "Fetch vendored binaries (cached)"
scripts/fetch-binaries.sh

step "Test RestoreyCore"
swift test --package-path RestoreyCore

step "Generate the Xcode project"
xcodegen generate --quiet

step "Build Debug (unsigned)"
build build/DerivedData-unsigned CODE_SIGNING_ALLOWED=NO
scripts/verify-bundle.sh build/DerivedData-unsigned/Build/Products/Debug/RestoreyDev.app --skip-signature

if [[ -f Config/Local.xcconfig ]]; then
  step "Build Debug (signed)"
  build build/DerivedData-signed -allowProvisioningUpdates
  scripts/verify-bundle.sh build/DerivedData-signed/Build/Products/Debug/RestoreyDev.app

  # The hosted app tests arrive with Task 11.
else
  step "Skipping signed build: Config/Local.xcconfig not found"
fi

step "All CI checks passed"
