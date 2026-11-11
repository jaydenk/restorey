# Restorey

A free, open-source macOS menu bar app that puts an Arq/Backblaze-style front end on
[restic](https://restic.net).

> **Status: design stage.** There is no app to download yet. The design is approved and the
> platform spike is done ([findings](docs/spike-findings.md)); v0.1 engine work has begun with the project scaffold.
> Nothing here is ready to protect your data.

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
- [Platform spike plan](docs/superpowers/plans/2026-11-10-platform-spike.md)
- [Platform spike findings](docs/spike-findings.md) (throwaway spike code in [`spike/`](spike/))

## Building from source

Prerequisites: macOS 27, Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

1. Fetch the pinned upstream binaries (restic 0.19.1 and rest-server 0.14.0, checked against each release's
   `SHA256SUMS`) into the gitignored `vendor/` folder:

   ```sh
   scripts/fetch-binaries.sh
   ```

2. Run the CI checks: the `RestoreyCore` tests, an unsigned Debug build and the bundle checks. If
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
- switched off in Login Items: "Background agent is switched off", with "Open Login Items". Never switched
  back on by Restorey. (macOS also quits Restorey when you switch the agent off, so this shows on the next launch.)
- registered but not answering: "Background agent isn't running", with "Restart Agent" and "Open Login
  Items". After 30 seconds without an answer it unregisters and registers the agent again on its own. A
  switched-off agent reads differently (see `docs/spike-findings.md`), so this never overrides your choice

When an update lands while a backup runs, the old agent finishes only the restic step in progress and starts no
new one, since restic would run the new helper, which the old agent refuses. A backup still waiting its turn shows
"Skipped: Restorey was updating" and the new agent runs it at once. The agent also notices on its own (within
a minute, or before its next restic step) that its executable was replaced, and restarts itself, even if the app
isn't running.

A stale agent is restarted before any re-registration, since an older agent may not know the newer
`prepareForReregistration` call. Automatic repairs happen at most once an hour for each kind (restart,
re-register), also across relaunches (a new version or build may repair at
once). Plan lines are shown only while the agent is healthy, and are fetched afresh each time it becomes healthy.
The icon shows an error for a stopped plan, a settings error, a failure alert or an agent that isn't running, a
warning for a skipped run or missing notifications, check-in or recent success, and is plain otherwise.
**A copy anywhere else does nothing to the agent**: no XPC, no
registration and not even a status read, which on its own can re-point the registration at the copy. It only
shows "Move Restorey to Applications". The app's log is `~/Library/Logs/Restorey-Dev/app.log`.

A Debug build adds a "Developer…" menu item. Its window saves plans (S3, B2 or a raw local repository path such
as `/tmp/restorey-dev-repo`), creates or adopts repositories, confirms the recovery details, backs up, pauses,
resumes, asks for notification permission, and shows the agent's live status as JSON.

```sh
launchctl print gui/$(id -u)/com.jaydenkerr.restorey.dev.agent        # spawn type = daemon (3), both Mach services
```

The agent serves its XPC interface only to the signed app: the listener requires the app's bundle ID and the
team in `Config/Local.xcconfig`, so any other process is refused. It is the only writer of `config.json`,
`state.json` and the plans' keychain items, all under `~/Library/Application Support/<root ID>` (mode 0700).
If either file is corrupt or was written by a newer Restorey, the agent reports it in `status`, refuses every
change and leaves the file as it is. Its log is `~/Library/Logs/Restorey-Dev/agent.log`, and MetricKit
diagnostics go to `diagnostics/` beside it.

## What a backup run does

The agent's plan runner (`RestoreyCore/Sources/AgentCore/PlanRunner.swift`) runs each backup in this order:

1. Refuses a plan that is invalid or whose recovery kit hasn't been confirmed, without running restic.
2. Checks the plan's conditions (network, battery, mounted volumes, sources that exist). A skipped run (on
   battery, no network, an unmounted volume) is recorded but sends no check-in ping.
3. Checks Full Disk Access by listing a protected folder (`~/Library/Safari`, `Mail` or `Messages`, never a
   file's contents). Without it the run fails with "Full Disk Access is missing" and restic doesn't run,
   because restic would otherwise save a snapshot of empty folders.

   A failure found in steps 1 to 3 (an invalid plan, a missing source, Full Disk Access missing) sends the
   check-in `/fail` ping with the reason. A plan whose recovery kit isn't confirmed yet sends nothing.
4. Runs `restic backup` through the repository's queue, classifies the result, records it, and sends the
   success or `/fail` ping straight away, so maintenance never delays it.
5. After a successful backup, in the same turn of the queue: `forget` (after every backup that made a
   snapshot, or daily for an adopted repository), `prune` weekly when it is switched on, and a plain
   `unlock` followed by `check` weekly. Each is its own run with its own log; a failed `check` raises its own
   alert and never turns the backup into a failure.
6. Records every step in `state.json` as it ends and raises or clears the alerts.

A wrong repository password, a missing repository or unreadable backup keys (including a password the helper
couldn't read from the Keychain) stop the plan until its repository or secrets are changed, or a later backup
succeeds. Pause stops a run in progress (SIGINT, then SIGKILL after 10 s) and resumes after an hour. Resume on a
paused plan starts a fresh backup at once, exactly as Back Up Now does (so it can still be skipped on battery or
without a network); a stopped plan's pause is cleared but nothing runs until it is fixed. Restorey
never runs `restic init` except from the explicit "Create new repository" action. That action first runs
`restic cat config`: if a repository is already there it refuses ("A repository already exists there"), and it
initialises only when restic reports nothing at the address. Restorey never creates an S3 or B2 bucket: create
it in your provider's console first. Adopting a repository only lists its snapshots.

Every restic run has its own log in `~/Library/Logs/Restorey/runs/<plan ID>/` (`Restorey-Dev` for Debug builds),
with secrets redacted. If the agent stops mid-run, its next start records that run as interrupted (an
interrupted backup sends its `/fail` ping) and runs a plain `restic unlock` (never `--remove-all`) once per
repository, before it accepts any run. Before exiting for an update, the agent finishes the run in progress and
then waits up to 3 minutes for queued check-in pings.

## Alerts

**Check-in pings.** If a plan has a check-in URL (a Healthchecks-style dead-man's switch, kept in the
Keychain), the agent POSTs to the URL itself when a backup succeeds and to `/fail` when it fails. It never sends
`/start`: Healthchecks.io treats a check that was told a run started and then hears nothing within its grace
time as down, and a paused, cancelled or lock-retried run has no honest ending to send, so a start ping would
raise a false alarm on every Pause. Paused, cancelled, skipped and lock-retried runs send nothing. The `/fail` body is plain text: restic's exit code and the last 20 lines of the run's error output, with
secrets removed. A network error or a 5xx is retried after 5 s, 30 s and 120 s; a 4xx is not. Each request
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
`Agent/Scheduler.swift`) checks every minute for plans that are due. It starts after recovery has finished,
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
hotspot or Low Data Mode, no network, an unmounted volume) is recorded and tried again at the next interval, or
sooner when the network comes back or the volume mounts, as above. A backup that met another client's lock, or
was interrupted because the agent stopped mid-run, is retried 15 minutes after it started (not at once, so
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
  helper: restic ran it once per command. Restorey's own helper is checked end to end in the v0.1 alpha.
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
`hosted keychain tests skipped: no signing` instead. The bundle also runs the installed helper by hand
and checks the agent refuses it (`HelperEndToEndTests`), so it needs `RestoreyDev.app` installed with
`scripts/install-dev.sh` and opened once so it registers its agent, and the agent restarted after each later
install (`launchctl kickstart -k gui/$(id -u)/com.jaydenkerr.restorey.dev.agent`): the app restarts it on its
own only when the build number differs. Without that it fails rather than skips. The tests use a random plan ID each and delete what they
create, so they never touch real Restorey items. The hosted build goes in `~/Library/Caches/restorey-ci`
(override with `RESTOREY_HOSTED_DERIVED_DATA`), not `build/`, because macOS blocks launching an app from
`~/Documents` on a privacy prompt that nobody is there to answer.

## Restoring without Restorey

Your backups will always be plain restic repositories. If Restorey ever disappears, you can restore with
the restic command-line tool and the details from your recovery kit. Full instructions will be added here
before the first release.

## Licence

MIT. See [LICENSE](LICENSE).
