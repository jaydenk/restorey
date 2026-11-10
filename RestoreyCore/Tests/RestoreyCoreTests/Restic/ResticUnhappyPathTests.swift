import Foundation
import Testing
@testable import RestoreyCore

/// The failures spec §10 lists, run against the vendored restic. Each asserts what `classify` makes
/// of the run, since that is what the user is told.
struct ResticUnhappyPathTests {
    private struct Snapshot: Decodable { let id: String }

    private func snapshotCount(_ repo: TempRepository) async throws -> Int {
        let listing = try await repo.run(.snapshots(allHosts: true))
        for case .unparseable(let line) in listing.messages where line.hasPrefix("[") {
            return try JSONDecoder().decode([Snapshot].self, from: Data(line.utf8)).count
        }
        return 0
    }

    private final class LockedBox<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); defer { lock.unlock() }; stored = newValue }
        }
    }

    /// Starts `op` and runs `action` when the first message matching `when` arrives.
    private func runUntil(
        _ op: ResticOperation, in repo: TempRepository,
        when: @escaping @Sendable (ResticMessage) -> Bool,
        _ action: @escaping @Sendable (ResticProcess) -> Void
    ) async throws -> Run {
        let process = repo.process(try repo.invocation(op))
        let log = MessageLog(when: when) { action(process) }
        return try await repo.finish(process, op: op, log: log)
    }

    // MARK: Repository and credentials

    @Test(.timeLimit(.minutes(1))) func wrongPasswordIs12() async throws {
        let repo = try TempRepository()
        defer { repo.remove() }
        try await repo.initialise()

        let run = try await repo.run(.snapshots(allHosts: false), password: "not-the-password")
        #expect(run.termination.exitCode == 12)
        #expect(run.outcome == .wrongPassword)
    }

    @Test(.timeLimit(.minutes(1))) func missingRepositoryIs10() async throws {
        let repo = try TempRepository() // never initialised
        defer { repo.remove() }

        let run = try await repo.run(.snapshots(allHosts: false))
        #expect(run.termination.exitCode == 10)
        #expect(run.outcome == .repositoryMissing)
    }

    // MARK: Locks

    @Test(.timeLimit(.minutes(1))) func staleLockBlocksCheckThenPlainUnlockClears() async throws {
        let repo = try TempRepository()
        defer { repo.remove() }
        try repo.writeRandomFiles(count: 6, megabytes: 20)
        repo.updatePlan { $0.uploadLimitKiB = 20_000 } // keeps the backup running while we kill it
        try await repo.initialise()

        // kill -9 mid-backup: restic cannot remove its lock.
        let supervisor = repo.supervisor
        let backup = try await runUntil(.backup, in: repo, when: MessageLog.isStatus) { _ in
            Task { for pid in await supervisor.all() { kill(pid, SIGKILL) } }
        }
        #expect(backup.termination.terminatedBySignal == SIGKILL)
        guard case .failed = backup.outcome else {
            Issue.record("a backup killed by a signal we did not send must be a failure, got \(backup.outcome)")
            return
        }
        #expect(!repo.lockFiles().isEmpty, "kill -9 left no lock behind")

        // The plan's `check` waits up to five minutes for a lock; a test should not.
        let blocked = try await repo.run(.check, transform: TempRepository.withoutRetryLock)
        #expect(blocked.termination.exitCode == 11, "check: \(blocked.termination.stderrTail)")
        #expect(blocked.outcome == .locked)

        let unlock = try await repo.run(.unlock)
        #expect(unlock.termination.exitCode == 0, "unlock: \(unlock.termination.stderrTail)")
        #expect(repo.lockFiles().isEmpty)

        let check = try await repo.run(.check, transform: TempRepository.withoutRetryLock)
        #expect(check.termination.exitCode == 0, "check: \(check.termination.stderrTail)")
    }

    /// Records what restic does with its lock when it is sent SIGINT during a real backup (the open
    /// item in docs/spike-findings.md). The assertions below are the observed behaviour.
    @Test(.timeLimit(.minutes(1))) func sigintDuringRealBackupLock() async throws {
        let repo = try TempRepository()
        defer { repo.remove() }
        try repo.writeRandomFiles(count: 10, megabytes: 30) // 300 MB of random data
        repo.updatePlan { $0.uploadLimitKiB = 20_000 } // about 15 s, so the signal lands mid-backup
        try await repo.initialise()

        // Note which lock files exist when the signal is sent, so an empty directory afterwards
        // means restic removed them rather than never made them.
        let locksAtInterrupt = LockedBox<[String]>([])
        let backup = try await runUntil(.backup, in: repo, when: MessageLog.isStatus) { process in
            locksAtInterrupt.value = repo.lockFiles()
            Task { await process.interrupt(.pause) }
        }
        #expect(locksAtInterrupt.value.count == 1, "expected restic's own lock while it ran: \(locksAtInterrupt.value)")
        #expect(backup.termination.exitCode == 130, "\(backup.termination.stderrTail)")
        #expect(backup.termination.terminatedBySignal == nil, "restic should exit on SIGINT, not be killed")
        #expect(backup.outcome == .paused)
        #expect(backup.termination.summary == nil)

        let locks = repo.lockFiles()
        // RECORDED: see docs/spike-findings.md, "SIGINT during a real backup".
        #expect(locks.isEmpty, "restic left lock files after SIGINT: \(locks)")
    }

    // MARK: Network and server

    /// restic retries a refused connection with growing delays for up to 15 minutes before it gives
    /// up, so this test does not wait for `.failed`. It shows that restic is retrying and says so on
    /// stderr, and that stopping the run then is a cancel, not a failure.
    @Test(.timeLimit(.minutes(1))) func unreachableRestServerRetriesAndReportsOnStderr() async throws {
        let port = try freeLocalPort() // nothing listens on it
        let repo = try TempRepository(repository: .raw(repository: "rest:http://127.0.0.1:\(port)/", environmentNames: []))
        defer { repo.remove() }

        let run = try await runUntil(.snapshots(allHosts: false), in: repo, when: MessageLog.line(containing: "retrying")) { process in
            Task { await process.interrupt(.cancel) }
        }
        #expect(run.termination.stderrTail.contains { $0.contains("connection refused") }, "\(run.termination.stderrTail)")
        #expect(run.outcome == .cancelled)
    }

    /// An answer that is not a retryable error is a prompt `.failed`: here the server refuses access.
    @Test(.timeLimit(.minutes(1))) func restServerThatRefusesAccessFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("restorey-rs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        // An empty .htpasswd turns authentication on and lets nobody in.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent(".htpasswd"))
        let server = try RestServer(directory: directory, authentication: true)
        defer { server.stop() }
        let repo = try TempRepository(repository: .raw(repository: server.repository, environmentNames: []))
        defer { repo.remove() }

        let run = try await repo.run(.snapshots(allHosts: false))
        guard case .failed(let code, _) = run.outcome else {
            Issue.record("expected .failed, got \(run.outcome)")
            return
        }
        #expect(code == 1)
        #expect(!run.termination.stderrTail.isEmpty)
    }

    /// Kills rest-server after the first status. restic retries each failed request for up to 15
    /// minutes, so the run neither succeeds nor fails promptly. This test shows that it does not
    /// complete as a success or unchanged run while the server is gone, and that restic says why.
    @Test(.timeLimit(.minutes(1))) func restServerDiesMidBackupIsNeverSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("restorey-rs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try RestServer(directory: directory)
        defer { server.stop() }
        let repo = try TempRepository(repository: .raw(repository: server.repository, environmentNames: []))
        defer { repo.remove() }
        try repo.writeRandomFiles(count: 6, megabytes: 20)
        repo.updatePlan { $0.uploadLimitKiB = 20_000 }
        try await repo.initialise()

        let process = repo.process(try repo.invocation(.backup))
        let log = MessageLog(when: MessageLog.isStatus) { server.stop() }
        // Once the server is gone restic starts to complain; stop it when it does.
        log.add(when: MessageLog.line(containing: "retrying")) { Task { await process.interrupt(.cancel) } }
        let run = try await repo.finish(process, op: .backup, log: log)

        #expect(run.termination.summary == nil)
        #expect(run.outcome != .unchanged)
        if case .success = run.outcome { Issue.record("a backup that lost its server reported success") }
        let tail = run.termination.stderrTail.joined(separator: "\n")
        #expect(["connection refused", "connection reset", "EOF", "broken pipe"].contains { tail.contains($0) },
                "no cause on stderr: \(tail)")
        #expect(run.outcome == .cancelled)
    }

    // MARK: Disk and files

    @Test(.timeLimit(.minutes(3))) func fullDiskFails() async throws {
        let disk = try RamDisk(megabytes: 64)
        defer { disk.detach() }
        let repo = try TempRepository(
            repository: .raw(repository: disk.mountPoint.appendingPathComponent("repo").path, environmentNames: []))
        defer { repo.remove() }
        try repo.writeRandomFiles(count: 4, megabytes: 30) // 120 MB onto a 64 MB disk
        try await repo.initialise()

        let run = try await repo.run(.backup)
        guard case .failed = run.outcome else {
            Issue.record("expected .failed, got \(run.outcome): \(run.termination.stderrTail)")
            return
        }
        #expect(run.termination.stderrTail.joined(separator: "\n").lowercased().contains("no space left"),
                "\(run.termination.stderrTail)")
    }

    @Test(.timeLimit(.minutes(1))) func unreadableFileIsWarning() async throws {
        let repo = try TempRepository()
        defer { repo.remove() }
        try repo.writeRandomFiles(count: 3, megabytes: 1)
        let locked = repo.source.appendingPathComponent("locked.txt")
        try "secret".write(to: locked, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        try await repo.initialise()

        let run = try await repo.run(.backup)
        #expect(run.termination.exitCode == 3)
        #expect(run.outcome == .warning(unreadable: 1))
        #expect(run.termination.messages.first?.item?.hasSuffix("locked.txt") == true)
        #expect(try await snapshotCount(repo) == 1, "a partial backup still saves a snapshot")
    }

    // MARK: Cloud

    private static let b2Endpoint = ProcessInfo.processInfo.environment["RESTOREY_B2_TEST_ENDPOINT"]
    private static let b2Bucket = ProcessInfo.processInfo.environment["RESTOREY_B2_TEST_BUCKET"]
    private static let b2Configured = [b2Endpoint, b2Bucket].allSatisfy { !($0 ?? "").isEmpty }

    /// Needs `RESTOREY_B2_TEST_ENDPOINT` and `RESTOREY_B2_TEST_BUCKET`. The key is made up here and is
    /// not valid anywhere, so no secret is involved. It reaches restic through `credential_process`,
    /// as in production, and is shaped like a B2 key ID (a malformed one is rejected with a
    /// different message).
    ///
    /// B2 refuses the key at once, but restic treats that as a transient error and retries with
    /// growing delays for up to 15 minutes before it exits. So this test does not wait for `.failed`.
    /// It shows that restic does not hang silently: within 120 s it reports the rejection on
    /// stderr, the run can be stopped, and stopping it is a cancel, never a success.
    @Test(.enabled(if: b2Configured, "set RESTOREY_B2_TEST_ENDPOINT and RESTOREY_B2_TEST_BUCKET"),
          .timeLimit(.minutes(2)))
    func b2WrongKeyIsRejectedAndRetried() async throws {
        let location = S3Location(
            provider: .b2, endpoint: try #require(URL(string: Self.b2Endpoint ?? "")),
            bucket: Self.b2Bucket ?? "", prefix: "task6-wrongkey")
        let repo = try TempRepository(repository: .s3(location))
        defer { repo.remove() }

        // Prints a made-up key with an expiry, which minio-go needs to avoid asking again at once.
        // minio-go splits the credential_process line on spaces and wants at least two arguments.
        let helper = repo.root.appendingPathComponent("wrong-key.sh")
        let expiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        try """
            #!/bin/sh
            echo '{"Version":1,"AccessKeyId":"004123456789abc0000000001","SecretAccessKey":"notarealsecretnotarealsecret0000000000","Expiration":"\(expiry)"}'
            """.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let credentials = repo.root.appendingPathComponent("credentials")
        try "[restorey-\(repo.planID.uuidString)]\ncredential_process = \(helper.path) s3-credentials --plan \(repo.planID.uuidString)\n"
            .write(to: credentials, atomically: true, encoding: .utf8)

        let started = ContinuousClock.now
        let op = ResticOperation.snapshots(allHosts: false)
        let process = repo.process(try repo.invocation(op, credentialsFile: credentials))
        let log = MessageLog(when: MessageLog.line(containing: "retrying")) {
            Task { await process.interrupt(.cancel) }
        }
        let run = try await repo.finish(process, op: op, log: log)

        #expect(ContinuousClock.now - started < .seconds(120))
        #expect(run.termination.stderrTail.contains { $0.contains("is not valid") }, "\(run.termination.stderrTail)")
        #expect(run.outcome == .cancelled)
    }
}
