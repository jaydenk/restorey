import Foundation
import Testing
@testable import RestoreyCore

/// Settings → Network (UI design §6.3, product spec §5.5): the Mac-wide rules as an edit with Save and Revert, the
/// Wi-Fi list's additions, and when adding a name asks the agent for Location permission.
struct NetworkEditTests {
    private static let saved = NetworkSettings(uploadLimit: .rate(kiB: 5120, unit: .megabytes), skipOnConstrainedNetwork: true, skippedWiFiNames: ["Cafe"])

    // MARK: Changes

    @Test func aFreshEditShowsTheSavedSettingsAndIsUnchanged() {
        let edit = NetworkEdit(settings: Self.saved)
        #expect(edit.fields.limitAmount == "5")
        #expect(edit.fields.skipOnConstrainedNetwork)
        #expect(edit.fields.wiFiNames == ["Cafe"])
        #expect(!edit.isDirty)
        #expect(edit.problem == nil)
        #expect(edit.request() == .success(Self.saved))
    }

    @Test func noLimitIsTheNoneChoiceWithAnEmptyAmount() {
        let fields = NetworkEdit(settings: .defaults).fields
        #expect(fields.limitKind == .none)
        #expect(fields.limitAmount == "")
        #expect(!fields.windowEnabled)
        // The window row's defaults: weekdays, 8:00 am to 6:00 pm.
        #expect(fields.windowDays == .weekdays)
        #expect(fields.windowStart == 480)
        #expect(fields.windowEnd == 1080)
    }

    @Test func eachFieldIsSavedAsTyped() {
        var edit = NetworkEdit(settings: Self.saved)
        edit.fields.limitAmount = " 1.5 "
        edit.fields.skipOnConstrainedNetwork = false
        let added = edit.add(name: "  Phone hotspot ")
        #expect(added)
        #expect(edit.isDirty)
        #expect(edit.request() == .success(NetworkSettings(
            uploadLimit: .rate(kiB: 1536, unit: .megabytes), skipOnConstrainedNetwork: false, skippedWiFiNames: ["Cafe", "Phone hotspot"])))
    }

    @Test func choosingNoneSavesNoLimitAndNoWindow() throws {
        var windowed = Self.saved
        windowed.limitWindow = LimitWindow(days: .weekdays, startMinute: 480, endMinute: 1080)
        var edit = NetworkEdit(settings: windowed)
        edit.setLimitKind(.none)
        let settings = try edit.request().get()
        #expect(settings.uploadLimit == .none)
        #expect(settings.limitWindow == nil)
    }

    /// A limit the field can only show rounded (3 KiB/s is "0"), left alone, keeps the agent's exact value.
    @Test func anUntouchedLimitKeepsTheSavedValueExactly() throws {
        let odd = NetworkSettings(uploadLimit: .rate(kiB: 3, unit: .megabytes), skipOnConstrainedNetwork: true, skippedWiFiNames: [])
        var edit = NetworkEdit(settings: odd)
        edit.fields.skipOnConstrainedNetwork = false
        #expect(try edit.request().get().uploadLimit == .rate(kiB: 3, unit: .megabytes))
    }

    @Test func aCleanEditCommitsNothing() {
        #expect(NetworkEdit(settings: .defaults).commit() == .nothing)
    }

    @Test func aCommitWithAProblemSendsNothing() {
        var edit = NetworkEdit(settings: .defaults)
        edit.setLimitKind(.percent)
        edit.fields.windowEnabled = true
        edit.fields.windowStart = 10 * 60
        edit.fields.windowEnd = 10 * 60
        #expect(edit.commit() == .problem("The limit’s start and end times can’t be the same."))
    }

    @Test func aCommitOfAnInvalidLimitSendsNothing() {
        var edit = NetworkEdit(settings: .defaults)
        edit.setLimitKind(.megabytes)
        edit.fields.limitAmount = "abc"
        guard case .problem = edit.commit() else { Issue.record("expected a problem"); return }
    }

    @Test func aValidChangeIsSentWhole() {
        var edit = NetworkEdit(settings: Self.saved)
        edit.fields.skipOnConstrainedNetwork.toggle()
        guard case .send(let settings) = edit.commit() else { Issue.record("expected send"); return }
        var expected = Self.saved
        expected.skipOnConstrainedNetwork.toggle()
        #expect(settings == expected)
    }

    @Test func aRefusedToggleReadsAsSavedAgain() {
        var edit = NetworkEdit(settings: .defaults)
        edit.fields.skipOnConstrainedNetwork.toggle()
        edit.add(name: "Cafe")
        edit.didRefuse()
        #expect(edit.saved == .defaults)
        #expect(edit.fields == NetworkEdit.Fields(settings: .defaults))
        #expect(!edit.isDirty)
    }

    @Test func aRefusedTypedAmountKeepsWhatWasTyped() {
        var edit = NetworkEdit(settings: Self.saved)
        edit.fields.limitAmount = "99999999999"
        edit.fields.windowEnabled = true
        edit.fields.windowStart = 7 * 60
        edit.didRefuse()
        #expect(edit.saved == Self.saved)
        #expect(edit.fields.limitAmount == "99999999999")
        #expect(edit.fields.windowStart == 7 * 60)
        #expect(edit.isDirty)
    }

    @Test func aRefusedKindChangeTakesItsAmountBackWithIt() {
        var edit = NetworkEdit(settings: Self.saved)
        edit.setLimitKind(.percent)
        edit.didRefuse()
        #expect(edit.fields.limitKind == .megabytes)
        #expect(edit.fields.limitAmount == NetworkEdit.Fields(settings: Self.saved).limitAmount)
        #expect(!edit.isDirty)
    }

    @Test func anEditMadeWhileASaveWasInFlightSurvivesIt() {
        var edit = NetworkEdit(settings: .defaults)
        edit.fields.skipOnConstrainedNetwork = false
        let sent = edit.fields
        var agent = NetworkSettings.defaults
        agent.skipOnConstrainedNetwork = false
        edit.fields.wiFiNames = ["Cafe"]            // typed while the save was out
        edit.didSave(agent, sent: sent)
        #expect(edit.saved == agent)
        #expect(edit.fields.skipOnConstrainedNetwork == false)
        #expect(edit.fields.wiFiNames == ["Cafe"])
        guard case .send(let next) = edit.commit() else { Issue.record("expected the next send"); return }
        #expect(next.skippedWiFiNames == ["Cafe"])
        #expect(next.skipOnConstrainedNetwork == false)
    }

    @Test func aGroupTheAgentNormalisedConvergesWithoutStayingDirty() {
        var edit = NetworkEdit(settings: .defaults)
        edit.setLimitKind(.megabytes)
        edit.fields.limitAmount = "05"
        let sent = edit.fields
        edit.didSave(NetworkSettings(uploadLimit: .rate(kiB: 5 * 1024, unit: .megabytes), skipOnConstrainedNetwork: true, skippedWiFiNames: []), sent: sent)
        #expect(edit.fields.limitAmount == "5")
        #expect(!edit.isDirty)
        #expect(edit.commit() == .nothing)
    }

    @Test func aSaveStartsAgainFromWhatTheAgentSaved() {
        var edit = NetworkEdit(settings: Self.saved)
        _ = edit.add(name: "Home ")
        edit.didSave(NetworkSettings(uploadLimit: .rate(kiB: 5120, unit: .megabytes), skipOnConstrainedNetwork: true, skippedWiFiNames: ["Cafe", "Home"]))
        #expect(!edit.isDirty)
        #expect(edit.fields.wiFiNames == ["Cafe", "Home"])
    }

    /// The agent's copy changed (a save from another window): an untouched form follows it; edits are kept.
    @Test func rebaseFollowsTheAgentOnlyWhileUntouched() throws {
        let newer = NetworkSettings(uploadLimit: .none, skipOnConstrainedNetwork: false, skippedWiFiNames: [])
        var untouched = NetworkEdit(settings: Self.saved)
        untouched.rebase(on: newer)
        #expect(untouched.fields == NetworkEdit.Fields(settings: newer))
        #expect(!untouched.isDirty)

        var edited = NetworkEdit(settings: Self.saved)
        edited.fields.limitAmount = "2"
        edited.rebase(on: newer)
        #expect(edited.fields.limitAmount == "2")
        #expect(edited.saved == newer)
        // What the form shows follows the agent too, except the field being edited.
        #expect(!edited.fields.skipOnConstrainedNetwork)
        #expect(edited.fields.wiFiNames == [])
        // Fields the user didn't touch keep the agent's newer values.
        #expect(try edited.request().get() == NetworkSettings(
            uploadLimit: .rate(kiB: 2048, unit: .megabytes), skipOnConstrainedNetwork: false, skippedWiFiNames: []))
    }

    // MARK: Unit, percentage and window (upload-limit design: Settings → Network)

    private static let en_AU = Locale(identifier: "en_AU")
    private static let adelaide: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Adelaide")!
        return calendar
    }()

    /// A wall-clock time in Adelaide (UTC+10:30 in January, daylight saving).
    private static func adelaideDate(_ y: Int, _ m: Int, _ d: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        adelaide.date(from: DateComponents(year: y, month: m, day: d, hour: hour, minute: minute))!
    }

    @Test func kilobytesAreReadAsKiB() throws {
        var edit = NetworkEdit(settings: .defaults)
        edit.setLimitKind(.kilobytes)
        edit.fields.limitAmount = "512"
        #expect(try edit.request().get().uploadLimit == .rate(kiB: 512, unit: .kilobytes))
        edit.setLimitKind(.megabytes)
        #expect(edit.fields.limitAmount == "0.5")
        #expect(try edit.request().get().uploadLimit == .rate(kiB: 512, unit: .megabytes))
    }

    @Test func switchingUnitConvertsTheAmount() {
        var edit = NetworkEdit(settings: Self.saved)  // 5 MB/s
        edit.setLimitKind(.kilobytes)
        #expect(edit.fields.limitAmount == "5120")
        edit.setLimitKind(.megabytes)
        #expect(edit.fields.limitAmount == "5")
        // Text that isn't a number is left for the user to fix.
        edit.fields.limitAmount = "fast"
        edit.setLimitKind(.kilobytes)
        #expect(edit.fields.limitAmount == "fast")
    }

    /// A unit switch never changes the stored KiB: the text is only how it reads back.
    @Test(arguments: [100, 300, 1000, 3])
    func switchingUnitsBackAndForthKeepsTheStoredKiB(kiB: Int) throws {
        let saved = NetworkSettings(uploadLimit: .rate(kiB: kiB, unit: .kilobytes), skipOnConstrainedNetwork: true, skippedWiFiNames: [])
        var edit = NetworkEdit(settings: saved)
        let started = edit.fields.limitAmount
        edit.setLimitKind(.megabytes)
        #expect(edit.problem == nil)
        #expect(try edit.request().get().uploadLimit == .rate(kiB: kiB, unit: .megabytes))
        edit.setLimitKind(.kilobytes)
        #expect(edit.fields.limitAmount == started)
        #expect(!edit.isDirty)
        #expect(try edit.request().get() == saved)
    }

    /// A switch that can't convert (empty or invalid text) mustn't leave the old exact value to apply to the new unit.
    @Test(arguments: ["", "fast"])
    func retypingTheOldDigitsAfterAnUnconvertibleSwitchIsInTheNewUnit(blank: String) throws {
        var edit = NetworkEdit(settings: NetworkSettings(
            uploadLimit: .rate(kiB: 100, unit: .kilobytes), skipOnConstrainedNetwork: true, skippedWiFiNames: []))
        edit.fields.limitAmount = blank
        edit.setLimitKind(.megabytes)
        edit.fields.limitAmount = "100"
        #expect(try edit.request().get().uploadLimit == .rate(kiB: 102_400, unit: .megabytes))
    }

    @Test func typingAfterASwitchIsReadAsTyped() throws {
        var edit = NetworkEdit(settings: NetworkSettings(
            uploadLimit: .rate(kiB: 1000, unit: .kilobytes), skipOnConstrainedNetwork: true, skippedWiFiNames: []))
        edit.setLimitKind(.megabytes)  // shows 0.98
        edit.fields.limitAmount = "0.99"  // typed: now it is what it says
        #expect(try edit.request().get().uploadLimit == .rate(kiB: 1014, unit: .megabytes))
    }

    @Test func choosingAKindFromNoneStartsFromASensibleAmount() {
        var edit = NetworkEdit(settings: .defaults)
        edit.setLimitKind(.percent)
        #expect(edit.fields.limitAmount == "50")
        edit.setLimitKind(.megabytes)
        #expect(edit.fields.limitAmount == "")
        edit.setLimitKind(.none)
        #expect(edit.fields.limitAmount == "")
    }

    @Test func aRateNeedsAnAmount() {
        var edit = NetworkEdit(settings: .defaults)
        edit.setLimitKind(.megabytes)
        #expect(edit.problem == "Enter the limit as a number of MB/s, such as 5 or 1.5.")
        edit.setLimitKind(.kilobytes)
        #expect(edit.problem == "Enter the limit as a number of KB/s, such as 512.")
    }

    @Test func percentRefusesOutOfRange() {
        for text in ["0", "101", "50.5", "", "-5", "fifty", "1e1"] {
            #expect(FormValidation.percent(text) == .failure("Enter a percentage from 1 to 100."), "\(text)")
        }
        #expect(FormValidation.percent(" 50 ") == .success(50))
        #expect(FormValidation.percent("1") == .success(1))
        #expect(FormValidation.percent("100") == .success(100))
        var edit = NetworkEdit(settings: .defaults)
        edit.setLimitKind(.percent)
        edit.fields.limitAmount = "101"
        #expect(edit.uploadLimitProblem == "Enter a percentage from 1 to 100.")
        #expect(throws: FormValidation.Problem.self) { try edit.request().get() }
    }

    @Test func aWindowWithEqualStartAndEndIsAProblem() {
        var edit = NetworkEdit(settings: .defaults)
        edit.setLimitKind(.percent)
        edit.fields.windowEnabled = true
        edit.fields.windowStart = 600
        edit.fields.windowEnd = 600
        #expect(edit.problem == "The limit’s start and end times can’t be the same.")
        // A window that is switched off, or a limit that is none, isn't saved, so it can't be a problem.
        edit.fields.windowEnabled = false
        #expect(edit.problem == nil)
    }

    @Test func savingBuildsTheSettings() throws {
        var edit = NetworkEdit(settings: .defaults)
        edit.setLimitKind(.percent)
        edit.fields.limitAmount = "50"
        edit.fields.windowEnabled = true
        #expect(edit.isDirty)
        var expected = NetworkSettings.defaults
        expected.uploadLimit = .percent(50)
        expected.limitWindow = LimitWindow(days: .weekdays, startMinute: 480, endMinute: 1080)
        #expect(try edit.request().get() == expected)

        // The window switched off: a limit all the time.
        edit.fields.windowEnabled = false
        expected.limitWindow = nil
        #expect(try edit.request().get() == expected)

        // Other days and times.
        edit.fields.windowEnabled = true
        edit.fields.windowDays = .weekends
        edit.fields.windowStart = 22 * 60
        edit.fields.windowEnd = 6 * 60
        expected.limitWindow = LimitWindow(days: .weekends, startMinute: 1320, endMinute: 360)
        #expect(try edit.request().get() == expected)
    }

    @Test func aSavedPercentAndWindowAreShownBack() {
        var settings = NetworkSettings.defaults
        settings.uploadLimit = .percent(30)
        settings.limitWindow = LimitWindow(days: .everyDay, startMinute: 60, endMinute: 120)
        let edit = NetworkEdit(settings: settings)
        #expect(edit.fields.limitKind == .percent)
        #expect(edit.fields.limitAmount == "30")
        #expect(edit.fields.windowEnabled)
        #expect(edit.fields.windowDays == .everyDay)
        #expect(edit.fields.windowStart == 60)
        #expect(edit.fields.windowEnd == 120)
        #expect(!edit.isDirty)
        #expect(edit.request() == .success(settings))
    }

    @Test func rebaseFollowsTheLimitAndTheWindowSeparately() throws {
        var newer = Self.saved
        newer.uploadLimit = .percent(40)
        newer.limitWindow = LimitWindow(days: .weekends, startMinute: 0, endMinute: 600)
        var edit = NetworkEdit(settings: Self.saved)
        edit.fields.limitAmount = "9"  // the limit is being edited; the window is untouched
        edit.rebase(on: newer)
        #expect(edit.fields.limitKind == .megabytes)
        #expect(edit.fields.limitAmount == "9")
        #expect(edit.fields.windowEnabled)
        #expect(edit.fields.windowDays == .weekends)
        #expect(edit.fields.windowEnd == 600)
    }

    // MARK: The Now line

    /// 335,544,320 bit/s is exactly 40 MB/s (41,943,040 bytes/s), so 50% is 20 MB/s.
    private static func measured(at date: Date) -> UploadSpeedStatus {
        UploadSpeedStatus(
            network: .wiFi(name: "Kerr Home"),
            record: UploadSpeedRecord(latest: UploadSpeedMeasurement(bitsPerSecond: 335_544_320, measuredAt: date)),
            testing: false)
    }

    private static func percentEdit() -> NetworkEdit {
        var settings = NetworkSettings.defaults
        settings.uploadLimit = .percent(50)
        settings.limitWindow = LimitWindow(days: .weekdays, startMinute: 480, endMinute: 1080)
        return NetworkEdit(settings: settings)
    }

    @Test func nowLineForEachReason() {
        let edit = Self.percentEdit()
        let friday10am = Self.adelaideDate(2027, 1, 15, 10)  // a Friday
        let status = Self.measured(at: friday10am)
        func now(_ edit: NetworkEdit, _ status: UploadSpeedStatus?, at date: Date) -> String {
            edit.nowLine(status: status, at: date, calendar: Self.adelaide, locale: Self.en_AU)
        }
        #expect(now(edit, status, at: friday10am) == "Now: 20 MB/s, until 6:00 pm")
        // After Friday's window the next change is Monday morning.
        #expect(now(edit, status, at: Self.adelaideDate(2027, 1, 15, 19)) == "Now: no limit, from 8:00 am Monday")
        // Before today's window opens: later today, so no day name.
        #expect(now(edit, status, at: Self.adelaideDate(2027, 1, 15, 7)) == "Now: no limit, from 8:00 am")
        // No measurement for this network yet.
        let unmeasured = UploadSpeedStatus(network: .ethernet, record: nil, testing: false)
        #expect(now(edit, unmeasured, at: friday10am) == "Now: no limit until this network is measured")
        #expect(now(edit, nil, at: friday10am) == "Now: no limit until this network is measured")
        // No limit set, a rate with no window, a percentage with no window.
        #expect(now(NetworkEdit(settings: .defaults), status, at: friday10am) == "No limit right now")
        #expect(now(NetworkEdit(settings: Self.saved), status, at: friday10am) == "Now: 5 MB/s")
        // A fixed rate reads in the unit it was set in, as the agent's log says it.
        var inKilobytes = NetworkSettings.defaults
        inKilobytes.uploadLimit = .rate(kiB: 5120, unit: .kilobytes)
        #expect(now(NetworkEdit(settings: inKilobytes), status, at: friday10am) == "Now: 5120 KB/s")
        var allDay = NetworkSettings.defaults
        allDay.uploadLimit = .percent(50)
        #expect(now(NetworkEdit(settings: allDay), status, at: friday10am) == "Now: 20 MB/s")
    }

    @Test func nowLineNamesTheDayWhenTheWindowEndsAnotherDay() {
        var settings = NetworkSettings.defaults
        settings.uploadLimit = .rate(kiB: 512, unit: .kilobytes)
        settings.limitWindow = LimitWindow(days: .everyDay, startMinute: 22 * 60, endMinute: 6 * 60)
        let edit = NetworkEdit(settings: settings)
        let line = edit.nowLine(
            status: nil, at: Self.adelaideDate(2027, 1, 15, 23), calendar: Self.adelaide, locale: Self.en_AU)
        #expect(line == "Now: 512 KB/s, until 6:00 am Saturday")
    }

    /// The line is about what the agent has; an edit not yet applied doesn't change it, and it never mentions saving.
    @Test func nowLineNeverMentionsSaving() {
        let friday10am = Self.adelaideDate(2027, 1, 15, 10)
        let status = Self.measured(at: friday10am)
        func now(_ edit: NetworkEdit) -> String {
            edit.nowLine(status: status, at: friday10am, calendar: Self.adelaide, locale: Self.en_AU)
        }
        var edit = Self.percentEdit()
        #expect(now(edit) == "Now: 20 MB/s, until 6:00 pm")
        edit.fields.limitAmount = "60"
        #expect(now(edit) == "Now: 20 MB/s, until 6:00 pm")
        edit.fields.windowEnd = 19 * 60
        #expect(now(edit) == "Now: 20 MB/s, until 6:00 pm")
        var none = NetworkEdit(settings: .defaults)
        none.setLimitKind(.megabytes)
        #expect(now(none) == "No limit right now")
    }

    // MARK: The speed line

    /// A huge stored speed (a file edited, or an old bug) neither traps nor shows.
    @Test func speedLineWithAnImplausibleSpeedIsNotMeasuredAndNeverTraps() {
        let edit = NetworkEdit(settings: .defaults)
        let now = Self.adelaideDate(2027, 1, 15, 10)
        for bits in [1e30, 1e14, Double.infinity, Double.nan] {
            let record = UploadSpeedRecord(latest: UploadSpeedMeasurement(bitsPerSecond: bits, measuredAt: now))
            let status = UploadSpeedStatus(network: .ethernet, record: record, testing: false)
            #expect(edit.speedLine(status, now: now, calendar: Self.adelaide, locale: Self.en_AU) == "Not measured on this network yet")
        }
        let huge = UploadSpeedStatus(
            network: .ethernet,
            record: UploadSpeedRecord(latest: UploadSpeedMeasurement(bitsPerSecond: 1e30, measuredAt: now)), testing: false)
        #expect(edit.nowLine(status: huge, at: now, calendar: Self.adelaide, locale: Self.en_AU) == "No limit right now")
    }

    @Test func speedLineAges() {
        let edit = NetworkEdit(settings: .defaults)
        let now = Self.adelaideDate(2027, 1, 15, 10)
        func line(measuredAt: Date) -> String {
            edit.speedLine(Self.measured(at: measuredAt), now: now, calendar: Self.adelaide, locale: Self.en_AU)
        }
        #expect(line(measuredAt: Self.adelaideDate(2027, 1, 15, 6)) == "Upload speed on “Kerr Home”: 40 MB/s, measured today")
        #expect(line(measuredAt: Self.adelaideDate(2027, 1, 14, 23)) == "Upload speed on “Kerr Home”: 40 MB/s, measured yesterday")
        #expect(line(measuredAt: Self.adelaideDate(2027, 1, 3, 9)) == "Upload speed on “Kerr Home”: 40 MB/s, measured 3 Jan 2027")
    }

    @Test func speedLineForTheOtherStates() {
        let edit = NetworkEdit(settings: .defaults)
        let now = Self.adelaideDate(2027, 1, 15, 10)
        func line(_ status: UploadSpeedStatus?) -> String {
            edit.speedLine(status, now: now, calendar: Self.adelaide, locale: Self.en_AU)
        }
        #expect(line(nil) == "Checking…", "no status yet is not the same as no network")
        #expect(line(UploadSpeedStatus(network: nil, record: nil, testing: false)) == "Not connected to a network")
        #expect(line(UploadSpeedStatus(network: .ethernet, record: nil, testing: false)) == "Not measured on this network yet")
        #expect(line(UploadSpeedStatus(network: .ethernet, record: nil, testing: true)) == "Testing upload speed…")
        let failed = UploadSpeedRecord(lastFailure: SpeedTestFailure(at: now, reason: "The speed test timed out"))
        #expect(line(UploadSpeedStatus(network: .ethernet, record: failed, testing: false)) == "The speed test timed out.")
        // A failure newer than the last measurement is what Settings says; an older one isn't.
        let older = UploadSpeedMeasurement(bitsPerSecond: 335_544_320, measuredAt: now.addingTimeInterval(-3600))
        let both = UploadSpeedRecord(latest: older, lastFailure: SpeedTestFailure(at: now, reason: "The speed test timed out"))
        #expect(line(UploadSpeedStatus(network: .ethernet, record: both, testing: false)) == "The speed test timed out.")
        let healed = UploadSpeedRecord(
            latest: UploadSpeedMeasurement(bitsPerSecond: 335_544_320, measuredAt: now),
            lastFailure: SpeedTestFailure(at: now.addingTimeInterval(-3600), reason: "The speed test timed out"))
        #expect(line(UploadSpeedStatus(network: .ethernet, record: healed, testing: false)) == "Upload speed on Ethernet: 40 MB/s, measured today")
        #expect(line(UploadSpeedStatus(network: .wiFiUnknown, record: nil, testing: false)) == "Not measured on this network yet")
    }

    @Test func thePercentNoteEndsWithAFullStopLikeTheOtherFormNotes() {
        #expect(WiFiNameAccess.refused.percentNote
            == "Without Location permission, Restorey can’t tell Wi-Fi networks apart, so they share one measurement.")
        #expect(WiFiNameAccess.allowed.percentNote == nil)
    }

    @Test func speedsShowInMegabytesWithOneDecimalOrKilobytesBelowOne() {
        #expect(UploadLimitText.speedText(kiB: 40960) == "40 MB/s")
        #expect(UploadLimitText.speedText(kiB: 4915) == "4.8 MB/s")
        #expect(UploadLimitText.speedText(kiB: 1024) == "1 MB/s")
        #expect(UploadLimitText.speedText(kiB: 1023) == "1023 KB/s")
        #expect(UploadLimitText.speedText(kiB: 300) == "300 KB/s")
    }

    // MARK: Time and day text (the Mac's locale in the app; the agent's log pins en_AU)

    @Test func timeAndDayText() {
        let window = LimitWindow(days: .weekdays, startMinute: 480, endMinute: 1080)
        #expect(UploadLimitText.windowText(window, locale: Self.en_AU) == "8:00 am–6:00 pm weekdays")
        let midnight = LimitWindow(days: .weekends, startMinute: 0, endMinute: 750)
        #expect(UploadLimitText.windowText(midnight, locale: Self.en_AU) == "12:00 am–12:30 pm weekends")
        #expect(UploadLimitText.windowText(LimitWindow(days: .everyDay, startMinute: 60, endMinute: 120), locale: Self.en_AU)
            == "1:00 am–2:00 am every day")
        // A 24-hour locale shows 24-hour times.
        #expect(UploadLimitText.windowText(window, locale: Locale(identifier: "de_DE")) == "08:00–18:00 weekdays")
    }

    @Test func aLimitInKilobytesOrMegabytesShowsBackInItsUnit() {
        #expect(UploadLimitText.rateText(kiB: 500, unit: .kilobytes) == "500 KB/s")
        #expect(UploadLimitText.rateText(kiB: 4885, unit: .megabytes) == "4.77 MB/s")
    }

    // MARK: Problems

    @Test func aBadLimitIsTheProblemAndBlocksTheSave() {
        var edit = NetworkEdit(settings: .defaults)
        edit.setLimitKind(.megabytes)
        edit.fields.limitAmount = "fast"
        #expect(edit.uploadLimitProblem == "Enter the limit as a number of MB/s, such as 5 or 1.5.")
        #expect(edit.problem == edit.uploadLimitProblem)
        #expect(throws: FormValidation.Problem.self) { try edit.request().get() }
        edit.fields.limitAmount = "0"
        #expect(edit.problem == "The upload limit must be more than 0 MB/s. Choose None for no limit.")
    }

    /// The agent refuses these too (`NetworkSettings.validationErrors`); the form says so first, with a full stop.
    @Test func aListTheAgentWouldRefuseIsAProblem() {
        var edit = NetworkEdit(settings: .defaults)
        edit.fields.wiFiNames = ["Cafe", "cafe "]
        #expect(edit.problem == "The Wi-Fi network “cafe” is in the list more than once.")
    }

    @Test func aNameToAddMustBeNewAndOnOneLine() {
        var edit = NetworkEdit(settings: Self.saved)
        #expect(edit.newNameProblem("   ") == "Enter the Wi-Fi network’s name.")
        #expect(edit.newNameProblem(" CAFE") == "“CAFE” is already in the list.")
        #expect(edit.newNameProblem("Two\nlines") == "A Wi-Fi network’s name is on one line.")
        #expect(edit.newNameProblem("Home") == nil)
        let added = edit.add(name: "cafe")
        #expect(!added)
        #expect(edit.fields.wiFiNames == ["Cafe"])
        #expect(!edit.isDirty)
    }

    /// Wi-Fi names longer than 32 bytes don't exist (IEEE 802.11 SSIDs are at most 32 octets).
    @Test func aNameLongerThanAnSSIDIsRefused() {
        let edit = NetworkEdit(settings: .defaults)
        #expect(edit.newNameProblem(String(repeating: "a", count: 32)) == nil)
        #expect(edit.newNameProblem(String(repeating: "a", count: 33))
            == "A Wi-Fi network’s name is at most 32 bytes long.")
        // "é" is two bytes in UTF-8.
        #expect(edit.newNameProblem(String(repeating: "é", count: 17)) != nil)
    }

    @Test func removingANameIsAnEdit() throws {
        var edit = NetworkEdit(settings: Self.saved)
        edit.remove(name: "Cafe")
        #expect(edit.isDirty)
        #expect(try edit.request().get().skippedWiFiNames == [])
    }

    // MARK: Location permission (UI design §6.3: asked only when the user first adds a network)

    private static func hello(authorised: Bool?, servicesEnabled: Bool?) -> HelloReply {
        HelloReply(
            agentVersion: "0.1.0", agentBuild: "1", executablePath: "/x", draining: false, notificationsAuthorised: true,
            locationAuthorised: authorised, locationServicesEnabled: servicesEnabled)
    }

    @Test func accessComesFromTheAgentsHello() {
        #expect(WiFiNameAccess(hello: nil) == .checking)
        #expect(WiFiNameAccess(hello: Self.hello(authorised: nil, servicesEnabled: true)) == .notAsked)
        #expect(WiFiNameAccess(hello: Self.hello(authorised: true, servicesEnabled: true)) == .allowed)
        #expect(WiFiNameAccess(hello: Self.hello(authorised: false, servicesEnabled: true)) == .refused)
        // An agent older than this field says nothing about Location Services: its authorisation decides.
        #expect(WiFiNameAccess(hello: Self.hello(authorised: true, servicesEnabled: nil)) == .allowed)
    }

    /// Location Services switched off for the whole Mac wins over everything: no app can see the Wi-Fi name then,
    /// and macOS may still report the agent as never asked.
    @Test func locationServicesOffForTheMacWins() {
        for authorised in [true, false, nil] as [Bool?] {
            #expect(WiFiNameAccess(hello: Self.hello(authorised: authorised, servicesEnabled: false)) == .servicesOff)
        }
    }

    @Test func accessAfterTheAgentsAnswer() {
        #expect(WiFiNameAccess(reply: LocationPermissionReply(authorised: true, status: "authorisedAlways")) == .allowed)
        #expect(WiFiNameAccess(reply: LocationPermissionReply(authorised: false, status: "denied")) == .refused)
        // Restricted by a profile or Screen Time: the user can't change it, so it isn't "refused" (fix round 1, M3).
        #expect(WiFiNameAccess(reply: LocationPermissionReply(authorised: false, status: "restricted")) == .restricted)
        #expect(WiFiNameAccess(reply: LocationPermissionReply(
            authorised: false, status: "restricted", servicesEnabled: true)) == .restricted)
        #expect(WiFiNameAccess(reply: LocationPermissionReply(authorised: false, status: "notDetermined")) == .notAsked)
        #expect(WiFiNameAccess(reply: LocationPermissionReply(
            authorised: false, status: "notDetermined", servicesEnabled: false)) == .servicesOff)
    }

    /// The "ask now?" decision: only adding a name while the agent has never been asked asks; a decided answer is
    /// never asked again (macOS wouldn't show the prompt), and with Location Services off nothing asks at all.
    @Test func addingANameAsksOnlyWhenNeverAsked() {
        #expect(WiFiNameAccess.notAsked.addStep == .askFirst)
        // Before the first hello the agent decides: it answers at once if the user already has.
        #expect(WiFiNameAccess.checking.addStep == .askFirst)
        #expect(WiFiNameAccess.allowed.addStep == .add)
        #expect(WiFiNameAccess.refused.addStep == .blocked)
        #expect(WiFiNameAccess.servicesOff.addStep == .blocked)
        #expect(WiFiNameAccess.restricted.addStep == .blocked)
    }

    @Test func whatTheListSaysForEachAccess() {
        #expect(WiFiNameAccess.allowed.note(listed: 1) == nil)
        #expect(WiFiNameAccess.checking.note(listed: 0) == nil)
        #expect(WiFiNameAccess.notAsked.note(listed: 0)
            == "Adding a network asks for Location permission: macOS shows the Wi-Fi network’s name only to apps "
            + "allowed to use Location.")
        #expect(WiFiNameAccess.refused.note(listed: 0) == "Restorey needs Location permission to see Wi-Fi names.")
        #expect(WiFiNameAccess.refused.note(listed: 2)
            == "Restorey needs Location permission to see Wi-Fi names. Until then, backups aren’t skipped on these networks.")
        #expect(WiFiNameAccess.servicesOff.note(listed: 0)
            == "Location Services is off for this Mac, so Restorey can’t see Wi-Fi names. Turn it on in System Settings "
            + "→ Privacy & Security → Location Services.")
        #expect(WiFiNameAccess.refused.opensSystemSettings)
        #expect(WiFiNameAccess.servicesOff.opensSystemSettings)
        #expect(!WiFiNameAccess.notAsked.opensSystemSettings)
        #expect(!WiFiNameAccess.restricted.opensSystemSettings, "System Settings can’t change a restriction")
        #expect(WiFiNameAccess.restricted.note(listed: 0)
            == "Location is restricted on this Mac, by a configuration profile or Screen Time, so Restorey can’t see "
            + "Wi-Fi names. Whoever manages this Mac can lift it.")
        #expect(WiFiNameAccess.restricted.note(listed: 1)!.hasSuffix(" Until then, backups aren’t skipped on these networks."))
        #expect(!WiFiNameAccess.allowed.opensSystemSettings)
        #expect(WiFiNameAccess.unanswered
            == "There was no answer about Location permission, so the network wasn’t added. Add it again to be asked again.")
    }
}
