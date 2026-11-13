import Foundation

/// What setup's password step and sources step decide about a repository that is already there (product
/// spec §5.4 and §5.6, UI design §4 step 3): the snapshot summary, which host label this Mac's snapshots are
/// under, the plan defaults for an adopted repository, the sources pre-filled from its latest snapshot, and
/// the "new snapshot group" warning. Pure; the setup window does the calls.
public enum SetupAdoption {
    /// "312 snapshots from 3 Macs". Each host restic recorded is counted as a Mac, as the mockup does.
    public static func summary(_ report: AdoptReport, locale: Locale = Locale(identifier: "en_AU")) -> String {
        if report.snapshotCount == 0 { return "No snapshots yet" }
        let snapshots = count(report.snapshotCount, "snapshot", "snapshots", locale)
        let macs = count(report.hosts.count, "Mac", "Macs", locale)
        return "\(snapshots) from \(macs)"
    }

    /// The names this Mac may have recorded snapshots under, most likely first: restic's default host is the
    /// Unix host name (which on macOS can come from the network), and people also type the computer name.
    /// `computerName` is also the label a new plan starts with.
    public static func thisMacNames(computerName: String?, localHostName: String?, hostName: String?) -> [String] {
        var names: [String] = []
        let hostShort = hostName.flatMap { $0.split(separator: ".").first.map(String.init) }
        for name in [computerName, localHostName, hostName, hostShort, localHostName.map { $0 + ".local" }] {
            guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                !names.contains(name)
            else { continue }
            names.append(name)
        }
        return names
    }

    /// The host label an adopted plan starts with: the host in the repository that matches one of this Mac's
    /// names (ignoring case, the first of `thisMac` to match wins), spelt as the snapshots spell it so
    /// `--host` keeps adding to the same group; otherwise this Mac's first name (a new group).
    public static func defaultHostLabel(hosts: [String], thisMac: [String]) -> String {
        for name in thisMac {
            if let host = hosts.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return host }
        }
        return thisMac.first ?? "Mac"
    }

    /// The host labels setup offers: every host in the repository, then this Mac's first name if no host
    /// has it.
    public static func hostChoices(hosts: [String], thisMac: [String]) -> [String] {
        var choices = hosts
        if let name = thisMac.first, !hosts.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            choices.append(name)
        }
        return choices
    }

    /// `plan` as an adopted repository's plan (product spec §5.6): someone else's repository is never
    /// pruned, `forget` runs daily rather than after every backup, and its pack size is left as it is.
    public static func adopted(_ plan: Plan, hostLabel: String) -> Plan {
        var plan = plan
        plan.origin = .adopted
        plan.hostLabel = hostLabel
        plan.pruneEnabled = false
        plan.forgetCadence = .daily
        plan.packSizeMiB = nil
        return plan
    }

    /// `plan` as a repository Restorey creates, with `Plan.newHotPlan`'s defaults for that origin (setup's
    /// "Create new repository", after a probe of an adopted plan's address found nothing).
    public static func created(_ plan: Plan) -> Plan {
        var plan = plan
        plan.origin = .created
        plan.pruneEnabled = true
        plan.forgetCadence = .afterEachBackup
        if case .s3 = plan.repository { plan.packSizeMiB = 64 } else { plan.packSizeMiB = nil }
        return plan
    }

    /// The sources an adopted plan starts with: the latest snapshot's paths for its host label, so the first
    /// backup has a parent (product spec §5.4). With no snapshot for the label, `current` is kept.
    public static func prefilledSources(_ report: AdoptReport, current: [String]) -> [String] {
        let paths = report.latestPathsForHost.filter { $0.hasPrefix("/") }
        return paths.isEmpty ? current : FormValidation.addingSources(paths, to: [])
    }

    /// The warning shown when the first backup won't continue an existing group (product spec §5.4): no
    /// snapshot has this host label, or the sources differ from its latest snapshot's paths. restic then picks
    /// no parent and reads every file again, and retention doesn't thin the old group (§5.6). Nil when the
    /// first backup continues the latest snapshot's group, and when `sources` is nil (not chosen yet: only the
    /// host label is checked). `report.latestPathsForHost` must be for `hostLabel`.
    public static func newGroupWarning(hostLabel: String, sources: [String]?, report: AdoptReport) -> String? {
        let reread = "so the first backup starts a new snapshot group: restic reads every file again (it doesn't upload "
            + "them again), and this plan's retention won't thin the old group."
        guard report.snapshotCount > 0 else { return nil }
        guard report.hosts.contains(hostLabel) else { return "No snapshots here are from “\(hostLabel)”, \(reread)" }
        guard let sources, !report.latestPathsForHost.isEmpty else { return nil }
        let latest = Set(FormValidation.addingSources(report.latestPathsForHost, to: []))
        let chosen = Set(FormValidation.addingSources(sources, to: []))
        guard latest != chosen else { return nil }
        return "These folders differ from the latest snapshot from “\(hostLabel)”, \(reread)"
    }

    private static func count(_ n: Int, _ one: String, _ many: String, _ locale: Locale) -> String {
        "\(n.formatted(.number.locale(locale))) \(n == 1 ? one : many)"
    }
}
