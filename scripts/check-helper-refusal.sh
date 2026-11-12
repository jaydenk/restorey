#!/usr/bin/env bash
# check-helper-refusal.sh: the confused-deputy negative control (design spec §7; docs/spike-findings.md H2),
# run against the installed RestoreyDev and its running launchd agent. The helper, run by hand rather than by
# a restic the agent supervises, must exit 1, print nothing, and the agent must log that it refused that pid.
#
# A live check, not a test: it needs RestoreyDev installed (scripts/install-dev.sh), opened once to register
# its agent, and the agent running the installed build. It reads the real agent.log, which no test may touch
# (Ruling R66). It writes nothing itself; the only change is the agent's own refusal line in agent.log, which is
# what it looks for.
set -euo pipefail

helper=/Applications/RestoreyDev.app/Contents/Helpers/RestoreyDevAgent.app/Contents/MacOS/RestoreyDevAgent
log="$HOME/Library/Logs/Restorey-Dev/agent.log"
[[ -x "$helper" ]] || { echo "FAIL: RestoreyDev isn't installed: run scripts/install-dev.sh, then open it" >&2; exit 1; }
[[ -f "$log" ]] || { echo "FAIL: no $log: is the agent registered and running?" >&2; exit 1; }

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

run() {
  # Only HOME and PATH, as restic would give it.
  local status=0
  env -i HOME="$HOME" PATH=/usr/bin:/bin "$helper" "$@" >"$scratch/out" 2>"$scratch/err" &
  local pid=$!
  wait "$pid" || status=$?
  echo "$pid $status"
}

failures=0
for command in print-password s3-credentials; do
  offset=$(stat -f %z "$log")
  read -r pid status < <(run "$command" --plan "$(uuidgen)")
  [[ "$status" == 1 ]] || { echo "FAIL: $command exited $status, expected 1"; failures=1; }
  [[ ! -s "$scratch/out" ]] || { echo "FAIL: $command wrote to stdout"; failures=1; }
  [[ ! -s "$scratch/err" ]] || { echo "FAIL: $command wrote to stderr: $(cat "$scratch/err")"; failures=1; }
  expected="Refused a helper request from pid $pid: the caller wasn't started by a restic run"
  found=0
  for _ in $(seq 40); do
    if tail -c +"$((offset + 1))" "$log" | grep -qF "$expected"; then found=1; break; fi
    sleep 0.05
  done
  [[ $found == 1 ]] || { echo "FAIL: $log has no refusal for pid $pid (is the agent running the installed build?)"; failures=1; }
done

read -r _ status < <(run print-password --account x)
[[ "$status" == 1 && ! -s "$scratch/out" && ! -s "$scratch/err" ]] \
  || { echo "FAIL: malformed arguments gave status $status or output"; failures=1; }

[[ $failures == 0 ]] && echo "check-helper-refusal: OK" || exit 1
