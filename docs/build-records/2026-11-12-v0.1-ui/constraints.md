# Binding constraints for reviewers (plan 2 Global Constraints and plan-1 constraints that still hold)

- macOS 27.0, Swift 6.4 language mode, `SWIFT_STRICT_CONCURRENCY: complete`, Swift Testing.
- Secrets (repository password, backend keys, raw environment values, check-in URL) live only in the keychain; never in config, logs, the agent's own environment, or a file. S3/B2 keys reach restic only through `credential_process`. Secrets are never kept in app state after the sheet or step that needed them closes, never logged, never written by the app to disk except where the user picks a save location for the recovery kit.
- Config/state are versioned JSON (`{"schemaVersion": n, "payload": …}`) changed only through registered migrations; `<name>.v<n>.bak` kept before a rewrite (R72); a newer/corrupt file is never overwritten.
- Old XPC payloads (e.g. an `AgentStatus` from build 11) must still decode.
- Every restic call passes `--json`, `--cache-dir …`, `RESTIC_PROGRESS_FPS=2`; `backup`/`forget`/`snapshots` pass `--host <plan.hostLabel>`; backups tagged `restorey:<plan id>`; maintenance uses `--retry-lock 5m`; never `unlock --remove-all`; never `restic init` except on an explicit create action.
- Network rules apply only to repositories that need the network (S3/B2, or raw with a non-local backend; Ruling R69).
- Menu wording: "Backed up at <time>", "Paused", "Resumes by itself at <time>", "Full Disk Access is missing", "The background agent isn't running", "Notifications are off — Restorey can't alert you", "No off-Mac monitoring", "Setup not finished", "New recovery kit needed", "Finishing the current backup before updating the agent". Never "Failed" for a paused, skipped or system-stopped run.
- Icon worst state: error > warning > paused > backing up > OK; error is the only filled icon. The menu updates while open.
- Timestamps stored in UTC; Australian English in UI text, logs for people and docs.
- Tests and ci.sh never touch the real identity (R66). The helper's code-signing requirements are not relaxed.
- Developer window stays Debug-only.
- Commits: README/docs updated in the same commit; no Co-Authored-By or session trailers; TODO.md never committed.
- Ruling P-1: every task leaves scripts/ci.sh green, including the app build.
