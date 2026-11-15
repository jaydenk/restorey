import Foundation

/// The two kinds of earlier snapshot, one restic preview each (`ResticOperation.forgetPreview`).
public enum EarlierSnapshotKind: String, Codable, Sendable, Hashable, CaseIterable {
    case beforeAdoption
    case previousFolderLists
}

/// Which earlier snapshots of a plan one opt-in action is about (product spec §5.6, Task 14b). Everything else in a
/// repository is out of reach of both: another Mac's snapshots, another plan's, another tool's under other folders,
/// and the plan's own current group (which its ordinary `forget` thins).
/// JSON: `{"type":"beforeAdoption"}`, `{"type":"previousFolderList","paths":["/Users/x/Old"]}`.
public enum EarlierSnapshotScope: Codable, Sendable, Hashable {
    /// This Mac's snapshots from before Restorey adopted the repository: the plan's host label, exactly the plan's
    /// source folders, and no `restorey:` tag at all (untagged, or another tool's tags). Adopted plans only.
    case beforeAdoption
    /// Snapshots this plan made of a folder list it no longer backs up: the plan's host label, exactly the tag
    /// `restorey:<plan id>`, and `paths` (cleaned and sorted, as `EarlierSnapshots.normalised` gives them), which
    /// differ from the plan's sources.
    case previousFolderList(paths: [String])

    public var kind: EarlierSnapshotKind {
        switch self {
        case .beforeAdoption: .beforeAdoption
        case .previousFolderList: .previousFolderLists
        }
    }

    private enum CodingKeys: String, CodingKey { case type, paths }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "beforeAdoption": self = .beforeAdoption
        case "previousFolderList": self = .previousFolderList(paths: try c.decode([String].self, forKey: .paths))
        case let other: throw UnknownCase.error(kind: "earlier snapshot scope", name: other, in: c, forKey: .type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .beforeAdoption: try c.encode("beforeAdoption", forKey: .type)
        case .previousFolderList(let paths):
            try c.encode("previousFolderList", forKey: .type)
            try c.encode(paths, forKey: .paths)
        }
    }
}

/// One action's snapshots, as a preview found them: how many the plan's retention keeps, and the full IDs of those it
/// would remove. The pre-adoption snapshots can be under several tag sets (restic groups by `host,paths,tags`); they
/// are one action, so they come back as one group, with the counts added up.
public struct EarlierSnapshotGroup: Codable, Sendable, Equatable {
    public var scope: EarlierSnapshotScope
    public var host: String
    /// Cleaned and sorted.
    public var paths: [String]
    /// The tags of the snapshots, sorted (empty for untagged ones).
    public var tags: [String]
    public var keptCount: Int
    /// restic's full 64-character IDs, in its order.
    public var removeIDs: [String]

    public var total: Int { keptCount + removeIDs.count }

    public init(
        scope: EarlierSnapshotScope, host: String, paths: [String], tags: [String], keptCount: Int, removeIDs: [String]
    ) {
        self.scope = scope
        self.host = host
        self.paths = paths
        self.tags = tags
        self.keptCount = keptCount
        self.removeIDs = removeIDs
    }
}

/// `previewEarlierSnapshots`'s reply: every earlier group of the plan, the pre-adoption one first, then each previous
/// folder list by its paths. A group retention leaves whole is listed too, with nothing to remove. A dry run: nothing
/// was removed and nothing was recorded. JSON: `{"groups":[…]}`.
public struct EarlierSnapshotsPreview: Codable, Sendable, Equatable {
    public var groups: [EarlierSnapshotGroup]

    public init(groups: [EarlierSnapshotGroup]) {
        self.groups = groups
    }

    public var hasAnythingToRemove: Bool { groups.contains { !$0.removeIDs.isEmpty } }

    public func group(_ scope: EarlierSnapshotScope) -> EarlierSnapshotGroup? {
        groups.first { $0.scope == scope }
    }
}

/// What the user confirmed: one action and exactly the snapshot IDs its confirmation counted. The agent removes only
/// those of them a fresh preview still puts in that action (`EarlierSnapshots.removable`), so a snapshot added after
/// the confirmation can never be removed by it. JSON: `{"scope":{…},"snapshotIDs":["…"]}`.
public struct EarlierSnapshotsConfirmation: Codable, Sendable, Equatable {
    public var scope: EarlierSnapshotScope
    public var snapshotIDs: [String]

    public init(scope: EarlierSnapshotScope, snapshotIDs: [String]) {
        self.scope = scope
        self.snapshotIDs = snapshotIDs
    }

    /// Confirms everything the preview's group would remove.
    public init(_ group: EarlierSnapshotGroup) {
        self.init(scope: group.scope, snapshotIDs: group.removeIDs)
    }

    /// Why the agent refuses this confirmation for `plan`, or nil: no IDs, an ID that isn't restic's full lower-case
    /// hex form (so it can't be a prefix, a flag or `latest`), a pre-adoption action on a repository Restorey created,
    /// or a "previous" folder list that is the plan's current one.
    public func problem(for plan: Plan) -> String? {
        if snapshotIDs.isEmpty { return "no snapshots were named" }
        if let bad = snapshotIDs.first(where: { !EarlierSnapshots.isSnapshotID($0) }) {
            return "\"\(bad.prefix(70))\" isn't a snapshot ID"
        }
        switch scope {
        case .beforeAdoption:
            if plan.origin != .adopted { return "Restorey created this repository, so nothing in it is from before Restorey" }
        case .previousFolderList(let paths):
            if EarlierSnapshots.normalised(paths) == EarlierSnapshots.normalised(plan.sources) {
                return "that folder list is the plan's current one"
            }
        }
        return nil
    }
}

/// `removeEarlierSnapshots`'s reply: how many snapshots restic removed, and how many confirmed ones were left because a
/// fresh preview no longer put them in the action (removed meanwhile, or retention now keeps them).
/// JSON: `{"leftAlone":0,"removed":12}`.
public struct EarlierSnapshotsRemoval: Codable, Sendable, Equatable {
    public var removed: Int
    public var leftAlone: Int

    public init(removed: Int, leftAlone: Int) {
        self.removed = removed
        self.leftAlone = leftAlone
    }
}

/// `removeEarlierSnapshots`' and `removeEarlierSnapshotsAfterNextBackup`'s request.
/// JSON: `{"confirmation":{…},"planID":"…"}`.
public struct EarlierSnapshotsRequest: Codable, Sendable, Equatable {
    public var planID: UUID
    public var confirmation: EarlierSnapshotsConfirmation

    public init(planID: UUID, confirmation: EarlierSnapshotsConfirmation) {
        self.planID = planID
        self.confirmation = confirmation
    }
}

/// Reads a `forget --dry-run --json` (`ResticOperation.forgetPreview`) into the plan's earlier groups, and decides what
/// a confirmed removal may take. Pure: the agent runs restic, this decides.
///
/// "Apply this plan's retention" means retention as if the earlier snapshots were the plan's own (product spec §5.6:
/// the old folder list's snapshots "are no longer thinned by the new group's policy"). So restic applies the policy to
/// a timeline holding them and the plan's current snapshots together, and the newest buckets go to whichever is
/// newest: for snapshots from before adoption, everything of the host with the same folders (`host,paths`); for
/// previous folder lists, everything with the plan's tag (`host,tags`). A separate group per folder list would change
/// nothing, because the plan's ordinary `forget` already applies the policy to each group on its own.
///
/// What may go is then decided snapshot by snapshot, from each snapshot's own hostname, paths and tags, never from the
/// grouping, so "never anything else" (product spec §5.6) holds whatever restic grouped:
/// - the host must be the plan's host label exactly;
/// - the plan's own tag alone (`restorey:<id>`, no other tag) with paths other than the plan's sources is a previous
///   folder list;
/// - no `restorey:` tag at all with exactly the plan's sources is from before adoption, for an adopted plan only;
/// - anything else (another plan's tag, the plan's tag with the user's own beside it, a superset or a subset of the
///   sources, the plan's current snapshots) is never removable, though it counts in the timeline as restic sees it.
public enum EarlierSnapshots {
    /// restic's full snapshot ID: 64 lower-case hex digits.
    public static func isSnapshotID(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Absolute paths compared as restic stores them (it cleans each target, and sorts the list to group): cleaned
    /// lexically like Go's `filepath.Clean`, without duplicates, sorted.
    public static func normalised(_ paths: [String]) -> [String] {
        Array(Set(paths.map(clean))).sorted()
    }

    /// The plan's earlier groups of `kind` in `line`, restic's reply to `forgetPreview(kind)`: one for the snapshots
    /// from before adoption, one per previous folder list. Throws when `line` is not a forget reply.
    public static func groups(
        fromForgetReply line: String, kind: EarlierSnapshotKind, plan: Plan
    ) throws -> [EarlierSnapshotGroup] {
        let reply = try JSONDecoder().decode([Group].self, from: Data(line.utf8))
        var found: [EarlierSnapshotScope: EarlierSnapshotGroup] = [:]
        func note(_ snapshot: Snapshot, removed: Bool) {
            let paths = normalised(snapshot.paths ?? [])
            let tags = (snapshot.tags ?? []).sorted()
            guard let scope = scope(host: snapshot.hostname ?? "", paths: paths, tags: tags, plan: plan),
                scope.kind == kind
            else { return }
            var entry = found[scope] ?? EarlierSnapshotGroup(
                scope: scope, host: plan.hostLabel, paths: paths, tags: [], keptCount: 0, removeIDs: [])
            if removed { entry.removeIDs.append(snapshot.id) } else { entry.keptCount += 1 }
            entry.tags = Array(Set(entry.tags + tags)).sorted()
            found[scope] = entry
        }
        for group in reply {
            for snapshot in group.keep ?? [] { note(snapshot, removed: false) }
            for snapshot in group.remove ?? [] { note(snapshot, removed: true) }
        }
        return sorted(Array(found.values))
    }

    /// Both kinds' groups together, in the preview's order: from before adoption first, then each previous folder
    /// list by its paths (restic's own order comes from a Go map, so it varies between runs).
    public static func sorted(_ groups: [EarlierSnapshotGroup]) -> [EarlierSnapshotGroup] {
        groups.sorted { order($0.scope) < order($1.scope) }
    }

    /// The confirmed IDs a removal may take now: those a fresh preview (`now`) still puts in the confirmation's
    /// action, in the confirmation's order, each once. Never an ID the user didn't confirm.
    public static func removable(_ confirmation: EarlierSnapshotsConfirmation, now groups: [EarlierSnapshotGroup]) -> [String] {
        let scope = canonical(confirmation.scope)
        let inScope = Set(groups.filter { $0.scope == scope }.flatMap(\.removeIDs))
        var seen: Set<String> = []
        return confirmation.snapshotIDs.filter { inScope.contains($0) && seen.insert($0).inserted }
    }

    // MARK: Classification

    private static func scope(host: String, paths: [String], tags: [String], plan: Plan) -> EarlierSnapshotScope? {
        guard host == plan.hostLabel else { return nil }
        let own = "restorey:\(plan.id.uuidString)"
        let current = normalised(plan.sources)
        if tags == [own], paths != current { return .previousFolderList(paths: paths) }
        if plan.origin == .adopted, paths == current, !tags.contains(where: { $0.hasPrefix("restorey:") }) {
            return .beforeAdoption
        }
        return nil
    }

    private static func canonical(_ scope: EarlierSnapshotScope) -> EarlierSnapshotScope {
        if case .previousFolderList(let paths) = scope { return .previousFolderList(paths: normalised(paths)) }
        return scope
    }

    private static func order(_ scope: EarlierSnapshotScope) -> String {
        switch scope {
        case .beforeAdoption: ""
        case .previousFolderList(let paths): "1" + paths.joined(separator: "\n")
        }
    }

    /// Go's `filepath.Clean` for an absolute path: one slash between components, no `.`, each `..` taking the
    /// component before it (never above the root), and no trailing slash except on the root itself.
    private static func clean(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    // MARK: Wire

    /// restic 0.19.1's `ForgetGroup` (cmd/restic/cmd_forget.go): `tags` and `remove` are null when empty.
    private struct Group: Decodable {
        let host: String?
        let paths: [String]?
        let tags: [String]?
        let keep: [Snapshot]?
        let remove: [Snapshot]?
    }

    private struct Snapshot: Decodable {
        let id: String
        let hostname: String?
        let paths: [String]?
        let tags: [String]?
    }
}

/// The words around the earlier-snapshots actions (UI design §4 step 3 and §6.2, Task 14b), in the product spec's terms.
public enum EarlierSnapshotsText {
    /// An NSAlert's text: a destructive confirmation whose default button is Cancel.
    public struct Confirmation: Sendable, Equatable {
        public var title: String
        public var message: String
        /// The destructive button, "Remove 12 Snapshots".
        public var button: String
    }

    /// The confirmation for `group`. `afterFirstBackup`: setup's, where the removal waits for the plan's first
    /// successful backup. Prune frees the space only where the plan prunes; otherwise the data stays.
    public static func confirmation(
        _ group: EarlierSnapshotGroup, pruneEnabled: Bool, afterFirstBackup: Bool, home: String = NSHomeDirectory()
    ) -> Confirmation {
        let n = group.removeIDs.count
        let title: String
        let whose: String
        switch group.scope {
        case .beforeAdoption:
            title = "Remove \(snapshots(n)) taken on \(group.host) before Restorey?"
            whose = "\(snapshots(group.total)) this Mac made of these folders before Restorey"
        case .previousFolderList:
            title = "Remove \(snapshots(n)) from the previous folder list?"
            whose = "\(snapshots(group.total)) of \(folders(group.paths, home: home))"
        }
        let when = afterFirstBackup ? " once the first backup has succeeded" : ""
        let keeps = group.keptCount == 0 ? "keeps none" : "keeps \(group.keptCount)"
        var message = "Applied as if they were this plan's own, its retention removes \(n) of the \(whose)\(when), and \(keeps)."
        if case .beforeAdoption = group.scope {
            message += " Snapshots from other Macs, other tools and other folders aren't touched."
        }
        message += pruneEnabled
            ? " The space \(n == 1 ? "it uses" : "they use") is freed at the plan's next prune."
            : " Their data stays in the repository while prune is off for this plan."
        message += " This can't be undone."
        return Confirmation(title: title, message: message, button: "Remove \(n) \(n == 1 ? "Snapshot" : "Snapshots")")
    }

    /// The Keep tab's line for one group.
    public static func row(_ group: EarlierSnapshotGroup, home: String = NSHomeDirectory()) -> String {
        let n = group.removeIDs.count
        let removes = "retention would remove \(n == 0 ? "none" : String(n))."
        switch group.scope {
        case .beforeAdoption:
            return "Before Restorey: \(snapshots(group.total)) from \(group.host); \(removes)"
        case .previousFolderList:
            return "Previous folder list \(folders(group.paths, home: home)): \(snapshots(group.total)); \(removes)"
        }
    }

    /// The Keep tab's one line when there is nothing to apply, or nil when some group has snapshots to remove.
    public static func nothingToApply(_ preview: EarlierSnapshotsPreview) -> String? {
        if preview.groups.isEmpty {
            return "No earlier snapshots from this Mac to apply retention to."
        }
        return preview.hasAnythingToRemove ? nil : "Nothing to apply: retention keeps every earlier snapshot."
    }

    /// What a finished removal says.
    public static func removed(_ removal: EarlierSnapshotsRemoval) -> String {
        var text = removal.removed == 0
            ? "No snapshots were removed."
            : "Removed \(removal.removed) earlier \(removal.removed == 1 ? "snapshot" : "snapshots")."
        if removal.leftAlone > 0 {
            text += removal.leftAlone == 1
                ? " 1 confirmed snapshot was left: it had gone, or retention now keeps it."
                : " \(removal.leftAlone) confirmed snapshots were left: they had gone, or retention now keeps them."
        }
        return text
    }

    /// History's outcome for a removal record (`ResticOperation.forgetSnapshots`) that succeeded.
    public static func historyOutcome(removed: Int) -> String {
        removed == 0 ? "No earlier snapshots needed removing" : "Removed \(removed) earlier \(removed == 1 ? "snapshot" : "snapshots")"
    }

    private static func snapshots(_ n: Int) -> String { "\(n) \(n == 1 ? "snapshot" : "snapshots")" }

    private static func folders(_ paths: [String], home: String) -> String {
        paths.map { FormValidation.displayPath($0, home: home) }.joined(separator: ", ")
    }
}
