import Foundation
import Testing
@testable import AgentCore

/// The reference count behind the agent's one idle-sleep assertion, against a fake assertion API.
struct SleepPreventionTests {
    final class FakeAssertions: Sendable {
        /// "create <name>" and "release <id>", in order.
        let events = Locked<[String]>([])
        let failCreates = Locked(0)
        private let nextID = Locked<UInt32>(0)

        var api: SleepPrevention.AssertionAPI {
            SleepPrevention.AssertionAPI(
                create: { [self] name in
                    if failCreates.value > 0 {
                        failCreates.mutate { $0 -= 1 }
                        events.mutate { $0.append("create failed") }
                        return nil
                    }
                    nextID.mutate { $0 += 1 }
                    let id = nextID.value
                    events.mutate { $0.append("create \(name) \(id)") }
                    return id
                },
                release: { [self] id in events.mutate { $0.append("release \(id)") } })
        }
    }

    @Test func overlappingRunsShareOneAssertionReleasedByTheLast() {
        let fake = FakeAssertions()
        let prevention = SleepPrevention(api: fake.api)

        prevention.begin()
        prevention.begin()
        #expect(fake.events.value == ["create Restorey backup 1"])
        #expect(prevention.isHeld)

        prevention.end()
        #expect(fake.events.value == ["create Restorey backup 1"])
        #expect(prevention.isHeld)

        prevention.end()
        #expect(fake.events.value == ["create Restorey backup 1", "release 1"])
        #expect(!prevention.isHeld)

        // The next run takes a fresh assertion.
        prevention.begin()
        prevention.end()
        #expect(fake.events.value.suffix(2) == ["create Restorey backup 2", "release 2"])
    }

    @Test func aDeferReleasesAfterARunThatThrows() {
        struct Failure: Error {}
        let fake = FakeAssertions()
        let prevention = SleepPrevention(api: fake.api)
        func run() throws {
            prevention.begin()
            defer { prevention.end() }
            throw Failure()
        }
        #expect(throws: Failure.self) { try run() }
        #expect(fake.events.value == ["create Restorey backup 1", "release 1"])
    }

    @Test func aFailedCreateIsLoggedAndRetriedByTheNextRun() {
        let fake = FakeAssertions()
        fake.failCreates.set(1)
        let logs = Locked<[String]>([])
        let prevention = SleepPrevention(api: fake.api) { line in logs.mutate { $0.append(line) } }

        prevention.begin()
        #expect(!prevention.isHeld)
        prevention.end()
        // Nothing to release.
        #expect(fake.events.value == ["create failed"])
        #expect(logs.value.count == 1)

        prevention.begin()
        #expect(prevention.isHeld)
        prevention.end()
        #expect(fake.events.value == ["create failed", "create Restorey backup 1", "release 1"])
    }

    @Test func anUnbalancedEndIsIgnored() {
        let fake = FakeAssertions()
        let prevention = SleepPrevention(api: fake.api)
        prevention.end()
        prevention.begin()
        #expect(prevention.isHeld)
        prevention.end()
        #expect(fake.events.value == ["create Restorey backup 1", "release 1"])
    }
}
