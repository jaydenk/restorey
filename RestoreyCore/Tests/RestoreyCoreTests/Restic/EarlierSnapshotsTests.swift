import Foundation
import Testing
@testable import RestoreyCore

/// Task 14b (product spec §5.6): the pure filter from a host-wide `forget --dry-run --json` to the snapshots one
/// confirmed action may remove, and the words around it. The real-restic proofs are in
/// `EarlierSnapshotsRunnerTests` (AgentCoreTests).
struct EarlierSnapshotsTests {
    private static let planID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private static let own = "restorey:11111111-2222-3333-4444-555555555555"
    private static let otherPlan = "restorey:99999999-2222-3333-4444-555555555555"

    /// 1 Jun 2026: after every sample snapshot (1 Jan 2026) unless a test says otherwise.
    private static let adoptedAt = EarlierSnapshots.date("2026-06-01T00:00:00Z")!

    private func plan(
        origin: RepositoryOrigin = .adopted, sources: [String] = ["/Users/x/Documents", "/Users/x/Code"],
        adoptedAt: Date? = EarlierSnapshotsTests.adoptedAt
    ) -> Plan {
        var p = Plan.newHotPlan(
            name: "Home", repository: .raw(repository: "/tmp/repo", environmentNames: []), origin: origin,
            hostLabel: "pepper", sources: sources, exclusions: [], now: Date(timeIntervalSince1970: 1_800_000_000))
        p.id = Self.planID
        if origin == .adopted { p.adoptedAt = adoptedAt }
        return p
    }

    /// A 64-character ID from a short seed, as restic writes them.
    private static func id(_ seed: String) -> String {
        String((seed + String(repeating: "0", count: 64)).prefix(64))
    }

    private struct Snap {
        var id: String
        var host = "pepper"
        var paths: [String]
        var tags: [String]?
        var time = "2026-01-01T10:00:00+10:30"
    }

    private struct Group {
        var host = "pepper"
        var paths: [String]
        var tags: [String]?
        var keep: [Snap]
        var remove: [Snap]
    }

    /// The reply in restic 0.19.1's shape (`ForgetGroup` in cmd_forget.go): `tags` and `remove` are null when
    /// empty, and each snapshot carries its own hostname, paths and tags.
    private func reply(_ groups: [Group]) -> String {
        func snap(_ s: Snap) -> [String: Any] {
            var d: [String: Any] = [
                "id": s.id, "short_id": String(s.id.prefix(8)), "hostname": s.host, "paths": s.paths,
                "time": s.time,
            ]
            if let tags = s.tags { d["tags"] = tags }
            return d
        }
        let array: [[String: Any]] = groups.map { g in
            [
                "host": g.host, "paths": g.paths, "tags": g.tags.map { $0 as Any } ?? NSNull(),
                "keep": g.keep.map(snap), "remove": g.remove.isEmpty ? NSNull() : g.remove.map(snap) as Any,
                "reasons": [],
            ]
        }
        let data = try! JSONSerialization.data(withJSONObject: array)
        return String(decoding: data, as: UTF8.self)
    }

    /// One group of `count` removable snapshots (and one kept) for a key.
    private func group(_ prefix: String, paths: [String], tags: [String]?, host: String = "pepper", remove: Int = 2) -> Group {
        Group(
            host: host, paths: paths, tags: tags,
            keep: [Snap(id: Self.id(prefix + "k"), host: host, paths: paths, tags: tags)],
            remove: (0..<remove).map { Snap(id: Self.id(prefix + "\($0)"), host: host, paths: paths, tags: tags) })
    }

    private let current = ["/Users/x/Code", "/Users/x/Documents"]

    /// Both previews' groups, as the agent puts them together (each kind reads its own reply; here one reply stands in
    /// for both, since the classification is per snapshot).
    private func groups(_ line: String, _ plan: Plan) throws -> [EarlierSnapshotGroup] {
        EarlierSnapshots.sorted(try EarlierSnapshotKind.allCases.flatMap {
            try EarlierSnapshots.groups(fromForgetReply: line, kind: $0, plan: plan)
        })
    }

    /// Retention runs over a timeline with the plan's current snapshots in it (restic groups the plan's tag by
    /// `host,tags`), so a current snapshot can be what retention keeps; it is never counted or removed as earlier,
    /// and the earlier ones are counted by their own folders.
    @Test func aTimelineSharedWithTheCurrentGroupCountsOnlyTheEarlierSnapshots() throws {
        let old = ["/Users/x/Old"]
        let line = reply([Group(
            paths: [], tags: [Self.own],
            keep: [Snap(id: Self.id("cur1"), paths: current, tags: [Self.own]), Snap(id: Self.id("old1"), paths: old, tags: [Self.own])],
            remove: [Snap(id: Self.id("old2"), paths: old, tags: [Self.own]), Snap(id: Self.id("cur2"), paths: current, tags: [Self.own])])])
        let groups = try EarlierSnapshots.groups(fromForgetReply: line, kind: .previousFolderLists, plan: plan())
        #expect(groups == [EarlierSnapshotGroup(
            scope: .previousFolderList(paths: old), host: "pepper", paths: old, tags: [Self.own], keptCount: 1,
            removeIDs: [Self.id("old2")])])
        #expect(try EarlierSnapshots.groups(fromForgetReply: line, kind: .beforeAdoption, plan: plan()).isEmpty)
    }

    // MARK: The filter

    /// Every kind of group a shared repository holds, and only the two the actions are about come back.
    @Test func keepsOnlyThePreAdoptionGroupAndThePlansPreviousFolderLists() throws {
        let line = reply([
            group("a1", paths: current, tags: nil),                               // before adoption: untagged
            group("a2", paths: current, tags: ["daily"]),                         // before adoption: another tool's tag
            group("b1", paths: ["/Users/x/Old"], tags: [Self.own]),               // previous folder list
            group("c1", paths: current, tags: [Self.own]),                        // the plan's own current group
            group("d1", paths: current, tags: [Self.otherPlan]),                  // another plan's
            group("d2", paths: current, tags: [Self.otherPlan, "daily"]),         // another plan's, with more tags
            group("e1", paths: current + ["/Users/x/Pictures"], tags: nil),       // a superset of the plan's paths
            group("e2", paths: ["/Users/x/Code"], tags: nil),                     // a subset
            group("f1", paths: current, tags: nil, host: "other-mac"),            // another host
            group("g1", paths: ["/Users/x/Old"], tags: [Self.own, "keepme"]),     // the plan's tag and the user's own
        ])
        let groups = try groups(line, plan())
        #expect(groups.map(\.scope) == [.beforeAdoption, .previousFolderList(paths: ["/Users/x/Old"])])
        let before = try #require(groups.first)
        #expect(Set(before.removeIDs) == Set(["a10", "a11", "a20", "a21"].map(Self.id)))
        #expect(before.keptCount == 2)
        #expect(before.host == "pepper")
        #expect(before.paths == current)
        let previous = groups[1]
        #expect(previous.removeIDs == ["b10", "b11"].map(Self.id))
        #expect(previous.keptCount == 1)
        #expect(previous.total == 3)
    }

    /// A created repository has no "before Restorey": only Restorey's own previous folder lists are offered.
    @Test func aCreatedRepositoryOffersNoPreAdoptionGroup() throws {
        let line = reply([
            group("a1", paths: current, tags: nil),
            group("b1", paths: ["/Users/x/Old"], tags: [Self.own]),
        ])
        let groups = try groups(line, plan(origin: .created))
        #expect(groups.map(\.scope) == [.previousFolderList(paths: ["/Users/x/Old"])])
    }

    /// Paths are compared as restic stores them: cleaned and sorted, so the plan's order and a trailing slash
    /// don't matter, while a superset or a subset never matches.
    @Test func pathsAreComparedAsCleanSortedSets() throws {
        let line = reply([group("a1", paths: current, tags: nil)])
        let reordered = plan(sources: ["/Users/x/Documents/", "/Users/x/./Code"])
        #expect(try groups(line, reordered).map(\.scope) == [.beforeAdoption])
        let fewer = plan(sources: ["/Users/x/Documents"])
        #expect(try groups(line, fewer).isEmpty)
        #expect(EarlierSnapshots.normalised(["/b/", "/a//c/../d", "/a/d", "/"]) == ["/", "/a/d", "/b"])
    }

    /// Several previous folder lists come back one per path set, in a stable order (restic's own order comes from a
    /// Go map, so it varies between runs).
    @Test func previousFolderListsAreSortedByTheirPaths() throws {
        let line = reply([
            group("z1", paths: ["/Users/x/Z"], tags: [Self.own]),
            group("a1", paths: ["/Users/x/A", "/Users/x/B"], tags: [Self.own]),
        ])
        let groups = try groups(line, plan(origin: .created))
        #expect(groups.map(\.scope) == [
            .previousFolderList(paths: ["/Users/x/A", "/Users/x/B"]), .previousFolderList(paths: ["/Users/x/Z"]),
        ])
    }

    /// Each removed snapshot is checked on its own fields too, so a snapshot that doesn't belong to its group's
    /// scope is never offered, whatever the grouping said.
    @Test func aSnapshotOutsideItsGroupsScopeIsDropped() throws {
        var g = group("a1", paths: current, tags: nil)
        g.remove.append(Snap(id: Self.id("x1"), host: "other-mac", paths: current, tags: nil))
        g.remove.append(Snap(id: Self.id("x2"), paths: current, tags: [Self.otherPlan]))
        g.remove.append(Snap(id: Self.id("x3"), paths: current + ["/Users/x/More"], tags: nil))
        g.remove.append(Snap(id: Self.id("x4"), paths: current, tags: [Self.own]))
        let groups = try groups(reply([g]), plan())
        #expect(groups.first?.removeIDs == ["a10", "a11"].map(Self.id))
    }

    /// A group retention leaves whole is still listed (with nothing to remove), so the Keep tab can count it.
    @Test func groupsWithNothingToRemoveAreKept() throws {
        let line = reply([group("a1", paths: current, tags: nil, remove: 0)])
        let groups = try groups(line, plan())
        #expect(groups.count == 1)
        #expect(groups.first?.removeIDs == [])
        #expect(groups.first?.keptCount == 1)
        #expect(EarlierSnapshotsPreview(groups: groups).hasAnythingToRemove == false)
    }

    /// restic prints nothing for a host with no snapshots; a reply that isn't one is an error.
    @Test func emptyAndBrokenReplies() throws {
        #expect(try groups("[]", plan()).isEmpty)
        #expect(throws: (any Error).self) { try groups("[{", plan()) }
        #expect(throws: (any Error).self) {
            try groups(#"[{"host":"pepper","paths":["/a"],"remove":[{"x":1}]}]"#, plan())
        }
    }

    // MARK: Before adoption means before adoption

    /// Fix round 1 (I2): only snapshots taken no later than the adoption are "from before adoption". Another tool
    /// still writing untagged snapshots of the same folders afterwards never has those offered.
    @Test func snapshotsTakenAfterTheAdoptionAreNotFromBeforeIt() throws {
        var g = group("a1", paths: current, tags: nil)
        g.remove.append(Snap(id: Self.id("late"), paths: current, tags: nil, time: "2026-07-01T09:00:00.123456789+10:30"))
        g.remove.append(Snap(id: Self.id("edge"), paths: current, tags: nil, time: "2026-06-01T00:00:00Z"))
        g.remove.append(Snap(id: Self.id("bad"), paths: current, tags: nil, time: "yesterday"))
        let before = try #require(try groups(reply([g]), plan()).first)
        #expect(before.removeIDs == ["a10", "a11", "edge"].map(Self.id))
        #expect(before.keptCount == 1)
    }

    /// A plan adopted before the adoption time was recorded is bounded by its own first snapshot; with none, nothing
    /// is known to be from before adoption, so nothing is offered.
    @Test func withoutARecordedAdoptionTheFirstOwnSnapshotBoundsIt() throws {
        var g = group("a1", paths: current, tags: nil)
        g.remove.append(Snap(id: Self.id("late"), paths: current, tags: nil, time: "2026-03-01T10:00:00+10:30"))
        let own = Group(
            paths: current, tags: [Self.own],
            keep: [Snap(id: Self.id("own2"), paths: current, tags: [Self.own], time: "2026-04-01T10:00:00+10:30"),
                   Snap(id: Self.id("own1"), paths: current, tags: [Self.own], time: "2026-02-01T10:00:00+10:30")],
            remove: [])
        let bounded = try groups(reply([g, own]), plan(adoptedAt: nil))
        #expect(bounded.first?.removeIDs == ["a10", "a11"].map(Self.id))
        #expect(try groups(reply([g]), plan(adoptedAt: nil)).isEmpty)
    }

    @Test func resticTimesAreRead() {
        #expect(EarlierSnapshots.date("2026-10-01T10:01:00.123456789+10:30") != nil)
        #expect(EarlierSnapshots.date("2026-10-01T00:31:00Z") == EarlierSnapshots.date("2026-10-01T10:01:00+09:30"))
        #expect(EarlierSnapshots.date("2026-10-01") == nil)
    }

    // MARK: What is confirmed is what is removed

    /// Only IDs the user confirmed AND a fresh preview still puts in the action's scope are removed: a snapshot
    /// added since can't join, one that has gone or left the scope drops out, and an ID from another scope is
    /// never taken along.
    @Test func theRemovalIsTheConfirmedIDsStillInScope() throws {
        let line = reply([
            group("a1", paths: current, tags: nil, remove: 3),
            group("b1", paths: ["/Users/x/Old"], tags: [Self.own]),
        ])
        let groups = try groups(line, plan())
        let confirmed = EarlierSnapshotsConfirmation(
            scope: .beforeAdoption,
            snapshotIDs: [Self.id("a10"), Self.id("gone"), Self.id("b10"), Self.id("a12"), Self.id("a10")])
        #expect(EarlierSnapshots.removable(confirmed, now: groups) == [Self.id("a10"), Self.id("a12")])
        let previous = EarlierSnapshotsConfirmation(
            scope: .previousFolderList(paths: ["/Users/x/Old/"]), snapshotIDs: [Self.id("b10"), Self.id("a10")])
        #expect(EarlierSnapshots.removable(previous, now: groups) == [Self.id("b10")])
    }

    @Test func confirmationsOfferExactlyTheGroupsIDs() throws {
        let line = reply([group("a1", paths: current, tags: nil)])
        let group = try #require(try groups(line, plan()).first)
        let confirmation = EarlierSnapshotsConfirmation(group)
        #expect(confirmation.scope == .beforeAdoption)
        #expect(confirmation.snapshotIDs == group.removeIDs)
    }

    @Test func confirmationsAreValidatedBeforeTheAgentUsesThem() {
        let good = EarlierSnapshotsConfirmation(scope: .beforeAdoption, snapshotIDs: [Self.id("a1")])
        #expect(good.problem(for: plan()) == nil)
        #expect(good.problem(for: plan(origin: .created)) != nil, "nothing is from before Restorey in a created repository")
        #expect(EarlierSnapshotsConfirmation(scope: .beforeAdoption, snapshotIDs: []).problem(for: plan()) != nil)
        for bad in ["a1b2", String(repeating: "g", count: 64), String(repeating: "A", count: 64), "-" + Self.id("a").dropFirst()] {
            let c = EarlierSnapshotsConfirmation(scope: .beforeAdoption, snapshotIDs: [bad])
            #expect(c.problem(for: plan()) != nil, "\(bad)")
        }
        let current = EarlierSnapshotsConfirmation(
            scope: .previousFolderList(paths: ["/Users/x/Documents", "/Users/x/Code"]), snapshotIDs: [Self.id("a1")])
        #expect(current.problem(for: plan()) != nil, "the current folder list is the plan’s own group")
    }

    // MARK: Coding

    @Test func scopeAndConfirmationJSON() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func json(_ value: some Encodable) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        #expect(try json(EarlierSnapshotScope.beforeAdoption) == #"{"type":"beforeAdoption"}"#)
        #expect(try json(EarlierSnapshotScope.previousFolderList(paths: ["/a"])) == #"{"paths":["\/a"],"type":"previousFolderList"}"#)
        let confirmation = EarlierSnapshotsConfirmation(scope: .previousFolderList(paths: ["/a"]), snapshotIDs: ["x"])
        #expect(try JSONDecoder().decode(EarlierSnapshotsConfirmation.self, from: encoder.encode(confirmation)) == confirmation)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EarlierSnapshotScope.self, from: Data(#"{"type":"everything"}"#.utf8))
        }
    }

    // MARK: Words

    private func sample(_ scope: EarlierSnapshotScope, kept: Int = 3, remove: Int = 12) -> EarlierSnapshotGroup {
        EarlierSnapshotGroup(
            scope: scope, host: "pepper", paths: ["/Users/x/Old", "/Users/x/Older"], tags: [], keptCount: kept,
            removeIDs: (0..<remove).map { Self.id("r\($0)") })
    }

    @Test func theAdoptionConfirmation() {
        let text = EarlierSnapshotsText.confirmation(
            sample(.beforeAdoption), pruneEnabled: false, afterFirstBackup: true, home: "/Users/x")
        #expect(text.title == "Remove 12 snapshots from before Restorey?")
        #expect(text.message == "Retention keeps 3 of the 15 snapshots of these folders from this Mac, other tools’ included; "
            + "the rest go after the first successful backup. Other Macs and folders aren’t touched. Prune is off: the data stays. "
            + "This can’t be undone.")
        #expect(text.button == "Remove 12 Snapshots")
        let settings = EarlierSnapshotsText.confirmation(
            sample(.beforeAdoption, kept: 0), pruneEnabled: true, afterFirstBackup: false, home: "/Users/x")
        #expect(settings.message == "Retention keeps none of the 12 snapshots of these folders from this Mac, other tools’ included. "
            + "Other Macs and folders aren’t touched. Prune frees the space later. This can’t be undone.")
    }

    @Test func thePreviousFolderListConfirmation() {
        let text = EarlierSnapshotsText.confirmation(
            sample(.previousFolderList(paths: ["/Users/x/Old", "/Users/x/Older"]), kept: 0, remove: 1),
            pruneEnabled: true, afterFirstBackup: false, home: "/Users/x")
        #expect(text.title == "Remove 1 snapshot of the previous folder list?")
        #expect(text.message == "Retention keeps none of the 1 snapshot of ~/Old, ~/Older. Prune frees the space later. "
            + "This can’t be undone.")
        #expect(text.button == "Remove 1 Snapshot")
    }

    @Test func theKeepTabRows() {
        #expect(EarlierSnapshotsText.row(sample(.beforeAdoption), home: "/Users/x")
            == "Before Restorey: 15 snapshots from pepper; retention would remove 12.")
        #expect(EarlierSnapshotsText.row(sample(.previousFolderList(paths: ["/Users/x/Old"]), remove: 0), home: "/Users/x")
            == "Previous folder list ~/Old, ~/Older: 3 snapshots; retention would remove none.")
        #expect(EarlierSnapshotsText.nothingToApply(EarlierSnapshotsPreview(groups: []))
            == "No earlier snapshots from this Mac to apply retention to.")
        #expect(EarlierSnapshotsText.nothingToApply(EarlierSnapshotsPreview(groups: [sample(.beforeAdoption, remove: 0)]))
            == "Nothing to apply: retention keeps every earlier snapshot.")
        #expect(EarlierSnapshotsText.nothingToApply(EarlierSnapshotsPreview(groups: [sample(.beforeAdoption)])) == nil)
    }

    @Test func theRemovedSentence() {
        #expect(EarlierSnapshotsText.removed(EarlierSnapshotsRemoval(removed: 12, leftAlone: 0))
            == "Removed 12 earlier snapshots.")
        #expect(EarlierSnapshotsText.removed(EarlierSnapshotsRemoval(removed: 1, leftAlone: 2))
            == "Removed 1 earlier snapshot. 2 confirmed snapshots were left: they had gone, or retention now keeps them.")
        #expect(EarlierSnapshotsText.removed(EarlierSnapshotsRemoval(removed: 0, leftAlone: 1))
            == "No snapshots were removed. 1 confirmed snapshot was left: it had gone, or retention now keeps it.")
    }
}
