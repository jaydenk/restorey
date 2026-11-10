# Restorey — design

Date: 9 November 2026 · Status: approved by the owner on 9 Nov 2026, including all (review 3) and (review 4) items; updated with the platform spike findings on 10 Nov 2026 · Author: Jayden Kerr (with Claude)

Restorey is a free, open-source macOS app that puts an Arq/Backblaze-quality front end on
[restic](https://restic.net). In the owner's words: "an open source version of Arq based on restic."

Provenance of each decision is marked:

- **(decided)** — the owner said this during brainstorming.
- **(my call)** — Claude's default, which the owner hasn't objected to. The builder may revisit it, but should flag the change.
- **(builder)** — deliberately left to whoever plans and builds it.
- **(review 3)** — added in the third review pass on 9 Nov 2026 after checking restic 0.19.1's documentation and source. The owner approved all of them on 9 Nov 2026.
- **(review 4)** — five architectural gaps raised in the fourth review pass on 9 Nov 2026 and accepted by the owner: agent notification identity (§8), how backend credentials reach restic (§7), agent liveness without a check-in URL (§6.2), agent restart on manual updates (§8), and where the recovery kit is saved (§7).
- **(spike)** — changes from the platform spike on 10 Nov 2026 (`docs/spike-findings.md`). The owner chose the three marked "(spike, decided)": the keychain helper's parent-chain check, S3 `credential_process` for S3 and B2, and `ProcessType=Standard`.

---

## 1. Intent and why

The owner needed an offsite backup for their Mac. The cheapest good option was restic → Backblaze B2, at about US$42/yr for ~0.5 TB. Backblaze Personal costs US$99/yr and Arq costs US$60–70/yr.

restic is excellent but has no native Mac experience:

- no menu bar status
- no Time Machine-style browsing
- nothing that keeps running and tells you when it has stopped

The existing Mac front ends were reviewed on 9 Nov 2026 and are either small and dated or very large and aimed at other platforms (§11).

Restorey is that missing front end, built for anyone in the same position, not just the owner.

**Audience (decided).** People who already know what restic is and want a polished Mac app that lets it replace Backblaze or Arq. It is not aimed at people who have never heard of a repository or a password-protected backup. The UI can use restic's vocabulary (repository, snapshot, prune) without explaining it at length.

**Thin wrapper (decided).** restic does the heavy lifting: deduplication, encryption, storage backends, retention, integrity checks. Restorey covers:

- scheduling
- configuration
- secrets
- status
- the restore UI
- alerts

Restorey should never reimplement anything restic already does. Where restic falls short, keep the gap-filling code small and isolated. The one known case is cold-storage thaw (§5.3).

**What success looks like.** A restic-literate user installs Restorey, then either points it at a new bucket or an existing repository, and from then on:

- it backs up without being thought about
- it says loudly when something is wrong
- restoring a file from three weeks ago takes a minute and feels like Time Machine

## 2. Goals

1. A menu bar app that shows backup state at a glance and lets you act: last and next backup, live progress, Back Up Now, Pause. **(decided)**
2. A Time Machine-style restore: Finder column hierarchy, a timeline to move through snapshots inside that hierarchy, and restore to Downloads. **(decided)**
3. Several independent backup plans, each with its own repository, sources, schedule and retention. Example: an hourly hot plan to B2 alongside a long-term cold plan to S3 Glacier Deep Archive. **(decided)**
4. Backups run whether or not the app's window or menu bar process is open, and catch up after sleep.
5. Failures and silent stops reach the user through channels they already use.
6. Existing restic repositories can be adopted without losing their history. **(decided)**

## 3. Non-goals

- **Not a sync tool.** It adds no data-handling logic of its own beyond a disposable local cache (§7).
- **No plain-text or CLI-compatible config required.** "If people wanted that they could use the restic cli." Plain text is acceptable if it falls out naturally, but it is not a requirement. **(decided)**
- **No parsers for other tools' configs** (resticprofile, autorestic, Backrest) in v1. Import means "point at a repository." **(decided)**
- **Mac only.** No Linux or Windows. Not distributed through the Mac App Store, because the sandbox rules out the Full Disk Access a backup tool needs. **(my call)**
- **No restic fork or patches.** Use upstream release binaries only. **(my call)**
- **No price calculator.** The app tells users to check their provider's pricing and shows real counts and sizes, but never shows dollar figures, because prices change and differ by region. **(decided** that users must be told to check pricing; **my call** on not showing figures)

## 4. Anti-goals — failure even if it "works"

The owner named two outcomes that would make the project a failure (decided):

1. **Backups stop silently and nobody notices until a restore is needed.** The owner's own serrano restic job failed every night from 9 May to 5 Nov 2026 without anyone being told.
2. **The repository becomes corrupted and the app never realises.**

Everything in §6 exists to prevent these two. Any design trade-off that weakens either is wrong, even if it simplifies the code.

A third anti-goal (my call): **the app implies protection it isn't providing.** Examples:

- showing a green tick when iCloud files were skipped, without saying so
- calling a cold plan "verified" when its data cannot be read

Status text must be honest about coverage.

## 5. Functional design

### 5.1 Menu bar (decided, mockup approved)

Mockup: `docs/mockups/menubar-and-restore.html` (copied from the AGENT brainstorm session). The owner's verdict was "that's good."

- **Idle state:**
  - status line, e.g. "Up to date"
  - last backup time and amount uploaded
  - next backup time
  - destination summary (provider · bucket · repository size)
  - Back Up Now, Restore Files…, Settings…, Quit
- **In-progress state:**
  - progress bar
  - bytes and files remaining
  - estimated time left
  - upload speed
  - Pause Backup
  - Restore Files…, Settings…, Quit
- **Live updates.** The menu updates while open: it must not be a snapshot taken when the menu opened. Restic Station has this flaw; avoid it.
- **Multiple plans** (my call):
  - The icon shows the worst state across all plans.
  - The menu lists each plan with its own status line.
  - Back Up Now applies to all plans, with a submenu for individual plans.
- **Icon states** (my call): idle/OK, backing up, paused, warning (e.g. skipped files, check overdue), error. Error must be visually distinct at a glance.
- **Not yet mocked up (my call; mockups needed before building these screens).** The approved mockup was drawn before the decisions below and shows only a single plan in the idle and in-progress states. The following need a mockup and the owner's sign-off first:
  - the menu with several plans, each with its own status line, and the Back Up Now submenu
  - the paused, warning and error states of both the menu and the icon, including what makes error "visually distinct"
  - the per-plan markers on the restore timeline, and the option for which plan to restore from
  - the "needs thaw" label on cold plans, in the timeline and the menu
  - (review 3) the host picker in the restore window, the recovery kit sheet, and the "Up to date — no changes" idle variant
  - (review 4) the "Background agent isn't running" error with its Restart agent action, and the "No off-Mac monitoring" note
  - (spike) the "Notifications are off — Restorey can't alert you" warning, the "Full Disk Access is missing" error (distinct from "some files skipped"), "Finishing the current backup before updating the agent", and the "Move Restorey to Applications" screen

**Pause (decided in principle).** restic has no native pause.

- Pause stops the restic process cleanly: SIGINT, then SIGKILL after a timeout. That is the Resticker pattern.
- Resume starts a fresh `restic backup`.
- Deduplication means data already uploaded is not uploaded again.
- The UI should say "Paused" (not "Failed"), and must not count a paused run as a failure for alerting.
- Auto-resume after a set time (e.g. 1 hour) is my call. Without it, a forgotten pause becomes anti-goal 1.

### 5.2 Restore window (decided, mockup approved)

- **Layout:** Finder-style column browser of the snapshot's file tree, with a vertical timeline on the right edge. Moving along the timeline keeps your place in the hierarchy and shows that folder as it was at the chosen snapshot.
- **Deleted items:** files that exist in an earlier snapshot but not the current one appear greyed out with "deleted <date>".
- **Search:** searches within the selected snapshot.
- **Restore action:** "Restore to Downloads" puts the selected files and folders into a new folder in `~/Downloads`, never overwriting anything. Restoring in place is out of scope for v1 (my call).
- **Speed comes from a local index (my call; required for the timeline to work).** Snapshots are immutable, so the app fetches each snapshot's full listing once (`restic ls --json <id>`) and caches it locally. Timeline moves and deleted-item detection then become local comparisons with no round trip to the storage provider. Resticker's approach of calling `restic ls` once per folder expand is too slow over B2 and cannot drive a timeline.
  - The cache is disposable: deleting it costs only a re-fetch.
  - It lives in `~/Library/Caches/<bundle id>/`.
  - The builder chooses its format and storage engine, e.g. SQLite with one table per snapshot or a content-addressed tree store (builder).
- **One combined timeline across all plans (decided).**
  - **What the timeline shows.** It merges snapshots from every plan that holds the path being browsed, keyed by absolute path on this Mac.
  - **Which plan a restore uses.** The timeline has an option for which plan to restore from (decided). When several plans hold the selected item at the chosen time, the default is a hot plan (my call). Cold plans are labelled "needs thaw".
  - **Marks on the timeline.** Each tick shows which plans it came from (my call: small per-plan markers).
  - **Deleted items.** "Deleted <date>" is worked out from the merged history (my call).
  - **Index cache.** It stays keyed per repository, and the merge happens at query time (my call). That way, removing a plan just drops its index.
- **Cold plans:** browsing works immediately, because restic keeps metadata in S3 Standard. A restore goes through the thaw flow in §5.3.
- **Restoring from another Mac (review 3).** The disaster this app exists for is "the Mac is dead or stolen." The replacement Mac has a different hostname and may have a different user name, so snapshots from the old machine are not "this Mac's" by path or host. The restore window must therefore:
  - let the user pick which host's snapshots to browse (default: this Mac), listing the hosts found in `restic snapshots --json`
  - show paths as they were on that host, not remapped to this one
  - restore them to Downloads like any other restore
  - Adopting a repository on a new Mac (§5.4) must make the old host's history available in the restore window immediately, before any backup from the new Mac has run.
- **Restore progress and cancel (review 3).** `restic restore --json` emits `status` messages (`percent_done`, `bytes_restored`, `files_restored`, `total_bytes`) and `error` messages per item. The restore window shows that progress, lets the user cancel (SIGINT, same as pause), and lists per-file errors at the end rather than failing the whole restore silently.

### 5.3 Plans and storage

- **Storage:** any restic backend. B2 and S3 get guided setup forms; anything else uses a raw repository string plus environment variables (my guess, which the owner accepted on playback).
  - **(spike, decided)** The B2 form sets up **restic's S3 backend against B2's S3-compatible endpoint**, not restic's native `b2:` backend. restic's own docs call this "the recommended way to utilize Backblaze B2", and it lets B2 keys go through `credential_process` (§7). Adopting an existing `b2:` repository still works. Restorey shows its repository string as it is, and may offer the S3 endpoint as an alternative.
- **Plan settings:**
  - name
  - repository
  - credentials
  - source folders
  - exclusions
  - schedule
  - conditions
  - retention
  - alert routing
  - hot or cold type
  - upload bandwidth limit (review 3): restic's `--limit-upload` (KiB/s), off by default. Every comparable backup tool offers this and restic supports it natively, so there is no reason to leave it out.
  - stable host label (review 3): see §5.4. The plan stores the `--host` value it passes to restic.
- **One plan, one repository, one restic invocation per run.** If two plans share a repository, their runs must be serialised to avoid lock contention (my call).
  - **The per-repository queue covers every restic command, not just `backup` (review 3).** `check`, `forget` and `prune` all take an exclusive lock (`check` verified in `cmd/restic/cmd_check.go`: it calls `openWithExclusiveLock`), so a weekly `check` that starts while an hourly backup is running fails with exit code 11. One actor per repository owns the queue; backups, checks, forget, prune and the test restore all go through it.
  - **Short waits use restic's own `--retry-lock` (review 3)** rather than a hand-rolled loop: `--retry-lock 5m` on maintenance commands lets restic wait for another client to finish. If the lock still can't be taken, the run is rescheduled and the "never break someone else's lock" rule in §5.6 applies.
- **Pack size on cloud backends (review 3).** restic's default target pack size is 16 MiB. Cloud providers bill per request and per listed object, and a 0.5 TB repository at 16 MiB is tens of thousands of objects. For repositories Restorey creates on B2 or S3, pass a larger `--pack-size` (builder picks the value from restic's tuning documentation and records the memory trade-off; 64 MiB is a reasonable starting point). Adopted repositories keep whatever they have. This applies to `backup` and `prune` and must be the same value on both.

**Cold plans (decided, v1).** These copy the owner's working `photos-offsite` setup (`homelab-services/photos-offsite`, runbook `docs/runbooks/photos-offsite-restore.md`). That setup has been tested with a full drill on 1.6 TB.

- **Backup:** `restic backup -o s3.storage-class=DEEP_ARCHIVE …` (or another archive class). restic stores data packs in the archive class and metadata in Standard.
- **Restore:** do not use restic's `RESTIC_FEATURES=s3-restore`. The FAQ describes it as "early alpha" and it has open bugs on 0.19.1: #22094 never requests the thaw, #5659 fails with "202 Accepted". Instead:
  1. Show a confirmation before anything is requested. It lists the real object count and total size of archived `data/` objects, the expected ready time, and the cost-check warning.
     - **Retrieval tier is the user's choice (review 3).** AWS documents Deep Archive retrievals as "within 12 hours" for Standard and "within 48 hours" for Bulk; Expedited is not available for Deep Archive. The confirmation offers both, defaulting to Bulk (cheapest), and says plainly that Standard costs more per GB. In an emergency, 12 h versus 48 h matters.
  2. List every archived object under `data/` and send an S3 `RestoreObject` request for each, using the chosen tier and a user-chosen number of days. Run requests in parallel and treat `RestoreAlreadyInProgress` as success. This is a port of `homelab-services/scripts/request-deep-archive-restore.sh`.
     - **Throttling (review 3).** S3 applies a restore-request quota of about 1,000 requests per second per account and returns `ThrottlingException` beyond it. Bound the concurrency, back off on that error, and resume where it left off after an app restart (see §12.6).
  3. Poll a sample of objects with `HeadObject` and wait for `ongoing-request="false"`. Show "Restore requested — ready by about <time>", and send a notification when ready.
  4. Run a plain `restic restore`.

  The thaw has to cover the whole bucket because packs aren't mapped to folders. You still pay download charges only on what restic actually reads.
- **Keep the thaw code isolated.** It is the one piece of non-restic storage logic. Put it in its own module behind a small interface, so it can be deleted if restic's native support matures (my call).
- **Disabled on cold plans** (decided, per the runbook "Don't" list): `prune`, `repair index`, `check --read-data`/`--read-data-subset`, test restores.
  - Cold plans keep all snapshots by default. `forget` without `prune` frees nothing, and Deep Archive charges early deletion within 180 days (my call).
- **Pricing honesty (decided).** At plan creation, state the 180-day minimum and that restores are slow and charged. At restore time, show the counts and sizes above with a link to the provider's pricing page.

### 5.4 Adding an existing repository (decided)

- The user enters a repository address, password and backend credentials. The app runs `restic snapshots --json`, and the history appears in the timeline.
- **Pre-fill:** source folders are filled in from the latest snapshot's `paths` for this hostname. Exclusions are not stored in snapshots, so the user re-enters them.
- **Show the matching keys:** display the hostname and paths the app will use. If they differ from existing snapshots, restic picks no parent snapshot and re-reads (but does not re-upload) everything on the first run. Warn when that will happen.
- **Always pass `--host` explicitly (review 3).** restic defaults the snapshot host to the live hostname, and people rename their Macs. A rename would silently start a new `host,paths` group: no parent snapshot, a full re-read, and retention that no longer covers the old group (§5.6). Each plan therefore stores a host label, set once at plan creation (default: the current hostname; at adoption, default to the host found in the snapshots whose paths matched) and passed as `--host` on every `backup`, `forget` and `snapshots` call. Renaming the Mac changes nothing. The label is editable in plan settings with the same "this starts a new group" warning as changing source folders.
- **New repositories:** `restic init` for new ones, behind an explicit "Create new repository" action. The app must never auto-initialise a repository because an address was mistyped. The owner's photos-offsite uses `SKIP_INIT=true` for exactly this reason.

### 5.5 Scheduling and conditions (decided defaults, all per-plan toggles)

- **Hot plans:** hourly, plus a catch-up run after waking from sleep or after a missed run, anacron-style.
- **Skip conditions:**
  - on battery below 20% (review 3: the threshold is a per-plan setting, and "never on battery" is one of its values, since that is what Arq and Time Machine's "back up on battery power" toggle offer)
  - on a constrained or expensive network (phone hotspot, Low Data Mode)
  - **a source folder's volume is not mounted (review 3).** Plans that back up an external drive must not run while it is unplugged. restic warns `does not exist, skipping` for a missing path and exits 3 with an incomplete snapshot, which would create a snapshot missing that whole tree and, with `--group-by paths`, fork the snapshot group. Before each run the agent checks that every source path exists; if any is on an unmounted volume the run is a tracked skip with the reason shown in the menu, and the next run is attempted when the volume mounts (`NSWorkspace.didMountNotification`). A path missing for any other reason is a failure, not a skip.
- **Skips are not failures, but they are tracked.** A plan that has been skipped for N days in a row still triggers the "no successful backup in N days" alert (§6.2), because a laptop that never charges is anti-goal 1.
- **No snapshot when nothing changed (review 3).** Hourly runs pass `--skip-if-unchanged`, so an unchanged home folder does not add 24 identical snapshots a day. This keeps the snapshot list and the restore index (§5.2) small. Consequences the UI must handle: the run exits 0 with no `snapshot_id`, so "last backup" means "last successful run" and is shown as "Up to date — no changes since <time of last snapshot>". A skipped-if-unchanged run still pings the check-in URL as a success, because the data is verifiably protected.
- **Cold plans:** default to daily or weekly (my call), with the user choosing.
- **Runs without the UI.** Backups run with the app closed, via a background agent registered with `SMAppService` (§8).

### 5.6 Retention (decided default for hot plans)

- **Default policy:** `--keep-hourly 24 --keep-daily 30 --keep-weekly 52 --keep-monthly 120`, editable per plan.
- **Forget and prune timing (my call):**
  - Repositories Restorey created: `forget` after each successful backup, and `prune` about weekly, so hourly runs aren't blocked by a long repack.
  - **`forget` takes an exclusive lock, just like `prune`** (verified in `cmd/restic/cmd_forget.go` via `openWithExclusiveLock`, 9 Nov 2026). On an adopted repository that other clients write to, running it every hour would collide with them often. For adopted repositories, `forget` therefore defaults to daily rather than after every backup. It follows the same rule as `prune`: if another client holds the lock, retry later and never break the lock.
  - Since `forget` frees no space without `prune`, running it less often costs nothing except a slightly longer snapshot list.
- **Never delete what Restorey didn't make (my call; anti-goal-level rule).**
  - Every Restorey backup is tagged `restorey:<plan id>`.
  - `forget` always runs with `--host <this Mac> --tag restorey:<plan id>` and `--group-by host,paths,tags`, so it can never thin out snapshots from other machines, other tools, or the period before adoption.
  - **Side effect of grouping by `paths` (my call: accepted, but must be visible).** Changing a plan's source folders starts a new group. Snapshots under the old folder list are no longer thinned by the new group's policy: the old group keeps up to its full retention allowance (e.g. 24 hourly, 30 daily, …) indefinitely. This is the safe default, because it never deletes history the user may still want. The plan settings should say so when sources change, and offer an explicit "apply retention to snapshots from the previous folder list" action with the same `--dry-run` confirmation used at adoption.
  - Snapshots that existed before adoption are left alone unless the user explicitly opts in on the adoption screen ("apply this plan's retention to existing snapshots from this Mac"). That choice gets its own confirmation, which shows how many snapshots it would remove (from a `forget --dry-run`).
  - `prune` is a per-plan toggle: on by default for repositories Restorey created, off by default for adopted ones. The adoption screen explains that `prune` takes an exclusive lock and can collide with other clients that write to the same repository. If `prune` hits a lock held by someone else, the app retries later instead of breaking the lock.
- **Cold plans:** keep everything (see §5.3).

### 5.7 What gets backed up

- **iCloud files that exist only in iCloud** (Optimise Mac Storage): skipped by default via `--exclude-cloud-files`. That flag is supported on macOS since restic 0.19.0 (Enh #5352).
  - The status says how many files were skipped, e.g. "1,204 iCloud files not on this Mac were skipped."
  - A per-plan option downloads them instead. That option must check free disk space first. **(decided)**
- **Default exclusions (my guess, accepted on playback):** caches (`~/Library/Caches`, `--exclude-caches` for CACHEDIR.TAG), Trash, `node_modules`, Docker/OrbStack disk images, and items macOS already marks as excluded from backup.
  - restic does not read Time Machine's exclusion attribute. The builder decides whether to translate it into restic excludes, and how (builder).
- **Full Disk Access:** onboarding must detect missing FDA and walk the user through granting it. It must check from the context backups actually run in, i.e. the background agent, not just the UI process. Restic Station's two-context probe is the reference (§11).
  - **(spike)** Confirmed: **one grant to Restorey.app covers the agent and the restic it launches.** TCC names the app's bundle ID as the subject and the agent as the responsible process. The grant reaches a running agent without a restart, and it survives Developer ID N→N+1 updates. The probe lists a protected directory such as `~/Library/Safari`; it never backs up the user's data.
  - **(spike)** Without FDA, restic exits **3** and still writes a snapshot of empty directories. So **the agent's own probe of a known protected directory decides whether Full Disk Access is missing**, before each run. That is an error with a fix action, never the ordinary "some files skipped" warning (anti-goal 3). Other "operation not permitted" errors count as skipped files, because SIP-protected and datavault paths return EPERM even with FDA. Before choosing the default exclusions, v0.1 runs once with FDA over a whole home folder and records which paths still return EPERM.

## 6. Safety: catching corruption and silent stops

### 6.1 Verification (hot plans)

| Check | Default cadence | What it proves |
|---|---|---|
| `restic check` | weekly | Index and structure are consistent |
| `restic check --read-data-subset=n/12`, rotating n | monthly | Every data pack is downloaded and verified about once a year. B2 egress is free up to 3× stored, so this is close to free there |
| Test restore | weekly (my call) | Restores a few random files from the latest snapshot to a temp directory and compares them byte-for-byte with the live files where those are unchanged since the snapshot (by mtime and size) |

A failure of any check is an alert-worthy event, with the same severity as a failed backup.

**Cold plans** run only `restic check`. Their status explicitly says "data can't be verified on cold storage." This is anti-goal 3.

### 6.2 Alerts (decided channels)

- **macOS notifications:** always on.
- **Check-in URL (Healthchecks.io-style dead-man's switch):**
  - ping `/start` at run start
  - ping success or `/fail` at the end
  - the service alerts the user when pings stop
  - This is the only defence against "the Mac is off, broken or stolen" and against Restorey itself being dead. It is therefore the most important integration for anti-goal 1.
  - **One URL per plan (my call).** Ping only on real outcomes: `/start`, then success or `/fail`. Skipped and paused runs send nothing.
  - **The `/fail` ping carries the reason (review 3).** Healthchecks-style services accept a request body and show it with the alert. Send the restic exit code and the last ~20 lines of the run log, with secrets stripped, so the email the user gets at work says *why*, not just that it failed.
  - **The user sets tolerance on the service side.** The period and grace set on the check service define how long "no successful backup" can last. The settings screen recommends setting them to the plan's N-day threshold (e.g. 3 days) rather than the hourly schedule. That way battery skips don't cause noise, and a laptop that never charges still triggers an alert. A success ping on a skipped run would hide exactly that case, so it is never sent.
- **Agent liveness without a check-in URL (review 4).** The check-in URL is optional, so it cannot be the only thing that notices a dead agent.
  - **(spike)** `SMAppService.status` reported `enabled` while launchd had removed the job after a launch-constraint failure (§8). Only the heartbeat shows the agent is alive. When the heartbeat fails and the app is running from /Applications, the app tries to repair it with `unregister()` then `register()`, **but only for a fault**. If the user switched the agent off in Login Items, the app shows "Background agent is switched off" with an "Open Login Items" action and never re-enables it silently. Telling the two cases apart (`SMAppService.status`, `launchctl print` state and last exit reason) is still unverified and is v0.1's job. `unregister()` stops a running agent and kills restic mid-run, so drain first (`prepareForRestart`) whenever the agent is reachable.
  - **(spike)** The heartbeat reply includes the agent's executable path. If it isn't inside the bundle of the app that's asking, the registration has been re-pointed (§8). That's treated as a fault even while the old agent process is still answering.
  - **The menu bar app watches the agent.** The agent sends a heartbeat over XPC (builder picks the interval). If the menu bar app can't reach the agent, or the heartbeat or the last scheduled run is overdue, the icon goes to the error state with "Background agent isn't running" and a one-click "Restart agent" action. The app also checks this on launch, so a Mac that was restarted with a broken agent shows the problem as soon as the user logs in.
  - **This covers a dead agent, not a dead Mac.** A Mac that is off, broken or stolen can only be caught by an outside service. Onboarding therefore asks for a check-in URL as a normal step with a clear "why", not as an advanced setting. Skipping it is allowed, but the plan's status then shows "No off-Mac monitoring" as a standing warning-level note (anti-goal 3), and the user can dismiss that note.
- **ntfy:** server URL and topic, optional token.
- **Pushover:** user key and app token, for people who already have it.
- **Generic webhook:** a URL plus a JSON body template. Covers Discord, Slack, Gotify and others.
- **Not included:** Apprise and Shoutrrr. Both would need a bundled Python or Go runtime (my call).

**Events that trigger alerts:**

- backup failed
- any verification check failed
- test restore failed
- no successful backup in N days (default 3, per plan), even if every individual run "succeeded" or was skipped
- thaw ready (cold plans)

**No success spam.** Successful runs don't notify by default. An optional daily or weekly digest is fine (my call).

**Edge-triggered latching is a known trap.** Do not send one alert and then go quiet while a fault persists. Re-notify on a back-off schedule while the condition holds. This is the failure mode documented in the owner's notes on edge-triggered alerting, where one alert was sent for a days-long outage.

## 7. Configuration and secrets

- **Format (builder).** Config is owned by the app (Codable files in Application Support, SwiftData, or similar). Plain text would be nice but isn't required.
  - **Versioned from the first release (review 3).** Whatever the store, it carries a schema version from v0.1 and changes go through explicit migrations, never ad-hoc edits. That is the owner's standing rule for schema changes, and the alpha's config must survive every later upgrade without the owner re-entering plans.
- **Recovery kit (review 3; anti-goal-level).** A repository password that exists only in the Keychain of a stolen Mac is a backup nobody can open. iCloud Keychain may or may not have synced it, and the user may not have another Apple device. So:
  - Plan creation and adoption end with a required "Save your recovery kit" step: a printable/saveable document with the repository address, the repository password, the backend credential names and values, the host label and the plain restic commands from the README's "how to restore without Restorey" section.
  - The user must confirm they have saved or printed it before the first backup runs. The app says where to keep it: a password manager, or paper somewhere that isn't the Mac.
  - "Show recovery kit" stays available in plan settings behind Touch ID / password.
  - **Don't leave the kit on the Mac it protects (review 4).** The kit holds every secret needed to open the repository, so a copy sitting in `~/Downloads` is both useless in the disaster it exists for and a risk if the Mac is lost. The flow offers, in order: copy each field for pasting into a password manager, print, or save to a location the user picks. Saving defaults to no location rather than Downloads, and if the chosen location is on the Mac's internal disk the app says so and recommends deleting the file once it is stored elsewhere. The kit is never written anywhere automatically.
  - This is what Arq's "export plan" and Backblaze's key-save prompts exist for, and it is the single most common way people lose access to encrypted backups.
- **Passwords:**
  - **Repository passwords and backend secrets live in the Keychain**, never in config files. (review 3) So do alert credentials: ntfy tokens, Pushover keys, webhook URLs that embed a secret, and the check-in URL itself, since knowing it lets anyone silence the dead-man's switch.
  - **restic receives the repository password via `RESTIC_PASSWORD_COMMAND`.** It calls a small helper that reads from the Keychain, so the repository password never goes into an environment variable or a file on disk.
  - **Backend credentials are different (review 4).** `RESTIC_PASSWORD_COMMAND` covers only the repository password. restic reads B2 keys (`B2_ACCOUNT_ID`, `B2_ACCOUNT_KEY`) and S3 keys (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) from environment variables, and on macOS another process running as the same user can read a child process's environment. The design must not claim otherwise. Baseline: the agent reads backend secrets from the Keychain at spawn time and sets them only in the restic child's environment, never in its own environment, a file or a log. The spike (§12.1) checks whether a better route exists for each backend, e.g. an S3 shared-credentials or `credential_process` file pointing at the Keychain helper, and records what it found. Whatever is chosen, the README states plainly how backend secrets are passed.
    - **(spike)** Confirmed: a same-user process can read a running restic's environment (`ps -E`, `sysctl KERN_PROCARGS2`).
    - **(spike, decided) S3 and B2 (through the S3 API):** no `AWS_*` variables. A per-plan shared-credentials file (mode 0600, in Application Support) holds only `[restorey-<plan id>] credential_process = <agent executable> s3-credentials --plan <id>`, and restic gets `AWS_SHARED_CREDENTIALS_FILE` and `AWS_PROFILE`. restic 0.19.1's S3 chain reads this file through minio-go v7.1.0. The line is split on whitespace with no quoting, so **the helper's path must contain no spaces**, and the helper checks that at startup. The launch-chain check above applies here too. **The helper must print `"Version": 1` and an `"Expiration"`** (e.g. now + 12 h). Without one, minio-go treats the credentials as always expired (`SetExpiration` with a zero time) and runs the helper again for nearly every S3 request. Helper errors go to os_log, not stderr, because minio-go's `cmd.Output()` discards stderr and restic reports only "no credentials found".
    - **(spike)** Not yet run end to end. The first v0.1 task verifies it against a real B2 bucket's S3 endpoint, with three checks:
      - a **positive control**: the helper logs every call, and the number of calls per backup is recorded (expected: about one per run)
      - a **negative control**: a profile pointing at a helper that deliberately fails must make restic fail. minio-go's chain otherwise falls through to `~/.mc/config.json` and IAM, so a passing run alone proves nothing
      - an empty `AWS_*` environment
    - **Other backends, including adopted native `b2:` repositories** (whose keys restic reads only from the environment): child environment only, and the README states that exposure. It never claims that "B2 keys" are kept out of the environment in general.
  - **Which keychain, and which helper (my call; to be confirmed in the spike, §12.1).** Restic Station calls `/usr/bin/security` as the password command. That conflicts with sharing items through a Keychain access group:
    - As far as is known, `security` works with the older file-based keychain, which controls access per application. Access groups belong to the newer data protection keychain, which `security` is not believed to read.
    - With file-based items, reading through `security` from the background agent can show an access prompt, and the agent has no window to show it in. A missed prompt means a failed backup: anti-goal 1.
  - **Proposed instead (superseded by the "(spike)" notes below: the helper is the agent app's executable, not a separate binary):** a small password helper, embedded in the bundle and signed with the same Developer ID and Keychain access group as the app and the agent, which reads from the data protection keychain. The app, the agent and the helper then share items without prompts, and an update keeps the same identity.
  - The spike must confirm this works from launchd context without prompting, both before and after an N→N+1 update. Which keychain is used is fixed when items are created, so it must be settled before v0.1.
  - **(spike) Confirmed, with a change of shape.** The helper is **the agent app's own executable**, run as `RestoreyAgent print-password --plan <id>`. Every executable that claims the access group must embed its own provisioning profile, so a bare tool is killed at launch by AMFI. Items are read from launchd context with no prompt, with the screen locked, after N→N+1 updates, and after the switch from development to Developer ID signing (access is by access group, not signature). Items are created with `kSecAttrAccessibleAfterFirstUnlock`.
  - **(spike, decided) Confused deputy.** Run by hand, the correctly signed helper prints the password to anyone running as the user. The owner chose a launch-chain check plus a README statement. **The agent does the checking, not the helper**, because a child process can't get its parent's audit token, and a pid-and-path check can be fooled by exec-in-place: a process forks, then execs the signed binary, keeping its pid. The mechanism:
    - `print-password` asks the running agent over XPC.
    - The agent checks the caller's **audit token** against the helper's own code requirement.
    - It then checks that the caller's parent pid is a restic **the agent itself spawned and is still supervising**, for the plan named in the request.
    - Only then does it return the secret, over XPC.

    An attacker can then only get secrets by hijacking an agent-supervised restic. The README states that residual risk, and the general one: any process running as you can do a great deal.
- **"Copy as restic command"** (my call). A per-plan menu item that prints the exact `restic` invocation with secrets replaced by placeholders. It serves CLI-minded users without committing the app to a file format.
- **Timestamps are stored in UTC** and converted to local time only for display. That's the owner's standing rule.

## 8. Architecture (my call; the builder may refine)

- **Platform:** Swift 6.4 language mode with strict concurrency, macOS 27 deployment target, Xcode 27.0. SwiftUI for windows, with AppKit `NSStatusItem` for the menu bar.
- **Two processes:**
  1. **Restorey.app:** UI only (menu bar, settings, restore window).
  2. **Background agent:** a LaunchAgent registered via `SMAppService.agent(plistName:)` with `BundleProgram`, embedded in the app bundle. It owns:
     - the scheduler
     - restic process supervision
     - the run-state store
     - alerts

     Backups therefore run with the UI closed. Restic Station uses this pattern.

     **(spike) Confirmed as a helper app** (`Contents/Helpers/RestoreyAgent.app`, `LSUIElement`, a real `NSApplication` run loop), registered with `SMAppService.agent(plistName:)` and a plist in `Contents/Library/LaunchAgents/` with `BundleProgram`, `MachServices`, `KeepAlive` and `RunAtLoad`. Login Items lists it under the app, using the agent's *executable name*, so name the product "RestoreyAgent" or similar. Registration needed no approval. The **app's** notification permission doesn't cover the agent. Without its own, `UNUserNotificationCenter.add` reports success and delivers **nothing**. So onboarding requests permission **from the agent only**, which leaves one entry in Notifications. The agent checks `authorizationStatus`, and the menu bar shows a standing warning when it isn't `authorized` (anti-goal 1).

     **The agent probably has to be a helper app, not a bare executable (review 4).** The agent owns alerts, and macOS notifications are always on (§6.2). `UNUserNotificationCenter` needs a process with a bundle identity, so a bare executable inside the app bundle can't post notifications reliably, and the main app may not be running to post them for it. The likely shape is a background-only helper app (`LSUIElement`) embedded in `Restorey.app`, with its own bundle identifier, registered through `SMAppService`. Consequences the spike (§12.1) must settle:
     - how the helper appears in System Settings for notifications, Login Items and Full Disk Access, and whether the user has to grant anything to it separately
     - that onboarding asks for notification permission from the helper, since a grant to the main app doesn't cover it
     - that the helper's notifications show the Restorey name and icon
- **Communication:** the app and agent talk over XPC (builder's choice of `NSXPCConnection` or another mechanism). Live progress streams from the agent to the UI.
- **Bundled restic:**
  - **Pinned version:** a tested upstream restic release (currently 0.19.1, released 5 Jul 2026 and still the latest as of 9 Nov 2026), embedded in the bundle and re-signed with the app's Developer ID.
  - **Who launches it:** always the agent, so TCC/FDA attribution is stable.
  - **Override:** an advanced setting points at a user-supplied binary, with a version check.
- **Process supervision:**
  - spawn restic with `posix_spawn` or `Process`
  - parse `--json` NDJSON progress
  - `RESTIC_PROGRESS_FPS` around 2
  - SIGINT, then SIGKILL after 10 s for cancel or pause
  - interpret restic's exit codes. (review 3) The documented set for 0.19.1 is: 0 success · 1 generic failure · 2 Go runtime error · 3 `backup` could not read some source data (incomplete snapshot) or `forget` could not remove a snapshot · 10 repository does not exist · 11 failed to lock the repository · 12 wrong password · 130 cancelled by SIGINT/SIGTERM. restic's docs say new codes may be added and any unknown code must be treated as failure. Mapping to UI: 3 is a warning with the skipped-file count, not a green tick (anti-goal 3); 11 reschedules; 10 and 12 are configuration errors that stop the plan and alert immediately rather than retrying hourly; 130 after our own SIGINT is a pause or cancel, never a failure.
  - **restic's own cache (review 3).** restic keeps an unencrypted-metadata cache (index, snapshots, tree packs) that defaults to `~/Library/Caches/restic` and grows without bound. Pass `--cache-dir` so it lives under Restorey's own cache directory alongside the restore index, pass `--cleanup-cache` on maintenance runs, and show its size in Settings with a "Clear" button. Running `check` with `--with-cache` so it does not download a fresh copy of the metadata each week is the builder's call once egress has been measured.
- **Agent lifecycle, power and priority (my call; the builder confirms the details):**
  - **Staying alive.** The agent is a long-running process (`KeepAlive`) that owns the schedule itself. launchd only keeps it running. A crash or kill is restarted by launchd, and the check-in URL (§6.2) covers the case where the agent stays dead.
  - **Sleep during a run.** While restic is running, the agent holds an `IOPMAssertion` that prevents idle sleep (not display sleep), and releases it when the run ends. Without this, a laptop left idle sleeps mid-backup and the run fails or stalls. Lid-closed sleep can't be prevented and isn't attempted: the run is resumed by the catch-up run after waking (§5.5).
  - **Waking from sleep.** After waking, wait until the network path is satisfied (`NWPathMonitor`) before starting a catch-up run, with a timeout. A run that starts before the network is up fails, and that failure is noise, not a real problem.
  - **Priority.** Don't set launchd's `ProcessType=Background` on the agent: it throttles disk I/O heavily and would make backups very slow. **(spike, decided) Use `ProcessType=Standard`, not `Adaptive`.** Under Adaptive, launchd keeps the agent at background priority (4) unless it is serving an XPC request, so every self-scheduled backup ran throttled: 954 s and unfinished, against 69 s under Standard. Run restic with `Process.qualityOfService = .utility`, so backups are noticeable but not disruptive. (The spike set this but didn't show it took effect, since restic read priority 46. Verify with `taskinfo` or by measuring.) Measure on a real 0.5 TB home folder and record the choice in `docs/`. The spike saw restic at about 3 cores on a dry run.
  - **Must live in /Applications (review 3).** An app launched from a DMG or `~/Downloads` with the quarantine flag is run by Gatekeeper from a randomised, read-only translocated path. From there `SMAppService` registers an agent whose `BundleProgram` path dies with the translocation, and any FDA grant attaches to a path that never exists again. First launch must detect translocation (the bundle path is not where the user put it) or a non-`/Applications` location, and offer to move itself before registering anything.
    - **(spike) A stray copy is dangerous even if it never registers.** Opening a second copy straight from the DMG made Background Task Management re-point the existing registration at that copy. The copy's version handshake then restarted the agent from the DMG, AMFI killed it with a launch-constraint violation, and launchd **removed the job**, so backups stopped silently. So a translocated or non-/Applications copy must do **nothing** that touches the agent: no handshake, no register or unregister, no XPC commands. It only offers "Move to Applications". The real copy self-repairs through the heartbeat (§6.2).
    - **(spike)** A quarantined copy made by script (`xattr`, or Finder `duplicate`) was still translocated from /Applications. A user's Finder drag wasn't. Test installs must use a real drag. The Homebrew cask path is untested.
    - **The app's own "Move to Applications" will hit the same problem.** After copying itself, it must remove `com.apple.quarantine` from the copy (as LetsMove does) before relaunching, and v0.1 tests that the moved copy isn't translocated. Both ported references (Resticker, Restic Station) are run from source and never hit this; it is unique to shipping a DMG.
  - **Agent restart after an update (review 3).** Sparkle replaces the bundle in place, which includes the agent binary, but launchd keeps running the old agent process. After an update the app must ask the old agent to finish any in-flight run and exit, so launchd relaunches the new one, and must verify over XPC that both report the same version before showing a healthy status. Doing this between runs, not during one, is the agent's job. This case is part of the N→N+1 spike (§12.1).
    - **(spike) Confirmed** under both signing identities. The old agent keeps running the deleted binary, `prepareForRestart` waits for the in-flight run, `exit(0)`, and `KeepAlive` starts the new agent within about 2 s, with no grants lost. The drain timeout must allow for a long first backup, and the UI says "Finishing the current backup before updating the agent".
    - **(spike) A changed plist isn't picked up by an update.** launchd keeps the job definition from `register()`. When the embedded plist's hash differs from the one recorded at the last registration, the app drains the agent first (`prepareForRestart`), then does `unregister()` then `register()` instead of a plain restart.
    - **This is needed from v0.1, not from Sparkle (review 4).** Before v1.0, updates are a new DMG dragged over the old app, which replaces the bundle in exactly the same way and leaves the old agent running. So the version handshake and the "finish the run, then exit" restart ship in v0.1. On launch the app compares its own version with the agent's over XPC and restarts the agent if they differ. The spike tests this with a manual replacement, so it doesn't depend on Sparkle.
- **External-service layer.** Everything that isn't restic sits behind service types with retry and back-off: S3 thaw, check-in pings, ntfy, Pushover, webhooks. This follows the owner's "wrap external API calls in a service layer" rule.
- **Concurrency:** actors for the scheduler, the per-repository run queue and the state store. No GCD or locks with non-Sendable classes, which is the Resticker problem.
- **Logging:**
  - **Persistent logs** (owner rule: "persistent logging, not just stdout"): one structured log file per run plus a rolling app log in `~/Library/Logs/Restorey/`, also mirrored to `os_log`.
  - **Retention** long enough for a yearly restore drill, e.g. 400 days to match photos-offsite (my call).
  - **Easy to reach:** the log for any run is one click away from the plan's status.
- **Crash reporting** (owner rule: "from day one"):
  - MetricKit diagnostics are collected locally.
  - A "Send diagnostic report" action lets users attach crash and run logs to a GitHub issue with secrets stripped.
  - Any third-party crash service must be opt-in and disclosed, since this is a privacy-sensitive backup tool (my call; the builder picks the mechanism).
- **No `/health` endpoint.** That owner rule applies to network services, and Restorey exposes no network service. Its health signal is the check-in URL in §6.2.

## 9. Distribution and project (my call unless noted)

- **Name: Restorey (decided).** "Restore-y". `jaydenk/restorey` on GitHub and the Homebrew `restorey` cask and formula names were free on 9 Nov 2026. Optionally also create `jaydenk/restory` as a redirect for mistypes. The name "Restory" was dropped because of the Steam game *ReStory: Chill Electronics Repairs*.
- **Licence: MIT.** Compatible with the MIT code ported from Resticker and Restic Station, which keep their copyright notices in a `THIRD_PARTY_NOTICES` file, and with restic's BSD-2-Clause licence for the bundled binary.
- **Releases:**
  - Developer ID-signed, notarised DMG on GitHub Releases.
  - Homebrew cask `restorey`.
  - In-app updates via Sparkle with EdDSA-signed appcast.
  - Builds come from CI, not a laptop (owner rule).
- **CI:** macOS build and test. Unit tests run on every push; signing and notarisation run on tags. (Corrected 10 Nov 2026: not on birdseye, which the owner keeps for iOS work. The CI host is chosen in the v0.1 plan.)
- **(spike) Development builds use a separate identity throughout:** app and agent bundle IDs, launchd label, Mach service name and keychain access group (e.g. a `….restorey.dev` family, as scrap's Debug does). TCC stores the designated requirement, so moving one bundle ID between development and Developer ID signing switches its FDA grant off. Shared labels or services would also make development and release agents collide.
- **Localisation:** Australian English is the development language (owner rule). Other localisations are welcome later.
- **Docs:** a README with install, first-run, an FDA explanation, and a "how to restore without Restorey" section. That section is the plain restic commands, because a backup tool's users must be able to recover if the tool disappears.

## 10. Constraints

- **macOS 27 only.** No App Store.
- **No root or privileged helper.** User-level LaunchAgent only. System-wide or other-user backups are out of scope.
- **Testing:** unhappy paths are tested (owner rule):
  - network failures
  - B2/S3 errors
  - malformed or unknown NDJSON lines from a newer restic
  - an unreachable repository
  - a wrong password
  - a stale lock
  - a full disk
- **A real restore is part of the release checklist.** "The first restore attempt should never be during an emergency."
- **Tests run against a real restic binary** with local and `rest-server` repositories, not just mocks, for the process-supervision and parsing layers.
- **Keychain tests need an entitled host (review 3).** Data protection keychain calls return `errSecMissingEntitlement` (-34018) under a bare `swift test` runner because it has no application-identifier entitlement. Keychain-touching tests run in an Xcode test bundle hosted by the signed app, or the password helper is tested through its process boundary. The builder must not "fix" this by dropping `kSecUseDataProtectionKeychain` in test builds, because that changes which keychain the items land in (§7).

## 11. Prior art and reuse

Reviewed 9 Nov 2026 (read-only clones). Both are MIT-licensed. **Decision (decided): new app, not a fork. Port the specific pieces below, with attribution.**

- **Resticker** (`marcboeker/resticker`, v0.7.0, ~6.3k Swift lines). Take:
  - `--json` message models and parsing (`ResticMessage.swift`)
  - process launch and cancel (`ResticCommand.swift`)
  - restore command construction
  - its ~96 Core XCTests as a starting point

  Leave behind:
  - the in-app timer scheduler (backups stop when the app quits)
  - GCD/NSLock concurrency
  - the 555-line AppDelegate
  - memory-only logs
  - per-folder `ls` restore browsing
  - swallowed errors in `Snapshot.swift`
- **Restic Station** (`bherila/restic-station`, v0.1.4, ~56k source + 43k test lines). Take:
  - the SMAppService LaunchAgent with `BundleProgram`
  - `posix_spawn` process ownership
  - NDJSON parsers (`Restic/Parsers/BackupMessages.swift`)
  - anacron-style `ScheduleMath`
  - the `RESTIC_PASSWORD_COMMAND` approach, but not its use of `/usr/bin/security` as the command (see §7)
  - the two-context FDA probe (`docs/keychain-and-fda.md`)
  - the `SF_DATALESS` check (`Config/CacheDirTag.swift`)

  Leave behind: the Linux, mirror, multi-machine and purge machinery.
- **Backrest** (web UI, Go). Reference for which hooks and notification types restic users expect.
- **The owner's `photos-offsite`.** Reference implementation for cold plans, the thaw flow and the "Don't" list.

## 12. Risks and open technical questions (builder)

1. **(spike) Answered on 10 Nov 2026; see `docs/spike-findings.md` and the "(spike)" notes in §5.7, §6.2, §7 and §8. Still open: the reboot-at-login run, B2 `credential_process` end to end, the CPU measurement, the SIGINT lock removal, and the Sparkle (v1.0) update path, which the spike tested only as a manual drag.** **FDA attribution for the bundled restic launched by a LaunchAgent.** Verify early, with a spike, that one FDA grant to Restorey covers restic spawned by the agent. Also verify it survives Sparkle updates. This is the riskiest assumption in the design.
   - **Owner's rule:** make it "as robust and straightforward as possible, whatever that requires" (decided). The user-facing target is **one Full Disk Access grant, made once, that survives updates.**
   - **What that means for the build:**
     - Accept extra internal complexity (a different process structure, or a different way of launching restic) before accepting extra user steps.
     - Never require re-granting after an update. Keep a stable Developer ID and designated requirement across releases, and test an update from N to N+1 as part of the spike.
     - Only if a single grant proves impossible on macOS 27: fall back to a guided two-item grant, where the app detects exactly which item lacks access and deep-links to the right Settings pane.
     - Document the spike's findings in `docs/`.
   - **Keychain is part of the same spike.** Confirm the bundled password helper (§7) reads data protection keychain items from launchd context without a prompt, both before and after an N→N+1 update.
   - **Also in the spike (review 4):**
     - the agent's process shape (§8): whether it must be a helper app for notifications, and what that does to the FDA, notification and Login Items grants
     - how backend credentials reach restic for B2 and S3, and whether anything better than the child-only environment exists (§7)
     - the N→N+1 test done by manually replacing the app from a DMG, including the version handshake and agent restart (§8)
2. **Index cache size.** A 0.5 TB home folder can have millions of entries per snapshot, and hourly snapshots multiply that. The cache needs deduplication across snapshots: most of the tree is unchanged between snapshots. It also needs eviction for snapshots that `forget` removed.
   - **Correction (review 3): `restic ls --json` does not expose per-directory tree IDs.** Its `node` messages carry name, type, path, size, mode, times and inode only; the sole tree ID is the root `tree` on the leading `snapshot` message. So "use restic's tree IDs" is not free. The builder has two routes and should spike both on the owner's real repository:
     - **(a)** walk the tree with `restic cat tree <id>`, which returns the raw tree object including each directory's `subtree` ID. One process spawn per directory, but tree packs are in restic's local cache after the first fetch, so later snapshots cost only the directories that changed. Unchanged subtrees are skipped by ID.
     - **(b)** take the flat `ls --json` listing once per snapshot and content-hash each directory's child list locally to find unchanged subtrees. One spawn per snapshot, but the full listing (millions of lines) is parsed every time.
     - `--skip-if-unchanged` (§5.5) reduces the pressure either way, since identical snapshots no longer exist.
   - **Privacy (review 3).** The index is a plaintext list of every file name the user has ever backed up, stored in `~/Library/Caches`. restic's own cache has the same property. State it in the README, rely on FileVault, and give the user a "Clear index" button.
3. **NDJSON stability across restic versions.** Pin the bundled version and tolerate unknown message types and fields, especially when the user overrides the binary.
4. **Test-restore comparison.** Files changed since the snapshot can't be compared byte-for-byte. Pick files whose mtime and size are unchanged, and report "nothing comparable" honestly rather than passing vacuously.
5. **Lock handling.** Stale locks after a crash or sleep. Decide when the app may run `restic unlock` automatically: only for locks it owns, and older than a threshold.
   - **(spike)** Killing the agent mid-run kills restic too, with no orphan, but leaves its lock, and an exclusive `check` then fails with exit 11. A **plain `restic unlock`** (never `--remove-all`) removes only locks restic itself judges stale: more than 30 min old, or this host with a dead pid (`internal/restic/lock.go` `Stale()`). Run it before maintenance commands and after any agent restart. After SIGINT (pause) restic exits 130. Whether it removes its own lock is **unverified**: the run tested was a `--dry-run`, which takes no lock (`cmd/restic/lock.go`: `if !dryRun`). Re-test during a real backup. Caveat: restic matches `os.Hostname()`, which can change with the network.
6. **Thaw at scale.** ~23k objects for 1.6 TB took about 45 minutes of requests with the AWS CLI. The Swift implementation needs bounded concurrency, resumability across app restarts, and progress reporting. (review 3) S3's documented restore-request quota is ~1,000 requests/s per account; a larger pack size (§5.3) cuts the object count for new cold repositories.
7. **App translocation and Sparkle (review 3).** Covered in §8; listed here because both affect the FDA spike. The spike must launch from a quarantined DMG, not from Xcode, or it tests nothing.
8. **Restoring another host's snapshots (review 3).** §5.2 adds a host picker. The index cache must key by (repository, snapshot) and not assume this Mac's hostname anywhere; the merged timeline merges only snapshots for the host being browsed.

## 13. Releases and methodology

An early release before the full feature set is fine, as long as it follows "good development methodologies" (decided). The milestone split below is my call.

**Methodology (my call, in line with the owner's standing rules):**
- test-driven development
- CI from the first commit (host chosen in the v0.1 plan; not birdseye)
- signed and notarised builds from the first release, because Full Disk Access depends on a stable signature
- semantic versioning, with `0.x` pre-releases on GitHub Releases
- a changelog
- every release checklist includes a real restore

**Milestones:**

| Milestone | Scope | Audience |
|---|---|---|
| **Spike** | Full Disk Access attribution, Keychain helper access, agent process shape and notifications, backend credential passing, and the manual N→N+1 update test (§12.1). Throwaway code; findings written up | — |
| **v0.1** | Background agent and scheduler; hot plans (any backend, B2/S3 forms); add existing repository; menu bar with live progress and Pause; macOS notifications and the check-in URL; agent heartbeat watched by the menu bar app (review 4); app/agent version handshake and agent restart after an update (review 4); `restic check`; Keychain secrets and the recovery kit (§7, review 3: an alpha whose password can be lost with the Mac is not a usable alpha); versioned config; `/Applications` check; persistent logs; signed and notarised DMG. Restore uses the documented restic commands ("how to restore without Restorey") | Owner's own Mac (alpha) |
| **v0.1.x** | `--read-data-subset` checks and the weekly test restore; ntfy, Pushover and webhook alerts. Kept out of v0.1 so the owner starts using the app sooner. Notifications and the check-in URL already cover both anti-goals at a basic level (my call) | Owner's own Mac (alpha) |
| **v0.2** | Restore window: index cache, column browser, combined timeline, restore to Downloads | Early testers |
| **v0.3** | Cold plans and the thaw flow | Early testers |
| **v1.0** | Sparkle updates, Homebrew cask, onboarding polish, full README | Public |

## 14. Left to the builder

- Storage engine for config and the index cache.
- XPC design.
- Exact UI layout of Settings and onboarding. Follow Apple's HIG; the menu and restore window should stay close to the approved mockup.
- Translating Time Machine exclusions.
- Exact check cadences beyond the defaults above.
- Webhook template syntax.
- Order of work. Suggested: agent + backup + menu bar, then alerts and checks, then restore index and timeline, then cold plans.
