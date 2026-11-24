import Foundation
import Synchronization
import Testing
@testable import AgentCore
import RestoreyCore

/// The plan runner end to end, against real restic and a local repository. The Full Disk Access
/// probe, the machine's conditions and the check-in sender are fakes.
@Suite(.timeLimit(.minutes(3)))
struct PlanRunnerTests {
    private static func isFail(_ ping: CheckInPing, heading: String) -> Bool {
        if case .fail(let body) = ping { body.hasPrefix(heading + "\n") } else { false }
    }

    // MARK: One run

    @Test func successfulRunRecordsSnapshotAndSendsOnlyTheSuccessPing() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        try f.write("a.txt", "hello")

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)

        guard case .success(let snapshotID?) = record.outcome else {
            Issue.record("expected a success with a snapshot, got \(record.outcome)")
            return
        }
        #expect(record.operation == .backup)
        #expect(record.trigger == .scheduled)
        #expect(record.summary?.snapshotID == snapshotID)
        #expect(record.droppedLogLines == 0)
        // Exactly one ping, the success: there is no /start (Ruling R57).
        #expect(await f.pings() == [.success])

        let history = await f.history()
        #expect(history.lastSuccessAt == record.endedAt)
        #expect(history.lastSnapshotAt == record.endedAt)
        #expect(history.lastAttemptAt == record.startedAt)
        #expect(history.runningRecordID == nil)
        #expect(history.runningRecord == nil)
        #expect(history.recent.contains(record))
        #expect(history.activeAlerts.isEmpty)

        let snapshots = try await f.snapshots()
        #expect(snapshots.map(\.id) == [snapshotID])
        #expect(snapshots.first?.hostname == "fixturehost")
        #expect(snapshots.first?.tags == ["restorey:\(f.planID.uuidString)"])

        // The run's log is where the record says, and holds no secret.
        #expect(record.logFile.hasPrefix("runs/\(f.planID.uuidString)/"))
        #expect(record.logFile.hasSuffix("-backup.log"))
        let log = try String(contentsOf: f.logs.appendingPathComponent(record.logFile), encoding: .utf8)
        #expect(log.contains(snapshotID))
        #expect(!log.contains(RunnerFixture.password))
    }

    /// Final review I1: the runner resolves a linked local repository off its actor and restic gets both spellings
    /// as exclusions, so the backups are never backed up whichever way the folders reach them.
    @Test func aRepositoryReachedThroughALinkIsExcludedByWhereItLeads() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        try f.write("a.txt", "hello")
        let link = f.root.appendingPathComponent("repo-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.repository)
        try await f.updatePlan { $0.repository = .raw(repository: link.path, environmentNames: []) }
        _ = try await f.state.confirmRecoveryKit(f.planID)

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        guard case .success = record.outcome else { Issue.record("expected a success, got \(record.outcome)"); return }
        let log = try String(contentsOf: f.logs.appendingPathComponent(record.logFile), encoding: .utf8)
        let resolved = link.resolvingSymlinksInPath().path
        #expect(resolved != link.path)
        #expect(log.contains("--exclude=\(DefaultExclusions.pattern(forFolder: link.path))"))
        #expect(log.contains("--exclude=\(DefaultExclusions.pattern(forFolder: resolved)) "))
    }

    /// Fix, 23 Nov 2026: other file systems mounted inside the plan's folders are found before the backup, off the
    /// runner's actor, and restic gets each as an exclusion, so it never reads a mount point from the mounted file
    /// system (CoreDevice's DeviceFS failed that read on every run). With one file system off, none are looked for.
    @Test func otherFileSystemsInsideTheFoldersAreExcluded() async throws {
        let asked = Locked<[[String]]>([])
        let f = try await RunnerFixture.make(otherFileSystems: { sources in
            asked.mutate { $0.append(sources) }
            return sources.map { $0 + "/DeviceFS" }
        })
        defer { f.remove() }
        try f.write("a.txt", "hello")
        _ = try await f.state.confirmRecoveryKit(f.planID)

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        guard case .success = record.outcome else { Issue.record("expected a success, got \(record.outcome)"); return }
        let log = try String(contentsOf: f.logs.appendingPathComponent(record.logFile), encoding: .utf8)
        let sources = await f.plan().sources
        #expect(asked.value == [sources])
        #expect(log.contains("--exclude=\(DefaultExclusions.pattern(forFolder: sources[0] + "/DeviceFS"))"))

        try await f.updatePlan { $0.oneFileSystem = false }
        let off = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        let offLog = try String(contentsOf: f.logs.appendingPathComponent(off.logFile), encoding: .utf8)
        #expect(asked.value.count == 1, "not looked for with one file system off")
        #expect(!offLog.contains("DeviceFS"))
    }

    /// Round 2: following the repository's link has a deadline (the subject: tiny, the check held past it). When the
    /// file system doesn't answer, the backup still runs and leaves out the folder as given, and the agent log says so.
    @Test func aRepositoryLinkThatCantBeFollowedInTimeLeavesOutThePathAsGiven() async throws {
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let gate = OneOutstandingGate()
        let resolver = LinkResolver(gate: gate, deadline: 0.05) { path in
            release.wait()
            release.signal() // a turnstile: one signal frees every check that was ever held
            finished.signal()
            return path + "-resolved"
        }
        let f = try await RunnerFixture.make(linkResolver: resolver)
        defer {
            f.remove()
            release.signal() // never leaves a held thread behind, whatever fails above
        }
        try f.write("a.txt", "hello")
        let plan = await f.plan()
        let repositoryPath = try #require(plan.repository.localFolderPath)

        #expect(await f.runner.repositoryLinkTarget(plan) == nil)
        #expect(f.agentInfo.value.filter { $0.hasPrefix("Couldn’t find out where the repository folder of plan") }.count == 1)
        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        guard case .success = record.outcome else { Issue.record("expected a success, got \(record.outcome)"); return }
        let log = try String(contentsOf: f.logs.appendingPathComponent(record.logFile), encoding: .utf8)
        #expect(log.contains("--exclude=\(DefaultExclusions.pattern(forFolder: repositoryPath))"))
        #expect(!log.contains("-resolved"))
        // Round 3: a stuck check is logged once per episode, not once per backup.
        #expect(f.agentInfo.value.filter { $0.hasPrefix("Couldn’t find out where the repository folder of plan") }.count == 1)

        // Wait for the held work only if a check was admitted (the gate is held while its thread is blocked); a
        // deadline that passed before admission starts no work, and nothing would signal `finished`.
        let admitted = gate.isBusy
        release.signal()
        if admitted { await OwnThread.run(named: "test wait", qualityOfService: .utility) { finished.wait() } }
    }

    /// Spec §8: idle sleep is held off while restic runs, and only then.
    @Test func resticStepsHoldTheSleepAssertionAndASkipTakesNone() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        try f.write("a.txt", "hello")
        f.sleepAssertions.set([])

        f.power.set(PowerState(onBattery: true, percent: 5))
        let skipped = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(skipped.outcome == .skipped(.batteryBelow(20)))
        #expect(f.sleepAssertions.value.isEmpty)

        f.power.set(PowerState(onBattery: false, percent: 100))
        let recordsBefore = await f.history().recent.count
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        // The backup and each maintenance step after it (sequential, through the repository's queue)
        // take one and give it back before the next: strictly create, release, create, release…
        let steps = await f.history().recent.count - recordsBefore
        #expect(steps >= 2)
        #expect(f.sleepAssertions.value == Array(repeating: ["create", "release"], count: steps).flatMap { $0 })
        #expect(!f.sleepPrevention.isHeld)
    }

    // MARK: Unchanged runs

    /// `--skip-if-unchanged` compares whole trees, including the metadata of every folder above the
    /// source, so an entry created beside any ancestor makes a new snapshot. Other tests and processes
    /// keep changing the temporary folders (`$TMPDIR`, /private/tmp); these tests keep their files in
    /// /Users/Shared, which almost nothing touches, one test at a time.
    @Suite(.serialized) struct Unchanged {
        /// Files are still skipped when no snapshot is made, so an unchanged backup is counted too (Task 15b).
        @Test func anUnchangedBackupIsCounted() async throws {
            let f = try await RunnerFixture.make(stableAncestors: true, cloudOnlySkipped: { _, _ in
                .counted(CloudOnlyCount(skipped: 3, includesOtherProviders: false))
            })
            defer { f.remove() }
            try f.write("a.txt", "hello")
            _ = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)

            let second = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
            #expect(second.outcome == .unchanged)
            #expect(second.cloudOnlySkipped?.skipped == 3)
        }

        @Test func unchangedSecondRunIsUnchangedAndPingsSuccess() async throws {
            let f = try await RunnerFixture.make(stableAncestors: true)
            defer { f.remove() }
            try f.write("a.txt", "hello")
            _ = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)

            // A directory source with nothing changed: restic 0.19.1 skips the snapshot.
            let second = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
            #expect(second.outcome == .unchanged)
            #expect(await f.pings() == [.success, .success])
            #expect(try await f.snapshots().count == 1)

            // No snapshot means nothing for forget to thin: only the first backup was followed by forget.
            let ops = await f.operations()
            #expect(ops.filter { $0 == .forget(dryRun: false) }.count == 1)
            #expect(ops.last == .backup)
            #expect(await f.history().lastSuccessAt == second.endedAt)
        }

        @Test func adoptedPlanForgetsAtMostDaily() async throws {
            let f = try await RunnerFixture.make(origin: .adopted, stableAncestors: true)
            defer { f.remove() }
            #expect(await f.plan().forgetCadence == .daily)
            #expect(await f.plan().pruneEnabled == false)

            try f.write("a.txt", "one")
            _ = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
            try f.write("a.txt", "two")
            f.clock.advance(3600)
            _ = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
            var forgets = await f.operations().filter { $0 == .forget(dryRun: false) }
            #expect(forgets.count == 1, "forget ran again within a day")

            // A day after the last forget, a successful backup forgets again, even an unchanged one.
            f.clock.advance(86_400)
            let third = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
            #expect(third.outcome == .unchanged)
            forgets = await f.operations().filter { $0 == .forget(dryRun: false) }
            #expect(forgets.count == 2)
            #expect(await f.operations().contains(.prune) == false)
        }
    }

    // MARK: Maintenance

    /// Ruling R9: forget must touch only this plan's group. Each foreign group has two snapshots older
    /// than the plan's newest, so an unscoped forget would remove one from each.
    @Test func forgetRunsAfterSnapshotForCreatedPlan() async throws {
        // restic 0.19 keeps a group's oldest snapshot while it has fewer buckets than the policy asks
        // for, so the default policy removes nothing from a young repository. One hourly does.
        let f = try await RunnerFixture.make { $0.retention = Retention(hourly: 1, daily: 0, weekly: 0, monthly: 0) }
        defer { f.remove() }
        try f.write("a.txt", "one")
        let plan = await f.plan()

        func seed(_ target: Plan, at times: [String], untagged: Bool = false) async throws {
            for time in times {
                let run = try await f.restic(.backup, plan: target) { inv in
                    // Seeded copies of unchanged data must still make a snapshot each.
                    inv.arguments.removeAll { $0 == "--skip-if-unchanged" }
                    if untagged { inv.arguments.removeAll { $0.hasPrefix("--tag=") } }
                    let separator = inv.arguments.firstIndex(of: "--")!
                    inv.arguments.insert(contentsOf: ["--time", time], at: separator)
                }
                #expect(run.exitCode == 0, "seed: \(run.stderrTail)")
            }
        }
        var otherHost = plan
        otherHost.hostLabel = "otherhost"
        var otherTag = plan
        otherTag.id = UUID()
        let times = ["2026-01-01 10:00:00", "2026-01-01 10:00:30"]
        try await seed(otherHost, at: times)
        try await seed(plan, at: times, untagged: true)
        try await seed(otherTag, at: times)
        try await seed(plan, at: times) // the plan's own group: forget keeps only the newest

        try f.write("a.txt", "two")
        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        guard case .success(let newest?) = record.outcome else {
            Issue.record("expected a snapshot, got \(record.outcome)")
            return
        }

        let history = await f.history()
        let forget = try #require(history.recent.first { $0.operation == .forget(dryRun: false) })
        #expect(forget.outcome == .success(snapshotID: nil))
        #expect(forget.logFile.hasSuffix("-forget.log"))
        #expect(history.lastForgetAt == forget.endedAt)
        #expect(history.recent.firstIndex(of: forget)! < history.recent.firstIndex(of: record)!)

        let snapshots = try await f.snapshots()
        let ownTag = "restorey:\(plan.id.uuidString)"
        let own = snapshots.filter { $0.hostname == "fixturehost" && $0.tags == [ownTag] }
        #expect(own.map(\.id) == [newest], "the plan’s own group keeps only its newest snapshot")
        #expect(snapshots.filter { $0.hostname == "otherhost" }.count == 2)
        #expect(snapshots.filter { $0.hostname == "fixturehost" && $0.tags == nil }.count == 2)
        #expect(snapshots.filter { $0.tags == ["restorey:\(otherTag.id.uuidString)"] }.count == 2)
        #expect(snapshots.count == 7)
    }

    @Test func checkRunsWeeklyAfterPlainUnlock() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        try f.write("a.txt", "one")
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)

        // The first backup is followed by forget, then a plain unlock and check. Prune waits a week
        // from the plan's creation.
        #expect(await f.operations() == [.catConfig, .initRepository, .backup, .forget(dryRun: false), .unlock, .check])
        let history = await f.history()
        let check = try #require(history.recent.first)
        #expect(check.operation == .check)
        #expect(check.outcome == .success(snapshotID: nil))
        #expect(history.lastCheckAt == check.endedAt)
        #expect(history.lastPruneAt == nil)

        // Within the week: no check.
        f.clock.advance(6 * 86_400)
        try f.write("a.txt", "two")
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(await f.operations().filter { $0 == .check }.count == 1)

        // A week after the last check (and the plan's creation): prune, then unlock and check again.
        f.clock.advance(86_400)
        try f.write("a.txt", "three")
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        let ops = await f.operations()
        #expect(Array(ops.suffix(6)) == [.backup, .forget(dryRun: false), .prune, .stats, .unlock, .check])
        #expect(ops.filter { $0 == .check }.count == 2)
        #expect(await f.history().lastPruneAt != nil)
        #expect(await f.history().activeAlerts.isEmpty)
    }

    /// Ruling P2-9: `stats` follows a successful prune (about weekly) and an adopt, and its total becomes
    /// the plan's repository size, dated when it was measured.
    @Test func statsRunsAfterPruneAndAdopt() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        try f.write("a.txt", "one")
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        // No prune yet (a week from the plan's creation), so nothing measured.
        #expect(!(await f.operations()).contains(.stats))
        #expect(await f.history().repositorySize == nil)

        f.clock.advance(7 * 86_400)
        try f.write("a.txt", "two")
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(Array(await f.operations().suffix(5)) == [.forget(dryRun: false), .prune, .stats, .unlock, .check])
        let history = await f.history()
        let stats = try #require(history.recent.first { $0.operation == .stats })
        #expect(stats.outcome == .success(snapshotID: nil))
        #expect(stats.logFile.hasSuffix("-stats.log"))
        let size = try #require(history.repositorySize)
        #expect(size.bytes > 0)
        #expect(size.measuredAt == stats.endedAt)
        #expect(history.activeAlerts.isEmpty)
        #expect(await f.status().repositorySize == size)

        f.clock.advance(60)
        _ = try await f.state.adopt(f.planID)
        await f.runner.waitForMeasurement(planID: f.planID)
        #expect(Array(await f.operations().suffix(2)) == [.snapshots(allHosts: true), .stats])
        let adopted = try #require(await f.history().repositorySize)
        #expect(adopted.measuredAt == f.clock.now)
        #expect(adopted.bytes == size.bytes)
    }

    /// A stats failure fails neither the prune nor the adopt and raises no alert: the size measured before
    /// stays, and the reason goes to agent.log.
    @Test func statsFailureKeepsTheSizeAndRaisesNothing() async throws {
        let restic = try ResticBinary.require()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("restorey-wrapper-\(UUID().uuidString).sh")
        try ("#!/bin/sh\nif [ \"$1\" = stats ]; then echo '{\"message_type\":\"exit_error\",\"code\":1,\"message\":\"Fatal: stats broke\"}' >&2; exit 1; fi\nexec '\(restic.path)' \"$@\"\n")
            .write(to: scratch, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratch.path)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let f = try await RunnerFixture.make(executable: scratch)
        defer { f.remove() }
        let earlier = RepositorySize(bytes: 1234, measuredAt: f.clock.now)
        try await f.state.updateHistory(f.planID) { $0.repositorySize = earlier }
        try f.write("a.txt", "one")
        f.clock.advance(7 * 86_400)
        let backup = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        guard case .success = backup.outcome else {
            Issue.record("a stats failure must not fail the backup, got \(backup.outcome)")
            return
        }
        var history = await f.history()
        #expect(history.recent.first { $0.operation == .prune }?.outcome == .success(snapshotID: nil))
        #expect(history.lastPruneAt != nil)
        let stats = try #require(history.recent.first { $0.operation == .stats })
        #expect(stats.outcome == .failed(exitCode: 1, reason: "Fatal: stats broke"))
        // The steps after it still ran.
        #expect(Array(await f.operations().suffix(3)) == [.stats, .unlock, .check])
        #expect(history.repositorySize == earlier)
        #expect(history.activeAlerts.isEmpty)
        #expect(f.agentLog.value.contains {
            $0.contains("Couldn't measure the repository size for plan \(f.planID.uuidString)") && $0.contains("Fatal: stats broke")
        })

        let report = try await f.state.adopt(f.planID)
        #expect(report.snapshotCount == 1)
        await f.runner.waitForMeasurement(planID: f.planID)
        #expect(await f.operations().last == .stats)
        history = await f.history()
        #expect(history.repositorySize == earlier)
        #expect(history.activeAlerts.isEmpty)
    }

    /// A forget log holds one summary line per group, never restic's JSON reply (about 2.35 KB per kept
    /// snapshot, kept 400 days).
    @Test func forgetLogHoldsASummaryPerGroupAndNoJSON() async throws {
        let f = try await RunnerFixture.make { $0.retention = Retention(hourly: 1, daily: 1, weekly: 1, monthly: 1) }
        defer { f.remove() }
        try f.write("a.txt", "one")
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        let first = try #require(try await f.snapshots().first)
        try f.write("a.txt", "two")
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)

        let forget = try #require(await f.history().recent.first { $0.operation == .forget(dryRun: false) })
        let log = try String(contentsOf: f.logs.appendingPathComponent(forget.logFile), encoding: .utf8)
        let summaries = log.split(separator: "\n").filter { $0.contains(": kept ") }
        #expect(summaries.count == 1, "\(log)")
        let shortID = String(first.id.prefix(8))
        #expect(summaries.first?.hasSuffix(
            "Group host fixturehost, paths \(f.source.path), tags restorey:\(f.planID.uuidString): kept 1, removed 1 (\(shortID))") == true,
            "\(log)")
        for marker in ["\"keep\"", "\"short_id\"", "\"tree\"", "[{"] {
            #expect(!log.contains(marker), "\(marker) in \(log)")
        }
    }

    /// Two groups (the plan's sources changed, so its snapshots group by two path sets): two summary lines.
    @Test func forgetLogHasALinePerGroup() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        try f.write("a.txt", "one")
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        let extra = f.root.appendingPathComponent("extra")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try "x".write(to: extra.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try await f.updatePlan { $0.sources = [f.source.path, extra.path] }
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)

        let forget = try #require(await f.history().recent.first { $0.operation == .forget(dryRun: false) })
        let log = try String(contentsOf: f.logs.appendingPathComponent(forget.logFile), encoding: .utf8)
        let summaries = log.split(separator: "\n").filter { $0.contains(": kept ") }
        #expect(summaries.count == 2, "\(log)")
        #expect(summaries.contains { $0.hasSuffix("paths \(f.source.path), tags restorey:\(f.planID.uuidString): kept 1, removed 0") })
        #expect(summaries.contains {
            $0.hasSuffix("paths \(extra.path), \(f.source.path), tags restorey:\(f.planID.uuidString): kept 1, removed 0")
                || $0.hasSuffix("paths \(f.source.path), \(extra.path), tags restorey:\(f.planID.uuidString): kept 1, removed 0")
        })
        #expect(!log.contains("\"keep\""))
    }

    /// A failing maintenance step is its own record and raises its own alert; the backup stays a success.
    @Test func failedCheckRaisesCheckFailedButLeavesBackupSuccessful() async throws {
        let wrapperBody = { (restic: URL) in
            "if [ \"$1\" = check ]; then echo '{\"message_type\":\"exit_error\",\"code\":1,\"message\":\"Fatal: repository contains errors\"}' >&2; exit 1; fi\nexec '\(restic.path)' \"$@\"\n"
        }
        let restic = try ResticBinary.require()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("restorey-wrapper-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + wrapperBody(restic)).write(to: scratch, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratch.path)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let f = try await RunnerFixture.make(executable: scratch)
        defer { f.remove() }
        try f.write("a.txt", "one")
        let backup = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)

        guard case .success = backup.outcome else {
            Issue.record("a failed check must not fail the backup, got \(backup.outcome)")
            return
        }
        #expect(await f.pings() == [.success])
        let history = await f.history()
        let check = try #require(history.recent.first)
        #expect(check.operation == .check)
        #expect(check.outcome == .failed(exitCode: 1, reason: "Fatal: repository contains errors"))
        #expect(Set(history.activeAlerts.keys) == [.checkFailed])
        #expect(await f.status().alerts == [.checkFailed])
    }

    /// Ruling R37: the end ping reports the backup alone, so it goes out before maintenance starts and a
    /// slow maintenance step can't hold it up. Here `forget` waits for a file the test only writes after
    /// the success ping has arrived.
    @Test func endPingIsSentBeforeMaintenance() async throws {
        let restic = try ResticBinary.require()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("restorey-slowforget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let release = dir.appendingPathComponent("release")
        let started = dir.appendingPathComponent("forget-started")
        let wrapper = dir.appendingPathComponent("restic.sh")
        try """
            #!/bin/sh
            if [ "$1" = forget ]; then
              : > '\(started.path)'
              while [ ! -f '\(release.path)' ]; do /bin/sleep 0.1; done
            fi
            exec '\(restic.path)' "$@"

            """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        let f = try await RunnerFixture.make(executable: wrapper)
        defer { f.remove() }
        try f.write("a.txt", "one")
        let run = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }

        // forget has started and is held; the success ping must already be out.
        let deadline = ContinuousClock.now + .seconds(60)
        while !FileManager.default.fileExists(atPath: started.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: started.path))
        await f.runner.pingsFlushed()
        #expect(await f.checkIn.pings == [.success])
        #expect(await f.history().runningRecord?.operation == .forget(dryRun: false))

        try "".write(to: release, atomically: true, encoding: .utf8)
        guard case .success = try await run.value.outcome else {
            Issue.record("expected a success")
            return
        }
        #expect(await f.pings() == [.success]) // maintenance added nothing
        #expect(await f.operations().suffix(4) == [.backup, .forget(dryRun: false), .unlock, .check])
    }

    // MARK: Refusals before restic

    @Test func fdaMissingSkipsResticAndRaisesCondition() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        try f.write("a.txt", "one")
        f.fda.set(.missing)

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(record.outcome == .failed(exitCode: -1, reason: "Full Disk Access is missing"))
        // Found before the backup starts (Ruling R33): /fail with the reason.
        #expect(await f.pings() == [.fail(body: "not started\nFull Disk Access is missing")])
        #expect(try await f.snapshots().isEmpty)
        #expect(await f.history().activeAlerts[.fullDiskAccessMissing] != nil)
        #expect(await f.status().alerts.contains(.fullDiskAccessMissing))
        #expect(await f.state.status().fdaMissing == true)

        // Once granted, the next run clears it and backs up.
        f.fda.set(.granted)
        let next = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        guard case .success = next.outcome else {
            Issue.record("expected a success once Full Disk Access is granted, got \(next.outcome)")
            return
        }
        #expect(await f.history().activeAlerts[.fullDiskAccessMissing] == nil)
        #expect(await f.state.status().fdaMissing == false)
    }

    // MARK: Backup started and finished notifications

    @Test func startedAndFinishedArePostedOnlyWhenOn() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        let notifier = FakeNotifier(authorised: true)
        await f.state.attach(notifier: notifier, log: { _ in })
        try f.write("a.txt", "one")

        // Off by default: a successful backup posts nothing (and takes away any it posted before).
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        await f.state.eventNotesDelivered()
        #expect(await notifier.events.isEmpty)
        let removedBefore = await notifier.removed

        _ = try await f.state.saveNotificationSettings(
            NotificationSettings(backupStarted: true, backupFinished: true, problems: true))
        try f.write("b.txt", "two")
        let record = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        #expect(PlanRunner.savedData(record.outcome))
        await f.state.eventNotesDelivered()
        let events = await notifier.events
        #expect(events.map(\.title) == ["Backing up — Fixture", "Backed up — Fixture"])
        #expect(Set(events.map(\.identifier)) == ["event.\(f.planID.uuidString)"])
        #expect(await notifier.removed == removedBefore, "a backup that posted Backed up removes nothing")
    }

    /// A failed backup takes its "Backing up" notification away, and posts no "Backed up".
    @Test func aFailedBackupRemovesItsStartedNotification() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        let notifier = FakeNotifier(authorised: true)
        await f.state.attach(notifier: notifier, log: { _ in })
        _ = try await f.state.saveNotificationSettings(
            NotificationSettings(backupStarted: true, backupFinished: true, problems: true))
        try f.write("a.txt", "one")
        try "not-the-password".write(to: f.passwordFile, atomically: true, encoding: .utf8)

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(record.outcome == .wrongPassword)
        await f.state.eventNotesDelivered()
        #expect(await notifier.events.map(\.title) == ["Backing up — Fixture"])
        #expect(await notifier.removed == ["event.\(f.planID.uuidString)"])
    }

    /// A cancelled backup posts no "Backed up", so its "Backing up" goes.
    @Test func aCancelledBackupRemovesItsStartedNotification() async throws {
        let stepped = try steppedBackupStub([.out(Self.cancelStatus), .out(Self.cancelSummary)])
        defer { stepped.finish() }
        let f = try await RunnerFixture.make(executable: stepped.stub)
        defer { f.remove() }
        let notifier = FakeNotifier(authorised: true)
        await f.state.attach(notifier: notifier, log: { _ in })
        _ = try await f.state.saveNotificationSettings(
            NotificationSettings(backupStarted: true, backupFinished: true, problems: true))
        let run = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }
        try await f.waitForPhase { $0.progress?.percentDone == 0.1 }
        _ = try await f.state.cancel(f.planID)
        let record = try await run.value

        #expect(record.outcome == .cancelled)
        await f.state.eventNotesDelivered()
        #expect(await notifier.events.map(\.title) == ["Backing up — Fixture"])
        #expect(await notifier.removed == ["event.\(f.planID.uuidString)"])
    }

    /// A backup the agent died during is marked interrupted on the next start, and the "Backing up" the dead agent
    /// posted goes.
    @Test func recoveryRemovesTheInterruptedBackupsStartedNotification() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        try await f.state.updateHistory(f.planID) {
            $0.runningRecordID = UUID()
            $0.lastAttemptAt = f.clock.now
        }
        let (state, runner) = await f.reloaded()
        let notifier = FakeNotifier(authorised: true)
        await state.attach(notifier: notifier, log: { _ in })
        await runner.recoverAfterStart()
        await state.eventNotesDelivered()
        #expect(await notifier.removed == ["event.\(f.planID.uuidString)"])
        #expect(await notifier.events.isEmpty)
    }

    /// Skipped before restic starts: nothing says it started.
    @Test func aSkippedBackupPostsNoStarted() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        let notifier = FakeNotifier(authorised: true)
        await f.state.attach(notifier: notifier, log: { _ in })
        _ = try await f.state.saveNotificationSettings(
            NotificationSettings(backupStarted: true, backupFinished: true, problems: true))
        f.power.set(PowerState(onBattery: true, percent: 5))

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        guard case .skipped = record.outcome else {
            Issue.record("expected a skip, got \(record.outcome)")
            return
        }
        await f.state.eventNotesDelivered()
        #expect(await notifier.events.isEmpty)
    }

    @Test func wrongPasswordStopsPlan() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        try f.write("a.txt", "one")
        try "not-the-password".write(to: f.passwordFile, atomically: true, encoding: .utf8)

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(record.outcome == .wrongPassword)
        let history = await f.history()
        #expect(history.stoppedReason == "The repository password is wrong")
        #expect(history.activeAlerts[.configurationError] != nil)
        #expect(history.activeAlerts[.backupFailed] != nil)
        #expect(nextRunDate(plan: await f.plan(), history: history, now: f.clock.now) == .distantFuture)
        #expect(await f.status().phase == .stopped(reason: "The repository password is wrong"))
        let pings = await f.pings()
        #expect(pings.count == 1)
        #expect(Self.isFail(pings[0], heading: "restic exit code 12"))
        // No maintenance after a failed backup.
        #expect(await f.operations() == [.catConfig, .initRepository, .backup])
    }

    @Test func missingEnvironmentValueStopsThePlanWithTheKeychainReason() async throws {
        // A raw plan whose environment value is missing from the Keychain can't build restic's
        // environment: the plan stops with the Keychain reason and sends /fail, without running restic.
        let f = try await RunnerFixture.make(createRepository: false) { plan in
            if case .raw(let repository, _) = plan.repository {
                plan.repository = .raw(repository: repository, environmentNames: ["RESTIC_COMPRESSION"])
            }
        }
        defer { f.remove() }
        try f.secrets.write("auto", for: .environment(f.planID, name: "RESTIC_COMPRESSION"))
        _ = try await f.runner.createRepository(planID: f.planID)
        try f.secrets.delete(.environment(f.planID, name: "RESTIC_COMPRESSION"))
        try f.write("a.txt", "one")
        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(record.outcome == .credentialsUnavailable)
        let reason = try #require(await f.history().stoppedReason)
        #expect(reason == "Couldn’t read the backup keys from the Keychain. The environment value RESTIC_COMPRESSION isn’t in the Keychain")
        let pings = await f.pings()
        #expect(pings.count == 1 && Self.isFail(pings[0], heading: "restic exit code 1"))
        #expect(try await f.snapshots().isEmpty)
    }

    /// The helper couldn't read the password (Task 13 notes why), so restic failed some other way:
    /// that is the credentials stop with the helper's reason, not a failure retried every hour.
    @Test func failedBackupWithAHelperFailureIsTheCredentialsStop() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        try f.write("a.txt", "one")
        try "".write(to: f.passwordFile, atomically: true, encoding: .utf8) // restic refuses an empty password
        await f.state.noteHelperFailure(planID: f.planID, reason: "The repository password isn’t in the Keychain")

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        #expect(record.outcome == .credentialsUnavailable)
        let history = await f.history()
        #expect(history.stoppedReason
            == "Couldn’t read the backup keys from the Keychain. The repository password isn’t in the Keychain")
        #expect(nextRunDate(plan: await f.plan(), history: history, now: f.clock.now) == .distantFuture)
        #expect(history.activeAlerts[.configurationError] != nil)
    }

    /// restic's own "no credentials found" (S3's credential_process failed) plus the helper's reason.
    @Test func credentialsUnavailableCarriesTheHelperReason() async throws {
        let restic = try ResticBinary.require()
        let stub = FileManager.default.temporaryDirectory
            .appendingPathComponent("restorey-nocreds-\(UUID().uuidString).sh")
        try """
            #!/bin/sh
            if [ "$1" = backup ]; then
              echo '{"message_type":"exit_error","code":1,"message":"Fatal: unable to open repository: s3.getCredentials: no credentials found"}' >&2
              exit 1
            fi
            exec '\(restic.path)' "$@"

            """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        defer { try? FileManager.default.removeItem(at: stub) }
        let f = try await RunnerFixture.make(executable: stub)
        defer { f.remove() }
        await f.state.noteHelperFailure(planID: f.planID, reason: "The S3 secret access key isn’t in the Keychain")

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(record.outcome == .credentialsUnavailable)
        #expect(await f.history().stoppedReason
            == "Couldn’t read the backup keys from the Keychain. The S3 secret access key isn’t in the Keychain")
        let pings = await f.pings()
        #expect(pings.count == 1)
        if case .fail(let body)? = pings.last {
            #expect(body.hasPrefix("restic exit code 1\n"))
            #expect(body.contains("The S3 secret access key isn’t in the Keychain"))
        } else {
            Issue.record("expected a /fail ping, got \(pings)")
        }
    }

    /// Task 16b: a backup that ends as a warning keeps the distinct unreadable items, with restic's short reason, on its
    /// record; a backup that doesn't end as one keeps none.
    @Test func aWarningBackupKeepsTheItemsItCouldntRead() async throws {
        let stub = FileManager.default.temporaryDirectory.appendingPathComponent("restorey-unreadable-\(UUID().uuidString).sh")
        let error = { (path: String, text: String, during: String) in
            #"{"message_type":"error","error":{"message":"\#(text)"},"during":"\#(during)","item":"\#(path)"}"#
        }
        try """
            #!/bin/sh
            [ "$1" = cat ] && exit 10
            [ "$1" = backup ] || exit 0
            echo '\(error("/Users/me/a", "open /Users/me/a: operation not permitted", "archival"))' >&2
            echo '\(error("/Users/me/a", "open /Users/me/a: operation not permitted", "archival"))' >&2
            echo '\(error("/Users/me/b", "lstat /Users/me/b: no such file or directory", "archival"))' >&2
            echo '\(error("/Users/me/c", "lstat /Users/me/c: no such file or directory", "scan"))' >&2
            exit 3

            """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        defer { try? FileManager.default.removeItem(at: stub) }
        let f = try await RunnerFixture.make(executable: stub)
        defer { f.remove() }

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        #expect(record.outcome == .warning(unreadable: 2))
        #expect(record.unreadableItems == [
            UnreadableItem(path: "/Users/me/a", reason: "operation not permitted"),
            UnreadableItem(path: "/Users/me/b", reason: "no such file or directory"),
        ])
    }

    @Test func onlyAWarningBackupKeepsUnreadableItems() {
        let messages = [ResticItemError(message: "open /a: permission denied", during: "archival", item: "/a")]
        let termination = ResticTermination(exitCode: 3, messages: messages, pid: 1)
        #expect(PlanRunner.unreadableItems(.backup, .warning(unreadable: 1), termination)?.count == 1)
        #expect(PlanRunner.unreadableItems(.backup, .success(snapshotID: "a"), termination) == nil)
        #expect(PlanRunner.unreadableItems(.check, .warning(unreadable: 1), termination) == nil)
        #expect(PlanRunner.unreadableItems(.backup, .warning(unreadable: 1), nil) == nil)
    }

    /// Ruling P2-6: the constrained-network rule is the Mac-wide one in `config.json`, not the plan's.
    @Test func theConstrainedNetworkRuleComesFromTheConfigsNetworkSettings() async throws {
        // Fails at once instead of trying the unreachable repository.
        let stub = FileManager.default.temporaryDirectory.appendingPathComponent("restorey-exit1-\(UUID().uuidString).sh")
        try "#!/bin/sh\nexit 1\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        defer { try? FileManager.default.removeItem(at: stub) }
        let networked: (inout Plan) -> Void = {
            $0.repository = .raw(repository: "rest:http://127.0.0.1:9/repo", environmentNames: [])
        }

        let skipping = try await RunnerFixture.make(executable: stub, createRepository: false, change: networked)
        defer { skipping.remove() }
        skipping.network.set(.satisfied(constrained: true, expensive: false))
        let skipped = try await skipping.runner.runBackup(planID: skipping.planID, trigger: .scheduled)
        #expect(skipped.outcome == .skipped(.constrainedNetwork))

        var off = NetworkSettings.defaults
        off.skipOnConstrainedNetwork = false
        let running = try await RunnerFixture.make(
            executable: stub, createRepository: false, networkSettings: off, change: networked)
        defer { running.remove() }
        running.network.set(.satisfied(constrained: true, expensive: true))
        let ran = try await running.runner.runBackup(planID: running.planID, trigger: .scheduled)
        guard case .failed = ran.outcome else {
            Issue.record("expected restic to run (and the stub to fail), got \(ran.outcome)")
            return
        }
    }

    /// Ruling P2-7: the Mac-wide limit is shared by the backups to networked repositories uploading when
    /// one starts, counting itself; a backup to a folder doesn't count. Each restic keeps the limit it
    /// started with. The stub records each backup's arguments and holds it until released.
    @Test func networkedBackupsShareTheMacWideUploadLimit() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("restorey-share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let release = dir.appendingPathComponent("release")
        let stub = dir.appendingPathComponent("restic.sh")
        try """
            #!/bin/sh
            if [ "$1" = backup ]; then
              for arg in "$@"; do echo "$arg"; done > '\(dir.path)'/args-$$.tmp
              mv '\(dir.path)'/args-$$.tmp '\(dir.path)'/args-$$
              while [ ! -f '\(release.path)' ]; do /bin/sleep 0.05; done
            fi
            exit 1

            """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let settings = NetworkSettings(uploadLimit: .rate(kiB: 1000, unit: .megabytes), skipOnConstrainedNetwork: true, skippedWiFiNames: [])
        let f = try await RunnerFixture.make(executable: stub, createRepository: false, networkSettings: settings) {
            $0.repository = .raw(repository: "rest:http://127.0.0.1:9/one", environmentNames: [])
        }
        defer { f.remove() }
        func addPlan(_ name: String, repository: String, limit: Int? = nil) async throws -> UUID {
            var plan = Plan.newHotPlan(
                name: name, repository: .raw(repository: repository, environmentNames: []), origin: .created,
                hostLabel: "fixturehost", sources: [f.source.path], exclusions: [], now: f.clock.now)
            plan.uploadLimitKiB = limit
            _ = try await f.state.savePlan(SavePlanRequest(
                plan: plan, secrets: [SecretEntry(key: .repositoryPassword(plan.id), value: RunnerFixture.password)]))
            _ = try await f.state.confirmRecoveryKit(plan.id)
            return plan.id
        }
        let two = try await addPlan("Two", repository: "rest:http://127.0.0.1:9/two", limit: 300)
        let three = try await addPlan("Three", repository: "sftp:me@127.0.0.1:/three")
        let folder = try await addPlan("Folder", repository: f.root.appendingPathComponent("folder").path)

        /// The `--limit-upload` value of each backup started so far, by plan.
        func limits() throws -> [UUID: String?] {
            var result: [UUID: String?] = [:]
            for file in try FileManager.default.contentsOfDirectory(atPath: dir.path) where file.hasPrefix("args-")
                && !file.hasSuffix(".tmp")
            {
                let args = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
                    .split(separator: "\n").map(String.init)
                let tag = try #require(args.first { $0.hasPrefix("--tag=restorey:") })
                let id = try #require(UUID(uuidString: String(tag.dropFirst("--tag=restorey:".count))))
                // Not `result[id] =`: assigning a nil `String?` through the subscript would remove the key.
                result.updateValue(args.firstIndex(of: "--limit-upload").map { args[$0 + 1] }, forKey: id)
            }
            return result
        }
        func waitForBackups(_ count: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(30)
            while try limits().count < count, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(try limits().count == count)
        }

        let runFolder = Task { try await f.runner.runBackup(planID: folder, trigger: .scheduled) }
        try await waitForBackups(1)
        #expect(try limits()[folder] == .some(nil), "a folder gets no Mac-wide limit")
        let runOne = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }
        try await waitForBackups(2)
        #expect(try limits()[f.planID] == "1000", "the folder backup doesn’t count")
        let runTwo = Task { try await f.runner.runBackup(planID: two, trigger: .scheduled) }
        try await waitForBackups(3)
        #expect(try limits()[two] == "300", "its own limit is smaller than half")
        let runThree = Task { try await f.runner.runBackup(planID: three, trigger: .scheduled) }
        try await waitForBackups(4)
        #expect(try limits()[three] == "333")
        #expect(try limits()[f.planID] == "1000", "a running backup keeps the limit it started with")

        try "".write(to: release, atomically: true, encoding: .utf8)
        for run in [runFolder, runOne, runTwo, runThree] { _ = try await run.value }

        // Once they have ended, the next backup has the whole limit again.
        for file in try FileManager.default.contentsOfDirectory(atPath: dir.path) where file.hasPrefix("args-") {
            try FileManager.default.removeItem(at: dir.appendingPathComponent(file))
        }
        _ = try await f.runner.runBackup(planID: three, trigger: .scheduled)
        #expect(try limits()[three] == "1000")
    }

    @Test func preflightSkipSendsNoPing() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        try f.write("a.txt", "one")
        f.power.set(PowerState(onBattery: true, percent: 5))

        let skipped = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(skipped.outcome == .skipped(.batteryBelow(20)))
        #expect(await f.history().lastAttemptAt == skipped.startedAt)
        #expect(await f.status().phase == .skipped(.batteryBelow(20)))

        // An unmounted volume is a skip too.
        f.power.set(PowerState(onBattery: false, percent: 100))
        try await f.updatePlan { $0.sources = ["/Volumes/RestoreyNotMounted/Photos"] }
        let unmounted = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(unmounted.outcome == .skipped(.volumeNotMounted("RestoreyNotMounted")))

        #expect(await f.pings() == [])
        #expect(try await f.snapshots().isEmpty)
    }

    /// Ruling R33: a source missing for any reason but an unmounted volume is a failure found before
    /// the backup starts, so /fail goes out with the reason.
    @Test func missingSourceSendsFailWithTheReason() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        try FileManager.default.removeItem(at: f.source)
        let failed = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(failed.outcome == .failed(exitCode: -1, reason: "\(f.source.path) doesn’t exist"))
        #expect(await f.history().activeAlerts[.backupFailed] != nil)
        #expect(await f.pings() == [.fail(body: "not started\n\(f.source.path) doesn’t exist")])
        #expect(try await f.snapshots().isEmpty)
    }

    @Test func noRecoveryKitNoRun() async throws {
        let f = try await RunnerFixture.make(confirmKit: false)
        defer { f.remove() }
        try f.write("a.txt", "one")

        await #expect {
            try await f.state.backUpNow(f.planID)
        } throws: { ($0 as? AgentError)?.message == "Confirm you’ve saved the recovery kit for Fixture before its first backup" }

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        #expect(record.outcome == .failed(
            exitCode: -1, reason: "Confirm you’ve saved the recovery kit for Fixture before its first backup"))
        #expect(await f.pings() == [])
        #expect(try await f.snapshots().isEmpty)
    }

    /// Carry list: a plan that finished setup and needs its kit again (a changed password) is told to save a
    /// new kit, not to confirm one "before its first backup".
    @Test func aChangedPasswordAsksForANewKitInWordsForAnExistingPlan() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        try f.write("a.txt", "one")
        let plan = await f.plan()
        _ = try await f.state.savePlan(SavePlanRequest(
            plan: plan, secrets: [SecretEntry(key: .repositoryPassword(plan.id), value: "a different password")]))
        #expect(await f.state.status().plans.first { $0.plan.id == f.planID }?.setupState == .needsNewKit)

        let expected = "Save a new recovery kit for Fixture — the saved one has the old keys"
        await #expect {
            try await f.state.backUpNow(f.planID)
        } throws: { ($0 as? AgentError)?.message == expected }
        let record = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        #expect(record.outcome == .failed(exitCode: -1, reason: expected))
        #expect(try await f.snapshots().isEmpty)
    }

    @Test func invalidPlanIsRefusedWithoutRestic() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        // Saving refuses an invalid plan, so put one in config.json the way an old file could.
        let store = AgentState.configStore(in: f.support)
        var config = try #require(try await store.load())
        config.plans[0].sources = ["relative/path"]
        try await store.save(config)
        let (_, runner) = await f.reloaded()

        let record = try await runner.runBackup(planID: f.planID, trigger: .manual)
        #expect(record.outcome == .failed(exitCode: -1, reason: "Source folders must be absolute paths"))
        await runner.pingsFlushed()
        #expect(await f.checkIn.pings == [.fail(body: "not started\nSource folders must be absolute paths")])
        #expect(try await f.snapshots().isEmpty)
    }

    // MARK: Pause

    /// Ruling R59: Resume on a paused plan clears the pause and starts one fresh backup at once, as
    /// Back Up Now does (trigger `.manual`), instead of waiting for the interval.
    @Test func resumeWhilePausedStartsOneManualBackup() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        try f.write("a.txt", "one")
        _ = try await f.state.pause(f.planID, for: .oneHour)
        #expect(await f.history().pausedUntil != nil)

        let status = try await f.state.resume(f.planID)
        #expect(status.plans.first?.phase.isRunning == true)
        let record = try #require(await f.runner.waitForBackgroundRun(planID: f.planID))
        #expect(record.trigger == .manual)
        guard case .success = record.outcome else {
            Issue.record("expected the resumed backup to succeed, got \(record.outcome)")
            return
        }
        let history = await f.history()
        #expect(history.pausedUntil == nil)
        #expect(history.recent.filter { $0.operation == .backup }.map(\.id) == [record.id])
    }

    /// Ruling R62: Resume pressed while the paused run is still stopping isn't refused as "already backing
    /// up". restic ignores SIGINT here, so the run is certainly still stopping when Resume arrives; the
    /// fresh backup (trigger `.manual`) starts once the paused run has ended and been recorded.
    @Test func resumeWhileThePausedRunIsStillStoppingStartsAfterIt() async throws {
        let restic = try ResticBinary.require()
        let markerDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("restorey-stubborn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: markerDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: markerDirectory) }
        let marker = markerDirectory.appendingPathComponent("stubborn")
        let wrapper = markerDirectory.appendingPathComponent("restic.sh")
        // Only the first backup is stubborn: it removes the marker as it starts.
        try """
            #!/bin/sh
            if [ "$1" = backup ] && [ -f '\(marker.path)' ]; then
              rm -f '\(marker.path)'
              trap '' INT
              echo '{"message_type":"status","percent_done":0.1,"total_files":1,"files_done":0,"total_bytes":1,"bytes_done":0}'
              exec /bin/sleep 30
            fi
            exec '\(restic.path)' "$@"

            """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        let f = try await RunnerFixture.make(executable: wrapper, gracePeriod: .seconds(2))
        defer { f.remove() }
        try f.write("a.txt", "one")
        try "".write(to: marker, atomically: true, encoding: .utf8)

        let run = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }
        try await f.waitForPhase { $0.progress != nil }
        _ = try await f.state.pause(f.planID, for: .oneHour)
        // The paused run is still stopping (SIGKILL comes after 2 s): Resume returns without an error.
        _ = try await f.state.resume(f.planID)

        let paused = try await run.value
        #expect(paused.outcome == .paused)
        let record = try #require(await f.runner.waitForBackgroundRun(planID: f.planID))
        #expect(record.trigger == .manual)
        #expect(record.startedAt >= paused.endedAt)
        guard case .success = record.outcome else {
            Issue.record("expected the resumed backup to succeed, got \(record.outcome)")
            return
        }
        let history = await f.history()
        #expect(history.pausedUntil == nil)
        // Exactly one backup after the paused one (the stale lock's unlock runs before it).
        #expect(history.recent.filter { $0.operation == .backup }.map(\.id) == [record.id, paused.id])
    }

    /// Back Up Now on a run that is stopping for a pause is refused as before ("already backing up"), not
    /// reported as already running: that run won't carry on. Unlike Resume (Ruling R62), Back Up Now doesn't
    /// queue a backup behind it.
    @Test func backUpNowWhileTheRunIsStoppingForAPauseIsRefused() async throws {
        let restic = try ResticBinary.require()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("restorey-stubborn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("stubborn")
        let wrapper = directory.appendingPathComponent("restic.sh")
        try """
            #!/bin/sh
            if [ "$1" = backup ] && [ -f '\(marker.path)' ]; then
              rm -f '\(marker.path)'
              trap '' INT
              echo '{"message_type":"status","percent_done":0.1,"total_files":1,"files_done":0,"total_bytes":1,"bytes_done":0}'
              exec /bin/sleep 30
            fi
            exec '\(restic.path)' "$@"

            """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        let f = try await RunnerFixture.make(executable: wrapper, gracePeriod: .seconds(2))
        defer { f.remove() }
        try f.write("a.txt", "one")
        try "".write(to: marker, atomically: true, encoding: .utf8)

        let run = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }
        try await f.waitForPhase { $0.progress != nil }
        // Running and carrying on: reported, not refused.
        let live = try await f.state.backUpNow(f.planID)
        #expect(live.alreadyRunning)
        _ = try await f.state.pause(f.planID, for: .oneHour)
        await #expect { try await f.state.backUpNow(f.planID) } throws: {
            ($0 as? AgentError)?.message == "Fixture is already backing up"
        }
        let paused = try await run.value
        #expect(paused.outcome == .paused)
        #expect(await f.runner.waitForBackgroundRun(planID: f.planID) == nil)
    }

    /// Once the backup step has finished, the run's maintenance (forget here) isn't "the backup asked for":
    /// Back Up Now then gets the old refusal, not a silent "already running" that starts nothing.
    @Test func backUpNowDuringTheRunsMaintenanceIsRefusedNotReportedAsRunning() async throws {
        let restic = try ResticBinary.require()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("restorey-maintenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inForget = directory.appendingPathComponent("in-forget")
        let release = directory.appendingPathComponent("release")
        let wrapper = directory.appendingPathComponent("restic.sh")
        // forget waits for the test to let it go, so the run sits in its maintenance.
        try """
            #!/bin/sh
            if [ "$1" = forget ]; then
              touch '\(inForget.path)'
              while [ ! -f '\(release.path)' ]; do /bin/sleep 0.05; done
            fi
            exec '\(restic.path)' "$@"

            """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        let f = try await RunnerFixture.make(executable: wrapper)
        defer { f.remove() }
        try f.write("a.txt", "one")

        let run = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }
        let deadline = ContinuousClock.now + .seconds(60)
        while !FileManager.default.fileExists(atPath: inForget.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: inForget.path))
        #expect(await f.status().phase.isRunning)
        await #expect { try await f.state.backUpNow(f.planID) } throws: {
            ($0 as? AgentError)?.message == "Fixture is already backing up"
        }
        try "".write(to: release, atomically: true, encoding: .utf8)
        let record = try await run.value
        guard case .success = record.outcome else {
            Issue.record("expected the backup to succeed, got \(record.outcome)")
            return
        }
    }

    /// A Resume on a plan that isn't paused only answers with the status.
    @Test func resumeWhileNotPausedStartsNothing() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        try f.write("a.txt", "one")
        let status = try await f.state.resume(f.planID)
        #expect(status.plans.first?.phase == .idle)
        #expect(await f.runner.waitForBackgroundRun(planID: f.planID) == nil)
        #expect(await f.history().recent.allSatisfy { $0.operation != .backup })

        // A pause that has already run out is no pause: the scheduler's catch-up runs it, not Resume.
        try await f.state.updateHistory(f.planID) { $0.pausedUntil = f.clock.now.addingTimeInterval(-1) }
        _ = try await f.state.resume(f.planID)
        #expect(await f.runner.waitForBackgroundRun(planID: f.planID) == nil)
        #expect(await f.history().pausedUntil == nil)
    }

    /// A stopped plan waits for its repository or secrets to be fixed: Resume clears the pause only.
    @Test func resumeWhilePausedButStoppedClearsThePauseOnly() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        try f.write("a.txt", "one")
        try await f.state.updateHistory(f.planID) { $0.stoppedReason = "The repository password is wrong" }
        _ = try await f.state.pause(f.planID, for: .oneHour)

        _ = try await f.state.resume(f.planID)
        #expect(await f.runner.waitForBackgroundRun(planID: f.planID) == nil)
        let history = await f.history()
        #expect(history.pausedUntil == nil)
        #expect(history.stoppedReason == "The repository password is wrong")
        #expect(history.recent.allSatisfy { $0.operation != .backup })
    }

    @Test func pauseThenAutoResume() async throws {
        let f = try await RunnerFixture.make { $0.uploadLimitKiB = 20_000 } // keeps the backup running
        defer { f.remove() }
        try await f.writeRandomFiles(count: 6, megabytes: 30)

        let run = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }
        try await f.waitForPhase { $0.progress != nil }
        let pausedAt = f.clock.now
        _ = try await f.state.pause(f.planID, for: .oneHour)
        let record = try await run.value

        #expect(record.outcome == .paused)
        #expect(await f.pings() == []) // a paused run sends nothing (Ruling R57)
        #expect(f.lockFiles().isEmpty, "an honoured SIGINT removes restic’s own lock")
        let history = await f.history()
        let until = pausedAt.addingTimeInterval(3600)
        #expect(history.pausedUntil == until)
        #expect(nextRunDate(plan: await f.plan(), history: history, now: f.clock.now) == until)
        #expect(await f.status().phase == .paused(until: until))
        #expect(await f.operations() == [.catConfig, .initRepository, .backup]) // no maintenance after a pause

        // Once the hour is up the plan is due, and the run that resumes it clears pausedUntil.
        f.clock.advance(3601)
        #expect(nextRunDate(plan: await f.plan(), history: history, now: f.clock.now) == f.clock.now)
        try await f.updatePlan { $0.uploadLimitKiB = nil }
        let resumed = try await f.runner.runBackup(planID: f.planID, trigger: .catchUp)
        guard case .success = resumed.outcome else {
            Issue.record("expected the resumed run to succeed, got \(resumed.outcome)")
            return
        }
        #expect(await f.history().pausedUntil == nil)
        #expect(await f.pings() == [.success])
    }

    /// Final review M2: the scheduler's tick cuts a pause the clock stretched back to a day from now and
    /// saves it, so it runs out a day later instead of sliding along with the clock.
    @Test func theTickCutsBackAPauseTheClockStretched() async throws {
        let f = try await RunnerFixture.make(createRepository: false)
        defer { f.remove() }
        try await f.state.updateHistory(f.planID) { [now = f.clock.now] in $0.pausedUntil = now.addingTimeInterval(5 * 86400) }

        await f.runner.refreshStatus()
        let limit = f.clock.now.addingTimeInterval(86400)
        #expect(await f.history().pausedUntil == limit)
        #expect(await f.status().phase == .paused(until: limit))
        let saved = try await AgentState.stateStore(in: f.support).load()
        #expect(saved?.plans[f.planID]?.pausedUntil == limit)

        f.clock.advance(1800)
        await f.runner.refreshStatus()
        #expect(await f.history().pausedUntil == limit, "a pause within the day is left alone")
    }

    /// restic ignores SIGINT here, so our SIGKILL ends it: still a pause, but its lock is left behind,
    /// so the next run unlocks first.
    @Test func killedPauseUnlocksBeforeNextRun() async throws {
        let restic = try ResticBinary.require()
        let markerDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("restorey-stubborn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: markerDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: markerDirectory) }
        let marker = markerDirectory.appendingPathComponent("stubborn")
        let wrapper = markerDirectory.appendingPathComponent("restic.sh")
        try """
            #!/bin/sh
            if [ "$1" = backup ] && [ -f '\(marker.path)' ]; then
              trap '' INT
              echo '{"message_type":"status","percent_done":0.1,"total_files":1,"files_done":0,"total_bytes":1,"bytes_done":0}'
              exec /bin/sleep 30
            fi
            exec '\(restic.path)' "$@"

            """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        let f = try await RunnerFixture.make(executable: wrapper, gracePeriod: .seconds(1))
        defer { f.remove() }
        try f.write("a.txt", "one")
        try "".write(to: marker, atomically: true, encoding: .utf8)

        let run = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }
        try await f.waitForPhase { $0.progress != nil }
        _ = try await f.state.pause(f.planID, for: .oneHour)
        #expect(try await run.value.outcome == .paused)

        try FileManager.default.removeItem(at: marker)
        try await f.state.updateHistory(f.planID) { $0.pausedUntil = nil }
        let next = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        guard case .success = next.outcome else {
            Issue.record("expected a success after the unlock, got \(next.outcome)")
            return
        }
        let ops = await f.operations()
        #expect(Array(ops.prefix(5)) == [.catConfig, .initRepository, .backup, .unlock, .backup])
    }

    // MARK: Recovery (Review Focus 3)

    @Test func interruptedRunRecoveredAfterStart() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        try await f.writeRandomFiles(count: 4, megabytes: 20)

        // A restic killed with SIGKILL mid-backup leaves its lock behind, as an agent crash would.
        let plan = await f.plan()
        var invocation = makeInvocation(.backup, plan: plan, context: f.context())
        invocation.arguments.insert(contentsOf: ["--limit-upload", "5000"], at: 1)
        let supervisor = SupervisedProcesses()
        let process = ResticProcess(
            executable: f.restic, invocation: invocation, planID: plan.id, supervisor: supervisor,
            homeDirectory: f.home)
        let killed = Locked(false)
        let termination = try await process.run { message in
            guard case .status = message, !killed.exchange(true) else { return }
            Task { for pid in await supervisor.all() { kill(pid, SIGKILL) } }
        }
        #expect(termination.terminatedBySignal == SIGKILL)
        #expect(!f.lockFiles().isEmpty, "kill -9 left no lock behind")

        // The agent had recorded the run as in progress when it died.
        let started = f.clock.now
        let provisional = RunRecord(
            id: UUID(), planID: plan.id, operation: .backup, trigger: .scheduled, startedAt: started,
            endedAt: started, outcome: .interrupted, summary: nil, logFile: "runs/x/y-backup.log")
        try await f.state.updateHistory(plan.id) {
            $0.runningRecord = provisional
            $0.runningRecordID = provisional.id
        }
        f.clock.advance(60)

        let (state, runner) = await f.reloaded() // the agent starting again
        await runner.recoverAfterStart()

        let history = try await state.runInputs(f.planID).history
        #expect(history.runningRecordID == nil)
        #expect(history.runningRecord == nil)
        let recovered = try #require(history.recent.first { $0.id == provisional.id })
        #expect(recovered.outcome == .interrupted)
        #expect(recovered.startedAt == started)
        #expect(recovered.endedAt == f.clock.now)
        #expect(recovered.logFile == provisional.logFile)
        #expect(history.activeAlerts[.backupFailed] != nil)
        #expect(history.recent.first?.operation == .unlock)
        #expect(f.lockFiles().isEmpty)
        // The interrupted backup's end ping, which it never sent.
        await runner.pingsFlushed()
        #expect(await f.checkIn.pings == [.fail(body: "interrupted\n")])

        let check = try await f.restic(.check) { inv in
            if let i = inv.arguments.firstIndex(of: "--retry-lock") { inv.arguments.removeSubrange(i...(i + 1)) }
        }
        #expect(check.exitCode == 0, "check: \(check.stderrTail)")
    }

    @Test func recoveryOfAnOldStateEntryWithOnlyTheRecordID() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        let id = UUID()
        try await f.state.updateHistory(f.planID) {
            $0.runningRecordID = id
            $0.lastAttemptAt = Date(timeIntervalSince1970: 1_799_999_000)
        }
        let (state, runner) = await f.reloaded()
        await runner.recoverAfterStart()
        let history = try await state.runInputs(f.planID).history
        let recovered = try #require(history.recent.first { $0.id == id })
        #expect(recovered.outcome == .interrupted)
        #expect(recovered.operation == .backup)
        #expect(recovered.startedAt == Date(timeIntervalSince1970: 1_799_999_000))
        #expect(history.runningRecordID == nil)
    }

    /// A run asked for while recovery is unlocking waits for it: the stale lock is gone before the
    /// backup starts, and the new run's in-progress marker is never cleared by recovery's record.
    @Test func runsStartedDuringRecoveryWaitForIt() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        try f.write("a.txt", "one")
        let plan = await f.plan()

        // A stale lock from a restic killed mid-backup, and the run the agent had marked in progress.
        try await f.writeRandomFiles(count: 2, megabytes: 20)
        var invocation = makeInvocation(.backup, plan: plan, context: f.context())
        invocation.arguments.insert(contentsOf: ["--limit-upload", "5000"], at: 1)
        let supervisor = SupervisedProcesses()
        let killed = Locked(false)
        _ = try await ResticProcess(
            executable: f.restic, invocation: invocation, planID: plan.id, supervisor: supervisor,
            homeDirectory: f.home
        ).run { message in
            guard case .status = message, !killed.exchange(true) else { return }
            Task { for pid in await supervisor.all() { kill(pid, SIGKILL) } }
        }
        #expect(!f.lockFiles().isEmpty)
        let stale = RunRecord(
            id: UUID(), planID: plan.id, operation: .backup, trigger: .scheduled, startedAt: f.clock.now,
            endedAt: f.clock.now, outcome: .interrupted, summary: nil, logFile: "")
        try await f.state.updateHistory(plan.id) {
            $0.runningRecord = stale
            $0.runningRecordID = stale.id
        }

        let (state, runner) = await f.reloaded()
        let recovery = Task { await runner.recoverAfterStart() }
        // Once recovery has recorded the interrupted run it is under way; ask for a backup now.
        while (try await state.runInputs(plan.id).history.recent.contains { $0.id == stale.id }) == false {
            try await Task.sleep(for: .milliseconds(5))
        }
        let live = try await runner.runBackup(planID: plan.id, trigger: .scheduled)
        await recovery.value

        guard case .success = live.outcome else {
            Issue.record("expected the backup to succeed after recovery’s unlock, got \(live.outcome)")
            return
        }
        let history = try await state.runInputs(plan.id).history
        let oldestFirst = Array(history.recent.reversed())
        let unlock = try #require(oldestFirst.firstIndex { $0.operation == .unlock })
        let backup = try #require(oldestFirst.firstIndex { $0.id == live.id })
        #expect(unlock < backup, "recovery’s unlock must run before the backup: \(oldestFirst.map(\.operation))")
        #expect(history.runningRecord == nil)
        #expect(history.runningRecordID == nil)
    }

    /// Recovery's `.interrupted` record for an old run leaves a newer run's in-progress marker alone.
    @Test func interruptedRecordNeverClearsAnotherRunsMarker() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        let plan = await f.plan()
        func record(_ outcome: RunOutcome) -> RunRecord {
            RunRecord(
                id: UUID(), planID: plan.id, operation: .backup, trigger: .scheduled, startedAt: f.clock.now,
                endedAt: f.clock.now, outcome: outcome, summary: nil, logFile: "")
        }
        let live = record(.interrupted)
        try await f.state.updateHistory(plan.id) {
            $0.runningRecord = live
            $0.runningRecordID = live.id
        }
        await f.runner.commit(record(.interrupted), plan: plan)
        #expect(await f.history().runningRecord == live)
        #expect(await f.history().runningRecordID == live.id)
        await f.runner.commit(live, plan: plan)
        #expect(await f.history().runningRecord == nil)
        #expect(await f.history().runningRecordID == nil)
    }

    /// Recovery's `unlock` after a start isn't a run of the plan (L168): the status never shows the plan running, so
    /// the menu bar icon doesn't say "backing up" for the seconds a remote unlock takes after every restart.
    @Test func recoveryUnlockDoesNotShowThePlanRunning() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        let (state, runner) = await f.reloaded() // the agent starting again
        let phases = Locked<[PlanPhase]>([])
        await state.setStatusObserver { status in
            phases.mutate { $0 += status.plans.map(\.phase) }
        }
        await runner.recoverAfterStart()
        let history = try await state.runInputs(f.planID).history
        #expect(history.recent.first?.operation == .unlock, "recovery ran its unlock")
        #expect(!phases.value.isEmpty, "the unlock's record was pushed")
        #expect(!phases.value.contains { $0.isRunning }, "pushed phases: \(phases.value)")
        #expect(history.runningRecord == nil)
    }

    /// A delete that arrives while start-up recovery is unlocking (the app's listener is up before the runner is
    /// attached, as in `main.swift`) is refused at once as "still starting up", like Back Up Now, rather than waiting
    /// for an unlock nothing can stop yet.
    @Test func aDeleteDuringRecoveryIsRefusedAtOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("restorey-held-unlock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = directory.appendingPathComponent("unlock-started")
        let release = directory.appendingPathComponent("release")
        let wrapper = directory.appendingPathComponent("restic.sh")
        try """
            #!/bin/sh
            if [ "$1" = unlock ]; then
              : > '\(started.path)'
              while [ ! -f '\(release.path)' ]; do /bin/sleep 0.05; done
            fi
            exec '\(try ResticBinary.require().path)' "$@"

            """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let f = try await RunnerFixture.make(executable: wrapper)
        defer { f.remove() }

        let (state, runner) = await f.reloadedUnattached()
        let recovery = Task {
            await runner.recoverAfterStart()
            await state.attach(runner: runner)
        }
        while !FileManager.default.fileExists(atPath: started.path) { try await Task.sleep(for: .milliseconds(10)) }

        // The unlock is held until the test releases it after the refusal; the fallback release only stops a delete
        // that waits for the unlock from hanging the test (it then finds the release file already there).
        let fallback = Task {
            try await Task.sleep(for: .seconds(30))
            try "".write(to: release, atomically: true, encoding: .utf8)
        }
        await #expect(throws: AgentError.runnerUnavailable) { _ = try await state.deletePlan(f.planID) }
        #expect(!FileManager.default.fileExists(atPath: release.path), "the delete waited for the unlock")
        try "".write(to: release, atomically: true, encoding: .utf8)
        fallback.cancel()
        await recovery.value
        #expect(try await state.runInputs(f.planID).history.recent.first?.operation == .unlock)
    }

    @Test func recoveryLogsAnUnlockItHasToSkip() async throws {
        let f = try await RunnerFixture.make(createRepository: false) { plan in
            if case .raw(let repository, _) = plan.repository {
                plan.repository = .raw(repository: repository, environmentNames: ["RESTIC_COMPRESSION"])
            }
        }
        defer { f.remove() }
        let (_, runner) = await f.reloaded()
        await runner.recoverAfterStart()
        let lines = f.agentLog.value
        #expect(lines.count == 1)
        #expect(lines.first?.contains(f.planID.uuidString) == true)
        #expect(lines.first?.contains("The environment value RESTIC_COMPRESSION isn’t in the Keychain") == true)
    }

    // MARK: Draining (Ruling R35)

    @Test func drainWaitsForQueuedPings() async throws {
        let f = try await RunnerFixture.make(pingDelay: .seconds(4))
        defer { f.remove() }
        try f.write("a.txt", "one")
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(await f.checkIn.pings.count < 2, "the sender is slow, so the pings are still queued")

        #expect(await f.state.prepareForRestart())
        #expect(await f.checkIn.pings == [.success])
    }

    @Test func drainGivesUpOnPingsAfterItsBudget() async throws {
        let f = try await RunnerFixture.make(pingDelay: .seconds(60))
        defer { f.remove() }
        try f.write("a.txt", "one")
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)

        let started = ContinuousClock.now
        #expect(await f.state.prepareForRestart(pingBudget: .milliseconds(300)) == false)
        // Against the 60 s the sender would take, not a tight absolute: the budget is 300 ms.
        #expect(ContinuousClock.now - started < .seconds(30))
        #expect(await f.checkIn.pings.isEmpty)
    }

    /// The agent's own restart drain says how long it really waited (final review M7).
    @Test func aSelfRestartLogsTheRealPingBudget() async throws {
        let f = try await RunnerFixture.make(pingDelay: .seconds(20))
        defer { f.remove() }
        let lines = Locked<[String]>([])
        let exited = Locked(false)
        await f.state.attach(restartExit: { exited.set(true) }, log: { line in lines.mutate { $0.append(line) } })
        try f.write("a.txt", "one")
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)

        await f.state.restartForReplacedBinary(pingBudget: .seconds(1))
        // No time bound: the exit follows the drain, and a hang is caught by the suite's limit.
        while !exited.value { try await Task.sleep(for: .milliseconds(20)) }
        #expect(lines.value.contains("Gave up waiting for check-in pings after 1 second; some may not have been sent"))
        #expect(AgentState.pingsGivenUp(after: .seconds(180)).contains("after 3 minutes;"))
        #expect(AgentState.pingsGivenUp(after: .seconds(90)).contains("after 90 seconds;"))
    }

    // MARK: Progress (Ruling R14)

    /// A stand-in restic whose `backup` prints one line, then waits for the test to create the next `go-N` file before
    /// printing the following, so each state the test asserts on lasts until the test moves on, however slow the runner
    /// is (task 18b: the stub used `/bin/sleep`, which a busy runner can outlast). `steps` are the lines to print, each
    /// after the first preceded by its wait; the last is followed by no wait.
    private struct SteppedStub: Sendable {
        let stub: URL
        let dir: URL
        let steps: Int

        /// Lets the stub print step `n` (the first step needs no release).
        func go(_ n: Int) { FileManager.default.createFile(atPath: dir.appendingPathComponent("go-\(n)").path, contents: nil) }

        /// Releases every step and removes the folder. The stub's wait loop also leaves when its folder is gone, so no
        /// stub outlives a test that stopped early, whatever the order of the two (`aSteppedStubEndsWhenItsFolderIsGone`).
        func finish() {
            for n in 1..<max(steps, 1) { go(n) }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// One line the stub prints, on stdout or stderr.
    private struct Step {
        let line: String
        let stderr: Bool
        static func out(_ line: String) -> Step { Step(line: line, stderr: false) }
        static func err(_ line: String) -> Step { Step(line: line, stderr: true) }
    }

    private func steppedBackupStub(_ steps: [Step]) throws -> SteppedStub {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("restorey-stepped-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var body = "#!/bin/sh\n[ \"$1\" = cat ] && exit 10\n[ \"$1\" = backup ] || exit 0\n"
        for (index, step) in steps.enumerated() {
            if index > 0 {
                body += "while [ ! -f '\(dir.path)/go-\(index)' ]; do [ -d '\(dir.path)' ] || exit 1; /bin/sleep 0.05; done\n"
            }
            body += "echo '\(step.line)'\(step.stderr ? " >&2" : "")\n"
        }
        let stub = dir.appendingPathComponent("restic.sh")
        try body.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return SteppedStub(stub: stub, dir: dir, steps: steps.count)
    }

    /// An early exit leaves no stub running: with its folder removed and no `go-N` ever created, the stub ends.
    @Test func aSteppedStubEndsWhenItsFolderIsGone() async throws {
        let stepped = try steppedBackupStub([.out("a"), .out("b")])
        let output = Pipe()
        let (printed, printedContinuation) = AsyncStream<Void>.makeStream()
        let (ended, endedContinuation) = AsyncStream<Void>.makeStream()
        output.fileHandleForReading.readabilityHandler = { handle in
            if !handle.availableData.isEmpty { printedContinuation.yield() }
        }
        let process = Process()
        process.executableURL = stepped.stub
        process.arguments = ["backup"]
        process.standardOutput = output
        process.terminationHandler = { _ in endedContinuation.yield() }
        try process.run()
        defer { output.fileHandleForReading.readabilityHandler = nil }

        // The stub has printed its first line, so it is now waiting for `go-1`.
        var printedIterator = printed.makeAsyncIterator()
        await printedIterator.next()
        try FileManager.default.removeItem(at: stepped.dir)
        // It must notice the folder is gone and exit rather than spin; a hang is caught by the suite's limit.
        var endedIterator = ended.makeAsyncIterator()
        await endedIterator.next()
        #expect(process.terminationStatus == 1)
    }

    @Test func retryingLineIsShownUntilTheNextStatus() async throws {
        let status = { (percent: Double) in
            #"{"message_type":"status","percent_done":\#(percent),"total_files":2,"files_done":1,"total_bytes":10,"bytes_done":5}"#
        }
        let summary = #"{"message_type":"summary","files_new":1,"files_changed":0,"files_unmodified":0,"data_added":1,"data_added_packed":1,"total_files_processed":1,"total_bytes_processed":1,"total_duration":1,"snapshot_id":"abc123"}"#
        let retry = "Save(<data/0123>) returned error, retrying after 552ms: dial tcp: user:\(RunnerFixture.password)@host connection refused"
        let stepped = try steppedBackupStub([.out(status(0.1)), .err(retry), .out(status(0.5)), .out(summary)])
        defer { stepped.finish() }

        let f = try await RunnerFixture.make(executable: stepped.stub)
        defer { f.remove() }
        let run = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }

        try await f.waitForPhase { $0.progress?.percentDone == 0.1 }
        stepped.go(1)
        try await f.waitForPhase { $0.retrying != nil }
        let retrying = try #require(await f.status().phase.retrying)
        #expect(retrying.contains("retrying after"))
        #expect(!retrying.contains(RunnerFixture.password))
        #expect(await f.status().phase.progress?.percentDone == 0.1)

        stepped.go(2)
        try await f.waitForPhase { $0.progress?.percentDone == 0.5 }
        #expect(await f.status().phase.retrying == nil)

        stepped.go(3)
        let record = try await run.value
        #expect(record.outcome == .success(snapshotID: "abc123"))
        #expect(await f.status().phase == .idle)
    }

    // MARK: Cancel Backup (v0.1.1)

    private static let cancelStatus =
        #"{"message_type":"status","percent_done":0.1,"total_files":2,"files_done":1,"total_bytes":10,"bytes_done":5}"#
    private static let cancelSummary =
        #"{"message_type":"summary","files_new":1,"files_changed":0,"files_unmodified":0,"data_added":1,"data_added_packed":1,"total_files_processed":1,"total_bytes_processed":1,"total_duration":1,"snapshot_id":"abc123"}"#

    /// A backup held mid-run by a stepped stub: Cancel ends it `.cancelled`, with no ping, no alert and no
    /// maintenance after it, and never touches the pause.
    @Test func cancelStopsTheRunAsCancelled() async throws {
        let stepped = try steppedBackupStub([.out(Self.cancelStatus), .out(Self.cancelSummary)])
        defer { stepped.finish() }
        let f = try await RunnerFixture.make(executable: stepped.stub)
        defer { f.remove() }
        let notifier = FakeNotifier(authorised: true)
        await f.state.attach(notifier: notifier, log: { _ in })
        let run = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }
        try await f.waitForPhase { $0.progress?.percentDone == 0.1 }

        let cancel = try await f.state.cancel(f.planID)
        let record = try await run.value

        #expect(cancel.stoppedARun, "the agent log says a run was cancelled")
        #expect(cancel.outcome == .stoppedARun)
        #expect(record.outcome == .cancelled)
        #expect(await f.pings() == [], "neither a /fail nor a success ping")
        await f.state.alertsDelivered()
        #expect(await notifier.titles == [], "no Backup failed notification")
        #expect(await f.operations() == [.catConfig, .initRepository, .backup], "no maintenance after a cancel")
        let history = await f.history()
        #expect(history.pausedUntil == nil)
        #expect(history.runningRecordID == nil)
        #expect(await f.status().phase == .idle)
    }

    /// Cancel isn't a failure and isn't a short retry: the plan runs again at its normal time.
    @Test func aCancelledBackupRunsAgainAtItsNormalTime() async throws {
        let stepped = try steppedBackupStub([.out(Self.cancelStatus), .out(Self.cancelSummary)])
        defer { stepped.finish() }
        let f = try await RunnerFixture.make(executable: stepped.stub)
        defer { f.remove() }
        let run = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }
        try await f.waitForPhase { $0.progress?.percentDone == 0.1 }
        _ = try await f.state.cancel(f.planID)
        #expect(try await run.value.outcome == .cancelled)

        let history = await f.history()
        let plan = await f.plan()
        let lastAttemptAt = try #require(history.lastAttemptAt)
        guard case .interval(let seconds) = plan.schedule else { Issue.record("expected an interval schedule"); return }
        #expect(!isShortRetry(history))
        #expect(nextRunDate(plan: plan, history: history, now: f.clock.now)
            == max(lastAttemptAt.addingTimeInterval(TimeInterval(seconds)), f.clock.now))
    }

    /// Owner, 20 Nov 2026: cancelling never moves the schedule. A Back Up Now half an hour after the last backup (the
    /// plan runs hourly), cancelled, leaves the next backup at the last backup plus the interval, not the cancelled
    /// run's start plus the interval.
    @Test func cancellingABackUpNowLeavesTheScheduleWhereItWas() async throws {
        let stepped = try steppedBackupStub([.out(Self.cancelStatus), .out(Self.cancelSummary)])
        defer { stepped.finish() }
        let f = try await RunnerFixture.make(executable: stepped.stub)
        defer { f.remove() }
        let lastBackup = f.clock.now.addingTimeInterval(-1800)
        try await f.state.updateHistory(f.planID) { $0.lastAttemptAt = lastBackup }

        let run = Task { try await f.runner.runBackup(planID: f.planID, trigger: .manual) }
        try await f.waitForPhase { $0.progress?.percentDone == 0.1 }
        _ = try await f.state.cancel(f.planID)
        #expect(try await run.value.outcome == .cancelled)

        let history = await f.history()
        let plan = await f.plan()
        guard case .interval(let seconds) = plan.schedule else { Issue.record("expected an interval schedule"); return }
        #expect(history.lastAttemptAt == lastBackup)
        #expect(history.attemptBeforeRun == nil, "cleared once the run has its record")
        #expect(nextRunDate(plan: plan, history: history, now: f.clock.now)
            == lastBackup.addingTimeInterval(TimeInterval(seconds)))
    }

    /// Review focus 4: a Cancel that arrives after the run ended changes nothing and records nothing.
    @Test func cancelAfterTheRunEndedDoesNothing() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        try f.write("a.txt", "one")
        let ended = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        guard case .success = ended.outcome else { Issue.record("expected a success, got \(ended.outcome)"); return }
        let before = await f.state.status()
        let recordsBefore = await f.history().recent.count

        let after = try await f.state.cancel(f.planID)

        #expect(!after.stoppedARun, "nothing was running, so the agent log doesn't say a run was cancelled")
        #expect(after.outcome == .nothingToCancel)
        // `generatedAt` and `sequence` move with every status built; everything else must stay as it was.
        #expect(after.status.plans == before.plans)
        #expect(await f.state.status().plans == before.plans)
        #expect(await f.history().recent.count == recordsBefore, "no new record")
        #expect(await f.pings() == [.success], "only the finished run’s ping")
    }

    /// A backup that traps SIGINT, counts each one in `ints`, and stays up until `release` exists: the run is held in
    /// its stopping state however slow the machine is. Once released it exits 130 if it was interrupted (restic's
    /// code), else finishes with a summary, so a second run of the same stub succeeds.
    private struct HeldStopStub: Sendable {
        let stub: URL
        let dir: URL
        func release() { FileManager.default.createFile(atPath: dir.appendingPathComponent("release").path, contents: nil) }
        func interrupts() -> Int {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            return files.filter { $0.hasPrefix("ints-") }.reduce(0) { total, name in
                total + ((try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? "")
                    .split(separator: "\n").count
            }
        }
        func finish() { release(); try? FileManager.default.removeItem(at: dir) }
    }

    private func heldStopStub() throws -> HeldStopStub {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("restorey-heldstop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body = """
            #!/bin/sh
            [ "$1" = cat ] && exit 10
            [ "$1" = backup ] || exit 0
            trap "echo i >> '\(dir.path)/ints-$$'" INT
            echo '\(Self.cancelStatus)'
            while [ ! -f '\(dir.path)/release' ]; do [ -d '\(dir.path)' ] || exit 1; /bin/sleep 0.05; done
            if [ -f "\(dir.path)/ints-$$" ]; then exit 130; fi
            echo '\(Self.cancelSummary)'

            """
        let stub = dir.appendingPathComponent("restic.sh")
        try body.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return HeldStopStub(stub: stub, dir: dir)
    }

    /// Review focus 4: a pause already stopping the run wins; Cancel keeps its outcome and its `pausedUntil`, and
    /// sends no second SIGINT. The stub holds the run stopping until released after Cancel returns.
    @Test func cancelWhileAPauseIsStoppingTheRunKeepsThePause() async throws {
        let held = try heldStopStub()
        defer { held.finish() }
        let f = try await RunnerFixture.make(executable: held.stub, gracePeriod: .seconds(60))
        defer { f.remove() }
        let run = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }
        try await f.waitForPhase { $0.progress?.percentDone == 0.1 }

        _ = try await f.state.pause(f.planID, for: .oneHour)
        let until = try #require(await f.history().pausedUntil)
        let cancel = try await f.state.cancel(f.planID)
        held.release()
        let record = try await run.value

        #expect(cancel.outcome == .alreadyPausing, "the Shortcut says the pause won, not that it cancelled")
        #expect(!cancel.stoppedARun)
        #expect(record.outcome == .paused)
        #expect(held.interrupts() == 1, "the pause’s SIGINT only, never a second")
        #expect(await f.history().pausedUntil == until)
        #expect(await f.status().phase == .paused(until: until))
        #expect(await f.pings() == [])
    }

    /// The first stop wins at the handle itself: a Cancel after a pause is refused and the intent stays `.pause`.
    @Test func aRunHandleKeepsItsFirstStop() {
        let handle = RunHandle(isBackup: true)
        #expect(handle.request(.pause) == nil, "no process attached, so nothing to interrupt, but the intent is recorded")
        #expect(handle.intent == .pause)
        #expect(handle.request(.cancel) == nil)
        #expect(handle.intent == .pause)
    }

    /// Cancel then Pause while the run is stopping, then Resume: Resume queues its backup behind the stopping run
    /// (any pending stop, not only a pause) instead of failing as "already backing up", and the pause is cleared.
    @Test func resumeAfterCancelThenPauseQueuesTheBackup() async throws {
        let held = try heldStopStub()
        defer { held.finish() }
        let f = try await RunnerFixture.make(executable: held.stub, gracePeriod: .seconds(60))
        defer { f.remove() }
        let run = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }
        try await f.waitForPhase { $0.progress?.percentDone == 0.1 }

        _ = try await f.state.cancel(f.planID)
        _ = try await f.state.pause(f.planID, for: .oneHour)
        _ = try await f.state.resume(f.planID)
        #expect(await f.history().pausedUntil == nil)
        held.release()
        #expect(try await run.value.outcome == .cancelled)

        let queued = try #require(await f.runner.waitForBackgroundRun(planID: f.planID), "the queued backup ran")
        guard case .success = queued.outcome else { Issue.record("expected a success, got \(queued.outcome)"); return }
    }

    /// Pause, Resume (a backup queued behind the stopping run), then Cancel: the Cancel drops the queued backup, so
    /// the user who pressed it gets no new backup when the paused run ends.
    @Test func cancelDropsTheBackupResumeQueued() async throws {
        let held = try heldStopStub()
        defer { held.finish() }
        let f = try await RunnerFixture.make(executable: held.stub, gracePeriod: .seconds(60))
        defer { f.remove() }
        let run = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }
        try await f.waitForPhase { $0.progress?.percentDone == 0.1 }

        _ = try await f.state.pause(f.planID, for: .oneHour)
        _ = try await f.state.resume(f.planID)
        _ = try await f.state.cancel(f.planID)
        held.release()
        #expect(try await run.value.outcome == .paused)

        #expect(await f.runner.waitForBackgroundRun(planID: f.planID) == nil, "no queued backup started")
        #expect(await f.operations().filter { $0 == .backup }.count == 1)
    }

    /// Task 16e: the progress carries whether restic has finished counting. A status before the `scan_finished` line
    /// says no; the line itself says yes at once, and so does every status after it.
    @Test func theScanFinishingReachesTheProgress() async throws {
        let status = { (percent: Double) in
            #"{"message_type":"status","percent_done":\#(percent),"total_files":2,"files_done":1,"total_bytes":10,"bytes_done":5}"#
        }
        let scan = #"{"message_type":"verbose_status","action":"scan_finished","item":"","duration":0.1,"data_size":10,"data_size_in_repo":0,"metadata_size":0,"metadata_size_in_repo":0,"total_files":2}"#
        let summary = #"{"message_type":"summary","files_new":1,"files_changed":0,"files_unmodified":0,"data_added":1,"data_added_packed":1,"total_files_processed":1,"total_bytes_processed":1,"total_duration":1,"snapshot_id":"abc123"}"#
        let stepped = try steppedBackupStub([.out(status(0.1)), .out(scan), .out(status(0.5)), .out(summary)])
        defer { stepped.finish() }

        let f = try await RunnerFixture.make(executable: stepped.stub)
        defer { f.remove() }
        let run = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }

        // The stub prints nothing more until released, so each read below sees exactly the state it names.
        try await f.waitForPhase { $0.progress?.percentDone == 0.1 }
        #expect(await f.status().phase.progress?.scanFinished == false)
        stepped.go(1)
        try await f.waitForPhase { $0.progress?.scanFinished == true }
        #expect(await f.status().phase.progress?.percentDone == 0.1)
        stepped.go(2)
        try await f.waitForPhase { $0.progress?.percentDone == 0.5 }
        #expect(await f.status().phase.progress?.scanFinished == true)
        stepped.go(3)
        _ = try await run.value
    }

    // MARK: Actions from the app

    @Test func backUpNowRunsInTheBackgroundAndIgnoresTheSchedule() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        try f.write("a.txt", "one")
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        try f.write("a.txt", "two")
        // Not due for another hour, but a manual run ignores the schedule.
        #expect(nextRunDate(plan: await f.plan(), history: await f.history(), now: f.clock.now) > f.clock.now)

        let reply = try await f.state.backUpNow(f.planID)
        #expect(reply.status.plans.first?.phase.isRunning == true)
        #expect(!reply.alreadyRunning)
        // Asked again while it runs: not a refusal, but its own answer (setup's Done relies on it).
        let again = try await f.state.backUpNow(f.planID)
        #expect(again.alreadyRunning)
        #expect(again.status.plans.first?.phase.isRunning == true)
        let record = try #require(await f.runner.waitForBackgroundRun(planID: f.planID))
        #expect(record.trigger == .manual)
        guard case .success = record.outcome else {
            Issue.record("expected a success, got \(record.outcome)")
            return
        }
        #expect(await f.status().phase == .idle)
    }

    /// Task 9 (final review rows 233, 246): setup's Start confirms the kit it showed and starts the first backup in one
    /// call. The confirmation and the run appear in the same status, so no status (and no scheduler read) ever has the
    /// plan confirmed but not running: it is never "due", and the backup that runs is this manual one.
    @Test func confirmingTheShownKitStartsTheFirstBackupInTheSameTurn() async throws {
        let f = try await RunnerFixture.make(confirmKit: false)
        defer { f.remove() }
        try f.write("a.txt", "one")
        let shown = RecoveryKitDocument.make(try await f.state.recoveryKit(f.planID), createdAt: f.clock.now).digest
        let firstConfirmed = Locked<PlanPhase?>(nil)
        let planID = f.planID
        await f.state.setStatusObserver { status in
            guard let plan = status.plans.first(where: { $0.plan.id == planID }), plan.plan.recoveryKitConfirmedAt != nil
            else { return }
            firstConfirmed.mutate { if $0 == nil { $0 = plan.phase } }
        }

        let status = try await f.state.confirmRecoveryKit(planID: f.planID, kitDigest: shown, startFirstBackup: true)
        #expect(status.plans.first?.setupState == .complete)
        #expect(status.plans.first?.phase.isRunning == true)
        #expect(firstConfirmed.value?.isRunning == true, "confirmed and running appeared together")
        let record = try #require(await f.runner.waitForBackgroundRun(planID: f.planID))
        #expect(record.trigger == .manual)
        guard case .success = record.outcome else {
            Issue.record("expected a success, got \(record.outcome)")
            return
        }
        #expect(await f.history().recent.filter { $0.operation == .backup }.map(\.id) == [record.id])
    }

    /// A kit shown before its keys changed confirms nothing and starts nothing; the plan stays free to start once the
    /// new kit is confirmed.
    @Test func aStaleKitNeitherConfirmsNorStartsTheFirstBackup() async throws {
        let f = try await RunnerFixture.make(confirmKit: false)
        defer { f.remove() }
        try f.write("a.txt", "one")
        let stale = RecoveryKitDocument.digest(for: await f.plan())
        try await f.updatePlan { $0.hostLabel = "otherhost" }

        await #expect { try await f.state.confirmRecoveryKit(planID: f.planID, kitDigest: stale, startFirstBackup: true) }
            throws: { ($0 as? AgentError) == .recoveryKitChanged }
        #expect(await f.plan().recoveryKitConfirmedAt == nil)
        #expect(await f.status().phase.isRunning == false)
        #expect(await f.runner.waitForBackgroundRun(planID: f.planID) == nil)

        let current = RecoveryKitDocument.digest(for: await f.plan())
        let status = try await f.state.confirmRecoveryKit(planID: f.planID, kitDigest: current, startFirstBackup: true)
        #expect(status.plans.first?.phase.isRunning == true)
        let record = try #require(await f.runner.waitForBackgroundRun(planID: f.planID))
        guard case .success = record.outcome else {
            Issue.record("expected a success, got \(record.outcome)")
            return
        }
    }

    @Test func backUpNowStillHonoursPreflight() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        f.power.set(PowerState(onBattery: true, percent: 1))
        let all = try await f.state.backUpNow(nil)
        #expect(!all.alreadyRunning)
        let record = try #require(await f.runner.waitForBackgroundRun(planID: f.planID))
        #expect(record.outcome == .skipped(.batteryBelow(20)))
        #expect(await f.pings() == [])
    }

    /// Final review M5: a refused Back Up Now leaves a line in agent.log, written by the state itself.
    @Test func refusedBackUpNowIsWrittenToTheAgentLog() async throws {
        let f = try await RunnerFixture.make(confirmKit: false)
        defer { f.remove() }
        let lines = Locked<[String]>([])
        await f.state.attach(agentLog: { line in lines.mutate { $0.append(line) } })

        await #expect(throws: AgentError.self) { try await f.state.backUpNow(f.planID) }
        #expect(lines.value == [
            "Refused Back Up Now of plan \(f.planID.uuidString): Confirm you’ve saved the recovery kit for Fixture before its first backup",
        ])
        let unknown = UUID()
        await #expect(throws: AgentError.self) { try await f.state.backUpNow(unknown) }
        #expect(lines.value.last == "Refused Back Up Now of plan \(unknown.uuidString): There’s no plan with that ID")

        await f.state.prepareForRestart()
        await #expect(throws: AgentError.self) { try await f.state.backUpNow(nil) }
        #expect(lines.value.last
            == "Refused Back Up Now of every plan: Restorey is finishing the current backup before updating")
        #expect(lines.value.count == 3)
    }

    /// Final review M6: Back Up Now for every plan still succeeds when one plan can't start, and says
    /// why in agent.log. Here the plan is being deleted while the call runs.
    @Test func backUpNowForEveryPlanLogsAPlanThatCouldNotStart() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        let store = AgentStateTests.ControlledStore(AgentState.configStore(in: f.support))
        let clock = f.clock
        let state = await AgentState(
            configStore: store, stateStore: AgentState.stateStore(in: f.support), secrets: f.secrets,
            credentialsDirectory: f.support, now: { clock.now })
        var dependencies = f.dependencies
        dependencies.state = state
        let runner = PlanRunner(dependencies: dependencies)
        await state.attach(runner: runner)

        await store.holdNextSave()
        let delete = Task { try await state.deletePlan(f.planID) }
        await store.waitUntilHeld()
        _ = try await state.backUpNow(nil)
        #expect(f.agentLog.value == ["Back Up Now couldn't start plan \(f.planID.uuidString): Fixture is being deleted"])
        #expect(await runner.waitForBackgroundRun(planID: f.planID) == nil)
        await store.release()
        _ = try await delete.value
    }

    @Test func createRepositoryRefusesAnExistingRepository() async throws {
        let f = try await RunnerFixture.make() // has already created it once
        defer { f.remove() }
        #expect(await f.operations() == [.catConfig, .initRepository])
        #expect(await f.history().recent.first?.outcome == .success(snapshotID: nil))
        let config = f.repository.appendingPathComponent("config")
        let before = try Data(contentsOf: config)

        // The probe finds the repository, so init never runs.
        await #expect {
            try await f.state.createRepository(f.planID)
        } throws: { ($0 as? AgentError)?.message == "A repository already exists there" }
        #expect(await f.operations() == [.catConfig, .initRepository, .catConfig])
        #expect(await f.history().recent.first?.outcome == .success(snapshotID: nil))
        #expect(try Data(contentsOf: config) == before)
    }

    @Test func createRepositoryProbesThenInitialisesAnEmptyLocation() async throws {
        let f = try await RunnerFixture.make(createRepository: false)
        defer { f.remove() }
        _ = try await f.state.createRepository(f.planID)
        let history = await f.history()
        #expect(history.recent.map(\.operation) == [.initRepository, .catConfig])
        #expect(history.recent.map(\.outcome) == [.success(snapshotID: nil), .repositoryMissing])
        #expect(history.stoppedReason == nil) // the probe's "nothing there" is not a stop
        #expect(FileManager.default.fileExists(atPath: f.repository.appendingPathComponent("config").path))
    }

    @Test func createRepositoryReportsAProbeThatFails() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        try "wrong".write(to: f.passwordFile, atomically: true, encoding: .utf8)
        await #expect {
            try await f.state.createRepository(f.planID)
        } throws: {
            ($0 as? AgentError)?.message == "Restorey couldn’t check the repository address: The repository password is wrong"
        }
        #expect(await f.operations() == [.catConfig, .initRepository, .catConfig])
    }

    /// Real stderr from restic 0.19.1 is not available for a missing AWS bucket here (see the round-2
    /// report: B2 answers a missing bucket with NoSuchKey, exit 10). The text is minio-go's message for
    /// S3's `NoSuchBucket`.
    @Test func probeFailureNamesAMissingBucketForS3Only() throws {
        let s3 = Repository.s3(S3Location(
            provider: .s3, endpoint: try #require(URL(string: "https://s3.eu-west-2.amazonaws.com")),
            bucket: "my-backups", prefix: "mac"))
        let stderr = [#"{"message_type":"exit_error","code":1,"message":"Fatal: unable to open config file: Stat: The specified bucket does not exist."}"#]
        let outcome = RunOutcome.failed(exitCode: 1, reason: "Fatal: unable to open config file: Stat: The specified bucket does not exist.")
        #expect(PlanRunner.probeFailureMessage(repository: s3, outcome: outcome, stoppedReason: nil, stderr: stderr)
            == "The bucket my-backups doesn’t exist or this key can’t see it. Create it in your provider’s console first")
        #expect(PlanRunner.probeFailureMessage(
            repository: s3, outcome: .failed(exitCode: 1, reason: "NoSuchBucket"), stoppedReason: nil, stderr: [])
            .hasPrefix("The bucket my-backups doesn’t exist"))

        // Any other failure, or a non-S3 repository, keeps restic's own reason.
        #expect(PlanRunner.probeFailureMessage(
            repository: s3, outcome: .failed(exitCode: 1, reason: "Fatal: connection refused"), stoppedReason: nil,
            stderr: []) == "Restorey couldn’t check the repository address: Fatal: connection refused")
        #expect(PlanRunner.probeFailureMessage(
            repository: .raw(repository: "/r", environmentNames: []), outcome: outcome, stoppedReason: nil,
            stderr: stderr).hasPrefix("Restorey couldn’t check the repository address: "))
    }

    static let b2Endpoint = ProcessInfo.processInfo.environment["RESTOREY_B2_TEST_ENDPOINT"]
    static let b2Bucket = ProcessInfo.processInfo.environment["RESTOREY_B2_TEST_BUCKET"]
    static let b2KeyID = ProcessInfo.processInfo.environment["RESTOREY_B2_TEST_KEY_ID"]
    static let b2Key = ProcessInfo.processInfo.environment["RESTOREY_B2_TEST_APP_KEY"]
    static let b2Configured = [b2Endpoint, b2Bucket, b2KeyID, b2Key].allSatisfy { !($0 ?? "").isEmpty }

    /// The create probe against a real B2 bucket: an empty prefix is "nothing there" (exit 10), so the
    /// action would go on to init. Read-only: it never runs init.
    @Test(.enabled(if: b2Configured,
                   "set RESTOREY_B2_TEST_ENDPOINT, RESTOREY_B2_TEST_BUCKET, RESTOREY_B2_TEST_KEY_ID and RESTOREY_B2_TEST_APP_KEY"))
    func b2ProbeOfAnEmptyPrefixIsRepositoryMissing() async throws {
        let f = try await RunnerFixture.make(createRepository: false)
        defer { f.remove() }
        var plan = await f.plan()
        plan.repository = .s3(S3Location(
            provider: .b2, endpoint: try #require(URL(string: Self.b2Endpoint ?? "")),
            bucket: Self.b2Bucket ?? "", prefix: "task14-probe-\(UUID().uuidString.prefix(8).lowercased())"))

        // A stand-in for the agent's s3-credentials helper. The keys come from the environment and live
        // only in this 0700 script inside the fixture, which is removed with it.
        let helper = f.root.appendingPathComponent("s3-helper.sh")
        let expiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        try """
            #!/bin/sh
            echo '{"Version":1,"AccessKeyId":"\(Self.b2KeyID ?? "")","SecretAccessKey":"\(Self.b2Key ?? "")","Expiration":"\(expiry)"}'

            """.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let credentials = try CredentialsFile.write(planID: plan.id, helper: helper, directory: f.support)

        var context = f.context()
        context.credentialsFile = credentials
        let invocation = makeInvocation(.catConfig, plan: plan, context: context)
        let termination = try await ResticProcess(
            executable: f.restic, invocation: invocation, planID: plan.id, supervisor: SupervisedProcesses(),
            homeDirectory: f.home
        ).run { _ in }
        #expect(termination.exitCode == 10, "\(termination.stderrTail)")
        #expect(termination.exitErrorMessage?.contains("The specified key does not exist") == true)
    }

    @Test func noRunEverInitialisesTheRepository() async throws {
        let f = try await RunnerFixture.make(createRepository: false)
        defer { f.remove() }
        try f.write("a.txt", "one")
        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(record.outcome == .repositoryMissing)
        #expect(!FileManager.default.fileExists(atPath: f.repository.appendingPathComponent("config").path))
        #expect(await f.history().stoppedReason == "There’s no restic repository at this plan’s address")
        #expect(await f.operations() == [.backup])
    }

    @Test func adoptReportsEveryHostAndNeverForgets() async throws {
        let f = try await RunnerFixture.make(origin: .adopted)
        defer { f.remove() }
        try f.write("a.txt", "one")
        let plan = await f.plan()
        var other = plan
        other.hostLabel = "otherhost"
        other.sources = [f.home.path]
        for target in [plan, other, plan] {
            try f.write("a.txt", UUID().uuidString)
            let run = try await f.restic(.backup, plan: target)
            #expect(run.exitCode == 0, "seed: \(run.stderrTail)")
        }

        let report = try await f.state.adopt(f.planID)
        #expect(report == AdoptReport(hosts: ["fixturehost", "otherhost"], latestPathsForHost: [f.source.path], snapshotCount: 3))
        #expect(try await f.snapshots().count == 3)
        await f.runner.waitForMeasurement(planID: f.planID)
        #expect(await f.operations() == [.catConfig, .initRepository, .snapshots(allHosts: true), .stats])
    }

    // MARK: Measuring after an adopt (Ruling P2-9, fix round 1)

    /// A restic stand-in that, while `hold-<command>` exists in `control`, touches `started-<command>` and
    /// waits for `go-<command>` before running the real restic (for `snapshots` and `stats`).
    private static func holdingRestic(control: URL) throws -> URL {
        let restic = try ResticBinary.require()
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        let script = control.appendingPathComponent("restic.sh")
        let c = control.path
        try """
            #!/bin/sh
            for command in snapshots stats; do
              if [ "$1" = "$command" ] && [ -f '\(c)'/hold-$command ]; then
                touch '\(c)'/started-$command
                while [ ! -f '\(c)'/go-$command ]; do sleep 0.05; done
              fi
            done
            exec '\(restic.path)' "$@"

            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private static func touch(_ control: URL, _ name: String) {
        FileManager.default.createFile(atPath: control.appendingPathComponent(name).path, contents: nil)
    }

    private static func exists(_ control: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: control.appendingPathComponent(name).path)
    }

    /// The adopt replies when the listing is done; `stats` follows as its own job in the queue, with the
    /// plan idle meanwhile, and sets the size once it finishes.
    @Test func adoptRepliesBeforeItsMeasurement() async throws {
        let control = FileManager.default.temporaryDirectory.appendingPathComponent("restorey-hold-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: control) }
        let f = try await RunnerFixture.make(origin: .adopted, executable: try Self.holdingRestic(control: control))
        defer { f.remove() }
        try f.write("a.txt", "one")
        #expect(try await f.restic(.backup).exitCode == 0)
        Self.touch(control, "hold-stats")

        let report = try await f.state.adopt(f.planID)
        #expect(report.snapshotCount == 1)
        #expect(await eventually { Self.exists(control, "started-stats") })
        // Replied while stats is still held: nothing recorded or measured yet, and the plan isn't running.
        #expect(await f.history().recent.contains { $0.operation == .stats } == false)
        #expect(await f.history().repositorySize == nil)
        #expect(await f.status().phase == .idle)

        Self.touch(control, "go-stats")
        await f.runner.waitForMeasurement(planID: f.planID)
        let stats = try #require(await f.history().recent.first)
        #expect(stats.operation == .stats)
        #expect(stats.outcome == .success(snapshotID: nil))
        #expect(await f.history().repositorySize?.bytes ?? 0 > 0)
    }

    /// Pausing or deleting the plan while its measurement runs stops it: no size, and a delete isn't refused.
    @Test func pauseOrDeleteStopsARunningMeasurement() async throws {
        for deleting in [false, true] {
            let control = FileManager.default.temporaryDirectory.appendingPathComponent("restorey-hold-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: control) }
            let f = try await RunnerFixture.make(
                origin: .adopted, executable: try Self.holdingRestic(control: control), gracePeriod: .seconds(2))
            defer { f.remove() }
            try f.write("a.txt", "one")
            #expect(try await f.restic(.backup).exitCode == 0)
            Self.touch(control, "hold-stats")
            _ = try await f.state.adopt(f.planID)
            #expect(await eventually { Self.exists(control, "started-stats") })

            if deleting {
                _ = try await f.state.deletePlan(f.planID)
                await f.runner.waitForMeasurement(planID: f.planID)
                #expect(await f.state.status().plans.isEmpty)
                #expect(!FileManager.default.fileExists(atPath: f.logs.appendingPathComponent("runs/\(f.planID.uuidString)").path))
            } else {
                _ = try await f.state.pause(f.planID, for: .oneHour)
                await f.runner.waitForMeasurement(planID: f.planID)
                let stats = try #require(await f.history().recent.first { $0.operation == .stats })
                #expect(stats.outcome == .paused)
                #expect(await f.history().repositorySize == nil)
                #expect(await f.history().activeAlerts.isEmpty)
            }
        }
    }

    /// A measurement still waiting in the queue doesn't start once the plan is paused or deleted, and says
    /// so in agent.log.
    @Test func aQueuedMeasurementDoesNotStartOncePausedOrDeleted() async throws {
        for deleting in [false, true] {
            let control = FileManager.default.temporaryDirectory.appendingPathComponent("restorey-hold-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: control) }
            let f = try await RunnerFixture.make(origin: .adopted, executable: try Self.holdingRestic(control: control))
            defer { f.remove() }
            try f.write("a.txt", "one")
            #expect(try await f.restic(.backup).exitCode == 0)

            // Hold the listing, queue a job behind it, then let the listing finish: the measurement queues
            // behind that job.
            Self.touch(control, "hold-snapshots")
            let adopt = Task { try await f.state.adopt(f.planID) }
            #expect(await eventually { Self.exists(control, "started-snapshots") })
            let gate = Gate()
            let blocker = await f.dependencies.queues.enqueue(repository: RepositoryQueues.key(for: await f.plan().repository)) {
                await gate.wait()
            }
            Self.touch(control, "go-snapshots")
            _ = try await adopt.value

            if deleting {
                _ = try await f.state.deletePlan(f.planID)
            } else {
                _ = try await f.state.pause(f.planID, for: .oneHour)
            }
            gate.open()
            await blocker.value()
            await f.runner.waitForMeasurement(planID: f.planID)
            let reason = deleting ? "There’s no plan with that ID" : "the plan was paused or deleted first"
            #expect(f.agentLog.value == [
                "Didn't measure the repository size after adopting it, for plan \(f.planID.uuidString): \(reason)",
            ])
            if !deleting {
                #expect(await f.history().recent.contains { $0.operation == .stats } == false)
            }
        }
    }

    @Test func adoptReportsAWrongPassword() async throws {
        let f = try await RunnerFixture.make(origin: .adopted)
        defer { f.remove() }
        try "wrong".write(to: f.passwordFile, atomically: true, encoding: .utf8)
        await #expect {
            _ = try await f.state.adopt(f.planID)
        } throws: { ($0 as? AgentError)?.message == "The repository password is wrong" }
        #expect(await f.history().stoppedReason == nil)
    }

    // MARK: Probing a repository (Ruling P2-2)

    /// A rest-server with nothing at the plan's path: `cat config` exits 10, so the probe says empty and
    /// nothing is created.
    @Test func probeEmptyRepository() async throws {
        let served = FileManager.default.temporaryDirectory
            .appendingPathComponent("restorey-probe-rest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: served) }
        let server = try await RestServer.start(directory: served)
        defer { server.stop() }
        let f = try await RunnerFixture.make(createRepository: false, confirmKit: false) { plan in
            plan.repository = .raw(repository: server.repository + "fresh", environmentNames: [])
        }
        defer { f.remove() }

        let probe = try await f.state.probeRepository(f.planID)
        #expect(probe == RepositoryProbe(state: .empty))
        let history = await f.history()
        #expect(history.recent.map(\.operation) == [.catConfig])
        #expect(history.recent.map(\.outcome) == [.repositoryMissing])
        #expect(history.stoppedReason == nil)
        #expect(!FileManager.default.fileExists(atPath: served.appendingPathComponent("fresh/config").path))
    }

    /// A repository with two snapshots from another Mac: the probe lists them as adopt does.
    @Test func probeExistingRepository() async throws {
        let f = try await RunnerFixture.make(origin: .adopted, confirmKit: false)
        defer { f.remove() }
        var other = await f.plan()
        other.hostLabel = "other"
        for _ in 0..<2 {
            try f.write("a.txt", UUID().uuidString)
            let run = try await f.restic(.backup, plan: other)
            #expect(run.exitCode == 0, "seed: \(run.stderrTail)")
        }

        let probe = try await f.state.probeRepository(f.planID)
        #expect(probe == RepositoryProbe(state: .existing(
            AdoptReport(hosts: ["other"], latestPathsForHost: [], snapshotCount: 2))))
        #expect(await f.operations() == [.catConfig, .initRepository, .catConfig, .snapshots(allHosts: true)])
        #expect(try await f.snapshots().count == 2)
    }

    @Test func probeWithTheWrongPasswordFindsARepositoryItCantOpen() async throws {
        let f = try await RunnerFixture.make(confirmKit: false)
        defer { f.remove() }
        try "wrong".write(to: f.passwordFile, atomically: true, encoding: .utf8)
        // A repository is there: setup's password step asks for its password (UI design §4 step 3).
        let probe = try await f.state.probeRepository(f.planID)
        #expect(probe == RepositoryProbe(state: .passwordRejected))
        // Recorded like adopt, and no stop: the user is still choosing the password.
        let history = await f.history()
        #expect(history.recent.first?.operation == .catConfig)
        #expect(history.recent.first?.outcome == .wrongPassword)
        #expect(history.stoppedReason == nil)
        #expect(await f.operations() == [.catConfig, .initRepository, .catConfig])
    }

    /// restic's exit_error for an unreadable repository is two lines (its message, then the repository's path):
    /// the sentence the app shows is the first, on one line, without the path repeated after it.
    @Test func aProbeFailureIsOneSentenceWithoutRestricsExtraLines() async throws {
        let f = try await RunnerFixture.make()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.repository.path)
            f.remove()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: f.repository.path)
        await #expect {
            _ = try await f.state.probeRepository(f.planID)
        } throws: { error in
            guard case .operationFailed(let message)? = error as? AgentError else { return false }
            return message.hasPrefix("Restorey couldn’t check the repository address: ")
                && message.contains("permission denied") && !message.contains("\n")
                && !message.hasSuffix(f.repository.lastPathComponent)
        }
    }

    /// Fix round 2: Settings' check of typed credentials, with the vendored restic. The fixture's helper script prints
    /// its password file, so an observer of the candidate store stands in for the agent's helper (whose serving is
    /// `HelperResponderTests`'): if the runner didn't set the candidate during its turn, the wrong one couldn't be
    /// rejected. A check is not a run: it leaves no history record and no in-progress marker, and the keychain is
    /// as it was.
    @Test func aCredentialCheckTriesTheCandidateAndLeavesNoTrace() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        let id = f.planID
        let passwordFile = f.passwordFile
        f.state.candidates.observe { _, secrets in
            let value = secrets?[.repositoryPassword(id)] ?? RunnerFixture.password
            try? value.write(to: passwordFile, atomically: true, encoding: .utf8)
        }
        let before = await f.history()

        let wrong = try await f.state.probeRepository(id, candidates: [SecretEntry(key: .repositoryPassword(id), value: "wrong")])
        #expect(wrong == RepositoryProbe(state: .passwordRejected))
        let right = try await f.state.probeRepository(
            id, candidates: [SecretEntry(key: .repositoryPassword(id), value: RunnerFixture.password)])
        #expect(right == RepositoryProbe(state: .existing(AdoptReport(hosts: [], latestPathsForHost: [], snapshotCount: 0))))

        let after = await f.history()
        #expect(after.recent == before.recent)
        #expect(after.runningRecordID == nil)
        #expect(after.runningRecord == nil)
        #expect(after.stoppedReason == nil)
        #expect(f.state.candidates.values(for: id) == nil)
        #expect(try f.secrets.read(.repositoryPassword(id)) == RunnerFixture.password)
    }

    /// A check is a short repository action, like the size measurement after an adopt: the plan isn't shown backing
    /// up, and Back Up Now isn't refused; the backup waits its turn in the repository's queue.
    @Test func backUpNowDuringACredentialCheckIsNotRefused() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        let id = f.planID
        let state = f.state
        let during = Locked<Task<(PlanPhase, Bool), Never>?>(nil)
        f.state.candidates.observe { _, secrets in
            guard secrets != nil else { return }
            during.set(Task {
                let phase = await state.status().plans.first { $0.plan.id == id }!.phase
                let started = (try? await state.backUpNow(id)) != nil
                return (phase, started)
            })
        }
        _ = try await f.state.probeRepository(id, candidates: [SecretEntry(key: .repositoryPassword(id), value: "x")])
        let (phase, started) = try #require(await during.value?.value)
        if case .running = phase { Issue.record("the check showed as a backup run") }
        #expect(started)
        try await f.waitForPhase { if case .running = $0 { false } else { true } }
    }

    /// Only the plan's own credentials can be checked, and the check-in URL isn't one.
    @Test func aCheckRefusesSecretsThatArentThePlansCredentials() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        await #expect(throws: AgentError.foreignSecret) {
            _ = try await f.state.probeRepository(f.planID, candidates: [SecretEntry(key: .repositoryPassword(UUID()), value: "x")])
        }
        await #expect {
            _ = try await f.state.probeRepository(
                f.planID, candidates: [SecretEntry(key: .checkInURL(f.planID), value: "https://hc-ping.com/x")])
        } throws: { error in
            if case .invalidRequest? = error as? AgentError { true } else { false }
        }
    }

    /// Fix round 3, N2: a check waiting in the repository's queue (behind another plan's backup, say) isn't yet
    /// registered, so deleting the plan doesn't wait for whatever is ahead of it; the check then finds the plan
    /// gone and runs nothing.
    @Test func deletingAPlanDoesntWaitForACheckStillQueued() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        let id = f.planID
        let key = RepositoryQueues.key(for: await f.plan().repository)
        let gate = Locked<CheckedContinuation<Void, Never>?>(nil)
        let holding = Task {
            await f.dependencies.queues.run(repository: key) {
                await withCheckedContinuation { continuation in gate.set(continuation) }
            }
        }
        while gate.value == nil { try await Task.sleep(for: .milliseconds(5)) }
        let check = Task {
            try await f.state.probeRepository(id, candidates: [SecretEntry(key: .repositoryPassword(id), value: "x")])
        }
        try await Task.sleep(for: .milliseconds(50))
        _ = try await f.state.deletePlan(id)
        gate.value?.resume()
        await holding.value
        await #expect(throws: AgentError.self) { _ = try await check.value }
        #expect(f.state.candidates.values(for: id) == nil)
    }

    @Test func probeIsRefusedWhileDraining() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        await f.state.prepareForRestart()
        await #expect { _ = try await f.state.probeRepository(f.planID) } throws: { ($0 as? AgentError) == .draining }
        await #expect { _ = try await f.state.probeRepository(UUID()) } throws: { ($0 as? AgentError) == .draining }
    }

    // MARK: Full Disk Access (Ruling P2-11)

    /// The setup step polls this: every call runs the agent's own probe and pushes, changed or not.
    @Test func probeFullDiskAccessRerunsTheProbeAndPushes() async throws {
        let f = try await RunnerFixture.make(createRepository: false)
        defer { f.remove() }
        let pushed = Locked<[Bool?]>([])
        await f.state.setStatusObserver { status in pushed.mutate { $0.append(status.fdaMissing) } }

        f.fda.set(.missing)
        #expect(try await f.state.probeFullDiskAccess().fdaMissing == true)
        #expect(try await f.state.probeFullDiskAccess().fdaMissing == true)
        f.fda.set(.granted)
        #expect(try await f.state.probeFullDiskAccess().fdaMissing == false)
        #expect(pushed.value == [true, true, false])
        #expect(await f.state.status().fdaMissing == false)
    }

    /// A probe that finds access granted clears the plan's alert in its own reply and push. No notifier is
    /// attached, so no delivery round runs to clear `activeAlerts`: the status alone must not show it.
    @Test func probeFindingAccessGrantedDropsThePlansAlertAtOnce() async throws {
        let f = try await RunnerFixture.make(createRepository: false)
        defer { f.remove() }
        f.fda.set(.missing)
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(await f.history().activeAlerts[.fullDiskAccessMissing] != nil)
        #expect(await f.status().alerts.contains(.fullDiskAccessMissing))
        let pushed = Locked<[[AlertCondition]]>([])
        await f.state.setStatusObserver { status in pushed.mutate { $0.append(status.plans.first?.alerts ?? []) } }

        f.fda.set(.granted)
        let reply = try await f.state.probeFullDiskAccess()
        #expect(reply.fdaMissing == false)
        #expect(reply.plans.first?.alerts.contains(.fullDiskAccessMissing) == false)
        #expect(pushed.value.count == 1)
        #expect(pushed.value.first?.contains(.fullDiskAccessMissing) == false)
        // Still in `activeAlerts` (no delivery round ran), which the status no longer reports.
        #expect(await f.history().activeAlerts[.fullDiskAccessMissing] != nil)
    }

    @Test func actionsAreRefusedWhileDraining() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        await f.state.prepareForRestart()
        let refused = "Restorey is finishing the current backup before updating"
        await #expect { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) } throws: {
            ($0 as? AgentError)?.message == refused
        }
        await #expect { try await f.state.backUpNow(nil) } throws: { ($0 as? AgentError)?.message == refused }
        await #expect { try await f.state.createRepository(f.planID) } throws: { ($0 as? AgentError)?.message == refused }
        await #expect { _ = try await f.state.adopt(f.planID) } throws: { ($0 as? AgentError)?.message == refused }
        // Pause stays allowed (Ruling R27).
        _ = try await f.state.pause(f.planID, for: .oneHour)
    }

    // MARK: Maintenance schedule (pure)

    @Test func maintenanceSchedule() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var plan = Plan.newHotPlan(
            name: "P", repository: .raw(repository: "/r", environmentNames: []), origin: .created,
            hostLabel: "h", sources: ["/s"], exclusions: [], now: now.addingTimeInterval(-86_400))
        var history = PlanRunHistory()
        history.lastCheckAt = now.addingTimeInterval(-3600)
        let snapshot = RunOutcome.success(snapshotID: "x")

        #expect(PlanRunner.maintenance(plan: plan, history: history, after: snapshot, now: now) == [.forget(dryRun: false)])
        #expect(PlanRunner.maintenance(plan: plan, history: history, after: .unchanged, now: now) == [])
        #expect(PlanRunner.maintenance(plan: plan, history: history, after: .warning(unreadable: 2), now: now) == [.forget(dryRun: false)])
        for outcome in [RunOutcome.paused, .cancelled, .locked, .wrongPassword, .failed(exitCode: 1, reason: "x")] {
            #expect(PlanRunner.maintenance(plan: plan, history: history, after: outcome, now: now) == [])
        }

        // Prune counts its week from the plan's creation; check runs when it has never run.
        plan.createdAt = now.addingTimeInterval(-7 * 86_400)
        history.lastCheckAt = nil
        #expect(PlanRunner.maintenance(plan: plan, history: history, after: snapshot, now: now)
            == [.forget(dryRun: false), .prune, .unlock, .check])
        plan.pruneEnabled = false
        #expect(PlanRunner.maintenance(plan: plan, history: history, after: .unchanged, now: now) == [.unlock, .check])

        // Daily forget, and a clock that went backwards counts as due.
        plan.forgetCadence = .daily
        history.lastCheckAt = now
        history.lastForgetAt = now.addingTimeInterval(-86_399)
        #expect(PlanRunner.maintenance(plan: plan, history: history, after: snapshot, now: now) == [])
        history.lastForgetAt = now.addingTimeInterval(-86_400)
        #expect(PlanRunner.maintenance(plan: plan, history: history, after: .unchanged, now: now) == [.forget(dryRun: false)])
        history.lastForgetAt = now.addingTimeInterval(3600)
        #expect(PlanRunner.maintenance(plan: plan, history: history, after: .unchanged, now: now) == [.forget(dryRun: false)])
    }

    /// A check that never really ran is tried again at the next backup rather than a week later.
    @Test func onlyACheckWithAVerdictMovesLastCheckAt() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func lastCheck(after outcome: RunOutcome) -> Date? {
            var history = PlanRunHistory()
            let record = RunRecord(
                id: UUID(), planID: UUID(), operation: .check, trigger: .scheduled, startedAt: now, endedAt: now,
                outcome: outcome, summary: nil, logFile: "")
            PlanRunner.apply(record, stoppedReason: nil, to: &history)
            return history.lastCheckAt
        }
        #expect(lastCheck(after: .success(snapshotID: nil)) == now)
        #expect(lastCheck(after: .failed(exitCode: 1, reason: "repository contains errors")) == now)
        #expect(lastCheck(after: .interrupted) == nil)
        #expect(lastCheck(after: .failed(exitCode: -1, reason: "Restorey couldn’t start restic")) == nil)
        #expect(lastCheck(after: .locked) == nil)
        #expect(lastCheck(after: .paused) == nil)
    }
}
