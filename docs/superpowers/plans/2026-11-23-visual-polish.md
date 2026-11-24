# Visual Polish Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split Restorey into a main window (Plans, History) and a standard Settings window (General, Notifications, Network), give lists the Mac's + and − control, add folder pickers, add optional status notifications, and clear the audit's leftovers.

**Architecture:** Every decision that can be tested lives in RestoreyCore (window routing in `AppShell`, menu rows in `MenuLayout`, form logic in `NetworkEdit`/`StorageForm`, notification content and gating in AgentCore), because the app target has no unit tests. AppKit keeps owning the windows (`WindowRouter`), SwiftUI draws their content. The agent stays the only writer of config.

**Tech Stack:** Swift 6.4, Swift Testing, SwiftUI + AppKit, NSXPC, UserNotifications, XcodeGen; macOS 27.

**Spec:** `docs/superpowers/specs/2026-11-23-visual-polish-design.md` (read it first; it is the authority). Code map of today's names: the spec's references, plus `AppShell.swift`, `WindowRouter.swift`, `StatusItemController.swift`, `MenuLayout.swift`, `NetworkEdit.swift`, `StorageForm.swift`, `AgentState+Alerts.swift`, `PlanRunner+Backup.swift`.

## Global Constraints

- Australian English in all text; curly quotes and apostrophes (’ “ ”) in UI strings, never straight ones.
- macOS 27 deployment target; no new dependencies.
- The app never writes config; every setting goes to the agent over XPC and the agent validates it.
- Config stays schema 5: a new Mac-wide field is additive, decoded with `decodeIfPresent` and a default (as `NetworkSettings` decodes `uploadLimit`). No migration.
- Settings window: title is the pane's name; panes in this order: General, Notifications, Network; no Save or Revert anywhere in it.
- Main window: sections in this order: Plans, History; the plan editor keeps its Save and Revert bar and `SaveQuestion`.
- Notification defaults: Backup started off, Backup finished off, Problems with backups on.
- Turning Problems off stops posting only: alerts are still raised, so the menu bar icon, banners and check-in pings are unchanged.
- No straight quotes, no "agent" in user-facing text (audit P13): say "Restorey’s background process".
- Update the README (and the UI design §5–§8 pointer) in the task whose behaviour it describes, before that task's commit.
- Test command: `swift test --package-path RestoreyCore` (filter with `--filter`); whole gate `scripts/ci.sh`. App changes are verified by `scripts/ci.sh`'s builds.

## Review Focus

1. **Reopen with the menu bar item hidden** must open Settings ▸ General (the way back to the item), not the main window. Test: `reopenWithAHiddenIconOpensSettingsGeneral` (Task 1).
2. **A refused Network value** must never be kept: the pane shows the agent's sentence and the saved settings stay. Test: `aCommitWithAProblemSendsNothing` and `aRefusedSaveKeepsTheSavedSettings` (Task 3).
3. **Problems off during a failure**: no notification, yet `activeAlerts` still holds `.backupFailed`. Test: `problemsOffRaisesButDoesNotPost` (Task 5).
4. **Several plans backing up at once with started and finished on**: one notification per plan, each replacing its own. Test: `startedAndFinishedShareOnePerPlanIdentifier` (Task 5).
5. **A stale "started" next to a failure**: the plan's started notification is removed when its backup fails. Test: `aFailedBackupRemovesItsStartedNotification` (Task 5).

---

### Task 1: Window routing split (RestoreyCore)

**Files:**
- Modify: `RestoreyCore/Sources/RestoreyCore/App/AppShell.swift`
- Modify: `RestoreyCore/Sources/RestoreyCore/App/SaveQuestion.swift`
- Test: `RestoreyCore/Tests/RestoreyCoreTests/App/AppShellTests.swift`, `SaveQuestionTests.swift`

**Interfaces:**
- Produces:
  - `enum MainSection: String, CaseIterable { case plans, history }` with `title` ("Plans", "History"), `init(remembered: String?)` (fallback `.plans`).
  - `enum SettingsPane: String, CaseIterable { case general, notifications, network }` with `title` ("General", "Notifications", "Network"), `symbolName` ("gearshape", "bell.badge", "network"), `init(remembered: String?)` (fallback `.general`).
  - `struct MainSectionPreference` (UserDefaults key `"mainSection"`) and `struct SettingsPanePreference` (key `"settingsPane"`), each with `init(defaults:)`, `load()`, `save(_:)`. The old key `"settingsSection"` is no longer read.
  - `AppWindowKind` gains `.main` (title "Restorey"); `.settings` title becomes "Settings". `isMiniaturizable` is false only for `.settings`.
  - `enum ShellOpening { case setup, main(MainSection?), settings(SettingsPane?), damagedNotice }`.
  - `shellOpeningOnReopen(mode:statusItemVisible:)`: running → `statusItemVisible ? .main(nil) : .settings(.general)`; refused → `.setup`; broken → `.damagedNotice`. `shellOpeningAtLaunch` keeps returning nil while the icon shows, else the same as reopen.
  - `struct MainRoute { section: MainSection; planID: UUID? }`, `static let initial = MainRoute(section: .plans)`, and `mainRoute(open:section:planID:initial:) -> MainRoute` (today's `settingsRoute`, renamed).
  - `SettingsSection` and `SettingsRoute` are removed. `UnsavedSettings` keeps only the plan case (`.plan`); its `section` becomes `MainSection.plans`. `SaveQuestion.network` is removed.

- [ ] **Step 1: Write the failing tests** (update the existing ones in `AppShellTests.swift` to the new names, and add):

```swift
@Test func reopenOpensTheMainWindowWhileTheIconShows() {
    #expect(shellOpeningOnReopen(mode: .running, statusItemVisible: true) == .main(nil))
}
@Test func reopenWithAHiddenIconOpensSettingsGeneral() {
    #expect(shellOpeningOnReopen(mode: .running, statusItemVisible: false) == .settings(.general))
    #expect(shellOpeningAtLaunch(mode: .running, statusItemVisible: false) == .settings(.general))
}
@Test func eachWindowRemembersItsOwnSectionAndIgnoresTheOldKey() {
    let defaults = UserDefaults(suiteName: "test-\(UUID())")!
    defaults.set("network", forKey: "settingsSection")
    #expect(MainSectionPreference(defaults: defaults).load() == .plans)
    #expect(SettingsPanePreference(defaults: defaults).load() == .general)
    SettingsPanePreference(defaults: defaults).save(.notifications)
    #expect(SettingsPanePreference(defaults: defaults).load() == .notifications)
}
@Test func paneOrderAndTitles() {
    #expect(MainSection.allCases.map(\.title) == ["Plans", "History"])
    #expect(SettingsPane.allCases.map(\.title) == ["General", "Notifications", "Network"])
    #expect(AppWindowKind.main.title == "Restorey")
    #expect(AppWindowKind.settings.title == "Settings")
    #expect(AppWindowKind.main.isMiniaturizable && !AppWindowKind.settings.isMiniaturizable)
}
```

- [ ] **Step 2: Run to see them fail**

Run: `swift test --package-path RestoreyCore --filter "AppShellTests|SaveQuestionTests"`
Expected: build errors for `MainSection`, `SettingsPane`, `.main`.

- [ ] **Step 3: Implement the interfaces above in `AppShell.swift` and `SaveQuestion.swift`.** The app target won't build until Task 2; that is expected within this branch.

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path RestoreyCore --filter "AppShellTests|SaveQuestionTests"`
Expected: PASS.

- [ ] **Step 5: Commit** `git commit -m "Window routing: a main window for plans and history, a Settings window for preferences"`

### Task 2: The two windows in the app

**Files:**
- Modify: `App/WindowRouter.swift`, `App/RestoreyApp.swift`, `App/MainMenu.swift`, `App/StatusItemController.swift`, `App/Settings/SettingsWindow.swift`, `App/Settings/PlansPane.swift` (in-window "Show in History"), `App/Settings/GeneralPane.swift` (route names only)
- Create: `App/MainWindow.swift` (the main window's root view and toolbar, from today's `SettingsWindow` plans/history half)
- Modify: `RestoreyCore/Sources/RestoreyCore/App/MenuLayout.swift`
- Test: `RestoreyCore/Tests/RestoreyCoreTests/App/MenuLayoutTests.swift`

**Interfaces:**
- Consumes: Task 1's `MainSection`, `SettingsPane`, `ShellOpening`, `MainRoute`, preferences, `AppWindowKind.main`.
- Produces:
  - `MenuCommand.openRestorey`; `MenuLayout.rows` puts `MenuItem("Open Restorey", command: .openRestorey)` directly above `Settings…`.
  - `WindowRouter.showMain(section: MainSection? = nil, planID: UUID? = nil, tab: PlanTab? = nil)` and `WindowRouter.showSettings(pane: SettingsPane? = nil)`; `show(_ opening: ShellOpening)` handles both.
  - Main window: frame autosave name `"RestoreyMain"`, toolbar identifier `"RestoreyMainToolbar"`, items Plans and History (symbols `list.bullet.rectangle`, `clock.arrow.circlepath`), title follows the section. Holds the plan editor slot, the unsaved-plan close question, and the "Discard your changes" alert.
  - Settings window: frame autosave name `"RestoreySettingsWindow"`, toolbar identifier `"RestoreySettingsToolbar"`, `toolbarStyle = .preference`, not resizable horizontally (fixed width 560; the builder may adjust after the live look), title follows the pane. Closing it never asks a question.

- [ ] **Step 1: Write the failing test** in `MenuLayoutTests.swift`:

```swift
@Test func openRestoreyComesJustBeforeSettings() {
    let rows = MenuLayout.rows(.sample, developer: false)
    let titles = rows.compactMap { if case .item(let i) = $0 { i.title } else { nil } }
    let open = try! #require(titles.firstIndex(of: "Open Restorey"))
    #expect(titles[open + 1] == "Settings…")
    #expect(rows.contains(.item(MenuItem("Open Restorey", command: .openRestorey))))
}
```
(Use the suite's existing sample content in place of `.sample`.)

- [ ] **Step 2: Run to see it fail**: `swift test --package-path RestoreyCore --filter MenuLayoutTests` → FAIL (no `openRestorey`).

- [ ] **Step 3: Implement.** Route every call site from the spec's list:
  - `.openPlan(id)` → `showMain(section: .plans, planID: id)`;
  - `.openRestorey` → `showMain()`;
  - `.settings` and ⌘, → `showSettings()`;
  - `.showLog` fallback and `.showDetails(id)` → `showMain(section: .history, planID:)`;
  - `.addCheckInURL(id)` → `showMain(section: .plans, planID: id, tab: .schedule)`;
  - `.showSettingsError` → `showMain(section: .plans)`;
  - `.openFullDiskAccess` → `showSettings(pane: .general)`, as today plus System Settings;
  - reopen and launch → `show(shellOpening…)`.

  `WindowActivation`, `WindowPresence` and `OwnerAuthentication` treat `.main` like `.settings` today: it is a window that makes the app regular. The Settings window shows General and Network (Notifications arrives in Task 6; until then the toolbar lists all three and Notifications shows the existing permission row moved from General).

- [ ] **Step 4: Verify**: `swift test --package-path RestoreyCore --filter MenuLayoutTests` → PASS; `scripts/ci.sh` → green (Debug and Release builds compile the app).

- [ ] **Step 5: Update README** ("Menus and windows", "Settings", "The menu bar") and the UI design §6 with a pointer to the spec. **Commit** `git commit -m "Main window and Settings window; Open Restorey in the menu"`

### Task 3: Network applies as you go

**Files:**
- Modify: `RestoreyCore/Sources/RestoreyCore/App/NetworkEdit.swift`
- Modify: `App/Settings/NetworkEditModel.swift`, `App/Settings/NetworkPane.swift`
- Test: `RestoreyCore/Tests/RestoreyCoreTests/App/NetworkEditTests.swift`

**Interfaces:**
- Produces: `NetworkEdit.commit() -> NetworkEdit.Commit` where `enum Commit: Equatable { case nothing, send(NetworkSettings), problem(String) }`: `.nothing` when not dirty, `.problem` when `problem != nil`, else `.send(request())`. `nowLine(status:at:calendar:locale:)` never appends ". Updates when you save." (remove the parameterising of dirty state).
- `NetworkEditModel.commit() async`: called on a toggle or picker change at once, and on a text field's `onSubmit` and focus loss; `.send` calls `supervisor.connection.saveNetworkSettings`, success → `edit.didSave`, refusal → `saveError` (shown beside the form, settings unchanged). No `save()`/`revert()` buttons; `saveBar` is removed. When the agent status is nil the pane shows `Text("Waiting for Restorey’s background process…")` beside the spinner, as PlansPane does. The model is discarded when the window closes, so invalid edits are dropped.

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func aCleanEditCommitsNothing() {
    #expect(NetworkEdit(saved: .defaults).commit() == .nothing)
}
@Test func aCommitWithAProblemSendsNothing() {
    var edit = NetworkEdit(saved: .defaults)
    edit.fields.limitKind = .percent
    edit.fields.windowEnabled = true
    edit.fields.windowStart = 600; edit.fields.windowEnd = 600
    #expect(edit.commit() == .problem("The limit’s start and end times can’t be the same."))
}
@Test func aValidChangeIsSentWhole() {
    var edit = NetworkEdit(saved: .defaults)
    edit.fields.skipOnConstrainedNetwork = false
    guard case .send(let settings) = edit.commit() else { Issue.record("expected send"); return }
    #expect(settings.skipOnConstrainedNetwork == false)
}
@Test func aRefusedSaveKeepsTheSavedSettings() {
    var edit = NetworkEdit(saved: .defaults)
    edit.fields.skipOnConstrainedNetwork = false
    _ = edit.commit()                      // the agent refuses: didSave is never called
    #expect(edit.saved == .defaults)
}
```
Update the three `". Updates when you save."` expectations (NetworkEditTests.swift:333,336,342) to the line without it. Use the real field names and minute representation from `NetworkEdit.Fields`; the values above are illustrative of the window rule, not new API.

- [ ] **Step 2: Run to see them fail**: `swift test --package-path RestoreyCore --filter NetworkEditTests` → FAIL.
- [ ] **Step 3: Implement** the interfaces above.
- [ ] **Step 4: Verify**: the filter passes; `scripts/ci.sh` green.
- [ ] **Step 5: README** (Settings ▸ Network: changes apply as you make them). **Commit** `git commit -m "Settings ▸ Network applies changes as they are made"`

### Task 4: Notification settings: config, agent and XPC

**Files:**
- Create: `RestoreyCore/Sources/RestoreyCore/Config/NotificationSettings.swift`
- Modify: `RestoreyCore/Sources/AgentCore/PayloadStore.swift` (`ConfigFile`), `RestoreyCore/Sources/AgentCore/AgentState+Plans.swift`, `RestoreyCore/Sources/RestoreyCore/XPC/AgentProtocol.swift`, `RestoreyCore/Sources/RestoreyCore/XPC/Messages.swift` (`AgentStatus`), `Agent/AgentService.swift`, `App/AgentConnection.swift`
- Test: `RestoreyCore/Tests/RestoreyCoreTests/Config/NotificationSettingsTests.swift`, `RestoreyCore/Tests/AgentCoreTests/AgentStateTests.swift`

**Interfaces:**
- Produces:
  - `public struct NotificationSettings: Codable, Sendable, Equatable { var backupStarted: Bool; var backupFinished: Bool; var problems: Bool; static let defaults = NotificationSettings(backupStarted: false, backupFinished: false, problems: true) }`, decoding each key with `decodeIfPresent` and the default.
  - `ConfigFile.notifications: NotificationSettings` with a hand-written `init(from:)` (`decodeIfPresent(…, forKey: .notifications) ?? .defaults`; `plans` and `network` as today).
  - `AgentState.saveNotificationSettings(_:) async throws -> AgentStatus` (`requireMutable()`, save, `pushStatus()`; no validation errors exist for three booleans).
  - `AgentStatus.notifications: NotificationSettings?` (nil from an older agent).
  - XPC `saveNotificationSettings(_ request: Data, withReply:)` on `AgentXPC`; `AgentConnection.saveNotificationSettings(_:) async -> Result<AgentStatus, AgentCallError>` (same `statusCall` pattern as `saveNetworkSettings`).

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func defaultsAreProblemsOnly() {
    #expect(NotificationSettings.defaults == NotificationSettings(backupStarted: false, backupFinished: false, problems: true))
}
@Test func aConfigWithoutNotificationsDecodesToTheDefaults() throws {
    let json = #"{"plans":[],"network":{"skipOnConstrainedNetwork":true,"skippedWiFiNames":[]}}"#
    let config = try JSONDecoder().decode(ConfigFile.self, from: Data(json.utf8))
    #expect(config.notifications == .defaults)
}
@Test func savedNotificationSettingsAreInTheStatus() async throws {   // AgentStateTests
    let state = /* the suite's existing fixture */
    let status = try await state.saveNotificationSettings(.init(backupStarted: true, backupFinished: false, problems: true))
    #expect(status.notifications?.backupStarted == true)
}
```

- [ ] **Step 2: Run to see them fail**: `swift test --package-path RestoreyCore --filter "NotificationSettingsTests|AgentStateTests"` → FAIL.
- [ ] **Step 3: Implement** the interfaces above.
- [ ] **Step 4: Verify** the filter passes and `ConfigMigrationTests` still pass (schema stays 5).
- [ ] **Step 5: README** (config.json section: the `notifications` object). **Commit** `git commit -m "Notification settings in config, the agent's status and XPC"`

### Task 5: The agent posts status notifications and honours Problems

**Files:**
- Modify: `RestoreyCore/Sources/AgentCore/AlertContent.swift`, `RestoreyCore/Sources/AgentCore/AgentState+Alerts.swift`, `RestoreyCore/Sources/AgentCore/PlanRunner+Backup.swift`, `Agent/Notifier.swift`, the `AlertNotifying` fakes in `RestoreyCore/Tests/AgentCoreTests/Support`
- Test: `RestoreyCore/Tests/AgentCoreTests/AgentStateAlertTests.swift`, `AlertContentTests.swift`, `PlanRunnerTests.swift`

**Interfaces:**
- Consumes: Task 4's `ConfigFile.notifications`.
- Produces:
  - `AlertNotifying.remove(identifiers: [String]) async` (Notifier: `removeDeliveredNotifications(withIdentifiers:)` and pending ones).
  - `AlertContent.backupStarted(plan: Plan, at: Date, calendar:locale:)` and `AlertContent.backupFinished(plan: Plan, record: RunRecord, calendar:locale:) -> AlertContent?` (nil unless the outcome is `.success(snapshotID: .some)`, `.unchanged` or `.warning`). Both use identifier `"event.\(plan.id.uuidString)"` and thread `"plan.\(plan.id.uuidString)"`. Titles, em dash as the alerts use: started "Backing up — \(name)", finished "Backed up — \(name)", body for finished is the menu's wording ("Nothing new to back up" for unchanged; "1 file couldn’t be read" for a warning; "Finished at 9:19 am" for success), started body "Started at 9:19 am".
  - `AgentState.noteBackupStarted(_ plan: Plan, at: Date)` and `AgentState.noteBackupEnded(_ plan: Plan, record: RunRecord)`: post only when the matching setting is on and notifications are authorised; on a failure verdict (the same set `AlertPolicy` treats as failed) remove `"event.<id>"`. Bounded by the existing `alertCallTimeout`; the runner calls them without awaiting the notification centre (`Task { await state.note… }`), so restic is never delayed.
  - Gating in `deliverOnce()`: with `notifications.problems == false`, conditions are still reconciled and stored, nothing is queued for posting, and `.notificationsOff` is not inserted (pass `notificationsAuthorised: true` to `alertConditions` for that purpose).
  - Runner hooks: `noteBackupStarted` right before `runStep(.backup, …)` in `backupSlot` (after the winding-down check), `noteBackupEnded` after `commit(backup.record, …)`.

- [ ] **Step 1: Write the failing tests** (in the suites' existing fixture style):

```swift
@Test func problemsOffRaisesButDoesNotPost() async throws {
    // notifications.problems = false; a failed backup record arrives
    #expect(activeAlerts(for: plan).contains(.backupFailed))
    #expect(notifier.posted.isEmpty)
}
@Test func notificationsOffIsNotRaisedWhileProblemsIsOff() async throws {
    // authorised == false, problems == false
    #expect(!activeAlerts(for: plan).contains(.notificationsOff))
}
@Test func startedAndFinishedShareOnePerPlanIdentifier() {
    let started = AlertContent.backupStarted(plan: planA, at: now, calendar: cal, locale: auLocale)
    let finished = try! #require(AlertContent.backupFinished(plan: planA, record: successRecord(planA), calendar: cal, locale: auLocale))
    let other = AlertContent.backupStarted(plan: planB, at: now, calendar: cal, locale: auLocale)
    #expect(started.identifier == finished.identifier)
    #expect(started.identifier == "event.\(planA.id.uuidString)")
    #expect(other.identifier != started.identifier)
    #expect(started.title == "Backing up — \(planA.name)")
    #expect(finished.title == "Backed up — \(planA.name)")
}
@Test func finishedIsOnlyForABackupThatSavedItsData() {
    #expect(AlertContent.backupFinished(plan: planA, record: record(.cancelled), calendar: cal, locale: auLocale) == nil)
    #expect(AlertContent.backupFinished(plan: planA, record: record(.failed(exitCode: 1, reason: "x")), calendar: cal, locale: auLocale) == nil)
    #expect(AlertContent.backupFinished(plan: planA, record: record(.warning(unreadable: 1)), calendar: cal, locale: auLocale)?.body == "1 file couldn’t be read")
}
@Test func aFailedBackupRemovesItsStartedNotification() async throws {
    // started on; a failed record ends the backup
    #expect(notifier.removed.contains("event.\(plan.id.uuidString)"))
}
@Test func startedAndFinishedArePostedOnlyWhenOn() async throws {   // PlanRunnerTests, fake notifier
    // defaults: a successful backup posts nothing; with both on, one started then one finished, same identifier
}
```

- [ ] **Step 2: Run to see them fail**: `swift test --package-path RestoreyCore --filter "AgentStateAlertTests|AlertContentTests|PlanRunnerTests"` → FAIL.
- [ ] **Step 3: Implement** the interfaces above.
- [ ] **Step 4: Verify** the filter passes, then the whole `swift test --package-path RestoreyCore`.
- [ ] **Step 5: README** (Alerts: the three options, and Problems off still shows in the menu bar and check-ins). **Commit** `git commit -m "Optional backup started and finished notifications; Problems can be turned off"`

### Task 6: Settings ▸ Notifications pane

**Files:**
- Create: `App/Settings/NotificationsPane.swift`
- Modify: `App/Settings/GeneralPane.swift` (the notifications permission row moves out), `App/Settings/SettingsWindow.swift`, `RestoreyCore/Sources/RestoreyCore/App/SettingsGeneral.swift`
- Test: `RestoreyCore/Tests/RestoreyCoreTests/App/SettingsGeneralTests.swift`

**Interfaces:**
- Consumes: Task 4's `NotificationSettings`, `AgentStatus.notifications`, `AgentConnection.saveNotificationSettings`; existing `SettingsGeneral.notifications(hello:)` line and `requestNotificationPermission`.
- Produces: `SettingsGeneral.asksPermission(turningOn: Bool, authorised: Bool?) -> Bool` (true only when turning a switch on and `authorised == nil`). Pane layout and copy exactly as the spec's sketch: switches "Backup started", "Backup finished", "Problems with backups"; under Problems, when off: "When this is off, the menu bar icon still shows a problem, and so does a check-in URL if you’ve set one."; then the permission line. Each switch saves at once; while the status is nil, the switches are disabled with "Waiting for Restorey’s background process…".

- [ ] **Step 1: Write the failing test:**

```swift
@Test func turningASwitchOnAsksOnlyWhenNeverAsked() {
    #expect(SettingsGeneral.asksPermission(turningOn: true, authorised: nil))
    #expect(!SettingsGeneral.asksPermission(turningOn: true, authorised: true))
    #expect(!SettingsGeneral.asksPermission(turningOn: true, authorised: false))
    #expect(!SettingsGeneral.asksPermission(turningOn: false, authorised: nil))
}
```
- [ ] **Step 2: Run to see it fail**: `--filter SettingsGeneralTests` → FAIL.
- [ ] **Step 3: Implement** the pane and the function.
- [ ] **Step 4: Verify** the filter passes; `scripts/ci.sh` green.
- [ ] **Step 5: README** (Settings ▸ Notifications). **Commit** `git commit -m "Settings ▸ Notifications"`

### Task 7: Lists with joined + and −

**Files:**
- Modify: `App/Controls/SquareButton.swift` (turn `ListAddRemoveBar` into a bordered container), `App/Settings/PlansPane.swift`, `App/Controls/SourcesEditor.swift`, `App/Controls/ExclusionsSheet.swift`, `App/Controls/FileTypesEditor.swift`, `App/Settings/NetworkPane.swift`

**Interfaces:**
- Produces: `struct BorderedList<Content: View>: View` (`init(addName: String, removeName: String, canAdd: Bool, canRemove: Bool, add: @escaping () -> Void, remove: @escaping () -> Void, @ViewBuilder content: () -> Content)`): one rounded border (the system's bordered-list stroke and corner radius) around the list content and a bar of two `SquareButton`s (`+`, `−`) at its bottom edge, separated from the list by a hairline, no gap. `ListAddRemoveBar` is removed once every caller uses `BorderedList`.
- Per list:
  - **Plans:** + is "Add Plan…", − is "Delete Plan…", the actions as today.
  - **Folders** (`SourcesEditor`): + opens the existing `NSOpenPanel` via `choose()`; − removes the selection. The separate "Add Folder or Drive…" and "Remove" buttons are deleted. Drag and drop and the context menu stay.
  - **Exclusions:** + is the existing `addFolder` panel ("Leave Out"); − removes the selected rows that aren't Restorey’s own. The "Add Folder…" and "Remove" buttons are deleted.
  - **File types and skipped Wi-Fi networks:** the list becomes a selectable `List`. + opens a small popover holding the existing name field and Add button (same validation, and the Location-permission flow for Wi-Fi). − removes the selection. Each row's Remove button is deleted.

- [ ] **Step 1: No RestoreyCore logic changes; verification is by build and the owner's live look.** Confirm no test references the removed buttons: `rg -n "Add Folder or Drive|ListAddRemoveBar" RestoreyCore/Tests` → no matches.
- [ ] **Step 2: Implement** `BorderedList` and convert the five lists.
- [ ] **Step 3: Verify**: `scripts/ci.sh` green. With no unit tests here, the task review reads each converted view for keyboard access: − disabled with nothing removable selected, `.onDeleteCommand` kept where it existed, accessibility labels equal to the button names. The look itself is checked in Task 10.
- [ ] **Step 4: README** (folders, exclusions and Wi-Fi descriptions mention + and −). **Commit** `git commit -m "Lists use the Mac's joined + and − buttons"`

### Task 8: A folder or drive on this Mac, chosen with a picker

**Files:**
- Modify: `RestoreyCore/Sources/RestoreyCore/App/StorageForm.swift`, `App/Setup/StorageView.swift`
- Test: `RestoreyCore/Tests/RestoreyCoreTests/App/StorageFormTests.swift`

**Interfaces:**
- Produces:
  - `StorageForm.Kind` gains `.folder` (order `b2, s3, folder, other`; title "Folder or Drive"; `helpLink` nil) and `StorageForm.folderPath: String`.
  - `repositoryProblem` for `.folder`: empty → "Choose a folder or drive for the backups.".
  - `repositoryValue` for `.folder` → `.raw(repository: folderPath, environmentNames: [])`.
  - `init(repository:)` maps a `.raw` whose `localFolderPath` is non-nil and that has no environment names to `.folder` with `folderPath = localFolderPath`. Other `.raw` values stay `.other`.
  - `planName(for:)` for `.folder` → "Local · <last component>", as for a local Other today.
  - `StorageView`: a `FolderFields` view showing the chosen folder (its Finder icon and name, the full path below in secondary text) and `Button("Choose…")` opening an `NSOpenPanel` (`canChooseDirectories = true`, `canChooseFiles = false`, `allowsMultipleSelection = false`, `canCreateDirectories = true`, prompt "Choose", message "Choose where the backups go: an empty folder, or one that holds a restic repository.") through `presentForKeyWindow()`. Other's note becomes "Any location restic understands, such as sftp:nas:/restic."

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func aLocalFolderIsTheFolderKind() {
    let form = StorageForm(repository: .raw(repository: "/Volumes/Backup/restic", environmentNames: []))
    #expect(form.kind == .folder)
    #expect(form.folderPath == "/Volumes/Backup/restic")
    #expect(form.repositoryValue == .raw(repository: "/Volumes/Backup/restic", environmentNames: []))
}
@Test func aRemoteRawLocationStaysOther() {
    #expect(StorageForm(repository: .raw(repository: "sftp:nas:/restic", environmentNames: [])).kind == .other)
}
@Test func aFolderMustBeChosen() {
    var form = StorageForm(repository: nil)   // use the suite's way of making an empty form
    form.choose(.folder)
    #expect(form.repositoryProblem == "Choose a folder or drive for the backups.")
}
@Test func kindsAreInOrder() {
    #expect(StorageForm.Kind.allCases == [.b2, .s3, .folder, .other])
}
```
- [ ] **Step 2: Run to see them fail**: `--filter StorageFormTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify** the filter passes; `scripts/ci.sh` green.
- [ ] **Step 5: README** (setup's storage step). **Commit** `git commit -m "Setup: a folder or drive on this Mac, chosen with a picker"`

### Task 9: Leftovers

**Files:**
- Modify: `RestoreyCore/Sources/RestoreyCore/App/MenuPresentation.swift` (`longWait` title), `RestoreyCore/Sources/RestoreyCore/App/PlanEdit.swift` (or a new `SaveBarVisibility` beside it), `App/Settings/PlansPane.swift` (`PlanDetail`), `App/MenuBuilder.swift` (diagnostics lines; progress inset comment), `App/Settings/NetworkPane.swift`, `App/Settings/PlanRetentionTab.swift`, `README.md`
- Test: `RestoreyCore/Tests/RestoreyCoreTests/App/MenuPresentationTests.swift`, `PlanEditTests.swift`

**Interfaces:**
- Produces:
  - `func showsSaveBar(pageHasFields: Bool, isDirty: Bool, saving: Bool) -> Bool` (true when `pageHasFields || isDirty || saving`). `PlanDetail` passes `pageHasFields: tab != .overview && tab != .history`.
  - `longWait` banner title: "No answer for 30 minutes". The detail keeps the full sentence.
  - Help buttons: SwiftUI `HelpLink(destination:)` at the top trailing corner of Settings ▸ Network (to `https://github.com/jaydenk/restorey#network`) and the plan's Retention tab (to `https://github.com/jaydenk/restorey#retention`). README gains `#### Network` and `#### Retention` headings over the existing run-in paragraphs, so those anchors exist.
  - Diagnostics lines: `MenuBuilder` draws a `.line` item's title as an attributed string in `NSColor.secondaryLabelColor` at the menu font, so it reads clearly while still not choosable.
  - Progress inset: no change to the value. The comment on `ProgressRowView.inset` records the spec's call: no NSMenu metric exists, it matches macOS 27, and it is checked in the live look.

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func theSaveBarHidesOnPagesWithoutFieldsUnlessThereIsSomethingToSave() {
    #expect(showsSaveBar(pageHasFields: true, isDirty: false, saving: false))
    #expect(!showsSaveBar(pageHasFields: false, isDirty: false, saving: false))
    #expect(showsSaveBar(pageHasFields: false, isDirty: true, saving: false))
    #expect(showsSaveBar(pageHasFields: false, isDirty: false, saving: true))
}
@Test func theLongWaitBannerIsShort() {
    // the suite's existing long-wait setup
    #expect(banner.title == "No answer for 30 minutes")
    #expect(banner.title.count <= 32)
}
```
Update the existing long-wait expectation in `MenuPresentationTests`.
- [ ] **Step 2: Run to see them fail**: `--filter "MenuPresentationTests|PlanEditTests"` → FAIL.
- [ ] **Step 3: Implement** all of the above.
- [ ] **Step 4: Verify** the filter passes; full `swift test --package-path RestoreyCore`; `scripts/ci.sh` green.
- [ ] **Step 5: Commit** `git commit -m "Polish leftovers: Save bar only where it applies, a short long-wait banner, help buttons, readable diagnostics"`

### Task 10: Install and the owner's live look

**Files:** `docs/build-records/2026-11-23-visual-polish/live-check.md` (create), plus whatever the look turns up.

- [ ] **Step 1:** Install a Dev build: `BUILD_NUMBER=<next> scripts/install-dev.sh` (only with the owner's go-ahead). Confirm the agent restarted from `~/Library/Logs/Restorey-Dev/agent.log`.
- [ ] **Step 2:** Guide the owner through:
  - the menu bar's Open Restorey and Settings…, and ⌘,;
  - reopen from the Dock, with the menu bar item shown and hidden;
  - the main window's Plans and History;
  - Settings ▸ General, Notifications and Network: a change applies at once, a refused value shows its sentence;
  - the + and − on each list;
  - the folder picker in a new plan's setup (cancel before saving);
  - Backup started and finished turned on for one Back Up Now, then back off;
  - the tab row at the main window's minimum width;
  - the help buttons;
  - the diagnostics lines with Option held.
- [ ] **Step 3:** Fix what the look turns up (the tab-row overhang, if seen, by measuring the grouped form's inset into `PlansPane.minimumWidth`), each with a test where the logic is in RestoreyCore.
- [ ] **Step 4:** Record the results, then commit `git commit -m "Visual polish: live check"`
