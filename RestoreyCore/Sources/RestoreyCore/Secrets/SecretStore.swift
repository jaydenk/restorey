import Foundation
import Synchronization

/// A secret Restorey holds on a plan's behalf. The `account` string is the keychain account name.
public enum SecretKey: Hashable, Sendable {
    case repositoryPassword(UUID)
    case s3AccessKeyID(UUID)
    case s3SecretAccessKey(UUID)
    case environment(UUID, name: String)
    case checkInURL(UUID)

    /// The prefix shared by every account that belongs to one plan.
    public static func accountPrefix(planID: UUID) -> String { "plan.\(planID.uuidString)." }

    public var account: String {
        switch self {
        case .repositoryPassword(let id): Self.accountPrefix(planID: id) + "repository-password"
        case .s3AccessKeyID(let id): Self.accountPrefix(planID: id) + "s3-access-key-id"
        case .s3SecretAccessKey(let id): Self.accountPrefix(planID: id) + "s3-secret-access-key"
        case .environment(let id, let name): Self.accountPrefix(planID: id) + "environment." + name
        case .checkInURL(let id): Self.accountPrefix(planID: id) + "check-in-url"
        }
    }
}

/// The app names the secrets it sends in `SavePlanRequest` with this.
/// JSON: `{"type":"repositoryPassword","planID":"…"}` (likewise `s3AccessKeyID`, `s3SecretAccessKey`,
/// `checkInURL`) and `{"type":"environment","planID":"…","name":"RESTIC_REST_PASSWORD"}`.
extension SecretKey: Codable {
    private enum CodingKeys: String, CodingKey { case type, planID, name }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let id = try c.decode(UUID.self, forKey: .planID)
        switch type {
        case "repositoryPassword": self = .repositoryPassword(id)
        case "s3AccessKeyID": self = .s3AccessKeyID(id)
        case "s3SecretAccessKey": self = .s3SecretAccessKey(id)
        case "environment": self = .environment(id, name: try c.decode(String.self, forKey: .name))
        case "checkInURL": self = .checkInURL(id)
        case let other: throw DecodingError.dataCorruptedError(
            forKey: .type, in: c, debugDescription: "Unknown secret key type \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .repositoryPassword(let id):
            try c.encode("repositoryPassword", forKey: .type)
            try c.encode(id, forKey: .planID)
        case .s3AccessKeyID(let id):
            try c.encode("s3AccessKeyID", forKey: .type)
            try c.encode(id, forKey: .planID)
        case .s3SecretAccessKey(let id):
            try c.encode("s3SecretAccessKey", forKey: .type)
            try c.encode(id, forKey: .planID)
        case .environment(let id, let name):
            try c.encode("environment", forKey: .type)
            try c.encode(id, forKey: .planID)
            try c.encode(name, forKey: .name)
        case .checkInURL(let id):
            try c.encode("checkInURL", forKey: .type)
            try c.encode(id, forKey: .planID)
        }
    }

    /// The plan the secret belongs to.
    public var planID: UUID {
        switch self {
        case .repositoryPassword(let id), .s3AccessKeyID(let id), .s3SecretAccessKey(let id),
             .environment(let id, _), .checkInURL(let id):
            id
        }
    }
}

public enum SecretStoreError: Error, Equatable, CustomStringConvertible {
    /// A Security framework call failed. `message` is `SecCopyErrorMessageString`'s text.
    case keychain(status: Int32, message: String)
    /// The stored bytes are not valid UTF-8.
    case undecodableValue(account: String)

    public var description: String {
        switch self {
        case .keychain(let status, let message): "keychain error \(status) (\(message))"
        case .undecodableValue(let account): "the keychain value for \(account) is not valid UTF-8"
        }
    }
}

public protocol SecretStore: Sendable {
    /// Returns nil when there is no such secret.
    func read(_ key: SecretKey) throws -> String?
    /// Creates or replaces the secret. The value is stored exactly as given.
    func write(_ value: String, for key: SecretKey) throws
    /// Deleting a secret that does not exist is not an error.
    func delete(_ key: SecretKey) throws
    /// Removes every secret whose account starts with `plan.<id>.`.
    func deleteAll(planID: UUID) throws
}

/// For tests of code that needs a `SecretStore` but not the keychain.
public final class InMemorySecretStore: SecretStore {
    private let items = Mutex<[String: String]>([:])

    public init() {}

    public func read(_ key: SecretKey) throws -> String? {
        items.withLock { $0[key.account] }
    }

    public func write(_ value: String, for key: SecretKey) throws {
        items.withLock { $0[key.account] = value }
    }

    public func delete(_ key: SecretKey) throws {
        items.withLock { _ = $0.removeValue(forKey: key.account) }
    }

    public func deleteAll(planID: UUID) throws {
        let prefix = SecretKey.accountPrefix(planID: planID)
        items.withLock { items in
            for account in items.keys where account.hasPrefix(prefix) { items.removeValue(forKey: account) }
        }
    }
}
