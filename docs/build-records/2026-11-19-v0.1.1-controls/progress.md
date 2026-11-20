# SDD ledger — plan: docs/superpowers/plans/2026-11-19-v0.1.1-controls.md

Branch v0.1.1-controls off main c3f5b46. Spec: owner decisions 18 Nov 2026 (TODO.md) + product/UI specs named in the plan header.
Execution: subagent-driven (owner, 20 Nov 2026).

## Pre-flight scan
| Pair / task | Produces → consumes | Finding |
|---|---|---|
| T1 → T2 | FolderDrop.addingSources(_:to:repository:), Outcome.note, Repository.localFolderPath, SourcePaths.contains | match |
| T3 → T5 | PauseLength (menuTitle, seconds, longest), AgentActions.pause(_:for:_:) | match |
| T4 → T5 | AgentActions.cancel(_:_:), cancelFailed | match |
| T3 ↔ T4 | both edit AgentProtocol/AgentService/AgentConnection/AgentActions/AgentState | sequential, no conflict |
| T3 ↔ T5 | T3 passes .oneHour to compile; T5 adds choices | consistent |
| T1 self | tests vs code: sentences, ordering, exclusion via DefaultExclusions.pattern | consistent |
| T2 self | SourcesEditor callers listed (PlanFoldersTab, SourcesView, DeveloperWindow) | consistent; setup picks repository before sources step (SetupModel+Sources.swift:39) |
| T3 self | planPauseDuration removed; AgentState.pauseDuration (line 21) uses it | consistent |
| T4 self | cancel never touches pausedUntil; allowed while draining | consistent with AgentProtocol draining note (only pause allowed today → cancel joins it) |
| T5 self | PlansPane Pause button covered by "Overview buttons" | consistent |

Ruling: commits carry NO Co-Authored-By / Claude-Session trailers — owner's global CLAUDE.md overrides the harness attribution reminder — cost if wrong: trailers missing.
Ruling: SetupAdoption (sources from a snapshot's paths) bypasses FolderDrop; the agent's sourceInsideRepository validation is the backstop and nested-duplicate paths from a snapshot are left as they are — out of the owner's three rules' entry points (+, drop, setup picker) — cost if wrong: an adopted plan could list a nested folder twice.

## Tasks
Task 1: dispatched (BASE ace9d99, implementer sonnet)
Task 1: implemented 078944b (DONE_WITH_CONCERNS: app not xcodebuilt; FolderDrop.name made public; plural repo sentences added); review dispatched (sonnet)
Task 1: minor (deferred): validationErrors now does file I/O (symlink resolution) per source for local repos; doc comment silent (Plan.swift:311)
Task 1: minor (deferred): relative source can raise sourceInsideRepository on top of relativeSource (Plan.swift:312, no hasPrefix("/") guard)
Task 1: minor (deferred): plural repository refusal sentences (FolderDrop.swift:255-270) and note+problem together untested
Task 1: minor (deferred): Review Focus 1 symlink tested only at SourcePaths level, not FolderDrop/validation
Task 1: minor (deferred): Refused.problem property vs problem(home:); same-place check repeats contains both ways; AgentCore uses FolderDrop.name (app-layer helper made public); aNetworkRepositoryAddsNoExclusion count depends on fixture
Task 1: ⚠️ App target unbuilt — resolved by Task 2's Debug build (Task 2 rewrites the same SourcesEditor call)
Task 1: complete (commits ace9d99..078944b, review clean)
Ruling: load is 86–200 (other projects); per-task scripts/ci.sh is skipped when the 1-min load stays ≥15 for 15 min — the implementer reports it skipped; the controller runs ci.sh/GitHub CI once on the whole branch before finishing — same call as Task 18's ruling — cost if wrong: a cross-target break found later, at branch end, not per task.
Task 2: dispatched (BASE 078944b, sonnet)
Task 2: implemented e7f5462 (ci.sh skipped per ruling; off-screen renders task2-*.png); review dispatched (sonnet)
Task 2: minor (deferred): SourcesEditor doc comment overlong/merged sentence; no test for repository == a source in repositoryRow; row uses FormValidation.displayPath vs DefaultExclusions.displayPattern for other rows
Task 2: ⚠️ .selectionDisabled() click behaviour needs a real interaction check → owner's hands-on checklist at branch end (no on-screen windows here)
Task 2: complete (commits 078944b..e7f5462, review clean)
Task 3: dispatched (BASE e7f5462, sonnet; reviewer opus)
Task 3: implemented dcb5dcd (DONE_WITH_CONCERNS: 2 one-hour-cap tests changed to day cap; AgentService glue build-only; full suite not re-run after test edits); review dispatched (opus)
Task 3: minor (deferred): anUnknownPauseLengthIsRefused's "state unchanged" asserts are vacuous (decode is pure, never reaches state) — AgentStateTests diff L912
Task 3: minor (deferred): PauseRequest.decoded copies AgentService.codingPath and already drifted (no intValue); lives in AgentError.swift — share one helper
Task 3: minor (deferred): "Until Tomorrow" across spring-forward at 23:30 lands 2 calendar days later and reads without "tomorrow"/day
Task 3: minor (deferred): AgentConnection.pause swallows an encode failure with try? (no log)
Task 3: minor (deferred): full suite not re-run after two cap tests edited → covered by the branch-end ci.sh/GitHub CI
Task 3: ⚠️ AgentService.pause glue untested (Agent/ not reachable from SPM tests) — accepted: decode-then-state order verified by reviewer inspection; build covers it
Ruling: a mixed-build app/agent pair calling pause:withReply: (NSString→NSData) is rejected by NSXPC's class check and the caller waits out statusCall's timeout rather than seeing the refusal sentence; the version handshake shows Updating… with no actions in the menu, so the window is narrow; Review Focus 5's sentence covers a request that decodes as PauseRequest with an unknown length (future builds) — cost if wrong: a Shortcut run during an update waits ~60 s then fails generically.
Task 3: complete (commits e7f5462..dcb5dcd, review clean)
Task 4: dispatched (BASE dcb5dcd, sonnet; reviewer opus)
Task 4: implemented 27a4a1f (DONE_WITH_CONCERNS: RunHandle.request now first-stop-wins (beyond brief, root cause of cancel-after-pause); Cancel-then-Pause race leaves run .cancelled with pausedUntil set); review dispatched (opus)
Task 4: review (opus) — spec ✅; Important: cancelWhileAPauseIsStoppingTheRunKeepsThePause races a ~50 ms stub exit (no INT trap) so it can pass vacuously on CI
Ruling: reviewer Minors 1 (Resume after Cancel→Pause throws "already backing up": R62 queue checks intent == .pause) and 2 (Pause→Resume→Cancel: queued startWhenPausedRunEnds still starts a backup) go into fix round 1 with 3 (vacuous phase != nil assert) and 4 (stale AgentActions doc) — they are real wrong behaviour in Cancel's own interactions, small, and in this task's files — cost if wrong: a slightly larger fix diff.
Task 4: fix round 1 dispatched (resume implementer, FIX_BASE 27a4a1f)
Task 4: fix round 1 committed a729d00 (5 findings fixed; RED shown with guard reverted); scoped re-review dispatched (sonnet)
Task 4: fix round 1/5 (5 addressed, 0 open; commits 27a4a1f..a729d00)
Task 4: minor (deferred): Pause→Resume→Cancel end state (unpaused, no backup) has no status assertion; HeldStopStub.interrupts() would double-count across two processes
Task 4: complete (commits dcb5dcd..a729d00, review clean after 1 fix round)
Task 5: dispatched (BASE a729d00, sonnet)
Task 5: implemented dea514f (DONE_WITH_CONCERNS: ci.sh tests passed, signed Debug build failed on a missing provisioning profile (env); approximate-chrome menu renders; judgement calls: plain Cancel item for one running among several, Cancel submenu lists running plans only, no confirm on Cancel); review dispatched (opus)
Task 5: minor (deferred): PlanOverviewTab.perform keeps a dead `case .pause: break`
Task 5: minor (deferred): cancelBackupAppearsOnlyWhileABackupRuns idle check only looks for an .item (a submenu would pass)
Task 5: minor (deferred): plain Cancel item (one of several running) has no accessibility label naming the plan
Task 5: minor (deferred): PauseLengthOption display titles duplicate PauseLength.menuTitle literals, nothing catches drift
Task 5: minor (deferred): README quotes the Cancel refusal as “<plan> isn’t backing up.” (wrong quote placement); README Overview sentence awkward; new README/spec lines exceed ~120-col wrap
Task 5: minor (deferred): CancelBackupIntent summary reads "Cancel the backup of Plan" with no plan chosen
Task 5: minor (deferred): App/Developer/DeveloperModel.swift:127 still passes .oneHour (Debug-only window)
Task 5: ⚠️ saved pre-change Pause shortcut picking up the default, real Shortcuts display, real AppKit menu look → owner hands-on checklist
Task 5: complete (commits a729d00..dea514f, review clean)
Final review: dispatched (opus, ace9d99^..HEAD = c3f5b46..dea514f)
Note: signed Debug build failed at 09:28 (Task 5 ci.sh): the restorey.dev app and agent profiles (dd250662, e31095fd) are gone from ~/Library/Developer/Xcode/UserData/Provisioning Profiles (dir modified 09:28; only the old .spike profiles remain); the build used a cached profile path. Plan: branch-end ci.sh with -allowProvisioningUpdates should fetch new ones; if it fails again, report to owner (Xcode > Settings > Accounts > Download Manual Profiles).
Final review (opus): With fixes. Important: (1) symlink-resolving I/O in validationErrors → nextRunDate → agent actor status/tick path can hang on an unreachable NAS share; (2) a v0.1-saved plan newly invalid under sourceInsideRepository silently stops (no next run, no reason shown). Minor: (3) double full stop in joined plan refusals; (4) README stale one-hour pause lines + misquoted refusal + Several-plans bullet; (5) cancelled first backup loses "carries on" note; (6) "“Home” was cancelled." wording; (7) Cancel dialog claims success when Pause won; (8) AgentService logs "Cancelled the run" with no run.
Ruling: one final fix dispatch covers 1, 2, 3, 4 (+T5 README quote/sentence/wrap), 5, 6, 8 — (7) parked: the agent's behaviour is correct, only a rare dialog's wording; fixing needs AgentState.cancel to report whether it stopped anything (API change late in the branch) — cost if wrong: one race shows "Cancelled the backup" when the pause in progress won.
Final fix: dispatched (opus, FIX_BASE dea514f)
Final fix: committed 979563a (7 findings; suite 1133+351 green; unsigned build ok; concerns: app-side FolderDrop/repositoryRow still resolve links on main thread; DefaultExclusions.pattern uses URL(fileURLWithPath:) on PlanRunner; invalid v0.1 plan now raises settings alert); scoped re-review dispatched (opus)
Final fix re-review (opus): 2–7 ADDRESSED; 1 NOT ADDRESSED — stopReason → PlanValidationError.message → FolderDrop.name → URL(fileURLWithPath:) stats a source path on the repository volume on the AgentState actor every status build (legacy-invalid plans). New: Important design caveat — Task.detached link resolution blocks cooperative-pool threads (hung volume can exhaust the pool → whole agent stalls); Minor — savePlan suspends before serialisedWrite so overlapping saves can land out of order; weak mode-000 test half. Out of scope: noRecentSuccess hides .stopped reason in menu line; app-side URL(fileURLWithPath:).lastPathComponent on repository paths (MenuPresentation:607, StorageForm:230).
Ruling: second, narrowly scoped final fix round (deviation from "one final fix dispatch") — finding 1 is the branch's own Important and still open, the pool-exhaustion caveat defeats it by another route, and the save reorder can lose a newer save; all real, load-bearing, small — cost if wrong: one more fix/re-review cycle.
Final fix round 2: dispatched (resume fixer, FIX_BASE 979563a)
Final fix round 2: committed 7e1c43a (A pure names + StatusPathPurityTests; B LinkResolver on OwnThread, 10 s deadline, OneOutstandingGate, fallback to path-only; C link check inside serialisedWrite; D repositoryRow path-only); suite 1138+354 green; re-review dispatched (opus)
Final fix round 2 re-review (opus): A–D ADDRESSED. New (test-only) Minor: LinkResolverTests deadline-vs-thread race (asserts calls==1 before handshake); AgentStateTests link-timeout test can hang if .expired before gate.enter; nit: repositoryLinkTarget logs every backup while stuck. Concern 3: purity scan file list incomplete, patterns narrow.
Ruling: one small test-hardening dispatch (sonnet) before CI — the two races are exactly the class that failed GitHub CI on the last branch (3–4 core runner); add README note that config writes can wait up to 10 s on a hung link check; widen the purity scan to directories + more patterns; log stuck once per episode — cost if wrong: one more short cycle.
Deferred (owner/follow-up): SchedulerCore.swift:181 standardizingPath on mount nudge (pre-existing, low risk); pattern(forFolder:) no longer strips /private for app-side UnreadableList comparison (edge); app-side link-following on main thread (FolderDrop.classify, FormValidation:200/214, StorageForm:230).
Final fix round 3: dispatched (sonnet, FIX_BASE 7e1c43a)
Final fix round 3: committed 25469d2 (handshakes in link-check tests; purity scan widened to AgentCore + Config/Schedule/Alerts/Restic + 3 App files with justified allowlist; SchedulerCore:181 now pure; log once per stuck episode; README 10 s note); full suite 1140+354 green.
Ruling: the remaining window in aCheckPastItsDeadline… (deadline passing between computing `end` and the synchronous gate.enter, no suspension between) is accepted — same shape as MarkedNotForBackupTests that passes CI; it fails loudly rather than hanging — cost if wrong: a rare CI red needing a re-run.
Final review: closed (Important findings addressed across 3 fix rounds). Next: branch-end scripts/ci.sh, then push + PR on owner's go.
Branch-end scripts/ci.sh: ALL PASSED (10:40–~11:00 20 Nov; RestoreyCore 1140, AgentCore 354, starvation 2, unsigned Debug/Release, signed Debug — profiles re-fetched — and 6 hosted tests). HEAD 25469d2. GitHub CI pending a push (owner's call).

## Owner decisions after the hands-on checks (20 Nov 2026)
- Cancelling never moves the schedule (owner: "if i have a backup scheduled at 12pm, every 4 hours, and cancel the 12pm instance, the 4pm instance should run as planned"). Found live on build 832: a Resume-started backup at 12:37, cancelled, moved the next backup from 16:24 to 16:37. Fix: `PlanRunHistory.attemptBeforeRun` (set at a backup's start) and `lastAttemptAfterCancel` put `lastAttemptAt` back to the old schedule's slot (the previous attempt if the run came early, else the newest slot at or before the cancel).
- Pause only while a backup runs, everywhere (owner: "you can't pause something that's not running"): `PlanChoice.canPause` = ready && running; menu Pause appears only with something running (per running plan when several); sidebar context menu shows Pause only then; Shortcuts refuse "Nothing is backing up, so there’s nothing to pause." / "“X” isn’t backing up, so there’s nothing to pause.". The agent's `pause` still accepts an idle plan (a Pause landing just after its run ended).
