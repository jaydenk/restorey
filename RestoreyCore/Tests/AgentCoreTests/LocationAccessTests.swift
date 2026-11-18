import Dispatch
import Foundation
import RestoreyCore
import Testing
@testable import AgentCore

/// The agent's Location logic (`LocationAccess`) against a fake Core Location: Location Services off for the Mac
/// answers at once and never asks, an undecided agent asks once, and a locationd that doesn't answer can't hold a
/// reply past its bound. Nothing here touches Core Location.
///
/// The bounds sleep on a `ManualClock` that only the test moves (task 18), so a reply that comes "at the bound" is
/// one the test let the bound decide, and one that comes "at once" came with the clock still: neither depends on how
/// soon the scheduler wakes a sleeper. A reply that wrongly waited for a bound the clock never reaches would never
/// come, and the suite's time limit fails it.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LocationAccessTests {
    final class FakeLocation: Sendable {
        let servicesOn = Locked(true)
        let status = Locked(LocationAuthorisation.notDetermined)
        let servicesReads = Locked(0)
        let statusReads = Locked(0)
        let requests = Locked(0)
        /// While set, a services read blocks until it is signalled (a locationd that doesn't answer).
        let hang = Locked<DispatchSemaphore?>(nil)

        var api: LocationAccess.API {
            LocationAccess.API(
                servicesEnabled: { [self] in
                    servicesReads.mutate { $0 += 1 }
                    hang.value?.wait()
                    return servicesOn.value
                },
                status: { [self] in
                    statusReads.mutate { $0 += 1 }
                    return status.value
                },
                requestWhenInUse: { [self] in requests.mutate { $0 += 1 } })
        }
    }

    private static func access(
        _ fake: FakeLocation, requestBound: Duration = .seconds(30), servicesBound: Duration = .seconds(5),
        clock: ManualClock = ManualClock()
    ) -> LocationAccess {
        LocationAccess(api: fake.api, requestBound: requestBound, servicesBound: servicesBound, clock: clock)
    }

    // MARK: Location Services off for the Mac (Task 15 deferral, fix round 1 M2, M6)

    @Test func servicesOffAnswersAtOnceAndNeverAsks() async {
        let fake = FakeLocation()
        fake.servicesOn.set(false)
        let access = Self.access(fake)
        // The clock never moves: the reply comes without waiting out either bound.
        let reply = await access.request()
        #expect(reply == LocationPermissionReply(authorised: false, status: "notDetermined", servicesEnabled: false))
        #expect(fake.requests.value == 0, "requestWhenInUseAuthorization is never called with services off")
        #expect(fake.statusReads.value == 0, "no Core Location call but the services read")
        #expect(access.knownServicesEnabled == false)
    }

    /// The status comes from what Core Location last reported, not from a call.
    @Test func servicesOffKeepsTheLastReportedStatus() async {
        let fake = FakeLocation()
        let access = Self.access(fake)
        access.statusChanged(.authorisedWhenInUse)
        // The report's own read of the switch (services on) finishes first.
        while access.knownServicesEnabled == nil { await Task.yield() }
        fake.servicesOn.set(false)
        let reply = await access.request()
        #expect(reply == LocationPermissionReply(authorised: false, status: "authorisedWhenInUse", servicesEnabled: false))
        #expect(fake.statusReads.value == 0)
    }

    // MARK: Asking

    @Test func anUndecidedAgentAsksOnceAndRepliesWithTheAnswer() async {
        let fake = FakeLocation()
        let access = Self.access(fake)
        async let first = access.request()
        async let second = access.request()
        // Let both requests reach the wait.
        while fake.requests.value == 0 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        fake.status.set(.authorisedWhenInUse)
        access.statusChanged(.authorisedWhenInUse)
        let replies = await [first, second]
        #expect(replies.allSatisfy { $0 == LocationPermissionReply(authorised: true, status: "authorisedWhenInUse", servicesEnabled: true) })
        #expect(fake.requests.value == 1, "one prompt however many callers wait")
        #expect(access.knownAuthorised == true)
    }

    @Test func aDecidedAgentAnswersAtOnceWithoutAsking() async {
        let fake = FakeLocation()
        fake.status.set(.denied)
        let reply = await Self.access(fake).request()
        #expect(reply == LocationPermissionReply(authorised: false, status: "denied", servicesEnabled: true))
        #expect(fake.requests.value == 0)
    }

    @Test func anUnansweredPromptRepliesAtTheBound() async {
        let fake = FakeLocation()
        let clock = ManualClock()
        let access = Self.access(fake, requestBound: .milliseconds(100), clock: clock)
        async let replied = access.request()
        // The request's bound is the only sleeper left once the services read (services on) has answered.
        while fake.requests.value == 0 { await Task.yield() }
        await clock.sleepers(atLeast: 1)
        clock.advance(by: .milliseconds(100))
        let reply = await replied
        #expect(reply.status == "notDetermined")
        #expect(!reply.authorised)
        #expect(fake.requests.value == 1)
    }

    // MARK: The services read (fix round 1 M1, I2)

    /// A locationd that doesn't answer: the reply comes at the bound with the last value known, and later calls
    /// share the one read in flight rather than starting more.
    @Test func aHungServicesReadIsBoundedAndShared() async {
        let fake = FakeLocation()
        let gate = DispatchSemaphore(value: 0)
        fake.hang.set(gate)
        let clock = ManualClock()
        let access = Self.access(fake, servicesBound: .milliseconds(100), clock: clock)
        // Each call waits on its bound; moving the clock past it is what returns it, the read still hung.
        async let firstReply = access.current()
        await clock.sleepers(atLeast: 1)
        clock.advance(by: .milliseconds(100))
        let first = await firstReply
        async let secondReply = access.current()
        await clock.sleepers(atLeast: 1)
        clock.advance(by: .milliseconds(100))
        let second = await secondReply
        #expect(first.servicesEnabled == nil, "nothing known yet")
        #expect(second.servicesEnabled == nil)
        #expect(fake.servicesReads.value == 1, "one read in flight at a time")
        fake.hang.set(nil)
        gate.signal()
        while access.knownServicesEnabled == nil { await Task.yield() }
        #expect(access.knownServicesEnabled == true)
    }

    /// The `locationAccess` call: a fresh read each time, never a prompt.
    @Test func currentReadsTheSwitchAfreshAndNeverAsks() async {
        let fake = FakeLocation()
        let access = Self.access(fake)
        access.statusChanged(.restricted)
        while access.knownServicesEnabled == nil { await Task.yield() }
        #expect(await access.current() == LocationPermissionReply(authorised: false, status: "restricted", servicesEnabled: true))
        fake.servicesOn.set(false)
        #expect(await access.current() == LocationPermissionReply(authorised: false, status: "restricted", servicesEnabled: false))
        #expect(fake.requests.value == 0)
        #expect(access.knownServicesEnabled == false)
    }

    /// Before Core Location's first report, the status is read once (services on), never asked for.
    @Test func currentBeforeTheFirstReportReadsTheStatus() async {
        let fake = FakeLocation()
        fake.status.set(.authorisedAlways)
        let reply = await Self.access(fake).current()
        #expect(reply == LocationPermissionReply(authorised: true, status: "authorisedAlways", servicesEnabled: true))
        #expect(fake.requests.value == 0)
    }

    /// A change Core Location reports reads the switch again in the background, so the hello's cached value follows.
    @Test func aReportedChangeReadsTheSwitchAgain() async {
        let fake = FakeLocation()
        let access = Self.access(fake)
        fake.servicesOn.set(false)
        access.statusChanged(.denied)
        while access.knownServicesEnabled == nil { await Task.yield() }
        #expect(access.knownServicesEnabled == false)
        #expect(access.knownAuthorised == false)
        #expect(fake.servicesReads.value == 1)
    }

    @Test func authorisationNames() {
        #expect(LocationAuthorisation.notDetermined.authorised == nil)
        #expect(LocationAuthorisation.restricted.authorised == false)
        #expect(LocationAuthorisation.denied.authorised == false)
        #expect(LocationAuthorisation.authorisedAlways.authorised == true)
        #expect(LocationAuthorisation.authorisedWhenInUse.authorised == true)
        #expect(LocationAuthorisation.unknown.authorised == false)
        #expect(LocationAuthorisation.authorisedWhenInUse.rawValue == "authorisedWhenInUse")
    }
}
