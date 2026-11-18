import Dispatch
import Foundation
import RestoreyCore
import Synchronization

/// The agent's Location Services authorisation, in the words its replies use (`LocationPermissionReply.status`).
/// The agent maps `CLAuthorizationStatus` to it (`Agent/LocationPermission.swift`).
public enum LocationAuthorisation: String, Sendable, Equatable {
    case notDetermined, restricted, denied, authorisedAlways, authorisedWhenInUse, unknown

    /// macOS treats "always" and "when in use" alike: an app that keeps running is always in use. Nil until the user
    /// has answered.
    public var authorised: Bool? {
        switch self {
        case .authorisedAlways, .authorisedWhenInUse: true
        case .denied, .restricted, .unknown: false
        case .notDetermined: nil
        }
    }
}

/// What the agent knows and asks about Location, which macOS requires before CoreWLAN reveals the Wi-Fi network's
/// name (UI design §6.3). Core Location is injected (`API`), so this is tested without it; the agent wraps one
/// `CLLocationManager` around it.
///
/// - Location Services switched off for the whole Mac is read (`API.servicesEnabled`, a synchronous call to
///   locationd that Apple warns against making on the main thread) on a dispatch queue, one read at a time, and each
///   caller waits at most `servicesBound` for it, then takes the last value known (fix round 1, M1).
/// - With services off, `request` answers at once and never asks macOS, which would show no prompt and leave the
///   request waiting out `requestBound` (Task 15); the status then comes from Core Location's last report, so the
///   branch makes no other Core Location call (M2).
/// - The switch is read again on each change Core Location reports and on each `current()` (the app's
///   `locationAccess` call, made when the Network pane appears or Restorey comes to the front), never per hello (I2).
@MainActor
public final class LocationAccess {
    public struct API: Sendable {
        /// `CLLocationManager.locationServicesEnabled()`. Blocking; never called on the main thread.
        public var servicesEnabled: @Sendable () -> Bool
        /// The manager's `authorizationStatus`.
        public var status: @MainActor () -> LocationAuthorisation
        /// `requestWhenInUseAuthorization()`.
        public var requestWhenInUse: @MainActor () -> Void

        public init(
            servicesEnabled: @escaping @Sendable () -> Bool, status: @escaping @MainActor () -> LocationAuthorisation,
            requestWhenInUse: @escaping @MainActor () -> Void
        ) {
            self.servicesEnabled = servicesEnabled
            self.status = status
            self.requestWhenInUse = requestWhenInUse
        }
    }

    private let api: API
    private let requestBound: Duration
    private let servicesBound: Duration
    /// What the bounds sleep on: tests pass a clock they move themselves, so no test depends on when the scheduler
    /// wakes a sleeper (task 18).
    private let clock: any Clock<Duration>
    private let queue = DispatchQueue(label: "Restorey.LocationServices", qos: .userInitiated)

    /// The last status Core Location reported; nil until its first report.
    private let lastReported = Mutex<LocationAuthorisation?>(nil)
    /// The last services read; nil until the first finishes.
    private let servicesEnabled = Mutex<Bool?>(nil)
    private var reading = false
    /// `readSettled()` callers, resumed when the read in flight finishes.
    private var readSettledWaiters: [CheckedContinuation<Void, Never>] = []
    /// Callers waiting for the services read, each with its bound's timer (stopped once the read answers).
    private var servicesWaiters: [UUID: (continuation: CheckedContinuation<Bool?, Never>, bound: Task<Void, Never>)] = [:]
    /// Requests waiting for the user to answer the prompt, resumed together by the next decided status, each with its
    /// bound's timer.
    private var waiting: [UUID: (continuation: CheckedContinuation<LocationPermissionReply, Never>, bound: Task<Void, Never>)] = [:]

    public init(api: API, requestBound: Duration, servicesBound: Duration, clock: any Clock<Duration> = ContinuousClock()) {
        self.api = api
        self.requestBound = requestBound
        self.servicesBound = servicesBound
        self.clock = clock
    }

    /// For `hello`: nil until the user has been asked (or before Core Location's first report).
    public nonisolated var knownAuthorised: Bool? { lastReported.withLock { $0?.authorised } }

    /// For `hello`: whether Location Services is on for the Mac, as last read; nil before the first read.
    public nonisolated var knownServicesEnabled: Bool? { servicesEnabled.withLock { $0 } }

    /// Core Location reported a status (`locationManagerDidChangeAuthorization`): kept, the switch read again in
    /// the background (switching it changes the agent's status too), and any waiting request answered once decided.
    public func statusChanged(_ status: LocationAuthorisation) {
        lastReported.withLock { $0 = status }
        startServicesRead()
        guard status != .notDetermined else { return }
        for id in Array(waiting.keys) { finish(id, status: status, servicesEnabled: knownServicesEnabled) }
    }

    /// The `locationAccess` call: the switch read afresh (bounded) and the authorisation, without asking.
    public func current() async -> LocationPermissionReply {
        let enabled = await readServices()
        // With services off no other Core Location call is made; before the first report one status read is.
        let status = lastReported.withLock { $0 } ?? (enabled == false ? .notDetermined : api.status())
        return Self.reply(status, servicesEnabled: enabled)
    }

    /// Shows the system prompt if the user hasn't answered yet and waits for the answer (at most `requestBound`);
    /// otherwise returns the authorisation at once, as macOS asks only once. With Location Services off for the Mac
    /// it returns at once, without asking. A read that times out with nothing known goes on as if services were on.
    public func request() async -> LocationPermissionReply {
        let enabled = await readServices()
        if enabled == false {
            return Self.reply(lastReported.withLock { $0 } ?? .notDetermined, servicesEnabled: false)
        }
        let status = api.status()
        guard status == .notDetermined else { return Self.reply(status, servicesEnabled: enabled) }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let first = waiting.isEmpty
            let bound = Task { [weak self, requestBound, clock] in
                guard (try? await clock.sleep(for: requestBound)) != nil, let self else { return }
                finish(id, status: lastReported.withLock { $0 } ?? .notDetermined, servicesEnabled: knownServicesEnabled)
            }
            waiting[id] = (continuation, bound)
            // One prompt however many callers wait; a second request would do nothing anyway.
            if first { api.requestWhenInUse() }
        }
    }

    // MARK: The services read

    /// The switch, read now or joined to the read in flight; the last value known after `servicesBound`.
    private func readServices() async -> Bool? {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let bound = Task { [weak self, servicesBound, clock] in
                guard (try? await clock.sleep(for: servicesBound)) != nil, let self else { return }
                servicesWaiters.removeValue(forKey: id)?.continuation.resume(returning: knownServicesEnabled)
            }
            servicesWaiters[id] = (continuation, bound)
            startServicesRead()
        }
    }

    private func startServicesRead() {
        guard !reading else { return }
        reading = true
        queue.async { [weak self, api] in
            let enabled = api.servicesEnabled()
            Task { @MainActor in self?.servicesRead(enabled) }
        }
    }

    /// Returns once no services read is in flight (at once if none is). For tests: waits for a background read to
    /// land without polling.
    func readSettled() async {
        guard reading else { return }
        await withCheckedContinuation { readSettledWaiters.append($0) }
    }

    private func servicesRead(_ enabled: Bool) {
        servicesEnabled.withLock { $0 = enabled }
        reading = false
        let settled = readSettledWaiters
        readSettledWaiters = []
        for waiter in settled { waiter.resume() }
        let waiters = servicesWaiters
        servicesWaiters = [:]
        for waiter in waiters.values {
            waiter.bound.cancel()
            waiter.continuation.resume(returning: enabled)
        }
    }

    private func finish(_ id: UUID, status: LocationAuthorisation, servicesEnabled: Bool?) {
        guard let waiter = waiting.removeValue(forKey: id) else { return }
        waiter.bound.cancel()
        waiter.continuation.resume(returning: Self.reply(status, servicesEnabled: servicesEnabled))
    }

    private static func reply(_ status: LocationAuthorisation, servicesEnabled: Bool?) -> LocationPermissionReply {
        LocationPermissionReply(
            authorised: servicesEnabled != false && status.authorised == true, status: status.rawValue,
            servicesEnabled: servicesEnabled)
    }
}
