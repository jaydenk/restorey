import AgentCore
import CoreLocation
import Foundation
import RestoreyCore

/// The agent's Location Services authorisation, which macOS requires before CoreWLAN reveals the Wi-Fi
/// network's name (`WiFiName`). The app asks for it over XPC (`requestLocationPermission`) when the user
/// first lists a Wi-Fi network to skip, and reads it without asking (`locationAccess`) when the Network pane
/// appears or Restorey comes to the front; the prompt names the agent's display name (Ruling R61).
///
/// The decisions are `LocationAccess`'s (AgentCore, tested with a fake Core Location); this wraps one
/// `CLLocationManager` around it, made on the main thread: Core Location delivers its delegate calls on the
/// thread whose run loop made the manager, and the agent's main thread runs `NSApplication`'s. The manager
/// reports the current authorisation as soon as it is made and again on every change, so `hello` reads only
/// what is held (Ruling R68).
@MainActor
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    /// How long a request waits for the user before replying with the authorisation as it stands. Under the
    /// app's 600 s timeout, so the agent replies (and keeps no waiter) before the app gives up.
    static let requestBound: Duration = .seconds(570)
    /// How long a reply waits for `locationServicesEnabled()` before taking the last value known.
    static let servicesBound: Duration = .seconds(3)

    private let manager: CLLocationManager
    private let access: LocationAccess

    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        access = LocationAccess(
            api: LocationAccess.API(
                servicesEnabled: { CLLocationManager.locationServicesEnabled() },
                status: { [manager] in Self.authorisation(manager.authorizationStatus) },
                requestWhenInUse: { [manager] in manager.requestWhenInUseAuthorization() }),
            requestBound: Self.requestBound, servicesBound: Self.servicesBound)
        super.init()
        manager.delegate = self
    }

    /// For `hello`: nil until the user has been asked (or before the manager's first report).
    nonisolated var knownAuthorised: Bool? { access.knownAuthorised }

    /// For `hello`: whether Location Services is on for the Mac, as last read.
    nonisolated var knownServicesEnabled: Bool? { access.knownServicesEnabled }

    func request() async -> LocationPermissionReply { await access.request() }

    func current() async -> LocationPermissionReply { await access.current() }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = Self.authorisation(manager.authorizationStatus)
        // Delivered on the main thread, where the manager was made (see the type's comment).
        MainActor.assumeIsolated { access.statusChanged(status) }
    }

    nonisolated static func authorisation(_ status: CLAuthorizationStatus) -> LocationAuthorisation {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorizedAlways: .authorisedAlways
        case .authorizedWhenInUse: .authorisedWhenInUse
        @unknown default: .unknown
        }
    }
}
