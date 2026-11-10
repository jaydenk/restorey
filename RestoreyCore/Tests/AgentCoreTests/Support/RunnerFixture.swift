import Foundation
import Synchronization
import Testing
@testable import AgentCore
import RestoreyCore

/// The vendored restic. A missing binary is a failure, never a skip: a skipped test would hide a broken fetch.
enum ResticBinary {
    struct Missing: Error, CustomStringConvertible {
        let path: String
        var description: String { "restic not found at \(path). Run scripts/fetch-binaries.sh or set RESTIC_BINARY." }
    }

    static func require() throws -> URL {
        let url: URL
        if let path = ProcessInfo.processInfo.environment["RESTIC_BINARY"], !path.isEmpty {
            url = URL(fileURLWithPath: path)
        } else {
            // <repo>/RestoreyCore/Tests/AgentCoreTests/Support/RunnerFixture.swift -> <repo>/vendor/restic
            url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("vendor/restic")
        }
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw Missing(path: url.path) }
        return url
    }
}

/// A value shared with the runner's injected closures. A class, so escaping closures can capture it.
final class Locked<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>
    init(_ value: Value) { storage = Mutex(value) }
    var value: Value { storage.withLock { $0 } }
    func set(_ value: Value) { storage.withLock { $0 = value } }
    /// Sets `value` and returns what it was.
    func exchange(_ value: Value) -> Value { storage.withLock { let old = $0; $0 = value; return old } }
    func mutate(_ change: (inout Value) -> Void) { storage.withLock { change(&$0) } }
}

final class FixtureClock: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
}

/// Records every ping, in order.
actor RecordingCheckIn: CheckInSending {
    private(set) var pings: [CheckInPing] = []
    func send(_ ping: CheckInPing, planID: UUID) async { pings.append(ping) }
}

/// One snapshot as `restic snapshots --json` lists it.
struct ListedSnapshot: Decodable, Equatable {
    let id: String
    let hostname: String
    let paths: [String]
    let tags: [String]?
}

/// A scratch world for the runner: a source folder, a local repository, cache, home, logs and the
/// agent's support directory as siblings (so nothing restic writes lands in the source), a real
/// `AgentState`, and a `PlanRunner` wired to fakes for the probe, the environment and the check-in.
///
/// The helper script stands in for the agent executable: restic runs it as `RESTIC_PASSWORD_COMMAND`
/// and it prints the contents of `passwordFile`, so a test can make the password wrong.
final class RunnerFixture: Sendable {
    static let password = "fixture-password-not-a-secret"

    let root: URL
    let source: URL
    let repository: URL
    let cache: URL
    let home: URL
    let logs: URL
    let support: URL
    let passwordFile: URL
    let helper: URL
    let restic: URL
    let clock: FixtureClock
    let secrets: InMemorySecretStore
    let checkIn: RecordingCheckIn
    let fda: Locked<FDAProbeResult>
    let power: Locked<PowerState>
    let supervisor: SupervisedProcesses
    let state: AgentState
    let runner: PlanRunner
    let dependencies: RunnerDependencies
    let planID: UUID

    private init(
        root: URL, restic: URL, clock: FixtureClock, secrets: InMemorySecretStore, checkIn: RecordingCheckIn,
        fda: Locked<FDAProbeResult>, power: Locked<PowerState>, supervisor: SupervisedProcesses,
        state: AgentState, runner: PlanRunner, dependencies: RunnerDependencies, planID: UUID
    ) {
        self.root = root
        source = root.appendingPathComponent("source")
        repository = root.appendingPathComponent("repo")
        cache = root.appendingPathComponent("cache")
        home = root.appendingPathComponent("home")
        logs = root.appendingPathComponent("logs")
        support = root.appendingPathComponent("support")
        passwordFile = root.appendingPathComponent("password")
        helper = root.appendingPathComponent("helper.sh")
        self.restic = restic
        self.clock = clock
        self.secrets = secrets
        self.checkIn = checkIn
        self.fda = fda
        self.power = power
        self.supervisor = supervisor
        self.state = state
        self.runner = runner
        self.dependencies = dependencies
        self.planID = planID
    }

    /// - Parameters:
    ///   - executable: restic, or a stand-in script; defaults to the vendored restic.
    ///   - createRepository: runs `createRepository` (restic init) before returning.
    ///   - confirmKit: confirms the recovery kit, which every scheduled backup requires.
    ///   - stableAncestors: keeps the files in /Users/Shared rather than the shared temporary folder,
    ///     whose metadata other tests (and other processes) keep changing (see `PlanRunnerTests.Unchanged`).
    static func make(
        origin: RepositoryOrigin = .created,
        executable: URL? = nil,
        createRepository: Bool = true,
        confirmKit: Bool = true,
        gracePeriod: Duration = .seconds(10),
        stableAncestors: Bool = false,
        change: (inout Plan) -> Void = { _ in }
    ) async throws -> RunnerFixture {
        let fm = FileManager.default
        let base = stableAncestors ? URL(fileURLWithPath: "/Users/Shared", isDirectory: true) : fm.temporaryDirectory
        let root = base.appendingPathComponent("restorey-runner-\(UUID().uuidString)", isDirectory: true)
        for name in ["source", "cache", "home", "logs", "support"] {
            try fm.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try password.write(to: root.appendingPathComponent("password"), atomically: true, encoding: .utf8)
        let helper = root.appendingPathComponent("helper.sh")
        try "#!/bin/sh\ncat '\(root.appendingPathComponent("password").path)'\n"
            .write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let restic = try ResticBinary.require()

        let clock = FixtureClock()
        let secrets = InMemorySecretStore()
        let checkIn = RecordingCheckIn()
        let fda = Locked<FDAProbeResult>(.granted)
        let power = Locked(PowerState(onBattery: false, percent: 100))
        let supervisor = SupervisedProcesses()
        let support = root.appendingPathComponent("support")
        let state = await AgentState(directory: support, secrets: secrets, now: { clock.now })

        var plan = Plan.newHotPlan(
            name: "Fixture",
            repository: .raw(repository: root.appendingPathComponent("repo").path, environmentNames: []),
            origin: origin, hostLabel: "fixturehost",
            sources: [root.appendingPathComponent("source").path], exclusions: [], now: clock.now)
        change(&plan)
        _ = try await state.savePlan(SavePlanRequest(
            plan: plan, secrets: [SecretEntry(key: .repositoryPassword(plan.id), value: password)]))

        let dependencies = RunnerDependencies(
            state: state, secrets: secrets, queues: RepositoryQueues(), supervisor: supervisor,
            logStore: RunLogStore(root: root.appendingPathComponent("logs"), subsystem: "test.restorey"),
            checkIn: checkIn,
            resticExecutable: executable ?? restic, helperExecutable: helper,
            cacheDirectory: root.appendingPathComponent("cache"), credentialsDirectory: support,
            homeDirectory: root.appendingPathComponent("home"), logSubsystem: "test.restorey",
            fdaProbe: { fda.value },
            preflightEnvironment: {
                PreflightEnvironment(
                    power: power.value, network: .satisfied(constrained: false, expensive: false),
                    isMountPoint: { _ in false },
                    fileExists: { FileManager.default.fileExists(atPath: $0) })
            },
            now: { clock.now },
            interruptGracePeriod: gracePeriod)
        let runner = PlanRunner(dependencies: dependencies)
        await state.attach(runner: runner)

        let fixture = RunnerFixture(
            root: root, restic: restic, clock: clock, secrets: secrets, checkIn: checkIn, fda: fda,
            power: power, supervisor: supervisor, state: state, runner: runner, dependencies: dependencies,
            planID: plan.id)
        if createRepository { _ = try await runner.createRepository(planID: plan.id) }
        if confirmKit { _ = try await state.confirmRecoveryKit(plan.id) }
        return fixture
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: State

    func plan() async -> Plan {
        await state.status().plans.first { $0.plan.id == planID }!.plan
    }

    func history() async -> PlanRunHistory {
        try! await state.runInputs(planID).history
    }

    /// A second agent (state and runner) reading the same files, as after a restart.
    func reloaded() async -> (AgentState, PlanRunner) {
        let clock = clock
        let state = await AgentState(directory: support, secrets: secrets, now: { clock.now })
        var dependencies = dependencies
        dependencies.state = state
        let runner = PlanRunner(dependencies: dependencies)
        await state.attach(runner: runner)
        return (state, runner)
    }

    func status() async -> PlanStatus {
        await state.status().plans.first { $0.plan.id == planID }!
    }

    /// Every ping sent so far, once the runner has handed over all it queued.
    func pings() async -> [CheckInPing] {
        await runner.pingsDelivered(planID: planID)
        return await checkIn.pings
    }

    /// Changes the plan through `savePlan`, keeping the recovery kit (same repository and password).
    func updatePlan(_ change: (inout Plan) -> Void) async throws {
        var plan = await plan()
        change(&plan)
        _ = try await state.savePlan(SavePlanRequest(
            plan: plan, secrets: [SecretEntry(key: .repositoryPassword(plan.id), value: Self.password)]))
    }

    /// Operations of `recent`, oldest first, which reads more naturally in assertions.
    func operations() async -> [ResticOperation] {
        await history().recent.reversed().map(\.operation)
    }

    // MARK: Source data

    func write(_ name: String, _ contents: String) throws {
        try contents.write(to: source.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// `count` files of `megabytes` each, of random (incompressible) data.
    func writeRandomFiles(count: Int, megabytes: Int) throws {
        for i in 0..<count {
            let dd = Process()
            dd.executableURL = URL(fileURLWithPath: "/bin/dd")
            dd.arguments = [
                "if=/dev/urandom", "of=\(source.appendingPathComponent("random-\(i).bin").path)",
                "bs=1048576", "count=\(megabytes)",
            ]
            dd.standardError = FileHandle.nullDevice
            try dd.run()
            dd.waitUntilExit()
            #expect(dd.terminationStatus == 0)
        }
    }

    // MARK: restic, run directly (outside the runner)

    func context() -> ResticContext {
        ResticContext(
            cacheDirectory: cache, helperExecutable: helper, credentialsFile: nil, rawEnvironment: [:],
            homeDirectory: home)
    }

    /// Runs `op` for `plan` (default: the fixture's plan) straight through `ResticProcess`.
    func restic(
        _ op: ResticOperation, plan: Plan? = nil, transform: (inout ResticInvocation) -> Void = { _ in }
    ) async throws -> ResticTermination {
        let target: Plan
        if let plan { target = plan } else { target = await self.plan() }
        var invocation = makeInvocation(op, plan: target, context: context())
        transform(&invocation)
        return try await ResticProcess(
            executable: restic, invocation: invocation, planID: target.id, supervisor: SupervisedProcesses(),
            homeDirectory: home
        ).run { _ in }
    }

    /// Every snapshot in the repository, of every host.
    func snapshots() async throws -> [ListedSnapshot] {
        let collected = Locked<[String]>([])
        let target = await plan()
        let invocation = makeInvocation(.snapshots(allHosts: true), plan: target, context: context())
        let termination = try await ResticProcess(
            executable: restic, invocation: invocation, planID: target.id, supervisor: SupervisedProcesses(),
            homeDirectory: home
        ).run { message in
            if case .unparseable(let line) = message, line.hasPrefix("[") { collected.mutate { $0.append(line) } }
        }
        #expect(termination.exitCode == 0, "snapshots: \(termination.stderrTail)")
        guard let line = collected.value.last else { return [] }
        return try JSONDecoder().decode([ListedSnapshot].self, from: Data(line.utf8))
    }

    /// Entries in the repository's `locks/` directory.
    func lockFiles() -> [String] {
        let dir = repository.appendingPathComponent("locks")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    /// Polls the plan's status until `predicate` holds.
    func waitForPhase(
        timeout: Duration = .seconds(60), _ predicate: (PlanPhase) -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate(await status().phase) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out waiting for the plan's phase; it is \(await status().phase)")
    }

    /// Writes an executable shell script in the fixture's root.
    func script(_ name: String, _ body: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

extension PlanPhase {
    var isRunning: Bool { if case .running = self { true } else { false } }
    var progress: BackupStatus? { if case .running(let progress, _) = self { progress } else { nil } }
    var retrying: String? { if case .running(_, let retrying) = self { retrying } else { nil } }
}
