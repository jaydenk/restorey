import Foundation
import Testing
@testable import RestoreyCore

/// Collects every message a `ResticProcess` reports, and can run actions the first time a message
/// matches. The two reader tasks may call it at once.
final class MessageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [ResticMessage] = []
    private var triggers: [(when: @Sendable (ResticMessage) -> Bool, action: @Sendable () -> Void)] = []

    init() {}

    /// Runs `action` once, on the first message for which `when` is true.
    convenience init(when: @escaping @Sendable (ResticMessage) -> Bool, then action: @escaping @Sendable () -> Void) {
        self.init()
        add(when: when, then: action)
    }

    func add(when: @escaping @Sendable (ResticMessage) -> Bool, then action: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        triggers.append((when, action))
    }

    static let isStatus: @Sendable (ResticMessage) -> Bool = {
        if case .status = $0 { true } else { false }
    }

    /// An unparseable line (restic's own retry notices are plain text) containing `text`.
    static func line(containing text: String) -> @Sendable (ResticMessage) -> Bool {
        { message in
            if case .unparseable(let line) = message { line.contains(text) } else { false }
        }
    }

    func record(_ message: ResticMessage) {
        lock.lock()
        all.append(message)
        let fired = triggers.filter { $0.when(message) }.map(\.action)
        triggers.removeAll { $0.when(message) }
        lock.unlock()
        for action in fired { action() }
    }

    var messages: [ResticMessage] {
        lock.lock(); defer { lock.unlock() }
        return all
    }
}

/// One finished restic run, with the outcome `classify` gives it.
struct Run {
    let termination: ResticTermination
    let messages: [ResticMessage]
    let outcome: RunOutcome
}

/// A scratch directory holding a source tree, a repository, a cache, a home directory and a fake
/// password helper, all siblings, so nothing restic writes lands inside the source tree.
final class TempRepository: @unchecked Sendable {
    static let password = "test-password-not-a-secret"

    let root: URL
    let source: URL
    let repositoryDirectory: URL
    let cache: URL
    let home: URL
    let restic: URL
    let supervisor = SupervisedProcesses()
    private(set) var plan: Plan

    /// - Parameter repository: defaults to a raw local directory in `root`.
    init(repository: Repository? = nil, hostLabel: String = "testhost") throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("restorey-test-\(UUID().uuidString)")
        source = root.appendingPathComponent("source")
        repositoryDirectory = root.appendingPathComponent("repo")
        cache = root.appendingPathComponent("cache")
        home = root.appendingPathComponent("home")
        for dir in [source, cache, home] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        restic = try TestBinaries.requireRestic()
        plan = Plan.newHotPlan(
            name: "Test",
            repository: repository ?? .raw(repository: repositoryDirectory.path, environmentNames: []),
            origin: .created, hostLabel: hostLabel, sources: [source.path], exclusions: [], now: Date()
        )
        #expect(plan.validationErrors().isEmpty)
    }

    func updatePlan(_ change: (inout Plan) -> Void) {
        change(&plan)
    }

    func remove() {
        // Unreadable test files would stop removal.
        chmodTree(root, mode: 0o700)
        try? FileManager.default.removeItem(at: root)
    }

    private func chmodTree(_ url: URL, mode: Int) {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
        for case let item as URL in walker {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: item.path)
        }
    }

    var planID: UUID { plan.id }
    var snapshotTag: String { "restorey:\(plan.id.uuidString)" }

    /// A fake agent: restic runs `RESTIC_PASSWORD_COMMAND` through the shell, and this prints `password`.
    func helper(password: String = TempRepository.password) throws -> URL {
        let url = root.appendingPathComponent("helper-\(password.hashValue.magnitude).sh")
        try "#!/bin/sh\necho '\(password)'\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func context(password: String = TempRepository.password, credentialsFile: URL? = nil) throws -> ResticContext {
        ResticContext(
            cacheDirectory: cache, helperExecutable: try helper(password: password),
            credentialsFile: credentialsFile, rawEnvironment: [:], homeDirectory: home
        )
    }

    func invocation(
        _ op: ResticOperation, password: String = TempRepository.password, credentialsFile: URL? = nil
    ) throws -> ResticInvocation {
        makeInvocation(op, plan: plan, context: try context(password: password, credentialsFile: credentialsFile))
    }

    func process(_ invocation: ResticInvocation, executable: URL? = nil) -> ResticProcess {
        ResticProcess(
            executable: executable ?? restic, invocation: invocation, planID: plan.id,
            supervisor: supervisor, homeDirectory: home
        )
    }

    /// Runs `op` to completion.
    func run(
        _ op: ResticOperation, password: String = TempRepository.password,
        transform: (inout ResticInvocation) -> Void = { _ in }
    ) async throws -> Run {
        var inv = try invocation(op, password: password)
        transform(&inv)
        return try await finish(process(inv), op: op, log: MessageLog())
    }

    func finish(_ process: ResticProcess, op: ResticOperation, log: MessageLog) async throws -> Run {
        let termination = try await process.run { log.record($0) }
        let outcome = classify(
            operation: op, exitCode: termination.exitCode, interruptedByUs: termination.interruptIntent,
            terminatedBySignal: termination.terminatedBySignal, killedByUs: termination.killedByUs, summary: termination.summary,
            errors: termination.messages, exitErrorMessage: termination.exitErrorMessage
        )
        return Run(termination: termination, messages: log.messages, outcome: outcome)
    }

    func initialise() async throws {
        let run = try await run(.initRepository)
        #expect(run.termination.exitCode == 0, "init failed: \(run.termination.stderrTail)")
    }

    /// Plain `--retry-lock` waits make lock tests take minutes; tests strip them.
    static func withoutRetryLock(_ inv: inout ResticInvocation) {
        if let i = inv.arguments.firstIndex(of: "--retry-lock") {
            inv.arguments.removeSubrange(i...(i + 1))
        }
    }

    // MARK: Source data

    /// Writes `count` files of `megabytes` each, of random (incompressible) data, off the cooperative pool.
    func writeRandomFiles(count: Int, megabytes: Int, in directory: URL? = nil) async throws {
        try await Tool.writeRandomFiles(count: count, megabytes: megabytes, in: directory ?? source)
    }

    /// Entries in the repository's `locks/` directory.
    func lockFiles() -> [String] {
        let dir = repositoryDirectory.appendingPathComponent("locks")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }
}

/// An unused TCP port on 127.0.0.1. Another process could take it before it is used; the tests
/// accept that small race.
func freeLocalPort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    guard named == 0 else { throw POSIXError(.EIO) }
    return Int(UInt16(bigEndian: addr.sin_port))
}
