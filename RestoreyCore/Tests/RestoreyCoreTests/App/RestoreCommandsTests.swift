import Foundation
import Testing

@testable import RestoreyCore

/// The restic commands the recovery kit and the Restore Files window give (UI design §5, §7; Review Focus 4).
/// Each one is run through `/bin/sh` here, so what a person pastes into Terminal is what is checked.
@Suite struct RestoreCommandsTests {
    /// Spaces, both quote marks, a non-ASCII letter and a trailing newline.
    static let awkward = "pa ss\"wörd'\n"

    static let planID = UUID()

    static func s3Plan(hostLabel: String = "pepper") -> Plan {
        Plan.newHotPlan(
            name: "Home",
            repository: .s3(S3Location(
                provider: .b2, endpoint: URL(string: "https://s3.us-west-004.backblazeb2.com")!,
                bucket: "my-bucket", prefix: "macs/pepper")),
            origin: .created, hostLabel: hostLabel, sources: ["/Users/me"], exclusions: [], now: Date())
    }

    static func secrets(_ plan: Plan, password: String = awkward, keyID: String = "0045f00dkeyid",
                        secretKey: String = awkward) -> [SecretEntry] {
        [
            SecretEntry(key: .repositoryPassword(plan.id), value: password),
            SecretEntry(key: .s3AccessKeyID(plan.id), value: keyID),
            SecretEntry(key: .s3SecretAccessKey(plan.id), value: secretKey),
        ]
    }

    /// Runs `script` in a clean `/bin/sh` and returns its standard output, byte for byte. The script goes in a
    /// file, not `sh -c`: `Process` passes its arguments in their file-system representation, which decomposes
    /// "ö" (NFD), so an argument would no longer be the bytes a person pastes.
    static func sh(_ script: String, environment: [String: String] = [:]) async throws -> Data {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("restorey-sh-\(UUID().uuidString)")
        try Data(script.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let env = ["PATH=/usr/bin:/bin"] + environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let output = try await Tool.run("/usr/bin/env", ["-i"] + env + ["/bin/sh", file.path])
        #expect(output.status == 0, "sh failed: \(output.stderr)")
        return output.stdout
    }

    // MARK: Quoting

    @Test func shellQuotingRoundTripsByteForByte() async throws {
        let quoted = shellQuoted(Self.awkward)
        let printed = try await Self.sh("printf %s \(quoted)")
        #expect(printed == Data(Self.awkward.utf8))
    }

    @Test func shellQuotingRoundTripsAnEmptyStringAndLoneQuotes() async throws {
        for text in ["", "'", "''", "\\", "$HOME `id` *", "\n"] {
            let printed = try await Self.sh("printf %s \(shellQuoted(text))")
            #expect(printed == Data(text.utf8), "\(text.debugDescription)")
        }
    }

    // MARK: The commands

    @Test func s3CommandsSetTheRepositoryAndKeysThenListAndRestoreThisMacsLatest() throws {
        let plan = Self.s3Plan()
        let commands = RestoreCommands.make(plan: plan, secrets: Self.secrets(plan))
        #expect(commands.map(\.title) == [
            "Tell restic where the repository is", "List this Mac's snapshots",
            "Restore the latest snapshot to Restored in your home folder",
        ])
        #expect(commands[0].revealedText.contains(
            "export RESTIC_REPOSITORY=s3:https://s3.us-west-004.backblazeb2.com/my-bucket/macs/pepper"))
        #expect(commands[0].revealedText.contains("export AWS_ACCESS_KEY_ID=" + shellQuoted("0045f00dkeyid")))
        #expect(commands[1].revealedText == "restic snapshots --host pepper")
        #expect(commands[2].revealedText == "restic restore latest --host pepper --target ~/Restored")
        // Nothing secret in the last two, so they read the same either way.
        #expect(commands[1].text == commands[1].revealedText)
        #expect(commands[2].text == commands[2].revealedText)
    }

    @Test func theRevealedSetupCommandHandsResticEverySecretByteForByte() async throws {
        let plan = Self.s3Plan()
        let setup = RestoreCommands.make(plan: plan, secrets: Self.secrets(plan))[0].revealedText
        for (name, expected) in [
            ("RESTIC_REPOSITORY", "s3:https://s3.us-west-004.backblazeb2.com/my-bucket/macs/pepper"),
            ("AWS_ACCESS_KEY_ID", "0045f00dkeyid"),
            ("AWS_SECRET_ACCESS_KEY", Self.awkward),
            // restic trims what its password command prints, so the repository's password is the trimmed one
            // (`RestoreCommands.resticPassword`); the end-to-end test below opens a real repository with it.
            ("RESTIC_PASSWORD", "pa ss\"wörd'"),
        ] {
            let printed = try await Self.sh(setup + "\nprintf %s \"$\(name)\"")
            #expect(printed == Data(expected.utf8), "\(name)")
        }
    }

    @Test func theMaskedTextHoldsNoSecretValue() {
        let plan = Self.s3Plan()
        let secrets = Self.secrets(plan, password: "correct horse battery", keyID: "0045f00dkeyid",
                                   secretKey: "K005supersecretkey")
        let masked = RestoreCommands.make(plan: plan, secrets: secrets).map(\.text).joined(separator: "\n")
        for secret in secrets { #expect(!masked.contains(secret.value), "\(secret.key.account)") }
        #expect(masked.contains("export RESTIC_PASSWORD=••••••••"))
        #expect(masked.contains("export AWS_SECRET_ACCESS_KEY=••••••••"))
        #expect(masked.contains("export RESTIC_REPOSITORY=s3:https://s3.us-west-004.backblazeb2.com/my-bucket/macs/pepper"))
    }

    @Test func theMaskedTextIsTheSameBeforeTheSecretsAreFetched() {
        let plan = Self.s3Plan()
        let fetched = RestoreCommands.make(plan: plan, secrets: Self.secrets(plan)).map(\.text)
        let before = RestoreCommands.make(plan: plan, secrets: []).map(\.text)
        #expect(before == fetched)
        // A secret that isn't there can't be revealed: it stays dots, never an empty value.
        let unrevealed = RestoreCommands.make(plan: plan, secrets: [])[0].revealedText
        #expect(unrevealed.contains("export RESTIC_PASSWORD=••••••••"))
    }

    @Test func aHostLabelWithSpacesIsQuoted() async throws {
        let plan = Self.s3Plan(hostLabel: "Jayden's MacBook Pro")
        let commands = RestoreCommands.make(plan: plan, secrets: Self.secrets(plan))
        #expect(commands[1].revealedText == "restic snapshots --host " + shellQuoted("Jayden's MacBook Pro"))
        let printed = try await Self.sh("printf %s " + commands[1].revealedText.dropFirst("restic snapshots --host ".count))
        #expect(printed == Data("Jayden's MacBook Pro".utf8))
    }

    @Test func aRawPlanExportsEachEnvironmentVariableInThePlansOrder() async throws {
        let plan = Plan.newHotPlan(
            name: "NAS", repository: .raw(repository: "rest:https://nas.local:8000/mac",
                                          environmentNames: ["RESTIC_REST_USERNAME", "RESTIC_REST_PASSWORD"]),
            origin: .adopted, hostLabel: "pepper", sources: ["/Users/me"], exclusions: [], now: Date())
        let secrets = [
            SecretEntry(key: .repositoryPassword(plan.id), value: "pw"),
            SecretEntry(key: .environment(plan.id, name: "RESTIC_REST_USERNAME"), value: "me"),
            SecretEntry(key: .environment(plan.id, name: "RESTIC_REST_PASSWORD"), value: Self.awkward),
        ]
        let setup = RestoreCommands.make(plan: plan, secrets: secrets)[0]
        #expect(setup.text == """
            export RESTIC_REPOSITORY=rest:https://nas.local:8000/mac
            export RESTIC_PASSWORD=••••••••
            export RESTIC_REST_USERNAME=••••••••
            export RESTIC_REST_PASSWORD=••••••••
            """)
        let printed = try await Self.sh(setup.revealedText + "\nprintf %s \"$RESTIC_REST_PASSWORD\"")
        #expect(printed == Data(Self.awkward.utf8))
    }

    @Test func resticsPasswordIsTheStoredOneWithoutSurroundingWhiteSpace() {
        #expect(RestoreCommands.resticPassword(Self.awkward) == "pa ss\"wörd'")
        #expect(RestoreCommands.resticPassword(" \t pw  word \r\n") == "pw  word")
        // Go's unicode.IsSpace: no-break and ideographic spaces count, a combining mark doesn't.
        #expect(RestoreCommands.resticPassword("\u{00A0}pw\u{3000}") == "pw")
        #expect(RestoreCommands.resticPassword("pw \u{0301}") == "pw \u{0301}")
        #expect(RestoreCommands.resticPassword("plain") == "plain")
    }

    // MARK: End to end

    /// A repository made the way the agent makes one (the password through `RESTIC_PASSWORD_COMMAND`, from the
    /// stored bytes, trailing newline and all), then opened and restored with nothing but the kit's commands,
    /// pasted into a clean shell.
    @Test(.timeLimit(.minutes(2))) func theCommandsRestoreARepositoryResticMadeFromTheStoredPassword() async throws {
        let restic = try TestBinaries.requireRestic()
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("restorey-commands-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let home = root.appendingPathComponent("home")
        let cache = root.appendingPathComponent("cache")
        for dir in [source, home, cache] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data("restored byte for byte\n".utf8).write(to: source.appendingPathComponent("file.txt"))
        let stored = root.appendingPathComponent("stored-password")
        try Data(Self.awkward.utf8).write(to: stored)
        let helper = root.appendingPathComponent("helper.sh")
        try "#!/bin/sh\ncat \(shellQuoted(stored.path))\n".write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let repository = root.appendingPathComponent("repo").path
        let agentLike = [
            "RESTIC_REPOSITORY": repository, "RESTIC_PASSWORD_COMMAND": helper.path, "RESTIC_CACHE_DIR": cache.path,
            "HOME": home.path,
        ]
        _ = try await Self.sh("\(shellQuoted(restic.path)) init -q", environment: agentLike)
        _ = try await Self.sh(
            "\(shellQuoted(restic.path)) backup -q --host 'Jayden'\\''s Mac' \(shellQuoted(source.path))",
            environment: agentLike)

        let plan = Plan.newHotPlan(
            name: "Local", repository: .raw(repository: repository, environmentNames: []), origin: .created,
            hostLabel: "Jayden's Mac", sources: [source.path], exclusions: [], now: Date())
        let commands = RestoreCommands.make(
            plan: plan, secrets: [SecretEntry(key: .repositoryPassword(plan.id), value: Self.awkward)])
        let script = commands.map(\.revealedText).joined(separator: "\n")
        _ = try await Self.sh(script, environment: [
            "HOME": home.path, "RESTIC_CACHE_DIR": cache.path,
            "PATH": restic.deletingLastPathComponent().path + ":/usr/bin:/bin",
        ])

        let restored = home.appendingPathComponent("Restored").appendingPathComponent(source.path)
            .appendingPathComponent("file.txt")
        #expect(try Data(contentsOf: restored) == Data("restored byte for byte\n".utf8))
    }
}
