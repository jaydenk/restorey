import Foundation
import Testing
@testable import RestoreyCore

struct RepositoryQueuesTests {
    private actor Log {
        var events: [String] = []
        func add(_ e: String) { events.append(e) }
    }

    private struct Boom: Error {}

    @Test func sameRepositorySerialises() async {
        let queues = RepositoryQueues()
        let log = Log()
        await withTaskGroup(of: Void.self) { group in
            for name in ["a", "b"] {
                group.addTask {
                    await queues.run(repository: "k") {
                        await log.add("start \(name)")
                        try? await Task.sleep(for: .milliseconds(80))
                        await log.add("end \(name)")
                    }
                }
                // Enqueue deterministically before the next.
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        let events = await log.events
        #expect(events == ["start a", "end a", "start b", "end b"])
    }

    @Test func differentRepositoriesOverlap() async {
        let queues = RepositoryQueues()
        let log = Log()
        await withTaskGroup(of: Void.self) { group in
            for key in ["one", "two"] {
                group.addTask {
                    await queues.run(repository: key) {
                        await log.add("start \(key)")
                        try? await Task.sleep(for: .milliseconds(150))
                        await log.add("end \(key)")
                    }
                }
            }
        }
        let events = await log.events
        #expect(events.prefix(2).allSatisfy { $0.hasPrefix("start") })
    }

    @Test func fifoOrder() async {
        let queues = RepositoryQueues()
        let log = Log()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    await queues.run(repository: "k") { await log.add("\(i)") }
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        #expect(await log.events == ["0", "1", "2", "3", "4"])
    }

    @Test func throwingJobReleasesQueue() async throws {
        let queues = RepositoryQueues()
        await #expect(throws: Boom.self) {
            try await queues.run(repository: "k") { () async throws -> Int in throw Boom() }
        }
        let value = await queues.run(repository: "k") { 42 }
        #expect(value == 42)
    }

    @Test func returnsValueAndLeavesNoStateBehind() async {
        let queues = RepositoryQueues()
        let value = await queues.run(repository: "k") { "done" }
        #expect(value == "done")
        #expect(await queues.pendingKeyCount == 0)
    }

    // MARK: Cancellation

    @Test func cancelledWaiterStillRunsAndLaterJobsProceed() async {
        let queues = RepositoryQueues()
        let log = Log()
        let blocker = Task {
            await queues.run(repository: "k") {
                await log.add("blocker start")
                try? await Task.sleep(for: .milliseconds(150))
                await log.add("blocker end")
            }
        }
        try? await Task.sleep(for: .milliseconds(30))
        let waiter = Task {
            await queues.run(repository: "k") {
                // Cancellation is delivered to the work; it decides how to react.
                await log.add("waiter cancelled=\(Task.isCancelled)")
            }
        }
        try? await Task.sleep(for: .milliseconds(30))
        waiter.cancel()
        let later = Task { await queues.run(repository: "k") { await log.add("later") } }
        await blocker.value
        await waiter.value
        await later.value
        #expect(await log.events == ["blocker start", "blocker end", "waiter cancelled=true", "later"])
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
