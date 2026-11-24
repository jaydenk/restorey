# Visual polish: rulings and deferred minors

Copied from the build ledger when the branch finished (24 Nov 2026). Each ruling is a decision taken on the owner's behalf, with its cost if wrong; each deferred minor waits for the polish batch.

## Rulings

- Ruling: accept the app build being red between T1's and T2's commits — T1 is RestoreyCore-only and verified by swift test; T2 restores the build — cost if wrong: a bisect across that commit hits a non-building app.
- Ruling: accept the T2→T3 interim without a Network close question — T3 removes Network's unsaved state entirely within the same branch — cost if wrong: none after T3.
- Ruling: keep T3's weak refusal test, and tell the implementer commit() must not mutate saved — cost if wrong: trivial.
- Task 2: Ruling: user text that sends people to plan things now in the main window stops saying "Settings": banner action "Show in Settings…" → "Show Plan…"; ScheduleView "Show Recovery Kit… in Settings" → "Show Recovery Kit… in the plan’s Overview"; SetupWindow "in Settings or another window" → "in Restorey’s window or another one"; PasswordView "turn pruning on in Settings" → "turn pruning on in the plan’s Retention tab" — after the split "Settings" means the preferences window, so these would send people to the wrong window — cost if wrong: wording churn the owner can change in the live look. Goes into Task 2's fix round.
- Task 2: Ruling: switching to History with unsaved plan edits asks nothing; the edits stay in the main window's editor slot (today's behaviour) — the spec's "the plan editor is unchanged" is the intent, and its "switching to History" clause was written on a wrong belief about today's code; spec wording amended in the fix round — cost if wrong: one extra question to add later.
- Task 2: Ruling: confirmed gap — "Turn On Notifications…" banner must open Settings ▸ Notifications as well as System Settings (spec §1 Routing: a banner's fix opens the Settings pane it names) — enters fix round 1.
- Task 3: Ruling: finding 3 — replace the weak test by moving the refusal and in-flight merge rules into RestoreyCore with real tests: NetworkEdit.didRefuse() (toggle/picker groups go back to saved, text groups keep the typed value) and NetworkEdit.didSave(_:sent:) (restore only groups edited during the flight) — the spec's "the setting stays as saved" must be what the control shows, and the common context puts such decisions in RestoreyCore — cost if wrong: a little more code in NetworkEdit.
- Task 3: Ruling: the re-review's unverified Important (DatePicker may not report focus/onSubmit, so a time edit might never send) is checked first thing in Task 10's live look, and fixed there if it fails — it can only be settled in a running UI, the app has no UI tests, and the failure is loud (the time visibly doesn't apply) not silent data loss — cost if wrong: one fix during the live look.
- Task 5: Ruling: accept per-plan queued event chain in AgentState instead of the brief's fire-and-forget Task — two Tasks could reorder and leave a stale "Backing up" next to a failure; the runner still never waits on the notification centre — cost if wrong: none.
- Task 5: Ruling: accept a separate authorisation key for the event path — sharing the alert round's key dropped events — cost if wrong: one extra bounded authorisation call.
- Task 5: Ruling: the times in started/finished bodies use the menu's DisplayFormat.time (follows the Mac's 12/24-hour setting; the owner's menu shows 09:35), not UploadLimitText.timeText — the plan's "9:19 am" was illustrative and the two places must agree — cost if wrong: trivial. Enters the fix round with the review's findings.
- Task 5: Ruling: started and finished notifications post without a sound (problem alerts keep the default sound) — they are opt-in status updates that fire hourly; a ding every hour works against "calm" — cost if wrong: owner can ask for sound in the live look. Enters the fix round.
- Task 5: Ruling: any backup end that posts no "Backed up" (failure verdict, cancelled, paused, stopped by the system, locked) removes the plan's "event.<id>" notification, and recovery that marks a backup interrupted after a crash calls noteBackupEnded too — the spec's purpose is "a stale 'started' never sits next to the failure", and a stale "Backing up" after any end is the same defect — cost if wrong: a "Backing up" disappears that someone wanted to keep (unlikely). Enters fix round 1 with the time and sound rulings.
- Task 5: Ruling: load-error notification ignores Problems — config can't be read in that state, so the setting is unknown; posting is the safe direction (anti-goal: losing a failure) — cost if wrong: one notification while Problems is off and config is broken.
- Task 5: Ruling: with Backup finished off, a successful backup's 'Backing up' is also removed at its end — the backup is no longer running, so a lingering 'Backing up' would be wrong — cost if wrong: none (implementer read ruling 3 literally; confirmed).
- Task 8: Ruling: fix at the comparison, not the form — add `Repository.isSameLocation(_:)` in RestoreyCore (both local → compare standardised localFolderPath; otherwise ==), tested, and use it for `sameRepository` in SetupModel+Storage.check() — the defect is two spellings of one folder comparing unequal — cost if wrong: trivial. Fix round 1.

## Deferred minors

- Task 1: minor (deferred): shellOpeningAtLaunch doc comment could say Settings opens on General
- Task 2: minor (deferred): SectionToolbar shared by both windows lives in SettingsWindow.swift; own file would be clearer
- Task 2: minor (deferred): SettingsContext now serves both windows; name misleads
- Task 2: minor (deferred): GeneralActionRunner also serves Notifications; name/doc
- Task 2: minor (deferred): NotificationsPane repeats GeneralPane's didBecomeActive refresh (Task 6 rewrites)
- Task 2: minor (deferred): PlanRunnerTests.twoBackupsOnAnUnmeasuredNetworkShareOneTest flaked under load ~24 (eventually{callersWaiting == 2})
- Task 3: minor (deferred): clicking a switch while the limit field is mid-edit sends the partial amount (valid values)
- Task 3: minor (deferred): local problems stored in saveError can show stale after retyping
- Task 3: minor (deferred): no in-flight indicator in the normal case
- Task 3: minor (deferred): NetworkEdit.request() now only used by tests
- Task 3: minor (deferred): a time edit can stay uncommitted if the pane closes while a picker has focus
- Task 3: minor (deferred): a connection drop mid-time-edit shows a refusal sentence for that change
- Task 3: minor (deferred): didRefuse tests don't assert windowEnabled/windowDays revert or in-flight window/limit groups
- Task 4: minor (deferred): no test for a partial notifications object in ConfigFile (per-key defaults covered in NotificationSettingsTests)
- Task 4: minor (deferred): TDD process — no RED run observed (tests meaningful)
- Task 5: minor (deferred): a started post hung past the timeout can surface after its removal (needs a >10 s notification-centre hang)
- Task 5: minor (deferred): doc drift — outstandingNotifierCalls keys and knownNotificationAuthorisation docs
- Task 5: minor (deferred): aHungNotifierHoldsEventsUpOnlyByTheTimeout would hang rather than fail on regression; doesn't check the finished post after a timed-out started
- Task 5: minor (deferred): DisplayFormat.time is always 24-hour ("Hmm"), so wording claiming it follows a 12-hour Mac setting (ruling/README) may need softening
- Task 5: minor (deferred): a later cancelled/paused backup's removal also takes away the previous "Backed up" (intended by the ruling)
- Task 5: minor (deferred): a hung started post makes the finished post skip while its post.event key is held (bounded)
- Task 6: minor (deferred): misplaced doc comment in SettingsGeneralTests (new test inserted under notifications()'s comment)
- Task 6: minor (deferred): failure while a newer change is queued drops it; a 60 s transport timeout is treated as a refusal
- Task 6: minor (deferred): two quick switch-ons can call requestNotificationPermission twice (macOS prompts once)
- Task 6: minor (deferred): section header "Notifications" repeats the pane title; throwaway model on parent re-init
- Task 7: minor (deferred): Wi-Fi popover keeps old newName/problem/note when reopened (FileTypesEditor clears)
- Task 7: minor (deferred): removing N Wi-Fi names sends N saves; one failure doesn't stop the rest
- Task 7: minor (deferred): redundant isEnabled in FileTypesEditor canRemove; stale "Remove button" comments in SourcesEditor; BorderedList initialiser boilerplate
- Task 8: minor (deferred): PlanEdit.storageKind maps local raws to .other (only S3 key labels use it); doc comment or .folder
- Task 8: minor (deferred): README paragraph reflow and one curly vs straight apostrophe
- Task 8: minor (deferred): switching Other → Folder or Drive doesn't carry a typed local path
- Task 8: minor (deferred): keepsSavedSecrets still compares with == (no effect for folders)
- Task 9: minor (deferred): Network help button sits inside the disabled region, so it's disabled while not connected
- Task 9: minor (deferred): README long-wait sentence wrapping and wording
- Task 9: minor (deferred): long-wait status-item tooltip now vaguer ("Restorey — No answer for 30 minutes"); could use the banner detail
- Task 9: minor (deferred): theLongWaitBannerIsShort's first two assertions check a constant against itself
- Final: minor (deferred): ⌘Q with Settings open may skip windowWillClose, so a pending Network time could still be lost on quit.
- Final: minor (deferred): no test covers two plans' notifications at once (review focus 4 passes by construction).
- Final: minor (deferred): settings-can't-be-read banner's button says "Show Plan…" though the problem covers all plans.
- Final: minor (deferred): help-button README anchors only resolve once the branch is on GitHub's main; recheck after push.
- Final: minor (deferred): flaky PlanRunnerTests.twoBackupsOnAnUnmeasuredNetworkShareOneTest needs a dated ticket.
