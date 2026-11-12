import Foundation
import Testing
@testable import RestoreyCore

@Suite struct RunLogStoreTests {
    private static func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("logs-\(UUID().uuidString)", isDirectory: true)
    }

    private static func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int ?? 0) & 0o777
    }

    private static func lines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private static var utcStamp: Regex<Substring> { #/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z /# }

    // MARK: Run logs

    @Test func writesRedactedLines() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RunLogStore(root: root, subsystem: "com.example.test")
        let writer = try await store.begin(
            planID: UUID(), operation: .backup, startedAt: Date(),
            redactor: Redactor(secrets: ["hunter2-secret"]))
        writer.line("password is hunter2-secret ok")
        writer.close()
        let content = try String(contentsOf: writer.fileURL, encoding: .utf8)
        #expect(content.contains("password is [redacted] ok"))
        #expect(!content.contains("hunter2-secret"))
        #expect(try Self.lines(writer.fileURL).first?.firstMatch(of: Self.utcStamp) != nil)
    }

    @Test func fileNameIsUTC() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let planID = UUID()
        // 2026-11-10T01:02:03Z, which is the 10th in UTC but the 9th in the US and 12:32 in Adelaide.
        let started = Date(timeIntervalSince1970: 1_794_272_523)
        let store = RunLogStore(root: root, subsystem: "com.example.test")
        let writer = try await store.begin(
            planID: planID, operation: .forget(dryRun: true), startedAt: started,
            redactor: Redactor(secrets: []))
        writer.close()
        #expect(writer.fileURL.lastPathComponent == "20261110T010203Z-forget-dry-run.log")
        #expect(writer.fileURL.deletingLastPathComponent().lastPathComponent == planID.uuidString)
        #expect(writer.fileURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "runs")
    }

    @Test func operationSlugsAreStable() {
        let slugs: [(ResticOperation, String)] = [
            (.initRepository, "init"), (.backup, "backup"), (.forget(dryRun: false), "forget"),
            (.forget(dryRun: true), "forget-dry-run"), (.prune, "prune"), (.check, "check"),
            (.snapshots(allHosts: false), "snapshots"),
            (.snapshots(allHosts: true), "snapshots-all-hosts"), (.unlock, "unlock"), (.catConfig, "cat-config"),
        ]
        for (operation, slug) in slugs { #expect(operation.logSlug == slug) }
        #expect(Set(slugs.map(\.1)).count == slugs.count)
    }

    @Test func logDirectoryCreatedWithUserOnlyPermissions() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let planID = UUID()
        let writer = try await RunLogStore(root: root, subsystem: "com.example.test").begin(
            planID: planID, operation: .backup, startedAt: Date(), redactor: Redactor(secrets: []))
        writer.line("x")
        writer.close()
        #expect(try Self.mode(root) == 0o700)
        #expect(try Self.mode(root.appendingPathComponent("runs")) == 0o700)
        #expect(try Self.mode(root.appendingPathComponent("runs/\(planID.uuidString)")) == 0o700)
        #expect(try Self.mode(writer.fileURL) == 0o600)
    }

    @Test func concurrentWritersProduceIntactLines() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try await RunLogStore(root: root, subsystem: "com.example.test").begin(
            planID: UUID(), operation: .backup, startedAt: Date(), redactor: Redactor(secrets: []))
        DispatchQueue.concurrentPerform(iterations: 2) { thread in
            for i in 0..<1_000 { writer.line("thread\(thread) line\(i) " + String(repeating: "x", count: 100)) }
        }
        writer.close()
        let lines = try Self.lines(writer.fileURL)
        #expect(lines.count == 2_000)
        let intact = #/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z thread[01] line\d+ x{100}$/#
        #expect(lines.allSatisfy { $0.wholeMatch(of: intact) != nil })
        for thread in 0..<2 {
            #expect(lines.filter { $0.contains("thread\(thread) ") }.count == 1_000)
        }
    }

    @Test func lineAfterCloseIsIgnored() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try await RunLogStore(root: root, subsystem: "com.example.test").begin(
            planID: UUID(), operation: .check, startedAt: Date(), redactor: Redactor(secrets: []))
        writer.line("before")
        writer.close()
        writer.line("after")
        writer.close()
        #expect(try Self.lines(writer.fileURL).count == 1)
    }

    // MARK: Pruning

    @Test func pruneRemovesOlderThan400Days() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RunLogStore(root: root, subsystem: "com.example.test")
        let now = Date()
        let fm = FileManager.default

        let planA = UUID(), planB = UUID()
        func make(_ plan: UUID, _ slug: String, ageDays: Double) async throws -> URL {
            let writer = try await store.begin(
                planID: plan, operation: slug == "check" ? .check : .backup,
                startedAt: now.addingTimeInterval(-ageDays * 86_400), redactor: Redactor(secrets: []))
            writer.line("x")
            writer.close()
            try fm.setAttributes(
                [.modificationDate: now.addingTimeInterval(-ageDays * 86_400)],
                ofItemAtPath: writer.fileURL.path)
            return writer.fileURL
        }
        let oldBackup = try await make(planA, "backup", ageDays: 401)
        let oldCheck = try await make(planA, "check", ageDays: 500)
        let recent = try await make(planA, "backup", ageDays: 399)
        let onlyOld = try await make(planB, "backup", ageDays: 450)

        // A file outside runs/ is never touched, however old.
        let appLog = root.appendingPathComponent("agent.log")
        try Data("x".utf8).write(to: appLog)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-900 * 86_400)], ofItemAtPath: appLog.path)

        let removed = try await store.prune(now: now)
        #expect(removed == 3)
        #expect(!fm.fileExists(atPath: oldBackup.path))
        #expect(!fm.fileExists(atPath: oldCheck.path))
        #expect(!fm.fileExists(atPath: onlyOld.path))
        #expect(fm.fileExists(atPath: recent.path))
        #expect(fm.fileExists(atPath: appLog.path))
        // Plan B's folder is now empty and goes; plan A's still holds a recent log.
        #expect(!fm.fileExists(atPath: onlyOld.deletingLastPathComponent().path))
        #expect(fm.fileExists(atPath: recent.deletingLastPathComponent().path))
    }

    @Test func pruneRemovesPreExistingEmptyPlanFolders() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("runs/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(try await RunLogStore(root: root, subsystem: "com.example.test").prune(now: Date()) == 0)
        #expect(!FileManager.default.fileExists(atPath: empty.path))
    }

    @Test func pruneWithNoRunsFolderIsANoOp() async throws {
        let root = Self.tempRoot()
        #expect(try await RunLogStore(root: root, subsystem: "com.example.test").prune(now: Date()) == 0)
    }

    // MARK: App log

    private static func appLog(_ root: URL, maxBytes: Int = 10_000_000, redactor: Redactor = Redactor(secrets: [])) -> AppLog {
        AppLog(root: root, kind: .agent, subsystem: "com.example.test", redactor: redactor, maxBytes: maxBytes)
    }

    @Test func appLogWritesRedactedStampedLevelledLines() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = Self.appLog(root, redactor: Redactor(secrets: ["s3cret-value"]))
        log.info("started s3cret-value")
        log.error("failed")
        let url = root.appendingPathComponent("agent.log")
        let lines = try Self.lines(url)
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix(" INFO started [redacted]"))
        #expect(lines[1].hasSuffix(" ERROR failed"))
        #expect(lines.allSatisfy { $0.firstMatch(of: Self.utcStamp) != nil })
        #expect(try Self.mode(root) == 0o700)
        #expect(try Self.mode(url) == 0o600)
    }

    @Test func rotatesAt10MB() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let limit = 300
        let log = Self.appLog(root, maxBytes: limit)
        for i in 0..<60 { log.info("line \(String(format: "%03d", i))") }

        let fm = FileManager.default
        func file(_ suffix: String) -> URL { root.appendingPathComponent("agent.log" + suffix) }
        for n in 1...5 { #expect(fm.fileExists(atPath: file(".\(n)").path), "missing .\(n)") }
        #expect(!fm.fileExists(atPath: file(".6").path))
        for suffix in ["", ".1", ".2", ".3", ".4", ".5"] {
            let size = try fm.attributesOfItem(atPath: file(suffix).path)[.size] as? Int ?? 0
            #expect(size <= limit && size > 0)
            #expect(try Self.mode(file(suffix)) == 0o600)
        }
        // Newer content is in lower-numbered files, and the newest line is in agent.log.
        let newest = try Self.lines(file("")).last ?? ""
        #expect(newest.hasSuffix("line 059"))
        let firstOf1 = try Self.lines(file(".1")).first ?? ""
        let firstOf2 = try Self.lines(file(".2")).first ?? ""
        #expect(firstOf2 < firstOf1 || firstOf2.split(separator: " ").last! < firstOf1.split(separator: " ").last!)
    }

    @Test func rotationContinuesFromAnExistingFile() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Self.appLog(root, maxBytes: 200)
        first.info("one")
        // A new process picks up the existing file's size and rotates when it fills.
        let second = Self.appLog(root, maxBytes: 200)
        for i in 0..<10 { second.info("second \(i)") }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("agent.log.1").path))
    }

    @Test func appLogToleratesConcurrentWriters() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = Self.appLog(root)
        DispatchQueue.concurrentPerform(iterations: 4) { t in
            for i in 0..<250 { log.info("t\(t) \(i)") }
        }
        #expect(try Self.lines(root.appendingPathComponent("agent.log")).count == 1_000)
    }

    // MARK: Failures are surfaced, never thrown

    @Test func runLogWriteFailureSetsFlagWithoutThrowing() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try await RunLogStore(root: root, subsystem: "com.example.test").begin(
            planID: UUID(), operation: .backup, startedAt: Date(), redactor: Redactor(secrets: []))
        writer.line("fine")
        #expect(!writer.hadWriteFailure)
        writer.breakDescriptorForTesting()
        writer.line("lost one")
        writer.line("lost two")
        #expect(writer.hadWriteFailure)
        #expect(writer.droppedLineCount == 2)
        #expect(try Self.lines(writer.fileURL).count == 1)
    }

    @Test func appLogWriteFailureSetsFlagWithoutThrowing() throws {
        let root = Self.tempRoot()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let log = Self.appLog(root)
        log.info("fine")
        #expect(!log.hadWriteFailure)
        // Delete the file and take away the right to recreate it.
        try FileManager.default.removeItem(at: root.appendingPathComponent("agent.log"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        log.info("lost")
        #expect(log.hadWriteFailure)
        #expect(log.droppedLineCount == 1)
        // Once permission returns, logging recovers.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        log.info("back")
        #expect(try Self.lines(root.appendingPathComponent("agent.log")).count == 1)
    }

    // MARK: Shared sink and external changes

    @Test func twoAppLogInstancesRotateTogetherWithoutLosingLines() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = Self.appLog(root, maxBytes: 300)
        let b = Self.appLog(root, maxBytes: 300)
        for i in 0..<20 { (i.isMultiple(of: 2) ? a : b).info("line \(String(format: "%02d", i))") }
        var seen: [String] = []
        for suffix in ["", ".1", ".2", ".3", ".4", ".5"] {
            let url = root.appendingPathComponent("agent.log" + suffix)
            if FileManager.default.fileExists(atPath: url.path) { seen += try Self.lines(url) }
        }
        #expect(seen.count == 20)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("agent.log.1").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("agent.log.6").path))
    }

    @Test func externallyDeletedAppLogIsRecreated() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = Self.appLog(root)
        log.info("before")
        let url = root.appendingPathComponent("agent.log")
        try FileManager.default.removeItem(at: url)
        log.info("after")
        let lines = try Self.lines(url)
        #expect(lines.count == 1)
        #expect(lines[0].hasSuffix("after"))
        #expect(!log.hadWriteFailure)
    }

    @Test func externallyRotatedAppLogReopens() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = Self.appLog(root)
        log.info("one")
        let url = root.appendingPathComponent("agent.log")
        try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("agent.log.1"))
        log.info("two")
        #expect(try Self.lines(url).count == 1)
        #expect(try Self.lines(root.appendingPathComponent("agent.log.1")).count == 1)
    }

    // MARK: Same-second runs

    @Test func sameSecondRunsGetTheirOwnFiles() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RunLogStore(root: root, subsystem: "com.example.test")
        let planID = UUID()
        let started = Date(timeIntervalSince1970: 1_794_272_523)
        let first = try await store.begin(planID: planID, operation: .backup, startedAt: started, redactor: Redactor(secrets: []))
        let second = try await store.begin(planID: planID, operation: .backup, startedAt: started, redactor: Redactor(secrets: []))
        let third = try await store.begin(planID: planID, operation: .backup, startedAt: started, redactor: Redactor(secrets: []))
        first.line("a"); second.line("b"); third.line("c")
        [first, second, third].forEach { $0.close() }
        #expect(first.fileURL.lastPathComponent == "20261110T010203Z-backup.log")
        #expect(second.fileURL.lastPathComponent == "20261110T010203Z-backup-2.log")
        #expect(third.fileURL.lastPathComponent == "20261110T010203Z-backup-3.log")
        #expect(try Self.lines(first.fileURL).count == 1)
        #expect(try Self.lines(second.fileURL).last?.hasSuffix(" b") == true)
    }

    // MARK: Pruning keeps going

    @Test func pruneContinuesPastAFileItCannotRemove() async throws {
        let root = Self.tempRoot()
        let fm = FileManager.default
        let store = RunLogStore(root: root, subsystem: "com.example.test")
        let now = Date()
        let lockedPlan = UUID(), openPlan = UUID()
        var files: [URL] = []
        for plan in [lockedPlan, openPlan] {
            let writer = try await store.begin(
                planID: plan, operation: .backup, startedAt: now, redactor: Redactor(secrets: []))
            writer.close()
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-500 * 86_400)], ofItemAtPath: writer.fileURL.path)
            files.append(writer.fileURL)
        }
        // A read-only plan folder means its file cannot be unlinked.
        let lockedDir = files[0].deletingLastPathComponent()
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: lockedDir.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockedDir.path)
            try? fm.removeItem(at: root)
        }
        let removed = try await store.prune(now: now)
        #expect(removed == 1)
        #expect(fm.fileExists(atPath: files[0].path))
        #expect(!fm.fileExists(atPath: files[1].path))
    }
}
