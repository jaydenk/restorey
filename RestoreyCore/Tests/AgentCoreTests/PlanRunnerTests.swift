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

    @Test func successfulRunRecordsSnapshotAndPingsStartThenSuccess() async throws {
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
        #expect(await f.pings() == [.start, .success])

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

    // MARK: Unchanged runs

    /// `--skip-if-unchanged` compares whole trees, including the metadata of every folder above the
    /// source, so an entry created beside any ancestor makes a new snapshot. Other tests and processes
    /// keep changing the temporary folders (`$TMPDIR`, /private/tmp); these tests keep their files in
    /// /Users/Shared, which almost nothing touches, one test at a time.
    @Suite(.serialized) struct Unchanged {
        @Test func unchangedSecondRunIsUnchangedAndPingsSuccess() async throws {
            let f = try await RunnerFixture.make(stableAncestors: true)
            defer { f.remove() }
            try f.write("a.txt", "hello")
            _ = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)

            // A directory source with nothing changed: restic 0.19.1 skips the snapshot.
            let second = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
            #expect(second.outcome == .unchanged)
            #expect(await f.pings() == [.start, .success, .start, .success])
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
        #expect(own.map(\.id) == [newest], "the plan's own group keeps only its newest snapshot")
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
        #expect(await f.operations() == [.initRepository, .backup, .forget(dryRun: false), .unlock, .check])
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
        #expect(Array(ops.suffix(5)) == [.backup, .forget(dryRun: false), .prune, .unlock, .check])
        #expect(ops.filter { $0 == .check }.count == 2)
        #expect(await f.history().lastPruneAt != nil)
        #expect(await f.history().activeAlerts.isEmpty)
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
        #expect(await f.pings() == [.start, .success])
        let history = await f.history()
        let check = try #require(history.recent.first)
        #expect(check.operation == .check)
        #expect(check.outcome == .failed(exitCode: 1, reason: "Fatal: repository contains errors"))
        #expect(Set(history.activeAlerts.keys) == [.checkFailed])
        #expect(await f.status().alerts == [.checkFailed])
    }

    // MARK: Refusals before restic

    @Test func fdaMissingSkipsResticAndRaisesCondition() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        try f.write("a.txt", "one")
        f.fda.set(.missing)

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(record.outcome == .failed(exitCode: -1, reason: "Full Disk Access is missing"))
        #expect(await f.pings() == [])
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
        #expect(pings.count == 2)
        #expect(pings.first == .start)
        #expect(Self.isFail(pings[1], heading: "restic exit code 12"))
        // No maintenance after a failed backup.
        #expect(await f.operations() == [.initRepository, .backup])
    }

    @Test func credentialsUnavailableNamesTheKeychainAndTheHelperReason() async throws {
        // A raw plan whose environment value is missing from the Keychain can't build restic's
        // environment: the plan stops with the Keychain reason, after /start, without running restic.
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
        #expect(reason.hasPrefix("Couldn't read the backup keys from the Keychain"))
        #expect(reason.contains("RESTIC_COMPRESSION"))
        let pings = await f.pings()
        #expect(pings.first == .start)
        #expect(pings.count == 2 && Self.isFail(pings[1], heading: "restic exit code 1"))
        #expect(try await f.snapshots().isEmpty)

        // A helper failure noted during the run (Task 13) is appended to the reason.
        try f.secrets.write("auto", for: .environment(f.planID, name: "RESTIC_COMPRESSION"))
        try await f.state.updateHistory(f.planID) { $0.stoppedReason = nil }
        try "".write(to: f.passwordFile, atomically: true, encoding: .utf8)
        await f.state.noteHelperFailure(planID: f.planID, reason: "The repository password isn't in the Keychain")
        let failed = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        guard case .failed(_, let failure) = failed.outcome else {
            Issue.record("expected a failure with an empty password, got \(failed.outcome)")
            return
        }
        #expect(failure.hasSuffix("The repository password isn't in the Keychain"))
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

        // A source that doesn't exist is a failure, but restic still never ran: no ping either.
        f.power.set(PowerState(onBattery: false, percent: 100))
        try FileManager.default.removeItem(at: f.source)
        let failed = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(failed.outcome == .failed(exitCode: -1, reason: "\(f.source.path) doesn't exist"))
        #expect(await f.history().activeAlerts[.backupFailed] != nil)

        #expect(await f.pings() == [])
        #expect(try await f.snapshots().isEmpty)
    }

    @Test func noRecoveryKitNoRun() async throws {
        let f = try await RunnerFixture.make(confirmKit: false)
        defer { f.remove() }
        try f.write("a.txt", "one")

        await #expect {
            try await f.state.backUpNow(f.planID)
        } throws: { ($0 as? AgentError)?.message == "Confirm you've saved the recovery kit for Fixture before its first backup" }

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        #expect(record.outcome == .failed(
            exitCode: -1, reason: "Confirm you've saved the recovery kit for Fixture before its first backup"))
        #expect(await f.pings() == [])
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
        #expect(await f.pings() == [])
        #expect(try await f.snapshots().isEmpty)
    }

    // MARK: Pause

    @Test func pauseThenAutoResume() async throws {
        let f = try await RunnerFixture.make { $0.uploadLimitKiB = 20_000 } // keeps the backup running
        defer { f.remove() }
        try f.writeRandomFiles(count: 6, megabytes: 30)

        let run = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }
        try await f.waitForPhase { $0.progress != nil }
        let pausedAt = f.clock.now
        _ = try await f.runner.pause(planID: f.planID)
        let record = try await run.value

        #expect(record.outcome == .paused)
        #expect(await f.pings() == [.start]) // nothing at the end of a paused run
        #expect(f.lockFiles().isEmpty, "an honoured SIGINT removes restic's own lock")
        let history = await f.history()
        let until = pausedAt.addingTimeInterval(3600)
        #expect(history.pausedUntil == until)
        #expect(nextRunDate(plan: await f.plan(), history: history, now: f.clock.now) == until)
        #expect(await f.status().phase == .paused(until: until))
        #expect(await f.operations() == [.initRepository, .backup]) // no maintenance after a pause

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
        #expect(await f.pings() == [.start, .start, .success])
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
        _ = try await f.runner.pause(planID: f.planID)
        #expect(try await run.value.outcome == .paused)

        try FileManager.default.removeItem(at: marker)
        try await f.state.updateHistory(f.planID) { $0.pausedUntil = nil }
        let next = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        guard case .success = next.outcome else {
            Issue.record("expected a success after the unlock, got \(next.outcome)")
            return
        }
        let ops = await f.operations()
        #expect(Array(ops.prefix(4)) == [.initRepository, .backup, .unlock, .backup])
    }

    // MARK: Recovery (Review Focus 3)

    @Test func interruptedRunRecoveredAfterStart() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        try f.writeRandomFiles(count: 4, megabytes: 20)

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

        await f.runner.recoverAfterStart()

        let history = await f.history()
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
        await f.runner.recoverAfterStart()
        let history = await f.history()
        let recovered = try #require(history.recent.first { $0.id == id })
        #expect(recovered.outcome == .interrupted)
        #expect(recovered.operation == .backup)
        #expect(recovered.startedAt == Date(timeIntervalSince1970: 1_799_999_000))
        #expect(history.runningRecordID == nil)
    }

    // MARK: Progress (Ruling R14)

    @Test func retryingLineIsShownUntilTheNextStatus() async throws {
        let stub = FileManager.default.temporaryDirectory
            .appendingPathComponent("restorey-retrying-\(UUID().uuidString).sh")
        let status = { (percent: Double) in
            #"{"message_type":"status","percent_done":\#(percent),"total_files":2,"files_done":1,"total_bytes":10,"bytes_done":5}"#
        }
        let summary = #"{"message_type":"summary","files_new":1,"files_changed":0,"files_unmodified":0,"data_added":1,"data_added_packed":1,"total_files_processed":1,"total_bytes_processed":1,"total_duration":1,"snapshot_id":"abc123"}"#
        try """
            #!/bin/sh
            [ "$1" = backup ] || exit 0
            echo '\(status(0.1))'
            /bin/sleep 1
            echo 'Save(<data/0123>) returned error, retrying after 552ms: dial tcp: user:\(RunnerFixture.password)@host connection refused' >&2
            /bin/sleep 2
            echo '\(status(0.5))'
            /bin/sleep 2
            echo '\(summary)'

            """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        defer { try? FileManager.default.removeItem(at: stub) }

        let f = try await RunnerFixture.make(executable: stub)
        defer { f.remove() }
        let run = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }

        try await f.waitForPhase { $0.retrying != nil }
        let retrying = try #require(await f.status().phase.retrying)
        #expect(retrying.contains("retrying after"))
        #expect(!retrying.contains(RunnerFixture.password))
        #expect(await f.status().phase.progress?.percentDone == 0.1)

        try await f.waitForPhase { $0.progress?.percentDone == 0.5 }
        #expect(await f.status().phase.retrying == nil)

        let record = try await run.value
        #expect(record.outcome == .success(snapshotID: "abc123"))
        #expect(await f.status().phase == .idle)
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

        let status = try await f.state.backUpNow(f.planID)
        #expect(status.plans.first?.phase.isRunning == true)
        await #expect { try await f.state.backUpNow(f.planID) } throws: {
            ($0 as? AgentError)?.message == "Fixture is already backing up"
        }
        let record = try #require(await f.runner.waitForBackgroundRun(planID: f.planID))
        #expect(record.trigger == .manual)
        guard case .success = record.outcome else {
            Issue.record("expected a success, got \(record.outcome)")
            return
        }
        #expect(await f.status().phase == .idle)
    }

    @Test func backUpNowStillHonoursPreflight() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        f.power.set(PowerState(onBattery: true, percent: 1))
        _ = try await f.state.backUpNow(nil)
        let record = try #require(await f.runner.waitForBackgroundRun(planID: f.planID))
        #expect(record.outcome == .skipped(.batteryBelow(20)))
        #expect(await f.pings() == [])
    }

    @Test func createRepositoryRefusesAnExistingRepository() async throws {
        let f = try await RunnerFixture.make() // has already created it once
        defer { f.remove() }
        #expect(await f.operations() == [.initRepository])
        #expect(await f.history().recent.first?.outcome == .success(snapshotID: nil))

        await #expect {
            try await f.state.createRepository(f.planID)
        } throws: { ($0 as? AgentError)?.message == "A repository already exists there" }
        #expect(await f.operations() == [.initRepository, .initRepository])
    }

    @Test func noRunEverInitialisesTheRepository() async throws {
        let f = try await RunnerFixture.make(createRepository: false)
        defer { f.remove() }
        try f.write("a.txt", "one")
        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(record.outcome == .repositoryMissing)
        #expect(!FileManager.default.fileExists(atPath: f.repository.appendingPathComponent("config").path))
        #expect(await f.history().stoppedReason == "There's no restic repository at this plan's address")
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
        #expect(await f.operations() == [.initRepository, .snapshots(allHosts: true)])
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

    @Test func actionsAreRefusedWhileDraining() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        await f.state.prepareForRestart()
        let refused = "Restorey is finishing the current backup before updating the agent"
        await #expect { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) } throws: {
            ($0 as? AgentError)?.message == refused
        }
        await #expect { try await f.state.backUpNow(nil) } throws: { ($0 as? AgentError)?.message == refused }
        await #expect { try await f.state.createRepository(f.planID) } throws: { ($0 as? AgentError)?.message == refused }
        await #expect { _ = try await f.state.adopt(f.planID) } throws: { ($0 as? AgentError)?.message == refused }
        // Pause stays allowed (Ruling R27).
        _ = try await f.runner.pause(planID: f.planID)
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
}
