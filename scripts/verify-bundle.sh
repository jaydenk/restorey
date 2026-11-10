#!/usr/bin/env bash
# verify-bundle.sh <app> [--skip-signature]
# Structural checks on a built Restorey bundle. --skip-signature is for unsigned CI builds:
# it still checks layout, identifiers and the launchd plist, but not code signatures.
set -euo pipefail

APP=""
CHECK_SIGNATURE=1
for arg in "$@"; do
  case "$arg" in
    --skip-signature) CHECK_SIGNATURE=0 ;;
    -*) echo "usage: verify-bundle.sh <app> [--skip-signature]" >&2; exit 2 ;;
    *) APP="$arg" ;;
  esac
done
[[ -n "$APP" ]] || { echo "usage: verify-bundle.sh <app> [--skip-signature]" >&2; exit 2; }
APP="${APP%/}"

fail() { echo "FAIL: $*" >&2; exit 1; }
plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }
no_space() { [[ "$2" != *" "* ]] || fail "$1 contains a space: '$2'"; }

[[ -d "$APP" ]] || fail "$APP is not a directory"
INFO="$APP/Contents/Info.plist"
[[ -f "$INFO" ]] || fail "app Info.plist missing"

# Identity: every expected value is derived from the root ID, which must be one of the two known.
root=$(plist_get "$INFO" RestoreyRootID)
case "$root" in
  com.jaydenkerr.restorey)     app_name="Restorey";    agent_name="RestoreyAgent";    logs="Restorey" ;;
  com.jaydenkerr.restorey.dev) app_name="RestoreyDev"; agent_name="RestoreyDevAgent"; logs="Restorey-Dev" ;;
  *) fail "RestoreyRootID is '$root', expected com.jaydenkerr.restorey[.dev]" ;;
esac
label="$root.agent"
helper="$label.helper"

[[ "$(basename "$APP")" == "$app_name.app" ]] || fail "app is named $(basename "$APP"), expected $app_name.app"
[[ "$(plist_get "$INFO" CFBundleIdentifier)" == "$root" ]] || fail "app CFBundleIdentifier differs from $root"
[[ "$(plist_get "$INFO" RestoreyAgentLabel)" == "$label" ]] || fail "RestoreyAgentLabel differs from $label"
[[ "$(plist_get "$INFO" RestoreyLogsName)" == "$logs" ]] || fail "RestoreyLogsName differs from $logs"
group=$(plist_get "$INFO" RestoreyKeychainGroup)
[[ "$group" == *"$root" && "$group" != *'$('* ]] || fail "RestoreyKeychainGroup '$group' does not end in $root or is unexpanded"

AGENT="$APP/Contents/Helpers/$agent_name.app"
AGENT_EXE="$AGENT/Contents/MacOS/$agent_name"
RESTIC="$APP/Contents/Helpers/restic"
PLIST="$APP/Contents/Library/LaunchAgents/$label.plist"

[[ -d "$AGENT" ]] || fail "agent app missing at $AGENT"
[[ -x "$AGENT_EXE" ]] || fail "agent executable missing at $AGENT_EXE"
[[ -x "$RESTIC" ]] || fail "restic missing or not executable at $RESTIC"
[[ -f "$PLIST" ]] || fail "launch agent plist missing at $PLIST"

# launchd cannot reliably handle spaces in these paths (spike finding).
no_space "agent executable path" "Contents/Helpers/$agent_name.app/Contents/MacOS/$agent_name"
no_space "restic path" "Contents/Helpers/restic"
no_space "launch agent plist name" "$(basename "$PLIST")"

[[ "$(plist_get "$AGENT/Contents/Info.plist" CFBundleIdentifier)" == "$label" ]] || fail "agent CFBundleIdentifier differs from $label"

# Launch agent plist.
[[ "$(plist_get "$PLIST" Label)" == "$label" ]] || fail "plist Label differs from $label"
prog=$(plist_get "$PLIST" BundleProgram)
[[ "$prog" == "Contents/Helpers/$agent_name.app/Contents/MacOS/$agent_name" ]] || fail "BundleProgram is '$prog'"
[[ -x "$APP/$prog" ]] || fail "BundleProgram $prog is not an executable in the bundle"
[[ "$(plist_get "$PLIST" ProcessType)" == "Standard" ]] || fail "ProcessType is '$(plist_get "$PLIST" ProcessType)', must be Standard"
[[ "$(plist_get "$PLIST" KeepAlive)" == "true" ]] || fail "KeepAlive is not true"
[[ "$(plist_get "$PLIST" RunAtLoad)" == "true" ]] || fail "RunAtLoad is not true"
for service in "$label" "$helper"; do
  [[ "$(plist_get "$PLIST" "MachServices:$service")" == "true" ]] || fail "MachServices lacks $service"
done

# Capture before matching: `cmd | grep -q` under pipefail fails when grep exits early (SIGPIPE).
rv=$("$RESTIC" version); [[ "$rv" == "restic 0.19.1 "* ]] || fail "restic is not 0.19.1 ($rv)"

if [[ $CHECK_SIGNATURE -eq 0 ]]; then
  echo "verify-bundle: OK (signature checks skipped) $APP"
  exit 0
fi

codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2

team_of() { codesign -dv "$1" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}'; }
app_team=$(team_of "$APP")
[[ "$app_team" =~ ^[A-Z0-9]{10}$ ]] || fail "app not team-signed (TeamIdentifier=$app_team)"
for part in "$AGENT" "$RESTIC"; do
  [[ "$(team_of "$part")" == "$app_team" ]] || fail "$(basename "$part") is not signed with the app's team $app_team"
  sig=$(codesign -dv "$part" 2>&1 || true)
  [[ "$sig" == *"(runtime)"* ]] || fail "$(basename "$part") lacks hardened runtime"
done
[[ "$(codesign -dv "$APP" 2>&1)" == *"(runtime)"* ]] || fail "app lacks hardened runtime"
restic_id=$(codesign -dv "$RESTIC" 2>&1 | awk -F= '/^Identifier=/{print $2}')
[[ "$restic_id" == "$root.restic" ]] || fail "restic identifier is '$restic_id', expected $root.restic"

for part in "$APP" "$AGENT"; do
  [[ -f "$part/Contents/embedded.provisionprofile" ]] || fail "$(basename "$part") has no embedded.provisionprofile"
  ent=$(codesign -d --entitlements - --xml "$part" 2>/dev/null || true)
  [[ "$ent" == *"keychain-access-groups"*"$app_team.$root"* ]] \
    || fail "$(basename "$part") lacks the keychain access group $app_team.$root"
done

echo "team: $app_team"
echo "verify-bundle: OK $APP"
