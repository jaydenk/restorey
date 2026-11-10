import Foundation
import Testing
@testable import RestoreyCore

struct ResticProcessTests {
    private struct Snapshot: Decodable {
        let id: String
        let hostname: String
        let tags: [String]?
    }

    /// `snapshots --json` prints one JSON array, which the message parser reports as an unparseable line.
    private func snapshots(in run: Run) throws -> [Snapshot] {
        for case .unparseable(let line) in run.messages where line.hasPrefix("[") {
            return try JSONDecoder().decode([Snapshot].self, from: Data(line.utf8))
        }
        return []
    }

    /// Writes an executable script into `repo`'s scratch directory.
    private func script(
        _ body: String, in repo: TempRepository, name: String = "fake-restic", interpreter: String = "/bin/sh"
    ) throws -> URL {
        let url = repo.root.appendingPathComponent(name)
        try "#!\(interpreter)\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func initBackupSnapshotsRoundTrip() async throws {
        let repo = try TempRepository()
        defer { repo.remove() }
        try repo.writeRandomFiles(count: 5, megabytes: 1)

        try await repo.initialise()
        let backup = try await repo.run(.backup)
        #expect(backup.termination.exitCode == 0, "\(backup.termination.stderrTail)")
        let snapshotID = try #require(backup.termination.summary?.snapshotID)
        #expect(backup.outcome == .success(snapshotID: snapshotID))
        #expect(backup.termination.summary?.totalFilesProcessed == 5)

        let listing = try await repo.run(.snapshots(allHosts: false))
        #expect(listing.outcome == .success(snapshotID: nil))
        let listed = try snapshots(in: listing)
        #expect(listed.count == 1)
        #expect(listed.first?.id.hasPrefix(String(snapshotID.prefix(8))) == true)
        #expect(listed.first?.hostname == "testhost")
        #expect(listed.first?.tags == [repo.snapshotTag])
    }

    @Test func progressMessagesStream() async throws {
        let repo = try TempRepository()
        defer { repo.remove() }
        // Throttled, so the backup lasts long enough for restic to report progress before it finishes.
        try repo.writeRandomFiles(count: 3, megabytes: 10)
        repo.updatePlan { $0.uploadLimitKiB = 10_000 }
        try await repo.initialise()

        let backup = try await repo.run(.backup)
        #expect(backup.outcome != .failed(exitCode: 1, reason: ""))
        let statusIndex = backup.messages.firstIndex { if case .status = $0 { true } else { false } }
        let summaryIndex = backup.messages.firstIndex { if case .summary = $0 { true } else { false } }
        let status = try #require(statusIndex, "no status message in \(backup.messages.count) messages")
        let summary = try #require(summaryIndex)
        #expect(status < summary)
    }

    @Test func environmentIsNotInherited() async throws {
        let repo = try TempRepository()
        defer { repo.remove() }
        setenv("RESTOREY_LEAK", "1", 1)
        defer { unsetenv("RESTOREY_LEAK") }
        // A stand-in for restic that prints the environment it was given.
        let fake = try script("exec /usr/bin/env", in: repo)
        var inv = try repo.invocation(.backup)
        inv.arguments.append("--dry-run")

        let run = try await repo.finish(repo.process(inv, executable: fake), op: .backup, log: MessageLog())
        var seen: [String: String] = [:]
        for case .unparseable(let line) in run.messages {
            guard let equals = line.firstIndex(of: "=") else { continue }
            seen[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        #expect(seen["RESTOREY_LEAK"] == nil)
        #expect(seen["HOME"] == repo.home.path)
        #expect(seen["PATH"] == "/usr/bin:/bin")
        for (key, value) in inv.environment { #expect(seen[key] == value, "\(key) missing or changed") }
        // Whatever else is there was added by the shell or the system, not inherited from the test.
        let allowed = Set(inv.environment.keys).union(["HOME", "PATH", "PWD", "OLDPWD", "SHLVL", "_", "__CF_USER_TEXT_ENCODING"])
        #expect(Set(seen.keys).subtracting(allowed).isEmpty, "unexpected: \(Set(seen.keys).subtracting(allowed))")
    }

    @Test func interruptSendsSIGINTThenSIGKILL() async throws {
        let repo = try TempRepository()
        defer { repo.remove() }
        // Ignores SIGINT, so only SIGKILL stops it. perl sets the disposition itself, so this holds
        // whatever signal dispositions the test runner passed down.
        let stubborn = try script(
            "$| = 1; $SIG{INT} = 'IGNORE'; print \"ready\\n\"; sleep 1000;", in: repo, interpreter: "/usr/bin/perl")
        let process = repo.process(try repo.invocation(.backup), executable: stubborn)

        let (ready, readyContinuation) = AsyncStream<Void>.makeStream()
        let log = MessageLog()
        let running = Task {
            try await process.run {
                log.record($0)
                readyContinuation.yield()
            }
        }
        var readyIterator = ready.makeAsyncIterator()
        await readyIterator.next()

        let interruptedAt = ContinuousClock.now
        await process.interrupt(.pause)
        let termination = try await running.value
        let elapsed = ContinuousClock.now - interruptedAt

        #expect(elapsed > .seconds(9.5), "killed after \(elapsed), before the 10 s grace period")
        #expect(elapsed < .seconds(10.5), "took \(elapsed) to kill")
        #expect(termination.interruptIntent == .pause)
        #expect(termination.terminatedBySignal == SIGKILL)
        #expect(termination.exitCode == 128 + SIGKILL)
        // Ruling R12: still a pause, not a failure.
        let outcome = classify(
            operation: .backup, exitCode: termination.exitCode, interruptedByUs: termination.interruptIntent,
            terminatedBySignal: termination.terminatedBySignal, summary: nil, errors: [], exitErrorMessage: nil)
        #expect(outcome == .paused)
    }

    @Test func interruptHonouredBeforeTheGracePeriodIsNotKilled() async throws {
        let repo = try TempRepository()
        defer { repo.remove() }
        let polite = try script(
            "$| = 1; $SIG{INT} = sub { exit 130 }; print \"ready\\n\"; sleep 1000;", in: repo, interpreter: "/usr/bin/perl")
        let process = repo.process(try repo.invocation(.backup), executable: polite)

        let (ready, readyContinuation) = AsyncStream<Void>.makeStream()
        let running = Task { try await process.run { _ in readyContinuation.yield() } }
        var readyIterator = ready.makeAsyncIterator()
        await readyIterator.next()

        let interruptedAt = ContinuousClock.now
        await process.interrupt(.cancel)
        let termination = try await running.value
        #expect(ContinuousClock.now - interruptedAt < .seconds(5))
        #expect(termination.exitCode == 130)
        #expect(termination.terminatedBySignal == nil)
        #expect(termination.interruptIntent == .cancel)
    }

    @Test func pidIsSupervisedOnlyWhileRunning() async throws {
        let repo = try TempRepository()
        defer { repo.remove() }
        let sleeper = try script("echo ready\nexec /bin/sleep 1000", in: repo)
        let process = repo.process(try repo.invocation(.backup), executable: sleeper)
        #expect(await repo.supervisor.all().isEmpty)

        let (ready, readyContinuation) = AsyncStream<Void>.makeStream()
        let running = Task { try await process.run { _ in readyContinuation.yield() } }
        var readyIterator = ready.makeAsyncIterator()
        await readyIterator.next()

        // The first message has arrived, so the pid was recorded before it.
        let pids = await repo.supervisor.all()
        #expect(pids.count == 1)
        let pid = try #require(pids.first)
        #expect(await repo.supervisor.isSupervised(pid: pid, planID: repo.planID))
        #expect(await !repo.supervisor.isSupervised(pid: pid, planID: UUID()))

        await process.interrupt(.cancel)
        let termination = try await running.value
        #expect(termination.pid == pid)
        #expect(await !repo.supervisor.isSupervised(pid: pid, planID: repo.planID))
        #expect(await repo.supervisor.all().isEmpty)
    }

    @Test func aProcessRunsOnlyOnce() async throws {
        let repo = try TempRepository()
        defer { repo.remove() }
        let quick = try script("exit 0", in: repo)
        let process = repo.process(try repo.invocation(.unlock), executable: quick)
        _ = try await process.run { _ in }
        await #expect(throws: ResticProcessError.alreadyStarted) { try await process.run { _ in } }
    }

    @Test func trailingOutputIsNotLostWhenTheProcessExits() async throws {
        let repo = try TempRepository()
        defer { repo.remove() }
        // Writes a lot to both streams and exits at once; every line must still arrive.
        let chatty = try script(
            "i=0\nwhile [ $i -lt 5000 ]; do echo \"out $i\"; echo \"err $i\" >&2; i=$((i+1)); done\n"
                + "echo '{\"message_type\":\"exit_error\",\"code\":1,\"message\":\"last words\"}' >&2\nexit 1",
            in: repo)
        let run = try await repo.finish(
            repo.process(try repo.invocation(.check), executable: chatty), op: .check, log: MessageLog())
        #expect(run.messages.count == 10_001)
        #expect(run.termination.exitErrorMessage == "last words")
        #expect(run.termination.stderrTail.count == 20)
        #expect(run.termination.stderrTail.last?.contains("last words") == true)
    }
}
