# Restorey

A free, open-source macOS menu bar app that puts an Arq/Backblaze-style front end on
[restic](https://restic.net).

> **Status: v0.1 in testing on the owner's Mac.** There is no app to download yet. The engine (background agent,
> scheduler, plans, Keychain secrets, check-ins and notifications) and the app (setup, the menu bar, Settings, the
> recovery kit and Restore Files) run from a development build; the owner's live checks of the whole app are in
> [docs/v0.1-measurements.md](docs/v0.1-measurements.md). Nothing here is ready to protect your data yet.

## What it will do

- Show backup status in the menu bar, with live progress, Back Up Now and Pause.
- Run backups from a background agent, so they keep running with the app closed and catch up after sleep.
- Support several independent backup plans, each with its own repository, sources, schedule and retention.
- Adopt existing restic repositories without losing their history.
- Restore files through a Time Machine-style window: Finder columns plus a timeline of snapshots.
- Alert loudly when backups fail or stop, through macOS notifications, a Healthchecks-style check-in URL, ntfy, Pushover or a webhook.
- Verify repositories regularly with `restic check` and test restores.
- Support cold storage plans on S3 Glacier Deep Archive, with a guided thaw before restoring.

Restorey is a thin wrapper. restic does the deduplication, encryption, storage and retention.

It is aimed at people who already know restic. It targets macOS 27 and will not be on the Mac App Store,
because the App Store sandbox rules out the Full Disk Access a backup tool needs.

## Documents

- [Design](docs/superpowers/specs/2026-11-09-restorey-design.md)
- [Menu bar and restore window mockup](docs/mockups/menubar-and-restore.html)
- [v0.1 UI design](docs/superpowers/specs/2026-11-12-restorey-v0.1-ui-design.md), with mockups of [setup](docs/mockups/v0.1-setup-flow.html), [Settings](docs/mockups/v0.1-settings.html) and the [menu bar states](docs/mockups/v0.1-menu-states.html)
- [Platform spike plan](docs/superpowers/plans/2026-11-10-platform-spike.md)
- [Platform spike findings](docs/spike-findings.md) (throwaway spike code in [`spike/`](spike/))
- [v0.1 engine plan](docs/superpowers/plans/2026-11-10-v0.1-engine.md), [measurements](docs/v0.1-measurements.md) and [rulings](docs/v0.1-rulings.md) (R1–R78)

## Using Restorey

This is what the app does, from the user's side. The sections under "Building from source" say how each part
works.

**Setup.** The first launch opens setup, which takes one plan from nothing to its first backup: move Restorey to
Applications, grant Full Disk Access (and, optionally, notifications and Open at login), say where backups go (B2,
S3, or any other restic location), set or enter the repository password (a new repository, or an existing one to
adopt with its history), save the recovery kit somewhere other than this Mac, choose what to back up (the home
folder by default, with the default exclusions) and the schedule (hourly by default, with retention and an
optional check-in URL), then start the first backup. Quitting part-way resumes where you left off. "+ Add plan…" in
Settings → Plans runs the same steps for another plan.

**The menu.** The menu bar icon shows the worst state across all plans. The menu lists any problem first, each with
its fix (Full Disk Access missing, notifications off, the agent not running or switched off, an unfinished setup, a
recovery kit to save again, no off-Mac monitoring); then one entry per plan with its status, progress or next run,
and destination (choosing it opens the plan in Settings, and a failed one has "Show Details…" for its history);
then Resume, Back Up Now and Pause, Restore Files…, Settings… (⌘,) and Quit Restorey. Backups run from the background
agent whether or not the app is open.

**Settings** has four sections in its toolbar:

- **General**: Open at login, Full Disk Access, notifications and the background agent, each with its fix, and the
  logs folder. While Full Disk Access is missing, a tile shows Restorey's icon and name with why it is needed and
  "Drag this into the list, then switch it on."; once it is on, the tile gives way to a green tick and "Full Disk
  Access is on".
- **Plans**: the plans in a sidebar with "+ Add plan…", and the selected plan's tabs. **Overview** (its state, the
  last and next backup, any iCloud files skipped, and Back Up Now, Pause, Resume and Restore Files…); **What** (folders, drives and
  exclusions); **Schedule** (how often, the battery rule, the plan's own upload limit); **Storage** (the address,
  read-only, the password and keys, the host label, and "Show recovery kit…"); **Keep** (retention, prune, and
  **Earlier snapshots**: applying retention to the snapshots of the plan's previous folder lists, or from before
  Restorey adopted the repository); **Alerts** (the check-in URL and "no successful backup in N days"); and
  **History** (the plan's runs). Edits are saved with Save (⌘S) or undone with Revert; changing the password, a key
  or the host label pauses backups until a new recovery kit is saved. Delete Plan… leaves the repository alone.
- **Network**: rules for the whole Mac, for plans that back up to another machine (S3, B2, a restic server; never a
  folder or drive): an upload limit shared by the backups uploading at once, skipping backups on a phone hotspot or
  in Low Data Mode (on by default), and a list of Wi-Fi networks to skip backups on. Adding the first network asks
  for Location permission, which macOS requires before it shows any app the Wi-Fi network's name.
- **History**: every plan's runs, newest first, filtered by plan and by outcome, each with its log.

When files exist only in iCloud, not on this Mac, a backup skips them. The plan's Overview then says "iCloud Drive
files skipped" under the last backup, and its info button explains how many and how to include them. Restorey counts
these itself in the iCloud Drive and CloudStorage folders your plan covers, giving up quietly after 10 seconds, so the
number is an approximation.

The recovery kit and Restore Files ask for Touch ID or your login password before showing a plan's secrets.

**The Developer window** is in Debug builds only (the `RestoreyDev` identity), from "Developer…" in the menu. A
Release build doesn't compile it at all, and `scripts/ci.sh` fails if one contains it (below).

## Building from source

Prerequisites: macOS 27, Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46.0 (`brew install
xcodegen`; CI installs exactly 2.46.0 from its release, checked against the published SHA-256).

1. Fetch the pinned upstream binaries (restic 0.19.1 and rest-server 0.14.0, checked against each release's
   `SHA256SUMS`) into the gitignored `vendor/` folder. A cached binary is reused only while it still matches
   the checksum recorded when it was extracted (`vendor/<name>.sha256`); otherwise it is downloaded again:

   ```sh
   scripts/fetch-binaries.sh
   ```

2. Run the CI checks: the `RestoreyCore` tests, unsigned Debug and Release builds and the bundle checks. If
   `Config/Local.xcconfig` exists, it also does a signed Debug build and the full signature checks.

   ```sh
   scripts/ci.sh
   ```

3. For a signed local install, copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig` (gitignored) and
   set `DEVELOPMENT_TEAM`. Then build, sign and install `RestoreyDev.app` into `/Applications`:

   ```sh
   scripts/install-dev.sh
   ```

   `BUILD_NUMBER=2 scripts/install-dev.sh` installs it with a different build number, so the running agent sees
   an update and is restarted. Reinstalling the same build within an hour of a repair leaves the old agent
   running until you choose "Restart Agent".

Debug builds use a separate identity (`com.jaydenkerr.restorey.dev`, `RestoreyDev`), so they can sit beside a
Release install without sharing a launchd label, keychain group or on-disk state. GitHub Actions runs the
unsigned path of `scripts/ci.sh` on every push and pull request.

### What the app does with the agent

The app is a menu bar item. When it runs from `/Applications` (any subfolder is fine) and isn't translocated,
it registers the embedded agent with `SMAppService`, says `hello` every 10 seconds and repairs what it can:

- not registered yet (`notFound` on a first launch): it registers
- the agent's binary isn't inside this app's bundle, or the embedded launchd plist changed since the last
  registration: it asks the agent to finish any run in progress and stay up (`prepareForReregistration`), then
  unregisters and registers again. If the agent can't be asked, or refuses because it is already restarting for an
  update, it doesn't unregister, and tries again later
- the agent runs a different version or build, or still runs a binary that an install has since replaced (it
  reports a fingerprint of its executable taken at launch, so a reinstall with the same build number is caught
  too): it asks the agent to finish any run in progress and exit
  (`prepareForRestart`), and launchd starts the new one. The menu says "Finishing the current backup before
  updating the agent" meanwhile, or "Updating the background agent…" when it finds the agent already draining
- the app's own bundle is missing the agent's plist: "Restorey's installation is damaged — reinstall it from the
  download", with no repair offered
- switched off in Login Items: "The background agent is switched off", with "Open Login Items…". Never switched
  back on by Restorey. The registration's status is read at every heartbeat, so a change shows within 10 seconds
  while Restorey runs; on macOS 27.2 switching the agent off also quits Restorey (loginwindow force-quits it, see
  `docs/spike-findings.md`), so in practice it shows on the next launch.
- registered but not answering: "The background agent isn't running", with "Restart Agent". While a backup
  was running at the agent's last status (under 30 minutes old), the menu instead keeps that status with
  "(agent not answering)" and a warning. After 30 seconds without an answer it unregisters and registers the agent again on its own, unless
  a restic from Restorey's own bundle is still running under the agent: unregistering would kill that backup,
  so it waits and looks again at each heartbeat. The agent's answer never waits on the notification centre, so a
  stuck `usernoted` doesn't make a working agent look dead. A switched-off agent reads differently (see
  `docs/spike-findings.md`), so this never overrides your choice

When an update lands while a backup runs, the old agent finishes only the restic step in progress and starts no
new one, since restic would run the new helper, which the old agent refuses. A backup still waiting its turn shows
"Skipped: Restorey was updating" and the new agent runs it at once. The agent also notices on its own (within
a minute, or before its next restic step) that its executable was replaced, and restarts itself, even if the app
isn't running.

A stale agent is restarted before any re-registration, since an older agent may not know the newer
`prepareForReregistration` call. Automatic repairs happen at most once an hour for each kind (restart,
re-register), also across relaunches (a new version or build may repair at
once). Plan lines are shown live only while the agent is healthy, and are fetched afresh each time it becomes
healthy; otherwise the last status received is used only for "Last known: …" and the lines above. Each agent
process stamps its hellos and statuses with its own run ID; once a hello reports a newer run, a late status from
the older one is ignored (Ruling R76). Only hellos retire a run: heartbeats are serialised, so their order is the
agents' order, while a late status can arrive at any time.
**A copy anywhere else does nothing to the agent**: no XPC, no
registration and not even a status read, which on its own can re-point the registration at the copy. It only
shows "Move Restorey to Applications". The app's log is `~/Library/Logs/Restorey-Dev/app.log`.

A Debug build adds a "Developer…" menu item; a Release build has neither the item nor the window. `project.yml`
leaves `App/Developer/` out of the Release build (`EXCLUDED_SOURCE_FILE_NAMES`), its uses are behind `#if DEBUG`,
and `scripts/verify-bundle.sh` (run by `scripts/ci.sh` on every build) reads every Mach-O file under the bundle's `Contents`
and fails a Release bundle that names any of its types (`DeveloperModel`, `DeveloperWindowController`, `DeveloperView`, which Swift's metadata keeps
even in a stripped binary), and a Debug bundle missing any of them, so the check can't pass by looking in the wrong
place. It also checks, for Debug and Release, that the built app holds the password word list
(`Contents/Resources/RestoreyCore_RestoreyCore.bundle/Contents/Resources/eff_large_wordlist.txt`, 7,776 lines), since
a missing one stops setup suggesting a password. The window saves plans (S3, B2 or a raw local repository path such
as `/tmp/restorey-dev-repo`), creates or adopts repositories, confirms the recovery details, backs up, pauses,
resumes, asks for notification permission, and shows the agent's live status as JSON. Its fields are the real
controls the setup flow and Settings use (`App/Controls/`): `PlainTextField` and `SecretField` (a secure field that
swaps to a plain one while "Show" is on, so dead keys and input methods work), `SourcesEditor` and
`FileTypesEditor`, with their checks in `FormValidation` (`RestoreyCore`). A plain field's Undo history belongs to
the field and lasts while it is being edited; a secret field has no Undo history, shown or hidden. A field shows a
new value from its model (another plan loaded, say) even while it is being edited, and never writes it back.

```sh
launchctl print gui/$(id -u)/com.jaydenkerr.restorey.dev.agent        # spawn type = daemon (3), both Mach services
```

The agent runs only as its launchd job: started any other way (double-clicked, run from Terminal, or as the
hosted tests' XCTest host) it touches none of its files and starts nothing, so there is never a second agent
beside the real one ("Why the keychain tests need a signed host" has the details). The agent serves its XPC
interface only to the signed app: the listener requires the app's bundle ID and the
team in `Config/Local.xcconfig`, so any other process is refused. Only one call returns secrets: `recoveryKit`
replies with a plan's repository password, its S3 keys or raw environment values, and its check-in URL, so the app
can show the recovery kit; it goes only to the signed Restorey app over that XPC connection, the agent logs just the
plan and how many secrets it sent, and the app keeps them only while the kit or the Restore Files window is open
(see "The recovery kit"). The other calls the setup and
Settings screens use return no secret: `probeRepository` (is the address empty, or a repository the password opens,
with its snapshots by host), `history` (run records, newest first, for one plan or all), `probeFullDiskAccess`
(runs the agent's own probe and pushes the status) and `dismissOffMacNote`. It is the only writer of `config.json`,
`state.json` and the plans' keychain items, all under `~/Library/Application Support/<root ID>` (mode 0700).
If either file is corrupt or was written by a newer Restorey, the agent reports it in `status`, refuses every
change and leaves the file as it is. Its log is `~/Library/Logs/Restorey-Dev/agent.log`, and MetricKit
diagnostics go to `diagnostics/` beside it.

### Menus and windows

Restorey is a menu bar (accessory) app while none of its windows is open. While any is (setup, Settings, the recovery
kit, Restore Files, an alert, or the Debug-only Developer window), it is an ordinary app: a Dock icon, a place in ⌘-Tab
and its own menu bar, and it goes back to the menu bar when the last window closes (`WindowPresence`,
`ActivationController`, `WindowActivation`). A minimised window still counts, and its own tile in the Dock brings it
back; clicking Restorey's app icon in the Dock is a reopen, which opens Settings (below). Open panels are sheets on the
window that asked, and the About panel counts while it is up, so no Restorey window is left on screen in a menu bar
app. As an accessory app it had no menu bar, so Quit and Edit weren't there while its window was in
use, and macOS passed it over when a Touch ID prompt went away, so the window that asked fell behind the app before
(diagnosis in `.superpowers/sdd/2026-11-12-v0.1-ui/o1-diagnosis.md`). The main menu is the app menu (About, Hide,
Quit), an Edit menu (Undo, Redo, Cut, Copy, Paste, Paste and Match Style, Delete, Select All) and a Window menu
(Minimise, Close), so ⌘Z, ⇧⌘Z, ⌘X, ⌘C, ⌘V, ⌘A, ⌘H, ⌘W and ⌘Q work in its windows. Each kind of window (setup,
Settings, recovery kit, Restore Files) opens at most once: asking again brings the open one to the front. A window is
ordered front and activation asked for once, while the click that opened it is handled. Since macOS 14 that request
can be refused; then, on the next turn of the run loop, a window still on screen is ordered in front anyway
(`orderFrontRegardless`), though it isn't key until clicked. A hidden Restorey (⌘H) is shown again first, without
activating it, so that window can be seen either way. After a Touch ID prompt, only a window still open is made key
again. None is restored at launch, and closing a
window releases it, so a recovery kit's secrets go with it. The setup window follows its content's size from step to step.

Opening Restorey again while it runs (from Finder, Spotlight, `open` or its Dock icon) opens Settings, or brings an open Settings
window forward as it is, so the app can still be reached when its menu bar icon can't be seen. If the icon is hidden (System Settings → Menu Bar) when Restorey
starts, it opens Settings at once, in General (as does opening it again while the icon is hidden), with the note "Restorey's menu bar icon is hidden. Show it in System
Settings → Menu Bar." An icon squeezed out of a full menu bar isn't detected (macOS still reports it as visible), so
opening the app again is the way in. A copy outside `/Applications` opens setup's "Move to Applications" step
instead. Open at login registers the app itself with `SMAppService.mainApp`, from the installed copy only; it is
switched in setup's permissions step and in Settings → General.

The setup window's step order and rules live in `SetupFlow` (`RestoreyCore`): Move to Applications,
permissions (Full Disk Access required, notifications optional), storage, password, recovery kit, sources, schedule,
then the first backup. "Check" saves the plan with its kit unconfirmed, so it never runs. `SetupProgressStore` keeps the
step in `UserDefaults` (`setupProgress`) so quitting resumes an unfinished setup; a plan needing a new kit is the
recovery-kit window's job, not setup's. The kit is saved at its step but the agent confirms it only at "Start first backup", so a plan stays unfinished (and never runs) until then.

The setup window opens at launch while a plan's setup is unfinished or no plan exists, decided on the agent's first
status; a copy outside `/Applications` opens it at once, on "Move to Applications" (also in its menu). That screen
copies the app into `/Applications` under the build's own name (`Restorey.app`, or `RestoreyDev.app` for the
development identity, whatever the downloaded copy was called), through a staging folder (`AppInstaller`), removes
`com.apple.quarantine` from the copy, moves the copy it ran from to the Trash (for a translocated launch, the original
in `~/Downloads`, never the read-only mount, and never the copy just moved in when that original was already
in Applications), opens the moved copy and quits. A copy that can't be read in full is reported as such (download
Restorey again), not as Applications being unwritable. `AppMove` decides, and decides again
when the button is pressed: while any agent of this identity is registered (read from launchd and from the app's
record of its last registration, never from `SMAppService`) it refuses and asks for Restorey to be quit and the copy in
Applications replaced by hand, since a backup may be running; an app of another bundle identifier at the destination
is never replaced; this Restorey there is offered for replacing, and the old copy goes to the Trash. It never asks for
an administrator password: `NSWorkspace.requestAuthorization` needs the restricted Privileged File Operations
entitlement, and administrators can write to `/Applications` anyway; anyone else is told to drag the app there in
Finder. The permissions step ticks off Applications, checks Full Disk Access through the agent's own probe and
re-reads the agent's notification answer every 2 s while the window can be seen and whenever Restorey comes back to
the front, asks the agent for notification permission, and has "Open at login" (on by default), applied on Continue,
which needs Full Disk Access; the switch is kept in the saved progress until then, since granting Full Disk Access
quits the app mid-step. While Full Disk Access is missing the step shows a tile with Restorey's icon and name, to drag
into System Settings' Full Disk Access list ("Drag this into the list, then switch it on."), with the one-line why
("Without it, Restorey can't back up Mail, Messages, Safari and other protected folders."); granted, it shows a green
tick and "Full Disk Access is on". The tile drags the app bundle as a file URL (`NSItemProvider(object: NSURL)`,
`public.file-url`): the agent is registered from inside the app, so macOS attributes its access, and restic's, to
the app (spike H1), and the app is the only item the list needs. The step's secrets live only in `SetupDraft`, which drops them whenever the step changes
and when the window closes; the progress is saved only when the step changes.

From the storage step on, each Continue saves the plan through the agent (kit unconfirmed, so it never runs), so a
resumed setup gets its values back from the agent's status. **Where backups go** offers B2 (the default), S3 or
another restic location (a path, or any restic backend with its environment variables, whose values go to the
keychain), with Backblaze's and AWS's pages on making a bucket and a key; `StorageForm` (`RestoreyCore`) checks the
fields with `FormValidation` and reads them into the plan's repository. "Check" saves the plan with a stand-in
generated password and asks the agent what is there (`probeRepository`): nothing (`empty`), or a repository the
stand-in can't open (`passwordRejected`, restic's exit 12), which is how setup learns that one is there before the
user has typed its password. **Repository password** then offers either a generated password (shown, copyable as a
concealed pasteboard item, or replaced by the user's own) and an explicit "Create New Repository", or the existing
repository's password: "Open Repository" probes again with it and shows "312 snapshots from 3 Macs" and the host
label this Mac's snapshots are under (`SetupAdoption`: the repository's host matching this Mac's computer, local or
Unix host name, spelt as the snapshots spell it, else this Mac's name, with the new-group warning); "Use This
Repository" makes it an adopted plan (no prune, forget daily, pack size left alone), runs `adopt` and fills the
sources in from the latest snapshot for that host label. What the step shows is `PasswordStep.decide`'s (`RestoreyCore`),
from the probe and two facts the saved progress records, never from the plan's origin: `repositoryCreated`, set only
when "Create New Repository" succeeds, and `adoption`, the adopt report (host names, the latest snapshot's paths,
the count), set only when `adopt` succeeds. So a setup quit after "Open Repository" but before "Use This Repository"
resumes on the adopt path rather than calling someone else's repository its own, and the sources step's new-group
warning survives a quit (kept rather than listed again, which can take minutes on a remote repository). A new
address at "Check" clears both facts. A password of the user's own that starts or ends with a space (or a tab or newline)
is refused ("A password can't start or end with a space."), because restic trims whitespace from the output of
`RESTIC_PASSWORD_COMMAND`, which is how Restorey passes it the password: it would never open the repository again. For
the same reason, adopting a repository whose password has whitespace at an end isn't supported. A copied password
(generated or the user's own, in setup or the recovery kit) is marked concealed, stays on this Mac (`.currentHostOnly`,
so Universal Clipboard doesn't send it to other devices) and is cleared from the pasteboard after 90 seconds unless
something else has been copied since. **Recovery kit** shows the kit (see "The recovery kit") once the
repository's own password is saved, that is once this setup created or adopted the repository; before that the plan
holds only "Check"'s stand-in, so the step says so and offers Back instead of a kit. The tick "I've
saved it somewhere other than this Mac" can be set once the kit has shown; it is recorded in the progress and lets
setup go on, and the agent confirms the kit only at "Start First Backup". **What to back up** has the
home folder by default (or the adopted snapshot's folders, with the new-group warning when they're changed), the
exclusions in one line (`ExclusionsSummary`, which also names the items apps mark as not for backup) and "Review Exclusions…" (folders, with Restorey's own two kept; file
types; one file system). **Schedule** has the interval (hourly by default; 1, 2, 4, 6, 12 or 24 hours), the battery
rule, retention and the optional check-in URL with why it matters (`ScheduleForm`). **Done**'s "Start First Backup"
saves anything left, confirms the kit, then backs up: confirming makes the plan due, so the scheduler may start it
first. `backUpNow` answers with a `BackUpNowReply` whose `alreadyRunning` says so for the plan asked for, instead
of refusing (an agent from before it answered with a bare status, which still decodes). Only a backup step still under way
and carrying on counts: a run stopping for a pause (or any other stop), a run in its maintenance after the backup step
(forget, prune, check), or a one-off action such as an adopt, still gets the "is already backing up" refusal, as before; only Resume queues a backup behind a stopping run (Ruling R62). The progress line
(`FirstBackupProgress`) is the menu's wording, plus "Waiting to start" while the run has no progress yet (queued behind
an adopt's size measurement, say). Closing the window leaves the backup running. Every agent sentence shown in setup
gets a closing full stop (`FormValidation.sentence`), as the form's own sentences have. An environment row's value
is held by the row until "Check" names its keychain item, so renaming the row keeps what was typed, and "Leave a key
empty to keep the one already saved" shows only while the form still shows the saved address. If the plan a setup
was building is gone from the agent's status (deleted elsewhere, while the window was closed or open), the window says so and
offers "Start Again" at the storage step. A status that lists no plans because the agent can't read its settings
never counts: the window shows "Restorey can't read its settings: …" (whenever the latest status says so) and waits, so the plan isn't orphaned once the
file is fixed. A resumed password step whose probe fails says so with "Try Again" rather than a spinner. The adopt
report is recorded only once the pre-filled sources are saved too, so a failure there leaves the step on the adopt
path and pressing the button again runs all of it again. `SetupModel` keeps the shared state; each step's actions are in their own file
(`SetupModel+Storage`, `+Password`, `+Sources`, `+Schedule`, `+Done`).

The adopt step also offers "Apply this plan's retention to existing snapshots from this Mac" (product spec §5.6),
off by default. Switched on, "Use This Repository" adopts as usual, then asks the agent for a preview
(`previewEarlierSnapshots`: a `forget --dry-run` that takes no lock and records nothing) and shows its own
confirmation, "Remove N snapshots from before Restorey?", with how many the plan's retention keeps, whether prune will
free the space, that they go after the first successful backup, and that it can't be undone, in a few short sentences so the sheet fits the setup window. Cancel is
the default button (Return, and Escape too); "Remove N Snapshots" is never the default (`DestructiveAlert`). The confirmed snapshot IDs are
kept in the setup progress (`earlierRemoval`), and Done hands them to the agent before it confirms the kit
(`removeEarlierSnapshotsAfterNextBackup`); the agent removes them only after the plan's first backup that succeeds
with every file, so a setup that fails never deletes anything. The confirmation says that other tools' snapshots of
these folders from this Mac are included, and that other Macs' and other folders' are not touched (another Restorey
plan's never is either). Nothing to remove, or Cancel, leaves the step on "The repository is
ready" saying so, with the switch there to try again.

### Settings

Settings (⌘, in the menu) is a window with a toolbar of sections, as macOS draws them for settings: **General**,
**Plans**, **Network** and **History** (mockup `docs/mockups/v0.1-settings.html`). The menu's routes pick the section
and plan: a plan's line opens it in Plans, "Show Details…" opens History for that plan, and "No off-Mac monitoring —
Add…" opens the plan's Alerts tab.

**General** has Open at login (the switch re-reads `SMAppService` after every change, so a Restorey switched off in
System Settings → General → Login Items shows as off with a note and "Open Login Items…", never as what was asked),
Full Disk Access as the agent's own probe finds it, notifications as the agent last heard from the notification
centre, the background agent's state and version ("Running · 0.1.0 (11)"), each with the menu's fix (Fix…, Turn
On…, Restart Agent, Open Login Items…), the logs folder (Show in Finder), and, while the menu bar icon is hidden, the
note saying where to show it. These are read again whenever Restorey comes back to the front. The words are
`SettingsGeneral`'s (`RestoreyCore`).

**Plans** lists the plans with "+ Add plan…", which opens setup from "Where backups go" (`SetupProgress.addingPlan`).
Setup keeps one saved progress, so `SetupFlow.addingPlan` decides what it opens: a new add, the add or first run
already under way, or, when another plan's setup isn't finished, a question offering to finish that one first. An
unfinished plan shows "Setup not finished" with "Finish Setup…" (setup is still making it, so it has no tabs); a plan
needing a new kit shows "New recovery kit needed" with "Save Recovery Kit…"; a plan the agent has stopped shows
"Stopped" and its reason, as its line in the menu does. The sidebar notes the same under each plan's name, one at a
time: "Setup not finished", then "Stopped", then "New recovery kit needed" (`PlanNote`). Every other plan has tabs:

- **Overview**, first and where a plan opens (picked in the sidebar, the menu's plan line, a new Settings window; a
  route that names a tab, such as "Add…" for Alerts, keeps it; `planRequestLandsOnFirstTab`): a headline with the
  plan's state only ("Up to date", "Backing up — 42%", "Paused", "Backup failed", "Stopped", "Needs attention",
  "Waiting for a new recovery kit", "No backup yet") and the menu's reason under it, coloured only when the plan
  itself needs attention; then the times, only in the Last backup and Next backup rows ("Today at 17:10", "Tomorrow
  at 09:00"); and Back Up Now, Pause while a backup runs, Resume while paused and Restore Files…, enabled as the menu's
  items are and asking the agent the same way (`MenuPresentation.overview`, `AgentActions`). After a backup that
  couldn't read some files, "Show…" under the reason opens "Files that couldn't be read" (see below). It follows the agent
  live, progress included. The window is at least as wide as the row of seven tabs, measured with the system's fonts each time a Settings
  window opens, so a text-size change applies from the next one.
- **What**: its name, the folders and drives, the exclusions (setup's line and "Review Exclusions…" sheet), and a
  line counting the items apps mark as not for backup ("Also skipped: 1,145 items apps mark as not for backup") with
  "Show…", a sheet with the plan's switch for them and the list, each with "Back up anyway".
- **Schedule**: the interval, the battery rule and the plan's own upload limit in MB/s (empty, the default, is none;
  a networked repository also gets its share of the Mac-wide limit, the smaller winning, Ruling P2-7). Under the
  interval, one quiet line gives the plan's last backup and next run in the menu's words ("Last backup at 14:16 ·
  next at 15:16"; "No backup yet · first at …"; paused, a skipping battery, network, Wi-Fi or drive rule, and a plan
  waiting for a recovery kit are each said). It describes the saved schedule: while the interval is edited and unsaved it adds "Next
  run time updates when you save." (`MenuPresentation.scheduleCaption`).
- **Storage**: the repository address, read-only (a different repository is a new plan), the repository password
  and storage keys or environment values (empty keeps what's saved; a new S3 or B2 key needs both halves), the host
  label, the pack size (read-only) and "Show recovery kit…". Entering the repository password doesn't change the
  repository's: it is for one changed outside Restorey.
- **Keep**: retention, with a plain-English summary under the counts that updates as you type ("Keeps the newest
  backup of each hour for the last 24 hours that have one, each day for the last 30 days that have one, …"; restic
  counts the hours, days, weeks and months that *have* a backup, not the last 24 hours of wall time, a count of 0
  leaves a rule out, and `RetentionSummary` words it); one quiet sentence that the weekly `restic check` (no
  `--read-data`) downloads the repository's snapshots, index and folder lists (tree data) with a temporary cache, never
  your files' contents, so it uses a little download allowance (restic 0.19.1 `check`); the prune switch, and for an
  adopted repository how often old snapshots are tidied. Below
  them, **Earlier snapshots**: a preview, run when the tab appears and after a save changes the folders, host label or
  retention, lists each earlier group of the plan (its previous folder lists, and for an adopted plan this Mac's
  snapshots from before Restorey) with how many snapshots it holds and how many retention would remove, and an "Apply
  Retention…" button that asks first ("Remove N snapshots of the previous folder list?", Cancel the default). With
  nothing to apply it says so in one line. It counts with the saved plan, so unsaved edits disable the buttons.
- **Alerts**: the check-in URL (saved, Remove, or a new one) and "no successful backup in N days".
- **History**: the History list for that plan; a warning row has "Show…" for the files that couldn't be read, and a
  backup row "Show…" for its biggest additions.

The tabs edit a copy (`PlanEdit` in `RestoreyCore`, held by `PlanEditModel`): the fields keep exactly what is typed,
and trimming and parsing happen only when Save (⌘S) builds the request, which applies only the fields the user
changed. So a value the form can't show exactly (an interval or battery rule set elsewhere, a limit with more
decimals than the field shows) is kept, and if the agent's copy of the plan changes while you edit, the fields you
didn't touch keep its newer values. Changing the folders or the host label shows the product spec's warning that the
next backup starts a new snapshot group, and that the old group's snapshots are kept as they are (§5.4, §5.6). Typing
a password, a key or an environment value, or a new host label, shows "Saving pauses backups until you save a new
recovery kit." before saving: the agent clears the kit's confirmation, so the plan waits for the new kit. A typed
repository password is first tried on the repository with any storage keys or environment values typed with it
("Checking the password…", `probeRepositoryCredentials`), and nothing is saved unless the repository opens with
them. The check isn't a run: it leaves nothing in the plan's history or run logs, the plan isn't shown backing up,
and a Back Up Now meanwhile waits its turn in the repository's queue, as during the size measurement after an
adopt. Like that measurement it is registered with the agent only once its turn comes (registrations are counted,
since the two can overlap), so deleting the plan never waits for whatever is queued ahead of it. The typed secrets go when the save succeeds, on Revert, when another plan is shown and when
the window closes. Every change of the plan shown (the sidebar, a plan's line in the menu, "Add…", opening the app
again) goes through one guard (`PlanSelection`): with unsaved edits, a request for another plan waits for "Discard
your changes…?" (a tab the route named, such as Alerts for "Add…", is shown once the switch happens), and closing
the window or quitting Restorey asks Save, Don't Save or Cancel (a refused save cancels the quit; a quit while
Settings already has a question up is cancelled, and the window brought forward so that question is answered first). The editor belongs to the window, so going
to General and back keeps them. Delete Plan… asks with the developer window's words ("Its
settings, saved passwords and keys, and history are removed. The repository and its snapshots aren't touched."); the
agent also removes the plan's run logs, and setup's saved progress is forgotten if it names the deleted plan
(`SetupProgressStore.forget`), as it is when the Developer window deletes one.

**Network** edits the Mac-wide rules (`NetworkEdit` in `RestoreyCore`, held by `NetworkEditModel` for as long as
the window is open, so going to another section and back keeps unsaved edits; closing the window or quitting with
unsaved Network edits asks Save, Don't Save or Cancel, after a plan's question if both have edits,
`UnsavedSettings`): "Upload limit for this Mac" in MB/s
(empty, the default, is none), "Skip on a hotspot or in Low Data Mode" and "Skip on these Wi-Fi networks", saved
with Save (⌘S) or undone with Revert, which apply only the fields you changed, as a plan's tabs do. A name is added
trimmed, at most 32 bytes (an SSID's limit), and not twice ignoring case; the agent's own checks are shown before a
save. Whether Restorey can see Wi-Fi names is `WiFiNameAccess`, from the agent's `locationAccess` reply (asked, never
prompting, when the pane appears and whenever Restorey comes back to the front), else its hello: adding a name while
the agent has never been asked sends `requestLocationPermission` first ("Waiting for your answer to the Location
question…", the field disabled meanwhile, and the name submitted is the one added) and adds the name only once it is
allowed. With permission refused, or Location Services off for the whole Mac, the field is disabled and the list says
why ("Restorey needs Location permission to see Wi-Fi names.") with "Open System Settings" (Privacy & Security →
Location Services); Location restricted by a configuration profile or Screen Time says so, with no button, since
System Settings can't change it.

**History** lists every plan's runs, newest first, with a plan filter (set again by each "Show Details…", and back to every plan once you pick a section yourself or
close Settings) and
Everything, Backups, Problems or Skipped and paused (`HistoryPresentation`): local time, plan, the step (Backup, Tidy,
Check…), how the run ended in the menu's wording ("Backed up", "Old snapshots
tidied", "Skipped: Photos isn't connected", "Backup failed" with the menu's reason; never "failed" for a pause, a
skip or a stop by the system; a probe finding no repository at an address, which is the answer setup expects for a
new one, reads "No repository there yet" and isn't a problem), the size added and the time taken where known, and "Show Log", which opens the run's
log only if its path stays inside the logs folder's `runs/`. The list is fetched again whenever a plan records a new
run. A backup that made a snapshot also names its biggest additions under its detail ("Biggest additions:
Photos.sqlite 1.1 GB, Lightroom Catalog.lrcat 312 MB, big.log 46 MB"), with "Show…" (see "What each backup added"
below).

### The menu bar

The icon and the menu come from one place (`MenuPresentation` in RestoreyCore), so they can't disagree. The icon
shows the worst state across all plans, from SF Symbols: OK (`externaldrive.badge.timemachine`), backing up (the
drive with an upload badge), paused (a pause badge), warning (an outlined "!" triangle) and error
(`externaldrive.fill.badge.xmark`, the only filled icon). All five are template images, monochrome like the rest of
the menu bar (owner, 12 Nov 2026), so the menu bar tints and dims them like its own; colour is kept for the text
inside the open menu.

With no plan at all, the menu shows "Setup not finished — Finish Setup…" (a warning), which reopens setup where it
was left, so a setup window closed before its first plan can always be found again.

The menu, top to bottom:

- **Banners** for each problem, errors first, each with its fix: choosing the banner runs it. "Full Disk Access is
  missing — Fix…" opens Privacy & Security → Full Disk Access and Settings → General, which holds the tile to drag
  into the list (the banner goes when the agent finds access granted); "Notifications are off — Restorey can't alert you —
  Turn On…" opens the agent's page in Notifications; "The background agent isn't running — Restart Agent";
  "The background agent is switched off — Open Login Items…"; "Setup not finished — Finish Setup…"; "New recovery
  kit needed — Save Recovery Kit…"; "No off-Mac monitoring — Add…" (opens the plan in Settings), with "Don't Show
  This Again" under it.
- **One entry per plan**: its name, status ("Backed up at 14:16", "Backing up", grey "Paused" with "Resumes by
  itself at 15:20", "Backup failed at 14:16" in red, with the time and reason of the newest backup that had a verdict, the same record
the "backup failed" alert is decided from, so a skip, pause or lock since doesn't hide them; a skip reason in
orange), a detail line (bytes done of the total and time left
  while backing up, or the next run; no upload speed, because restic 0.19.1 reports no count of bytes uploaded, only bytes
  processed, which counts unchanged files at once) and its destination with the repository size. A running
  backup has a progress bar under it. Choosing a plan opens it in Settings; a failed one has "Show Details…" (its
  history).
- **Resume**, **Back Up Now** and **Pause**. With one plan they act on it; with several, each opens a submenu whose
  first item, "All Plans", acts on every plan, then one item per plan (an AppKit item with a submenu can't also
  have its own action). They appear only while the agent is healthy.
- **Restore Files…** (a submenu of plans when there are several; an unfinished plan isn't listed, having no
  recovery kit and perhaps no repository yet), which opens the plan's restic restore commands (see "The recovery
  kit"), **Settings…** (⌘,), the Debug-only
  **Developer…**, and **Quit Restorey** (⌘Q).

Coloured text (the fix in the accent colour, a red or orange status) switches to the highlight's text colour on
the row under the pointer, since the highlight is the accent colour and AppKit leaves an attributed title's colours
as they are. The menu updates while it is open: progress and status change in place under the pointer. When rows come or
go (a backup starts and its progress bar appears, a banner is raised) the items are replaced instead.

## What a backup run does

The agent's plan runner (`RestoreyCore/Sources/AgentCore/PlanRunner.swift`) runs each backup in this order:

1. Refuses a plan that is invalid or whose recovery kit hasn't been confirmed, without running restic: "Confirm
   you've saved the recovery kit for <plan> before its first backup", or, for a plan that finished setup and needs
   its kit again after a change, "Save a new recovery kit for <plan> — the saved one has the old keys".
2. Checks the plan's conditions (network, battery, mounted volumes, sources that exist). A skipped run (on
   battery, no network, an unmounted volume) is recorded but sends no check-in ping. The network conditions
   apply only to a repository on another machine (S3, B2, or a raw `sftp:`, `rest:`, `rclone:` and so on): a
   repository in a local folder or on an external drive (a path, or `local:`) backs up with no network.
3. Checks Full Disk Access by listing a protected folder (`~/Library/Safari`, `Mail` or `Messages`, never a
   file's contents). Without it the run fails with "Full Disk Access is missing" and restic doesn't run,
   because restic would otherwise save a snapshot of empty folders.

   A failure found in steps 1 to 3 (an invalid plan, a missing source, Full Disk Access missing) sends the
   check-in `/fail` ping with the reason, headed "not started". A plan whose recovery kit isn't confirmed yet
   sends nothing.
4. Runs `restic backup` through the repository's queue, classifies the result, records it, and sends the
   success or `/fail` ping straight away, so maintenance never delays it.
5. After a successful backup, in the same turn of the queue: `forget` (after every backup that made a
   snapshot, or daily for an adopted repository), `prune` weekly when it is switched on, and a plain
   `unlock` followed by `check` weekly. A successful prune is followed by `restic stats --mode raw-data`,
   whose total (the stored size of the data the snapshots use, a little under what the provider counts,
   which includes unused packs and indexes) is the repository size the menu shows with its age. Each is its
   own run with its own log; a failed `check` raises its own alert and never turns the backup into a
   failure, and a failed `stats` raises none and keeps the size measured before (the reason goes to the
   agent log).
6. Records every step in `state.json` as it ends and raises or clears the alerts.

A wrong repository password, a missing repository or unreadable backup keys (including a password the helper
couldn't read from the Keychain) stop the plan until its repository or secrets are changed, or a later backup
succeeds. Pause stops a run in progress (SIGINT, then SIGKILL after 10 s) and resumes after an hour. Resume on a
paused plan starts a fresh backup at once, exactly as Back Up Now does (so it can still be skipped on battery or
without a network), and if the paused run is still stopping, the new backup starts as soon as it has ended; a
stopped plan's pause is cleared but nothing runs until it is fixed. Restorey never runs `restic init` except
from the explicit "Create new repository" action. That action first runs `restic cat config`: if a repository
is already there it refuses ("A repository already exists there"), and it initialises only when restic reports
nothing at the address. Restorey makes no separate bucket call, but `restic init` creates the bucket if it
doesn't exist and the key is allowed to create buckets (a key scoped to one bucket can't); with a scoped key,
create the bucket in your provider's console first. Restorey never runs `init` on its own. Adopting a repository
only lists its snapshots; it replies with them at once and then measures the size with `restic stats` as the
next job in the repository's queue (the plan stays idle meanwhile, and a pause or delete stops it).

**Earlier snapshots** (product spec §5.6, Task 14b). The plan's ordinary `forget` never touches snapshots outside its
own group. Two opt-in actions can: the snapshots this Mac made before Restorey adopted the repository (exactly the
plan's folders, no `restorey:` tag), and those the plan made of a previous folder list (its own tag alone, other
folders). "Apply retention" means as if they were the plan's own: the preview is `forget --dry-run --no-lock --host
<label>` with the plan's retention over a timeline that holds them and the plan's current snapshots together
(`--group-by host,paths` for the snapshots from before adoption; `--tag restorey:<id> --group-by host,tags` for
previous folder lists), since the plan's ordinary `forget`, a group at a time, already thins each old group on its own.
`EarlierSnapshots` (RestoreyCore) then decides snapshot by snapshot, from each one's own host, paths, tags and time, so
another Mac's snapshots, another Restorey plan's, a superset of the plan's folders, the plan's current snapshots, or
the plan's tag with the user's own beside it are never removable. "Before adoption" means this Mac's snapshots of
exactly the plan's folders with no `restorey:` tag, other tools' tagged ones included, taken no later than the
adoption (`Plan.adoptedAt`, recorded by "Use This Repository"; a plan adopted before it was recorded is bounded by its
first snapshot with its own tag, and with none nothing is offered), so a tool still writing to the same folders after
adoption never has those snapshots offered. A confirmed removal runs a fresh preview in the same turn of the
repository's queue and then `forget --retry-lock 5m -- <ids>` with no policy and no filter, for exactly the confirmed
IDs that preview still puts in the action: a snapshot added after the confirmation is never taken, and one gone
meanwhile is left out (restic itself skips a missing ID with `Ignoring "<id>"` and exits 0). A lock another client
holds past the wait removes nothing, says so, and is never broken. Nothing is pruned; the plan's prune schedule frees
the space. Each confirmed removal is a History row ("Removed 12 earlier snapshots", "No earlier snapshots needed
removing", or "Couldn't remove earlier snapshots", a fresh preview that failed included) with its log; the preview
records nothing. Setup's choice runs only after a backup that succeeded with every file (not one that left unreadable
files out); a lock held elsewhere, an interruption or a preview that fails keeps it for the next backup (a line in
`agent.log` at ERROR, no row), and its row is added when it finally runs (its success is an INFO line in
`agent.log`). A lock or an interruption also holds that backup's `forget`, `prune` and `check` back; a preview that
fails does not, because the plan's own `forget` is scoped to its tag and `check` is independent, so a lasting failure
can't stop retention or integrity checking. After three backups in a row with a failed preview the plan's Overview
adds a quiet line ("Couldn't remove the earlier snapshots you chose: <reason>. Restorey will try again after the next
backup."): information only, with no alert and no change to the menu icon. A removal that reaches a verdict, or a new
choice, resets the count.

"N files couldn't be read" after a backup counts the distinct files restic left out of the snapshot: those it failed on
while archiving (`"during":"archival"` in its `--json` output). Errors from its scanner, which only estimates totals for
the progress figure (for example files deleted before the backup reached them), never change the snapshot or its exit
status, so they are in the run log but not counted. An exit status 3 with no archival error still reads "1 file".

The warning's record keeps those files (`UnreadableItems`, Task 16b): each distinct archival `item` with the short end of
restic's message ("operation not permitted"; restic 0.19.1 `internal/ui/backup/json.go` and
`internal/archiver/archiver.go`), the first 100 only, while the count stays exact ("and N more" in the list). Records
written before this have none, and their line stays text. A "Show…" button next to the line (on the Overview, and on the
row in a plan's History tab; the all-plans History list has no plan editor to change, so it has none) opens
"Files that couldn't be read": each path (`~` for your home folder), why in plain words ("Restorey isn't allowed to read
this" for operation not permitted or permission denied, "It was deleted while the backup ran" for no such file,
otherwise restic's text), "Open in Finder" where the path still exists, and "Don't back this up". That adds the path's
exclusion pattern (`DefaultExclusions.pattern(forFolder:)`, glob characters escaped) to the plan's exclusions as an
unsaved edit, with Save, Revert and the close and quit guard as in the What tab; the row then reads "Won't be backed up
from the next backup" with Undo, which removes it again; nothing changes until you save the plan. A file deleted while the backup ran has no button, and a path
the plan already excludes reads "Already not backed up". This is information only: no outcome, icon, alert or ping changes.

**What each backup added** (Task 16d). Every backup runs with restic's `--verbose`, so `backup --json` prints a
`verbose_status` line for each file and folder it finishes (restic 0.19.1 `internal/ui/backup/json.go`); a new or
changed file's line carries `data_size_in_repo`, what its data took in the repository after compression and
encryption. The agent reads them as they stream and keeps only the 10 files that added the most, the total, and the
top 5 folders: each file counts towards its folder up to three levels below the deepest source holding it, stopping
early at the package it is in
(`~/Pictures/Photos Library.photoslibrary`, `~/Library/Application Support/BeeperTexts`), so a library of many small
files shows up. Unchanged items, most of the lines (about 2 million on a home folder), are dropped by a byte comparison
before any decoding, and none of the lines reaches the run log, which gets one "Biggest additions …" line instead.
The record of a backup that made a snapshot keeps them (`biggestAdditions`). History names the three biggest files on
the backup's row, the Overview does under Last backup when that backup added more than 100 MB to the repository, and
"Show…" lists the files and folders with their sizes and "Open in Finder". Information only: nothing changes an
outcome, the icon, an alert or a ping, and it is there to tell which exclusion would help. It has a cost: restic
printing a line per item adds CPU time to every backup (measured on a 100k-file test, `BiggestAdditionsMeasurement`,
run only with `RESTOREY_MEASURE_16D=1`).

Every restic run has its own log in `~/Library/Logs/Restorey/runs/<plan ID>/` (`Restorey-Dev` for Debug builds),
with secrets redacted. A log starts with the restic command (values hidden) and ends with the outcome; a
`forget` log holds one line per snapshot group, `Group host <host>, paths <paths>, tags <tags>: kept N,
removed M (<short IDs>)` (`would remove` for a dry run), rather than restic's JSON reply. Run logs are kept
for 400 days: the agent removes older ones when it starts and once a day after that, and deleting a plan
removes its folder at once. Logging out, restarting or shutting down the Mac stops the agent with SIGTERM:
it gives each restic in progress SIGINT (so restic removes its own lock), records the run as stopped by the
system, which is not a failure (no alert, no check-in ping; the backup is tried again 15 minutes after it
started), and exits within 4 seconds, before launchd's 5-second limit (restic gets 2.5 seconds to honour
SIGINT). A run already being paused keeps its pause, but its restic gets the same 2.5 seconds instead of the pause's 10. If the agent stops mid-run any other way (a crash, `kill -9`), its next start records
that run as interrupted (an interrupted backup is a failure and sends its `/fail` ping) and runs a plain
`restic unlock` (never `--remove-all`) once per repository, before it accepts any run. Before exiting for an update, the agent finishes the restic step in
progress (a backup's maintenance waits for the next backup) and then waits up to 3 minutes for queued check-in
pings.

## What a backup leaves out

Each plan starts with these defaults (`RestoreyCore/Sources/RestoreyCore/Restic/DefaultExclusions.swift`; the
reasons are in the design spec, §5.7):

- **Folders**, passed as `--exclude`: caches (`~/Library/Caches` and the caches inside app containers), the
  Trash, `node_modules`, Docker Desktop's and OrbStack's VM images, the folders Time Machine leaves out by
  default or that carry its exclusion attribute (`~/Library/Logs`, the Spotlight index, Xcode's DerivedData,
  the simulators, `~/.cache`, `~/.npm`, Mail's index and similar rebuilt state), a few system folders that fail
  on every run even with Full Disk Access (including `~/Library/Group Containers/group.com.apple.CoreSpeech/Caches`),
  and Restorey's own logs and settings. Logs elsewhere are backed up.
- **File types**, passed case-insensitively as `--iexclude=*.<ext>`, at any depth: disk images (`dmg`, `iso`,
  `sparseimage`) and virtual machine disks and bundles (`vmdk`, `vhdx`, `qcow2`, `pvm` and the like). The list
  is editable per plan (`fileTypeExclusions`): remove `dmg` to back up disk images. An entry must be a bare
  extension (`dmg`, or `tar.gz`), with no leading dot, slash, wildcard or space, or the plan is refused as
  invalid. The agent stores entries trimmed, in lower case and without duplicates.
- **Other filesystems mounted under a source** (`--one-file-system`, on by default), such as `~/OrbStack` or a
  connected iPhone's DeviceFS. A drive listed as a source is still backed up.
- **Items apps mark as not for backup**: Time Machine's per-item exclusion attribute
  (`com_apple_backup_excludeItem`), which macOS and apps set on data they can rebuild or download again, such as
  Lightroom previews, virtual machine disks, build folders and app caches. Restorey skips them as Time Machine does
  (`MarkedNotForBackup.swift`). Before each backup the agent asks Spotlight for them within the plan's sources, checks
  each still carries the attribute, folds items inside another (or inside an excluded folder) away, and passes the
  list to restic in a per-run file (`--exclude-file`, removed when restic finishes). Each plan has a switch for this
  (on by default) and a "Back up anyway" list (Settings → What → Show…). Spotlight is the source, so items in folders
  Spotlight doesn't index (indexing off, an unindexed drive, a folder on Spotlight's privacy list) are backed up.
  If the look takes over 10 seconds or finds over 100,000 items, that backup includes them all, and while a look
  Spotlight never answered is still outstanding no new one starts (one blocked thread at most). Without Full Disk
  Access the What tab's list may be incomplete, and says so; backups are unaffected. The count
  is recorded on the backup's run record and is never a warning.

restic also skips folders tagged with `CACHEDIR.TAG` (`--exclude-caches`) and iCloud files that aren't
downloaded to this Mac (`--exclude-cloud-files`). Time Machine's own exclusion list can't be read on macOS 27,
so Restorey doesn't try. Plans saved by an earlier build get the file types and the one-file-system setting when
`config.json` is upgraded to schema 2; their folder exclusions are kept as they were (defaults added later, such as the CoreSpeech folder, reach new plans
only: add them to an existing plan under Settings → What, Review Exclusions…). Before a file is
rewritten by an upgrade, the old one is kept beside it as `config.json.v1.bak` (`<file>.v<schema>.bak`, readable
only by you). If an upgrade fails, the agent says so and leaves the file alone.

## `config.json`

`config.json` (schema 3) holds the plans and, beside them, the Mac-wide network settings (`network`): an upload
limit shared by the backups to networked repositories (none by default), whether to skip a backup on a
constrained or expensive network (on by default), and Wi-Fi network names to skip backups on (none by default).
These rules apply only to a repository on another machine; a backup to a folder or an external drive ignores them.
A backup to a networked repository gets restic's `--limit-upload` set to the smaller of the plan's own limit and
its share of the Mac-wide one: the Mac-wide limit divided by the backups to networked repositories uploading when
it starts, counting itself (never below 1 KiB/s). restic can't change the limit mid-run, so a backup keeps the
share it started with. A backup to a folder or drive gets the plan's own limit alone. Wi-Fi names are matched
ignoring case and surrounding spaces (not accents), and a backup on a listed network is recorded as "Skipped on
Wi-Fi “<name>”". The app saves these settings through the agent, which refuses an upload limit of 0 or less, an
empty Wi-Fi name and a name listed twice, with the reason, and saves the names trimmed. The agent reads the
Wi-Fi name itself (CoreWLAN) just before a backup to a networked repository, and only when the list isn't empty;
a name it can't read (no Location permission, or not on Wi-Fi) never skips a backup.

**Location permission.** macOS reveals the Wi-Fi network's name only to a process with Location Services
permission, so the agent, which reads it, needs its own. Restorey asks for it only when you first add a Wi-Fi
network to skip in Settings → Network, never during setup; the app asks the agent over XPC
(`requestLocationPermission`), and the prompt
names the agent's display name ("Restorey", or "Restorey Dev" for a Debug build) and says "Restorey checks the
Wi-Fi network's name so it can skip backups on networks you've listed." Once you have answered, macOS doesn't
ask again; change it in System Settings → Privacy & Security → Location Services. The agent carries the usage text
under `NSLocationUsageDescription` and `NSLocationWhenInUseUsageDescription`, and the hardened runtime's
`com.apple.security.personal-information.location` entitlement; `scripts/verify-bundle.sh` checks all three.
The agent reports the authorisation in `hello` (`locationAuthorised`) from what Core Location last told it,
never by asking, and logs each request's answer and whether the Wi-Fi name was then readable. With Location
Services switched off for the whole Mac, macOS shows no prompt and can leave the agent undecided, so a request would
otherwise wait out its 570-second bound: the agent checks `CLLocationManager.locationServicesEnabled()` first (off
the main thread, which Apple asks for, since it is a synchronous call to locationd, and for 3 seconds at most before
taking the last value known) and answers at once with `servicesEnabled: false`, making no other Core Location call
(the status is the one Core Location last reported). The switch is read only on events: each change Core Location
reports, and each `locationAccess` call, which the Network pane makes when it appears and whenever Restorey comes
to the front, and which answers at once with the switch and the authorisation, never asking. The hello carries the
last value read (`locationServicesEnabled`) and never reads it. The logic is `LocationAccess` (AgentCore), tested
against a fake Core Location; `Agent/LocationPermission.swift` wraps the one `CLLocationManager` around it. A Release log
never names the network; a Debug build's log does, and also logs each name a backup's checks read. The Debug
developer window's "Request Location" button sends the request and shows the reply.
Each plan also records when its setup finished (`setupCompletedAt`, set when its recovery kit is first confirmed
and never cleared), so a plan whose kit must be confirmed again is told apart from one whose setup was never
finished, and whether the "No off-Mac monitoring" note was dismissed. The agent owns both setup dates and the
dismissed note; a saved plan can't change them (only confirming the recovery kit and `dismissOffMacNote` do).
Upgrading from schema 2 moves the per-plan "skip on a constrained network" setting to the Mac-wide one, which
stays on if any plan had it on (an upgrade with every plan's setting off turns it off), and marks every plan
whose recovery kit was already confirmed as having finished setup.

## Alerts

**Check-in pings.** If a plan has a check-in URL (a Healthchecks-style dead-man's switch, kept in the
Keychain), the agent POSTs to the URL itself when a backup succeeds and to `/fail` when it fails. It never
sends `/start`: Healthchecks.io treats a check that was told a run started and then hears nothing within its
grace time as down, and a paused, cancelled or lock-retried run has no honest ending to send, so a start ping
would raise a false alarm on every Pause. Paused, cancelled, skipped and lock-retried runs send nothing, nor does
a run the system stopped at logout or shutdown. The `/fail` body is plain text: restic's exit code (or "not
started" for a failure found before restic ran, or "interrupted") and the last 20 lines of the run's error
output, with secrets removed. A network error or a 5xx is retried after 5 s, 30 s and 120 s; a 4xx is not. Each request
times out after 30 s without data or 60 s in all, and one send, retries included, is bounded at 170 s, inside
the 3 minutes the agent waits for pings before exiting for an update. A plan's pings go out one after another,
so a ping queued behind an earlier one for the same plan that is still being retried can take longer; the
agent then exits anyway and logs it. A ping that fails is written to the agent's
log as "check-in ping <kind> for <plan ID>: <outcome>", never with the URL, and never fails the backup. If
the service answers a ping with a 4xx, the plan shows "Check-in URL rejected" and the agent notifies, because
the service won't alert anyone if backups stop; the next successful ping, or changing or removing the URL,
clears it. Set the
check's period and grace on the service to the plan's "no successful backup" threshold (3 days by default),
not to its hourly schedule.

**Notifications.** The agent posts a macOS notification when a backup or a repository check fails, when a plan
stops (a wrong password, say), when Full Disk Access is missing and when a plan has had no successful backup
for 3 days, and when a check-in URL is rejected. It re-notifies while the problem lasts: at once, then after 1 hour, 6 hours, and every 24 hours,
and starts again at once if the problem clears and comes back. A re-notification replaces the earlier banner,
and Full Disk Access has one banner however many plans need it. The agent checks this every minute and whenever
a plan's status changes, and keeps the bookkeeping in `state.json` (`activeAlerts`), so a restart doesn't
repeat a recent notification. Each call to the notification centre gets 10 s; one that doesn't answer counts
as not delivered and never holds up a backup; while a call is still waiting for an answer, no second one is
made, and a permission check that doesn't answer keeps the last answer it gave. A call still waiting after
10 minutes is abandoned and tried afresh; an abandoned permission check shows "notifications off" until
macOS answers again. If `config.json` or `state.json` can't be read, the agent posts
one notification, "Restorey has stopped — its settings can't be read", on the same schedule.

The agent needs its own notification permission, separate from the app's, and macOS reports a notification
from an agent without one as posted while showing nothing. So the agent checks its permission before posting.
Without it, it posts nothing, raises "notifications off" for the menu bar to show, and holds the alerts back
until permission is granted. The agent carries the app's display name (`RESTOREY_DISPLAY_NAME` in
`Config/Debug.xcconfig` and `Release.xcconfig`: "Restorey", or "Restorey Dev" for a Debug build), so its
permission prompt, its banners and its entry in System Settings → Notifications read as Restorey, not as a
separate agent. `scripts/verify-bundle.sh` checks that both bundles carry it. Login Items names the agent by its
executable instead (`RestoreyAgent`, or `RestoreyDevAgent`).

## When backups run

The agent's scheduler (`RestoreyCore/Sources/AgentCore/SchedulerCore.swift`, wired up in
`Agent/Scheduler.swift`) wakes when the next plan falls due, and at least once a minute, so an hourly plan
starts on its hour rather than drifting later each run; a changed plan, a wake or a mount wakes it to look
again. It starts after recovery has finished,
and its first check waits for the network as a wake does (at most 2 minutes), so a backup due at login isn't
skipped for a network that is still coming up. A plan is
due an interval (an hour for hot plans) after its last attempt, counted in elapsed time, so a time zone or
daylight saving change never moves a run. It also looks again straight away:

- **after waking from sleep**, once the network is back (it waits at most 2 minutes, then goes ahead), so a run
  missed while the Mac slept catches up without failing on a network that isn't up yet;
- **when the network comes back** (the path goes from offline to online while the Mac is awake), running any
  plan that was skipped for no network;
- **when a volume mounts**, running any plan that was skipped because that drive wasn't plugged in;
- when a plan is saved, its recovery kit is confirmed, or it is resumed.

A skipped run (on battery below the plan's threshold, a constrained or expensive network such as a phone
hotspot or Low Data Mode while the Mac-wide "skip on a constrained network" setting is on, a Wi-Fi network in
the Mac-wide skip list, no network, an unmounted volume) is recorded and tried again at the next interval, or
sooner when the network comes back or the volume mounts, as above. A backup that met another client's lock, was
stopped by the system at logout or shutdown, or was interrupted because the agent stopped mid-run, is retried 15
minutes after it started (not at once, so
something that kills the agent on every run can't loop); a paused plan runs as soon as its hour is up. One plan
never runs twice at once; different plans can, and plans that share a repository take turns. While restic runs, the agent
holds a power assertion that stops the Mac idle-sleeping ("Restorey backup" in `pmset -g assertions`); the
display can still sleep, and closing the lid still sleeps the Mac. When the agent is finishing up for a
restart, the scheduler stops.

## How secrets reach restic

Repository passwords, and keys for S3 (including Backblaze B2 through its S3 endpoint), are read from your
Keychain by Restorey's background agent and handed to restic through a pipe. They are never written to disk
or put in environment variables. Credentials for other backends, including repositories that use restic's
native `b2:` backend, are passed to restic as environment variables while it runs. Other programs running as
you can read those.

How it works (design spec §7; [spike findings](docs/spike-findings.md) H2 and H4):

- restic runs the agent's own executable as `RESTIC_PASSWORD_COMMAND`
  (`RestoreyAgent print-password --plan <id>`) and, for S3 and B2, as the `credential_process` in a per-plan
  shared-credentials file (`RestoreyAgent s3-credentials --plan <id>`). That file holds only the command line,
  never a key. The route itself was verified against a real B2 bucket through its S3 endpoint with a test
  helper: restic ran it once per command. Restorey's own helper was checked end to end in the v0.1 alpha: a
  23-minute, 15 GB first backup to B2 asked it once for the password and once for the keys, and never during
  the upload.
- The helper holds no secrets. It asks the running agent over XPC. The agent accepts the connection only
  from its own executable, signed by the same team (checked against the caller's audit token). It then
  checks that the caller's parent process is a restic that the agent itself started and is still
  supervising, for the plan named in the request. Only then does it read the Keychain and reply.
- Run by hand, from Terminal or any other program, the helper gets nothing: it exits 1 and prints nothing.
- For S3 the helper prints `Version`, both keys and an `Expiration` 12 hours ahead, so restic asks once per
  run rather than once per request. The helper refuses to run (exit 2) if its own path contains a space,
  because the `credential_process` line can't be quoted. Its errors go to the unified log (subsystem
  `com.jaydenkerr.restorey`, or `com.jaydenkerr.restorey.dev` for Debug builds, category `helper`), not
  stderr, which restic's S3 library discards.
- The agent trusts a restic by its process ID and start time together, and stops trusting it the moment it
  exits, so a later process that reuses the same ID is never mistaken for it.
- Settings tries a changed repository password, with any storage keys or environment values typed with it, before
  saving them (`probeRepositoryCredentials`): the agent holds them in memory for the plan (`CandidateSecrets`)
  only during that check's turn of the repository's queue, when no other restic of the plan or its repository can
  run, and the helper hands them to the check's restic instead of the Keychain's (a typed environment value goes
  into its environment). They are added to the redactor, never saved, and cleared when the turn ends, however it
  ends.

What this doesn't protect against: an attacker who can hijack a restic process Restorey is supervising could
obtain that plan's secrets; any program running as you can already do a great deal.

## Why the keychain tests need a signed host

Restorey keeps every repository password, backend key and check-in URL in the data protection keychain
(design spec §7 and §10), never the legacy file keychain that `/usr/bin/security` can read. The data
protection keychain only works for code that carries the `keychain-access-groups` entitlement, which needs a
signed app with a provisioning profile. Under bare `swift test` there is no such app, so `SecItemAdd` and
`SecItemCopyMatching` fail with `-34018` (`errSecMissingEntitlement`). Dropping `kSecUseDataProtectionKeychain`
in tests would pass but test the wrong keychain, so the keychain tests are not in `RestoreyCore`'s package suite.

They live in the `AgentHostedTests` bundle, which runs inside the signed Debug agent
(`xcodebuild test -scheme AgentHostedTests -configuration Debug`). `scripts/ci.sh` runs them only when
`Config/Local.xcconfig` exists. On GitHub Actions it doesn't, and the script prints
`hosted keychain tests skipped: no signing` instead. The tests use a random plan ID each and delete what
they create, so they never touch real Restorey items.

The test host is the agent's own executable, launched by XCTest from DerivedData, so it carries the real Debug
identity. The agent therefore runs its start-up only as the launchd job for its label: launchd sets
`XPC_SERVICE_NAME` to the label in the job's environment (`launchctl print gui/$(id -u)/<label>` shows it), and
any other process sees something else (for example `0` from a login shell, `application.<bundle id>…` for an app launched by
macOS). Under XCTest (`XCTestConfigurationFilePath` and friends set) the agent does nothing but let XCTest run;
otherwise it logs one line to the unified log (category `agent`) and exits with status 78. Either way it writes
nothing to `agent.log`, loads no `config.json` or `state.json`, and starts no listener, recovery or scheduler,
before or after (`AgentLaunchRole`, Ruling R66). Hosted tests must not refer to the real logs, Application
Support or caches folders or the installed app; `scripts/ci.sh` checks that. The confused-deputy check, the
installed helper run by hand and refused by the running agent, is a live check instead:
`scripts/check-helper-refusal.sh`, with `RestoreyDev.app` installed by `scripts/install-dev.sh`, opened once so it
registers its agent, and the agent restarted after each later install
(`launchctl kickstart -k gui/$(id -u)/com.jaydenkerr.restorey.dev.agent`). The hosted build goes in `~/Library/Caches/restorey-ci`
(override with `RESTOREY_HOSTED_DERIVED_DATA`), not `build/`, because macOS blocks launching an app from
`~/Documents` on a privacy prompt that nobody is there to answer.

## The recovery kit

A repository password that exists only in the Keychain of a lost Mac opens nothing, so every plan has a recovery
kit (`RecoveryKitDocument`, from the agent's `recoveryKit` reply): the repository address and password, the
storage keys (an S3 or B2 plan's key ID and secret key, or each environment variable of another location), the
host label this Mac's snapshots are under, the commands below, and the check-in URL when the plan has one. A kit
missing any secret isn't shown: the agent refuses it, naming the Keychain item, and the app shows that sentence.

It appears in setup's recovery kit step, from the menu's "New recovery kit needed — Save Recovery Kit…" and from
"Show recovery kit…" in the plan's settings. Each field has a copy button (secrets are copied as concealed
pasteboard items, so clipboard managers that honour the marker don't keep them), then **Print…** and **Save as
PDF…**. The save panel picks no folder for you, and if the PDF lands on this Mac's own disk the window says so and
recommends deleting it once the kit is stored elsewhere. The PDF is laid out in memory, written to a temporary file
created readable only by you (`mkstemp`, mode 0600) in the folder you picked, flushed to disk and renamed over the
target (`PrivateFile`), so no copy is ever readable by others and a failed save leaves nothing behind. Restorey
never writes the kit anywhere by itself. The kit saved during setup comes before the schedule step, so it has no
check-in URL (it isn't needed to restore); the kit window includes it once it is saved, and the schedule step says
so.

Outside setup the kit window asks for Touch ID or your login password first (`OwnerAuthentication`), once per
opening, and only then fetches the secrets; closing the window drops them. Only a plan that has finished setup
opens there (the agent's `setupCompletedAt`, set by the first confirmation and never cleared); an unfinished one
offers "Finish Setup…". The kit's secrets show as dots, with the same "Show Passwords and Keys" / "Hide Passwords and
Keys" button and Option peek as Restore Files (in setup's kit step too); after a declined prompt, approving through
"Show Recovery Kit" shows them at once. Whichever way a Touch ID or password prompt ends, the window that asked is
made key again and Restorey brought back to the front. For a plan needing a new kit, the window is headed "Save a new recovery kit — the saved one
has the old keys" and its tick "I've saved it somewhere other than this Mac" confirms the kit with the agent, which
lets backups carry on. Before confirming, the window checks the kit against the agent's current secrets, so a kit
whose keys changed while it was open is shown again rather than confirmed.

A plan needs a new kit when what the kit holds to open and restore its repository changes: saving a different
repository password or storage key (or environment value), or a new host label (the kit's restore commands pass it
as `--host`, so an old kit would restore the old group's latest snapshot), clears the kit's confirmation, and the
plan's backups wait until the new kit is saved and confirmed. A new host label doesn't clear a stopped plan's stop;
only a new address or key can cure one. Adding, changing or removing the check-in URL doesn't need a new kit: it
isn't needed to restore, so answering "No off-Mac monitoring — Add…" never stops backups.

**Restore Files…** in the menu opens the same commands for the chosen plan (a plan picker switches between
plans). Passwords and keys show as dots. "Show Passwords and Keys" shows them and keeps them shown (the button
becomes "Hide Passwords and Keys") until it is pressed again, the window stops being the key window, or it closes;
holding Option shows them only while it is held, for a quick look (`SecretReveal`). Each command has a copy
button that copies the real command. The first reveal or copy of a command that carries secrets (decided from the
plan, so a copy before any reveal still asks and copies the real values) asks for Touch ID or your login password,
once per opening, and the secrets are fetched only then and dropped when the window closes or another plan is
picked. Approving through the button shows them at once: Restorey waits (up to a second) for the window to come
back from the prompt (to lose the key window to it and become key again, since the prompt's answer can arrive before
macOS says the window lost the key), then fetches the secrets, and shows them only if the window is still key, so
switching away meanwhile leaves dots (`KeyWaiter`, `RevealOrder`). Closing the window, or picking another plan,
during the prompt or that wait ends the wait at once, and nothing is fetched for it (the kit window too). If you decline, holding Option doesn't ask again in that
opening; "Show Passwords and Keys…" or a copy does. A Mac that can't ask at all (no login password set, say) says so and why, rather than asking you to try
Touch ID.

## Restoring without Restorey

Your backups are plain restic repositories, so restic alone can restore them. Install
[restic](https://restic.net), then paste these into Terminal in order, with the values from your recovery kit
(the kit and Restore Files give them filled in):

```sh
export RESTIC_REPOSITORY=s3:https://s3.us-west-004.backblazeb2.com/my-bucket/macs/pepper
export RESTIC_PASSWORD='your repository password'
export AWS_ACCESS_KEY_ID='your key ID'
export AWS_SECRET_ACCESS_KEY='your secret key'
restic snapshots --host pepper
restic restore latest --host pepper --target ~/Restored
```

The first lines tell restic where the repository is and how to open it: an S3 or B2 plan (B2 through its S3
endpoint) uses the two `AWS_` keys; another location exports its own environment variables instead (for example
`RESTIC_REST_USERNAME` and `RESTIC_REST_PASSWORD`), and a folder or drive needs none. `restic snapshots` lists this
Mac's snapshots (`--host` is the kit's host label), and `restic restore latest` restores the newest of them into a
folder called `Restored` in your home folder, under each file's original path. Every password and key is
single-quoted so the shell reads it exactly, spaces, quote marks and non-ASCII letters included; the repository
address and host label are quoted only when they hold characters the shell would treat specially.

The password is the one restic knows. Restorey hands restic the stored password through
`RESTIC_PASSWORD_COMMAND`, and restic trims white space from the ends of what that command prints, while it reads
`RESTIC_PASSWORD` as it is; so for a password typed with a space or newline at either end, the kit gives it without
them, which is the password the repository really has (checked against restic 0.19.1, and by
`RestoreCommandsTests` end to end).

## Licence

MIT. See [LICENSE](LICENSE).

Generated repository passwords use the Electronic Frontier Foundation's large word list
(`RestoreyCore/Sources/RestoreyCore/Resources/eff_large_wordlist.txt`, 7,776 words, vendored unchanged from
<https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt>, SHA-256
`addd35536511597a02fa0a9ff1e5284677b8883b83e986e43f15a3db996b903e`), © Electronic Frontier Foundation, used under the
Creative Commons Attribution licence (CC BY 3.0 US when EFF published the list in 2016; EFF's copyright policy now
offers its original material under CC BY 4.0, <https://www.eff.org/copyright>). A password is six words drawn with
the system's secure random number generator, joined by hyphens: about 77.5 bits.
