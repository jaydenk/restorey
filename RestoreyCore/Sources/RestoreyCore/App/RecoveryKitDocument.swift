import CryptoKit
import Foundation

/// The recovery kit (UI design §7, product spec §7): everything needed to open a plan's repository if this Mac
/// is lost, made from the agent's `recoveryKit` reply. The app shows it with a copy button per field, prints it
/// and saves it as a PDF where the user picks; it is never written anywhere by itself.
///
/// It holds secrets: the app keeps one only while the window or setup step showing it is open. Its
/// descriptions and mirror never include a secret value, like `SecretEntry`'s.
public struct RecoveryKitDocument: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public struct Section: Sendable, Equatable, Identifiable, CustomStringConvertible, CustomReflectable {
        public var title: String
        public var fields: [Field]

        public init(title: String, fields: [Field]) {
            self.title = title
            self.fields = fields
        }

        public var id: String { title }
        public var description: String { "Section(\(title): \(fields))" }
        public var customMirror: Mirror {
            Mirror(self, children: ["title": title, "fields": fields], displayStyle: .struct)
        }
    }

    public struct Field: Sendable, Equatable, Identifiable, CustomStringConvertible, CustomReflectable {
        public var label: String
        public var value: String
        /// The value opens the repository or stands in for it (a password, a key, a command carrying them, the
        /// check-in URL): shown as `concealed` until revealed.
        public var isSecret: Bool
        /// What the screen shows before a reveal: the value itself when it isn't secret, a command with its
        /// secrets as dots, or just dots.
        public var concealed: String

        public init(label: String, value: String, isSecret: Bool, concealed: String? = nil) {
            self.label = label
            self.value = value
            self.isSecret = isSecret
            self.concealed = concealed ?? (isSecret ? RestoreCommands.mask : value)
        }

        public var id: String { label }
        public var description: String { "Field(\(label): \(concealed))" }
        public var customMirror: Mirror {
            Mirror(self, children: ["label": label, "value": concealed, "isSecret": isSecret], displayStyle: .struct)
        }
    }

    public var planName: String
    /// When the kit was made, for its heading (stored in UTC, shown in local time).
    public var createdAt: Date
    public var sections: [Section]
    /// `digest(for:)` of the plan the kit was made from: what confirming this kit sends, so the agent can tell it
    /// still matches what it stores. Not secret.
    public var digest: String

    public init(planName: String, createdAt: Date, sections: [Section], digest: String) {
        self.planName = planName
        self.createdAt = createdAt
        self.sections = sections
        self.digest = digest
    }

    public var description: String { "RecoveryKitDocument(\(planName), sections: \(sections.map(\.title)))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["planName": planName, "createdAt": createdAt, "sections": sections], displayStyle: .struct)
    }

    /// Repository (address, password); the backend's keys, as "Storage keys" for S3 and B2 or each environment
    /// variable for another location, left out when there are none; This Mac (the host label snapshots are
    /// under); Restore without Restorey (`RestoreCommands`); and the check-in URL when the plan has one. The
    /// password is the one restic uses (`RestoreCommands.resticPassword`); every other value is as stored.
    public static func make(_ kit: RecoveryKitSecrets, createdAt: Date) -> RecoveryKitDocument {
        let plan = kit.plan
        let values = Dictionary(kit.secrets.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        func secret(_ label: String, _ key: SecretKey) -> Field? {
            values[key].map { Field(label: label, value: $0, isSecret: true) }
        }

        var sections = [Section(title: "Repository", fields: [
            Field(label: "Address", value: plan.repository.resticRepository, isSecret: false),
        ] + [values[.repositoryPassword(plan.id)].map {
            Field(label: "Password", value: RestoreCommands.resticPassword($0), isSecret: true)
        }].compactMap { $0 })]

        switch plan.repository {
        case .s3:
            let keys = [secret("Key ID", .s3AccessKeyID(plan.id)), secret("Secret key", .s3SecretAccessKey(plan.id))]
            sections.append(Section(title: "Storage keys", fields: keys.compactMap { $0 }))
        case .raw(_, let names) where !names.isEmpty:
            sections.append(Section(
                title: "Environment variables",
                fields: names.compactMap { secret($0, .environment(plan.id, name: $0)) }))
        case .raw:
            break
        }

        sections.append(Section(title: "This Mac", fields: [
            Field(label: "Host label", value: plan.hostLabel, isSecret: false),
        ]))
        sections.append(Section(
            title: "Restore without Restorey",
            fields: RestoreCommands.make(plan: plan, secrets: kit.secrets).map {
                Field(label: $0.title, value: $0.revealedText, isSecret: $0.needsSecrets, concealed: $0.text)
            }))
        if plan.hasCheckInURL, let url = secret("Check-in URL", .checkInURL(plan.id)) {
            sections.append(Section(title: "Check-in URL", fields: [url]))
        }
        return RecoveryKitDocument(planName: plan.name, createdAt: createdAt, sections: sections, digest: digest(for: plan))
    }

    /// What a kit for `plan` stands for, as lower-case hex SHA-256 (Task 9). The app makes it from the plan in the kit
    /// it showed (`make`), the agent from the plan it stores, so a confirmation is refused when anything the kit holds
    /// has changed since it was shown. It hashes the plan's ID, the repository address, the host label the restore
    /// commands pass, the names of the keys the kit holds (`Plan.credentialKeys`) and `credentialsVersion`, which
    /// stands for their values: no secret goes in, so the agent needn't read the keychain to make it and the digest
    /// gives nothing away. The check-in URL, the name and the folders aren't in it: none of them is needed to restore,
    /// and changing them doesn't ask for a new kit (`AgentState.savePlan`).
    public static func digest(for plan: Plan) -> String {
        let facts = ["restorey-recovery-kit-1", plan.id.uuidString, plan.repository.resticRepository, plan.hostLabel]
            + plan.credentialKeys.map(\.account) + [String(plan.credentialsVersion)]
        // Each fact is prefixed with its length, so no two lists of facts give the same bytes.
        let bytes = facts.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(bytes.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The agent's refusal when the kit confirmed isn't the current one (`digest(for:)` differs), so the app can send the
    /// person back to the kit.
    public static let detailsChangedRefusal = "The recovery details changed. Save the new recovery kit first."
}

/// Whether a place the recovery kit is saved to is this Mac's own disk (UI design §7: "a warning if the location
/// is on the Mac's internal disk"). The app reads the volume's `volumeIsInternal` and `volumeIsRemovable`; this
/// decides.
public enum RecoveryKitLocation {
    /// Internal and not removable is the Mac's own disk. Unknown counts as the Mac's own: a needless warning
    /// costs a glance, a missing one leaves the only copy of the kit on the Mac it protects.
    public static func isOnInternalDisk(isInternal: Bool?, isRemovable: Bool?) -> Bool {
        if isRemovable == true { return false }
        return isInternal ?? true
    }

    /// The sentence shown after saving to the Mac's own disk.
    public static let internalDiskWarning =
        "This copy is on this Mac’s own disk, so it would be lost with the Mac. Once the kit is stored somewhere else (a password manager, a drive you keep elsewhere, or paper), delete this file."
}
