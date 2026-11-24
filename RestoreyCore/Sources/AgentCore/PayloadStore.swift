import RestoreyCore

/// The payload of `config.json` (schema `ConfigMigrations.currentVersion`): `{"network":{…},"plans":[…]}`.
public struct ConfigFile: Codable, Sendable, Equatable {
    public var plans: [Plan]
    /// The Mac-wide network rules (schema 3, Ruling P2-6).
    public var network: NetworkSettings

    /// Which notifications are posted. Additive to schema 5: absent decodes to `.defaults`.
    public var notifications: NotificationSettings

    public init(plans: [Plan] = [], network: NetworkSettings = .defaults, notifications: NotificationSettings = .defaults) {
        self.plans = plans
        self.network = network
        self.notifications = notifications
    }

    private enum CodingKeys: String, CodingKey { case plans, network, notifications }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plans = try c.decode([Plan].self, forKey: .plans)
        network = try c.decode(NetworkSettings.self, forKey: .network)
        notifications = try c.decodeIfPresent(NotificationSettings.self, forKey: .notifications) ?? .defaults
    }
}

/// What `AgentState` needs from a file store. `VersionedStore` is the real one; tests wrap it to make
/// a save fail or suspend at a point they control.
public protocol PayloadStore<Payload>: Sendable {
    associatedtype Payload: Codable & Sendable
    /// Nil when there is no file.
    func load() async throws -> Payload?
    func save(_ payload: Payload) async throws
}

extension VersionedStore: PayloadStore {}
