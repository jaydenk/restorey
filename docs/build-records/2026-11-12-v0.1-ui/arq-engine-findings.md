# Arq engine and agent findings for Restorey

Source: Arq 7.51 (`/Applications/Arq.app`). Evidence comes from `strings`, `nm -u`, `codesign -d --entitlements -` on ArqAgent, ArqMonitor and arqc, plus Hopper pseudo-code of the main `Arq` binary. ArqAgent is not loaded in Hopper, so agent behaviour below is inferred from its strings, imported symbols and class/method names. Where I could not read the logic, the confidence is marked medium or low. Nothing was executed, and no Arq user data was read.

Ideas only: nothing here is code to copy.

---

## 1. Bandwidth limit (top priority)

### What Arq does

- **It is a fixed rate in KB/s, per backup plan. It is not a percentage.**
  - Each plan has a `transfer_rate_json` column (alongside `thread_count` and `cpu_usage`).
  - The default dictionary (decompiled `-[BackupPlan defaultTransferRateJSON]`) has six keys. The key names, recovered from strings, are `enabled`, `maxKBPS`, `scheduleType`, `startTimeOfDay`, `endTimeOfDay` and `daysOfWeek`.
  - The default values are `enabled=NO` and `maxKBPS=100`.
  - The UI offers a schedule type of "Always" or "from..to", with default hint times of 08:00 and 17:00. The edit-plan controller has a checkbox per weekday (`throttleMon` to `throttleSun`), `throttleFrom`, `throttleTo`, `throttleAlways` and `throttleFromTo`.
  - That makes it a per-plan cap with one time-of-day window and a weekday mask. I found no separate "outside the window" rate, so outside the window the rate is unlimited.
- **Arq does not measure available or peak bandwidth to set the limit.**
  - I found no speed-test code and no "percent of link" logic.
  - There is an `_bpsSamples`/`_numBPSSamples`/`averageBPS` moving average. It sits in the transfer-statistics classes and looks like it feeds the displayed speed and ETA, not the throttle.
- **The limit is enforced inside the engine by pacing, not by the OS.**
  - `-[ConnectionSleeper sleepWithBytesTransmittedThisTime:httpThrottle:]` (Hopper, decompiled) works like a debt-based pacer. It remembers when the last send finished and computes how long the bytes just sent should have taken at the cap (bytes / KBPS / 1024). If the real elapsed time was shorter, it sleeps the difference. Any sleep overrun is carried forward, so the long-run average hits the cap without per-chunk jitter.
  - The throttle object (`HTTPThrottle`, `initWithType:kbps:`) is handed to the HTTP input stream (`HTTPInputStream initWithData:httpThrottle:`) and to the data-transfer delegate. It is applied to the request body, so it limits uploads.
  - The type field (`throttleType`) is compared against 2. I could not decode the meaning, but it is plausibly "none / fixed / reserved".
- **The cap is shared across worker threads.** The agent logs "throttle KBPS per thread: %ld" and "maximum transfer rate" just before "starting %ld backup thread(s)". So the plan limit is divided by the thread count.
- **It adapts while running, but only at schedule boundaries.**
  - The agent has `currentThrottleForTransferRateJSON:` and `earliestNextThrottleChangeForTransferRateJSON:`.
  - The second one returns the next moment the answer changes (window start or end). This lets a long-running backup re-read its limit when a window opens or closes, rather than fixing it at launch.
  - It does not adapt to measured network conditions.
- **There is no per-network throttle.** Network rules are on/off only (see section 4). The old Arq 5 import path carried a single `maxKBPS`. The 7.x model is the schedule above.
- **Units:** the internal and storage unit is KB/s (`maxKBPS`). The pacing maths implies a 1024 divisor, so it is KiB/s in practice. I did not find the UI label.
- **Disk I/O throttling is a separate, agent-wide setting.** `throttleDiskIO` (`/api/v1/throttleDiskIO`) uses `setiopolicy_np` ("set disk I/O policy to 'throttle'" or 'passive'). Plans also have a `cpu_usage` percentage (default 25).

### Evidence

- Hopper: `-[ConnectionSleeper sleepWithBytesTransmittedThisTime:httpThrottle:]` at 0x1000b14d0, `-[BackupPlan defaultTransferRateJSON]` at 0x100013678 and `-[HTTPThrottle initWithType:kbps:]` at 0x1000b1800.
- The `transfer_rate_json` column, in the `backup_plans` DDL string in ArqAgent.
- Strings: `maxKBPS`, `scheduleType`, `startTimeOfDay`, `endTimeOfDay`, `daysOfWeek`, "throttle KBPS per thread: %ld", `earliestNextThrottleChangeForTransferRateJSON:`.

### Comparison with Restorey

Restorey (spec lines ~168) has `--limit-upload` per plan plus a Mac-wide limit in Settings → Network. A networked backup gets `min(plan limit, Mac-wide limit / concurrent networked uploads at start)`, fixed for the whole run because restic cannot change it mid-run. This is already a superset of Arq's model, which has no Mac-wide limit and no division across concurrent plans. The two real gaps are time-of-day windows and mid-run changes.

### Recommendation

1. **Stay with a fixed rate in KiB/s. Do not add a percentage-of-link mode.**
   - Arq does not do one either.
   - Restic's `bytes_done / seconds_elapsed` is bytes scanned or processed from the source, not bytes uploaded. With deduplication and unchanged files it can be far above the real upload rate, so it is a poor basis for "peak throughput".
   - A percentage would need a measured upload ceiling, and that data is not in the status stream. If you ever want one, measure it deliberately (a timed, unlimited first upload to a networked repository, using total new data added over wall time) and let the user confirm it. I would not build it for v0.1.
2. **Add a time-of-day window to the Mac-wide limit, not to each plan.** A single window with a weekday mask is enough, and it matches what Arq has:
   - "Limit to N between 08:00 and 17:00 on these days; unlimited otherwise."
   - Evaluate it at run start, and also apply it in the budget calculation you already do ("divided by concurrent uploaders").
3. **For mid-run changes, restic cannot change `--limit-upload`.**
   - Cheap option: accept the start-of-run value (current behaviour) and tell the user in the Settings → Network help text: "The limit applies for the whole run."
   - Better option: let the agent stop and restart a long upload run at the window boundary. Run `restic backup` under a supervisor that sends SIGINT at the boundary and then relaunches with the new limit. Restic already uploaded the finished pack files, and the next run reuses them through deduplication (confirm this against current restic docs before relying on it). Arq's `earliestNextThrottleChange` is the same idea: compute the next change time and wake then.
   - I would ship the cheap option in v0.1 and note the restart option as a later enhancement.
4. **Units:** store KiB/s (restic's unit). Show the user Mbit/s or MB/s with live conversion text, for example "5 MB/s = 4,883 KiB/s". Arq's KB/s-only storage with no label I could find is the weaker design.
5. Note Arq's per-thread division. Restic has no thread-count parameter for uploads. `--limit-upload` is process-wide, so you do not need this.

Confidence: high on fixed-KB/s, per-plan, schedule JSON keys and the debt-pacer; medium on mid-run window re-evaluation (inferred from method names only) and on the throttle-type values; low on the UI unit label.

---

## 2. Unreadable files and default exclusions

### What Arq does

- **There is no "exit 3" equivalent that taints the whole run for ordinary unreadable files, but it does not hide them either.** Arq records per-file errors in the backup record (`BackupRecordErrors` window, `unreadable` flag on records, `_snapshotErrors`). Retention, thinning and budget enforcement are skipped when a run had errors:
  - "Errors occurred; not enforcing budget or removing unreferenced data".
  - "Removes older backups by its retention settings, but that was skipped at the last backup (%@) because the backup had errors."
  - This is a cautious design, and Restorey should copy the idea. Running `forget`/`prune` after a run with read errors risks pruning data that you could not capture.
- **It retries EPERM.** `localItemFSCallWithEPERMRetry` retries POSIX calls that return EPERM ("EPERM (attempt %d/%d), retrying", "EPERM resolved on attempt %d"). It also detects `NSFileReadNoPermissionError` that wraps EPERM. The retry targets transient permission denials (TCC prompts settling, cloud and file-provider timing). It does not make a SIP or datavault path readable.
- **It has built-in exclusion lists in the main binary** (all as strings, grouped):
  - Root-level: `/System`, `/bin`, `/sbin`, `/usr`, `/etc`, `/var`, `/private`, `/tmp`, `/cores`, `/dev`, `/home`, `/net`, `/mnt`, `/macOS Install Data`, `/.fseventsd`, `/.vol`, `/.DS_Store`, `/.VolumeIcon.icns` and similar.
  - Any-depth names: `.Spotlight-V100`, `.Trash`, `.Trashes`, `.TemporaryItems`, `.MobileBackups(.trash)`, `.DocumentRevisions-V100`, `.dropbox(.cache)`, `.hotfiles.btree`, `Backups.backupdb`, `Cache`, `Caches`, `DerivedData`, `node_modules`.
  - Home-relative: `Library/Caches`, `Library/Biome`, `Library/VoiceTrigger/SAT`, `Library/Metadata/CoreSpotlight`, `Library/Developer`, `Library/Mirrors`, `Library/PubSub/*`, Safari icon/favicon caches and history index, the Mail envelope index files and "Mail Downloads", `Containers/com.apple.mail/Data/DataVaults`, `Application Support/MobileSync/Backup`, `CrashReporter`, `Dropbox`, `Google`, iTunes media downloads and podcasts, and a LaunchServices template.
- **Nothing about `group.com.apple.CoreSpeech` or `DuetExpertCenter`.** No string matches either. Arq's only nearby entries are `Library/Biome` and `Library/VoiceTrigger/SAT`. So Arq does not solve the exact paths Restorey hits: it would simply report those as errors.
- **It also honours Time Machine's exclusions.** It reads `/Library/Preferences/com.apple.TimeMachine.plist` (`ExcludeByPath`, `SkipPaths`) and the per-item exclusion attribute (`NSURLIsExcludedFromBackup`). The plan option is `skipTMExcludes`.
- **It removes `/Volumes` from all-drives plans** ("removing '/Volumes' exclude rule from all-drives backup plan"), then handles external drives through its volume enumeration instead (include-new-volumes, excluded drives, volume-unmounting aborts).
- **Cloud-only (dataless) files have a three-way policy** (plan option `datalessFilesOption`): report as errors, ignore, or materialise. The ignore mode logs a count: "Skipped %@ dataless (cloud-only) file(s) because...". Materialising is done by setting the thread I/O policy for `IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES`. A separate `arqevicter` helper evicts files again afterwards.
- **Full Disk Access is detected by trying to open a protected file.** `+[FullDiskAccess granted:]` opens `/Library/Application Support/com.apple.TCC/TCC.db`; the log line is "full disk access is granted because we successfully opened %s". The agent exposes it at `/api/v1/fullDiskAccessGranted`, and the backup log says "Arq does not have full disk access..." and aborts.

### Evidence

Strings in `Arq` (main binary) between the `ignoredRelativePaths`, `wildcardExcludes`, `regexExcludes` and `skipTMExcludes` property names and the lists above. Agent strings listed in quotes above. `BackupPlan.datalessFilesOption`, `BackupPlan.skipTMExcludes`.

### Suggestion for Restorey

- Restorey already excludes the two EPERM paths from its own survey (`FileProvider/*/wharf` and `group.com.apple.secure-control-center-preferences`). Add `group.com.apple.CoreSpeech` and `Library/DuetExpertCenter` to the same list, by verifying them with the same survey method (run once with FDA, record EPERM). Arq gives no help on those two.
- **Copy the "skip prune when there were read errors" rule.** Only run `forget`/`prune` after a run that finished with exit 0, or exit 3 where every error is on a path in a known-benign list. If Restorey currently prunes after exit 3, this is the safest improvement from this research.
- **Make the "N files couldn't be read" warning smarter.** Classify errors by path against the known-benign EPERM list (SIP and datavault paths). When all read errors are benign, show "Finished" with a quiet note, not a warning that appears on every run. Reserve the warning for new, unexpected paths.
- **Probe FDA the way Arq does:** open one genuinely protected file from the agent's own process. The spec already says the agent probes a protected directory. Use a file open of `TCC.db` as a second signal, since that is a very stable check, but verify it still works on macOS 27 before relying on it.
- Consider a per-plan three-way cloud-file policy only if users ask. Restorey's `--exclude-cloud-files` default plus a skipped-count status is simpler and mostly equivalent.
- Honour Time Machine's per-item exclusion attribute, which Restorey's list already mirrors. No change needed.
- Consider a short bounded retry (2 to 3 attempts) for EPERM only if you see flaky, non-repeatable EPERM errors. I would not add it. Restic reads files once, and a retry of a whole run costs more than the error is worth.

Confidence: high on the exclusion lists, the FDA probe and the skip-retention-on-errors behaviour; medium on EPERM-retry purpose (logic not read); high that CoreSpeech and DuetExpertCenter are absent from Arq.

---

## 3. Consistency (APFS snapshots)

### What Arq does

- **Yes. Arq backs up from a frozen APFS snapshot by default where it can.**
  - The agent has the entitlement `com.apple.developer.vfs.snapshot` and imports `fs_snapshot_create`, `fs_snapshot_delete`, `fs_snapshot_list` and `fs_snapshot_mount`.
  - Classes: `APFSSnapshotFactory` and `APFSSnapshot`, with `BackupRunner apfsSnapshotForVolume:`.
  - Plan column `use_apfs_snapshots`. Log lines: "backup folder %@: start using APFS snapshot if available", "created APFS snapshot", "Removing APFS snapshot for %@", "Removed APFS snapshot".
  - The snapshot is mounted under `/Library/Application Support/ArqAgentAPFS.noindex/` (and a Pro variant) and read from there. One lock serialises create and delete. A bounded retry exists ("again creating APFS snapshot...").
  - **Fallbacks and failure modes:**
    - If the snapshot is unmounted by another process, the run aborts with "Aborted because our APFS snapshot was unmounted by another process (this may be caused by insufficient disk space)".
    - Dataless (cloud-only) files are read live, bypassing the snapshot ("SF_DATALESS detected on %@; reading live (bypassing APFS snapshot)").
    - Snapshots are deleted at the end of the run, and a startup path cleans leftovers (`lockedDeleteAllSnapshotsForMountedVolumes:`).
  - It does not shell out to `tmutil localsnapshot`. It uses the `fs_snapshot_*` C API, which needs the Apple-granted restricted entitlement. The only `tmutil` use is `addexclusion` on its own cache directory.

### Suggestion for Restorey

- **This is not reachable with a plain restic child process.** `fs_snapshot_create` requires `com.apple.developer.vfs.snapshot`, a restricted entitlement that Apple grants on request and that must be in the provisioning profile. Restorey, as an open-source app signed by its owner, would have to apply for it. Without it, `tmutil localsnapshot` plus `mount_apfs -s` is an alternative:
  - `tmutil localsnapshot` needs no entitlement but needs admin rights for some operations on some macOS versions, and mounting a snapshot read-only with `mount_apfs -o rdonly,nobrowse -s <snap> <volume> <dir>` needs root.
  - I did not verify that on macOS 27. Verify against Apple's docs and by experiment before committing.
- If it is feasible, the design would be: create the snapshot, point restic at the mounted snapshot path, and pass `--host`/`--tag`/`--group-by` as now. Note the path changes the snapshot's `paths` field, which breaks Restorey's grouping and parent-snapshot matching (restic picks the parent by host plus paths). Restic's `--group-by` ignores that only if you override the path with something stable. This is a real design cost, and it is the reason I would defer snapshots beyond v0.1.
- Worth stating in the user docs: Restorey reads live files, so a file changing mid-run can be inconsistent. Mitigation: restic's own change-detection, and `--skip-if-unchanged`.

Confidence: high that Arq uses `fs_snapshot_*` with the vfs.snapshot entitlement; high on lifecycle details; low on the `tmutil`/`mount_apfs` alternative for Restorey (not verified).

---

## 4. Scheduling and power

### What Arq does

- **Daemon architecture:** the agent runs as a root LaunchDaemon (`/Library/LaunchDaemons/<id>.plist`), and ArqMonitor (the menu bar app) runs as a per-user LaunchAgent (`/Library/LaunchAgents/com.haystacksoftware.ArqMonitor.plist`). The uninstall path unloads both with `launchctl`. The main app talks to the agent over a local HTTP API (`/api/v1/...`), not XPC.
- **Schedule engine.** The plan's `schedule_json` supports manual, hourly (every N hours, minutes after the hour, optionally per weekday), and daily at a time (optionally per weekday). `+[BackupPlanSchedule nextScheduledBackupDateForScheduleJSON:backupPlanCreationDate:lastSessionEndDate:]` computes the next fire time from the last session's end, so a missed run is detectable. A single timer is armed for the earliest next date ("scheduling a timer for %@ to check backup schedules again"). On wake the agent logs "computer woke up; checking backup schedules" and re-evaluates. This is the same catch-up model the Restorey spec describes (anacron-style).
- **Sleep/wake.** `IORegisterForSystemPower` handles sleep (`-[ArqServer systemWillSleep]`) and wake. It calls `IOAllowPowerChange` when it is safe to sleep.
- **Wake to back up.** `wake_for_backup` plan option. It uses `IOPMSchedulePowerEvent`, `IOPMCopyScheduledPowerEvents` and `IOPMCancelScheduledPowerEvent` ("scheduled auto-wake event for backup %ld at %@", "canceled power event for backup"). That requires root. Restorey's user-level agent cannot do this (see below).
- **Prevent sleep during a run.** A `NoIdleSleep` helper takes an IOPM assertion ("asserted no-idle-sleep", "Preventing computer sleep while backing up"), controlled by the `prevent_sleep` plan option.
- **Battery.** `pause_on_battery` plan option. It checks `IOPSGetProvidingPowerSourceType` (AC vs battery) and stops the run with "Paused while on battery power". There is **no battery-percentage threshold and no Low Power Mode check** (I found no `lowPowerMode` string). Restorey's below-N-percent threshold is already richer.
- **Network rules.**
  - `preventBackupOnConstrainedNetworks` and `preventBackupOnExpensiveNetworks` are plan options, passed down into every network request as `allowConstrainedNetworkAccess:` and `allowExpensiveNetworkAccess:`. This is the URLSession/`NWPath` mechanism (Low Data Mode and hotspot), enforced per request, not only at start. A log line says "Computer is connected to an expensive network and 'Prevent backup on expensive networks' was checked in the backup plan."
  - Per-plan allow or deny lists for network interfaces (`excluded_network_interfaces`) and Wi-Fi names (`excluded_wifi_network_names`, plus an "included" list). The Wi-Fi name comes from `CWWiFiClient` through the main app ("requesting wifi network name from delegate"), is cached, and a stale cache is ignored ("ignoring cached WiFi SSID; too old"). The agent needs Location Services to read the SSID, and the app explains this to the user ("Arq needs Location Services enabled so it can retrieve the current WiFi network name...").
  - `SCNetworkReachability` watches the storage host, with a "storage location reachable" precheck.
- **Pause windows and manual pause.** `pause_during_window` with `pause_from`/`pause_to`, a `manualResumeDate` ("Paused until %@") and `pauseAllBackupJobs`/`resumeAll` API calls. Pause reasons are stored on the activity (`pause_reason` column), so the UI can say why a run is paused.
- **Volume handling:** "volume %@ is unmounting; abort backup": it watches for unmounts mid-run and stops cleanly. Unmounted source folders are skipped with a message, not failed.
- **Preflight and postflight scripts** per plan (`preflight_script`, `postflight_script`). Log lines: "script returned exit code %d", "postflight script error: %@". I did not decode whether a non-zero preflight aborts the run.
- **Full Disk Access:** see section 2.

### Suggestions for Restorey

- **Wake to back up is the one Arq feature Restorey cannot match from a per-user launchd agent.** `IOPMSchedulePowerEvent` needs root. Do not promise it. Offer "back up soon after the Mac wakes (Power Nap and DarkWake permitting)" and document the limit. If the owner wants real wake scheduling, it needs a privileged helper (SMAppService daemon), which conflicts with the "no sudo" posture; or tell users to set a schedule in System Settings → Energy ("Schedule" or `pmset repeat wakeorpoweron`).
- **Per-request network enforcement is worth a thought.** Arq lets URLSession refuse expensive or constrained networks mid-run. Restic cannot. Restorey's check at start is correct, but add a re-check while the run is going. If the Mac moves onto a hotspot mid-upload, the agent could stop the run (SIGINT, as above) and retry later. This costs little with `NWPathMonitor` (constrained and expensive flags) and fills the gap restic leaves.
- **Record the pause reason** on every skipped or paused run (Arq stores it in `activities.pause_reason`) and show it in the menu. Restorey's spec has the reasons, but make sure each is persisted per run, not only shown live.
- **Unmount handling:** watch `NSWorkspace.didUnmountNotification` for the plan's source volumes and stop the run cleanly. The spec already skips plans whose volume is not mounted before starting. A mid-run unmount handler is the missing half.
- **Location Services copy:** Arq's explanation text is a good model for the Settings → Network prompt: say exactly why (reading the Wi-Fi name), and ask only when the first name is added. Restorey already does this.
- **Scripts:** if you add preflight and postflight hooks later, define up front that a non-zero preflight skips the run and records the reason. Arq's behaviour is unconfirmed, so treat this as a design choice, not a copied one.

Confidence: high on IOPM calls, `IORegisterForSystemPower`, `NoIdleSleep`, AC-only battery check and the daemon plus agent layout; medium on the HTTP-API control channel details and on how often the schedule timer is re-armed; high that no Low Power Mode check exists in the agent (string and symbol searches found none).

---

## 5. Other techniques

| Technique | What Arq does | Evidence | Suggestion | Confidence |
|---|---|---|---|---|
| Budget enforcement | Plan `budget_gb` (and `budgetDollars`). A `BudgetEnforcer` deletes the oldest backup records until the repository fits. It never runs after an errored backup. | `BudgetEnforcer.m`, `BackupPlan.budgetGB`, "Errors occurred; not enforcing budget..." | Restorey's `forget` runs by retention rules only. A budget would need `restic stats` plus a loop of `forget` and `prune`. Not for v0.1. Keep the "skip after errors" guard from section 2 regardless. | high |
| Thinning | `BackupRecordThinner` applies retention (hourly, daily, weekly, monthly, "keep all") per plan, with an activity log for each step. It runs as a separate activity from the backup. | `BackupRecordThinner.m`, `retain_*` columns, "Thinning/budget enforcement activity started" | Restorey already separates `forget` from backup and uses `--group-by host,paths,tags`. Showing thinning as its own named activity in History (start, end, count removed) matches Arq and is cheap. | high |
| Separate activities | Backup, validation, thinning/budget and cleanup are four named activities, each with start and end log lines. | Agent log strings | History pane: one row per activity type, not only per backup run. | high |
| "No backups for N days" alert | `NoBackupsAlerter` fires after N days with no successful backup, configured per plan (`no_backups_alert_days`). | `NoBackupsAlerter.m`, `arqServerBackupPlanNoBackupsForDays` | Restorey delegates this to healthchecks pings, with a re-notify back-off. A local in-app version is a useful safety net for users who skip healthchecks. | high |
| Data validation | Periodic validation activity re-checks stored data (`data_validation_interval_hours` in the legacy plan, `valid` flags on blobs). | Schema strings | Restorey's weekly test-restore plus `restic check --read-data-subset` covers this. | medium |
| Filesystem events for incremental scans | A `ChangedDirSet` built from file-system events tells the scanner which directories changed, with a full-scan fallback ("timed out waiting for file system events; full scan needed"). | Agent strings | Restic always walks the tree. An FSEvents-based "nothing changed since last run" pre-check could skip a run entirely, as a stronger form of `--skip-if-unchanged`. Real gain only for large trees. Defer. | medium |
| Disk I/O and CPU politeness | `setiopolicy_np` throttle or passive for the agent, plus a per-plan CPU percentage. | `throttleDiskIO`, `cpu_usage` | Launch restic with `taskpolicy -b` (background QoS and I/O throttle) or `nice`. Restic has no CPU option beyond `GOMAXPROCS`. Cheap and effective for laptop users. Verify `taskpolicy` flags in the man page first. | medium |
| Config change history | A `backup_plans_history` table keeps every prior plan config (and a diff check, "BackupPlan.X not equal"). | Schema and diff strings | Useful for a "what changed in this plan" audit trail in History. Low priority. | high |
| Atomic and resumable uploads | Large uploads create a session first and finish atomically, with retry per operation ("not retrying"/"retrying" log pairs). | Agent strings | Restic handles this in the backend layer. Nothing to add. | medium |
| Immutability and ransomware window | "Immutability: latest backup record immutable for N days, refreshed every N days" (object-lock style). | Agent log string | Restic has no equivalent in the app. Mention that S3 object lock needs the repo to be set up outside Restorey. Not a v0.1 feature. | medium |

---

## Priority list for Restorey (my opinion)

1. Skip `forget`/`prune` after a run that had unexpected read errors. Cheapest, safest, copied from Arq's rule.
2. Classify exit-3 errors against the known-benign EPERM list, so the "couldn't be read" warning stops appearing on every run. Add CoreSpeech and DuetExpertCenter to the exclusions after verifying them.
3. Bandwidth: keep fixed KiB/s. Add the optional time-of-day window to the Mac-wide limit. Do not build a percentage mode.
4. Re-check constrained and expensive network state mid-run with `NWPathMonitor`, and stop the run if it changes.
5. Run restic under `taskpolicy -b` for background QoS.
6. Defer APFS snapshots (entitlement and path-grouping cost) and wake-to-back-up (needs root).
