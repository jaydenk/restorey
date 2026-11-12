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

    override init() {
        super.init()
        manager.delegate = self
    }

    /// For `hello`: nil until the user has been asked (or before the manager's first report).
    nonisolated var knownAuthorised: Bool? {
        lastReported.withLock { status in status.flatMap(Self.authorised) }
    }

    /// Shows the system prompt if the user hasn't answered yet and waits for the answer (at most
    /// `requestBound`); otherwise returns the authorisation at once, as macOS asks only once.
    func request() async -> LocationPermissionReply {
        let status = manager.authorizationStatus
        guard status == .notDetermined else { return Self.reply(status) }
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
        guard status != .notDetermined else { return }
        // Delivered on the main thread, where the manager was made (see the type's comment).
        MainActor.assumeIsolated {
            for id in Array(waiting.keys) { finish(id, with: status) }
        }
    }

    private func finish(_ id: UUID, with status: CLAuthorizationStatus) {
        waiting.removeValue(forKey: id)?.resume(returning: Self.reply(status))
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

    nonisolated static func reply(_ status: CLAuthorizationStatus) -> LocationPermissionReply {
        let name =
            switch status {
            case .notDetermined: "notDetermined"
            case .restricted: "restricted"
            case .denied: "denied"
            case .authorizedAlways: "authorisedAlways"
            case .authorizedWhenInUse: "authorisedWhenInUse"
            @unknown default: "unknown"
            }
        return LocationPermissionReply(authorised: authorised(status) == true, status: name)
    }
}
