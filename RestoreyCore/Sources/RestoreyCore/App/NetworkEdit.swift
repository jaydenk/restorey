import Foundation

/// The kinds of Mac-wide limit the picker offers: None, KB/s, MB/s, or a percentage of the measured upload speed.
public enum LimitKind: String, CaseIterable, Sendable {
    case none, kilobytes, megabytes, percent

    /// The picker's title.
    public var title: String {
        switch self {
        case .none: "None"
        case .kilobytes: "KB/s"
        case .megabytes: "MB/s"
        case .percent: "% of upload speed"
        }
    }

    /// The unit of a fixed rate; nil for none and a percentage.
    public var unit: UploadLimitUnit? {
        switch self {
        case .kilobytes: .kilobytes
        case .megabytes: .megabytes
        case .none, .percent: nil
        }
    }

    public init(unit: UploadLimitUnit) {
        self = unit == .kilobytes ? .kilobytes : .megabytes
    }
}

/// Settings → Network (UI design §6.3, product spec §5.5, Ruling P2-6, and the upload-limit design): the Mac-wide
/// rules being edited, with Save and Revert as a plan's tabs have them. Pure; the app's `NetworkEditModel` does the
/// calls.
///
/// The fields hold exactly what the controls show: the limit is parsed in `request()`, never as the user types. A
/// field still equal to its start is one the user hasn't changed, and a save leaves the agent's value for it alone.
public struct NetworkEdit: Sendable, Equatable {
    public struct Fields: Sendable, Equatable {
        /// What the picker shows. The amount is in this kind's unit (KB/s, MB/s, or a percentage).
        public var limitKind: LimitKind
        /// The amount as typed; empty for `.none`.
        public var limitAmount: String
        /// The exact KiB/s the amount stands for after a KB/s / MB/s switch (`FormValidation.ExactLimit`).
        public var limitExact: FormValidation.ExactLimit?
        /// "Only limit during" is ticked. The window's own fields below are shown whenever the kind isn't none, and
        /// start as weekdays 8:00 am to 6:00 pm.
        public var windowEnabled: Bool
        public var windowDays: LimitDays
        /// Minutes after midnight.
        public var windowStart: Int
        public var windowEnd: Int
        public var skipOnConstrainedNetwork: Bool
        /// The Wi-Fi networks to skip, as the list shows them (each trimmed when it was added).
        public var wiFiNames: [String]

        public static let defaultWindow = LimitWindow(days: .weekdays, startMinute: 8 * 60, endMinute: 18 * 60)

        public init(settings: NetworkSettings) {
            switch settings.uploadLimit {
            case .none:
                limitKind = .none
                limitAmount = ""
                limitExact = nil
            case .rate(let kiB, let unit):
                limitKind = LimitKind(unit: unit)
                limitAmount = FormValidation.uploadLimitText(kiB: kiB, unit: unit)
                limitExact = .init(text: limitAmount, kiB: kiB)
            case .percent(let percent):
                limitKind = .percent
                limitAmount = String(percent)
                limitExact = nil
            }
            let window = settings.limitWindow
            windowEnabled = window != nil
            windowDays = (window ?? Self.defaultWindow).days
            windowStart = (window ?? Self.defaultWindow).startMinute
            windowEnd = (window ?? Self.defaultWindow).endMinute
            skipOnConstrainedNetwork = settings.skipOnConstrainedNetwork
            wiFiNames = settings.skippedWiFiNames
        }

        fileprivate var limit: LimitFields { LimitFields(kind: limitKind, amount: limitAmount) }
        fileprivate var window: WindowFields {
            WindowFields(enabled: windowEnabled, days: windowDays, start: windowStart, end: windowEnd)
        }
    }

    /// The limit's two fields, which are saved (and followed from the agent) together.
    fileprivate struct LimitFields: Equatable {
        var kind: LimitKind
        var amount: String
    }

    fileprivate struct WindowFields: Equatable {
        var enabled: Bool
        var days: LimitDays
        var start: Int
        var end: Int
    }

    /// The settings as the agent last reported them: what a save is built on.
    public private(set) var saved: NetworkSettings
    public var fields: Fields
    private var started: Fields

    public init(settings: NetworkSettings) {
        saved = settings
        fields = Fields(settings: settings)
        started = fields
    }

    public var isDirty: Bool { fields != started }

    // MARK: The limit

    /// Chooses what kind of limit this is. Between KB/s and MB/s the typed amount converts (5 MB/s becomes
    /// 5120 KB/s) rather than being read in the new unit. Choosing a percentage from anything else starts at 50, and
    /// a rate from anything else starts empty.
    public mutating func setLimitKind(_ kind: LimitKind) {
        let old = fields.limitKind
        guard kind != old else { return }
        switch (old.unit, kind.unit) {
        case (let from?, let to?):
            let converted = FormValidation.convertedLimit(fields.limitAmount, exact: fields.limitExact, from: from, to: to)
            fields.limitAmount = converted.text
            fields.limitExact = converted.exact
        default:
            fields.limitAmount = kind == .percent ? "50" : ""
            fields.limitExact = nil
        }
        fields.limitKind = kind
    }

    /// Whether the limit is something the user has changed. Only then is it checked and saved: one the field can
    /// only show rounded (3 KiB/s shows as "0") is kept as saved, not refused.
    private var limitChanged: Bool { fields.limit != started.limit }
    private var windowChanged: Bool { fields.window != started.window }

    /// The limit as typed: what a save stores, or why it can't.
    private func parsedLimit() -> Result<MacUploadLimit, FormValidation.Problem> {
        switch fields.limitKind {
        case .none:
            return .success(.none)
        case .kilobytes, .megabytes:
            let unit = fields.limitKind.unit ?? .megabytes
            switch FormValidation.limitKiB(fields.limitAmount, unit: unit, exact: fields.limitExact, emptyMeansNone: false) {
            case .failure(let problem): return .failure(problem)
            case .success(let kiB?): return .success(.rate(kiB: kiB, unit: unit))
            case .success(nil):
                // Empty is no limit for a plan; here that is the None choice.
                return .failure(FormValidation.limitNotANumber(unit))
            }
        case .percent:
            return FormValidation.percent(fields.limitAmount).map { .percent($0) }
        }
    }

    // MARK: The Wi-Fi list

    /// IEEE 802.11 limits a network name (SSID) to 32 bytes.
    public static let maximumNameBytes = 32

    /// Why `typed` can't be added, as a sentence; nil when it can. Compared as the agent matches names: trimmed
    /// and ignoring case (`NetworkSettings.isSkipped`).
    public func newNameProblem(_ typed: String) -> String? {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Enter the Wi-Fi network’s name." }
        if name.contains(where: \.isNewline) { return "A Wi-Fi network’s name is on one line." }
        if name.utf8.count > Self.maximumNameBytes {
            return "A Wi-Fi network’s name is at most \(Self.maximumNameBytes) bytes long."
        }
        let listed = NetworkSettings(uploadLimit: .none, skipOnConstrainedNetwork: false, skippedWiFiNames: fields.wiFiNames)
        if listed.isSkipped(wiFiName: name) { return "“\(name)” is already in the list." }
        return nil
    }

    /// Adds `typed`, trimmed, to the end of the list. False (and nothing added) when it has a problem.
    @discardableResult
    public mutating func add(name typed: String) -> Bool {
        guard newNameProblem(typed) == nil else { return false }
        fields.wiFiNames.append(typed.trimmingCharacters(in: .whitespacesAndNewlines))
        return true
    }

    public mutating func remove(name: String) {
        fields.wiFiNames.removeAll { $0 == name }
    }

    // MARK: Problems (each a sentence ending with a full stop)

    /// Only for a limit the user has changed.
    public var uploadLimitProblem: String? {
        guard limitChanged else { return nil }
        if case .failure(let problem) = parsedLimit() { return problem.message }
        return nil
    }

    /// The window's start and end are the same time, which the agent refuses. Only while the window would be saved.
    public var windowProblem: String? {
        guard fields.limitKind != .none, fields.windowEnabled, fields.windowStart == fields.windowEnd else { return nil }
        return FormValidation.sentence(NetworkSettingsError.windowStartEqualsEnd.message)
    }

    /// The first problem: the limit, then whatever the agent would refuse (the window, the list).
    public var problem: String? {
        if let uploadLimitProblem { return uploadLimitProblem }
        if let windowProblem { return windowProblem }
        return candidate().validationErrors().first.map { FormValidation.sentence($0.message) }
    }

    // MARK: Saving

    /// The settings a save would send: the saved ones with each group the user changed applied. A limit that
    /// doesn't parse leaves the saved one (`problem` reports it first). The window is saved only with a limit.
    private func candidate() -> NetworkSettings {
        var settings = saved
        if limitChanged, case .success(let limit) = parsedLimit() { settings.uploadLimit = limit }
        if limitChanged || windowChanged {
            let w = fields.window
            settings.limitWindow = fields.limitKind != .none && w.enabled
                ? LimitWindow(days: w.days, startMinute: w.start, endMinute: w.end) : nil
        }
        if fields.skipOnConstrainedNetwork != started.skipOnConstrainedNetwork {
            settings.skipOnConstrainedNetwork = fields.skipOnConstrainedNetwork
        }
        if fields.wiFiNames != started.wiFiNames { settings.skippedWiFiNames = fields.wiFiNames }
        return settings
    }

    /// What a save sends, or the first problem. Only what the user changed is applied, so a limit the field shows
    /// rounded is kept exactly unless it is retyped.
    public func request() -> Result<NetworkSettings, FormValidation.Problem> {
        if let problem { return .failure(.init(problem)) }
        return .success(candidate())
    }

    /// The agent's copy changed (a save elsewhere): each field the user hasn't touched follows it, both what it shows
    /// and its start; a field being edited is kept as typed. The limit's kind and amount go together, as do the
    /// window's fields.
    public mutating func rebase(on latest: NetworkSettings) {
        guard latest != saved else { return }
        saved = latest
        let next = Fields(settings: latest)
        if fields.limit == started.limit {
            fields.limitKind = next.limitKind
            fields.limitAmount = next.limitAmount
            fields.limitExact = next.limitExact
            started.limitKind = next.limitKind
            started.limitAmount = next.limitAmount
            started.limitExact = next.limitExact
        }
        if fields.window == started.window {
            fields.windowEnabled = next.windowEnabled
            fields.windowDays = next.windowDays
            fields.windowStart = next.windowStart
            fields.windowEnd = next.windowEnd
            started.windowEnabled = next.windowEnabled
            started.windowDays = next.windowDays
            started.windowStart = next.windowStart
            started.windowEnd = next.windowEnd
        }
        if fields.skipOnConstrainedNetwork == started.skipOnConstrainedNetwork {
            fields.skipOnConstrainedNetwork = next.skipOnConstrainedNetwork
            started.skipOnConstrainedNetwork = next.skipOnConstrainedNetwork
        }
        if fields.wiFiNames == started.wiFiNames { fields.wiFiNames = next.wiFiNames; started.wiFiNames = next.wiFiNames }
    }

    /// The agent saved `settings` (with names trimmed): the form starts again from them.
    public mutating func didSave(_ settings: NetworkSettings) {
        saved = settings
        fields = Fields(settings: settings)
        started = fields
    }

    public mutating func revert() {
        fields = Fields(settings: saved)
        started = fields
    }

    // MARK: The Now and speed lines

    /// What a backup starting at `date` would get as the Mac-wide limit, and when that next changes: "Now: 20 MB/s,
    /// until 6:00 pm", "Now: no limit, from 8:00 am Monday". From the settings the agent has (`saved`), not the
    /// form, since that is what a backup would use.
    public func nowLine(
        status: UploadSpeedStatus?, at date: Date, calendar: Calendar, locale: Locale = .current
    ) -> String {
        let resolved = resolveMacWideLimit(saved, measurement: status?.record?.latest, at: date, calendar: calendar)
        func when(_ change: Date) -> String {
            let time = UploadLimitText.timeText(change, calendar: calendar, locale: locale)
            guard !calendar.isDate(change, inSameDayAs: date) else { return time }
            return "\(time) \(UploadLimitText.weekdayText(change, calendar: calendar, locale: locale))"
        }
        switch resolved.reason {
        case .noLimitSet:
            return "No limit right now"
        case .percentNotMeasured:
            return "Now: no limit until this network is measured"
        case .outsideWindow:
            return "Now: no limit" + (resolved.changesAt.map { ", from \(when($0))" } ?? "")
        case .rate, .percentOf:
            let limit = resolved.kiB.map { UploadLimitText.speedText(kiB: $0) } ?? "no limit"
            return "Now: \(limit)" + (resolved.changesAt.map { ", until \(when($0))" } ?? "")
        }
    }

    /// The current network's speed and its age, or why there isn't one: "Upload speed on “Kerr Home”: 38 MB/s,
    /// measured today". A failure newer than the last measurement is told instead of it.
    public func speedLine(
        _ status: UploadSpeedStatus?, now: Date, calendar: Calendar, locale: Locale = .current
    ) -> String {
        guard let status, let network = status.network else { return "Not connected to a network" }
        if status.testing { return "Testing upload speed…" }
        let record = status.record
        if let failure = record?.lastFailure, failure.at > (record?.latest?.measuredAt ?? .distantPast) {
            return FormValidation.sentence(failure.reason)
        }
        guard let measurement = record?.latest else { return "Not measured on this network yet" }
        let name: String
        switch network {
        case .wiFi: name = "“\(network.displayName)”"
        case .wiFiUnknown, .ethernet, .other: name = network.displayName
        }
        let speed = UploadLimitText.speedText(kiB: Int(measurement.bitsPerSecond / 8 / 1024))
        let age = UploadLimitText.dayText(measurement.measuredAt, now: now, calendar: calendar, locale: locale)
        return "Upload speed on \(name): \(speed), measured \(age)"
    }
}

/// Whether Restorey can see the Wi-Fi network's name, which macOS reveals only to a process allowed to use Location
/// (the agent reads it, so the agent holds the permission). Decides when adding a network asks for Location (UI
/// design §6.3: only when the user first adds one) and what the list says without it.
public enum WiFiNameAccess: Sendable, Equatable {
    /// No hello from the agent yet.
    case checking
    /// The agent has never been asked (or macOS has no answer yet).
    case notAsked
    case allowed
    /// Refused for the agent; only System Settings can change it now.
    case refused
    /// Restricted (a configuration profile or Screen Time): the user can't change it, so no button is offered. Only
    /// the `locationAccess` reply carries it; a hello's Bool reads it as `refused`.
    case restricted
    /// Location Services is off for the whole Mac. No app sees the Wi-Fi name, and macOS shows no prompt.
    case servicesOff

    public init(hello: HelloReply?) {
        guard let hello else {
            self = .checking
            return
        }
        if hello.locationServicesEnabled == false {
            self = .servicesOff
            return
        }
        switch hello.locationAuthorised {
        case true?: self = .allowed
        case false?: self = .refused
        case nil: self = .notAsked
        }
    }

    public init(reply: LocationPermissionReply) {
        if reply.servicesEnabled == false {
            self = .servicesOff
        } else if reply.authorised {
            self = .allowed
        } else {
            switch reply.status {
            case "notDetermined": self = .notAsked
            case "restricted": self = .restricted
            default: self = .refused
            }
        }
    }

    public enum AddStep: Sendable, Equatable {
        /// Add the name; Restorey can already see Wi-Fi names.
        case add
        /// Ask the agent for Location permission first, and add the name only once it is allowed.
        case askFirst
        /// Adding can't help: the list says why and offers System Settings.
        case blocked
    }

    /// The "ask now?" decision for adding a name. Before the first hello the agent decides: it asks macOS only if the
    /// user has never answered, and otherwise replies at once.
    public var addStep: AddStep {
        switch self {
        case .allowed: .add
        case .notAsked, .checking: .askFirst
        case .refused, .restricted, .servicesOff: .blocked
        }
    }

    /// The sentence under the list, given how many networks it holds; nil when there is nothing to say.
    public func note(listed: Int) -> String? {
        let unused = listed > 0 ? " Until then, backups aren’t skipped on these networks." : ""
        switch self {
        case .allowed, .checking: return nil
        case .notAsked:
            return "Adding a network asks for Location permission: macOS shows the Wi-Fi network’s name only to apps "
                + "allowed to use Location."
        case .refused: return "Restorey needs Location permission to see Wi-Fi names." + unused
        case .restricted:
            return "Location is restricted on this Mac, by a configuration profile or Screen Time, so Restorey can’t "
                + "see Wi-Fi names. Whoever manages this Mac can lift it." + unused
        case .servicesOff:
            return "Location Services is off for this Mac, so Restorey can’t see Wi-Fi names. Turn it on in System "
                + "Settings → Privacy & Security → Location Services." + unused
        }
    }

    /// The line under a percentage limit when Wi-Fi networks can't be told apart (the agent can't read the name, so
    /// every Wi-Fi network shares one measurement); nil when it can, or the answer isn't known yet.
    public var percentNote: String? {
        switch self {
        case .allowed, .checking: nil
        case .notAsked, .refused, .restricted, .servicesOff:
            "Without Location permission, Restorey can’t tell Wi-Fi networks apart, so they share one measurement"
        }
    }

    /// The note comes with a button to System Settings → Privacy & Security → Location Services.
    public var opensSystemSettings: Bool { self == .refused || self == .servicesOff }

    /// After asking, when macOS still has no answer (the question wasn't answered in time, or wasn't shown).
    public static let unanswered =
        "There was no answer about Location permission, so the network wasn’t added. Add it again to be asked again."
}
