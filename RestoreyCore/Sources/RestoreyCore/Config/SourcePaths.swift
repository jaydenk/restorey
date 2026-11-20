import Foundation

/// Where one backup folder lies against another: the one place paths are compared for containment (Task 1).
///
/// `containsByPath` compares the paths as written and never touches the file system (final review I1). It is the one
/// for validation and anything on the agent's status and scheduling path (`Plan.validationErrors()`, `nextRunDate`),
/// which a repository on a hung network volume must not be able to stall. Where links lead is learnt only through
/// `LinkResolver`, on a thread of its own with a deadline, by the agent and by the app adding folders (`FolderDrop.look`,
/// L157); callers then compare the paths it gives back with `containsByPath`.
public enum SourcePaths {
    /// Whether `inner` is `outer` or lies below it, by whole path components (`/Users/me/Doc` doesn't contain
    /// `/Users/me/Documents`). Compared standardised (trailing slashes, `.` and `..` don't matter), as written: a link
    /// is judged by its own path, not where it leads. Never reads the file system.
    ///
    /// `/private/tmp`, `/private/var` and `/private/etc` are their short forms (`/tmp`, `/var`, `/etc`): macOS makes
    /// them one place, and the folder picker stores one spelling where a typed path keeps the other (seen live 20 Nov
    /// 2026). Only those three; `/Users/me` and `/private/Users/me` stay different. A path as written still counts, so
    /// `/private` contains `/private/tmp/x`.
    public static func containsByPath(_ outer: String, _ inner: String) -> Bool {
        comparableComponents(inner).starts(with: comparableComponents(outer))
            || components(inner).starts(with: components(outer))
    }

    /// Whether `a` and `b` are the same path as `containsByPath` compares them (the firmlink spellings agree). Pure.
    public static func sameFirmlinkSpelling(_ a: String, _ b: String) -> Bool {
        comparableComponents(a) == comparableComponents(b)
    }

    /// `path` with `.`, `..` and repeated or trailing slashes removed, as written: `/a/x/../b/` is `/a/b`. Pure: unlike
    /// `URL(fileURLWithPath:)`, which asks the file system whether the path is a folder, it reads nothing.
    public static func standardised(_ path: String) -> String {
        let parts = components(path)
        return path.hasPrefix("/") ? "/" + parts.joined(separator: "/") : parts.joined(separator: "/")
    }

    /// Where `path` leads once every link in it is followed. Reads the file system, and can block for as long as a
    /// volume doesn't answer: only `LinkResolver` calls it.
    public static func resolvingLinks(_ path: String) -> String {
        URL(fileURLWithPath: standardised(path), isDirectory: true).resolvingSymlinksInPath().path
    }

    /// The last component of `path` once standardised, as a sentence names a folder: `/Volumes/Disk/repo/` is `repo`,
    /// `/a/b/..` is `a`. Pure string handling: `URL(fileURLWithPath:)` (no `isDirectory:`) stats the path to learn
    /// whether it is a folder, so it must not name folders anywhere the agent builds a status (final review round 2).
    /// The root, or a path with no components, is returned as it is.
    public static func lastComponent(_ path: String) -> String {
        components(path).last.map(String.init) ?? path
    }

    /// The three firmlinks under `/private` that macOS also reaches by a short path.
    private static let firmlinkNames: Set<Substring> = ["tmp", "var", "etc"]

    /// `components`, with a leading `private/tmp`, `private/var` or `private/etc` shortened to `tmp`, `var` or `etc`.
    private static func comparableComponents(_ path: String) -> [Substring] {
        var parts = components(path)
        if parts.count >= 2, parts[0] == "private", firmlinkNames.contains(parts[1]) { parts.removeFirst() }
        return parts
    }

    private static func components(_ path: String) -> [Substring] {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return parts
    }
}

/// Where paths lead once links are followed (final review round 2): for the agent, `AgentState.savePlan`'s check of a
/// source reaching the repository through a link and a backup's exclusion of where a link to its repository leads; for
/// the app, reading what is being added to a plan's lists (`FolderDrop.look`, L157), so its main actor never waits on a
/// volume.
///
/// Following a link reads the disk, which a network volume that stops answering can hold up for good, so the work runs
/// on a thread of its own (`OwnThread`), never on the cooperative pool, raced against `deadline`, with one outstanding
/// at a time (`OneOutstandingGate`): a check that arrives while an earlier one is stuck past its deadline gives up at
/// once rather than leave another blocked thread behind. Nil when the answer didn't come in time or an earlier check is
/// still stuck; callers then fall back to the paths as written.
public struct LinkResolver: Sendable {
    /// The same bound as the agent's other blocking file-system looks (`MarkedNotForBackup.timeLimit`, 10 s).
    public static let defaultDeadline: TimeInterval = MarkedNotForBackup.timeLimit
    /// One for the whole process, so a stuck check leaves one blocked thread there: in the agent every save and every
    /// backup share it; in the app, every add to a plan's lists.
    public static let live = LinkResolver()

    public let gate: OneOutstandingGate
    public let deadline: TimeInterval
    private let follow: @Sendable (String) -> String

    /// `follow` is `SourcePaths.resolvingLinks` except in tests, which hold it to test the deadline.
    public init(
        gate: OneOutstandingGate = OneOutstandingGate(), deadline: TimeInterval = LinkResolver.defaultDeadline,
        follow: @escaping @Sendable (String) -> String = SourcePaths.resolvingLinks
    ) {
        self.gate = gate
        self.deadline = deadline
        self.follow = follow
    }

    /// Where each of `paths` leads, in order; nil when the file system didn't answer within `deadline`, or an earlier
    /// check is still outstanding past its own.
    public func resolve(_ paths: [String]) async -> [String]? {
        await look { follow in paths.map(follow) }
    }

    /// `work`'s result, handed this resolver's way of following a link, under the same thread, deadline and gate as
    /// `resolve`: for a check that reads more of the disk than where links lead (what an item dropped on a list is).
    /// Nil when it didn't finish within `deadline`, or an earlier check is still outstanding past its own; `work` then
    /// finishes later on its own thread, its result discarded, so it must touch nothing but its own state.
    public func look<Value: Sendable>(
        _ work: @escaping @Sendable (_ follow: @Sendable (String) -> String) -> Value
    ) async -> Value? {
        let end = ContinuousClock.now.advanced(by: .seconds(deadline))
        let (gate, follow) = (gate, follow)
        guard await gate.enter(until: end) else { return nil }
        let remaining = max(0, ContinuousClock.now.duration(to: end) / .seconds(1))
        return await OwnThread.run(
            named: "Restorey link check", qualityOfService: .utility, deadline: remaining, orElse: nil
        ) { () -> Value? in
            let value = work(follow)
            // Only when the work has really returned: a check abandoned at its deadline keeps the gate until then.
            gate.leave()
            return value
        }
    }
}
