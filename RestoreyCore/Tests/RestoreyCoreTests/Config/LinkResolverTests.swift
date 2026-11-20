import Dispatch
import Synchronization
import Foundation
import Testing
@testable import RestoreyCore

/// Final review round 2: the agent follows links on a thread of its own, raced against a deadline, with one check
/// outstanding at a time, so a volume that doesn't answer can't block the cooperative pool.
struct LinkResolverTests {
    @Test func resolvesWhereEachPathLeads() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("LinkResolverTests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let resolver = LinkResolver(deadline: 3600)
        let resolved = try #require(await resolver.resolve([link.path, real.path]))
        #expect(resolved == [SourcePaths.resolvingLinks(real.path), SourcePaths.resolvingLinks(real.path)])
        #expect(!resolver.gate.isBusy)
    }

    /// The deadline is the subject: the work is held past a tiny deadline until released. The caller gets nil at the
    /// deadline; a second check while the first is still stuck gives up at once without starting any work; once the
    /// held work has really returned, the gate is free again.
    @Test func aCheckPastItsDeadlineGivesUpAndAStuckOneBlocksNoMoreThreads() async {
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let calls = Atomic(0)
        let resolver = LinkResolver(deadline: 0.05) { path in
            if calls.add(1) == 1 {
                entered.signal()
                release.wait()
                finished.signal()
            }
            return path
        }
        #expect(await resolver.resolve(["/Volumes/Gone/repo"]) == nil)
        // Holding the gate means the work's thread was started, but on a busy runner it may not have reached `follow`
        // when the deadline passed (as in MarkedNotForBackupTests.aStuckLookIsNotJoinedByAnother): wait for it to be in
        // the held work before asserting on it or checking again. Only waited for when the gate is held, so a deadline
        // that passed before the work was even admitted fails the test here rather than hanging it.
        guard resolver.gate.isBusy else {
            Issue.record("the deadline passed before the check was admitted, so no work was held")
            return
        }
        await OwnThread.run(named: "test wait", qualityOfService: .utility) { entered.wait() }
        #expect(await resolver.resolve(["/Volumes/Gone/repo"]) == nil)
        #expect(calls.value == 1, "no second thread was started behind the stuck one")

        release.signal()
        await OwnThread.run(named: "test wait", qualityOfService: .utility) { finished.wait() }
        #expect(await eventuallyFree(resolver.gate))
        let unheld = LinkResolver(gate: resolver.gate, deadline: 3600) { $0 }
        #expect(await unheld.resolve(["/a"]) == ["/a"])
    }

    /// `leave()` runs right after `finished.signal()` on the work's thread: poll the gate for it (about two seconds at most).
    private func eventuallyFree(_ gate: OneOutstandingGate) async -> Bool {
        for _ in 0..<2000 where gate.isBusy { try? await Task.sleep(for: .milliseconds(1)) }
        return !gate.isBusy
    }
}

private final class Atomic: Sendable {
    private let state: Mutex<Int>
    init(_ value: Int) { state = Mutex(value) }
    var value: Int { state.withLock { $0 } }
    /// The count after adding.
    func add(_ n: Int) -> Int { state.withLock { $0 += n; return $0 } }
}
