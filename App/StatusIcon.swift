import AppKit
import RestoreyCore

/// The menu bar icon for each `StatusIconState` (UI design §5): the "Layers" glyph, which matches the app icon. Three
/// stacked snapshot layers fade back in time (the newest full, the next 65 %, the oldest 35 %); the top slot says what
/// is happening. Idle shows the newest layer; while backing up it lifts away as an arrow; paused shows a pause mark;
/// needs attention a "!"; and a problem that stops backups an "×". The two older layers never change, so the icon
/// keeps its size and place in the menu bar from state to state.
///
/// The art is in `App/Assets.xcassets` as vector SVG template images (black with partial alpha). A template image is
/// drawn from its alpha channel ("You can use the alpha channel in the image to adjust the opacity of black content",
/// `NSImage.isTemplate`), so the menu bar tints it for light and dark, dims it on an inactive display, and keeps the
/// fade. `verify-bundle.sh` checks every name below is in the built `Assets.car`.
@MainActor
enum StatusIcon {
    static func image(for state: StatusIconState) -> NSImage {
        if let cached = cache[state] { return cached }
        let image = make(state)
        cache[state] = image
        return image
    }

    private static var cache: [StatusIconState: NSImage] = [:]

    static func accessibilityDescription(for state: StatusIconState) -> String {
        switch state {
        case .ok: "Restorey"
        case .backingUp: "Restorey: backing up"
        case .paused: "Restorey: paused"
        case .warning: "Restorey: needs attention"
        case .error: "Restorey: a problem stops backups"
        }
    }

    /// The asset catalog image for each state.
    static func assetName(for state: StatusIconState) -> String {
        switch state {
        case .ok: "StatusIdle"
        case .backingUp: "StatusBackingUp"
        case .paused: "StatusPaused"
        case .warning: "StatusAttention"
        case .error: "StatusError"
        }
    }

    private static func make(_ state: StatusIconState) -> NSImage {
        let name = assetName(for: state)
        // The catalog is compiled into the app; a missing image is a broken build, which verify-bundle.sh rejects.
        guard let asset = NSImage(named: name), let image = asset.copy() as? NSImage else {
            preconditionFailure("\(name) is missing from the app's asset catalog")
        }
        // The catalog marks these as templates; set it again so the tinting never depends on that one setting.
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription(for: state)
        return image
    }
}
