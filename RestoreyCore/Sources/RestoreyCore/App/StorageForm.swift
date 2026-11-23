import Foundation

/// Setup's "Where backups go" form (UI design §4 step 2): B2, S3, or another restic location, read into the
/// plan's `Repository`. Holds no secret: the keys and environment values are typed into `SecretField`s and
/// kept in `SetupDraft` until "Check" hands them to the agent. Each problem is a sentence ending with a full
/// stop, or nil.
public struct StorageForm: Sendable, Equatable {
    public enum Kind: String, CaseIterable, Sendable, Identifiable {
        case b2, s3, folder, other
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .b2: "B2"
            case .s3: "S3"
            case .folder: "Folder or Drive"
            case .other: "Other"
            }
        }

        /// Where to read how to make a bucket and a key, for the guided forms.
        public var helpLink: (title: String, url: URL)? {
            switch self {
            case .b2:
                ("How to make a bucket and an application key in Backblaze",
                 URL(string: "https://www.backblaze.com/docs/cloud-storage-create-and-manage-app-keys")!)
            case .s3:
                ("How to make an access key in AWS",
                 URL(string: "https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html")!)
            case .folder, .other: nil
            }
        }
    }

    /// A raw repository's environment variable: the name is kept in the plan, the value is a secret.
    public struct EnvironmentRow: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var name: String

        public init(id: UUID = UUID(), name: String = "") {
            self.id = id
            self.name = name
        }
    }

    /// Set by restic invocations themselves: a raw value under one of these names would be ignored.
    public static let reservedEnvironmentNames: Set<String> = [
        "RESTIC_REPOSITORY", "RESTIC_REPOSITORY_FILE", "RESTIC_PASSWORD", "RESTIC_PASSWORD_FILE",
        "RESTIC_PASSWORD_COMMAND", "RESTIC_PROGRESS_FPS",
    ]

    public var kind: Kind
    public var endpoint: String
    public var bucket: String
    public var prefix: String
    /// `.folder`: the folder or drive chosen with the picker, as a full path; empty until one is chosen.
    public var folderPath: String
    /// `.other`: what restic takes as `-r`, such as `/Volumes/Backup/restic` or `sftp:nas:/restic`.
    public var repository: String
    public var environment: [EnvironmentRow]

    /// A new form: B2 (the default, UI design §4), with no endpoint, since every B2 bucket names its own.
    public init(kind: Kind = .b2) {
        self.kind = kind
        endpoint = ""
        bucket = ""
        prefix = ""
        folderPath = ""
        repository = ""
        environment = []
    }

    /// AWS's global endpoint, which restic resolves to the bucket's region.
    public static let awsEndpoint = "s3.amazonaws.com"
    /// What the B2 endpoint field shows when empty: the form of the bucket's endpoint in Backblaze's console.
    public static let b2EndpointPlaceholder = "s3.us-west-004.backblazeb2.com"

    /// Switches the kind, filling in AWS's endpoint for S3 when nothing has been typed there.
    public mutating func choose(_ kind: Kind) {
        if kind == .s3, endpoint.trimmingCharacters(in: .whitespaces).isEmpty { endpoint = Self.awsEndpoint }
        if kind == .b2, endpoint == Self.awsEndpoint { endpoint = "" }
        self.kind = kind
    }

    /// The form showing a saved plan's repository (setup resumed at this step).
    public init(repository: Repository) {
        self.init()
        switch repository {
        case .s3(let location):
            kind = location.provider == .b2 ? .b2 : .s3
            endpoint = location.endpoint.absoluteString
            bucket = location.bucket
            prefix = location.prefix
        case .raw(let raw, let names):
            if names.isEmpty, let folder = repository.localFolderPath {
                kind = .folder
                folderPath = folder
            } else {
                kind = .other
                self.repository = raw
                environment = names.map { EnvironmentRow(name: $0) }
            }
        }
    }

    // MARK: Problems

    public var endpointProblem: String? { !isBucketKind ? nil : FormValidation.endpoint(endpoint) }
    public var bucketProblem: String? { !isBucketKind ? nil : FormValidation.bucket(bucket) }

    /// The prefix is a folder inside the bucket: slashes at either end are dropped, and nothing else is refused
    /// except a line break.
    public var prefixProblem: String? {
        guard isBucketKind else { return nil }
        return prefix.contains(where: \.isNewline) ? "The folder must be on one line." : nil
    }

    /// B2 and S3, which have an endpoint, a bucket and a folder in it.
    private var isBucketKind: Bool { kind == .b2 || kind == .s3 }

    public var repositoryProblem: String? {
        switch kind {
        case .b2, .s3: return nil
        case .folder:
            return folderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Choose a folder or drive for the backups." : nil
        case .other: break
        }
        let typed = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty { return "Enter the repository location, such as /Volumes/Backup/restic or sftp:nas:/restic." }
        if typed.contains(where: \.isNewline) { return "The repository location must be on one line." }
        let path = Self.expandedPath(typed)
        let local = !Repository.rawLocationNeedsNetwork(path)
        if local {
            let folder = path.hasPrefix("local:") ? String(path.dropFirst("local:".count)) : path
            if !folder.hasPrefix("/") {
                return "A folder or drive needs its full path, starting with / (or ~ for your home folder)."
            }
        }
        return nil
    }

    /// One sentence per row, or nil: a name restic's environment can hold, not one Restorey sets itself, and
    /// not listed twice.
    public func environmentProblem(_ row: EnvironmentRow) -> String? {
        let name = row.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Enter the variable’s name, such as RESTIC_REST_PASSWORD." }
        if name.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) == nil {
            return "A variable name is letters, numbers and underscores, and doesn’t start with a number."
        }
        if Self.reservedEnvironmentNames.contains(name) {
            return "Restorey sets \(name) itself: leave it out."
        }
        if environment.filter({ $0.name.trimmingCharacters(in: .whitespaces) == name }).count > 1 {
            return "\(name) is listed twice."
        }
        return nil
    }

    /// Whether every field reads (the secrets are checked by `missingSecrets`).
    public var isValid: Bool {
        [endpointProblem, bucketProblem, prefixProblem, repositoryProblem].allSatisfy { $0 == nil }
            && (kind != .other || environment.allSatisfy { environmentProblem($0) == nil })
    }

    // MARK: Reading

    /// The repository the form describes, or nil while it has a problem.
    public var repositoryValue: Repository? {
        guard isValid else { return nil }
        switch kind {
        case .b2, .s3:
            guard let endpoint = FormValidation.normalisedEndpoint(endpoint), let url = URL(string: endpoint) else {
                return nil
            }
            let folder = prefix.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return .s3(S3Location(
                provider: kind == .b2 ? .b2 : .s3, endpoint: url,
                bucket: bucket.trimmingCharacters(in: .whitespacesAndNewlines), prefix: folder))
        case .folder:
            return .raw(repository: folderPath.trimmingCharacters(in: .whitespacesAndNewlines), environmentNames: [])
        case .other:
            return .raw(
                repository: Self.expandedPath(repository.trimmingCharacters(in: .whitespacesAndNewlines)),
                environmentNames: environment.map { $0.name.trimmingCharacters(in: .whitespaces) })
        }
    }

    /// The secrets this form's repository needs, for `planID`: both keys for B2 and S3, each environment value
    /// for another location. `secret` reads what the user typed (empty or nil is nothing).
    public func secretKeys(planID: UUID) -> [SecretKey] {
        switch kind {
        case .b2, .s3: [.s3AccessKeyID(planID), .s3SecretAccessKey(planID)]
        case .folder: []
        case .other: environment.map { .environment(planID, name: $0.name.trimmingCharacters(in: .whitespaces)) }
        }
    }

    /// Whether an empty secret field keeps the saved value: only while the form still describes `saved`, the
    /// repository the plan was saved with (a changed address needs every secret again, `secretEntries`).
    public func keepsSavedSecrets(saved: Repository?) -> Bool {
        saved != nil && repositoryValue == saved
    }

    /// The secrets to send with "Check", or the sentence saying what's missing. A secret left empty is kept as
    /// it is when `saved` (the plan was saved before with the same repository, so the agent has it); a new
    /// plan, or a changed repository, needs every one. `typed` reads the keys' fields; `environmentValue` reads
    /// an environment row's value by the row's id, since its name (and so its keychain name) may have changed
    /// since it was typed.
    public func secretEntries(
        planID: UUID, typed: (SecretKey) -> String?, environmentValue: (UUID) -> String? = { _ in nil },
        saved: Bool
    ) -> Result<[SecretEntry], FormValidation.Problem> {
        var entries: [SecretEntry] = []
        var missing: [String] = []
        let rows = Dictionary(
            environment.map { ($0.name.trimmingCharacters(in: .whitespaces), $0.id) }, uniquingKeysWith: { first, _ in first })
        for key in secretKeys(planID: planID) {
            let value: String?
            if case .environment(_, let name) = key { value = rows[name].flatMap(environmentValue) } else { value = typed(key) }
            if let value, !value.isEmpty {
                entries.append(SecretEntry(key: key, value: value))
            } else if !saved {
                missing.append(Self.label(for: key, kind: kind))
            }
        }
        guard missing.isEmpty else {
            return .failure(FormValidation.Problem("Enter the \(Self.list(missing))."))
        }
        return .success(entries)
    }

    /// The label of a secret's field.
    public static func label(for key: SecretKey, kind: Kind) -> String {
        switch key {
        case .s3AccessKeyID: kind == .b2 ? "key ID" : "access key ID"
        case .s3SecretAccessKey: kind == .b2 ? "application key" : "secret access key"
        case .environment(_, let name): "value of \(name.isEmpty ? "each variable" : name)"
        case .repositoryPassword: "repository password"
        case .checkInURL: "check-in URL"
        }
    }

    /// A plan name for the new plan, from where it backs up to: "B2 · my-backups", "Local · Backup". String handling
    /// alone (`SourcePaths.lastComponent`): setup names the plan on the main actor, where a stat of a drive that stops
    /// answering would hang the app (L157).
    public static func planName(for repository: Repository) -> String {
        switch repository {
        case .s3(let location): "\(location.provider == .b2 ? "B2" : "S3") · \(location.bucket)"
        case .raw(let raw, _):
            Repository.rawLocationNeedsNetwork(raw)
                ? "restic · \(raw.prefix { $0 != ":" })"
                : "Local · \(SourcePaths.lastComponent(raw.hasPrefix("local:") ? String(raw.dropFirst(6)) : raw))"
        }
    }

    /// `~` and `~/…` (and `local:~/…`) written out, since restic expands neither.
    static func expandedPath(_ typed: String, home: String = NSHomeDirectory()) -> String {
        let local = typed.hasPrefix("local:")
        let path = local ? String(typed.dropFirst("local:".count)) : typed
        let expanded = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst(1) : path
        return (local ? "local:" : "") + expanded
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }
}
