# Arq UI findings for Restorey

Source: Arq 7 (ArqMonitor 7.51) app bundle and Hopper (document "Arq", read-only). Ideas and concepts only. No Arq code, assets or copy are to be reused. Short quoted labels below are for identification.

Evidence key: NIB = strings in `/Applications/Arq.app/Contents/Resources/<Name>.nib`; HELP = `ArqHelp.help/.../English.lproj/<page>.html`; Hopper = symbol or string in the Arq binary (addresses given where useful).

---

## 1. Bandwidth limit

### What Arq does

- **One limit per backup plan**, set in the Edit Backup Plan window, in a section titled "Network" (NIB `EditBackupPlanWindowController`). There is no global Mac-wide limit in Preferences. Preferences has only a separate "Throttle disk I/O" control (NIB `SettingsWindowController`, Hopper `-[SettingsWindowController setThrottleDiskIO:error:]`, agent route `/api/v1/throttleDiskIO`). That one is about disk reads, not upload.
- **Control layout** (from nib label strings and binding names):
  - a checkbox, "Limit transfer rate to", bound to `throttle`;
  - a numeric text field bound to `throttleKBPS`, with the fixed unit label "KB/s" beside it;
  - two radio buttons: "Always" (`throttleAlways`) and "From" (`throttleFromTo`) with two time-of-day fields (`throttleFrom`, `throttleTo`);
  - seven day-of-week checkboxes (`throttleMon`..`throttleSun`), enabled only when "From" is chosen (binding `enabled: throttleFromTo`).
  - Validation message in Hopper: "Invalid transfer rate time of day".
- **Units**: a single fixed unit, KB/s, an unsigned integer (`throttleKBPS` is `TQ`, unsigned 64-bit). There is no MB/s or Mbps option and no unit picker.
- **Not a percentage of measured speed.** No such control exists. `HTTPThrottle` is built from `initWithType:kbps:` and holds only a type and a KB/s number.
- **Enforcement**: `-[ConnectionSleeper sleepWithBytesTransmittedThisTime:httpThrottle:]` (0x1000b14d0). After each chunk it computes the time the chunk should have taken (bytes divided by the KB/s cap) and sleeps for the shortfall against the elapsed time. That is simple pacing. It is applied inside the HTTP upload stream (`-[HTTPInputStream initWithData:httpThrottle:]`), so the cap is on the upload only.
- **Schedule is separate from throttle.** The plan's Schedule section has its own "Pause backup between [from] and [to]" window (`pauseDuringWindow`, `pauseFrom`, `pauseTo`). So Arq distinguishes "slow down during work hours" (throttle schedule) from "do not run at all in this window" (pause window).
- **Per network**: separate from the rate limit. The same section has "Network interfaces:" with Include/Exclude, "WiFi networks:" with Include/Exclude and an Add.. button, "Prevent backup on expensive networks" and "Prevent backup on low data mode networks". Saving a plan whose Wi-Fi list would exclude every network asks "You've configured the backup plan so it can't use any WiFi network. Do you want to save anyway?" (Hopper 0x10020c0d5). HELP `createBackupPlan`: "limit network throughput during backup, either all the time or during a window on certain days of the week. This is useful for limiting network usage during the work day while allowing full upload outside of work hours."
- **Measuring or showing speed**: I found no upload-speed readout in the UI strings. The activity text is built by `-[MainWindowController progressDescriptionForActivity:progressPercent:isIndeterminate:]` (0x10006a900) from bytes scanned, files, and "uploaded <size>", for example "Scanned X of Y (n of m files), uploaded Z", with a percentage bar. No "/s", no ETA, no peak speed. There is a `NetMonitor` class (`-[NetMonitor sample:]`, `averageBPS`) that reads the Mac's network byte counters via sysctl and keeps a 4-sample average, minus a small noise floor. Its caller is only in a method table, so I could not confirm what uses it. It may feed backoff logic in the agent. Treat as unknown.

### Evidence summary

NIB `EditBackupPlanWindowController` (labels, bindings); Hopper `HTTPThrottle`, `ConnectionSleeper`, `-[EditBackupPlanWindowController throttleKBPS]` family (0x1000a7c7c to 0x1000a7e28), `-[BackupPlan transferRateJSON]` (0x100013a44), string "Invalid transfer rate time of day" (0x10020bfcd).

### Assessment against Restorey

Restorey (spec 6.3, README "config.json") already has a Mac-wide limit plus a per-plan limit, divided among concurrent networked backups, with Wi-Fi skip and constrained/expensive skip. That is ahead of Arq on sharing and on honesty about restic not changing the limit mid-run. Arq is ahead on two things: a time-window schedule for the cap, and the day-of-week selection.

### Recommendation

1. **Store KiB/s (restic's `--limit-upload` unit); let the user type in the unit they know.** Arq's bare "KB/s" integer is the weakest part: ISPs quote megabits, so users must convert by hand and often get it wrong by 8x. Suggest a number field plus a unit pop-up: `Mbit/s`, `MB/s`, `KiB/s` (default Mbit/s for home users), with a live caption under the field, for example "About 1.2 MB/s (1,220 KiB/s)". The unit label should say what restic does (KiB, 1024). Confidence: high that this is better than Arq; medium on the exact default unit.
2. **Do not copy a "percentage of measured speed" idea.** Arq doesn't do it, and measuring a link reliably is a source of surprise. If anything is added later, a one-shot "Test my upload speed" helper that only suggests a number, which the user then accepts, is calmer than auto-tuning. Confidence: medium (design opinion).
3. **Schedule (optional, post v0.1):** copy the idea, not the layout. "Limit all the time" or "Limit only during [time] to [time] on [days]", with a second value outside the window ("Outside that, use [no limit]"). Arq has only "limit inside window, unlimited outside". Because restic can't change the limit mid-run, the agent should pick the limit at start (as Restorey already does for sharing) and show the consequence in plain words: "A backup that starts at 8:55 am keeps its limit until it finishes." This is an important honesty point Arq doesn't need, because it enforces the cap itself. Confidence: high that the windowed schedule is useful; high that the start-time caveat must be stated.
4. **Keep "pause window" and "limit window" as separate concepts** if both ever exist, as Arq does. Confidence: medium.
5. **Display**: since restic's `--json` output reports `bytes_done`, `total_bytes`, and seconds elapsed, Restorey can show a live "uploading at about N Mbit/s" line in the menu while backing up, something Arq's UI doesn't show. This would also let a user see whether the cap is working. Confidence: medium (feasibility depends on restic's progress granularity; I did not verify restic output).
6. Per-network precision: Arq lets Wi-Fi be include or exclude, per plan. Restorey's Mac-wide exclude list is simpler and enough for v0.1. The save-time warning when the list makes backups impossible is worth copying if Restorey ever adds an "only on these networks" mode. Confidence: high.

---

## 2. Screen inventory and what is worth borrowing

### 2.1 Main window: source list with BACKUP and RESTORE sections
- **What Arq does**: left sidebar with two headed groups, "BACKUP" (active plans) and "RESTORE" (storage locations, expanding to backup sets, then to backup records by date/time). The right pane is a detail view that changes with the selection (backup plan, storage location, backup set, backup record, activity, activity with errors). Evidence: HELP `restore` (describes both), Hopper properties `backupPlanDetailView`, `storageLocationDetailView`, `backupSetDetailView`, `backupRecordDetailView`, `activityDetailView`, `activityWithErrorsDetailView`.
- **Suggestion**: Restorey's v0.2 restore window could follow "plan, then snapshot, then files", but avoid exposing a "backup set" tier. The Arq glossary shows how much vocabulary this costs ("backup set", "backup record", "adopt", "detach", "storage location"). Keep restic's word "snapshot" or a plainer "backup from 3 Nov, 9:02 am". Confidence: medium.

### 2.2 "Restore from the active plan" shortcut
- **What Arq does**: on a backup plan, a Restore… button jumps to the latest backup record in the restore tree (HELP `restore`). A separate FindBackups window says "Select a folder to view the latest backup record:" with "Show Latest Backup Record" (NIB `FindBackupsWindowController`): pick a folder, see its latest version.
- **Suggestion**: for v0.2, "Show me this folder's latest backup" is a calmer entry point than a snapshot list. Confidence: medium.

### 2.3 Restore destination sheet
- **What Arq does**: "Restore to:" with "Original location" or "Other location" plus "Choose Location...", and one checkbox "Overwrite existing files" (NIB `SelectRestoreDestinationWindowController`). Drag-and-drop from the backup view to Finder also restores (HELP `restore`). The overwrite rule is spelled out: files with different modification time or size are replaced.
- **Suggestion**: copy the minimal option set, and default to a new folder rather than the original location for safety, with the overwrite rule written in a caption. Confidence: high.

### 2.4 Backup plan editor
- **What Arq does**: one window with named sections as a long scroll or tabs, in this order (NIB strings): Files (all drives vs specific folders, exclusion rules, Import/Export of rules), Schedule (Hourly/Daily/Weekly/"Not scheduled", "Also start backup when a volume is connected", "Last backup ended at:", "Next backup starts at:", pause window), Network (see 1), Retention ("Thin backup records as they age", hourly/daily/weekly/monthly keep counts, "Limit storage used to", note "Arq keeps at least 1 backup record no matter the budget setting"), Report (email), Options, Encryption, Immutable.
- **Evidence**: NIB `EditBackupPlanWindowController`; HELP `createBackupPlan`.
- **Suggestion**: the "Last backup ended at / Next backup starts at" pair directly inside the schedule editor answers "did my schedule save correctly" without leaving the form. Restorey's plan Schedule tab could show the next run time as a caption. The retention explanation, with a worked example in HELP ("keep hourly for 24 hours, daily for 30 days..."), is a good pattern for explaining restic's `forget` policy in words. Show a one-line plain summary of the policy under the controls. Confidence: high.

### 2.5 Options worth noting
From NIB: "Pause backup while on battery power", "Prevent computer sleep during backup", "Wake computer at backup time", "Alert if no successful backups for [N] days", "Show notifications when backup finishes", "Maximum CPU usage:", "Include list of uploaded files in activity logs and email reports", "Use filesystem snapshots for APFS volumes (except cloud files)", "Keep deleted files in subsequent backup records", before/after scripts.
- **Suggestion**: "Alert if no successful backups for N days" is already in Restorey's menu ("No successful backup in N days"). A CPU-use control is the one Arq option Restorey lacks; consider mapping it to a plain "Low / Normal" priority choice (nice/QoS) rather than a number. Confidence: low-medium.

### 2.6 Storage-location setup flow
- **What Arq does**: File menu, New Storage Location…, a list of provider types, then one dedicated window per provider (`AddS3StorageLocationWindowController`, B2, GCS, SFTP, Wasabi, Storj, Filebase, Tencent, MEGA S4, S3-compatible), then an "Enter storage location name" window, with separate "Edit…Params" windows per provider. There is also an OAuth authorise window for Google/Dropbox. Evidence: nib file list. New plan creation then asks only "choose your storage location", "choose an encryption password", and "choose which files" (HELP `createBackupPlan`).
- **Suggestion**: Arq separates "where" (storage location, reusable across plans) from "what" (plan). Restorey's setup is already a guided sequence per plan, so the useful bit is the three-question shape: where, password, what. Do not add a provider-specific window zoo. Confidence: medium.

### 2.7 Menu bar monitor (ArqMonitor.app)
- **What Arq does**: a separate login-item app (`LSUIElement`, bundle id `com.haystacksoftware.ArqMonitor`). Its menu has "Pause...", "Resume", "Open Arq". "Pause..." opens a sheet "Pause backups for [N minutes]" with Pause/Cancel (NIB `EnterPauseMinutesWindowController`). The agent exposes `resumeDate` and `resumeAll` routes, so a pause carries an end time.
- Preferences: "Show in menubar", "Status icon:", "Animate when busy" (Hopper `setAnimateMenubarIcon:`), and "Suppress all user notifications" as an agent-wide switch (`suppressAllUserNotifications`).
- **Suggestion**: Restorey's menu is richer (banners with fix actions, per-plan status). The cheap thing to adopt: Pause offers fixed durations (1 hour, until tomorrow, custom minutes) and always states the resume time, which Restorey already does ("auto-resume time"). "Animate when busy" as an opt-out is a calm-UI touch. A global "mute notifications" switch contradicts Restorey's "notifications always on" ruling, so skip it. Confidence: medium.

### 2.8 Preferences window
Small: log level, app password ("Set..."), disk I/O throttle, licence, menubar options, "Send crash reports", auto-update. The app-password option locks Arq's UI ("each time you open Arq you'll be prompted", HELP `security`).
- **Suggestion**: Restorey already gates secrets behind Touch ID. Not needed. Confidence: high (nothing to borrow).

### 2.9 Onboarding and permission prompts
- **What Arq does**: three Full Disk Access windows (NIB `FullDiskAccessWindowController`, `VenturaFullDiskAccessWindowController`, `SequoiaFullDiskAccessWindowController`), each a titled window "Grant full disk access to Arq", an explanation sentence ("In order to back up your application data (Photos, Contacts, Calendars, Mail, etc) Arq needs permission to read it."), a drag-and-drop icon so the user can drag the app into the System Settings list (class `DragDropImageView`), an "Open System Settings" button and a "Do not show this again" checkbox. The main window also has a menu item "Grant full disk access to Arq..." and a positive confirmation, "Arq has full disk access". A fallback text spells out the path: Privacy & Security, then Full Disk Access (Hopper 0x100201195). HELP `permissionRequirements` explains why the agent (not the app) needs it, and what breaks without it (errors, and FSEvents for fast incremental scans on protected folders).
- Windows are OS-version-specific because the System Settings layout changes.
- **Suggestion**: three good ideas. (a) A **drag-here icon** in the sheet, so the user drags the agent into the list rather than hunting for it. That is the single most useful trick for a menu-bar app whose Full Disk Access target is a helper that is hard to find in a file picker. (b) A **positive confirmation** state once granted. Restorey's banner "Full Disk Access is missing — Fix…" can flip to a quiet tick. (c) **"Why":** one sentence naming what is missed. Skip "Do not show this again", since it hides a real risk; a banner that stays until fixed is the right call. Confidence: high for (a) and (b).

---

## 3. Errors, unreadable files, interrupted backups

### 3.1 Errors as a dedicated list with one-click "skip next time"
- **What Arq does**: `BackupRecordErrorsWindowController` is a table with an "Error Message" column (NIB). A backup that has file errors is not a "failure": the activity status reads "finished with errors …" (Hopper 0x1002037bc) and appears in its own detail view, `activityWithErrorsDetailView`, with its own table (`activityErrors`, `activityErrorRows`) and a selection-dependent action. From a selected error, the user can add an exclude rule. The confirmation text is: "A wildcard exclude rule will be added to the backup plan so this file is skipped in future backups. You can edit or remove it later by editing the backup plan." (plural variant also present, Hopper 0x100203a9b, 0x100203b3b).
- **Suggestion**: Restorey's "files that couldn't be read" warning could open a list of paths with a per-row or multi-select action "Don't back this up (add an exclude)". The reassurance line that the rule can be edited later is the key to making this feel safe. Distinguish permission errors (fix: Full Disk Access) from "file vanished mid-backup" (benign) and from unreadable-by-design (exclude). Confidence: high.

### 3.2 Safety coupling: retention is skipped when the backup had errors
- **What Arq does**: strings say retention "was skipped at the last backup (%@) because the backup had errors" and "SKIPPED because the backup had errors" (Hopper 0x1001fe33b, 0x1001fe8c4), and a storage-budget message says limits are enforced "unless errors occur during backup" (0x10020f829).
- **Suggestion**: `restic forget`/prune after a partial backup can discard the older complete snapshots you may still need. Restorey's agent should do the same (no automatic forget after a backup that ended with read errors) and say so in the History row: "Cleanup skipped: the last backup had errors." Check what the agent does today. Confidence: high that it is the right behaviour; I did not check Restorey's implementation.

### 3.3 Partial data wording
Hopper 0x1001fe43a: "; partial: some data couldn't be read". Arq uses "partial" as a distinct marker on a backup record, not a failure.
- **Suggestion**: three outcome words, not two: "Completed", "Completed with errors" (with a count and a link), "Failed". Restorey seems to have this already (restic exit code 3). Make sure the menu icon treats "completed with errors" as a warning, not an error. Confidence: medium.

### 3.4 Notifications and reports
- **What Arq does**: email reports "after every backup" or "only when errors occur (including when a backup is aborted)" (HELP `createBackupPlan`). Arq Premium rate-limits them: at most one error report per 6 hours while failing, at most one "0 errors" report per day, but the first error after success and the first success after errors are always sent. Local: "Show notifications when backup finishes" and "Alert if no successful backups for N days" (`noBackupsAlertDays`, `noBackupsNotificationOptions`).
- **Suggestion**: the **edge-plus-rate-limit rule** (always report a state change, throttle repeats) is exactly the calm-alerting pattern. Apply it to Restorey's notifications and to any check-in/webhook. Confidence: high.

### 3.5 Interrupted and network-skipped backups
Arq pauses while on battery, in a pause window, off allowed Wi-Fi, or on expensive/low-data networks, and shows "Paused". I found no distinct "interrupted" screen. Hopper shows a retry string for directory listing ("contentsOfDirectoryAtPath(%@) interrupted; retrying") and a "Calculating backup set size..." window. Restorey's "Skipped on Wi-Fi …" History entries with a reason are already better than this. Confidence: medium (absence of evidence).

### 3.6 Send log
`SendLogFileWindowController` asks only "Please enter your email address so we can reply to you:" and sends the log ("Log file sent"). A "View Log" action exists. Restorey is open source, so "Copy log" or "Reveal log in Finder" plus a prefilled GitHub issue link is the equivalent. Confidence: low-medium.

---

## 4. Other ideas that would make a restic front end clearer

1. **"Validate" explained with its cost**: HELP `validate` warns plainly that verification will "download a significant amount of data", mentions transfer fees and ISP data caps, and offers the cheaper alternative (clear the cache and re-list the repository). Restorey's `restic check` and `check --read-data` options should carry the same cost warning, with the repository's size in the dialog ("This reads all 486 GB from the repository"). Confidence: high.
2. **Dataless / cloud-only files**: HELP `datalessFiles` explains why files evicted by iCloud/Dropbox aren't backed up from a snapshot and that reads time out without a logged-in session. Restorey reads live files, not APFS snapshots, but still triggers downloads of cloud-only files. A plan option "Skip cloud-only files (not downloaded to this Mac)" with that explanation prevents a surprise multi-GB download and a long-running backup. Confidence: medium.
3. **Cache clearing in plain words**: separate "clear this plan's local cache" and "clear the location cache", each stating when it is needed and what it costs. Maps to restic's cache and `restic cache --cleanup`. Confidence: low-medium.
4. **Backup-set size calculation as an explicit, cancellable action** ("Calculating backup set size…"), rather than an invisible cost. Fits Restorey's decision to compute repository size only after prune. Confidence: medium.
5. **Immutable records** with a visible cost note ("This will increase costs with some storage providers.") and "Object lock is not available for the chosen storage location." greyed with an explanation. A pattern for any feature a given repository backend can't support: show it disabled with the reason, never hide it. Confidence: high.
6. **Glossary page** in the help book. Arq needed one because of its vocabulary. A restic front end can avoid most of that by choosing plain words once and sticking to them. Confidence: medium.
7. **Terminology cleanup**: Arq changed "snapshot" (Arq 6) to "backup record" (Arq 7) because "snapshot" collided with filesystem snapshots. Restorey faces the same collision: restic snapshots vs APFS snapshots. If Restorey ever uses APFS snapshots, name them differently in the UI. Confidence: medium.

## Gaps

- I could not render the nibs, so control positions and the visual grouping are inferred from string and binding names. Arq's `throttleType` values (none, always, from-to) are inferred, not read from a table.
- No upload-speed or ETA string was found. If the live app does show one, it is outside the strings I searched.
- No network or user data was read; Arq was not launched.
