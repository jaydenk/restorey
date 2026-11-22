# Upload Limit Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Mac-wide upload limit can be a rate in KB/s or MB/s, or a percentage of a per-network measured upload speed. It can apply only inside a days-and-hours window, and is resolved when each networked backup starts.

**Architecture:**
- **Pure values and functions in RestoreyCore:** the setting types, the window, `resolveMacWideLimit` and the `networkQuality` JSON parser. The agent and the app both use them, so the Settings "Now" line and the agent's choice can't disagree.
- **AgentCore:** a `SpeedTester` actor runs `/usr/bin/networkQuality` through an injected runner. It stores results per network in `upload-speeds.json` (a `VersionedStore`) and coordinates with `PlanRunner` so a test never overlaps a networked restic command.
- **The app:** the Network pane edits the new settings, shows the speed and the "Now" line, and calls a new XPC `runUploadSpeedTest`.

**Tech Stack:** Swift 6.4, Swift Testing, SPM targets RestoreyCore/AgentCore, NSXPC, SwiftUI, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-21-upload-limit-design.md` (approved 21 Nov 2026). Background: `docs/superpowers/specs/2026-11-09-restorey-design.md` §5.3 (Ruling P2-7) and `2026-11-12-restorey-v0.1-ui-design.md` §6.3.

## Global Constraints

- Restorey never stops or restarts a running backup to change its limit. A backup keeps the `--limit-upload` it started with.
- 1 MB/s = 1024 KiB/s and 1 KB/s = 1 KiB/s (restic's unit). The labels stay "KB/s" and "MB/s".
- A percentage is a whole number from 1 to 100. A resolved percentage limit is rounded down to KiB/s and is never below 1.
- With no measurement for the current network, or a failed pre-backup test, a percentage resolves to **no** Mac-wide limit. A backup is never skipped or delayed beyond the test for this reason.
- `effectiveUploadLimitKiB(plan:macWide:networkedBackupsRunning:)` is unchanged. Only its `macWide` input becomes the resolved value.
- A speed test never runs on a constrained or expensive network, on a skipped Wi-Fi network, with no network, or while restic runs any command against a networked repository.
- A networked restic command that wants to start during a test waits for the test to end.
- No root, no `dnctl`/`pfctl`.
- Tests never run the real `networkQuality` or restic against B2, and nothing does CPU-load or stress testing on the owner's Mac.
- Window days are `everyDay`, `weekdays` (Mon–Fri) or `weekends`. Times are minutes from midnight, in the Mac's current time zone, evaluated when a backup starts.
- A window crossing midnight belongs to the day it starts on. Start equal to end is refused.
- User-visible text is in Australian English. Agent error sentences have no closing full stop (the `NetworkSettingsError` style).
- Every commit updates the README and the relevant docs first. No Co-Authored-By, Claude-Session or "Generated with" lines. `TODO.md` is never added.
- CI is `scripts/ci.sh`: `swift test --package-path RestoreyCore`, then the xcodebuild Debug and Release builds.

## Review Focus

1. **A window across midnight, a daylight-saving change, and a time-zone change**, evaluated at a backup's start. A backup at 11 pm Friday in a weekday 10 pm–6 am window is limited; one at 5 am Saturday is too; one at 5 am Monday isn't. Pinned in Task 3.
2. **Two networked backups starting together on an unmeasured network, with a percentage set.** Exactly one test runs, and both backups use its result. Pinned in Task 6.
3. **`networkQuality` problems:** it hangs past its bound, exits 0 with no or partial JSON, or reports `ul_throughput` 0. Each is a failure with a sentence, and the previous measurement is kept. Pinned in Task 4.
4. **The network changes between the test and the backup.** The backup resolves against the network it starts on, not the one tested. Pinned in Task 6.
5. **A schema 4 `config.json` with a Mac-wide limit, plan limits, both, or neither,** migrates to the same KiB values shown in MB, with no window. Pinned in Task 2.

---

### Task 1: The setting types and their validation

**Files:**
- Create: `RestoreyCore/Sources/RestoreyCore/Config/UploadLimit.swift`
- Modify: `RestoreyCore/Sources/RestoreyCore/Config/NetworkSettings.swift`, `RestoreyCore/Sources/RestoreyCore/Config/Plan.swift` (add `uploadLimitUnit`), and every `NetworkSettings(uploadLimitKiB:…)` call site (`NetworkEdit.swift`, `AgentState+Status.swift`, tests)
- Test: `RestoreyCore/Tests/RestoreyCoreTests/Config/UploadLimitTests.swift`, `NetworkSettingsTests` (existing)

**Interfaces:**
- Produces:
  ```swift
  public enum UploadLimitUnit: String, Codable, Sendable, CaseIterable { case kilobytes = "KB", megabytes = "MB" }
  public enum MacUploadLimit: Codable, Sendable, Equatable {
      case none
      case rate(kiB: Int, unit: UploadLimitUnit)
      case percent(Int)
  }
  public enum LimitDays: String, Codable, Sendable, CaseIterable { case everyDay, weekdays, weekends }
  public struct LimitWindow: Codable, Sendable, Equatable {
      public var days: LimitDays
      public var startMinute: Int   // 0..<1440
      public var endMinute: Int     // 0..<1440
  }
  // NetworkSettings: `uploadLimitKiB` is replaced by
  public var uploadLimit: MacUploadLimit
  public var limitWindow: LimitWindow?
  // Plan: `uploadLimitKiB` stays; adds
  public var uploadLimitUnit: UploadLimitUnit   // decodeIfPresent, default .megabytes
  ```
- JSON for `uploadLimit`: `{"kind":"none"}`, `{"kind":"rate","kiB":2048,"unit":"MB"}` or `{"kind":"percent","percent":50}`. Window: `{"days":"weekdays","startMinute":480,"endMinute":1080}`, omitted when nil.
- `NetworkSettingsError` gains `.percentOutOfRange(Int)` "The upload limit must be a percentage from 1 to 100" and `.windowStartEqualsEnd` "The limit’s start and end times can’t be the same". It keeps `.limitNotPositive` for a rate ≤ 0. Minutes outside 0..<1440 are refused as `.windowTimeInvalid` "A limit time must be within the day". Order: limit, window, then the Wi-Fi errors.

- [ ] **Step 1: Write the failing tests**
  - `macUploadLimitRoundTripsEachKind`: encode then decode each case. The JSON contains `"kind":"rate"` and `"unit":"MB"` for the rate case.
  - `windowIsOmittedWhenNil`: the encoded JSON has no `limitWindow` key.
  - `validationRefusesEachBadLimitAndWindow`: `.rate(kiB: 0, …)` → `[.limitNotPositive]`, `.percent(0)` and `.percent(101)` → `.percentOutOfRange`, window 480/480 → `[.windowStartEqualsEnd]`, `endMinute: 1440` → `.windowTimeInvalid`. `.percent(1)`, `.percent(100)` and window 1320/360 (crossing midnight) validate clean.
  - `planWithoutUnitDecodesAsMegabytes`.
- [ ] **Step 2: Run** `swift test --package-path RestoreyCore --filter UploadLimitTests`. Expected: FAIL (types not defined).
- [ ] **Step 3: Implement** the types above. Replace `uploadLimitKiB` on `NetworkSettings`. Update `defaults` to `.none` with no window, and update call sites. Where the agent read `networkSettings.uploadLimitKiB` (`PlanRunner+Steps.swift:69`), temporarily pass `uploadLimit` as a rate's `kiB`, else nil. Task 6 replaces this.
- [ ] **Step 4: Run** the filter, then the whole `swift test --package-path RestoreyCore`. Expected: PASS. (The migration test for schema 4 → 5 doesn't exist yet. Config tests that build schema 4 JSON by hand still pass because Task 2 hasn't bumped the version. If a fixture fails to decode, note it for Task 2 rather than editing the fixture.)
- [ ] **Step 5: Commit.** "Upload limit: a rate with its unit or a percentage, and an optional window"

### Task 2: Schema 5 migration

**Files:**
- Modify: `RestoreyCore/Sources/RestoreyCore/Config/Migrations.swift` (`currentVersion = 5`, `4: convertUploadLimits`)
- Test: `RestoreyCore/Tests/AgentCoreTests/ConfigMigrationTests.swift`; the README's `config.json` section (schema 5)

**Interfaces:**
- Consumes: Task 1's JSON shapes.
- Produces: `@Sendable public static func convertUploadLimits(_ payload: inout [String: Any]) throws`.
  - 4 → 5: `network.uploadLimitKiB: n` becomes `network.uploadLimit = {"kind":"rate","kiB":n,"unit":"MB"}`. A missing value becomes `{"kind":"none"}`, and `uploadLimitKiB` is removed.
  - No `limitWindow` is added.
  - Every plan gets `uploadLimitUnit: "MB"` when it lacks one, and its `uploadLimitKiB` is untouched.
  - A payload without `network` is left without one.

- [ ] **Step 1: Write the failing tests:** `schema4MacWideLimitBecomesAMegabyteRate` (n = 5120 → rate 5120 MB), `schema4WithoutLimitBecomesNone`, `schema4PlansGainMegabyteUnitAndKeepTheirLimit` (a plan with 1536 and one without), `schema4ToCurrentDecodesThroughTheStore` (a `VersionedStore` over a schema 4 file loads a `ConfigFile`, and `config.json.v4.bak` exists).
- [ ] **Step 2: Run** `swift test --package-path RestoreyCore --filter ConfigMigrationTests`. Expected: FAIL.
- [ ] **Step 3: Implement** `convertUploadLimits` and register it. Throw `MigrationError.notAPlanList` for a `plans` value that isn't a list, as the others do.
- [ ] **Step 4: Run** the whole suite. Expected: PASS.
- [ ] **Step 5: Commit**, with the README's schema line and its `config.json` paragraph updated. "Config schema 5: upload limits gain a unit or a percentage"

### Task 3: The window and the resolved Mac-wide limit (pure)

**Files:**
- Create: `RestoreyCore/Sources/RestoreyCore/Config/UploadLimitResolution.swift`
- Test: `RestoreyCore/Tests/RestoreyCoreTests/Config/UploadLimitResolutionTests.swift`

**Interfaces:**
- Consumes: Task 1 types; `UploadSpeedMeasurement` (defined here so Task 4 reuses it).
- Produces:
  ```swift
  public struct UploadSpeedMeasurement: Codable, Sendable, Equatable {
      public var bitsPerSecond: Double
      public var bytesSent: Int64?
      public var measuredAt: Date      // UTC
  }
  extension LimitWindow {
      public func contains(_ date: Date, calendar: Calendar) -> Bool
      /// The next instant after `date` at which `contains` changes value. Nil only if it never changes.
      public func nextChange(after date: Date, calendar: Calendar) -> Date?
  }
  public struct ResolvedMacWideLimit: Sendable, Equatable {
      public enum Reason: Sendable, Equatable {
          case noLimitSet, outsideWindow, rate, percentOf(UploadSpeedMeasurement), percentNotMeasured
      }
      public var kiB: Int?
      public var reason: Reason
      /// When a backup starting later would get a different answer because of the window. Nil without a window.
      public var changesAt: Date?
  }
  public func resolveMacWideLimit(
      _ settings: NetworkSettings, measurement: UploadSpeedMeasurement?, at date: Date, calendar: Calendar
  ) -> ResolvedMacWideLimit
  ```
- Percentage → KiB/s: `floor(bitsPerSecond / 8 / 1024 * percent / 100)`, at least 1. The order is the spec's: window first, then the kind.

- [ ] **Step 1: Write the failing tests.** Use a `Calendar` with time zone `Australia/Adelaide`, and pin these:
  - `weekdayWindowContainsWeekdayHoursOnly`: 8:00–18:00 weekdays. Mon 07:59 false, Mon 08:00 true, Mon 17:59 true, Mon 18:00 false, Sat 12:00 false.
  - `midnightWindowBelongsToTheDayItStarts`: weekdays 22:00–06:00. Fri 23:00 true, Sat 05:00 true, Sat 23:00 false, Mon 05:00 false, Mon 23:00 true.
  - `windowAcrossDaylightSavingStartUsesWallClock`: on 4 Oct 2026 (Adelaide clocks go from 2:00 to 3:00), an everyDay 01:00–04:00 window. 01:30 true, 03:30 true, 04:30 false.
  - `nextChangeIsTheNextBoundary`: Mon 12:00 in an 8–18 weekdays window gives Mon 18:00. Fri 19:00 gives Mon 08:00.
  - `percentOfMeasuredSpeed`: 50% of 320,000,000 bit/s = 19,531 KiB/s (floor). 1% of 8,000 bit/s = 1 (the floor to at least 1).
  - `percentWithoutMeasurementIsNoLimit`: kiB nil, reason `.percentNotMeasured`.
  - `outsideWindowIsNoLimitEvenForARate`: kiB nil, reason `.outsideWindow`, `changesAt` set.
  - `rateWithoutWindowNeverChanges`: `changesAt` nil.
- [ ] **Step 2: Run** `swift test --package-path RestoreyCore --filter UploadLimitResolutionTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** For `contains`, take the calendar day of `date` and the day before, then test whether `date` falls in either day's interval, where that day's start is allowed by `days`. Build each interval from the day's start minute plus the duration in minutes (crossing midnight adds 1440), using `calendar.date(bySettingHour:minute:…)` so wall-clock times survive DST. For `nextChange`, take the candidate boundaries over the next 8 days and return the first one after `date`.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit.** "Resolve the Mac-wide upload limit from the window and the measured speed"

### Task 4: The speed test runner and the measurements store

**Files:**
- Create: `RestoreyCore/Sources/RestoreyCore/Network/NetworkQuality.swift` (parser and runner), `RestoreyCore/Sources/RestoreyCore/Network/UploadSpeeds.swift` (`NetworkKey`, the file payload)
- Test: `RestoreyCore/Tests/RestoreyCoreTests/Network/NetworkQualityTests.swift`, `UploadSpeedsTests.swift`, fixtures in `Fixtures/networkQuality/` (a full JSON document, one with `ul_throughput` 0, one truncated)

**Interfaces:**
- Produces:
  ```swift
  public enum NetworkKey: Codable, Sendable, Hashable {
      case wiFi(name: String)   // name trimmed, matched like skippedWiFiNames (case- and form-folded)
      case wiFiUnknown, ethernet, other
      public var displayName: String   // “Kerr Home”, "Wi-Fi (name unknown)", "Ethernet", "this network"
  }
  public struct UploadSpeedRecord: Codable, Sendable, Equatable {
      public var latest: UploadSpeedMeasurement?
      public var lastFailure: SpeedTestFailure?
  }
  public struct SpeedTestFailure: Codable, Sendable, Equatable { public var at: Date; public var reason: String }
  public struct UploadSpeedsFile: Codable, Sendable, Equatable { public var records: [NetworkKey: UploadSpeedRecord] }
  public enum NetworkQuality {
      public static let executable = URL(fileURLWithPath: "/usr/bin/networkQuality")
      public static let arguments = ["-d", "-c", "-M", "20"]   // upload only, JSON, 20 s bound
      public static let killAfter: Duration = .seconds(10)     // past the bound
      public static func parse(stdout: Data, bytesFallback: Int64?) -> Result<UploadSpeedMeasurementDraft, SpeedTestError>
      public static func run(executable: URL, now: @Sendable () -> Date) async -> Result<UploadSpeedMeasurement, SpeedTestError>
  }
  public enum SpeedTestError: Error, Equatable { case couldNotStart(String), timedOut, exited(Int32), unreadable, noUploadMeasured
      public var message: String }
  ```
  `UploadSpeedMeasurementDraft` is `(bitsPerSecond, bytesSent)`; `run` stamps `measuredAt`. `NetworkKey` must encode as a dictionary key; give it a string `CodingKeyRepresentable` form, `"wifi:<name>"`, `"wifi?"`, `"ethernet"`, `"other"`. The store is `VersionedStore<UploadSpeedsFile>` at `upload-speeds.json`, schema 1, no migrations.
- Messages (no closing full stop): `couldNotStart` "The upload speed test couldn’t start: <reason>", `timedOut` "The upload speed test didn’t finish in time", `exited` "The upload speed test stopped with an error (<code>)", `unreadable` "The upload speed test’s result couldn’t be read", `noUploadMeasured` "The upload speed test didn’t measure any upload".

- [ ] **Step 1: Write the failing tests.**
  - `parsesUploadThroughputAndBytes`: the full fixture gives its `ul_throughput` and `ul_bytes_transferred`.
  - `zeroThroughputIsNoUploadMeasured`.
  - `truncatedJSONIsUnreadable`.
  - `runReportsExitAndTimeout`: these use shell-script stand-ins written to a temp directory. One prints the fixture and exits 0. One exits 3. One `sleep`s past a bound shortened to 1 s through a test-only parameter. They give success, `.exited(3)` and `.timedOut` respectively, and the sleeper is killed.
  - `networkKeysRoundTripAsDictionaryKeys`, and `wiFiKeysMatchIgnoringCaseAndForm` ("Café" precomposed equals decomposed, and "kerr home" equals "Kerr Home").
- [ ] **Step 2: Run** `swift test --package-path RestoreyCore --filter "NetworkQualityTests|UploadSpeedsTests"`. Expected: FAIL.
- [ ] **Step 3: Implement.** Use `Foundation.Process`. Read stdout fully, then wait, enforcing the bound with a task that sends `terminate()` at the bound and `SIGKILL` `killAfter` later. Give `run` an internal `bound: Duration = .seconds(20 + 5)` parameter for the tests. Don't route this through `ResticProcess`: that type is restic-specific (messages, redaction, supervisor).
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit.** "Run macOS's networkQuality and keep its upload result per network"

### Task 5: Which network the Mac is on

**Files:**
- Modify: `RestoreyCore/Sources/RestoreyCore/Schedule/Preflight.swift` (`NetworkState`), `Agent/SystemObservers.swift` (map `NWPath`), `RestoreyCore/Sources/AgentCore/NetworkPath.swift`, and every `.satisfied(constrained:expensive:)` pattern and constructor
- Test: `NetworkPathTests`, `PreflightTests`

**Interfaces:**
- Produces:
  ```swift
  public enum NetworkInterface: String, Sendable, Equatable { case wiFi, wired, other }
  case satisfied(constrained: Bool, expensive: Bool, interface: NetworkInterface = .other)
  public func networkKey(for state: NetworkState, wiFiName: String?) -> NetworkKey?   // nil when unsatisfied
  ```
  `wiFi` plus a name gives `.wiFi(name:)`. `wiFi` with nil or an empty name gives `.wiFiUnknown`. `wired` gives `.ethernet`, and `other` gives `.other`. The agent maps `NWPath` by `usesInterfaceType(.wifi)`, then `.wiredEthernet`, else `.other`.
- `NetworkPath.update` already treats a change in only constrained or expensive as "not restored". A change in only the interface is not "restored" either.

- [ ] **Step 1: Write the failing tests:** `networkKeyForEachInterface` (the four cases above, plus unsatisfied → nil), and `interfaceChangeAloneIsNotARestore`.
- [ ] **Step 2: Run** `swift test --package-path RestoreyCore --filter "NetworkPathTests|PreflightTests"`. Expected: FAIL.
- [ ] **Step 3: Implement.** Update patterns that bind both values (`case .satisfied(let constrained, let expensive)`) to bind or ignore the third.
- [ ] **Step 4: Run** the whole suite and `xcodebuild` Debug (the Agent target maps `NWPath`). Expected: PASS and BUILD SUCCEEDED.
- [ ] **Step 5: Commit.** "Network state carries the interface type, giving each network a key"

### Task 6: The agent tests and resolves at a backup's start

**Files:**
- Create: `RestoreyCore/Sources/AgentCore/SpeedTester.swift`
- Modify: `RestoreyCore/Sources/AgentCore/RunnerDependencies.swift` (inject the tester), `PlanRunner+Steps.swift` (resolve, log, and count networked commands), `PlanRunner.swift` (`networkedCommands`), `SchedulerCore.swift` (the daily test on the tick), `AgentState.swift` (own the `upload-speeds.json` store), `Agent/main.swift` (wire the real runner and Wi-Fi name)
- Test: `RestoreyCore/Tests/AgentCoreTests/SpeedTesterTests.swift`, `PlanRunnerTests` (limit resolution)

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces:
  ```swift
  public actor SpeedTester {
      public init(store: any PayloadStore<UploadSpeedsFile>, run: @escaping @Sendable () async -> Result<UploadSpeedMeasurement, SpeedTestError>,
                  now: @escaping @Sendable () -> Date, log: @escaping @Sendable (String) -> Void)
      public var isTesting: Bool { get }
      public func record(for key: NetworkKey) -> UploadSpeedRecord?
      /// Runs one test for `key`, or joins the one in flight. Saves success as `latest` and a failure as `lastFailure`, keeping `latest`.
      public func test(_ key: NetworkKey) async -> Result<UploadSpeedMeasurement, SpeedTestError>
      /// Whether a test for `key` has succeeded or failed on `now`'s calendar day.
      public func testedToday(_ key: NetworkKey, calendar: Calendar) -> Bool
  }
  public enum SpeedTestRefusal: Equatable { case noNetwork, constrained, skippedWiFi(String), networkedCommandRunning
      public var message: String }
  ```
- In `PlanRunner`, `networkedCommands: Set<UUID>` counts every restic command against a repository with `needsNetwork`. `networkedUploads` stays as the backup-only count for sharing.
- A test may start only when `networkedCommands` is empty. A networked command that is about to start first `await`s `speedTester.waitUntilIdle()`. Add that method: it returns at once when there's no test.
- **Resolution at a backup's start**, replacing Task 1's stopgap, in this order:
  1. Read the network key.
  2. If the setting is a percentage, the key has no measurement, the window would contain now, and the network is testable, `await test(key)`.
  3. Resolve with `resolveMacWideLimit(…, calendar: .current)` and pass `resolved.kiB` as `macWide`.
  4. Log one line: "Mac-wide upload limit <x>: <how>". `<x>` is "none" or "<n> KB/s" / "<n> MB/s" via `FormValidation.uploadLimitText`. `<how>` is one of "50% of 38 MB/s measured on “Kerr Home” <date>", "a fixed rate", "outside <window>", "not measured on <network> yet", or "no limit set".
- **The daily test:** on each scheduler tick, when the setting is a percentage, the network is testable, `networkedCommands` is empty and `!testedToday(key)`, start `test(key)` without blocking the tick.

- [ ] **Step 1: Write the failing tests.** Use a fake `run` that counts calls and can be held open with a continuation.
  - `twoBackupsOnAnUnmeasuredNetworkShareOneTest`: two networked backups start together with a percentage set. The fake is called once, and both invocations carry the same `--limit-upload`.
  - `aFailedPreBackupTestGivesNoMacWideLimit`: there's no `--limit-upload` (no plan limit). `lastFailure` is saved, and an earlier `latest` is kept.
  - `outsideTheWindowNoPreBackupTestRuns`: the fake isn't called.
  - `aBackupResolvesAgainstTheNetworkItStartsOn`: "Home" is measured at 320 Mbit/s and "Office" at 80 Mbit/s, with a 50% limit. A backup starting on Office gets 4,882 KiB/s.
  - `aNetworkedCommandWaitsForATestInFlight`: hold the fake open and start a backup. The fake is released before restic's fake executable is launched.
  - `noTestWhileANetworkedCommandRuns` and `noTestOnAConstrainedNetworkOrSkippedWiFi`.
  - `theDailyTestRunsOncePerNetworkPerDay`: two ticks on the same day give one call. Advance the clock past midnight and the next tick calls again.
  - `aRateNeverRunsTheDailyTest`.
- [ ] **Step 2: Run** `swift test --package-path RestoreyCore --filter "SpeedTesterTests|PlanRunnerTests"`. Expected: FAIL.
- [ ] **Step 3: Implement.** Testability: the network is satisfied, not constrained or expensive when `skipOnConstrainedNetwork`, and not a skipped Wi-Fi name. Reuse `NetworkSettings.isSkipped`. Joining a test in flight means one stored `Task` per key.
- [ ] **Step 4: Run** the whole suite and the Debug build. Expected: PASS and BUILD SUCCEEDED.
- [ ] **Step 5: Commit**, with the README paragraph on `--limit-upload` (§ `config.json`) and the restorey design §5.3 pointer to this spec updated. "The agent measures upload speed per network and resolves the Mac-wide limit at each backup's start"

### Task 7: The XPC call and the status

**Files:**
- Modify: `RestoreyCore/Sources/RestoreyCore/XPC/AgentProtocol.swift`, `Messages.swift` (`AgentStatus.uploadSpeed`), `Agent/AgentService.swift`, `AgentState+Status.swift`, `App/AgentConnection.swift` (the call)
- Test: `RestoreyCore/Tests/RestoreyCoreTests/XPC/MessagesTests.swift`, `AgentStateTests`

**Interfaces:**
- Produces:
  ```swift
  /// → `AgentStatus`. Runs an upload speed test on the current network now, or joins one in flight; refusals (`SpeedTestRefusal.message`) come back as the error.
  func runUploadSpeedTest(withReply reply: @escaping @Sendable (Data?, String?) -> Void)
  public struct UploadSpeedStatus: Codable, Sendable, Equatable {
      public var network: NetworkKey?          // nil with no network
      public var record: UploadSpeedRecord?
      public var testing: Bool
  }
  // AgentStatus gains `public var uploadSpeed: UploadSpeedStatus?` (decodeIfPresent; nil from an older agent)
  ```
  A test's own failure is not an XPC error: the reply is the status with `lastFailure` set. Only a refusal is an error. A config error or draining refuses, as other mutating calls do. Add `runUploadSpeedTest` to the doc comment's list of mutating calls.
- [ ] **Step 1: Write the failing tests:** `agentStatusDecodesWithoutUploadSpeed` (older agent JSON), `uploadSpeedStatusRoundTrips`, `runUploadSpeedTestIsRefusedOnAConstrainedNetwork`, and `runUploadSpeedTestReturnsTheStatusWithTheFailure` (fake run fails; the reply has `lastFailure`, not an error).
- [ ] **Step 2: Run** `swift test --package-path RestoreyCore --filter "MessagesTests|AgentStateTests"`. Expected: FAIL.
- [ ] **Step 3: Implement.** A test running from the daily tick or before a backup also sets `testing`. Status pushes go out when a test starts and ends, the same way other changes publish the status.
- [ ] **Step 4: Run** the whole suite and the Debug build. Expected: PASS and BUILD SUCCEEDED.
- [ ] **Step 5: Commit**, with the README's XPC section updated. "XPC: runUploadSpeedTest, and the upload speed in the agent's status"

### Task 8: Settings → Network, the plan limit's unit, and Location

**Files:**
- Modify: `RestoreyCore/Sources/RestoreyCore/App/NetworkEdit.swift`, `PlanEdit.swift`, `FormValidation.swift` (unit-aware `uploadLimit(_:unit:)` and `uploadLimitText(kiB:unit:)`), `StepperText.swift`, `App/Settings/NetworkPane.swift`, `App/Settings/PlanScheduleTab.swift`, `App/Controls/ScheduleControls.swift` (`UploadLimitField` gains a unit picker), `Agent/Info.plist` (Location text), `scripts/verify-bundle.sh` (`location_text`)
- Test: `RestoreyCore/Tests/RestoreyCoreTests/App/NetworkEditTests.swift`, `PlanEditTests`, `FormValidationTests`

**Interfaces:**
- Consumes: Tasks 1, 3 and 7.
- Produces:
  ```swift
  public enum LimitKind: String, CaseIterable, Sendable { case none, kilobytes, megabytes, percent }  // the picker: None · KB/s · MB/s · % of upload speed
  // NetworkEdit.Fields gains: limitKind, limitAmount: String, windowEnabled: Bool, windowDays: LimitDays, windowStart: Int, windowEnd: Int
  public static func uploadLimit(_ text: String, unit: UploadLimitUnit) -> Result<Int?, Problem>
  public static func uploadLimitText(kiB: Int?, unit: UploadLimitUnit) -> String
  public static func percent(_ text: String) -> Result<Int, Problem>   // "Enter a percentage from 1 to 100."
  public func nowLine(status: UploadSpeedStatus?, at: Date, calendar: Calendar) -> String   // on NetworkEdit
  public func speedLine(_ status: UploadSpeedStatus?, now: Date, calendar: Calendar) -> String
  ```
  - `nowLine` uses `resolveMacWideLimit` and gives "Now: 20 MB/s, until 6:00 pm", "Now: no limit, from 8:00 am Monday", "No limit right now" or "Now: no limit until this network is measured".
  - `speedLine` gives "Upload speed on “Kerr Home”: 38 MB/s, measured today" (or "yesterday", or a date), "Not measured on this network yet", the failure's sentence, "Testing upload speed…", or "Not connected to a network".
  - Speeds show in MB/s with up to one decimal, or in KB/s below 1 MB/s.
- Behaviour:
  - The window row appears whenever the kind isn't `none`, with defaults weekdays 8:00–18:00. **Test now** is disabled while `testing`.
  - Choosing `percent` when `hello.locationAuthorised` isn't true calls the existing `requestLocationPermission`. A refusal shows "Without Location permission, Restorey can’t tell Wi-Fi networks apart, so they share one measurement".
  - The plan's Schedule tab gets the KB/s / MB/s picker only.
  - Switching the unit converts the typed amount (5 MB/s → 5120 KB/s) instead of reinterpreting it.
- Location text, in `Info.plist` (both keys) and `verify-bundle.sh`: "Restorey checks the Wi-Fi network's name so it can skip backups on networks you've listed and measure each network's upload speed."

- [ ] **Step 1: Write the failing tests.**
  - `kilobytesAreReadAsKiB` ("512" KB → 512).
  - `switchingUnitConvertsTheAmount`.
  - `percentRefusesOutOfRange` ("0", "101", "50.5").
  - `nowLineForEachReason`: Adelaide calendar, fixed instants, 50% of a measured 335,544,320 bit/s (exactly 40 MB/s). Within the weekday window it shows "Now: 20 MB/s, until 6:00 pm"; after Friday's window, "Now: no limit, from 8:00 am Monday".
  - `speedLineAges`: today, yesterday, a date.
  - `savingBuildsTheSettings`: percent 50 with weekdays 8–18 gives `.percent(50)` and the window. Choosing `none` saves no window.
  - `planLimitKeepsItsUnit`.
- [ ] **Step 2: Run** `swift test --package-path RestoreyCore --filter "NetworkEditTests|PlanEditTests|FormValidationTests"`. Expected: FAIL.
- [ ] **Step 3: Implement** the models, then the views with the existing controls (`NumberField`, the pickers in `ScheduleControls.swift`). Lay out the views per the spec's sketch.
- [ ] **Step 4: Run** the whole suite, then `scripts/ci.sh`. Expected: PASS, and CI green (Debug and Release, `verify-bundle.sh` passing with the new Location text).
- [ ] **Step 5: Commit**, with the README's Settings → Network, Schedule tab and Location permission paragraphs and the UI design §6.3 pointer updated. "Settings: upload limit unit, percentage, window, speed and Now line"

### Task 9: Live check on the owner's Mac (owner-guided)

No code. Install with `BUILD_NUMBER=<n> scripts/install-dev.sh`, then the owner checks:
1. Choose "% of upload speed", which asks for Location permission. Press **Test now**: "Testing upload speed…" appears, then a speed. The agent log shows the test line with bytes sent.
2. Set a window that contains now. The "Now:" line shows the limit. **Back Up Now** on a networked plan logs "Mac-wide upload limit …: 50% of …" and the matching `--limit-upload`.
3. Set a window that doesn't contain now. The Now line shows "no limit, from …", and a backup logs "outside …" with no Mac-wide `--limit-upload`.

Read only the app and agent logs, and never restic against B2 from this session. Record the results in the build record. Restore the owner's previous limit if they want it.
