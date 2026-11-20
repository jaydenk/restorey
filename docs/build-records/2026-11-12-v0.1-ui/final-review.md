# Final whole-branch review: `v0.1-ui` (53276e1..1fc8fb0)

Reviewer: senior code review (Opus), 17 Nov 2026. Read-only on the checkout. One focused build of the RestoreyCore tests;
a repeated `ResticProcessTests` loop under CPU load was started and then stopped at the coordinator's request, with no
result. Nothing ran against restic, the Keychain or the owner's data.

How the 33k-line diff was read, in passes:
1. Engine and agent: `AgentCore/*` (PlanRunner and its extensions, AgentState, CandidateSecrets, CloudOnlyWalker,
   LocationAccess), `Agent/*`, and `Restic/*` (RunOutcome, ResticMessage, ResticInvocation, DefaultExclusions).
2. RestoreyCore presentation: `App/MenuPresentation`, `HistoryPresentation`, `ProgressRate`, `PrivateFile`,
   `PasswordGenerator`, `SetupFlow`, `PlanEdit`, and the XPC protocol and messages.
3. App UI, secrets only: `ConcealedPasteboard`, `RecoveryKit*`, `AgentConnection`, and the `project.yml` Release
   exclusion.
4. Tests: ResticProcessTests, for the flake, plus coverage spot checks.
5. Docs: the README and specs, against what the code does.

restic behaviour was checked against restic v0.19.1 source: `cmd/restic/cmd_backup.go`,
`internal/ui/backup/progress.go` and `internal/ui/backup/json.go`.

## Strengths

- **Safety properties are stated and tested where they live.** `makeInvocation` lists its guarantees: `forget` is
  scoped to the host and `restorey:<id>` tag, there is no `--remove-all`, and the password is never in the environment.
  Task 14b's removal re-previews and then forgets only the confirmed IDs still in scope. It also handles restic's
  `Ignoring "<id>"` exit-0 case.
- **The exit-3 meaning per operation is right.** For `forget`, exit 3 is a failure, not a warning (M9). It is easy
  to get wrong and was got right.
- **Secret handling is careful throughout:**
  - `CandidateSecrets` is cleared by `defer` and synchronous (it uses `Mutex`).
  - `PrivateFile` writes with mkstemp at 0600, then fsync and rename, and unlinks on failure.
  - The kit re-checks `stillCurrent()` before confirming.
  - The concealed pasteboard marker is set.
  - `recoveryKit` is the only call that returns secrets, behind the unchanged signed-app listener requirement.
  - The helper's code-signing requirements were not relaxed.
- **The Developer window really is gone from Release.** `EXCLUDED_SOURCE_FILE_NAMES` excludes it, it is behind
  `#if DEBUG`, and `verify-bundle.sh` checks positive and negative controls.
- **System stops are handled well.** SIGTERM at logout or restart becomes `stoppedBySystem` with no alert and a
  15-minute retry, inside launchd's measured 5 s exit timeout. The owner verified this live, twice.
- **Location Services follows the spec.** The only prompt is `requestWhenInUse` in the user-initiated
  `requestLocationPermission`. Reads never ask, and without authorisation the rule fails open ("backups aren't skipped").
- **The Task 15b cloud-only count is bounded.** It has a deadline, runs off the cooperative pool, and is information
  only.
- **The presentation logic is unusually well tested.** Examples: the exhaustive 4,608-case "coloured headline ⇒
  reason" test, and `SettledFacts` shared by the menu line and the Overview.

## Issues

### Critical

None.

### Important

**I1. "N files couldn't be read" counts restic's scanner errors, which never affect the backup.**
- **Where:** `RestoreyCore/Sources/RestoreyCore/Restic/RunOutcome.swift:318`
  (`case .backup: return .warning(unreadable: errors.count)`). Shown by `PlanRunner+Policy.swift:123`,
  `MenuPresentation.swift:501-503` and `HistoryPresentation.swift:89-91`.
- **What's wrong:** `errors` is every `{"message_type":"error"}` line, whatever its `during`. In restic 0.19.1:
  - The scanner only estimates totals for progress. It is wired as `sc.Error = printer.ScannerError`, which emits
    `"during":"scan"` and never sets `success = false`.
  - Only the archiver's errors (`arch.Error`, `"during":"archival"`) set `success = false` and so cause
    `ErrInvalidSourceData` (exit 3).

  The owner's 2→8 jump was exactly this. Six `lstat … no such file or directory` scan errors (files deleted before
  restic reached them, so never part of what the snapshot should hold) were added to the two real CoreSpeech
  archival failures. A directory unreadable to both the scanner and the archiver is also counted twice.
- **Why it matters:** the count is the only fact the user gets about a warning backup. Inflating it with deleted files
  teaches the user to ignore the warning. The spec's "files that couldn't be read" means files left out of the
  snapshot, which scan errors are not.
- **Fix (root cause, small):**
  - Count distinct `item`s among errors with `during == "archival"`.
  - Keep a floor of 1 for an exit 3 with none, so a future restic wording change can't produce
    "Finished, but 0 files couldn't be read".
  - Optionally, word an archival ENOENT separately as "deleted while backing up". It is a file that vanished between
    the archiver's readdir and open, and is genuinely not in the snapshot.
  - Scan errors stay in the run log: `RunSupport.swift:108` already writes "during scan".
  - Add classifier tests: scan-only ENOENT plus one archival failure → 1, and the same item in both phases → 1.

  Old `RunRecord`s keep their counts, and no migration is needed.

**I2. A persistently failing preview of setup's pending removal silently stops forget, prune and check for good.**
- **Where:** `AgentCore/PlanRunner.swift` (`backupSlot`, the `pendingEarlierRemoval` guard that `return backup`s) and
  `PlanRunner+EarlierSnapshots.swift:106` (`pending` → `.notFinished` on any preview failure).
- **What's wrong:** while a pending removal exists, every successful backup runs the preview first. If the preview
  fails for any non-interrupt reason (a restic error, or the "couldn't read restic's list of snapshots" decode failure
  at `:74`), the slot returns before maintenance. Nothing clears the pending choice and no row or alert is recorded,
  by design: "so a backend down for a day doesn't leave a row an hour". Only `agentLog` sees it. So a failure that
  persists means:
  - retention stops and the repository grows without bound;
  - prune stops;
  - the weekly `check` stops, so repository damage goes undetected.

  All of this happens while the menu says the plan is fine. The ledger parked this as M2. It is the one parked item I
  would not defer.
- **Why it matters:** a reasonable person expects maintenance and integrity checking to keep running, or to be told
  they aren't. The plan's own `forget` is scoped to its `restorey:<id>` tag and cannot touch the earlier (adopted)
  snapshots, and `check` is independent. Holding them back buys no safety.
- **Fix:** on `.notFinished` from the pending removal, carry on into `maintenance(...)`. The existing per-step guards
  already stop on interruption, lock or wind-down. Then make a long-lived failure visible: count consecutive pending
  failures in `PlanRunHistory` and, after about 3, record a History row or an Overview issue such as "Couldn't remove
  the earlier snapshots you chose: <reason>". Add a runner test: a failing preview, then the backup, then forget and
  check still run.

**I3. The menu's speed figure is restic's processed-bytes rate, but the docs call it upload speed.**
- **Where:** `RestoreyCore/Sources/RestoreyCore/App/ProgressRate.swift:3` ("Upload speed"), `MenuPresentation.swift:341`,
  `README.md:438` ("upload speed while backing up"), UI design spec line 237.
- **What's wrong:** `bytes_done` counts source bytes processed. Unchanged files are counted at once without being read
  or sent, and dedup means most read bytes are never uploaded. On an hourly incremental against B2 this shows hundreds
  of MB/s (the owner saw "346 MB/s"). With an upload limit of a few MB/s, the figure reads as "the limit is broken". The
  docs must match behaviour (binding constraint), and they don't.
- **Fix (cheap, now):**
  1. Show it as what it is, for example "1.2 GB of 4.0 GB · ~6 min · 346 MB/s processed". Or drop the rate and keep
     the remaining-time estimate.
  2. Fix the README and UI spec wording.

  restic 0.19.1 reports no uploaded-bytes counter (Arq research item 6 agrees). A true upload rate would need
  backend-side measurement, so it is out of scope for v0.1.

### Minor

| # | File:line | What | Fix / where tracked |
|---|---|---|---|
| m1 | `RestoreyCore/Sources/RestoreyCore/Restic/DefaultExclusions.swift:42-48` | `~/Library/Group Containers/group.com.apple.CoreSpeech/Caches` errors (EPERM) on every run even with Full Disk Access. The existing `Group Containers/*/Library/Caches` pattern misses it because there is no `Library/` level. The Step 3c logs also name DuetExpertCenter, and CoreDevice/DeviceFS xattr "file too large". | **Now:** add `"\(h)/Library/Group Containers/group.com.apple.CoreSpeech/Caches"` in the "survey" block. Keep it specific; a `*/Caches` glob could drop real app data. Defaults only reach new plans, so the owner adds it to the existing plan by hand (don't silently migrate user exclusion lists). Confirm the DuetExpertCenter and CoreDevice paths from the run log before listing them. |
| m2 | `App/Controls/ConcealedPasteboard.swift:10-15` | A copied password or kit secret stays on the pasteboard indefinitely and syncs to the owner's other devices through Universal Clipboard. The concealed marker only helps clipboard managers. (Parked Task 12 minor 8.) | **Now:** `pasteboard.prepareForNewContents(with: .currentHostOnly)` before writing, and clear after about 90 s if `changeCount` is unchanged. |
| m3 | `RestoreyCore/Sources/RestoreyCore/App/PrivateFile.swift:38-45` | `write` returning 0 loops forever (Task 13 nit). | **Now:** treat 0 as EIO. F_FULLFSYNC → later. |
| m4 | `App/AgentConnection.swift:244` | The app doesn't check the agent's code signature on its `NSXPCConnection`, yet now sends typed credentials (`probeRepositoryCredentials`, `savePlan`) and receives secrets. A same-user process can't easily take a launchd-owned Mach name, so this is defence in depth. | **Later (v0.2):** `setCodeSigningRequirement` with the agent's bundle ID and team, mirroring `AgentListener`. |
| m5 | `PlanRunner+Policy.swift:13-18` | `forget` runs after a warning backup. See Q2 below: correct today. | **Later:** a regression guard, tracked in the post-v0.1 list. |
| m6 | `RestoreyCore/Sources/RestoreyCore/App/MenuPresentation.swift` (`settledFacts`, about :396) | A first backup stopped by the system or interrupted shows "No backup yet · Next 10:25". It doesn't say the backup will carry on, or that restic keeps what it already uploaded. (Owner request.) | **Now:** when `lastBackup == nil` and the latest backup record is `stoppedBySystem`, `interrupted` or `paused` with a `nextRunAt`, the detail becomes "The first backup was interrupted — it carries on at 10:25 (what's uploaded is kept)". `PlanStatus.latestBackupRecord` already exists. |
| m7 | `scripts/verify-bundle.sh` | No check that RestoreyCore's resource bundle (`eff_large_wordlist.txt`) is in the built app. A missing resource is a `preconditionFailure` the moment setup suggests a password, and Release setup hasn't been run live. | **Now:** assert `Contents/Resources/RestoreyCore_RestoreyCore.bundle/**/eff_large_wordlist.txt` exists for Debug and Release. |
| m8 | `RestoreyCore/Sources/RestoreyCore/Restic/ResticProcess.swift:248` (pre-existing, not in this diff) | `Drained.errors` is unbounded. A run where a large subtree turns unreadable holds every error in agent memory. | **Later:** cap the stored list, keep a count. |
| m9 | ResticProcessTests:255 (flake) | See the parked verdict below. | Capture the failure text in `ci.sh`'s log. |

## Questions asked of this review

**Q1. Should vanished files count as "couldn't be read"? Should defaults cover CoreSpeech?**
No, see I1. The root cause is counting restic's scanner errors. The scanner's `"during":"scan"` errors never change
the snapshot or the exit code; only archival errors do. Count distinct archival items. Yes on CoreSpeech, see m1:
add the specific `group.com.apple.CoreSpeech/Caches` path.

**Q2. Is `forget` after a warning backup correct and safe?**
Correct, and safe enough for v0.1:
- A warning backup is a complete snapshot of everything readable.
- `forget` is tag- and host-scoped and keeps the newest snapshot per hourly, daily, weekly and monthly bucket.
- Persistent unreadables (CoreSpeech) were missing from the earlier snapshots too.
- Skipping forget after every warning, as Arq does after errored runs, would stop retention entirely for a Mac with
  one permanently unreadable file, which is today's normal case.

The real risk is a regression: a large subtree turning unreadable (a permission change, for example) while hourly
forgets roll complete snapshots out of the buckets over days. The counts only become a usable signal once I1 lands.
Later, skip `forget` when the archival count rises well above the previous backup's (say ×2 and +100), and say so.
That is post-v0.1; track it with Arq item 2.

**Q3a. Interrupted-first-backup wording.**
Cheap and safe now, see m6.

**Q3b. A 19-minute hourly backup.**
Not a bug on what's visible:
- It runs on a home folder of about 2M files.
- Scheduling is "an hour after the last attempt", so it can't pile up.
- restic runs at `.utility` QoS, which macOS I/O-throttles.

Hypothesis to check before acting: restic 0.17+ uses ctime for change detection, and macOS bumps ctime on xattr-only
changes such as `com.apple.lastuseddate#PS`, so unchanged files may be re-read. Compare `files_changed` and
`data_added` in that run's summary with the wall time. If many files are "changed" with little data added, that's the
cause; `--ignore-ctime` is the lever, and a deliberate decision. Do not change flags on the hypothesis alone.

**Q3c. The menu speed label shows the read rate.**
See I3. Fix the wording now.

## Parked items verdicts

| Ledger line | Item | Verdict |
|---|---|---|
| 92 | A pre-Task-5 app decoding a `.stats` lastRecord | Defer (Minor). The app and agent ship together, and the handshake restarts a stale agent. |
| 184 | NSSecureTextView keeps the last secret after Tab-away; ⌘Z in a secure field | Accept (Minor). This is AppKit's in-process memory, not app state. |
| 192 | Hint for typing accents with Show on | Later (Minor). One README line; do it in the polish pass. |
| 220 | minor 8, pasteboard expiry | **Fix now (Minor, cheap): m2.** |
| 233 | Done's Start can show the refusal if the scheduler's backup won the race | Defer (Minor). It costs one extra click. Root fix in v0.2: `confirmRecoveryKit` starts the first backup atomically. |
| 234 | Banner hides while the agent is unhealthy; over-long README line | Accept the banner behaviour. Wrap the line in the docs fix for I3. |
| 239 | Edge whitespace in passwords (restic trims RESTIC_PASSWORD_COMMAND output) | **Fix now (Minor, cheap).** The setup own-password field refuses leading or trailing whitespace with a sentence. Adoption of an externally made repository with such a password stays unsupported (README note). |
| 246 | Stale-kit race until `confirmRecoveryKit` takes a digest | Defer (Minor). `stillCurrent()` narrows it to a sub-second window. Do the digest in v0.2. |
| 248 | Decline state survives a plan switch; `write` returning 0 loops; no F_FULLFSYNC; doc comment | **Fix the 0-loop now (m3).** The rest later (Minor). |
| 265 | PDF label-text extraction test | Defer (Minor). |
| 277/282 | `ResticProcessTests.cancellingTheAwaitingTaskInterruptsAndWaitsForExit` flake | Minor, not diagnosed to a cause (see below). |
| 310 | N1–N4 | Accept (Minor). N1 is unreachable (every caller is inside a window). N2 is superseded by 14c's `AboutPanel.find`. N3 recovers through planMissing. N4 is a test gap. |
| 324/327 | 14c minor 6, About routing test gap | Defer (Minor). |
| 338/353 | M1 (vanish-race runner test), M3 (Done summary after later source changes), M7 (host+paths timeline shared with another plan's same-folder snapshots) | Defer (Minor). M7 is display-only because removal is ID-confirmed. |
| 341/353 | **M2**, a permanently failing preview keeps the pending choice and skips maintenance | **Fix now: Important I2.** |
| 341/353 | Sub-millisecond adoption-time truncation; fallback bound for pre-field adoptions | Defer (Minor). |
| 348/353 | AppKit in RestoreyCore (the agent links AppKit unused); `agentInfo` defaults to a silent no-op; L1 can't prove post-layout key equivalents | Defer (Minor). Move `DestructiveAlert` to the app or a small UI target in v0.2. |
| 362 | Task 15 R1 minors (second chain in the run-loop gap; services-read timeout; stale refresh; 3 s sleeper) | Accept (Minor). |
| 368 | Unreadable-file reporting and defaults | **Covered by I1 and m1.** |
| 375 | Arq carry-overs | (1) **I3 now.** (2) Q2: later, after I1. (3) Biome is already excluded; add `Library/VoiceTrigger/SAT` only after an EPERM check. Honouring Time Machine per-item exclusions is later. (4)–(9) post-v0.1. |
| 381 | 15b minors (15 s test sleep; Stop waits up to 10 s; abandoned walk holds a GCD thread) | Accept (Minor). |
| 387 | Vanished files counted as unreadable | **Important I1.** |

**The flake (277/282), in more detail.**
- The cancellation path reads correctly: `ready` is printed after `$SIG{INT}` is installed, the process is stored
  before the drains start, and each test has its own `SupervisedProcesses`. So no ordering race is visible.
- The ledger doesn't record which expectation failed. Two load-dependent candidates remain:
  1. **SIGKILL escalation:** perl didn't exit within the 10 s `killAfter`, giving exit 137. The failing test would
     then take about 10 s.
  2. **The 1-minute time limit** under the full parallel suite.
- **Recommendation:** have `ci.sh` keep the failing expectation text, then run the test repeatedly under load on
  birdseye or CI, not on the owner's Mac. Until then it stays Minor: it tests a fake, not product behaviour.

## Owner requests

| Request | Now or later |
|---|---|
| Menu and Overview say an interrupted first backup will be retried | **Now (cheap, safe): m6.** |
| Visual polish pass before 1.0 | Later: before 1.0, not a merge blocker. |
| Upload-limit redesign (units, time-of-day window, percentage of peak) | Later: needs brainstorming. Percentage-of-peak isn't feasible from restic status. The unit choice is cheap but belongs with the redesign. |
| Wake-to-back-up (Power Nap spike, root daemon only with sign-off) | Later: post-v0.1. |

## Declined to judge

- Visual and layout quality of the SwiftUI and AppKit screens. Not checkable read-only; the owner's live checks and
  the polish pass own this.
- The VoiceOver and assistive-input behaviour of `PlainTextField` and `SecretField` (Task 9 owner checks 1–7). It
  needs a hand check.
- APFS snapshot sources, `taskpolicy -b`, and re-checking a constrained network mid-run (Arq items 7–9). These are
  outside the v0.1 plan.
- Whether `--ignore-ctime` should be adopted. It is a hypothesis needing the run summary, which I was told not to
  read.
- The real-world behaviour of the 19-minute run and the exact DuetExpertCenter and CoreDevice paths. They need the
  owner's logs, which were off-limits.
- Correctness of the 4,834 cloud-only figure. Verified live by the owner; the counting code was only spot-read.
- Whether Universal Clipboard sync of secrets matters to this owner. I graded it as a reasonable person would (Minor)
  rather than assume.

## Recommendations

1. Land I1, I2 and I3 plus the cheap minors (m1, m2, m3, m6, m7, and the line-239 whitespace refusal) in one fix
   round, with tests as described. Update the README (speed wording, the unreadable-count meaning, the CoreSpeech
   default) in the same commit.
2. Re-run the owner's hourly check once: the count should read 2 (CoreSpeech) on a run where files were deleted
   mid-scan, then 0 after adding the exclusion by hand.
3. Track m4, m5/Q2, m8 and the deferred parked items in TODO.md under "post-v0.1", each with a date.

## Assessment

**Ready to merge? With fixes.**

The branch is careful and well tested, and the owner's live checks passed. Three things a user would be misled by
should be fixed before merge, each small and local:
- the unreadable count includes restic's scanner noise;
- a failing pending removal silently stops retention and integrity checking;
- the speed figure is documented as an upload speed it isn't.
