import Foundation

/// The arguments and environment for one restic process. Every restic run in Restorey is built by
/// `makeInvocation`, so this is the single place the flags are decided. Flag names are pinned to
/// the vendored restic by `ResticInvocationAcceptanceTests`.
public struct ResticInvocation: Sendable, Equatable {
    public var arguments: [String]
    public var environment: [String: String]

    public init(arguments: [String], environment: [String: String]) {
        self.arguments = arguments
        self.environment = environment
    }
}

/// Everything the builder needs that is not part of the plan.
public struct ResticContext: Sendable {
    /// Passed as `--cache-dir` exactly as given.
    public var cacheDirectory: URL
    /// The agent executable, which answers `print-password --plan <id>` for `RESTIC_PASSWORD_COMMAND`.
    public var helperExecutable: URL
    /// The AWS shared credentials file restic reads through `credential_process`. S3 plans only.
    public var credentialsFile: URL?
    /// Environment values for raw plans, read from the keychain by the caller. Ignored for S3 plans.
    public var rawEnvironment: [String: String]
    public var homeDirectory: URL

    public init(
        cacheDirectory: URL,
        helperExecutable: URL,
        credentialsFile: URL?,
        rawEnvironment: [String: String],
        homeDirectory: URL
    ) {
        self.cacheDirectory = cacheDirectory
        self.helperExecutable = helperExecutable
        self.credentialsFile = credentialsFile
        self.rawEnvironment = rawEnvironment
        self.homeDirectory = homeDirectory
    }
}

/// One restic operation. Persisted in run records, so the JSON is explicit:
/// `{"type":"forget","dryRun":true}`, `{"type":"snapshots","allHosts":false}`, `{"type":"backup"}`.
public enum ResticOperation: Codable, Sendable, Equatable {
    case initRepository
    case backup
    case forget(dryRun: Bool)
    case prune
    case check
    /// `allHosts: true` lists every host's snapshots (adopting a repository) and omits `--host`.
    case snapshots(allHosts: Bool)
    case unlock

    private enum CodingKeys: String, CodingKey { case type, dryRun, allHosts }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "initRepository": self = .initRepository
        case "backup": self = .backup
        case "forget": self = .forget(dryRun: try c.decode(Bool.self, forKey: .dryRun))
        case "prune": self = .prune
        case "check": self = .check
        case "snapshots": self = .snapshots(allHosts: try c.decode(Bool.self, forKey: .allHosts))
        case "unlock": self = .unlock
        case let other: throw DecodingError.dataCorruptedError(
            forKey: .type, in: c, debugDescription: "Unknown restic operation \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .initRepository: try c.encode("initRepository", forKey: .type)
        case .backup: try c.encode("backup", forKey: .type)
        case .forget(let dryRun):
            try c.encode("forget", forKey: .type)
            try c.encode(dryRun, forKey: .dryRun)
        case .prune: try c.encode("prune", forKey: .type)
        case .check: try c.encode("check", forKey: .type)
        case .snapshots(let allHosts):
            try c.encode("snapshots", forKey: .type)
            try c.encode(allHosts, forKey: .allHosts)
        case .unlock: try c.encode("unlock", forKey: .type)
        }
    }
}

/// How long the maintenance commands wait for a repository lock held by another process.
private let maintenanceRetryLock = "5m"

/// Builds the restic invocation for `op`.
///
/// Safety properties, each covered by a test:
/// - `forget` is always limited to this plan's host and `restorey:<id>` tag and never prunes, so it
///   cannot delete snapshots that Restorey did not make.
/// - `unlock` never passes `--remove-all`.
/// - The repository password is never in the environment, only the command that fetches it.
/// - S3 plans get a profile in the credentials file and no `AWS_*` key variables.
public func makeInvocation(_ op: ResticOperation, plan: Plan, context: ResticContext) -> ResticInvocation {
    let tag = "restorey:\(plan.id.uuidString)"
    var args: [String]

    switch op {
    case .initRepository:
        args = ["init"] + common(context)
    case .backup:
        args = ["backup"] + common(context)
            + ["--host", plan.hostLabel, "--tag", tag,
               "--skip-if-unchanged", "--exclude-cloud-files", "--exclude-caches"]
            + packSize(plan)
        if let limit = plan.uploadLimitKiB { args += ["--limit-upload", String(limit)] }
        for pattern in plan.exclusions { args += ["--exclude", pattern] }
        args += ["--"] + plan.sources
    case .forget(let dryRun):
        let r = plan.retention
        args = ["forget"] + common(context)
            + ["--host", plan.hostLabel, "--tag", tag, "--group-by", "host,paths,tags",
               "--keep-hourly", String(r.hourly), "--keep-daily", String(r.daily),
               "--keep-weekly", String(r.weekly), "--keep-monthly", String(r.monthly)]
        if dryRun { args.append("--dry-run") }
        args += ["--retry-lock", maintenanceRetryLock]
    case .prune:
        args = ["prune"] + common(context) + packSize(plan) + ["--retry-lock", maintenanceRetryLock]
    case .check:
        args = ["check"] + common(context) + ["--retry-lock", maintenanceRetryLock]
    case .snapshots(let allHosts):
        args = ["snapshots"] + common(context)
        if !allHosts { args += ["--host", plan.hostLabel] }
    case .unlock:
        args = ["unlock"] + common(context)
    }

    return ResticInvocation(arguments: args, environment: environment(plan: plan, context: context))
}

private func common(_ context: ResticContext) -> [String] {
    ["--json", "--cache-dir", context.cacheDirectory.path]
}

private func packSize(_ plan: Plan) -> [String] {
    plan.packSizeMiB.map { ["--pack-size", String($0)] } ?? []
}

private func environment(plan: Plan, context: ResticContext) -> [String: String] {
    var env: [String: String] = [:]
    switch plan.repository {
    case .s3:
        if let file = context.credentialsFile { env["AWS_SHARED_CREDENTIALS_FILE"] = file.path }
        env["AWS_PROFILE"] = "restorey-\(plan.id.uuidString)"
    case .raw:
        // Raw values first, so they can never replace the variables set below.
        env = context.rawEnvironment
    }
    env["RESTIC_REPOSITORY"] = plan.repository.resticRepository
    env["RESTIC_PASSWORD_COMMAND"] =
        "\(shellQuoted(context.helperExecutable.path)) print-password --plan \(plan.id.uuidString)"
    env["RESTIC_PROGRESS_FPS"] = "2"
    return env
}

/// Environment variables whose values are shown by `displayCommand`.
private let visibleEnvironment: Set<String> = ["RESTIC_PROGRESS_FPS", "AWS_SHARED_CREDENTIALS_FILE"]

/// A shell-pasteable rendering of an invocation for "Copy as restic command". Every environment
/// value is replaced with `<…>` except the progress rate and file paths, because values may be
/// credentials, or repository URLs containing them.
public func displayCommand(_ inv: ResticInvocation) -> String {
    let env = inv.environment.keys.sorted().map { key -> String in
        let value = visibleEnvironment.contains(key) ? displayQuoted(inv.environment[key] ?? "") : "<…>"
        return "\(key)=\(value)"
    }
    return (env + ["restic"] + inv.arguments.map(displayQuoted)).joined(separator: " ")
}

/// Always single-quoted.
private func shellQuoted(_ s: String) -> String {
    "'" + s.replacing("'", with: "'\\''") + "'"
}

/// Quoted only when the text has characters the shell would treat specially.
private func displayQuoted(_ s: String) -> String {
    let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-")
    return !s.isEmpty && s.allSatisfy(safe.contains) ? s : shellQuoted(s)
}
