import Foundation

/// The agent's helper interface, served on `Identity.helperServiceName` only to the agent's own
/// executable running in helper mode (`print-password` or `s3-credentials`; spec §7).
///
/// The reply is `(payload, error)`: exactly one is non-nil. For `.repositoryPassword` the payload is
/// the password's bytes exactly as stored; for `.s3Credentials` it is the `credential_process` JSON.
/// The error names why the request was refused and never carries a secret.
@objc public protocol HelperXPC {
    /// `HelperRequest` JSON → secret bytes.
    func secret(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
}

/// What the helper asks for. JSON: `{"kind":"repositoryPassword","planID":"…"}`. `planID` stays a
/// string on the wire so the agent decides what an unparseable one means (a refusal).
public struct HelperRequest: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case repositoryPassword
        case s3Credentials
    }

    public var kind: Kind
    public var planID: String

    public init(kind: Kind, planID: String) {
        self.kind = kind
        self.planID = planID
    }
}

/// How long restic may keep S3 keys before it runs the helper again.
public let credentialProcessLifetime: TimeInterval = 12 * 3600

/// The `credential_process` output minio-go v7.1.0 reads:
/// `{"Version":1,"AccessKeyId":…,"SecretAccessKey":…,"Expiration":"<now + 12 h, RFC 3339 UTC>"}`.
///
/// `Expiration` is never omitted. Without it minio-go treats the keys as always expired and runs the
/// helper again for nearly every request: 16 calls instead of 1 for one backup against B2
/// (docs/spike-findings.md, H4 addendum).
public func makeCredentialProcessJSON(accessKeyID: String, secret: String, now: Date) throws -> Data {
    struct Output: Encodable {
        let Version = 1
        let AccessKeyId: String
        let SecretAccessKey: String
        let Expiration: String
    }
    let expiration = now.addingTimeInterval(credentialProcessLifetime)
        .formatted(Date.ISO8601FormatStyle(timeZone: .gmt))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(
        Output(AccessKeyId: accessKeyID, SecretAccessKey: secret, Expiration: expiration))
}
