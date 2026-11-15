import CoreLocation
import Foundation
import RestoreyCore
import Synchronization

/// The agent's Location Services authorisation, which macOS requires before CoreWLAN reveals the Wi-Fi
/// network's name (`WiFiName`). The app asks for it over XPC (`requestLocationPermission`) when the user
/// first lists a Wi-Fi network to skip; the prompt names the agent's display name (Ruling R61).
///
/// One `CLLocationManager`, made on the main thread: Core Location delivers its delegate calls on the
/// thread whose run loop made the manager, and the agent's main thread runs `NSApplication`'s. The manager
/// reports the current authorisation as soon as it is made and again on every change, so `knownAuthorised`
/// is kept from those reports and `hello` never asks Core Location (Ruling R68).
///
/// Location Services switched off for the whole Mac (System Settings → Privacy & Security → Location Services) is
/// checked before asking: with it off macOS shows no prompt (`requestWhenInUseAuthorization` documents that it
/// does nothing unless the status is undecided, and an undecided agent can stay undecided), so the request would
/// otherwise wait the full `requestBound` for an answer that can't come. `CLLocationManager.locationServicesEnabled()`
/// is a synchronous call to locationd, which Apple warns not to make on the main thread, so it runs on a utility
/// queue and its last answer is kept for `hello` (`knownServicesEnabled`).
@MainActor
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    /// How long a request waits for the user before replying with the authorisation as it stands. Under the
    /// app's 600 s timeout, so the agent replies (and keeps no waiter) before the app gives up.
    static let requestBound: Duration = .seconds(570)

    private let manager = CLLocationManager()
    /// The last authorisation the manager reported; nil until its first report.
    private let lastReported = Mutex<CLAuthorizationStatus?>(nil)
    /// Requests waiting for the user to answer the prompt, resumed together by the next decided status.
    private var waiting: [UUID: CheckedContinuation<LocationPermissionReply, Never>] = [:]
    /// The last answer from `locationServicesEnabled()`; nil until the first one.
    private let servicesEnabled = Mutex<Bool?>(nil)
    /// A background read of `locationServicesEnabled()` is under way: at most one, so a locationd that doesn't
    /// answer holds one thread, not one per hello.
    private let readingServices = Mutex(false)

    override init() {
        super.init()
        manager.delegate = self
        refreshServicesEnabled()
    }

    /// For `hello`: nil until the user has been asked (or before the manager's first report).
    nonisolated var knownAuthorised: Bool? {
        lastReported.withLock { status in status.flatMap(Self.authorised) }
    }

    /// For `hello`: whether Location Services is on for the Mac, as last read; nil before the first read.
    nonisolated var knownServicesEnabled: Bool? { servicesEnabled.withLock { $0 } }

    /// Reads `locationServicesEnabled()` again in the background, unless a read is already under way, so the next
    /// hello carries a switch the user has since flipped. Never waits.
    nonisolated func refreshServicesEnabled() {
        let start = readingServices.withLock { busy in
            defer { busy = true }
            return !busy
        }
        guard start else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            let enabled = CLLocationManager.locationServicesEnabled()
            servicesEnabled.withLock { $0 = enabled }
            readingServices.withLock { $0 = false }
        }
    }

    /// Reads `locationServicesEnabled()` now, off the main thread, and keeps the answer.
    private nonisolated func readServicesEnabled() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let enabled = CLLocationManager.locationServicesEnabled()
                servicesEnabled.withLock { $0 = enabled }
                continuation.resume(returning: enabled)
            }
        }
    }

    /// Shows the system prompt if the user hasn't answered yet and waits for the answer (at most
    /// `requestBound`); otherwise returns the authorisation at once, as macOS asks only once. With Location
    /// Services off for the Mac it returns at once, without asking.
    func request() async -> LocationPermissionReply {
        guard await readServicesEnabled() else {
            // No app can use Location now, whatever the agent's own answer was.
            var reply = Self.reply(manager.authorizationStatus, servicesEnabled: false)
            reply.authorised = false
            return reply
        }
        let status = manager.authorizationStatus
        guard status == .notDetermined else { return Self.reply(status, servicesEnabled: true) }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let first = waiting.isEmpty
            waiting[id] = continuation
            // One prompt however many callers wait; a second request would do nothing anyway.
            if first { manager.requestWhenInUseAuthorization() }
            Task { [weak self] in
                try? await Task.sleep(for: Self.requestBound)
                self?.finish(id, with: self?.manager.authorizationStatus ?? .notDetermined)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        lastReported.withLock { $0 = status }
        // Switching Location Services off or on for the Mac changes the agent's status too.
        refreshServicesEnabled()
        guard status != .notDetermined else { return }
        // Delivered on the main thread, where the manager was made (see the type's comment).
        MainActor.assumeIsolated {
            for id in Array(waiting.keys) { finish(id, with: status) }
        }
    }

    private func finish(_ id: UUID, with status: CLAuthorizationStatus) {
        waiting.removeValue(forKey: id)?.resume(returning: Self.reply(status, servicesEnabled: knownServicesEnabled))
    }

    // MARK: Mapping

    /// macOS treats "always" and "when in use" alike: an app that keeps running is always in use.
    nonisolated static func authorised(_ status: CLAuthorizationStatus) -> Bool? {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: true
        case .denied, .restricted: false
        case .notDetermined: nil
        @unknown default: false
        }
    }

    nonisolated static func reply(_ status: CLAuthorizationStatus, servicesEnabled: Bool?) -> LocationPermissionReply {
        let name =
            switch status {
            case .notDetermined: "notDetermined"
            case .restricted: "restricted"
            case .denied: "denied"
            case .authorizedAlways: "authorisedAlways"
            case .authorizedWhenInUse: "authorisedWhenInUse"
            @unknown default: "unknown"
            }
        return LocationPermissionReply(authorised: authorised(status) == true, status: name, servicesEnabled: servicesEnabled)
    }
}
