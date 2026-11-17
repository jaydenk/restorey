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
            return "“\(bad.prefix(70))” isn’t a snapshot ID"
        }
        switch scope {
        case .beforeAdoption:
            if plan.origin != .adopted { return "Restorey created this repository, so nothing in it is from before Restorey" }
        case .previousFolderList(let paths):
            if EarlierSnapshots.normalised(paths) == EarlierSnapshots.normalised(plan.sources) {
                return "that folder list is the plan’s current one"
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
/// - no `restorey:` tag at all (untagged, or other tools' tags) with exactly the plan's sources, taken no later than the
///   adoption, is from before adoption, for an adopted plan only. The bound is `Plan.adoptedAt`; a plan adopted before
///   that was recorded is bounded by its earliest snapshot with its own tag, and with none nothing is offered. A
///   snapshot whose time can't be read never qualifies;
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
        let all = reply.flatMap { ($0.keep ?? []) + ($0.remove ?? []) }
        let adoption = adoptionBound(plan: plan, snapshots: all)
        var found: [EarlierSnapshotScope: EarlierSnapshotGroup] = [:]
        func note(_ snapshot: Snapshot, removed: Bool) {
            let paths = normalised(snapshot.paths ?? [])
            let tags = (snapshot.tags ?? []).sorted()
            guard let scope = scope(host: snapshot.hostname ?? "", paths: paths, tags: tags, plan: plan),
                scope.kind == kind
            else { return }
            if case .beforeAdoption = scope {
                guard let adoption, let taken = snapshot.time.flatMap(date), taken <= adoption else { return }
            }
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

    /// The latest time a snapshot may have to count as from before adoption: `Plan.adoptedAt`, or for a plan adopted
    /// before that was recorded, the earliest snapshot carrying the plan's own tag (the first one Restorey made). Nil:
    /// nothing is known to be from before adoption, so nothing is offered.
    private static func adoptionBound(plan: Plan, snapshots: [Snapshot]) -> Date? {
        if let adoptedAt = plan.adoptedAt { return adoptedAt }
        let own = "restorey:\(plan.id.uuidString)"
        return snapshots.filter { ($0.tags ?? []).contains(own) }.compactMap { $0.time.flatMap(date) }.min()
    }

    /// restic's RFC 3339 time (`2026-10-01T10:01:00.123456789+10:30`, up to nine fractional digits, or `Z`). The
    /// fraction is cut to milliseconds, which the formatter takes; nil when it can't be read.
    static func date(_ text: String) -> Date? {
        var trimmed = text
        if let dot = text.firstIndex(of: "."),
            let end = text[text.index(after: dot)...].firstIndex(where: { !$0.isNumber })
        {
            let digits = text[text.index(after: dot)..<end].prefix(3)
            trimmed = String(text[..<dot]) + (digits.isEmpty ? "" : "." + digits) + String(text[end...])
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = trimmed.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }

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
        let time: String?
    }
}
