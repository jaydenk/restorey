import Foundation
import Synchronization
import Testing

@testable import RestoreyCore

struct PreflightTests {
    private func plan(
        sources: [String] = ["/Users/me"],
        battery: BatteryRule = .minimumPercent(20),
        repository: Repository = .raw(repository: "sftp:backup@nas:/srv/restic", environmentNames: [])
    ) -> Plan {
        var plan = Plan.newHotPlan(
            name: "Home",
            repository: repository,
            origin: .created, hostLabel: "mac", sources: sources, exclusions: [],
            now: Date(timeIntervalSince1970: 1_800_000_000))
        plan.conditions = Conditions(battery: battery)
        return plan
    }

    /// Fully injected: nothing here touches real power, network or filesystem state.
    private func env(
        power: PowerState = PowerState(onBattery: false, percent: 100),
        network: NetworkState = .satisfied(constrained: false, expensive: false),
        mounted: Set<String> = [],
        existing: Set<String> = ["/Users/me"],
        networkSettings: NetworkSettings = .defaults
    ) -> PreflightEnvironment {
        PreflightEnvironment(
            power: power, network: network,
            isMountPoint: { mounted.contains($0) }, fileExists: { existing.contains($0) },
            networkSettings: networkSettings)
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

    /// The rule is Mac-wide (Ruling P2-6): it comes from the environment's network settings.
    @Test func constrainedNetworkRunsWhenTheOptionIsOff() {
        var off = NetworkSettings.defaults
        off.skipOnConstrainedNetwork = false
        let e = env(network: .satisfied(constrained: true, expensive: true), networkSettings: off)
        #expect(preflight(plan: plan(), env: e) == .run)
    }

    private static let s3 = Repository.s3(S3Location(
        provider: .b2, endpoint: URL(string: "https://s3.us-west-004.backblazeb2.com")!, bucket: "bucket",
        prefix: "mac"))
    private static let folder = Repository.raw(repository: "/Volumes/Backup/restic", environmentNames: [])

    /// The Mac-wide rule applies only to a repository that needs the network (Ruling R69).
    @Test func constrainedNetworkSkipsAnS3PlanButNotAPathPlan() {
        let e = env(network: .satisfied(constrained: true, expensive: false), mounted: ["/Volumes/Backup"])
        #expect(preflight(plan: plan(repository: Self.s3), env: e) == .skip(.constrainedNetwork))
        #expect(preflight(plan: plan(repository: Self.folder), env: e) == .run)
    }

    private func wiFi(
        _ name: String?, skipping names: [String], network: NetworkState = .satisfied(constrained: false, expensive: false)
    ) -> PreflightEnvironment {
        var e = env(network: network, mounted: ["/Volumes/Backup"], networkSettings: NetworkSettings(
            uploadLimit: .none, skipOnConstrainedNetwork: true, skippedWiFiNames: names))
        e.currentWiFiName = { name }
        return e
    }

    /// The skip names the network as the Mac reports it, whatever the list's spelling.
    @Test func aListedWiFiNetworkSkipsIgnoringCase() {
        #expect(preflight(plan: plan(repository: Self.s3), env: wiFi("Café", skipping: ["café"])) == .skip(.skippedWiFi("Café")))
        #expect(preflight(plan: plan(), env: wiFi("Café", skipping: ["Home", "CAFÉ"])) == .skip(.skippedWiFi("Café")))
    }

    @Test func anUnlistedWiFiNetworkRuns() {
        #expect(preflight(plan: plan(), env: wiFi("Home 5G", skipping: ["Home"])) == .run)
    }

    /// Ruling P2-8: no Location permission, or not on Wi-Fi, never skips.
    @Test func anUnknownWiFiNameRuns() {
        #expect(preflight(plan: plan(), env: wiFi(nil, skipping: ["Home"])) == .run)
    }

    @Test func aListedWiFiNetworkDoesntSkipAPathPlan() {
        #expect(preflight(plan: plan(repository: Self.folder), env: wiFi("Home", skipping: ["Home"])) == .run)
    }

    /// No network wins over the Wi-Fi rule, and the constrained rule is checked first.
    @Test func theNetworkChecksComeInOrder() {
        #expect(preflight(plan: plan(), env: wiFi("Home", skipping: ["Home"], network: .unsatisfied)) == .skip(.noNetwork))
        let constrained = NetworkState.satisfied(constrained: true, expensive: false)
        #expect(preflight(plan: plan(), env: wiFi("Home", skipping: ["Home"], network: constrained))
            == .skip(.constrainedNetwork))
    }

    /// With no names listed, the Wi-Fi name isn't read at all.
    @Test func theWiFiNameIsReadOnlyWhenNamesAreListed() {
        let reads = ReadCounter()
        var e = env()
        e.currentWiFiName = { reads.value.withLock { $0 += 1 }; return "Home" }
        #expect(preflight(plan: plan(), env: e) == .run)
        #expect(reads.value.withLock { $0 } == 0)
    }

    final class ReadCounter: Sendable {
        let value = Mutex(0)
    }

    @Test func theEnvironmentDefaultsToTheDefaultNetworkSettings() {
        let e = PreflightEnvironment(
            power: PowerState(onBattery: false, percent: 100), network: .satisfied(constrained: true, expensive: false),
            isMountPoint: { _ in false }, fileExists: { _ in true })
        #expect(e.networkSettings == .defaults)
        #expect(preflight(plan: plan(), env: e) == .skip(.constrainedNetwork))
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
        #expect(preflight(plan: p, env: e) == .fail("/Volumes/Media/Photos doesn’t exist"))
    }

    @Test func staleDirectoryOnUnmountedVolumeSkips() {
        // The path exists (a leftover directory) but the drive is not mounted.
        let p = plan(sources: ["/Volumes/Media/Photos"])
        let e = env(mounted: [], existing: ["/Volumes/Media/Photos"])
        #expect(preflight(plan: p, env: e) == .skip(.volumeNotMounted("Media")))
    }

    @Test func mixedMountedAndUnmountedVolumesSkipsWithTheUnmountedName() {
        let p = plan(sources: ["/Volumes/Mounted/a", "/Volumes/Gone/b"])
        let e = env(mounted: ["/Volumes/Mounted"], existing: ["/Volumes/Mounted/a", "/Volumes/Gone/b"])
        #expect(preflight(plan: p, env: e) == .skip(.volumeNotMounted("Gone")))
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
        #expect(preflight(plan: p, env: env()) == .fail("/Users/me/Gone doesn’t exist"))
    }

    @Test func firstMissingPathIsReported() {
        let p = plan(sources: ["/a", "/b"])
        #expect(preflight(plan: p, env: env(existing: [])) == .fail("/a doesn’t exist"))
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

    // MARK: Network conditions apply only to repositories that need the network (Ruling R69)

    private static let localFolder = Repository.raw(repository: "/Volumes/Backup/restic", environmentNames: [])
    private static let b2 = Repository.s3(S3Location(
        provider: .b2, endpoint: URL(string: "https://s3.us-west-004.backblazeb2.com")!, bucket: "b", prefix: "p"))

    @Test func localRepositoryRunsWithNoNetwork() {
        let p = plan(repository: Self.localFolder)
        #expect(preflight(plan: p, env: env(network: .unsatisfied)) == .run)
    }

    @Test func localRepositoryRunsOnAConstrainedNetwork() {
        let p = plan(repository: Self.localFolder)
        #expect(preflight(plan: p, env: env(network: .satisfied(constrained: true, expensive: true))) == .run)
    }

    @Test func localPrefixedRepositoryRunsWithNoNetwork() {
        let p = plan(repository: .raw(repository: "local:/Users/me/repo", environmentNames: []))
        #expect(preflight(plan: p, env: env(network: .unsatisfied)) == .run)
    }

    @Test func rawSFTPRepositorySkipsWithNoNetwork() {
        let p = plan(repository: .raw(repository: "sftp:me@host:/srv/repo", environmentNames: []))
        #expect(preflight(plan: p, env: env(network: .unsatisfied)) == .skip(.noNetwork))
    }

    @Test func s3RepositorySkipsWithNoNetwork() {
        #expect(preflight(plan: plan(repository: Self.b2), env: env(network: .unsatisfied)) == .skip(.noNetwork))
    }

    @Test func localRepositoryStillChecksBatteryWithNoNetwork() {
        let e = env(power: PowerState(onBattery: true, percent: 3), network: .unsatisfied)
        #expect(preflight(plan: plan(repository: Self.localFolder), env: e) == .skip(.batteryBelow(20)))
    }

    @Test(arguments: [
        ("/Users/me/repo", false), ("../repo", false), ("repo", false), ("local:/x", false),
        ("local:relative", false), ("/path:with:colons", false),
        ("s3:https://host/bucket", true), ("b2:bucket:path", true), ("rest:https://host/", true),
        ("sftp:host:/srv", true), ("rclone:remote:path", true), ("azure:container:/", true),
        ("gs:bucket:/", true), ("swift:container:/", true), ("unknown:thing", true),
    ])
    func rawLocationsAreReadAsResticReadsThem(location: String, needsNetwork: Bool) {
        #expect(Repository.raw(repository: location, environmentNames: []).needsNetwork == needsNetwork)
    }

    @Test func networkKeyForEachInterface() {
        func state(_ interface: NetworkInterface) -> NetworkState {
            .satisfied(constrained: false, expensive: false, interface: interface)
        }
        #expect(networkKey(for: state(.wiFi), wiFiName: "Kerr Home") == .wiFi(name: "Kerr Home"))
        #expect(networkKey(for: state(.wiFi), wiFiName: "  Kerr Home ") == .wiFi(name: "Kerr Home"))
        #expect(networkKey(for: state(.wiFi), wiFiName: nil) == .wiFiUnknown)
        #expect(networkKey(for: state(.wiFi), wiFiName: "") == .wiFiUnknown)
        #expect(networkKey(for: state(.wiFi), wiFiName: " \t\n ") == .wiFiUnknown)
        #expect(networkKey(for: state(.wired), wiFiName: "Kerr Home") == .ethernet)
        #expect(networkKey(for: state(.other), wiFiName: "Kerr Home") == .other)
        #expect(networkKey(for: .satisfied(constrained: true, expensive: true), wiFiName: nil) == .other)
        #expect(networkKey(for: .unsatisfied, wiFiName: "Kerr Home") == nil)
    }
}
