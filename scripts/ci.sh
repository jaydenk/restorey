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
# build <configuration> <derived data> [xcodebuild settings…]
build() {
  local configuration="$1" derived="$2"; shift 2
  if ! xcodebuild -project Restorey.xcodeproj -scheme Restorey -configuration "$configuration" \
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

# Deadlines under GCD starvation, on their own: these park every constrained global-queue thread in the test process,
# so they would stall other tests beside them (README: "Building from source"). Skipped in the run above.
step "Test deadlines under GCD starvation (alone)"
starvation_log=build/starvation-tests.log
RESTOREY_STARVATION_TESTS=1 swift test --package-path RestoreyCore --skip-build --no-parallel \
  --filter GlobalQueueStarvationTests 2>&1 | tee "$starvation_log"
# A skipped suite or a filter that matches nothing would also exit 0: require both tests to have passed.
if [[ $(grep -cE "Test [A-Za-z]+WhileGlobalQueuesAreStarved\(\) passed" "$starvation_log") -ne 2 ]]; then
  echo "error: the two GCD starvation tests didn't both run and pass (log: $starvation_log)" >&2
  exit 1
fi

step "Generate the Xcode project"
xcodegen generate --quiet

# verify-bundle.sh also checks the Developer window: in every Debug build (all its types found, the positive
# control) and absent from every Release build, so a Release that compiled it in fails here.
step "Build Debug (unsigned)"
build Debug build/DerivedData-unsigned CODE_SIGNING_ALLOWED=NO
scripts/verify-bundle.sh build/DerivedData-unsigned/Build/Products/Debug/RestoreyDev.app --skip-signature

# The release identity and settings are built on every run too, so a Release-only break (a
# configuration-specific name, a setting) shows up before a release is cut. Signing it is Plan 3's.
step "Build Release (unsigned)"
build Release build/DerivedData-release-unsigned CODE_SIGNING_ALLOWED=NO
scripts/verify-bundle.sh build/DerivedData-release-unsigned/Build/Products/Release/Restorey.app --skip-signature

if [[ -f Config/Local.xcconfig ]]; then
  step "Build Debug (signed)"
  build Debug build/DerivedData-signed -allowProvisioningUpdates
  scripts/verify-bundle.sh build/DerivedData-signed/Build/Products/Debug/RestoreyDev.app

  # The keychain tests need the agent's keychain-access-groups entitlement, so they run inside the
  # signed agent (README: "Why the keychain tests need a signed host"). The agent is launched, and
  # macOS blocks a launch from ~/Documents (and Desktop, Downloads, iCloud Drive) on a privacy
  # prompt, so this build lives under ~/Library/Caches instead of build/.
  # The host is the agent's own executable, which takes its test-host branch and runs none of its start-up
  # (Ruling R66). The tests must never reach the real identity's files or the installed build: the
  # helper's negative control against the running agent is scripts/check-helper-refusal.sh, a live check.
  step "Hosted tests (signed agent as test host)"
  if grep -nE 'logsDirectory|applicationSupportDirectory|cachesDirectory|Library/(Logs|Application Support)|/Applications/' \
      AgentHostedTests/*.swift; then
    echo "error: a hosted test refers to the real identity's folders or the installed app (above)" >&2
    exit 1
  fi
  hosted_derived="${RESTOREY_HOSTED_DERIVED_DATA:-$HOME/Library/Caches/restorey-ci/DerivedData-hosted}"
  mkdir -p "$hosted_derived"
  hosted_log=build/xcodebuild-hosted.log
  if ! xcodebuild test -project Restorey.xcodeproj -scheme AgentHostedTests -configuration Debug \
      -destination 'platform=macOS' -derivedDataPath "$hosted_derived" -allowProvisioningUpdates \
      >"$hosted_log" 2>&1; then
    tail -40 "$hosted_log" >&2
    echo "error: hosted tests failed, full log in $hosted_log" >&2
    exit 1
  fi
  grep -E "^.{1,3} Test .* (passed|failed)|TEST SUCCEEDED" "$hosted_log"
  # TEST SUCCEEDED alone is also what a run that executed nothing reports.
  if ! grep -E "Test run with [1-9][0-9]* tests?" "$hosted_log"; then
    echo "error: the hosted run executed no tests, see $hosted_log" >&2
    exit 1
  fi
else
  step "Skipping signed build: Config/Local.xcconfig not found"
  echo "hosted keychain tests skipped: no signing (Config/Local.xcconfig not found)"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::warning::hosted keychain tests skipped: no signing"
  fi
fi

step "All CI checks passed"
