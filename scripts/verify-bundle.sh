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
  com.jaydenkerr.restorey)     app_name="Restorey";    agent_name="RestoreyAgent";    logs="Restorey";     display="Restorey" ;;
  com.jaydenkerr.restorey.dev) app_name="RestoreyDev"; agent_name="RestoreyDevAgent"; logs="Restorey-Dev"; display="Restorey Dev" ;;
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

# The agent posts the notifications and asks for their permission, so it carries the app's display name
# and both read as Restorey in System Settings and in banners (Ruling R61).
app_display=$(plist_get "$INFO" CFBundleDisplayName)
agent_display=$(plist_get "$AGENT/Contents/Info.plist" CFBundleDisplayName)
[[ "$app_display" == "$display" ]] || fail "app CFBundleDisplayName is '$app_display', expected '$display'"
[[ "$agent_display" == "$app_display" ]] || fail "agent CFBundleDisplayName is '$agent_display', the app's is '$app_display'"

# The agent reads the Wi-Fi name, which needs Location permission: requestWhenInUseAuthorization fails at once
# without the usage description (NSLocationUsageDescription on macOS, and the When In Use key it documents).
location_text="Restorey checks the Wi-Fi network's name so it can skip backups on networks you've listed."
for key in NSLocationUsageDescription NSLocationWhenInUseUsageDescription; do
  [[ "$(plist_get "$AGENT/Contents/Info.plist" "$key")" == "$location_text" ]] || fail "agent $key is not the Location usage text"
done

# The Developer window is Debug-only (project.yml excludes App/Developer from Release, and its uses are behind
# #if DEBUG). Its Swift types' names are in a binary's metadata whenever it is compiled in, stripped or not, so a
# Release bundle must have none of them, and a Debug one all three: the positive control that shows the check looks
# in the right binaries (a Debug app's code is in Contents/MacOS/*.debug.dylib, not the main executable). Every
# Mach-O file under Contents is read, so an embedded framework or helper added later is covered too.
developer_types='DeveloperModel|DeveloperWindowController|DeveloperView'
developer_found=""
developer_scanned=0
while IFS= read -r -d '' file; do
  [[ "$(file -b "$file")" == Mach-O* ]] || continue
  developer_scanned=$((developer_scanned + 1))
  found=$(strings -a "$file" | grep -oE "$developer_types" | sort -u | tr '\n' ' ' || true)
  developer_found+="$found"
done < <(find "$APP/Contents" -type f -print0)
# The app, the agent and restic at least.
(( developer_scanned >= 3 )) || fail "only $developer_scanned Mach-O files found under $APP/Contents"
developer_found=$(tr ' ' '\n' <<<"$developer_found" | grep -v '^$' | sort -u | tr '\n' ' ' || true)
case "$root" in
  com.jaydenkerr.restorey)
    [[ -z "$developer_found" ]] || fail "the Release app contains the Developer window ($developer_found)" ;;
  com.jaydenkerr.restorey.dev)
    [[ "$developer_found" == "DeveloperModel DeveloperView DeveloperWindowController " ]] \
      || fail "the Debug app's Developer window types weren't all found ('$developer_found'): the check would miss them" ;;
esac

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

# Under the hardened runtime, Location Services also needs the resource-access entitlement.
agent_ent=$(codesign -d --entitlements - --xml "$AGENT" 2>/dev/null || true)
[[ "$agent_ent" == *"<key>com.apple.security.personal-information.location</key><true/>"* ]] \
  || fail "agent lacks com.apple.security.personal-information.location"

echo "team: $app_team"
echo "verify-bundle: OK $APP"
