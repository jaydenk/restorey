import Foundation

/// Settings → Network (UI design §6.3, product spec §5.5, Ruling P2-6): the Mac-wide rules being edited, with Save
/// and Revert as a plan's tabs have them. Pure; the app's `NetworkEditModel` does the calls.
///
/// The fields hold exactly what the controls show: the limit is parsed in `request()`, never as the user types. A
/// field still equal to its start is one the user hasn't changed, and a save leaves the agent's value for it alone.
public struct NetworkEdit: Sendable, Equatable {
    public struct Fields: Sendable, Equatable {
        /// MB/s as typed; empty is no Mac-wide limit (the default).
        public var uploadLimit: String
        public var skipOnConstrainedNetwork: Bool
        /// The Wi-Fi networks to skip, as the list shows them (each trimmed when it was added).
        public var wiFiNames: [String]

        public init(settings: NetworkSettings) {
            uploadLimit = FormValidation.uploadLimitText(kiB: settings.uploadLimitKiB)
            skipOnConstrainedNetwork = settings.skipOnConstrainedNetwork
            wiFiNames = settings.skippedWiFiNames
        }
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
        let listed = NetworkSettings(uploadLimitKiB: nil, skipOnConstrainedNetwork: false, skippedWiFiNames: fields.wiFiNames)
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

    /// Only for a limit the user has typed: one the field can only show rounded (3 KiB/s shows as "0") is kept as
    /// saved, not refused.
    public var uploadLimitProblem: String? {
        guard fields.uploadLimit != started.uploadLimit else { return nil }
        if case .failure(let problem) = FormValidation.uploadLimit(fields.uploadLimit) { return problem.message }
        return nil
    }

    /// The first problem: the limit, then whatever the agent would refuse in the list.
    public var problem: String? {
        if let uploadLimitProblem { return uploadLimitProblem }
        let listed = NetworkSettings(uploadLimitKiB: nil, skipOnConstrainedNetwork: false, skippedWiFiNames: fields.wiFiNames)
        return listed.validationErrors().first.map { FormValidation.sentence($0.message) }
    }

    // MARK: Saving

    /// What a save sends, or the first problem. Only what the user changed is applied, so a limit the field shows
    /// rounded is kept exactly unless it is retyped.
    public func request() -> Result<NetworkSettings, FormValidation.Problem> {
        if let problem { return .failure(.init(problem)) }
        var settings = saved
        if fields.uploadLimit != started.uploadLimit, case .success(let limit) = FormValidation.uploadLimit(fields.uploadLimit) {
            settings.uploadLimitKiB = limit
        }
        if fields.skipOnConstrainedNetwork != started.skipOnConstrainedNetwork {
            settings.skipOnConstrainedNetwork = fields.skipOnConstrainedNetwork
        }
        if fields.wiFiNames != started.wiFiNames { settings.skippedWiFiNames = fields.wiFiNames }
        return .success(settings)
    }

    /// The agent's copy changed (a save elsewhere): each field the user hasn't touched follows it, both what it shows
    /// and its start; a field being edited is kept as typed.
    public mutating func rebase(on latest: NetworkSettings) {
        guard latest != saved else { return }
        saved = latest
        let next = Fields(settings: latest)
        if fields.uploadLimit == started.uploadLimit { fields.uploadLimit = next.uploadLimit; started.uploadLimit = next.uploadLimit }
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

    /// The note comes with a button to System Settings → Privacy & Security → Location Services.
    public var opensSystemSettings: Bool { self == .refused || self == .servicesOff }

    /// After asking, when macOS still has no answer (the question wasn't answered in time, or wasn't shown).
    public static let unanswered =
        "There was no answer about Location permission, so the network wasn’t added. Add it again to be asked again."
}
