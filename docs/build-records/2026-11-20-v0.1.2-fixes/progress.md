# SDD ledger — plan: docs/superpowers/plans/2026-11-20-v0.1.2-fixes.md
Branch: v0.1.2-fixes (in the main checkout; base b967a91, plan commit on top). Specs: docs/superpowers/specs/2026-11-09-restorey-design.md, 2026-11-12-restorey-v0.1-ui-design.md.

## Pre-flight scan
| Tasks | Shared | Found |
|---|---|---|
| T1→T2 | T1 produces the unreadable count incl. dropped errors; T2 consumes `.warning(unreadable: n)` | consistent |
| T2, T4, T6, T11 | MenuPresentation.swift (notes/banners/icon) | sequential edits, no contradiction |
| T6, T11 | AgentHealth.swift possibly (T6 only if L168 investigation lands there) | no contradiction |
| T3, T12 | DefaultExclusions.swift | T3 names `Config/DefaultExclusions.swift`; real path is `Restic/` → Ruling P1 |
| T7, T11 | app agent plumbing (AgentConnection vs AgentSupervisor) | different files |
| T9, T12 | AgentState.swift (confirmRecoveryKit vs config load) | different regions |
| T12, T9 | SetupModel+Storage (plan creation revision) vs SetupModel+Done | different files |
| T1 | self | tests match code steps |
| T2 | self | ok |
| T3 | self | path typo only (P1) |
| T4 | self | L99(b) text to be pinned from current message — implementer pins it |
| T5 | self | ok |
| T6 | self | Step 1 reads agent log read-only, allowed by Global Constraints because the task says so |
| T7 | self | verification partly deferred to end-of-branch ci.sh — accepted |
| T8 | self | ok |
| T9 | self | ok |
| T10 | self | ok |
| T11 | self | ok |
| T12 | self | bumps ConfigMigrations.currentVersion to 4; tests pinning 3 update |
Ruling P1: Task 3's DefaultExclusions path is `RestoreyCore/Sources/RestoreyCore/Restic/DefaultExclusions.swift` — plan typo — none.

## Tasks
Task 1: dispatched (base 2e9fcb6)
Task 1 implementer agent: a313e45ef539ef5bc (sonnet)
Task 1: implementer DONE_WITH_CONCERNS 09090d7 — AgentCoreTests stalled under load ~110-157 (also stalls on baseline); RULING: AgentCore suite deferred to a quiet-machine run before end-of-branch ci.sh — the AgentCore change is a pass-through arg — cost if wrong: a regression found late. Concern 2 (flag only on forget/prune/check) matches brief. Reviewer: ae555ad23924f85a4 (sonnet)
Task 1: review Approved, spec ✅. ⚠️ AgentCore suite unverified under load → covered by the deferred quiet-machine AgentCore run (ruling above). ⚠️ --cleanup-cache in 0.19.1: verified by controller earlier this session (present in restic 0.19.1).
Task 1: minor (deferred): cleanup-cache test doesn't pin forgetPreview/forgetSnapshots either way; merge-step cap branch (stderr+stdout > limit) untested; flood test uses a slow shell loop.
Task 1: complete (commits 2e9fcb6..09090d7, review clean)
Task 2: dispatched (base 09090d7)
Task 2 implementer: ae331438ba9653dac (sonnet). Ruling T2-1: previous backup without a warning counts as m=0 (so the jump rule needs n>=100) — the brief's rule applied to a clean previous run — cost if wrong: a first big unreadable jump after clean runs tidies anyway or not, adjustable later.
Task 2: implementer DONE_WITH_CONCERNS 8545d30; AgentCoreTests 361 passed (also clears the Task 1 deferred AgentCore run). Curly apostrophes accepted (house style).
Task 2: review Approved (opus), spec ✅; ⚠️ Overview line build-only → check by eye at end-of-branch install.
Task 2: minor (deferred): prune dropped silently when held but forget not due (daily cadence); prune half of the jump test can't fail; try? on runInputs read; skip record written while winding down; counts not locale-formatted; maintenance() computed twice.
Task 2: complete (commits 09090d7..8545d30, review clean)
Task 3: dispatched (base 8545d30)
Task 3: implementer DONE d2d3cfe (af11db980fac5fb45)
Task 3: review Needs fixes (1 Important: /private outer no longer contains /private/tmp/x — containment regression). Fix round 1 sent to implementer.
Task 3: fix round 1/5 (2 addressed, 0 open — /private containment, README wrap; commits d2d3cfe..f8c9518)
Task 3: complete (commits 8545d30..f8c9518, review clean)
Task 4: dispatched (base f8c9518)
Task 4: implementer DONE_WITH_CONCERNS d4e6439 (a03d5763e51f2ad84); caption build-only → eye check at install
Task 4: review Approved (opus), spec ✅; ⚠️ PasswordView caption by eye at install.
Task 4: minor (deferred): README.md:308 triple opening quote; PasswordView.swift:205-210 accentsHint inserted between a doc comment and its struct; PlanRunner.swift:490 outcome taken from any handle, so a measurement handle taking the cancel while the main run pauses reports stoppedARun; mixed All Plans wording lists nothingToCancel plans as cancelled.
Task 4: complete (commits f8c9518..d4e6439, review clean)
Task 5: dispatched (base d4e6439)
Task 5: implementer DONE_WITH_CONCERNS 9ae440d (a8d5949d19e5acdd4) — concerns: silent fallback, fallback treats files as folders, FormValidation.addingSources no longer dedups link+target / leaves relative paths
Task 5: review Needs fixes (opus): Important — silent/unlogged fallback; byPath treats files as folders; easy to trigger via one stalled listed source. Concern 3 (no dedup in FormValidation.addingSources) ruled correct by reviewer.
Task 5: Ruling T5-1: fallback gets note "Restorey couldn’t check these in time, so they were added as chosen." + .info log via injected AppLog + hasDirectoryPath file classification (or refuse) — reviewer's suggested fix, copy chosen by controller — cost if wrong: copy tweak.
Task 5: minor (deferred): end-of-test bounded sleep loop for gate release (mirrors LinkResolverTests); `against` captured before the look goes stale; no progress sign during a 10 s look.
Task 5: fix round 1 sent.
Task 5: fix round 1/5 (2 addressed, 0 open — silent fallback/file-as-folder, doc comments; commits 9ae440d..b5168c4)
Task 5: minor (deferred): fallback refusal of a real folder URL without trailing slash says "isn’t a folder"; note/log UI build-only (eye check at install).
Task 5: complete (commits d4e6439..b5168c4, review clean)
Task 6: dispatched (base b5168c4)
Task 6: implementer DONE_WITH_CONCERNS 247fba5 (ae51f9b0f1dea5b93); L168 cause: recovery unlock registered as a run → phase .running; fixed by registering as a measurement
Task 6: review Needs fixes (opus): Important — delete during recovery unlock now blocks unbounded (runner nil during recovery) and docs claim it stops the unlock. Concurrency named risk: clean (recovery gate + unattached runner + repo queue).
Task 6: Ruling T6-1: refuse delete during recovery with the existing "still starting up" refusal — restores pre-change immediate answer — cost if wrong: owner must retry a delete a few seconds later.
Task 6: minor (deferred): measurement* names now cover four job kinds (rename ticket); first-pass-green MenuPresentation tests pin existing behaviour; transparency layer/R fallback by eye at install.
Task 6: fix round 1 sent.
Task 6: fix round 1/5 (3 addressed, 0 open — delete refused during recovery, handle order, README reflow; commits 247fba5..9b05bf5). Re-review flagged a Minor test-timing flake.
Task 6: Ruling T6-2: re-graded the recovery-delete test timing flake to Important — CI is 3-4 cores with a known cancel-test flake, and a deterministic fix is cheap — cost if wrong: one extra small round.
Task 6: fix round 2 sent (deterministic test).
Task 6: fix round 2/5 (1 addressed, 0 open — deterministic recovery-delete test; commits 9b05bf5..441687b)
Task 6: complete (commits b5168c4..441687b, review clean)
Task 7: dispatched (base 441687b)
Task 7: implementer DONE_WITH_CONCERNS b39d9b3 (a2762b8fc6c45449c); signed path deferred to end-of-branch ci.sh + install
Task 7: review Approved (opus), spec ✅; ⚠️ signed path end-to-end → end-of-branch ci.sh signed build + install (check log says "requires … signed by its team").
Task 7: Ruling T7-1: refuse-all peer check must become a terminal health state that skips automatic repair — carried into Task 11's dispatch (Task 11 lets repair stop a backup) — cost if wrong: a broken build kills a backup hourly.
Task 7: minor (deferred): README.md:259 "not the Info.plist" slightly inaccurate + wrap; OwnSignature.current() has no automated (signed hosted) test.
Task 7: complete (commits 441687b..b39d9b3, review clean)
Task 8: dispatched (base b39d9b3)
Task 8: implementer DONE_WITH_CONCERNS b8735b5 (ae913256789b64616); Step 1 list: DestructiveAlert.swift was the only RestoreyCore AppKit import → moved to App/Controls; AboutPanel, ActivationController, KeyWaiter, MenuLayout are Foundation-only, kept
Task 8: review Approved (sonnet), spec ✅.
Task 8: minor (deferred): no permanent verify-bundle.sh guard that DestructiveAlert stays out of Helpers (pattern at verify-bundle.sh:111-133); NSAlert button test now hosted-only (skipped on unsigned CI); duplicated `longest` fixture.
Task 8: complete (commits b39d9b3..b8735b5, review clean)
Task 9: dispatched (base b8735b5)
Task 9: implementer DONE_WITH_CONCERNS 24a2ac2 (aea86193cfb6b799f); added Plan.credentialsVersion; ResticProcessTests timing flaked once under load ~60 (untouched code)
Task 9: review Approved (opus), spec ✅. Check-in URL left out of digest/stamp — accepted (added after the kit step). ⚠️ owner UI run: change password while setup sits at Done → Start → kit step shows new kit, tick cleared, sentence shown.
Task 9: minor (deferred): old agent's "isn't a plan ID" reply shown raw in the update window; untested confirmKit refusal and began==false branches; README.md:382 unwrapped; refusal matched by shared text constant (typed code later).
Task 9: complete (commits b8735b5..24a2ac2, review clean)
Task 10: dispatched (base 24a2ac2)
Task 10: implementer DONE 41d21c2 (a37cdb7461b8dc814)
Task 10: review Approved (haiku), spec ✅; build/ exists (ci.sh:11).
Task 10: minor (deferred): brief's "as the starvation step does" premise was wrong (starvation step doesn't grep failures) — no code change needed.
Task 10: complete (commits 24a2ac2..41d21c2, review clean)
Task 11: dispatched (base 41d21c2), carrying Ruling T7-1
Task 11: implementer DONE_WITH_CONCERNS fcfe17d (a05681320eeecd287); T7-1 → new health state signatureUntrusted
Task 11: review Needs fixes (opus): Important — wall-clock cap counts sleep (one post-wake failure can kill a healthy backup); Important — register-under-refuseAll exception not owner-approved; Minor — UI spec R68 item stale.
Task 11: Ruling T11-1: keep "register a missing agent" under refuse-all — register() stops nothing and the next heartbeat lands in signatureUntrusted — but a register failure there must show the signature cause — cost if wrong: a broken build re-registers a missing agent it can't talk to (harmless).
Task 11: minor (deferred): banner usually clears within ~one retry (and says "next time" while the plan is backing up); skipped runs clear it (untested); banner can stay forever if the stopped plan is deleted/stopped and nothing else runs; wording says "backup" even if the hung restic was maintenance; legacy recovery fallback startedAt=now clears early; user Restart that stops a backup shows no banner.
Task 11: fix round 1 sent (sleep-proof cap, register-failure cause, spec item).
Task 11: fix round 1/5 (3 addressed, 0 open — awake-time cap via SuspendingClock, register-failure cause, UI spec item; commits fcfe17d..251a57a)
Task 11: minor (deferred): menu notAnsweringGrace still wall-clock (wording only); early-return heartbeats don't reset UnreachableRun (as before).
Task 11: complete (commits 41d21c2..251a57a, review clean)
Task 12: dispatched (base 251a57a)
Task 12: implementer DONE_WITH_CONCERNS ea5fb46 (addf573fdae7b2576); savePlan keeps agent-owned revision (beyond brief, accepted pending review)
Task 12: review Approved (opus), spec ✅; ⚠️ owner-plan CoreSpeech row by eye after install.
Task 12: minor (deferred): new-plan-with-old-revision savePlan branch untested; schema 4 bump is the only thing making a downgraded agent refuse the file (plan's choice, not owner's — decode default alone would do); drift guard one-directional (freeze revision-1 list).
Task 12: complete (commits 251a57a..ea5fb46, review clean)
Final review: dispatched (opus, a93a59db4c33916b1) over b967a91..ea5fb46
Final review: With fixes (opus). Important 1: OwnSignature uses dynamic validity — a team-signed Debug build under the debugger may lose CS_VALID → refuse-all. Important 2: backup-stopped banner can stay for good (stopped plan deleted/stopped), holding the icon at warning, no dismiss. Minors: Undo for firmlink-matched unreadable row does nothing; containsByPath("/private","/tmp/x") false; stale doc comment MenuPresentation.swift:808; README:260 says Debug builds are unsigned.
Final: Ruling: UnreadableFilesSheet fileExists on main actor (pre-existing, Task 16b) — out of scope, defer to the polish/robustness batch — cost if wrong: sheet stall on a hung volume.
Final: Ruling: PlanStatus strict decode of `.forgetHeldBack` by an older app — app and agent ship together and the handshake restarts a stale agent — stands — cost if wrong: an old app shows a status decode error in the update window.
Final: Ruling: UnreachableRun restarts on app relaunch (stretches the cap) — measured from the first failed heartbeat this app saw, as specified — stands — cost if wrong: a hung backup waits longer than 30 min after a relaunch.
Final: Ruling: forget hold lasts one backup — spec states it; flag to owner — cost if wrong: weaker protection with hourly backups.
Final: Ruling: Important 1 fixed by reading the team from the static code (not dynamic validity) — avoids the debugger case without weakening the agent-side check — cost if wrong: none to security (the agent listener still enforces).
Final: Ruling: Important 2 fixed by clearing the note when no plan could run and giving the banner a dismiss action — cost if wrong: copy/UX tweak.
Final: fix wave dispatched (Important 1-2, Minors 1-4).
Final: fix wave DONE_WITH_CONCERNS 471c5bd,4060f9a,9b74f41 (a4c75dc756e6f7161); debugger case not reproducible here (Developer mode off)
Final: re-review — all findings addressed, no new Critical/Important.
Final: minor (deferred): when the agent can't load its settings (no plans / all stopped), the supervisor erases the stopped-backup time rather than hiding it.
Final: Ruling: static-code signature read accepts a team-signed-on-disk process with invalid running code as `.required` (was refuseAll) — the agent's listener still checks the running peer; the self-check was never a boundary — cost if wrong: none to security beyond app-bundle write access.

## Owner correction (20 Nov 2026)
Owner: "give up after 30 minutes" meant "show a warning and keep waiting", not "stop the backup". Restorey can't tell a stuck restic from a busy one.
Correction: 0bb1ba8 — no automatic action ever stops a restic running under an unreachable agent; after 30 awake minutes the menu warns "Restorey’s background process hasn’t answered for 30 minutes" / "A backup is still running, so Restorey is waiting for it rather than stopping it. Restart Backups stops it now." with the user's Restart Backups; the stopped-backup note, its UserDefaults key and Dismiss are removed. Review: Approved (opus).
Fix round 1: 692af15 — Ruling: no window says "no backups will happen" while waiting (Settings "Not answering — a backup is still running", Diagnostics "not answering; a backup is still running") — follows the owner's correction; the false sentence nudged towards stopping — cost if wrong: wording. Ruling: the restic probe fails closed (an unreadable process table counts as "may be running") — same principle — cost if wrong: a truly dead agent with an unreadable process table waits for the user's Restart instead of auto-repairing. Re-review: all addressed.
Minor (deferred): short-wait view after an app relaunch shows the banner with no plan lines; the first 30 s of silence (before the grace) can still read "not running" with restic running.

## Post-merge finding (21 Nov 2026): updates and Task 7's requirement
Found installing build 836 over 835: for ~40 s the app couldn't talk to the old agent (unified log: "Received message forbidden due to code signing requirement"), showed "Backups aren’t running", then re-registered it undrained at the 30 s grace. Cause: an install replaces the agent's file while the old process runs; its signature then seals an Info.plist no longer on disk, so Task 7's requirement on the app's connection refuses it, and the app can no longer ask it to drain (`prepareForRestart`). The old agent noticed its replacement only at its next scheduler tick (60 s) or restic step, after the app's 30 s grace.
Fix (owner approved): the agent checks its executable every 5 s (`ReplacementWatch`, started after recovery) and restarts itself; the app classifies `NSXPCConnectionCodeSigningRequirementFailure` as `AgentHeartbeat.signatureRejected` → `waitForReplacedAgent` ("Updating Restorey’s background process…", no repair).
Review (opus): Important — a 240 s grace from the first refusal could re-register an agent still committing its run after a long step; Important — the restic probe misses a restic whose bundle was moved aside (verified: after `mv`, `proc_pidpath` reports the new location; after `rm -rf` + copy it keeps the old path); Minor — refused time carried into the 30 s grace for the new agent.
Ruling: a refused agent is never repaired automatically (no grace at all) — every agent since R55 restarts itself (5 s watch, or its 60 s scheduler tick), the probe can't be relied on to see its backup, and a non-update refusal survives re-registration anyway; from 30 awake minutes the menu warns (`waitForRunningRestic(longWait: true)` if restic may run, else `showNotRunning(canRepair: true)`), Restart Backups being the person's choice — cost if wrong: a refused agent that is truly wedged waits for the person for 30 minutes before being offered the restart.
Fixed: `AgentSilence` restarts the unreachable run when a refusal gives way to silence.
Minor (deferred): an old agent that is hung outright (times out rather than refused) after a move-aside install with restic running is missed by the probe and could be re-registered at the 30 s grace (pre-existing, R68); fix with a probe that doesn't depend on the bundle path.
