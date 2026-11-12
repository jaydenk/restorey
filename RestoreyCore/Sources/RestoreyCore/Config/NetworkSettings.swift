import Foundation

/// The Mac-wide network rules (Ruling P2-6, UI design §6.3), kept in `config.json` beside the plans
/// (`ConfigFile.network`) since schema 3. They apply only to a repository that needs the network
/// (`Repository.needsNetwork`).
/// JSON: `{"skipOnConstrainedNetwork":true,"skippedWiFiNames":[]}`, with `uploadLimitKiB` omitted when nil.
public struct NetworkSettings: Codable, Sendable, Equatable {
    /// The upload limit, in KiB/s, shared by the backups to networked repositories that run at once. Nil
    /// for no Mac-wide limit; a plan's own `uploadLimitKiB` still applies.
    public var uploadLimitKiB: Int?
    /// Skip a backup on a constrained or expensive network (Low Data Mode, a phone hotspot).
    public var skipOnConstrainedNetwork: Bool
    /// Wi-Fi network names to skip backups on.
    public var skippedWiFiNames: [String]

    public init(uploadLimitKiB: Int?, skipOnConstrainedNetwork: Bool, skippedWiFiNames: [String]) {
        self.uploadLimitKiB = uploadLimitKiB
        self.skipOnConstrainedNetwork = skipOnConstrainedNetwork
        self.skippedWiFiNames = skippedWiFiNames
    }

    /// No Mac-wide limit, skip on a constrained network, no Wi-Fi names.
    public static let defaults = NetworkSettings(uploadLimitKiB: nil, skipOnConstrainedNetwork: true, skippedWiFiNames: [])
}
