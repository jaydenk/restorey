#!/usr/bin/env bash
# verify-bundle.sh <app>: structural checks the spike depends on. Prints designated requirements.
set -euo pipefail
APP="${1:?usage: verify-bundle.sh <app>}"
AGENT="$APP/Contents/Helpers/RestoreySpikeAgent.app"
RESTIC="$APP/Contents/Helpers/restic"
PLIST="$APP/Contents/Library/LaunchAgents/com.jaydenkerr.restorey.spike.agent.plist"
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -d "$AGENT" ]] || fail "agent app missing"
[[ -x "$RESTIC" ]] || fail "restic missing"
[[ -f "$PLIST" ]] || fail "launch agent plist missing"
prog=$(/usr/libexec/PlistBuddy -c "Print :BundleProgram" "$PLIST")
[[ -x "$APP/$prog" ]] || fail "BundleProgram $prog is not an executable in the bundle"
# Capture before matching: `cmd | grep -q` under pipefail fails when grep exits early (SIGPIPE).
rv=$("$RESTIC" version); [[ "$rv" == "restic 0.19.1 "* ]] || fail "restic is not 0.19.1 ($rv)"

codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2

team_of() { codesign -dv "$1" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}'; }
app_team=$(team_of "$APP")
[[ "$app_team" =~ ^[A-Z0-9]{10}$ ]] || fail "app not team-signed (TeamIdentifier=$app_team)"
for part in "$AGENT" "$RESTIC"; do
  [[ "$(team_of "$part")" == "$app_team" ]] || fail "$(basename "$part") team differs from app"
  sig=$(codesign -dv "$part" 2>&1 || true)
  [[ "$sig" == *"(runtime)"* ]] || fail "$(basename "$part") lacks hardened runtime"
done
for part in "$APP" "$AGENT"; do
  [[ -f "$part/Contents/embedded.provisionprofile" ]] || fail "$(basename "$part") has no embedded.provisionprofile"
  ent=$(codesign -d --entitlements - --xml "$part" 2>/dev/null || true)
  [[ "$ent" == *"keychain-access-groups"*"com.jaydenkerr.restorey.spike"* ]] \
    || fail "$(basename "$part") lacks the keychain access group entitlement"
done

echo "team: $app_team"
for part in "$APP" "$AGENT" "$RESTIC"; do
  echo "--- $(basename "$part")"
  codesign -dv "$part" 2>&1 | grep -E "^(Identifier|Authority|TeamIdentifier)=" | head -3
  codesign -d -r- "$part" 2>&1 | grep designated
done
echo "PASS"
