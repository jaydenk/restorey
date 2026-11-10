import Foundation
import Testing
@testable import RestoreyCore

struct RepositoryQueuesTests {
    private actor Log {
        var events: [String] = []
        func add(_ e: String) { events.append(e) }
    }

    private struct Boom: Error {}

    /// One-shot gate: `wait()` suspends until `open()`; no wall-clock involved.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private struct Typed: Error, Equatable { let code: Int }

    @Test(.timeLimit(.minutes(1))) func sameRepositorySerialises() async {
        let queues = RepositoryQueues()
        let log = Log()
        let aStarted = Gate(), release = Gate()
        let a = await queues.enqueue(repository: "k") {
            await log.add("start a")
            await aStarted.open()
            await release.wait()
            await log.add("end a")
        }
        let b = await queues.enqueue(repository: "k") {
            await log.add("start b")
            await log.add("end b")
        }
        await aStarted.wait()
        await release.open()
        await a.value()
        await b.value()
        #expect(await log.events == ["start a", "end a", "start b", "end b"])
    }

    @Test(.timeLimit(.minutes(1))) func differentRepositoriesOverlap() async {
        let queues = RepositoryQueues()
        let bStarted = Gate()
        // A can only finish once B has started, so serialising them would hang the test.
        let a = await queues.enqueue(repository: "one") { await bStarted.wait() }
        let b = await queues.enqueue(repository: "two") { await bStarted.open() }
        await a.value()
        await b.value()
    }

    @Test(.timeLimit(.minutes(1))) func fifoOrder() async {
        let queues = RepositoryQueues()
        let log = Log()
        let release = Gate()
        var jobs: [RepositoryQueues.Job<Void, Never>] = []
        for i in 0..<5 {
            jobs.append(await queues.enqueue(repository: "k") {
                if i == 0 { await release.wait() }
                await log.add("\(i)")
            })
        }
        await release.open()
        for job in jobs { await job.value() }
        #expect(await log.events == ["0", "1", "2", "3", "4"])
    }

    @Test(.timeLimit(.minutes(1))) func throwingJobReleasesQueue() async throws {
        let queues = RepositoryQueues()
        await #expect(throws: Boom.self) {
            try await queues.run(repository: "k") { () async throws -> Int in throw Boom() }
        }
        let value = await queues.run(repository: "k") { 42 }
        #expect(value == 42)
    }

    @Test(.timeLimit(.minutes(1))) func typedErrorComesBackUnchanged() async {
        let queues = RepositoryQueues()
        do throws(Typed) {
            _ = try await queues.run(repository: "k") { () async throws(Typed) -> Int in throw Typed(code: 7) }
            Issue.record("expected a throw")
        } catch {
            #expect(error == Typed(code: 7))
        }
    }

    @Test(.timeLimit(.minutes(1))) func returnsValueAndLeavesNoStateBehind() async {
        let queues = RepositoryQueues()
        let value = await queues.run(repository: "k") { "done" }
        #expect(value == "done")
        #expect(await queues.pendingKeyCount == 0)
    }

    @Test(.timeLimit(.minutes(1))) func longSynchronousJobDoesNotBlockAnotherKey() async {
        let queues = RepositoryQueues()
        let log = Log()
        let aStarted = Gate()
        let a = await queues.enqueue(repository: "A") {
            await aStarted.open()
            for _ in 0..<30 { usleep(10_000) }  // ~300 ms of blocking, synchronous work
            await log.add("A end")
        }
        await aStarted.wait()
        // Were A's work on the actor, this call would not return until A had finished.
        let b = await queues.enqueue(repository: "B") { await log.add("B start") }
        await b.value()
        await a.value()
        #expect(await log.events == ["B start", "A end"])
    }

    // MARK: Cancellation

    @Test(.timeLimit(.minutes(1))) func cancelledWaiterStillRunsAndLaterJobsProceed() async {
        let queues = RepositoryQueues()
        let log = Log()
        let release = Gate()
        let blocker = await queues.enqueue(repository: "k") {
            await release.wait()
            await log.add("blocker")
        }
        let waiter = await queues.enqueue(repository: "k") {
            // Cancellation is delivered to the work; it decides how to react.
            await log.add("waiter cancelled=\(Task.isCancelled)")
        }
        // This is exactly what a cancelled caller's `value()` does.
        waiter.cancel()
        let later = await queues.enqueue(repository: "k") { await log.add("later") }
        await release.open()
        await blocker.value()
        await waiter.value()
        await later.value()
        #expect(await log.events == ["blocker", "waiter cancelled=true", "later"])
    }

    @Test(.timeLimit(.minutes(1))) func cancellingTheCallerDoesNotWedgeTheQueue() async {
        let queues = RepositoryQueues()
        let release = Gate()
        let blocker = await queues.enqueue(repository: "k") { await release.wait() }
        let caller = Task { await queues.run(repository: "k") { 1 } }
        caller.cancel()
        let later = await queues.enqueue(repository: "k") { 2 }
        await release.open()
        await blocker.value()
        #expect(await caller.value == 1)
        #expect(await later.value() == 2)
    }

    // MARK: Keys

    @Test func twoPlansSameBucketShareKey() {
        let upper = Repository.raw(
            repository: "s3:https://S3.us-west-004.backblazeb2.com/b/p/", environmentNames: [])
        let lower = Repository.raw(
            repository: "s3:https://s3.us-west-004.backblazeb2.com/b/p", environmentNames: [])
        #expect(RepositoryQueues.key(for: upper) == RepositoryQueues.key(for: lower))
    }

    @Test func s3LocationAndEquivalentRawShareKey() {
        let location = S3Location(
            provider: .b2, endpoint: URL(string: "https://S3.us-west-004.backblazeb2.com")!,
            bucket: "b", prefix: "p")
        let raw = Repository.raw(
            repository: "s3:https://s3.us-west-004.backblazeb2.com/b/p/", environmentNames: [])
        #expect(RepositoryQueues.key(for: .s3(location)) == RepositoryQueues.key(for: raw))
    }

    @Test func schemeLessS3NormalisesToHTTPS() {
        func key(_ s: String) -> String {
            RepositoryQueues.key(for: .raw(repository: s, environmentNames: []))
        }
        let location = S3Location(
            provider: .s3, endpoint: URL(string: "https://s3.amazonaws.com")!, bucket: "Bucket", prefix: "")
        let expected = RepositoryQueues.key(for: .s3(location))
        #expect(key("s3:S3.Amazonaws.com/Bucket") == expected)
        #expect(key("s3:https://s3.amazonaws.com/Bucket") == expected)
        #expect(key("s3:s3.amazonaws.com/Bucket/") == expected)
        #expect(key("s3:s3.amazonaws.com/bucket") != expected)
    }

    @Test func defaultPortsAreStripped() {
        func key(_ s: String) -> String {
            RepositoryQueues.key(for: .raw(repository: s, environmentNames: []))
        }
        #expect(key("s3:https://Host.example:443/b/p") == key("s3:https://host.example/b/p"))
        #expect(key("s3:host.example:443/b/p") == key("s3:https://host.example/b/p"))
        #expect(key("s3:http://host.example:80/b") == key("s3:http://host.example/b"))
        #expect(key("s3:https://host.example:9000/b") != key("s3:https://host.example/b"))
        #expect(key("s3:http://host.example:443/b") != key("s3:http://host.example/b"))
    }

    @Test func pathCaseIsSignificant() {
        func key(_ s: String) -> String {
            RepositoryQueues.key(for: .raw(repository: s, environmentNames: []))
        }
        #expect(key("s3:https://s3.example.com/Bucket/Prefix") != key("s3:https://s3.example.com/bucket/prefix"))
        #expect(key("s3:https://s3.example.com/b/Prefix") != key("s3:https://s3.example.com/b/prefix"))
    }

    @Test func unrecognisedShapesOnlyLoseTrailingSlash() {
        func key(_ s: String) -> String {
            RepositoryQueues.key(for: .raw(repository: s, environmentNames: []))
        }
        #expect(key("sftp:User@Host:/Srv/Restic/") == "sftp:User@Host:/Srv/Restic")
        #expect(key("rest:https://Host.example/Repo/") == "rest:https://Host.example/Repo")
        #expect(key("/Volumes/Backup/Repo/") == "/Volumes/Backup/Repo")
        #expect(key("/") == "/")
    }
}
