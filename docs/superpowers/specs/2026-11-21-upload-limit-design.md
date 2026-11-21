# Upload limit redesign

**Status:** draft for the owner's approval (21 Nov 2026). Decided by the owner on 20 Nov 2026 (all three parts) and
in conversation on 21 Nov 2026. Builds on the restorey design §5.3 (upload limit, Ruling P2-7) and the v0.1 UI
design §6.3 (Settings → Network).

## Intent

Backups to a networked repository shouldn't hog the owner's internet connection, and the owner shouldn't have to
guess a number to stop that. Today the only option is a fixed limit in MB/s (per plan, and Mac-wide), with no idea
of what the line can actually do. This redesign adds three things:

1. **A unit picker**: a limit can be typed in KB/s or MB/s.
2. **A daily speed test**: Restorey measures the upload speed of the network the Mac is on, so the Mac-wide limit
   can be a **percentage** of it ("50% of my upload").
3. **A time-of-day window**: the Mac-wide limit applies only during chosen days and hours, with full speed outside
   them.

## Goals

- A Mac-wide limit given as a fixed rate (KB/s or MB/s) or as a percentage of the measured upload speed.
- Measured speed remembered **per network**, because a laptop's "50%" means a different number at home, at the
  office and in a café.
- A window (days and hours) outside which there is no Mac-wide limit.
- The current speed and the limit that applies right now are visible in Settings → Network.

## Non-goals

- A percentage for a plan's own limit. A plan's limit stays a fixed rate (with the new unit picker). "This plan may
  use 20% while others share the rest" is more confusing than useful.
- More than one window, or a different limit inside and outside the window. Inside: the Mac-wide limit. Outside:
  no Mac-wide limit.
- Measuring the speed to the repository itself (for example B2). The test measures the line to Apple's servers,
  which stands in for "my upload".
- Download limits (restores). Unchanged.

## Anti-goals (a failure even if it works)

- **Stopping or restarting a running backup** to change its limit. Owner rule: Restorey never stops a running
  backup automatically. restic can't change `--limit-upload` mid-run, so a backup keeps the limit it started with,
  even when the window opens or closes while it runs.
- A **missed backup** because there is no measurement yet. With no measurement, a percentage limit falls back to
  no Mac-wide limit.
- Speed tests that use mobile data or skew the result: never on a constrained or expensive network (phone hotspot,
  Low Data Mode), never on a skipped Wi-Fi network, and never while a backup is uploading.
- Needing root or a privileged helper (spec §"No root or privileged helper"). This rules out traffic shaping from
  outside restic (`dnctl`/`pfctl`).

## Constraints

- restic's `--limit-upload` takes KiB/s and is fixed for the run. One MB/s here is 1024 KiB/s and one KB/s is 1 KiB/s,
  as today (`FormValidation.uploadLimit`). The unit labels stay "KB/s" and "MB/s".
- The Ruling P2-7 sharing rule stays: a networked backup gets the smaller of the plan's limit and the Mac-wide
  limit divided by the networked backups uploading when it starts, counting itself (`effectiveUploadLimitKiB`). The
  only change is the Mac-wide input: it is now **resolved** at the backup's start from the setting, the current
  network's measurement and the clock.
- macOS shows the Wi-Fi network's name only to a process with Location permission (README, "Location permission").
  The agent already has the usage text, entitlement and request path for the skipped-Wi-Fi list.
- `config.json` is versioned (schema 4 today). Changing its shape is a schema bump with a migration and the
  `<file>.v<schema>.bak` copy, as for every upgrade.
- No CPU-load or stress tests on the owner's Mac. Tests of the speed-test runner use a fake executable, never the
  real `networkQuality`.

## Approaches

1. **The agent runs macOS's `networkQuality` (chosen).** `/usr/bin/networkQuality -d -c -M <seconds>` runs an
   upload-only test against Apple's servers and prints JSON. `ul_throughput` is the uplink throughput in bits per
   second (man page). The agent runs it as a subprocess like restic, stores each result per network in its own
   state, and resolves the Mac-wide limit at each networked backup's start. Nothing is uploaded to the owner's
   bucket and there's nothing to host.
2. **Measure from restic's own uploads (rejected).** This needs no test traffic, but whatever limit is set caps
   the measurement: a 50% limit would measure half the line and then take half of that. It also counts restic's
   own pace (hashing, deduplication), not just the line.
3. **Run the test from the app (rejected).** The app isn't always running, and the agent is what knows when a backup
   is uploading and which network the Mac is on. A test from the app could collide with a backup.

## The design

### The Mac-wide limit setting

`NetworkSettings` replaces `uploadLimitKiB` with:

- **The limit:** none, a **rate** (KiB/s plus the unit the user picked, KB or MB, kept only so the field shows it
  back the same way), or a **percentage** (a whole number from 1 to 100).
- **The window:** optional; when absent, the limit applies all the time. Days are one of every day, weekdays
  (Monday to Friday) or weekends. A start and end are each a wall-clock time to the minute. A window may cross
  midnight (for example 10:00 pm to 6:00 am, where the end belongs to the next day). Start equal to end is
  refused with a reason.

The window is evaluated in the Mac's current time zone at the moment a backup starts. For a window that crosses
midnight, "weekdays" refers to the day the window **starts** on (Friday 10 pm to Saturday 6 am is in a weekday
window).

The agent validates these settings like the rest (`NetworkSettingsError`): a rate of 0 or less, a percentage
outside 1–100, and start equal to end are each refused with a sentence.

A plan's own limit stays a rate in KiB/s, gaining the same unit picker (unit stored beside it on the plan).

Schema 5: the migration turns `uploadLimitKiB: n` into a rate of n KiB/s shown in MB (today's field is MB/s), no
window. A plan's `uploadLimitKiB` keeps its value and gains the MB unit.

### Measurements

- **Network key.** Wi-Fi: the network's name when the agent can read it, otherwise one shared "Wi-Fi (name
  unknown)" entry. Wired: "Ethernet". Anything else (for example a USB modem): "Other". The interface type comes
  from the agent's `NWPathMonitor` path (`NetworkState` gains the interface type, which it doesn't carry today);
  the name comes from CoreWLAN, as for the skip list.
- **Per network, the agent keeps** the last successful result: speed (bits per second, from `ul_throughput`), the
  bytes the test sent, and when it was measured (UTC). It also keeps the last failure (when, and the reason in a
  sentence) so Settings can say "the last test failed". This lives in the agent's state directory as a versioned
  file of its own. It is a measurement, not a setting, so it never goes in `config.json`.
- **When it runs (my calls):**
  - At most **once per network per calendar day**, and only while the Mac-wide limit is a percentage. With a fixed
    rate or no limit, nothing runs on its own; **Test now** in Settings always works.
  - Never while restic runs any command against a networked repository (a backup, or prune, forget or check,
    which also send traffic), my call. A networked command that wants to start during a test waits for the test
    to end, which is bounded by the test's maximum run time.
  - Never on a constrained or expensive network, on a skipped Wi-Fi network, or with no network. Test now in those
    cases refuses with the reason instead of running.
  - **Before the first networked backup on a network that has no measurement yet** (percentage set), the agent
    runs the test first and then starts the backup. If the test fails or times out, that backup runs with no
    Mac-wide limit, and the failure is kept for Settings. When the backup starts outside the window, no limit
    applies anyway, so this test is skipped and left to the daily one (my call).
  - Otherwise the daily test runs on the scheduler's tick, when the day's test for the current network hasn't run
    yet.
- **The run.** `networkQuality -d -c -M <max>` with a bounded run time (the builder picks the value, about 20
  seconds, and a hard kill a little after). JSON on stdout. An exit other than 0, unreadable JSON, or a missing or
  zero `ul_throughput` is a failure with a sentence. The agent logs each test's result, network key, bytes sent and
  duration.

### Resolving the limit at a backup's start

1. Not inside the window (when a window is set): no Mac-wide limit.
2. A rate: that rate.
3. A percentage: the percentage of the current network's latest measured speed, converted to KiB/s and rounded
   down, never below 1. With no measurement (or the "before the first backup" test failed): no Mac-wide limit.
4. The result feeds `effectiveUploadLimitKiB` as the Mac-wide input, unchanged otherwise.

The backup's log line already shows the `--limit-upload` it got. It also logs how the limit was resolved, for
example "Mac-wide limit 19 MB/s: 50% of 38 MB/s measured on “Kerr Home” today, inside 8:00 am–6:00 pm weekdays".

### Location permission

A percentage needs the Wi-Fi name to tell networks apart. When the user first chooses "% of upload speed" and
the agent isn't authorised, the app asks the agent to request Location permission, through the same path the
skipped-Wi-Fi list uses (`requestLocationPermission`). The prompt text is broadened to cover both uses (wording
in Australian English, the builder's draft, for the owner to see in review). If permission is refused, every Wi-Fi
network shares the "Wi-Fi (name unknown)" measurement, and Settings says so in one line.

### Settings → Network

```
Upload limit for this Mac   [ 50 ] [ % of upload speed ▾ ]      (None · KB/s · MB/s · % of upload speed)
Upload speed on “Kerr Home”: 38 MB/s, measured today            [Test now]
[x] Only limit during  [Weekdays ▾]  [ 8:00 am ] to [ 6:00 pm ]
Now: 19 MB/s, until 6:00 pm
[x] Skip backups on a phone hotspot or Low Data Mode
Skip these Wi-Fi networks: …
```

- The speed line shows the current network's measurement and its age ("today", "yesterday", or a date), or "Not
  measured on this network yet", or the last failure's sentence. While a test runs it reads "Testing upload
  speed…" and Test now is disabled.
- **"Now:"** shows what a backup starting this moment would get as the Mac-wide limit, before sharing, and when
  that next changes ("until 6:00 pm", "from 8:00 am Monday"), or "No limit right now".
- The window row is shown whenever a limit other than None is chosen.
- The Schedule tab's plan limit gets the KB/s / MB/s picker only.

The exact layout, wording and control types follow the app's existing controls (`NumberField`, `UploadLimitField`,
the pickers in `ScheduleControls.swift`). They are the builder's, and the visual polish pass may revisit them.

### Agent and app interface

- `hello` or the status the app already polls carries the current network's measurement (or failure), whether a
  test is running, and the resolved "Now" line's inputs. The builder picks which, following how the Network pane
  gets its data today.
- A new XPC call starts a test now (refused with a sentence when it can't run). It returns once the test has
  ended, with its result.

## Left to the builder

- The test's maximum run time and kill grace, and the measurement file's format and name.
- How the "Now" line is computed and refreshed. A shared pure function used by the agent's resolution and the app's
  display is the obvious shape, so the two can't disagree.
- Whether a daily test that is due waits for a quiet moment (no plan due within a minute or two) or simply runs on
  the next eligible tick.
- Field-level validation messages, kept in the style of `NetworkSettingsError`.
- Test names, file splits, and README and spec updates (§5.3 and the UI design §6.3 gain a pointer here).

## Review focus

The inputs most likely to bite:

1. A window that crosses midnight, a daylight-saving change, and a time-zone change while travelling, evaluated
   at a backup's start.
2. A backup starting while a test runs, two backups starting together on an unmeasured network (one test, not
   two), and a test while a local (folder or drive) backup runs (allowed; it doesn't upload).
3. `networkQuality` hanging, exiting 0 with no or partial JSON, or reporting `ul_throughput` 0.
4. A percentage on a network whose Wi-Fi name can't be read (no permission, or not on Wi-Fi), and moving between
   networks between the test and the backup.
5. Upgrading a schema 4 `config.json` with and without an existing Mac-wide and plan limit.
