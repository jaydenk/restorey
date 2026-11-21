import Foundation
import RestoreyCore

/// Runs the upload speed tests and keeps their results per network in `upload-speeds.json` (the upload-limit design,
/// "Measurements"). One test runs at a time: a test asked for on the network being tested joins it, and one asked for
/// on another network waits for it to end first.
///
/// The tester doesn't decide whether a test may run. The plan runner does (`PlanRunner.runSpeedTest`), because the
/// rule "never while restic runs a networked command" is about the runner's commands.
///
/// A file that can't be read (corrupt, written by a newer Restorey) is no measurements, logged once; it is never
/// overwritten (`VersionedStore.save` refuses), so results are then kept in memory only.
public actor SpeedTester {
    private let store: any PayloadStore<UploadSpeedsFile>
    private let run: @Sendable () async -> Result<UploadSpeedMeasurement, SpeedTestError>
    private let now: @Sendable () -> Date
    private let log: @Sendable (String) -> Void

    /// The file's records once read; nil until then.
    private var file: UploadSpeedsFile?
    private var loading: Task<UploadSpeedsFile, Never>?
    private var loggedSaveFailure = false
    /// The test in flight, by the network it is testing. At most one entry.
    private var inFlight: [NetworkKey: Task<Result<UploadSpeedMeasurement, SpeedTestError>, Never>] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// Calls to `test` that haven't returned. For tests.
    private(set) var callersWaiting = 0

    /// - Parameters:
    ///   - run: one test (the agent passes `NetworkQuality.run`, tests a fake).
    ///   - log: a line for the agent's log for each test, and for a file that can't be read or saved.
    public init(
        store: any PayloadStore<UploadSpeedsFile>,
        run: @escaping @Sendable () async -> Result<UploadSpeedMeasurement, SpeedTestError>,
        now: @escaping @Sendable () -> Date,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.store = store
        self.run = run
        self.now = now
        self.log = log
    }

    /// Whether a test is running.
    public var isTesting: Bool { !inFlight.isEmpty }

    /// What is kept for `key`: its last successful measurement and its last failure.
    public func record(for key: NetworkKey) async -> UploadSpeedRecord? {
        await records()[key]
    }

    /// Runs one test for `key`, or joins the one in flight for it. Saves a success as `latest` (clearing an older
    /// failure) and a failure as `lastFailure`, keeping `latest`.
    public func test(_ key: NetworkKey) async -> Result<UploadSpeedMeasurement, SpeedTestError> {
        callersWaiting += 1
        defer { callersWaiting -= 1 }
        while true {
            if let running = inFlight[key] { return await running.value }
            guard inFlight.isEmpty else {
                await waitUntilIdle()
                continue
            }
            // Registered before this call suspends, so a caller arriving next finds it.
            let task = Task { await perform(key) }
            inFlight[key] = task
            return await task.value
        }
    }

    /// Whether a test for `key` has succeeded or failed on `now`'s calendar day.
    public func testedToday(_ key: NetworkKey, calendar: Calendar) async -> Bool {
        guard let record = await records()[key] else { return false }
        let today = now()
        return [record.latest?.measuredAt, record.lastFailure?.at].contains { date in
            date.map { calendar.isDate($0, inSameDayAs: today) } ?? false
        }
    }

    /// Returns once no test is running: at once when none is.
    public func waitUntilIdle() async {
        guard !inFlight.isEmpty else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: Private

    private func perform(_ key: NetworkKey) async -> Result<UploadSpeedMeasurement, SpeedTestError> {
        var updated = await records()
        let started = ContinuousClock.now
        let result = await run()
        let took = Self.seconds(ContinuousClock.now - started)
        var record = updated[key] ?? UploadSpeedRecord()
        switch result {
        case .success(let measurement):
            record.latest = measurement
            record.lastFailure = nil
            let bytes = measurement.bytesSent.map { ", \($0) bytes sent" } ?? ""
            log("Upload speed test on \(key.logName): \(Self.megabits(measurement.bitsPerSecond)) Mbit/s\(bytes), took \(took)")
        case .failure(let error):
            record.lastFailure = SpeedTestFailure(at: now(), reason: error.message)
            log("Upload speed test on \(key.logName) failed after \(took): \(error.message)")
        }
        // Another caller may have loaded or changed the records while the test ran.
        updated = await records()
        updated[key] = record
        file = UploadSpeedsFile(records: updated)
        inFlight[key] = nil
        if inFlight.isEmpty {
            let waiters = idleWaiters
            idleWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        await save()
        return result
    }

    private func records() async -> [NetworkKey: UploadSpeedRecord] {
        if let file { return file.records }
        if loading == nil {
            let store = store
            let log = log
            loading = Task {
                do {
                    return try await store.load() ?? UploadSpeedsFile()
                } catch {
                    log("Couldn’t read \(UploadSpeedsFile.fileName), so no upload speed measurements are used until a test runs: \(Self.describe(error))")
                    return UploadSpeedsFile()
                }
            }
        }
        let loaded = await loading?.value ?? UploadSpeedsFile()
        if file == nil { file = loaded }
        return file?.records ?? [:]
    }

    private func save() async {
        guard let file else { return }
        do {
            try await store.save(file)
        } catch {
            guard !loggedSaveFailure else { return }
            loggedSaveFailure = true
            log("Couldn’t save \(UploadSpeedsFile.fileName), so upload speed measurements are kept only until the agent restarts: \(Self.describe(error))")
        }
    }

    /// What went wrong with the file, never the error's own description: a decoding error's coding path holds the
    /// stored key, which for a Wi-Fi network contains its name, and a Release log never names the network.
    static func describe(_ error: any Error) -> String {
        switch error as? VersionedStoreError {
        case .newerSchema(let found, _)?: "written by a newer Restorey (schema \(found))"
        case .corrupt?: "corrupt"
        case .missingMigration?, .migrationFailed?: "can’t be migrated"
        case nil: error is DecodingError || error is EncodingError ? "corrupt" : "an error reading or writing the file"
        }
    }

    static func megabits(_ bitsPerSecond: Double) -> String {
        let megabits = bitsPerSecond / 1_000_000
        return megabits >= 10 ? String(Int(megabits.rounded())) : String(format: "%.1f", megabits)
    }

    private static func seconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return String(format: "%.1f s", Double(seconds) + Double(attoseconds) / 1e18)
    }
}

extension NetworkKey {
    /// The network as a log line names it: "Wi-Fi", "Wi-Fi (name unknown)", "Ethernet", "this network". A Release log
    /// never names the Wi-Fi network, which says where the user is; a Debug build's does, in quotes (“Kerr Home”), as
    /// `SystemObservers.wiFiName()` logs the name it reads.
    var logName: String {
        guard case .wiFi = self else { return displayName }
        #if DEBUG
        return "“\(displayName)”"
        #else
        return "Wi-Fi"
        #endif
    }
}

/// Why an upload speed test won't run now. `message` is the sentence shown to the user, with no closing full stop.
public enum SpeedTestRefusal: Error, Equatable, Sendable {
    case noNetwork
    /// A constrained or expensive network (a phone hotspot, Low Data Mode).
    case constrained
    /// A Wi-Fi network in the skip list, by the name the Mac reported.
    case skippedWiFi(String)
    /// restic is running a command against a networked repository.
    case networkedCommandRunning

    public var message: String {
        switch self {
        case .noNetwork: "The upload speed can’t be tested without a network connection"
        case .constrained: "The upload speed isn’t tested on a phone hotspot or in Low Data Mode"
        case .skippedWiFi(let name):
            "The upload speed isn’t tested on “\(name.trimmingCharacters(in: .whitespacesAndNewlines))”, a Wi-Fi network backups skip"
        case .networkedCommandRunning:
            "The upload speed can’t be tested while a backup or another restic command is using the network"
        }
    }

    /// Why no test may run on `network`, nil when one may: never with no network, never on a constrained or expensive
    /// network (whatever `skipOnConstrainedNetwork` says: a test there would spend mobile data and measure the wrong
    /// line), never on a skipped Wi-Fi network, and never while a networked restic command runs.
    public static func check(
        network: NetworkState, settings: NetworkSettings, wiFiName: String?, networkedCommandRunning: Bool
    ) -> SpeedTestRefusal? {
        guard case .satisfied(let constrained, let expensive, _) = network else { return .noNetwork }
        if constrained || expensive { return .constrained }
        if let wiFiName, settings.isSkipped(wiFiName: wiFiName) { return .skippedWiFi(wiFiName) }
        if networkedCommandRunning { return .networkedCommandRunning }
        return nil
    }
}
