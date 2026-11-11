import Foundation
import Testing
@testable import RestoreyCore

struct ResticInvocationTests {
    private static let s3 = S3Location(
        provider: .b2,
        endpoint: URL(string: "https://s3.us-west-004.backblazeb2.com")!,
        bucket: "bucket",
        prefix: "mac"
    )
    private static let context = ResticContext(
        cacheDirectory: URL(fileURLWithPath: "/Users/x/Library/Caches/Restorey/restic"),
        helperExecutable: URL(fileURLWithPath: "/Applications/Restorey.app/Contents/MacOS/restorey-agent"),
        credentialsFile: URL(fileURLWithPath: "/Users/x/Library/Application Support/Restorey/credentials"),
        rawEnvironment: [:],
        homeDirectory: URL(fileURLWithPath: "/Users/x")
    )
    private static let cache = "/Users/x/Library/Caches/Restorey/restic"

    private func plan(
        _ repository: Repository? = nil,
        origin: RepositoryOrigin = .created,
        exclusions: [String] = ["/Users/x/Library/Caches", "**/node_modules"]
    ) -> Plan {
        var p = Plan.newHotPlan(
            name: "Home", repository: repository ?? .s3(Self.s3), origin: origin, hostLabel: "pepper",
            sources: ["/Users/x/Documents", "/Users/x/-drafts", "/Users/x/Café Notes"],
            exclusions: exclusions, now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        p.id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        return p
    }

    private var tag: String { "restorey:11111111-2222-3333-4444-555555555555" }

    private func inv(_ op: ResticOperation, _ plan: Plan? = nil, _ context: ResticContext? = nil) -> ResticInvocation {
        makeInvocation(op, plan: plan ?? self.plan(), context: context ?? Self.context)
    }

    @Test func backupArguments() {
        let p = plan()
        #expect(inv(.backup, p).arguments == [
            "backup", "--json", "--cache-dir", Self.cache, "--host=pepper", "--tag=\(tag)",
            "--skip-if-unchanged", "--exclude-cloud-files", "--exclude-caches", "--pack-size", "64",
            "--one-file-system", "--exclude=/Users/x/Library/Caches", "--exclude=**/node_modules",
        ] + DefaultExclusions.fileTypes.map { "--iexclude=*.\($0)" } + [
            "--", "/Users/x/Documents", "/Users/x/-drafts", "/Users/x/Café Notes",
        ])
    }

    @Test func adoptedBackupOmitsPackSize() {
        let args = inv(.backup, plan(origin: .adopted)).arguments
        #expect(!args.contains("--pack-size"))
    }

    @Test func uploadLimitAddsLimitUpload() {
        var p = plan()
        p.uploadLimitKiB = 500
        let args = inv(.backup, p).arguments
        let i = args.firstIndex(of: "--limit-upload")
        #expect(i != nil)
        #expect(i.map { args[$0 + 1] } == "500")
        // Options must come before the "--" that ends them.
        #expect(i! < args.firstIndex(of: "--")!)
        #expect(!inv(.backup, plan()).arguments.contains("--limit-upload"))
    }

    @Test func sourcesAfterSeparatorEvenWhenTheyLookLikeFlags() {
        let args = inv(.backup).arguments
        let sep = args.firstIndex(of: "--")!
        #expect(args[(sep + 1)...].contains("/Users/x/-drafts"))
        #expect(!args[..<sep].contains("/Users/x/-drafts"))
    }

    @Test func leadingDashValuesCannotBeReadAsFlags() {
        var p = plan(exclusions: ["-foo"])
        p.fileTypeExclusions = []
        p.hostLabel = "-host"
        p.sources = ["-drafts"] // not a valid plan; builder-only check
        #expect(inv(.backup, p).arguments == [
            "backup", "--json", "--cache-dir", Self.cache, "--host=-host", "--tag=\(tag)",
            "--skip-if-unchanged", "--exclude-cloud-files", "--exclude-caches", "--pack-size", "64",
            "--one-file-system", "--exclude=-foo", "--", "-drafts",
        ])
        #expect(inv(.snapshots(allHosts: false), p).arguments.contains("--host=-host"))
        #expect(inv(.forget(dryRun: false), p).arguments.contains("--host=-host"))
    }

    @Test func validationErrors() {
        #expect(plan().validationErrors() == [])
        var p = plan()
        p.hostLabel = " \t"
        #expect(p.validationErrors() == [.emptyHostLabel])
        p = plan(); p.hostLabel = ""
        #expect(p.validationErrors() == [.emptyHostLabel])
        p = plan(); p.sources = []
        #expect(p.validationErrors() == [.noSources])
        p = plan(); p.sources = ["/ok", "rel/path", "-drafts"]
        #expect(p.validationErrors() == [.relativeSource("rel/path"), .relativeSource("-drafts")])
    }

    @Test func forgetIsScopedToRestoreyTagAndHost() {
        let args = inv(.forget(dryRun: false)).arguments
        #expect(args == [
            "forget", "--json", "--cache-dir", Self.cache, "--host=pepper", "--tag=\(tag)",
            "--group-by", "host,paths,tags",
            "--keep-hourly", "24", "--keep-daily", "30", "--keep-weekly", "52", "--keep-monthly", "120",
            "--retry-lock", "5m",
        ])
        #expect(!args.contains("--prune"))
        #expect(!args.contains("--dry-run"))
    }

    @Test func forgetUsesPlanRetention() {
        var p = plan()
        p.retention = Retention(hourly: 1, daily: 2, weekly: 3, monthly: 4)
        let args = inv(.forget(dryRun: false), p).arguments
        #expect(args.contains("1") && args.contains("2") && args.contains("3") && args.contains("4"))
        let i = args.firstIndex(of: "--keep-monthly")!
        #expect(args[i + 1] == "4")
    }

    @Test func forgetDryRunAddsDryRun() {
        let args = inv(.forget(dryRun: true)).arguments
        #expect(args.contains("--dry-run"))
        #expect(args.contains("--tag=\(tag)"))
        #expect(!args.contains("--prune"))
    }

    @Test func pruneAndCheckRetryLock() {
        #expect(inv(.prune).arguments.starts(with: ["prune", "--json", "--cache-dir", Self.cache]))
        #expect(inv(.prune).arguments.contains("--retry-lock"))
        #expect(inv(.check).arguments == ["check", "--json", "--cache-dir", Self.cache, "--retry-lock", "5m"])
    }

    @Test func pruneUsesPackSizeWhenSet() {
        let args = inv(.prune).arguments
        let i = args.firstIndex(of: "--pack-size")
        #expect(i.map { args[$0 + 1] } == "64")
        #expect(!inv(.prune, plan(origin: .adopted)).arguments.contains("--pack-size"))
    }

    @Test func retryLockOnlyOnMaintenanceCommands() {
        for op in [ResticOperation.backup, .initRepository, .snapshots(allHosts: false), .snapshots(allHosts: true), .unlock, .catConfig] {
            #expect(!inv(op).arguments.contains("--retry-lock"), "\(op)")
        }
    }

    @Test func everyOperationPassesJSONAndCacheDirectory() {
        let ops: [ResticOperation] = [
            .initRepository, .backup, .forget(dryRun: false), .forget(dryRun: true), .prune, .check,
            .snapshots(allHosts: false), .snapshots(allHosts: true), .unlock, .catConfig,
        ]
        for op in ops {
            let args = inv(op).arguments
            #expect(args.contains("--json"), "\(op)")
            let i = args.firstIndex(of: "--cache-dir")
            #expect(i.map { args[$0 + 1] } == Self.cache, "\(op)")
        }
    }

    @Test func snapshotsScopedToHostUnlessAllHosts() {
        #expect(inv(.snapshots(allHosts: false)).arguments == [
            "snapshots", "--json", "--cache-dir", Self.cache, "--host=pepper",
        ])
        let all = inv(.snapshots(allHosts: true)).arguments
        #expect(all == ["snapshots", "--json", "--cache-dir", Self.cache])
        #expect(!all.contains("--host"))
    }

    @Test func initIsPlain() {
        #expect(inv(.initRepository).arguments == ["init", "--json", "--cache-dir", Self.cache])
        #expect(inv(.catConfig).arguments == ["cat", "config", "--json", "--cache-dir", Self.cache])
    }

    @Test func unlockNeverRemovesAll() {
        let args = inv(.unlock).arguments
        #expect(args == ["unlock", "--json", "--cache-dir", Self.cache])
        #expect(!args.contains("--remove-all"))
    }

    @Test func s3EnvironmentHasNoAWSKeys() {
        let env = inv(.backup).environment
        let aws = env.keys.filter { $0.hasPrefix("AWS_") }.sorted()
        #expect(aws == ["AWS_PROFILE", "AWS_SHARED_CREDENTIALS_FILE"])
        #expect(env["AWS_PROFILE"] == "restorey-11111111-2222-3333-4444-555555555555")
        #expect(env["AWS_SHARED_CREDENTIALS_FILE"] == "/Users/x/Library/Application Support/Restorey/credentials")
        #expect(env["RESTIC_REPOSITORY"] == "s3:https://s3.us-west-004.backblazeb2.com/bucket/mac")
        #expect(env["RESTIC_PROGRESS_FPS"] == "2")
    }

    @Test func passwordCommandNamesPlan() {
        let env = inv(.backup).environment
        #expect(env["RESTIC_PASSWORD_COMMAND"]
            == "'/Applications/Restorey.app/Contents/MacOS/restorey-agent' print-password --plan 11111111-2222-3333-4444-555555555555")
        // Never a literal password.
        #expect(env["RESTIC_PASSWORD"] == nil)
        #expect(env["RESTIC_PASSWORD_FILE"] == nil)
    }

    @Test func rawEnvironmentMergesButCannotOverrideCoreVariables() {
        let raw = Repository.raw(repository: "rest:http://nas/repo", environmentNames: ["RESTIC_REST_USERNAME"])
        let ctx = ResticContext(
            cacheDirectory: Self.context.cacheDirectory, helperExecutable: Self.context.helperExecutable,
            credentialsFile: nil,
            rawEnvironment: [
                "RESTIC_REST_USERNAME": "u", "RESTIC_REST_PASSWORD": "p",
                "RESTIC_REPOSITORY": "evil", "RESTIC_PASSWORD_COMMAND": "evil",
            ],
            homeDirectory: Self.context.homeDirectory
        )
        let env = inv(.backup, plan(raw), ctx).environment
        #expect(env["RESTIC_REST_USERNAME"] == "u")
        #expect(env["RESTIC_REST_PASSWORD"] == "p")
        #expect(env["RESTIC_REPOSITORY"] == "rest:http://nas/repo")
        #expect(env["RESTIC_PASSWORD_COMMAND"]?.contains("print-password") == true)
        #expect(!env.keys.contains("AWS_PROFILE"))
        #expect(!env.keys.contains("AWS_SHARED_CREDENTIALS_FILE"))
    }

    @Test func rawEnvironmentIsIgnoredForS3Plans() {
        let ctx = ResticContext(
            cacheDirectory: Self.context.cacheDirectory, helperExecutable: Self.context.helperExecutable,
            credentialsFile: Self.context.credentialsFile, rawEnvironment: ["AWS_SECRET_ACCESS_KEY": "s"],
            homeDirectory: Self.context.homeDirectory
        )
        #expect(!inv(.backup, nil, ctx).environment.keys.contains("AWS_SECRET_ACCESS_KEY"))
    }

    @Test func displayCommandHidesValues() {
        let raw = Repository.raw(repository: "rest:https://user:hunter2@nas/repo", environmentNames: ["TOKEN"])
        let ctx = ResticContext(
            cacheDirectory: Self.context.cacheDirectory, helperExecutable: Self.context.helperExecutable,
            credentialsFile: nil, rawEnvironment: ["TOKEN": "s3cr3t-token"], homeDirectory: Self.context.homeDirectory
        )
        let text = displayCommand(inv(.backup, plan(raw), ctx))
        #expect(!text.contains("hunter2"))
        #expect(!text.contains("s3cr3t-token"))
        #expect(text.contains("TOKEN=<…>"))
        #expect(text.contains("RESTIC_REPOSITORY=<…>"))
        #expect(text.contains("RESTIC_PROGRESS_FPS=2"))
        #expect(text.contains(" restic backup "))

        let s3 = displayCommand(inv(.backup))
        #expect(s3.contains("AWS_SHARED_CREDENTIALS_FILE='/Users/x/Library/Application Support/Restorey/credentials'"))
        #expect(s3.contains("AWS_PROFILE=<…>"))
        #expect(s3.contains("'/Users/x/Café Notes'"))
    }

    // MARK: Codable

    @Test func operationGoldenJSON() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func json(_ op: ResticOperation) throws -> String {
            String(decoding: try encoder.encode(op), as: UTF8.self)
        }
        #expect(try json(.initRepository) == #"{"type":"initRepository"}"#)
        #expect(try json(.backup) == #"{"type":"backup"}"#)
        #expect(try json(.forget(dryRun: true)) == #"{"dryRun":true,"type":"forget"}"#)
        #expect(try json(.prune) == #"{"type":"prune"}"#)
        #expect(try json(.check) == #"{"type":"check"}"#)
        #expect(try json(.snapshots(allHosts: false)) == #"{"allHosts":false,"type":"snapshots"}"#)
        #expect(try json(.unlock) == #"{"type":"unlock"}"#)
        #expect(try json(.catConfig) == #"{"type":"catConfig"}"#)
    }

    @Test func operationRoundTripsAndRejectsUnknown() throws {
        let ops: [ResticOperation] = [
            .initRepository, .backup, .forget(dryRun: false), .forget(dryRun: true), .prune, .check,
            .snapshots(allHosts: false), .snapshots(allHosts: true), .unlock, .catConfig,
        ]
        for op in ops {
            let data = try JSONEncoder().encode(op)
            #expect(try JSONDecoder().decode(ResticOperation.self, from: data) == op)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ResticOperation.self, from: Data(#"{"type":"wipe"}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ResticOperation.self, from: Data(#"{"type":"forget"}"#.utf8))
        }
    }

    // MARK: Default exclusions

    /// Ruling R64a: the decided folder list, resolved against the given home and nothing else (the
    /// Time Machine plist reader is gone, so nothing is read from the real system).
    @Test func defaultExclusionsAreResolvedAgainstGivenHome() {
        let paths = DefaultExclusions.paths(home: URL(fileURLWithPath: "/Users/test"))
        let h = "/Users/test"
        #expect(paths == [
            "\(h)/Library/Caches", "\(h)/.Trash", "**/node_modules",
            "\(h)/Library/Containers/com.docker.docker/Data/vms",
            "\(h)/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data",
            "\(h)/Library/Logs", "\(h)/Library/Metadata/CoreSpotlight", "\(h)/Library/Mobile Documents/.Trash",
            "\(h)/Library/Saved Application State", "\(h)/Library/Developer/Xcode/DerivedData",
            "\(h)/Library/Developer/CoreSimulator", "\(h)/Library/Suggestions", "\(h)/Library/Biome",
            "\(h)/Library/Trial", "\(h)/Library/Application Support/CloudDocs/session/db",
            "**/Mail/V*/MailData/Envelope Index*", "\(h)/.cache", "\(h)/.npm",
            "\(h)/Library/Containers/*/Data/Library/Caches", "\(h)/Library/Group Containers/*/Library/Caches",
            "\(h)/Library/Application Support/FileProvider/*/wharf",
            "\(h)/Library/Group Containers/group.com.apple.secure-control-center-preferences",
        ])
        // The owner keeps logs and project build folders: none of these become defaults.
        for unwanted in ["*.log", "**/.venv", "**/Pods", "**/target", "**/.build"] {
            #expect(!paths.contains(unwanted))
        }
    }

    @Test func everyDefaultIsUnderTheHomeOrAnyDepthPattern() {
        let paths = DefaultExclusions.paths(home: URL(fileURLWithPath: "/Users/nobody"))
        #expect(paths.allSatisfy { $0.hasPrefix("/Users/nobody/") || $0.hasPrefix("**/") })
    }

    /// restic matches with Go's `filepath.Match`, so a home path's own glob characters are escaped and
    /// match only themselves (the real-restic check is in `ResticInvocationAcceptanceTests`).
    @Test func globCharactersInTheHomePathAreEscaped() {
        #expect(DefaultExclusions.escapedGlob("/Users/a[b]*?\\c") == "/Users/a\\[b\\]\\*\\?\\\\c")
        let paths = DefaultExclusions.paths(home: URL(fileURLWithPath: "/Users/x[1]"))
        #expect(paths.first == "/Users/x\\[1\\]/Library/Caches")
        #expect(paths.contains("/Users/x\\[1\\]/Library/Containers/*/Data/Library/Caches"))
        #expect(DefaultExclusions.escapedGlob("/Users/Jo Smith") == "/Users/Jo Smith")
    }

    // MARK: File types and filesystems (Ruling R64b, R64c)

    @Test func defaultFileTypes() {
        #expect(DefaultExclusions.fileTypes == [
            "dmg", "iso", "sparseimage",
            "vmdk", "vhd", "vhdx", "vdi", "qcow2", "hdd", "hds", "pvm", "pvs", "pvi", "pva", "fdd", "vmc",
            "vmx", "vmxf", "vmsn", "vmsd", "vmem", "nvram", "mem", "vsv",
        ])
        for kept in ["log", "o", "exe", "dll", "sparsebundle"] { #expect(!DefaultExclusions.fileTypes.contains(kept)) }
        #expect(DefaultExclusions.fileTypes.allSatisfy { Plan.normalisedFileType($0) == $0 })
    }

    @Test func fileTypesBecomeCaseInsensitiveExcludesBeforeTheSources() {
        var p = plan()
        p.fileTypeExclusions = ["dmg", " VMDK "]
        let args = inv(.backup, p).arguments
        let types = args.filter { $0.hasPrefix("--iexclude=") }
        #expect(types == ["--iexclude=*.dmg", "--iexclude=*.vmdk"])
        #expect(args.firstIndex(of: "--iexclude=*.vmdk")! < args.firstIndex(of: "--")!)
        // A new plan carries the default list.
        #expect(inv(.backup).arguments.filter { $0.hasPrefix("--iexclude=") }.count == DefaultExclusions.fileTypes.count)
        p.fileTypeExclusions = []
        #expect(!inv(.backup, p).arguments.contains { $0.hasPrefix("--iexclude") })
    }

    @Test func invalidFileTypesFailValidation() {
        for bad in ["", "  ", ".dmg", "a/b", "*.iso", "v?mdk", "[ab]", "x\\y", "two words"] {
            var p = plan()
            p.fileTypeExclusions = ["dmg", bad]
            #expect(p.validationErrors() == [.invalidFileType(bad)], "\(bad)")
        }
        var p = plan()
        p.fileTypeExclusions = ["DMG", " iso", "tar.gz"]
        #expect(p.validationErrors().isEmpty)
    }

    @Test func oneFileSystemByDefaultAndOffWhenTurnedOff() {
        var p = plan()
        #expect(p.oneFileSystem)
        let args = inv(.backup, p).arguments
        #expect(args.contains("--one-file-system"))
        #expect(args.firstIndex(of: "--one-file-system")! < args.firstIndex(of: "--")!)
        p.oneFileSystem = false
        #expect(!inv(.backup, p).arguments.contains("--one-file-system"))
        // Only backup takes it.
        #expect(!inv(.forget(dryRun: false)).arguments.contains("--one-file-system"))
    }
}
