import Foundation
import Testing

@testable import RestoreyCore

struct PreflightTests {
    private func plan(
        sources: [String] = ["/Users/me"],
        battery: BatteryRule = .minimumPercent(20),
        skipConstrained: Bool = true
    ) -> Plan {
        var plan = Plan.newHotPlan(
            name: "Home",
            repository: .raw(repository: "/tmp/repo", environmentNames: []),
            origin: .created, hostLabel: "mac", sources: sources, exclusions: [],
            now: Date(timeIntervalSince1970: 1_800_000_000))
        plan.conditions = Conditions(battery: battery, skipOnConstrainedNetwork: skipConstrained)
        return plan
    }

    /// Fully injected: nothing here touches real power, network or filesystem state.
    private func env(
        power: PowerState = PowerState(onBattery: false, percent: 100),
        network: NetworkState = .satisfied(constrained: false, expensive: false),
        mounted: Set<String> = [],
        existing: Set<String> = ["/Users/me"]
    ) -> PreflightEnvironment {
        PreflightEnvironment(
            power: power, network: network,
            isMountPoint: { mounted.contains($0) }, fileExists: { existing.contains($0) })
    }

    @Test func allSourcesPresentRuns() {
        #expect(preflight(plan: plan(), env: env()) == .run)
    }

    @Test func noNetworkSkips() {
        #expect(preflight(plan: plan(), env: env(network: .unsatisfied)) == .skip(.noNetwork))
    }

    @Test func constrainedNetworkSkips() {
        let e = env(network: .satisfied(constrained: true, expensive: false))
        #expect(preflight(plan: plan(), env: e) == .skip(.constrainedNetwork))
    }

    @Test func expensiveNetworkSkips() {
        let e = env(network: .satisfied(constrained: false, expensive: true))
        #expect(preflight(plan: plan(), env: e) == .skip(.constrainedNetwork))
    }

    @Test func constrainedNetworkRunsWhenTheOptionIsOff() {
        let e = env(network: .satisfied(constrained: true, expensive: true))
        #expect(preflight(plan: plan(skipConstrained: false), env: e) == .run)
    }

    @Test func neverOnBatterySkipsOnBattery() {
        let e = env(power: PowerState(onBattery: true, percent: 99))
        #expect(preflight(plan: plan(battery: .neverOnBattery), env: e) == .skip(.onBattery))
    }

    @Test func neverOnBatteryRunsOnMains() {
        #expect(preflight(plan: plan(battery: .neverOnBattery), env: env()) == .run)
    }

    @Test func lowBatterySkips() {
        let e = env(power: PowerState(onBattery: true, percent: 19))
        #expect(preflight(plan: plan(), env: e) == .skip(.batteryBelow(20)))
    }

    @Test func batteryAtTheMinimumRuns() {
        let e = env(power: PowerState(onBattery: true, percent: 20))
        #expect(preflight(plan: plan(), env: e) == .run)
    }

    @Test func lowChargeOnMainsRuns() {
        let e = env(power: PowerState(onBattery: false, percent: 5))
        #expect(preflight(plan: plan(), env: e) == .run)
    }

    @Test func unknownPercentOnBatteryRuns() {
        // No reading to compare: the backup is not blocked on a guess.
        let e = env(power: PowerState(onBattery: true, percent: nil))
        #expect(preflight(plan: plan(), env: e) == .run)
    }

    @Test func missingVolumeSkips() {
        let p = plan(sources: ["/Volumes/Backup Drive/Photos"])
        #expect(preflight(plan: p, env: env(existing: [])) == .skip(.volumeNotMounted("Backup Drive")))
    }

    @Test func volumeRootAsSourceSkipsWhenUnmounted() {
        let p = plan(sources: ["/Volumes/Media"])
        #expect(preflight(plan: p, env: env(existing: [])) == .skip(.volumeNotMounted("Media")))
    }

    @Test func mountedVolumeWithMissingFolderFails() {
        let p = plan(sources: ["/Volumes/Media/Photos"])
        let e = env(mounted: ["/Volumes/Media"], existing: ["/Volumes/Media"])
        #expect(preflight(plan: p, env: e) == .fail("/Volumes/Media/Photos doesn't exist"))
    }

    @Test func presentVolumeSourceRuns() {
        let p = plan(sources: ["/Volumes/Media/Photos"])
        let e = env(mounted: ["/Volumes/Media"], existing: ["/Volumes/Media/Photos"])
        #expect(preflight(plan: p, env: e) == .run)
    }

    @Test func similarVolumeNamePrefixIsNotTheSameVolume() {
        // /Volumes/MediaX/... is not under /Volumes/Media, even though the strings share a prefix.
        let p = plan(sources: ["/Volumes/MediaX/Photos"])
        let e = env(mounted: ["/Volumes/Media"], existing: [])
        #expect(preflight(plan: p, env: e) == .skip(.volumeNotMounted("MediaX")))
    }

    @Test func missingNonVolumePathFails() {
        let p = plan(sources: ["/Users/me", "/Users/me/Gone"])
        #expect(preflight(plan: p, env: env()) == .fail("/Users/me/Gone doesn't exist"))
    }

    @Test func firstMissingPathIsReported() {
        let p = plan(sources: ["/a", "/b"])
        #expect(preflight(plan: p, env: env(existing: [])) == .fail("/a doesn't exist"))
    }

    @Test func unmountedVolumeBeatsAnEarlierMissingPath() {
        // The drive's absence explains the run, so the skip wins.
        let p = plan(sources: ["/Users/me/Gone", "/Volumes/Backup/Data"])
        #expect(preflight(plan: p, env: env(existing: [])) == .skip(.volumeNotMounted("Backup")))
    }

    @Test func firstUnmountedVolumeIsReported() {
        let p = plan(sources: ["/Volumes/One/x", "/Volumes/Two/y"])
        #expect(preflight(plan: p, env: env(existing: [])) == .skip(.volumeNotMounted("One")))
    }

    @Test func noNetworkBeatsLowBattery() {
        let e = env(power: PowerState(onBattery: true, percent: 3), network: .unsatisfied)
        #expect(preflight(plan: plan(), env: e) == .skip(.noNetwork))
    }

    @Test func batteryBeatsMissingSources() {
        let e = env(power: PowerState(onBattery: true, percent: 3), existing: [])
        #expect(preflight(plan: plan(), env: e) == .skip(.batteryBelow(20)))
    }

    @Test func networkBeatsMissingSources() {
        #expect(preflight(plan: plan(), env: env(network: .unsatisfied, existing: [])) == .skip(.noNetwork))
    }
}
