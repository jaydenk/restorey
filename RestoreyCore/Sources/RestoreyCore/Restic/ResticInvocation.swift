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
    /// The Mac-wide upload limit (`NetworkSettings.uploadLimitKiB`), KiB/s. A backup to a networked
    /// repository gets its share (`effectiveUploadLimitKiB`); every other command and repository ignores it.
    public var macWideUploadLimitKiB: Int?
    /// The backups to networked repositories uploading as this one starts, counting itself.
    public var networkedBackupsRunning: Int
    /// How long the maintenance commands (`forget`, `prune`, `check`, `stats`) wait for a lock another client
    /// holds, as restic's `--retry-lock` duration. Five minutes in the agent; tests shorten it.
    public var maintenanceRetryLock: String
    /// This run's list of items apps mark as not for backup (`MarkedNotForBackup.excludeFile`), passed to `backup` as
    /// `--exclude-file`. Nil when there is nothing to skip: the flag is then left out.
    public var notForBackupExcludeFile: URL?
    /// Where the plan's local repository folder leads once links are followed (`SourcePaths.resolvingLinks`), worked
    /// out by the caller off its actor: a backup excludes it as well as the path as given. Nil when not resolved; the
    /// builder never reads the file system itself (final review I1).
    public var repositoryLinkTarget: String?

    public init(
        cacheDirectory: URL,
        helperExecutable: URL,
        credentialsFile: URL?,
        rawEnvironment: [String: String],
        homeDirectory: URL,
        macWideUploadLimitKiB: Int? = nil,
        networkedBackupsRunning: Int = 1,
        maintenanceRetryLock: String = "5m",
        notForBackupExcludeFile: URL? = nil,
        repositoryLinkTarget: String? = nil
    ) {
        self.cacheDirectory = cacheDirectory
        self.helperExecutable = helperExecutable
        self.credentialsFile = credentialsFile
        self.rawEnvironment = rawEnvironment
        self.homeDirectory = homeDirectory
        self.macWideUploadLimitKiB = macWideUploadLimitKiB
        self.networkedBackupsRunning = networkedBackupsRunning
        self.maintenanceRetryLock = maintenanceRetryLock
        self.repositoryLinkTarget = repositoryLinkTarget
        self.notForBackupExcludeFile = notForBackupExcludeFile
    }
}

/// One restic operation. Persisted in run records, so the JSON is explicit:
/// `{"type":"forget","dryRun":true}`, `{"type":"snapshots","allHosts":false}`, `{"type":"backup"}`,
/// `{"type":"stats"}`, `{"type":"forgetPreview","of":"beforeAdoption"}`, `{"type":"forgetSnapshots","ids":["…"]}`. A build that doesn't
/// know a type drops that record rather than the history.
public enum ResticOperation: Codable, Sendable, Equatable {
    case initRepository
    case backup
    case forget(dryRun: Bool)
    case prune
    case check
    /// `allHosts: true` lists every host's snapshots (adopting a repository) and omits `--host`.
    case snapshots(allHosts: Bool)
    case unlock
    /// `cat config`: reads the repository's config, which exists only once a repository has been
    /// initialised. `createRepository` uses it to tell "exists" (0) from "nothing there" (10).
    case catConfig
    /// `stats --mode raw-data`: the size of the whole repository as stored (Ruling P2-9), every host's
    /// data included. Run after a successful prune and after an adopt.
    case stats
    /// `forget --dry-run --no-lock` with the plan's retention, over a timeline that puts the plan's earlier snapshots
    /// of one kind with its current ones (Task 14b), so retention treats them as the plan's own: for snapshots from
    /// before adoption, every snapshot of the host grouped by `host,paths` (no `--tag`); for previous folder lists, the
    /// plan's own tag grouped by `host,tags` (the folders left out). `EarlierSnapshots` then picks, snapshot by snapshot,
    /// the ones the action is about. Removes nothing and takes no lock, so it is never recorded.
    case forgetPreview(EarlierSnapshotKind)
    /// `forget <ids>`: removes exactly these snapshots, with no policy and no filter (Task 14b). Only ever built from
    /// IDs the user confirmed that a fresh `forgetPreview` still puts in the action's scope (`EarlierSnapshots`). Its
    /// record keeps the IDs restic removed, so the history says exactly what went.
    case forgetSnapshots(ids: [String])

    /// A short, stable, file-name-safe name for this operation, used in run log file names.
    /// Never change an existing value: it would orphan the names of logs already on disk.
    public var logSlug: String {
        switch self {
        case .initRepository: "init"
        case .backup: "backup"
        case .forget(let dryRun): dryRun ? "forget-dry-run" : "forget"
        case .prune: "prune"
        case .check: "check"
        case .snapshots(let allHosts): allHosts ? "snapshots-all-hosts" : "snapshots"
        case .unlock: "unlock"
        case .catConfig: "cat-config"
        case .stats: "stats"
        case .forgetPreview(let kind): "forget-preview-\(kind.rawValue)"
        case .forgetSnapshots: "forget-snapshots"
        }
    }

    private enum CodingKeys: String, CodingKey { case type, dryRun, allHosts, ids, of }

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
        case "catConfig": self = .catConfig
        case "stats": self = .stats
        case "forgetPreview":
            let raw = try c.decode(String.self, forKey: .of)
            guard let kind = EarlierSnapshotKind(rawValue: raw) else {
                throw UnknownCase.error(kind: "earlier snapshot kind", name: raw, in: c, forKey: .of)
            }
            self = .forgetPreview(kind)
        case "forgetSnapshots": self = .forgetSnapshots(ids: try c.decode([String].self, forKey: .ids))
        case let other: throw UnknownCase.error(kind: "restic operation", name: other, in: c, forKey: .type)
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
        case .catConfig: try c.encode("catConfig", forKey: .type)
        case .stats: try c.encode("stats", forKey: .type)
        case .forgetPreview(let kind):
            try c.encode("forgetPreview", forKey: .type)
            try c.encode(kind.rawValue, forKey: .of)
        case .forgetSnapshots(let ids):
            try c.encode("forgetSnapshots", forKey: .type)
            try c.encode(ids, forKey: .ids)
        }
    }
}

/// Builds the restic invocation for `op`.
///
/// Callers must refuse a plan whose `validationErrors()` is non-empty before calling this; the
/// builder does not throw, so an invalid host label or source would reach restic as given.
///
/// Values are joined to their flag with `=` so one starting with `-` is never read as a flag.
///
/// Safety properties, each covered by a test:
/// - `forget` is always limited to this plan's host and `restorey:<id>` tag and never prunes, so it
///   cannot delete snapshots that Restorey did not make. The two exceptions are the user's own, confirmed
///   (Task 14b): `forgetPreview` is a dry run that takes no lock and removes nothing, and `forgetSnapshots`
///   removes only the IDs it is given.
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
        // `--verbose` once is restic's verbosity 2 (0.19.1 `internal/global/global.go`; `--verbose=2` is 3), at which
        // `backup --json` prints a `verbose_status` line per file and folder (`internal/ui/backup/json.go`), for the
        // backup's biggest additions (Task 16d). In JSON mode it prints nothing else.
        args = ["backup"] + common(context) + ["--verbose"]
            + ["--host=\(plan.hostLabel)", "--tag=\(tag)",
               "--skip-if-unchanged", "--exclude-cloud-files", "--exclude-caches"]
            + packSize(plan)
        if plan.oneFileSystem { args.append("--one-file-system") }
        // The Mac-wide limit is for the network (Ruling P2-7): a folder or drive gets the plan's own alone.
        let limit = plan.repository.needsNetwork
            ? effectiveUploadLimitKiB(
                plan: plan.uploadLimitKiB, macWide: context.macWideUploadLimitKiB,
                networkedBackupsRunning: context.networkedBackupsRunning)
            : plan.uploadLimitKiB
        if let limit { args += ["--limit-upload", String(limit)] }
        for pattern in plan.exclusions { args.append("--exclude=\(pattern)") }
        // A local repository is never part of its own backup, however the plan's folders are chosen: left out by the
        // path as given and, if a link leads elsewhere, by the place it leads to (Task 1), which the caller resolved.
        if let repositoryPath = plan.repository.localFolderPath {
            let resolved = context.repositoryLinkTarget.map(SourcePaths.standardised) ?? repositoryPath
            for path in resolved == repositoryPath ? [repositoryPath] : [repositoryPath, resolved] {
                args.append("--exclude=\(DefaultExclusions.pattern(forFolder: path))")
            }
        }
        // Items apps mark as not for backup (Task 15c): literal patterns, one per line, written for this run.
        if let file = context.notForBackupExcludeFile { args.append("--exclude-file=\(file.path)") }
        // A relative pattern matches a whole path component at any depth (restic 0.19.1
        // internal/filter/filter.go), so `*.pvm` also excludes a `.pvm` bundle directory; `--iexclude`
        // lower-cases pattern and path. Invalid entries never get here: the plan fails validation.
        for type in plan.fileTypeExclusions {
            if let ext = Plan.normalisedFileType(type) { args.append("--iexclude=*.\(ext)") }
        }
        args += ["--"] + plan.sources
    case .forget(let dryRun):
        let r = plan.retention
        args = ["forget"] + common(context)
            + ["--host=\(plan.hostLabel)", "--tag=\(tag)", "--group-by", "host,paths,tags",
               "--keep-hourly", String(r.hourly), "--keep-daily", String(r.daily),
               "--keep-weekly", String(r.weekly), "--keep-monthly", String(r.monthly)]
        if dryRun { args.append("--dry-run") }
        args += ["--retry-lock", context.maintenanceRetryLock]
    case .forgetPreview(let kind):
        // `--no-lock` is allowed only with `--dry-run` (restic 0.19.1 cmd_forget.go), and then forget opens the
        // repository without its exclusive lock, so the count can be taken while another client works.
        let r = plan.retention
        let timeline: [String] = switch kind {
        case .beforeAdoption: ["--group-by", "host,paths"]
        case .previousFolderLists: ["--tag=\(tag)", "--group-by", "host,tags"]
        }
        args = ["forget"] + common(context)
            + ["--no-lock", "--dry-run", "--host=\(plan.hostLabel)"] + timeline
            + ["--keep-hourly", String(r.hourly), "--keep-daily", String(r.daily),
               "--keep-weekly", String(r.weekly), "--keep-monthly", String(r.monthly)]
    case .forgetSnapshots(let ids):
        // No policy and no filter: given IDs, restic removes those snapshots and ignores (with a warning) any
        // filter, and skips an ID it can't find ("Ignoring …"), still exiting 0 (restic 0.19.1, verified).
        args = ["forget"] + common(context) + ["--retry-lock", context.maintenanceRetryLock, "--"] + ids
    case .prune:
        args = ["prune"] + common(context) + packSize(plan) + ["--retry-lock", context.maintenanceRetryLock]
    case .check:
        args = ["check"] + common(context) + ["--retry-lock", context.maintenanceRetryLock]
    case .snapshots(let allHosts):
        args = ["snapshots"] + common(context)
        if !allHosts { args.append("--host=\(plan.hostLabel)") }
    case .unlock:
        args = ["unlock"] + common(context)
    case .catConfig:
        args = ["cat", "config"] + common(context)
    case .stats:
        // No `--host`: the size is the repository's, whichever Macs back up to it. A shared lock, so it waits
        // like the maintenance commands rather than failing at once while another client prunes.
        args = ["stats"] + common(context) + ["--mode", "raw-data", "--retry-lock", context.maintenanceRetryLock]
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

/// Always single-quoted: `sh` reads every byte between single quotes as it is, newlines included, and a
/// single quote is written `'\''`. Shared with `RestoreCommands`.
func shellQuoted(_ s: String) -> String {
    "'" + s.replacing("'", with: "'\\''") + "'"
}

/// Quoted only when the text has characters the shell would treat specially. Shared with `RestoreCommands`.
func displayQuoted(_ s: String) -> String {
    let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-")
    return !s.isEmpty && s.allSatisfy(safe.contains) ? s : shellQuoted(s)
}
