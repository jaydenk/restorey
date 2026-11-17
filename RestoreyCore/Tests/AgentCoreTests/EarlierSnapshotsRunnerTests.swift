import Foundation
import Testing
@testable import AgentCore
import RestoreyCore

/// Task 14b against the vendored restic 0.19.1 and real temporary repositories (product spec §5.6): the two opt-in
/// actions remove exactly the snapshots the user confirmed that are still in the action's scope, and nothing else:
/// not another host's, another plan's, another tool's under other folders, a superset of the plan's folders, or the
/// plan's own current group. A preview changes nothing and records nothing; a lock held elsewhere removes nothing.
@Suite(.serialized)
struct EarlierSnapshotsRunnerTests {
    /// The plan keeps one snapshot a day, and every seeded snapshot is from the same day, so each group keeps its
    /// newest and the rest are removable.
    private static let keepOneADay = Retention(hourly: 0, daily: 1, weekly: 0, monthly: 0)

    /// Snapshot IDs by what they are.
    private struct Seeded {
        var beforeAdoption: [String] = []
        var beforeAdoptionTagged: [String] = []
        var otherHost: [String] = []
        var otherPlan: [String] = []
        var superset: [String] = []
        var previousFolderList: [String] = []
        var previousWithUserTag: [String] = []
        var current: [String] = []
    }

    /// Adopted at noon on 1 Oct 2026, local time (restic's `--time` is local too): every seeded snapshot is from
    /// before it.
    private static let adoptedAt = Calendar.current.date(
        from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))!

    private func fixture(
        origin: RepositoryOrigin = .adopted, retryLock: String = "5m", executable: URL? = nil
    ) async throws -> RunnerFixture {
        try await RunnerFixture.make(origin: origin, executable: executable, retryLock: retryLock) {
            $0.retention = Self.keepOneADay
            if origin == .adopted { $0.adoptedAt = Self.adoptedAt }
        }
    }

    /// One snapshot made with plain restic, outside the runner, at `hour` o'clock on `day` Oct 2026. Returns its ID.
    @discardableResult
    private func snapshot(
        _ f: RunnerFixture, host: String = "fixturehost", tags: [String] = [], paths: [URL], hour: Int, day: Int = 1
    ) async throws -> String {
        let time = String(format: "2026-10-%02d %02d:00:00", day, hour)
        let args = ["backup", "--json", "--cache-dir", f.cache.path, "--host=\(host)"]
            + tags.map { "--tag=\($0)" } + ["--time=\(time)", "--"] + paths.map(\.path)
        let done = try await f.restic(.backup) { $0.arguments = args }
        #expect(done.exitCode == 0, "seed backup: \(done.stderrTail)")
        // The summary's snapshot_id is restic's full ID (0.19.1).
        return try #require(done.summary?.snapshotID)
    }

    /// Every kind of snapshot a shared repository holds, three (or two) of each.
    private func seed(_ f: RunnerFixture) async throws -> Seeded {
        let old = f.root.appendingPathComponent("old"), extra = f.root.appendingPathComponent("extra")
        for dir in [old, extra] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "x".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        }
        try f.write("a.txt", "a")
        let own = "restorey:\(f.planID.uuidString)"
        var s = Seeded()
        // Before Restorey (hours 1–3), then the plan's previous folder list (4–6), then its current one (7–9).
        for hour in 1...3 {
            s.beforeAdoption.append(try await snapshot(f, paths: [f.source], hour: hour))
            s.otherHost.append(try await snapshot(f, host: "other-mac", paths: [f.source], hour: hour))
            s.otherPlan.append(try await snapshot(f, tags: ["restorey:\(UUID().uuidString)"], paths: [f.source], hour: hour))
            s.superset.append(try await snapshot(f, paths: [f.source, extra], hour: hour))
            s.previousFolderList.append(try await snapshot(f, tags: [own], paths: [old], hour: hour + 3))
            s.current.append(try await snapshot(f, tags: [own], paths: [f.source], hour: hour + 6))
        }
        for hour in 1...2 {
            s.beforeAdoptionTagged.append(try await snapshot(f, tags: ["daily"], paths: [f.source], hour: hour))
            s.previousWithUserTag.append(try await snapshot(f, tags: [own, "keepme"], paths: [old], hour: hour + 3))
        }
        return s
    }

    /// Retention over the shared timeline keeps the newest of the day, the plan's current snapshot at 09:00, so every
    /// earlier snapshot of the action is removable, while the plan's ordinary `forget`, a group at a time, would keep
    /// the newest of each.

    // MARK: Preview

    @Test(.timeLimit(.minutes(3))) func aPreviewFindsOnlyTheTwoActionsAndChangesNothing() async throws {
        let f = try await fixture()
        defer { f.remove() }
        let seeded = try await seed(f)
        let before = try await f.snapshotIDs()
        let recordsBefore = await f.history().recent

        let preview = try await f.state.previewEarlierSnapshots(f.planID)

        let old = EarlierSnapshots.normalised([f.root.appendingPathComponent("old").path])
        #expect(preview.groups.map(\.scope) == [.beforeAdoption, .previousFolderList(paths: old)])
        let adoption = try #require(preview.group(.beforeAdoption))
        #expect(Set(adoption.removeIDs) == Set(seeded.beforeAdoption + seeded.beforeAdoptionTagged))
        #expect(adoption.keptCount == 0)
        let previous = try #require(preview.group(.previousFolderList(paths: old)))
        #expect(Set(previous.removeIDs) == Set(seeded.previousFolderList))
        #expect(previous.keptCount == 0)
        // A dry run: the same snapshots, no record, no in-progress marker, no lock left.
        #expect(try await f.snapshotIDs() == before)
        #expect(await f.history().recent == recordsBefore)
        #expect(await f.history().runningRecordID == nil)
        #expect(f.lockFiles().isEmpty)
    }

    /// A repository Restorey created has nothing from before Restorey, whatever is untagged in it.
    @Test(.timeLimit(.minutes(3))) func aCreatedRepositoryOffersOnlyPreviousFolderLists() async throws {
        let f = try await fixture(origin: .created)
        defer { f.remove() }
        _ = try await seed(f)
        let preview = try await f.state.previewEarlierSnapshots(f.planID)
        #expect(preview.groups.count == 1)
        #expect(preview.group(.beforeAdoption) == nil)
        await #expect(throws: AgentError.self) {
            try await f.state.removeEarlierSnapshots(EarlierSnapshotsRequest(
                planID: f.planID,
                confirmation: EarlierSnapshotsConfirmation(scope: .beforeAdoption, snapshotIDs: [String(repeating: "a", count: 64)])))
        }
    }

    // MARK: Removal

    @Test(.timeLimit(.minutes(3))) func theAdoptionOptInRemovesOnlyTheConfirmedSnapshots() async throws {
        let f = try await fixture()
        defer { f.remove() }
        let seeded = try await seed(f)
        let before = Set(try await f.snapshots().map(\.id))
        let group = try #require(try await f.state.previewEarlierSnapshots(f.planID).group(.beforeAdoption))

        let removal = try await f.state.removeEarlierSnapshots(
            EarlierSnapshotsRequest(planID: f.planID, confirmation: EarlierSnapshotsConfirmation(group)))

        let confirmed = Set(group.removeIDs)
        #expect(removal == EarlierSnapshotsRemoval(removed: confirmed.count, leftAlone: 0))
        let after = Set(try await f.snapshots().map(\.id))
        #expect(after == before.subtracting(confirmed), "only the confirmed snapshots are gone")
        for survivor in seeded.otherHost + seeded.otherPlan + seeded.superset + seeded.previousFolderList
            + seeded.previousWithUserTag + seeded.current
        {
            #expect(after.contains(survivor))
        }
        // One History row, with its log, naming exactly what went.
        let record = try #require(await f.history().recent.first)
        #expect(record.operation == .forgetSnapshots(ids: group.removeIDs))
        #expect(record.outcome == .success(snapshotID: nil))
        #expect(FileManager.default.fileExists(atPath: f.logs.appendingPathComponent(record.logFile).path))
        #expect(f.lockFiles().isEmpty)
    }

    @Test(.timeLimit(.minutes(3))) func thePreviousFolderListRemovesOnlyItsOwnSnapshots() async throws {
        let f = try await fixture(origin: .created)
        defer { f.remove() }
        let seeded = try await seed(f)
        let before = Set(try await f.snapshots().map(\.id))
        let old = EarlierSnapshots.normalised([f.root.appendingPathComponent("old").path])
        let group = try #require(try await f.state.previewEarlierSnapshots(f.planID).group(.previousFolderList(paths: old)))

        let removal = try await f.state.removeEarlierSnapshots(
            EarlierSnapshotsRequest(planID: f.planID, confirmation: EarlierSnapshotsConfirmation(group)))

        #expect(removal.removed == 3)
        #expect(Set(try await f.snapshots().map(\.id)) == before.subtracting(seeded.previousFolderList))
    }

    /// What is confirmed is the most that goes: a snapshot added after the confirmation (one retention would now
    /// remove) stays, and one removed elsewhere meanwhile is left out of restic's command and counted as left.
    @Test(.timeLimit(.minutes(3))) func aStaleConfirmationRemovesOnlyWhatIsStillConfirmedAndInScope() async throws {
        let f = try await fixture()
        defer { f.remove() }
        _ = try await seed(f)
        let group = try #require(try await f.state.previewEarlierSnapshots(f.planID).group(.beforeAdoption))
        let confirmation = EarlierSnapshotsConfirmation(group)
        // Meanwhile: another client removes one confirmed snapshot, and a new pre-adoption-looking one appears.
        let vanished = confirmation.snapshotIDs[0]
        let forgot = try await f.restic(.backup) {
            $0.arguments = ["forget", "--json", "--cache-dir", f.cache.path, "--", vanished]
        }
        #expect(forgot.exitCode == 0)
        let added = try await snapshot(f, paths: [f.source], hour: 0)
        let before = Set(try await f.snapshots().map(\.id))

        let removal = try await f.state.removeEarlierSnapshots(EarlierSnapshotsRequest(planID: f.planID, confirmation: confirmation))

        #expect(removal == EarlierSnapshotsRemoval(removed: confirmation.snapshotIDs.count - 1, leftAlone: 1))
        let after = Set(try await f.snapshots().map(\.id))
        #expect(after == before.subtracting(confirmation.snapshotIDs))
        #expect(after.contains(added), "a snapshot nobody confirmed is never removed")
        let record = try #require(await f.history().recent.first)
        #expect(record.operation == .forgetSnapshots(ids: Array(confirmation.snapshotIDs.dropFirst())))
    }

    /// Nothing confirmed is still there: no restic forget runs, and the row says nothing needed removing.
    @Test(.timeLimit(.minutes(3))) func aConfirmationWithNothingLeftRunsNoForget() async throws {
        let f = try await fixture()
        defer { f.remove() }
        _ = try await seed(f)
        let missing = EarlierSnapshotsConfirmation(scope: .beforeAdoption, snapshotIDs: [String(repeating: "0", count: 64)])
        let before = try await f.snapshotIDs()
        let removal = try await f.state.removeEarlierSnapshots(EarlierSnapshotsRequest(planID: f.planID, confirmation: missing))
        #expect(removal == EarlierSnapshotsRemoval(removed: 0, leftAlone: 1))
        #expect(try await f.snapshotIDs() == before)
        let record = try #require(await f.history().recent.first)
        #expect(record.operation == .forgetSnapshots(ids: []))
        #expect(record.logFile == "")
    }

    /// restic's own words for an ID it can't find, as 0.19.1 prints them (verified on a real repository).
    @Test func restictsIgnoredLineGivesTheID() {
        let id = String(repeating: "8", count: 64)
        #expect(PlanRunner.ignoredID(#"Ignoring "\#(id)": failed to load snapshot 88888888: open /r/snapshots/\#(id): no such file or directory"#) == id)
        #expect(PlanRunner.ignoredID("Ignoring nothing") == nil)
    }

    // MARK: Locks

    /// Another client's live lock: the preview still counts (it takes no lock), the removal waits `--retry-lock`, then
    /// ends with the sentence, removes nothing and breaks nothing.
    @Test(.timeLimit(.minutes(3))) func aLockHeldElsewhereRemovesNothing() async throws {
        let f = try await fixture(retryLock: "2s")
        defer { f.remove() }
        _ = try await seed(f)
        let group = try #require(try await f.state.previewEarlierSnapshots(f.planID).group(.beforeAdoption))
        let holder = try await LockHolder(f)
        let before = try await f.snapshotIDs()

        #expect(try await f.state.previewEarlierSnapshots(f.planID).group(.beforeAdoption) == group)
        do {
            _ = try await f.state.removeEarlierSnapshots(
                EarlierSnapshotsRequest(planID: f.planID, confirmation: EarlierSnapshotsConfirmation(group)))
            Issue.record("the removal should have been refused by the lock")
        } catch let error as AgentError {
            #expect(error.message.contains("holds its lock, so no snapshots were removed"), "\(error.message)")
        }
        #expect(try await f.snapshotIDs() == before)
        #expect(await f.history().recent.first?.outcome == .locked)
        #expect(!f.lockFiles().isEmpty, "the other client's lock is never broken")
        await holder.release()
    }

    // MARK: Setup's opt-in, after the first backup

    @Test(.timeLimit(.minutes(3))) func setupsChoiceRunsOnlyAfterABackupThatSucceeded() async throws {
        let f = try await fixture()
        defer { f.remove() }
        let seeded = try await seed(f)
        let group = try #require(try await f.state.previewEarlierSnapshots(f.planID).group(.beforeAdoption))
        _ = try await f.state.removeEarlierSnapshotsAfterNextBackup(
            EarlierSnapshotsRequest(planID: f.planID, confirmation: EarlierSnapshotsConfirmation(group)))
        #expect(await f.history().pendingEarlierRemoval == EarlierSnapshotsConfirmation(group))

        // A backup that fails (Full Disk Access missing) deletes nothing and keeps the choice.
        f.fda.set(.missing)
        let refused = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        #expect(!PlanRunHistory.savedData(refused))
        #expect(Set(try await f.snapshots().map(\.id)).isSuperset(of: seeded.beforeAdoption))
        #expect(await f.history().pendingEarlierRemoval != nil)

        f.fda.set(.granted)
        let backup = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        #expect(PlanRunHistory.savedData(backup))
        let after = Set(try await f.snapshots().map(\.id))
        #expect(after.isDisjoint(with: group.removeIDs))
        // The plan's ordinary forget ran after it, a group at a time, so only what it never touches is checked here.
        #expect(after.isSuperset(of: seeded.otherHost + seeded.otherPlan + seeded.superset))
        #expect(await f.history().pendingEarlierRemoval == nil)
        // Fix round 2 (L2): a removal that went as asked is an INFO line, not an ERROR.
        #expect(f.agentInfo.value.contains { $0.contains("Removed \(group.removeIDs.count) earlier snapshots") })
        #expect(!f.agentLog.value.contains { $0.contains("earlier snapshots") })
        let ops = await f.operations()
        let backupIndex = try #require(ops.lastIndex(of: .backup))
        #expect(ops[backupIndex + 1] == .forgetSnapshots(ids: group.removeIDs), "\(ops)")
    }

    /// Fix round 1 (I2): an untagged snapshot of the same folders taken after the adoption (another tool still writing)
    /// is not from before it: it is never offered, and it survives the removal.
    @Test(.timeLimit(.minutes(3))) func aSnapshotTakenAfterTheAdoptionIsNotOffered() async throws {
        let f = try await fixture()
        defer { f.remove() }
        let seeded = try await seed(f)
        // Two on 2 Oct, so retention (one a day) would remove the earlier of them: only the time bound keeps it out.
        let later = try await snapshot(f, paths: [f.source], hour: 1, day: 2)
        let latest = try await snapshot(f, paths: [f.source], hour: 2, day: 2)
        let group = try #require(try await f.state.previewEarlierSnapshots(f.planID).group(.beforeAdoption))
        #expect(Set(group.removeIDs) == Set(seeded.beforeAdoption + seeded.beforeAdoptionTagged))
        #expect(!group.removeIDs.contains(later))
        #expect(group.keptCount == 0, "a snapshot from after the adoption isn't counted as kept from before it either")
        _ = try await f.state.removeEarlierSnapshots(
            EarlierSnapshotsRequest(planID: f.planID, confirmation: EarlierSnapshotsConfirmation(group)))
        #expect(try await f.snapshotIDs().isSuperset(of: [later, latest]))
    }

    /// Fix round 1 (I1): a backup that left files out (`.warning`) isn't the success setup's choice waits for.
    @Test(.timeLimit(.minutes(3))) func setupsChoiceWaitsForABackupWithEveryFile() async throws {
        let f = try await fixture()
        defer { f.remove() }
        let seeded = try await seed(f)
        let group = try #require(try await f.state.previewEarlierSnapshots(f.planID).group(.beforeAdoption))
        _ = try await f.state.removeEarlierSnapshotsAfterNextBackup(
            EarlierSnapshotsRequest(planID: f.planID, confirmation: EarlierSnapshotsConfirmation(group)))
        let unreadable = f.source.appendingPathComponent("unreadable.txt")
        try "secret".write(to: unreadable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        let partial = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        #expect({ if case .warning = partial.outcome { true } else { false } }(), "\(partial.outcome)")
        #expect(await f.history().pendingEarlierRemoval != nil)
        #expect(try await f.snapshotIDs().isSuperset(of: seeded.beforeAdoption))

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path)
        let full = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        #expect(PlanRunner.succeededFully(full.outcome), "\(full.outcome)")
        #expect(await f.history().pendingEarlierRemoval == nil)
        #expect(try await f.snapshotIDs().isDisjoint(with: group.removeIDs))
    }

    // MARK: A preview that fails (I3)

    /// A stand-in restic that fails every earlier-snapshots preview while `flag` exists, and is the vendored restic
    /// otherwise.
    private func failingPreviews(flag: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("restorey-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("restic")
        try """
            #!/bin/sh
            # Only the previews pass --no-lock (it is allowed with forget --dry-run alone).
            case " $* " in *" --no-lock "*)
              if [ -e '\(flag.path)' ]; then
                echo '{"message_type":"exit_error","code":1,"message":"Fatal: the preview broke"}' >&2; exit 1
              fi;;
            esac
            exec '\(try ResticBinary.require().path)' "$@"
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// A removal confirmed in Settings whose fresh preview fails is a failed History row, and removes nothing.
    @Test(.timeLimit(.minutes(3))) func aFailedPreviewDuringAConfirmedRemovalIsAFailedRow() async throws {
        let flag = FileManager.default.temporaryDirectory.appendingPathComponent("restorey-flag-\(UUID().uuidString)")
        let f = try await fixture(executable: try failingPreviews(flag: flag))
        defer { f.remove(); try? FileManager.default.removeItem(at: flag) }
        _ = try await seed(f)
        let group = try #require(try await f.state.previewEarlierSnapshots(f.planID).group(.beforeAdoption))
        let before = try await f.snapshotIDs()
        FileManager.default.createFile(atPath: flag.path, contents: nil)
        await #expect(throws: AgentError.self) {
            try await f.state.removeEarlierSnapshots(
                EarlierSnapshotsRequest(planID: f.planID, confirmation: EarlierSnapshotsConfirmation(group)))
        }
        let record = try #require(await f.history().recent.first)
        #expect(record.operation == .forgetSnapshots(ids: group.removeIDs))
        #expect({ if case .failed(_, let reason) = record.outcome { reason.contains("preview broke") } else { false } }(),
                "\(record.outcome)")
        #expect(try await f.snapshotIDs() == before)
    }

    /// Setup's choice isn't finished by a failed preview: no row, one agent.log line, and it runs at the next backup,
    /// whose row is the one it ends with.
    @Test(.timeLimit(.minutes(3))) func aFailedPreviewKeepsSetupsChoiceForTheNextBackup() async throws {
        let flag = FileManager.default.temporaryDirectory.appendingPathComponent("restorey-flag-\(UUID().uuidString)")
        let f = try await fixture(executable: try failingPreviews(flag: flag))
        defer { f.remove(); try? FileManager.default.removeItem(at: flag) }
        _ = try await seed(f)
        let group = try #require(try await f.state.previewEarlierSnapshots(f.planID).group(.beforeAdoption))
        _ = try await f.state.removeEarlierSnapshotsAfterNextBackup(
            EarlierSnapshotsRequest(planID: f.planID, confirmation: EarlierSnapshotsConfirmation(group)))
        FileManager.default.createFile(atPath: flag.path, contents: nil)
        let first = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        #expect(PlanRunner.succeededFully(first.outcome))
        #expect(await f.history().pendingEarlierRemoval != nil)
        #expect(!(await f.operations()).contains { if case .forgetSnapshots = $0 { true } else { false } })
        #expect(f.agentLog.value.contains { $0.contains("for its next backup") && $0.contains("preview broke") })
        #expect(try await f.snapshotIDs().isSuperset(of: group.removeIDs))
        // Final review I2: the failing preview doesn't hold back the backup's own maintenance.
        let ops = await f.operations()
        let backupIndex = try #require(ops.lastIndex(of: .backup))
        let after = Array(ops[(backupIndex + 1)...])
        #expect(after.contains(.forget(dryRun: false)), "\(after)")
        #expect(after.contains(.check), "\(after)")
        #expect(await f.history().pendingEarlierRemovalFailures?.count == 1)

        try FileManager.default.removeItem(at: flag)
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        #expect(await f.history().pendingEarlierRemoval == nil)
        #expect(await f.history().pendingEarlierRemovalFailures == nil)
        #expect(await f.operations().contains(.forgetSnapshots(ids: group.removeIDs)))
        #expect(try await f.snapshotIDs().isDisjoint(with: group.removeIDs))
    }

    /// Final review I2: a failure that lasts is said once it has happened three backups in a row, and a later success
    /// clears it.
    @Test(.timeLimit(.minutes(3))) func aLastingFailureIsSaidFromTheThirdBackupAndClearedByASuccess() async throws {
        let flag = FileManager.default.temporaryDirectory.appendingPathComponent("restorey-flag-\(UUID().uuidString)")
        let f = try await fixture(executable: try failingPreviews(flag: flag))
        defer { f.remove(); try? FileManager.default.removeItem(at: flag) }
        _ = try await seed(f)
        let group = try #require(try await f.state.previewEarlierSnapshots(f.planID).group(.beforeAdoption))
        _ = try await f.state.removeEarlierSnapshotsAfterNextBackup(
            EarlierSnapshotsRequest(planID: f.planID, confirmation: EarlierSnapshotsConfirmation(group)))
        FileManager.default.createFile(atPath: flag.path, contents: nil)
        for backups in 1...3 {
            _ = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
            #expect(await f.history().pendingEarlierRemovalFailures?.count == backups)
            let problem = try #require(await f.state.status().plans.first { $0.plan.id == f.planID }).earlierRemovalProblem
            if backups < 3 {
                #expect(problem == nil, "backup \(backups)")
            } else {
                #expect(problem?.contains("preview broke") == true, "\(String(describing: problem))")
            }
        }
        try FileManager.default.removeItem(at: flag)
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        #expect(await f.history().pendingEarlierRemoval == nil)
        #expect(await f.history().pendingEarlierRemovalFailures == nil)
        #expect(try #require(await f.state.status().plans.first { $0.plan.id == f.planID }).earlierRemovalProblem == nil)
    }

    /// A lock held elsewhere when the first backup's turn comes: the choice waits for the next backup.
    @Test(.timeLimit(.minutes(3))) func setupsChoiceWaitsOutALock() async throws {
        let f = try await fixture(retryLock: "2s")
        defer { f.remove() }
        _ = try await seed(f)
        let group = try #require(try await f.state.previewEarlierSnapshots(f.planID).group(.beforeAdoption))
        _ = try await f.state.removeEarlierSnapshotsAfterNextBackup(
            EarlierSnapshotsRequest(planID: f.planID, confirmation: EarlierSnapshotsConfirmation(group)))
        let holder = try await LockHolder(f)
        // The backup itself takes a shared lock, which the holder's doesn't block; the removal's exclusive one waits.
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        #expect(await f.history().pendingEarlierRemoval != nil)
        // A lock held elsewhere is a stop, not a failure to count.
        #expect(await f.history().pendingEarlierRemovalFailures == nil)
        #expect(Set(try await f.snapshots().map(\.id)).isSuperset(of: group.removeIDs))
        await holder.release()
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        #expect(await f.history().pendingEarlierRemoval == nil)
        #expect(Set(try await f.snapshots().map(\.id)).isDisjoint(with: group.removeIDs))
    }
}

extension RunnerFixture {
    /// The IDs of every snapshot (restic lists snapshots with the same time in no fixed order).
    func snapshotIDs() async throws -> Set<String> { Set(try await snapshots().map(\.id)) }
}

/// Another restic client holding a live lock: `backup --stdin` reading from a pipe nobody writes to, so it holds its
/// (shared) lock until released. An exclusive lock (forget) can't be taken meanwhile.
private final class LockHolder: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    /// Finishes when restic has exited. `waitUntilExit()` can't be used: it waits on a run loop the test's thread
    /// doesn't run, and hangs.
    private let exited = AsyncStream<Void>.makeStream()

    init(_ f: RunnerFixture) async throws {
        process.executableURL = f.restic
        process.arguments = ["backup", "--stdin", "--host=lock-holder", "--cache-dir", f.root.appendingPathComponent("holder-cache").path]
        process.environment = [
            "RESTIC_REPOSITORY": f.repository.path, "RESTIC_PASSWORD_COMMAND": f.helper.path, "HOME": f.home.path,
            "PATH": "/usr/bin:/bin",
        ]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let continuation = exited.continuation
        process.terminationHandler = { _ in continuation.finish() }
        let before = f.lockFiles()
        try process.run()
        let deadline = ContinuousClock.now + .seconds(30)
        while f.lockFiles() == before, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(f.lockFiles() != before, "the holder never took its lock")
    }

    /// Stops the holder and waits for it: restic removes its lock as it exits, and the next step mustn't find it.
    func release() async {
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
        for await _ in exited.stream {}
    }
}
