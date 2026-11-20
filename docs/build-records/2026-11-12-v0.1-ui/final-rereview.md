# Final-fix re-review (1fc8fb0..d6315e9)

Read-only review of the diff file plus targeted source reads. No tests run.

## Finding Verdicts

- **I1 ADDRESSED.** `RunOutcome.swift` `unreadableFileCount` counts distinct `item`s of `during == "archival"` errors, floor 1; itemless archival errors count once each. `ResticItemError` already carries `during`/`item`; the error array (`ResticProcess.swift:248`) is uncapped, so no undercount. Tests cover all five briefed cases. Old records untouched.
- **I2 ADDRESSED.** `PlanRunner+EarlierSnapshots.swift` `runPendingEarlierRemoval` returns true for `.notFinished(.failed…)` (the only `.failed` source is the pending preview failure, `removeEarlier` line 106) and false for intent/lock/winding-down stops, so `backupSlot` carries on into maintenance. `PendingRemovalFailures` (decodeIfPresent) counts, resets on verdict (`clearPendingEarlierRemoval`) and on a replaced choice (`AgentState+Runs.swift`); `PlanStatus.earlierRemovalProblem` is set from the third failure, shown as an Overview note only (no alert, icon unchanged). Wording matches the brief. Runner tests cover maintenance still running, 1/2/3 then clear, lock not counted. Implementer concern (tests never seen red): acceptable. The pre-fix version of the test asserted the opposite behaviour, and the new assertions (forget and check after the backup, count == 1) cannot hold under the old `return false`.
- **I3 ADDRESSED.** No MB/s in the menu detail; `ProgressRate`/`ProgressRates`/`DisplayFormat.rate` and the `rates` plumbing are gone (grep of Swift sources finds no remaining use). Time-left comes from restic's `seconds_remaining`, so deleting rather than renaming is correct (nothing left to rename; the brief said keep only if needed). README (menu section and "progress and status" line), UI spec §8, original spec and measurements note are reworded. Remaining "MB/s" hits are the upload-limit field and historical mockups/plan docs, not the progress figure.
- **m1 ADDRESSED.** `DefaultExclusions.swift` adds the specific CoreSpeech Caches path; pinned test updated; README notes new plans only.
- **m2 ADDRESSED.** `ConcealedPasteboard.swift`: secrets use `prepareForNewContents(with: .currentHostOnly)`, concealed marker kept, `changeCount` captured after both writes, cleared after 90 s only if unchanged. Non-secret copies unchanged. No test (AppKit and a timed main-actor task): reasonable.
- **m3 ADDRESSED.** `PrivateFile.swift` throws EIO when `write` returns 0. Not injectable, so untested, as stated.
- **m6 ADDRESSED.** `MenuPresentation.swift` `settledFacts`: no `lastBackup`, idle phase, `nextRunAt` known, latest backup record stoppedBySystem/interrupted/paused gives the specified sentence, severity unchanged (nil). Shared by menu and Overview. Tests for each outcome and the limits (per the report; I read the source, not each test body).
- **m7 ADDRESSED.** `scripts/verify-bundle.sh:79-82` asserts the word list exists in the app bundle and has 7,776 lines; runs for every build ci.sh verifies (Debug unsigned, Release unsigned, Debug signed). Negative controls reported by the implementer.
- **Line 239 ADDRESSED for the new-repository field.** `FormValidation.newRepositoryPassword` (leading/trailing whitespace, exact sentence), wired into `SetupModel.passwordProblem` (gates `createRepository`) and shown under the field once non-empty; README states the rule and the adopt-repository limitation. Whitespace rule only on the new-repository field: matches the brief ("own new password") and the README says adoption isn't supported. An adopted password with edge whitespace still reaches the Open path unchecked, which is the documented limitation rather than a defect.

## New Breakage in the Fix Diff

- **Minor:** a repository lock held during the pending-removal *preview* is classified `.failed` (`earlierGroups` wraps any non-success outcome as `operationFailed`), so it is counted toward the three-strikes note and maintenance proceeds (where its own steps then meet the lock and record `.locked`). Harmless and arguably right, but it differs from the "a lock stops" wording in the comments and README; the lock test only covers a lock during the forget step.
- **Minor (wording):** the Overview note nests two sentences, e.g. "Couldn't remove the earlier snapshots you chose: Restorey couldn't count the earlier snapshots: ….". Reads clumsily but matches "use the existing reason text".
- **Cosmetic:** a stray blank line left in `SetupModel.swift` after `planStatus` (two consecutive blank lines where `bytesPerSecond` was removed).
- **Cosmetic:** `MenuLayoutTests.swift:187` still uses an "18 MB/s" detail string as arbitrary text.
- Nothing Critical or Important.

## Out-of-Scope Observations

- `docs/mockups/*.html` and `docs/superpowers/plans/2026-11-12-v0.1-ui.md` still show the upload-speed figure; they are historical design artefacts, not user-facing.
- The "Open" (adopt existing repository) password field has no whitespace check; documented as unsupported in the README.

## Assessment

**Approved.** All nine findings are addressed; no NOT ADDRESSED items; no new Critical or Important breakage.
