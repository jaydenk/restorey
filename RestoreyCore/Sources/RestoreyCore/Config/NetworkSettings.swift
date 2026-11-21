import Foundation

/// The Mac-wide network rules (Ruling P2-6, UI design §6.3), kept in `config.json` beside the plans
/// (`ConfigFile.network`) since schema 3. They apply only to a repository that needs the network
/// (`Repository.needsNetwork`).
/// JSON: `{"uploadLimit":{"kind":"none"},"skipOnConstrainedNetwork":true,"skippedWiFiNames":[]}`, with `limitWindow`
/// omitted when nil. `uploadLimit` decodes as none when absent (the migration to schema 5 reads the old
/// `uploadLimitKiB`).
public struct NetworkSettings: Codable, Sendable, Equatable {
    /// The upload limit shared by the backups to networked repositories that run at once; a plan's own
    /// `uploadLimitKiB` still applies.
    public var uploadLimit: MacUploadLimit
    /// When the limit applies; nil means always.
    public var limitWindow: LimitWindow?
    /// Skip a backup on a constrained or expensive network (Low Data Mode, a phone hotspot).
    public var skipOnConstrainedNetwork: Bool
    /// Wi-Fi network names to skip backups on.
    public var skippedWiFiNames: [String]

    public init(
        uploadLimit: MacUploadLimit,
        limitWindow: LimitWindow? = nil,
        skipOnConstrainedNetwork: Bool,
        skippedWiFiNames: [String]
    ) {
        self.uploadLimit = uploadLimit
        self.limitWindow = limitWindow
        self.skipOnConstrainedNetwork = skipOnConstrainedNetwork
        self.skippedWiFiNames = skippedWiFiNames
    }

    private enum CodingKeys: String, CodingKey { case uploadLimit, limitWindow, skipOnConstrainedNetwork, skippedWiFiNames }

    /// Hand-written so a config from before `uploadLimit` existed still decodes (as no limit).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uploadLimit = try c.decodeIfPresent(MacUploadLimit.self, forKey: .uploadLimit) ?? .none
        limitWindow = try c.decodeIfPresent(LimitWindow.self, forKey: .limitWindow)
        skipOnConstrainedNetwork = try c.decode(Bool.self, forKey: .skipOnConstrainedNetwork)
        skippedWiFiNames = try c.decode([String].self, forKey: .skippedWiFiNames)
    }

    /// No Mac-wide limit, skip on a constrained network, no Wi-Fi names.
    public static let defaults = NetworkSettings(uploadLimit: .none, skipOnConstrainedNetwork: true, skippedWiFiNames: [])
}

/// Why `NetworkSettings` can't be saved (Review Focus 5). `message` is the sentence shown to the user.
public enum NetworkSettingsError: Equatable, Sendable {
    /// The Mac-wide upload rate is 0 or negative. No limit is `.none`, not 0.
    case limitNotPositive
    /// The Mac-wide upload percentage is not from 1 to 100.
    case percentOutOfRange(Int)
    /// The limit window starts and ends at the same time.
    case windowStartEqualsEnd
    /// A limit window time is not within the day (0..<1440 minutes).
    case windowTimeInvalid
    /// A Wi-Fi name is empty or only spaces.
    case emptyWiFiName
    /// A Wi-Fi name is listed twice, ignoring case and surrounding spaces. Carries the later spelling, trimmed.
    case duplicateWiFiName(String)

    public var message: String {
        switch self {
        case .limitNotPositive: "The upload limit must be more than 0 KiB/s"
        case .percentOutOfRange: "The upload limit must be a percentage from 1 to 100"
        case .windowStartEqualsEnd: "The limit’s start and end times can’t be the same"
        case .windowTimeInvalid: "A limit time must be within the day"
        case .emptyWiFiName: "A Wi-Fi network name can’t be empty"
        case .duplicateWiFiName(let name): "The Wi-Fi network “\(name)” is in the list more than once"
        }
    }
}

extension NetworkSettings {
    /// Every problem, each once, in a fixed order: the limit, the window, then an empty name, then each network
    /// listed more than once. Names are compared as they are saved (`normalised`) and as they are matched
    /// (`isSkipped`): trimmed and ignoring case.
    public func validationErrors() -> [NetworkSettingsError] {
        var errors: [NetworkSettingsError] = []
        switch uploadLimit {
        case .none: break
        case .rate(let kiB, _): if kiB <= 0 { errors.append(.limitNotPositive) }
        case .percent(let percent): if !(1...100).contains(percent) { errors.append(.percentOutOfRange(percent)) }
        }
        if let limitWindow {
            let day = 0..<1440
            if !day.contains(limitWindow.startMinute) || !day.contains(limitWindow.endMinute) {
                errors.append(.windowTimeInvalid)
            } else if limitWindow.startMinute == limitWindow.endMinute {
                errors.append(.windowStartEqualsEnd)
            }
        }
        var seen: Set<String> = []
        var reported: Set<String> = []
        var duplicates: [NetworkSettingsError] = []
        for name in skippedWiFiNames.map(Self.trimmed) {
            if name.isEmpty {
                if !errors.contains(.emptyWiFiName) { errors.append(.emptyWiFiName) }
                continue
            }
            let key = Self.matchKey(name)
            if !seen.insert(key).inserted, reported.insert(key).inserted {
                duplicates.append(.duplicateWiFiName(name))
            }
        }
        return errors + duplicates
    }

    /// The settings as saved: each Wi-Fi name trimmed of surrounding spaces and newlines.
    public func normalised() -> NetworkSettings {
        var settings = self
        settings.skippedWiFiNames = skippedWiFiNames.map(Self.trimmed)
        return settings
    }

    /// Whether the Wi-Fi network named `wiFiName` is in the skip list. Matching ignores case and
    /// surrounding spaces, not accents: "Cafe" and "Café" are different networks.
    public func isSkipped(wiFiName: String) -> Bool {
        let key = Self.matchKey(Self.trimmed(wiFiName))
        return !key.isEmpty && skippedWiFiNames.contains { Self.matchKey(Self.trimmed($0)) == key }
    }

    static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Case-folded and in one Unicode form, so canonically equivalent spellings ("é" as one code point or
    /// as "e" and a combining accent) give the same key in a `Set`. Shared with `NetworkKey`, so a Wi-Fi name
    /// is matched the same way for the skip list and for the measurements.
    static func matchKey(_ name: String) -> String {
        name.folding(options: .caseInsensitive, locale: nil).precomposedStringWithCanonicalMapping
    }
}

/// The `--limit-upload` (KiB/s) for a backup to a networked repository (Ruling P2-7): the smaller of the
/// plan's own limit and its share of the Mac-wide one, the Mac-wide limit divided by the backups to
/// networked repositories uploading when this one starts, counting itself. Never 0, which restic reads
/// as no limit. Nil when neither limit is set. A backup to a folder or drive gets the plan's limit alone.
public func effectiveUploadLimitKiB(plan: Int?, macWide: Int?, networkedBackupsRunning: Int) -> Int? {
    let share = macWide.map { max(1, $0 / max(1, networkedBackupsRunning)) }
    switch (plan, share) {
    case let (plan?, share?): return min(plan, share)
    case let (plan?, nil): return plan
    case let (nil, share?): return share
    case (nil, nil): return nil
    }
}
